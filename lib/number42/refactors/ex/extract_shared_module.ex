defmodule Number42.Refactors.Ex.ExtractSharedModule do
  @moduledoc """
  Extracts exact-duplicate public functions across modules into a new
  `{LCP}.Shared` module and replaces both originals with `defdelegate`
  to it.

      # before
      defmodule MyApp.Items do
        def assign(scope, attrs), do: ...big shared body...
      end

      defmodule MyApp.Items.Positions do
        def assign(scope, attrs), do: ...same big shared body...
      end

      # after — three files
      defmodule MyApp.Items do
        defdelegate assign(scope, attrs), to: MyApp.Items.Shared
      end

      defmodule MyApp.Items.Positions do
        defdelegate assign(scope, attrs), to: MyApp.Items.Shared
      end

      defmodule MyApp.Items.Shared do
        def assign(scope, attrs), do: ...big shared body...
      end

  ## Why a shared module instead of `defdelegate` to one of the
  ## originals?

  Phase 1 (`DelegateExactDuplicates`) picks one of the cloned modules
  as winner and the others delegate to it. That introduces an
  asymmetric dependency: a domain module like `MyApp.Items` ends up
  depending on a more specific submodule `MyApp.Items.Positions` for
  basic operations.

  This refactor breaks the tie symmetrically: the implementation moves
  to a fresh `{LCP}.Shared` module and *every* original delegates to
  it. The history is honest — the function is genuinely shared, not
  owned by one of the originals — and downstream tooling can spot the
  pattern by name (any `*.Shared` module is by convention a shared-
  function host).

  ## Longest common prefix (LCP)

  The new module's namespace is the longest common prefix of the
  originals' module names, suffixed with `.Shared`. We require LCP ≥ 2
  segments — a single common segment would produce a project-wide
  `MyApp.Shared`, which is exactly the kind of grab-bag this refactor
  is supposed to *avoid*.

  Examples:

      MyApp.Items, MyApp.Items.Positions
        → LCP = MyApp.Items, target = MyApp.Items.Shared

      MyApp.Items.A, MyApp.Items.B
        → LCP = MyApp.Items, target = MyApp.Items.Shared

      MyApp.Foo, MyApp.Bar
        → LCP = MyApp (only 1 segment) — SKIP

      MyApp.Foo, OtherApp.Bar
        → LCP = empty — SKIP

  ## Match criteria (same as Phase 1, with one extra)

    1. Public functions only (`def`).
    2. All clauses identical after AST/var normalization.
    3. Heads contain only plain variable arguments.
    4. Bodies don't reference module attributes.
    5. Body has at least `min_mass` AST nodes (default 20).
    6. **All originals share the same `import` statements**, otherwise
       the extracted body wouldn't compile in the shared module.

  ## Body rendering in the shared module

  Every alias used inside the body is **fully qualified** when written
  to the shared module: `Repo.all(query)` becomes
  `MyApp.Repo.all(query)` if the original had `alias MyApp.Repo`. That
  way the shared module needs no `alias` of its own and we can never
  get into alias-conflict territory between originals. The
  `AliasUsage` refactor will shorten the result on a later pass if you
  want.

  ## Helper migration

  Local `defp` helpers reachable only from the cloned function are
  migrated into the shared module along with the function itself, then
  deleted from the originals (same reachability analysis as in
  Phase 1's cleanup step).

  ## Side effect: file write

  Unlike all other refactors, `prepare/1` writes a new `.ex` file to
  disk for each shared module it plans. The destination is computed
  from the module name via the standard Phoenix/Elixir convention
  (`MyApp.Items.Shared` → `lib/my_app/items/shared.ex`).

  ## `write_root` and dry-run

  `write_root` is the directory where new `*.Shared` files land. It
  defaults to `File.cwd!/0`; tests pass a per-test tmp dir to keep
  writes contained. When the engine runs with `dry_run: true` (i.e.
  `mix refactor --dry-run`) the planner still produces a full plan
  but skips every disk write, so previews never mutate the project
  tree.
  """

  use Number42.Refactors.Refactor

  @default_min_mass 20

  @excluded_path_prefixes ["test/", "dev/"]

  @doc """
  Build a rewrite plan from `[{path, source_string}]` tuples.

  Side effect: writes one new `.ex` file per shared module to
  `opts[:write_root]` (defaults to `File.cwd!/0`). Pass
  `dry_run: true` to skip every disk write while still returning a
  fully populated plan (used by `mix refactor --dry-run`).

  Plan shape: `%{loser_module => [{name, arity, args, shared_module}]}`.
  """
  @spec build_plan([{String.t(), String.t()}], keyword()) :: %{
          module() => [{atom(), arity(), [atom()], module()}]
        }
  def build_plan(sources, opts \\ []) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)
    write_root = Keyword.get(opts, :write_root, File.cwd!())
    dry_run? = Keyword.get(opts, :dry_run, false)

    # Excluded paths (test/, dev/refactors/refactors/) are never valid
    # extraction sources, regardless of how they got here. Test code
    # would otherwise leak Shared modules into the lib/ tree via the
    # module-name → file-path convention, and the refactor's own
    # source files would re-extract themselves into a self-referential
    # mess. Filter unconditionally — callers that legitimately want
    # those paths included would have to opt out explicitly, and so
    # far nobody does.
    sources
    |> Enum.reject(fn {path, _src} -> excluded_path?(path) end)
    |> do_build_plan(min_mass, write_root, dry_run?)
  end

  # On-disk paths of the (non-excluded) source files, used to derive the
  # real `lib/<dir>` layout instead of naively underscoring the namespace.
  defp source_paths(sources), do: sources |> Enum.map(fn {path, _src} -> path end)

  @impl Number42.Refactors.Refactor
  def description, do: "Cross-file: extract exact duplicates into a {LCP}.Shared module"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Same function body in two or more modules → extract the body into
    a fresh `{LCP}.Shared` module, replace every original with
    `defdelegate ..., to: ...Shared`. Symmetric (no module "owns" the
    implementation), discoverable by name (`*.Shared` is the
    convention), and stable (CI tooling can flag unexpected
    `*.Shared`-creation as architecture drift).
    """
  end

  @impl Number42.Refactors.Refactor
  def prepare(opts), do: Keyword.get(opts, :source_files) |> prepared_for_paths(opts)
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, opts),
    do: Keyword.get(opts, :prepared) |> rewrite_with_plan_or_passthrough(source)

  defp all_imports_match?([first | rest]) do
    keys = fn entries -> entries.imports |> Enum.map(fn {k, _} -> k end) end
    first_keys = keys.(first)
    rest |> Enum.all?(&(keys.(&1) == first_keys))
  end

  defp apply_plan_to_ast(ast, source, plan) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, mod} ->
            if shared_module?(mod) do
              # `*.Shared` is the target of this refactor — never patch
              # one as a loser. Otherwise we'd inject `import Self, only:
              # [...]` and rewrite the function we just extracted into a
              # delegate to itself.
              []
            else
              patches_for_module(mod, body_to_exprs(body), plan)
            end

          :error ->
            []
        end

      _ ->
        []
    end)
    |> patch_or_passthrough(source)
  end

  defp apply_plan_to_parse_result({:ok, ast}, plan, source),
    do: ast |> apply_plan_to_ast(source, plan)

  defp apply_plan_to_parse_result({:error, _}, _plan, source), do: source

  defp args_are_plain_vars?({_name, _, args}) when is_list(args),
    do: args |> Enum.all?(&plain_var?/1)

  defp args_are_plain_vars?({_name, _, nil}), do: true
  defp args_are_plain_vars?(_), do: false

  defp attr_migratable?(name, module_attrs),
    do: Map.fetch(module_attrs, name) |> attr_value_literal?()

  defp attr_refs_in(ast) do
    {_, refs} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{name, _, ctx}]} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    refs
  end

  defp attr_value_literal?({:ok, value}), do: value |> value_literal?()
  defp attr_value_literal?(:error), do: false

  defp attrs_consistent_across_entries?([first | rest]) do
    first.attrs
    |> Enum.all?(fn {name, value} ->
      stripped = strip_meta(value)

      rest
      |> Enum.all?(fn e ->
        case Map.fetch(e.attrs, name) do
          {:ok, other} -> strip_meta(other) == stripped
          :error -> false
        end
      end)
    end)
  end

  defp body_calls_unmigratable_local?(clauses, helper_clauses, body_exprs) do
    body_calls = collect_calls_in_clauses(clauses)

    migratable_set =
      helper_clauses
      |> Enum.map(&clause_name_arity/1)
      |> MapSet.new()

    locally_defined =
      body_exprs
      |> collect_definitions()
      |> Enum.map(&{&1.name, &1.arity})
      |> MapSet.new()

    body_calls
    |> Enum.any?(fn {name, arity} = call ->
      MapSet.member?(locally_defined, call) and not MapSet.member?(migratable_set, {name, arity})
    end)
  end

  defp build_clause_group_patch(first_node, last_node, replacement) do
    with %{start: start_pos} <- Sourceror.get_range(first_node),
         %{end: end_pos} <- Sourceror.get_range(last_node) do
      [%{change: replacement, range: %{end: end_pos, start: start_pos}}]
    else
      _ -> []
    end
  end

  defp build_function_entry(
         module,
         kind,
         name,
         arity,
         clauses,
         body_exprs,
         aliases,
         imports,
         module_attrs,
         has_use,
         source,
         min_mass
       ) do
    cond do
      total_mass(clauses) < min_mass ->
        []

      true ->
        # All clauses are plain-var? Then we can render `defdelegate`
        # in the original. Otherwise we'll need a wrapper-`def`.
        all_plain = clauses |> Enum.all?(&plain_var_clause?/1)

        # Generate synthetic arg names `arg_0, arg_1, ...` for the
        # wrapper. (For plain-var clauses we still use the original
        # arg names — that's nicer to read in `defdelegate`.)
        wrapper_args = generate_wrapper_args(arity)

        delegate_args =
          if all_plain, do: clause_arg_names(hd(clauses)), else: wrapper_args

        hashed_clause = hash_clauses(clauses)

        # Helpers reachable only from these clauses (transitively),
        # collected for migration.
        helper_clauses = reachable_helper_clauses(body_exprs, name, arity)

        with false <- body_calls_unmigratable_local?(clauses, helper_clauses, body_exprs),
             {:ok, attrs_to_migrate} <-
               resolve_attrs_for_migration(clauses, helper_clauses, module_attrs) do
          [
            %{
              aliases: aliases,
              all_plain: all_plain,
              args: delegate_args,
              arity: arity,
              attrs: attrs_to_migrate,
              clauses: clauses,
              has_use: has_use,
              hash: hashed_clause,
              helper_clauses: helper_clauses,
              imports: imports,
              kind: kind,
              module: module,
              name: name,
              source: source
            }
          ]
        else
          _ -> []
        end
    end
  end

  defp build_import_patches(body_exprs, entries) do
    defp_entries = entries |> Enum.filter(&(&1.kind == :defp))

    if defp_entries == [] do
      []
    else
      grouped = defp_entries |> Enum.group_by(& &1.target)

      grouped
      |> Enum.flat_map(fn {target, group_entries} ->
        new_pairs =
          group_entries
          |> Enum.map(fn e -> {e.name, e.arity} end)
          |> Enum.uniq()

        case find_existing_import_for_target(body_exprs, target) do
          {:full, _node} ->
            # The loser already does `import Target` without `only:`.
            # Migrated helpers are reachable through the wide import —
            # nothing to patch.
            []

          {:only, node, existing_pairs} ->
            # Extend the existing `only:` list to include the new
            # helpers. Anything already imported stays imported, so we
            # never break callers of pre-existing functions.
            merged =
              (existing_pairs ++ new_pairs)
              |> Enum.uniq()
              |> Enum.sort()

            only_list =
              merged |> Enum.map_join(", ", fn {n, a} -> "#{n}: #{a}" end)

            replacement = "import #{inspect(target)}, only: [#{only_list}]"

            case Sourceror.get_range(node) do
              %{end: end_pos, start: start_pos} ->
                [%{change: replacement, range: %{end: end_pos, start: start_pos}}]

              _ ->
                []
            end

          :none ->
            only_list =
              new_pairs |> Enum.sort() |> Enum.map_join(", ", fn {n, a} -> "#{n}: #{a}" end)

            replacement = "import #{inspect(target)}, only: [#{only_list}]"
            # IMPORTANT: anchor on the *first def/defp in the module*, not
            # on the first removed clause. `import` is positionally scoped
            # — a `defp` that calls the migrated helper appears earlier in
            # the source and would not see the import otherwise. Inserting
            # at the very first definition guarantees every later body
            # picks up the new import.
            insertion_anchor = first_def_in_module(body_exprs)

            case insertion_anchor do
              nil ->
                []

              anchor ->
                case Sourceror.get_range(anchor) do
                  %{start: pos} ->
                    [%{change: replacement <> "\n\n  ", range: %{end: pos, start: pos}}]

                  _ ->
                    []
                end
            end
        end
      end)
    end
  end

  defp canonical_import_key(import_node),
    # token meta we've stripped. `inspect` gives us a stable string
    # representation that's good enough for equality checks.
    do: import_node |> strip_meta() |> inspect(limit: :infinity, printable_limit: :infinity)

  defp check_and_emit(entries, name, arity, target_module, _write_root) do
    cond do
      not all_imports_match?(entries) ->
        {[], %{}}

      not attrs_consistent_across_entries?(entries) ->
        # At least one referenced module attribute is defined with
        # diverging values between clone modules. Co-migrating it
        # would silently pick one — refuse instead.
        {[], %{}}

      entries |> Enum.any?(& &1.has_use) ->
        # At least one source module has `use Foo` statements. Macros
        # injected by `use` (e.g. `assign/3` from `Phoenix.LiveView`,
        # `field/3` from `Ecto.Schema`) aren't available in a bare
        # shared module. Refuse the migration — the bare extracted
        # module would fail to compile.
        {[], %{}}

      true ->
        canonical = hd(entries)

        # Sources for the function: every module that contributed a
        # clone (the function genuinely lived in all of them).
        function_sources = entries |> Enum.map(& &1.module) |> MapSet.new()

        # Sources for transitively-migrated helpers: just the canonical
        # module — helpers aren't deduplicated across modules; we only
        # ever pull the helper graph from the winner's body.
        helper_sources =
          for clause <- canonical.helper_clauses do
            {clause_name_arity(clause), MapSet.new([canonical.module])}
          end
          |> Map.new()

        function_with_sources = Map.put(canonical, :sources, function_sources)

        # Build the spec for this clone group. The caller will merge
        # specs by target module across all groups.
        spec_update = %{
          target_module => %{
            aliases: canonical.aliases,
            attributes: canonical.attrs,
            functions: [function_with_sources],
            helper_sources: helper_sources,
            helpers: canonical.helper_clauses,
            imports: canonical.imports
          }
        }

        loser_entries =
          entries
          |> Enum.map(fn entry ->
            {entry.module,
             %{
               all_plain: entry.all_plain,
               args: entry.args,
               arity: arity,
               hash: entry.hash,
               kind: entry.kind,
               name: name,
               target: target_module
             }}
          end)

        {loser_entries, spec_update}
    end
  end

  defp clause_arg_names({kind, _, [head | _]}) when kind in [:def, :defp] do
    head |> strip_when() |> head_arg_names()
  end

  defp clause_mass({kind, _, [_head, body_kw]}) when kind in [:def, :defp] do
    body_kw |> Keyword.values() |> Enum.map(&node_count/1) |> Enum.sum()
  end

  defp clause_matches?({kind, _, [head | _]}, name, arity) when kind in [:def, :defp] do
    case strip_when(head) do
      {^name, _, args} when is_list(args) and length(args) == arity -> true
      {^name, _, nil} when arity == 0 -> true
      _ -> false
    end
  end

  defp clause_matches?(_, _, _), do: false
  defp clause_name_arity({_kind, _, [head | _]}), do: strip_when(head) |> name_arity_or_sentinel()

  defp collect_aliases(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {:alias, _, [{:__aliases__, _, parts}]} ->
        full = Module.concat(parts)
        short = List.last(parts)
        [{short, full}]

      {:alias, _, [{:__aliases__, _, parts}, opts]} ->
        full = Module.concat(parts)

        short =
          case Keyword.get(unwrap_keyword(opts), :as) do
            {:__aliases__, _, [as_name]} -> as_name
            nil -> List.last(parts)
            _ -> List.last(parts)
          end

        [{short, full}]

      {:alias, _, [{{:., _, [{:__aliases__, _, base_parts}, :{}]}, _, sub_aliases}]} ->
        sub_aliases
        |> Enum.map(fn {:__aliases__, _, sub_parts} ->
          full = Module.concat(base_parts ++ sub_parts)
          short = List.last(sub_parts)
          {short, full}
        end)

      _ ->
        []
    end)
    |> Map.new()
  end

  defp collect_attrs_used(clauses, helper_clauses) do
    (clauses ++ helper_clauses)
    |> Enum.flat_map(fn {_, _, [_head, body_kw]} ->
      body_kw
      |> Keyword.values()
      |> Enum.flat_map(&attr_refs_in/1)
    end)
    |> MapSet.new()
  end

  defp collect_imports(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {:import, _, _} = node ->
        [{canonical_import_key(node), node}]

      _ ->
        []
    end)
    |> Enum.sort_by(fn {k, _} -> k end)
  end

  defp collect_module_attributes(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {:@, _, [{name, _, [value]}]} when is_atom(name) -> [{name, value}]
      _ -> []
    end)
    |> Map.new()
  end

  defp dead_helper_patches(body_exprs, delegated_entries) do
    delegated_set =
      delegated_entries
      |> Enum.map(fn e -> {e.name, e.arity} end)
      |> MapSet.new()

    definitions = collect_definitions(body_exprs)

    live_roots =
      definitions
      |> Enum.filter(fn d ->
        d.kind == :def and not MapSet.member?(delegated_set, {d.name, d.arity})
      end)
      |> Enum.map(&{&1.name, &1.arity})
      |> MapSet.new()

    call_graph =
      for d <- definitions do
        {{d.name, d.arity}, d.calls}
      end
      |> Map.new()

    reachable = transitive_closure(live_roots, call_graph)

    definitions
    |> Enum.filter(fn d ->
      # Already going to be replaced by patch_for_function — don't
      # double-patch.
      d.kind == :defp and
        not MapSet.member?(reachable, {d.name, d.arity}) and
        not MapSet.member?(delegated_set, {d.name, d.arity})
    end)
    |> Enum.flat_map(&delete_patch_for/1)
  end

  defp decide_target(entries) do
    parts_lists = entries |> Enum.map(&Module.split(&1.module))
    prefix = longest_common_prefix(parts_lists)

    if prefix != [] do
      target = Module.concat(prefix ++ ["Shared"])
      {:ok, target}
    else
      :skip
    end
  end

  defp def_clause?({kind, _, [_head, body_kw]}) when kind in [:def, :defp] and is_list(body_kw),
    do: true

  defp def_clause?(_), do: false

  defp def_name_arity_or_skip({kind, _, [head | _]}) when kind in [:def, :defp] do
    strip_when(head) |> kind_name_arity_or_skip(kind)
  end

  defp delete_patch_for(%{clauses: [first | _] = clauses}) do
    last = List.last(clauses)

    with %{start: start_pos} <- Sourceror.get_range(first),
         %{end: end_pos} <- Sourceror.get_range(last) do
      [%{change: "", range: %{end: end_pos, start: start_pos}}]
    else
      _ -> []
    end
  end

  defp do_build_plan(sources, min_mass, write_root, dry_run?) do
    paths = source_paths(sources)

    # Two-pass: first collect every loser-rewrite + the canonical entry
    # the shared module should host, *without* touching the filesystem.
    # Then group everything by target module and write each shared file
    # once. That way two clones landing in the same `*.Shared` module
    # are merged into a single output file instead of overwriting.
    {loser_entries, shared_specs} =
      sources
      |> Enum.flat_map(&extract_module_info(&1, min_mass))
      |> group_by_clone()
      |> Enum.flat_map_reduce(%{}, fn group, specs_acc ->
        case plan_for_group(group, write_root) do
          {[], specs_update} -> {[], merge_specs(specs_acc, specs_update)}
          {entries, specs_update} -> {entries, merge_specs(specs_acc, specs_update)}
        end
      end)

    # An earlier refactor pass (typically ExtractParametricClone) may
    # have already written the target Shared module with the helper
    # we're about to migrate as `defp`. The loser-side rewrite would
    # then inject `import Target, only: [helper: arity]` and delete
    # the local `defp`, leaving the caller pointing at a private name.
    # Drop those entries — the local `defp` stays put, and we leave
    # the existing Shared module alone for that name.
    loser_entries =
      loser_entries |> drop_entries_blocked_by_existing_privates(write_root, paths)

    # A loser is only safe to rewrite once the function it delegates to
    # (or imports) is guaranteed to exist as a public `def` in the
    # *canonical* `*.Shared` module — the one the compiler resolves the
    # target name to. When a Shared module already exists for the target
    # namespace but the lift cannot reach it (e.g. it lives at a path the
    # writer doesn't target, so the spec lands in a stray file instead),
    # the body deletion + import rewrite would point the loser at a
    # function that never arrives. Drop those entries so both edits are
    # refused and the source stays compilable.
    loser_entries =
      loser_entries |> drop_entries_with_incomplete_lift(sources, shared_specs, write_root)

    unless dry_run? do
      shared_specs
      |> Enum.each(fn {target, spec} ->
        write_shared_module(target, spec, write_root, paths)
      end)
    end

    loser_entries |> Enum.group_by(fn {loser, _} -> loser end, fn {_, entry} -> entry end)
  end

  # For each target Shared module, the set of public `{name, arity}`
  # functions the loser rewrites are allowed to rely on. Anything not in
  # this set means the lift did not (and will not) land in the module the
  # loser points to — so the loser must keep its local definition.
  defp drop_entries_with_incomplete_lift(loser_entries, sources, shared_specs, write_root) do
    publics_per_target =
      loser_entries
      |> Enum.map(fn {_loser, %{target: t}} -> t end)
      |> Enum.uniq()
      |> Map.new(fn target ->
        {target, lifted_publics_for_target(target, sources, shared_specs, write_root)}
      end)

    loser_entries
    |> Enum.reject(fn {_loser, %{arity: a, name: n, target: t}} ->
      not MapSet.member?(Map.fetch!(publics_per_target, t), {n, a})
    end)
  end

  # Public `{name, arity}` set the canonical `target` module will expose
  # after the writes. Two contributors:
  #
  #   * functions already public in the canonical module (found in the
  #     input sources — `mix refactor` threads the whole file list,
  #     including any pre-existing `*.Shared`, through `source_files`).
  #   * functions/helpers the current plan supplies — but only when they
  #     actually reach the canonical module: either there is no canonical
  #     yet (a fresh module is written and *is* the canonical) or the
  #     writer's path resolves to the existing canonical so the append
  #     lands there.
  defp lifted_publics_for_target(target, sources, shared_specs, write_root) do
    canonical_body = canonical_shared_body(target, sources)
    existing_publics = canonical_public_keys(canonical_body)

    spec_publics =
      case Map.fetch(shared_specs, target) do
        {:ok, spec} -> spec_public_keys(spec)
        :error -> MapSet.new()
      end

    if spec_reaches_canonical?(canonical_body, target, write_root, source_paths(sources)) do
      MapSet.union(existing_publics, spec_publics)
    else
      existing_publics
    end
  end

  # The canonical module's body if it appears among the input sources,
  # else nil. `*.Shared` modules are skipped by `extract_from_ast`, so we
  # look them up here directly by name.
  defp canonical_shared_body(target, sources) do
    sources
    |> Enum.find_value(fn {_path, source} ->
      with {:ok, ast} <- Sourceror.parse_string(source),
           {:ok, body_exprs} <- find_target_module_body(ast, target) do
        body_exprs
      else
        _ -> nil
      end
    end)
  end

  defp canonical_public_keys(nil), do: MapSet.new()

  defp canonical_public_keys(body_exprs) do
    body_exprs
    |> Enum.filter(&match?({:def, _, _}, &1))
    |> Enum.map(&clause_name_arity/1)
    |> Enum.reject(&match?({nil, _}, &1))
    |> MapSet.new()
  end

  # Functions and helpers the spec contributes, all rendered as public
  # `def` in the shared module (helpers are promoted on write).
  defp spec_public_keys(spec) do
    function_keys = spec.functions |> Enum.map(fn e -> {e.name, e.arity} end)
    helper_keys = spec.helpers |> Enum.map(&clause_name_arity/1)

    (function_keys ++ helper_keys)
    |> Enum.reject(&match?({nil, _}, &1))
    |> MapSet.new()
  end

  # nil canonical body → no pre-existing Shared in sources → a fresh
  # module is written at the target path and *is* the canonical one, so
  # the spec always reaches it. Otherwise the append only lands when the
  # writer's path actually resolves to that same existing module.
  defp spec_reaches_canonical?(nil, _target, _write_root, _source_paths), do: true

  defp spec_reaches_canonical?(_canonical_body, target, write_root, source_paths) do
    shared_module_path(target, write_root, source_paths)
    |> read_existing_shared(target)
    |> is_map()
  end

  defp drop_entries_blocked_by_existing_privates(loser_entries, write_root, source_paths) do
    targets =
      loser_entries
      |> Enum.map(fn {_loser, %{target: t}} -> t end)
      |> Enum.uniq()

    privates_per_target =
      Map.new(targets, fn target ->
        path = shared_module_path(target, write_root, source_paths)

        privates =
          case read_existing_shared(path, target) do
            %{private_function_keys: keys} -> keys
            _ -> MapSet.new()
          end

        {target, privates}
      end)

    loser_entries
    |> Enum.reject(fn {_loser, %{arity: a, name: n, target: t}} ->
      MapSet.member?(Map.fetch!(privates_per_target, t), {n, a})
    end)
  end

  defp drop_self_imports(spec, target_module) do
    Map.update!(spec, :imports, fn imports ->
      imports
      |> Enum.reject(fn {_key, node} ->
        import_target_module(node) == target_module
      end)
    end)
  end

  defp entry_still_applicable?(body_exprs, entry),
    do: Map.get(entry, :hash) |> entry_still_applicable?(body_exprs, entry)

  defp entry_still_applicable?(nil, _body_exprs, _entry), do: true

  defp entry_still_applicable?(expected_hash, body_exprs, entry) do
    clauses = body_exprs |> Enum.filter(&clause_matches?(&1, entry.name, entry.arity))
    clauses != [] and hash_clauses(clauses) == expected_hash
  end

  defp excluded_path?(path?) do
    # CLI shell expansion (`mix refactor ./dev/**/*.ex`) leaves `./`
    # on every path; the prefix list uses bare `dev/...`. Normalize
    # the input before comparing or the filter silently misses every
    # CLI-supplied excluded path.
    normalized = String.trim_leading(path?, "./")
    @excluded_path_prefixes |> Enum.any?(&String.starts_with?(normalized, &1))
  end

  defp existing_attribute_names(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {:@, _, [{name, _, [_value]}]} when is_atom(name) -> [name]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp existing_function_keys(body_exprs) do
    body_exprs
    |> Enum.filter(fn
      {kind, _, _} when kind in [:def, :defp] -> true
      _ -> false
    end)
    |> Enum.map(&clause_name_arity/1)
    |> Enum.reject(&match?({nil, _}, &1))
    |> MapSet.new()
  end

  defp existing_import_keys(body_exprs) do
    body_exprs
    |> Enum.filter(fn
      {:import, _, _} -> true
      _ -> false
    end)
    |> Enum.map(&canonical_import_key/1)
    |> MapSet.new()
  end

  defp existing_private_function_keys(body_exprs) do
    body_exprs
    |> Enum.filter(fn
      {:defp, _, _} -> true
      _ -> false
    end)
    |> Enum.map(&clause_name_arity/1)
    |> Enum.reject(&match?({nil, _}, &1))
    |> MapSet.new()
  end

  defp extract_from_ast(ast, source, min_mass) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, mod} ->
            if shared_module?(mod) do
              # `*.Shared` modules are this refactor's own output. Treating
              # their bodies as clone candidates would re-extract functions
              # we already extracted in a previous run and emit imports
              # pointing at the same module being defined — a self-import
              # that fails to compile.
              []
            else
              body_exprs = body_to_exprs(body)
              functions_in_module(mod, body_exprs, source, min_mass)
            end

          :error ->
            []
        end

      _ ->
        []
    end)
  end

  defp extract_from_parse_result({:ok, ast}, min_mass, source),
    do: ast |> extract_from_ast(source, min_mass)

  defp extract_from_parse_result({:error, _}, _min_mass, _source), do: []

  defp extract_module_info({_path, source}, min_mass),
    do: Sourceror.parse_string(source) |> extract_from_parse_result(min_mass, source)

  defp extract_only_pairs(opts) when is_list(opts) do
    opts
    |> Enum.find_value(:no_only, fn
      {key, value} ->
        if unblock_atom(key) == :only do
          {:ok, only_list_to_pairs(unblock_list(value))}
        end

      _ ->
        nil
    end)
  end

  defp extract_only_pairs({:__block__, _, [opts]}) when is_list(opts),
    do: extract_only_pairs(opts)

  defp extract_only_pairs(_), do: :no_only
  defp filter_against_existing(spec, nil), do: spec

  defp filter_against_existing(spec, %{
         attribute_names: anames,
         function_keys: fkeys,
         import_keys: ikeys
       }) do
    %{
      aliases: spec.aliases,
      attributes:
        spec.attributes
        |> Enum.reject(fn {name, _} -> MapSet.member?(anames, name) end)
        |> Map.new(),
      functions: spec.functions |> Enum.reject(&MapSet.member?(fkeys, {&1.name, &1.arity})),
      helper_sources: spec.helper_sources,
      helpers:
        spec.helpers
        |> Enum.reject(&MapSet.member?(fkeys, clause_name_arity(&1))),
      imports: spec.imports |> Enum.reject(fn {key, _} -> MapSet.member?(ikeys, key) end)
    }
  end

  defp find_existing_import_for_target(body_exprs, target) do
    body_exprs
    |> Enum.find_value(:none, fn node ->
      case node do
        {:import, _, [{:__aliases__, _, parts}]} ->
          if Module.concat(parts) == target, do: {:full, node}, else: nil

        {:import, _, [{:__aliases__, _, parts}, opts]} ->
          if Module.concat(parts) == target do
            case extract_only_pairs(opts) do
              :no_only -> {:full, node}
              {:ok, pairs} -> {:only, node, pairs}
            end
          end

        _ ->
          nil
      end
    end)
  end

  defp find_target_module_body(ast, target_module) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, ^target_module} -> {:ok, body_to_exprs(body)}
          _ -> nil
        end

      _ ->
        nil
    end) || :error
  end

  defp first_def_in_module(body_exprs) do
    body_exprs
    |> Enum.find(fn
      {kind, _, _} when kind in [:def, :defp] -> true
      _ -> false
    end)
  end

  defp functions_in_module(module, body_exprs, source, min_mass) do
    aliases = collect_aliases(body_exprs)
    imports = collect_imports(body_exprs)
    module_attrs = collect_module_attributes(body_exprs)
    has_use = has_use_statements?(body_exprs)

    body_exprs
    |> Enum.filter(&def_clause?/1)
    |> Enum.group_by(&def_name_arity_or_skip/1)
    |> Enum.reject(fn {key, _} -> key == :skip end)
    |> Enum.flat_map(fn {{kind, name, arity}, clauses} ->
      build_function_entry(
        module,
        kind,
        name,
        arity,
        clauses,
        body_exprs,
        aliases,
        imports,
        module_attrs,
        has_use,
        source,
        min_mass
      )
    end)
  end

  defp generate_wrapper_args(arity), do: 0..(arity - 1)//1 |> Enum.map(&:"arg_#{&1}")

  defp group_by_clone(entries) do
    entries |> Enum.group_by(fn e -> {e.name, e.arity, e.hash} end)
  end

  defp has_use_statements?(body_exprs) do
    body_exprs
    |> Enum.any?(fn
      {:use, _, _} -> true
      _ -> false
    end)
  end

  defp hash_clauses(clauses), do: clauses |> Enum.map(&normalize_clause/1) |> :erlang.phash2()

  defp head_arg_names({_name, _, args}) when is_list(args) do
    args |> Enum.map(fn {n, _, _} -> n end)
  end

  defp head_arg_names({_name, _, nil}), do: []

  defp import_target_module({:import, _, [{:__aliases__, _, parts} | _]}),
    do: Module.concat(parts)

  defp import_target_module(_), do: nil

  defp indent(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end

  defp kind_name_arity_or_skip({name, _, args}, kind) when is_atom(name) and is_list(args) do
    {kind, name, length(args)}
  end

  defp kind_name_arity_or_skip({name, _, nil}, kind) when is_atom(name) do
    {kind, name, 0}
  end

  defp kind_name_arity_or_skip(_, _kind), do: :skip

  defp load_default_sources,
    do: File.read(".refactor.exs") |> parse_inputs_from_config()

  defp local_call_in_value?(name),
    do:
      not Macro.special_form?(name, 0) and
        not Macro.special_form?(name, 1) and
        not Macro.special_form?(name, 2) and
        not Macro.operator?(name, 1) and
        not Macro.operator?(name, 2) and
        name not in [
          :%{},
          :%,
          :{},
          :__aliases__,
          :sigil_w,
          :sigil_W,
          :sigil_s,
          :sigil_S,
          :sigil_c,
          :sigil_C,
          :<<>>,
          :"::"
        ]

  defp longest_common_prefix([]), do: []
  defp longest_common_prefix([single]), do: single

  defp longest_common_prefix(lists) do
    lists
    |> Enum.zip()
    |> Enum.take_while(fn tuple ->
      elements = Tuple.to_list(tuple)
      elements |> Enum.all?(&(&1 == hd(elements)))
    end)
    |> Enum.map(
      &elem(
        &1,
        0
      )
    )
  end

  defp merge_imports(a, b) do
    (a ++ b) |> Enum.uniq_by(fn {key, _} -> key end)
  end

  defp merge_source_maps(a, b) do
    Map.merge(a, b, fn _key, set_a, set_b -> MapSet.union(set_a, set_b) end)
  end

  defp merge_specs(merged_specs, updates) do
    updates
    |> Enum.reduce(merged_specs, fn {target, new_spec}, acc ->
      Map.update(acc, target, new_spec, fn existing ->
        %{
          aliases: Map.merge(existing.aliases, new_spec.aliases),
          attributes: Map.merge(new_spec.attributes, existing.attributes),
          functions: existing.functions ++ new_spec.functions,
          helper_sources: merge_source_maps(existing.helper_sources, new_spec.helper_sources),
          helpers: existing.helpers ++ new_spec.helpers,
          imports: merge_imports(existing.imports, new_spec.imports)
        }
      end)
    end)
  end

  defp module_patches(nil, _body_exprs), do: []

  defp module_patches(entries, body_exprs) do
    normalized_entries = entries |> Enum.map(&normalize_entry/1)

    # Drop entries whose target clause has already been rewritten
    # by an earlier refactor pass (body hash no longer matches the
    # plan). Without this filter we'd collide with e.g.
    # `ExtractParametricClone`, which can convert the very same
    # `defp` we'd migrate into a pass-through wrapper — re-applying
    # our plan would delete the wrapper and leave non-clone callers
    # dangling.
    live_entries = normalized_entries |> Enum.filter(&entry_still_applicable?(body_exprs, &1))

    rewrite_patches =
      live_entries
      |> Enum.flat_map(&patch_for_function(body_exprs, &1))

    # Group defp-entries by target module to render `import Target,
    # only: [...]` once per target. We append the import as a new
    # AST node by rendering it before the first remaining `def`-ish
    # node — but the simplest patch shape here is to splice it in
    # at the position of the first replaced clause. We do that by
    # prefixing `import ...\n` to the first defp's replacement.
    import_patches = build_import_patches(body_exprs, live_entries)

    cleanup_patches = dead_helper_patches(body_exprs, live_entries)

    rewrite_patches ++ import_patches ++ cleanup_patches
  end

  defp name_arity_or_sentinel({name, _, args}) when is_list(args) do
    {name, length(args)}
  end

  defp name_arity_or_sentinel({name, _, nil}), do: {name, 0}
  defp name_arity_or_sentinel(_), do: {nil, -1}

  defp node_count(ast) do
    {_, count} = Macro.prewalk(ast, 0, fn node, acc -> {node, acc + 1} end)
    count
  end

  defp normalize_clause({kind, _, [head, body_kw]}) when kind in [:def, :defp] do
    stripped_head = strip_meta(head)
    stripped_body = body_kw |> Keyword.values() |> Enum.map(&strip_meta/1)
    rename_vars({stripped_head, stripped_body})
  end

  defp normalize_entry(%{kind: _} = m), do: m

  defp normalize_entry({name, arity, args, target}),
    do: %{all_plain: true, args: args, arity: arity, kind: :def, name: name, target: target}

  defp only_list_to_pairs(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      {name, arity} when is_atom(name) and is_integer(arity) ->
        [{name, arity}]

      {key, value} ->
        with name when is_atom(name) <- unblock_atom(key),
             arity when is_integer(arity) <- unblock_integer(value) do
          [{name, arity}]
        else
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp only_list_to_pairs(_), do: []

  defp parse_inputs_from_config({:ok, contents}) do
    {config, _} = Code.eval_string(contents)
    inputs = Keyword.get(config, :inputs, [])

    inputs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&excluded_path?/1)
    |> Enum.map(fn p -> {p, File.read!(p)} end)
  end

  defp parse_inputs_from_config(_), do: []

  defp patch_for_function(body_exprs, entry) do
    clauses = body_exprs |> Enum.filter(&clause_matches?(&1, entry.name, entry.arity))

    cond do
      clauses == [] ->
        []

      # The plan was built off the original source. By the time this
      # patch runs, an earlier refactor (e.g. `ExtractParametricClone`)
      # may have rewritten the very same `def`/`defp` into a
      # pass-through wrapper — its body no longer matches the original
      # clone hash. Re-applying the loser replacement would either
      # delete the wrapper (for `defp`, leaving callers with an
      # undefined-function error) or overwrite it with a new one. Skip
      # instead.
      Map.get(entry, :hash) && hash_clauses(clauses) != entry.hash ->
        []

      true ->
        first = hd(clauses)
        last = List.last(clauses)
        replacement = render_loser_replacement(entry)
        build_clause_group_patch(first, last, replacement)
    end
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp patches_for_module(module, body_exprs, plan),
    do: Map.get(plan, module) |> module_patches(body_exprs)

  defp patches_for_target_or_empty(:skip, _arity, _entries, _name, _write_root), do: {[], %{}}

  defp patches_for_target_or_empty({:ok, target_module}, arity, entries, name, write_root) do
    case entries |> Enum.find(&(&1.module == target_module)) do
      nil ->
        check_and_emit(entries, name, arity, target_module, write_root)

      _existing ->
        {[], %{}}
    end
  end

  defp plain_var?({:\\, _, _}), do: false

  defp plain_var?({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    not underscore?(name)
  end

  defp plain_var?(_), do: false

  defp plain_var_clause?({_kind, _, [head | _]}) do
    case strip_when(head) do
      ^head -> args_are_plain_vars?(head)
      _ -> false
    end
  end

  defp plan_for_group({_key, [_only]}, _write_root), do: {[], %{}}

  defp plan_for_group({{name, arity, _hash}, entries}, write_root),
    do: decide_target(entries) |> patches_for_target_or_empty(arity, entries, name, write_root)

  defp plan_from_sources([], _opts), do: :no_cache
  defp plan_from_sources(sources, opts), do: {:ok, build_plan(sources, opts)}

  defp prepared_for_paths(nil, opts),
    do: load_default_sources() |> plan_from_sources(opts)

  defp prepared_for_paths(paths, opts) when is_list(paths) do
    sources = paths |> Enum.map(fn p -> {p, File.read!(p)} end)
    {:ok, build_plan(sources, opts)}
  end

  defp promote_to_def({:defp, meta, args}), do: {:def, meta, args}
  defp promote_to_def(other), do: other

  defp qualify_aliases(ast, aliases) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, [single]} = node when is_atom(single) ->
        case Map.get(aliases, single) do
          nil ->
            node

          full ->
            full_parts = Module.split(full) |> Enum.map(&String.to_atom/1)
            {:__aliases__, meta, full_parts}
        end

      other ->
        other
    end)
  end

  defp reachable_helper_clauses(body_exprs, target_name, target_arity) do
    definitions = collect_definitions(body_exprs)

    target_calls =
      definitions
      |> Enum.find(fn d ->
        d.kind == :def and d.name == target_name and d.arity == target_arity
      end)
      |> case do
        nil -> MapSet.new()
        d -> d.calls
      end

    call_graph =
      for d <- definitions do
        {{d.name, d.arity}, d.calls}
      end
      |> Map.new()

    reachable_from_target = transitive_closure(target_calls, call_graph)

    # A defp is "owned" by the target if it's reachable from the
    # target AND not reachable from any *other* def. That second check
    # is what makes the helper safe to migrate.
    other_defs =
      definitions
      |> Enum.filter(fn d ->
        d.kind == :def and not (d.name == target_name and d.arity == target_arity)
      end)
      |> Enum.map(&{&1.name, &1.arity})
      |> MapSet.new()

    reachable_from_others = transitive_closure(other_defs, call_graph)

    definitions
    |> Enum.filter(fn d ->
      d.kind == :defp and
        MapSet.member?(reachable_from_target, {d.name, d.arity}) and
        not MapSet.member?(reachable_from_others, {d.name, d.arity})
    end)
    |> Enum.flat_map(& &1.clauses)
  end

  defp read_existing_shared(path, target_module) do
    with true <- File.exists?(path),
         {:ok, source} <- File.read(path),
         {:ok, ast} <- Sourceror.parse_string(source),
         {:ok, body_exprs} <- find_target_module_body(ast, target_module) do
      %{
        attribute_names: existing_attribute_names(body_exprs),
        function_keys: existing_function_keys(body_exprs),
        import_keys: existing_import_keys(body_exprs),
        private_function_keys: existing_private_function_keys(body_exprs),
        source: source
      }
    else
      _ -> nil
    end
  end

  defp rename_var_node({name, [], ctx} = node, acc)
       when is_atom(name) and is_atom(ctx) do
    cond do
      underscore?(name) ->
        {node, acc}

      Map.has_key?(acc, name) ->
        {{:"$var", [], [Map.fetch!(acc, name)]}, acc}

      true ->
        idx = map_size(acc)
        {{:"$var", [], [idx]}, Map.put(acc, name, idx)}
    end
  end

  defp rename_var_node(node, acc), do: {node, acc}

  defp rename_vars(ast) do
    {result, _} = Macro.prewalk(ast, %{}, &rename_var_node/2)
    result
  end

  defp render_appended_module(source, spec) do
    aliases = spec.aliases

    function_keys =
      spec.functions |> Enum.map(fn e -> {e.name, e.arity} end) |> MapSet.new()

    deduped_helpers =
      spec.helpers
      |> Enum.reject(&MapSet.member?(function_keys, clause_name_arity(&1)))
      |> Enum.uniq_by(&strip_meta/1)

    rendered_functions = render_functions_with_sources(spec.functions, aliases)

    rendered_helpers =
      render_helpers_with_sources(deduped_helpers, spec.helper_sources, aliases)

    addition =
      [
        render_attributes(spec.attributes),
        render_imports(spec.imports),
        rendered_helpers,
        rendered_functions
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    if addition == "" do
      :unchanged
    else
      {:ok, splice_before_module_end(source, addition)}
    end
  end

  defp render_attributes(map) when map == %{}, do: ""

  defp render_attributes(map) do
    map
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map_join("\n", fn {name, value_ast} ->
      "@#{name} #{Sourceror.to_string(value_ast)}"
    end)
  end

  defp render_clause({_kind, _, _} = clause, aliases) do
    expanded = qualify_aliases(clause, aliases)
    Sourceror.to_string(expanded)
  end

  defp render_fresh_module(target_module, spec) do
    aliases = spec.aliases

    function_keys =
      spec.functions
      |> Enum.map(fn e -> {e.name, e.arity} end)
      |> MapSet.new()

    # Helpers can be duplicated across clone groups (multiple cloned
    # functions transitively pulled the same helper) and can collide
    # with a function that's also a clone (e.g. `maybe_update_oz/2` is
    # both used by `recalculate_all_oz_fragments` AND cloned in its
    # own right). The function version wins — drop helpers whose
    # `{name, arity}` matches any function. After that, dedupe at the
    # clause level (strip meta, take the first) so we keep all clauses
    # of multi-clause helpers without re-rendering them per clone-group.
    deduped_helpers =
      spec.helpers
      |> Enum.reject(fn clause ->
        {n, a} = clause_name_arity(clause)
        MapSet.member?(function_keys, {n, a})
      end)
      |> Enum.uniq_by(&strip_meta/1)

    rendered_functions = render_functions_with_sources(spec.functions, aliases)

    rendered_helpers =
      render_helpers_with_sources(deduped_helpers, spec.helper_sources, aliases)

    body =
      [
        render_attributes(spec.attributes),
        render_imports(spec.imports),
        rendered_helpers,
        rendered_functions
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    """
    defmodule #{inspect(target_module)} do
    #{indent(body, "  ")}
    end
    """
  end

  defp render_functions_with_sources(functions, aliases) do
    functions
    |> Enum.map_join("\n\n", fn fn_entry ->
      header = render_origin_comment(Map.get(fn_entry, :sources, MapSet.new()))

      body =
        render_shared_function(%{
          aliases: aliases,
          clauses: fn_entry.clauses,
          kind: fn_entry.kind
        })

      [header, body] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
    end)
  end

  defp render_helpers_with_sources([], _sources, _aliases), do: ""

  defp render_helpers_with_sources(helper_clauses, helper_sources, aliases) do
    helper_clauses
    |> Enum.group_by(&clause_name_arity/1)
    |> Enum.map_join("\n\n", fn {key, clauses} ->
      header = render_origin_comment(Map.get(helper_sources, key, MapSet.new()))

      body =
        clauses |> Enum.map_join("\n\n", &render_clause(&1, aliases))

      [header, body] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
    end)
  end

  defp render_imports([]), do: ""

  defp render_imports(imports) do
    imports |> Enum.map_join("\n", fn {_key, ast} -> Sourceror.to_string(ast) end)
  end

  defp render_loser_replacement(%{kind: :defp}), do: ""

  defp render_loser_replacement(%{
         all_plain: true,
         args: args,
         kind: :def,
         name: name,
         target: t
       }),
       do: "defdelegate #{name}(#{args |> Enum.join(", ")}), to: #{inspect(t)}"

  defp render_loser_replacement(%{args: args, kind: :def, name: name, target: t}) do
    arg_list = args |> Enum.join(", ")
    "def #{name}(#{arg_list}), do: #{inspect(t)}.#{name}(#{arg_list})"
  end

  defp render_origin_comment(sources) do
    list = sources |> Enum.map(&inspect/1) |> Enum.sort()

    case list do
      [] -> ""
      _ -> "# extracted from: " <> Enum.join(list, ", ")
    end
  end

  defp render_shared_function(%{aliases: aliases, clauses: clauses, kind: kind}) do
    # The shared module is the "owner" — if the source was private, we
    # promote it to a public `def` here so consumers can `import` the
    # function. The original modules will get an `import Shared, only:
    # [name: arity]` to compensate.
    promoted = if kind == :defp, do: clauses |> Enum.map(&promote_to_def/1), else: clauses

    promoted
    |> Enum.map_join("\n\n", &render_clause(&1, aliases))
    |> String.trim()
  end

  defp resolve_attrs_for_migration(clauses, helper_clauses, module_attrs) do
    attrs_used = collect_attrs_used(clauses, helper_clauses)

    if attrs_used |> Enum.all?(&attr_migratable?(&1, module_attrs)) do
      attrs =
        attrs_used
        |> Enum.map(fn name -> {name, Map.fetch!(module_attrs, name)} end)
        |> Map.new()

      {:ok, attrs}
    else
      :skip
    end
  end

  defp rewrite(source, plan),
    do: Sourceror.parse_string(source) |> apply_plan_to_parse_result(plan, source)

  defp rewrite_with_plan_or_passthrough(nil, source), do: source
  defp rewrite_with_plan_or_passthrough(plan, source), do: source |> rewrite(plan)
  defp shared_module?(module), do: module |> Module.split() |> List.last() == "Shared"

  defp splice_before_module_end(source, addition) do
    lines = String.split(source, "\n")
    {prefix, suffix} = split_at_last_end(lines)

    indented = indent(addition, "  ")

    (prefix ++ ["", indented] ++ suffix)
    |> Enum.join("\n")
  end

  defp split_at_last_end(lines) do
    idx =
      lines
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {line, i} ->
        if String.trim(line) == "end", do: i, else: nil
      end)

    case idx do
      nil -> {lines, []}
      i -> {lines |> Enum.take(i), lines |> Enum.drop(i)}
    end
  end

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other
  defp total_mass(clauses), do: clauses |> Enum.map(&clause_mass/1) |> Enum.sum()
  defp unblock_atom({:__block__, _, [a]}) when is_atom(a), do: a
  defp unblock_atom(a) when is_atom(a), do: a
  defp unblock_atom(_), do: nil
  defp unblock_integer({:__block__, _, [n]}) when is_integer(n), do: n
  defp unblock_integer(n) when is_integer(n), do: n
  defp unblock_integer(_), do: nil
  defp unblock_list({:__block__, _, [list]}) when is_list(list), do: list
  defp unblock_list(list) when is_list(list), do: list
  defp unblock_list(_), do: []
  defp unwrap_keyword([{k, v} | rest]), do: [{k, v} | rest]
  defp unwrap_keyword(other), do: other

  defp value_literal?(ast) do
    {_, ok?} =
      Macro.prewalk(ast, true, fn
        # Hard stop: any function call (local, remote, or capture)
        # makes the value compile-time-evaluated and unsafe.
        {{:., _, _}, _, _}, _acc ->
          {nil, false}

        {:&, _, _}, _acc ->
          {nil, false}

        # Local function call: `{name, _, args}` with args being a
        # list and `name` being a non-special-form atom.
        {name, _, args} = node, acc
        when is_atom(name) and is_list(args) and acc ->
          if local_call_in_value?(name) do
            {nil, false}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    ok?
  end

  defp write_shared_module(target_module, spec, write_root, source_paths) do
    path = shared_module_path(target_module, write_root, source_paths)
    File.mkdir_p!(Path.dirname(path))

    # Source modules can already `import target_module` from a prior
    # refactor pass (e.g. `ExtractParametricClone` extracted a helper
    # there). Carrying that import into the target module would be a
    # self-import and refuse to compile.
    spec = spec |> drop_self_imports(target_module)

    existing = read_existing_shared(path, target_module)
    filtered = filter_against_existing(spec, existing)

    case existing do
      nil ->
        File.write!(path, render_fresh_module(target_module, filtered))

      %{source: source} ->
        case render_appended_module(source, filtered) do
          :unchanged -> :ok
          {:ok, new_source} -> File.write!(path, new_source)
        end
    end
  end
end
