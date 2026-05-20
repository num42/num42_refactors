defmodule Num42.Refactors.Refactors.ExtractParametricClone do
  @moduledoc """
  Type-II clone extractor: same AST skeleton, differing only in literal
  values, gets parametrised into a single helper that takes the
  divergent values as extra arguments.

      # before
      defmodule MyApp.Time do
        def format_until(t), do: "until " <> Calendar.strftime(t, "%H:%M")
        def format_ago(t),   do: "ago "   <> Calendar.strftime(t, "%H:%M")
      end

      # after
      defmodule MyApp.Time do
        def format_until(t), do: format_shared(t, "until ")
        def format_ago(t),   do: format_shared(t, "ago ")

        defp format_shared(t, prefix), do: prefix <> Calendar.strftime(t, "%H:%M")
      end

  ## Source-of-truth selection

  Unlike `ExtractSharedModule` (always `{LCP}.Shared`), this refactor
  picks the host module by a three-step rule:

  1. **Intra-file concentration**: a single file with ≥ 2 clone
     occurrences hosts the helper. Tie on count → longest module
     chain. Tie on chain length → alphabetically first.
  2. **Suffix-based selection** for distributed (1+1+1) clones: a
     module ending in `.Formatter` / `.Helper` / `.Helpers` /
     `.Shared` is preferred (in that order; ties → alphabetical).
  3. **Fallback**: `{LCP}.Shared` like `ExtractSharedModule`.

  The first iteration only emits plans for the **intra** case;
  suffix and LCP-shared targets are computed but not yet rewritten.
  """

  use Num42.Refactors.Refactor

  alias Num42.Refactors.AstDiff
  alias Num42.Refactors.AstHelpers

  @default_min_mass 25

  @suffix_priority [:Format, :Formatter, :Helper, :Helpers, :Shared]

  @excluded_path_prefixes ["test/", "dev/"]

  # Macros whose body uses a binding-introducing form `bind in Schema`
  # plus a compile-time keyword-list of clauses. Parametrising any
  # position inside such a call produces an AST that the formatter or
  # the macro itself reject. Treat their presence in a clone body as
  # "skip this clause".
  @binding_macros [:from]

  @impl Num42.Refactors.Refactor
  def description, do: "Type-II clone extraction: parametrise differing literals into a helper"

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    Find functions whose AST skeleton matches but whose concrete
    literal values differ; replace each clone with a call to a single
    helper that takes the differing values as extra arguments. Picks
    the helper's host module by intra-file concentration first, then
    by `.Formatter`/`.Helper`/`.Shared` suffix, then by `{LCP}.Shared`
    fallback.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Num42.Refactors.Refactor
  def priority, do: 110

  @impl Num42.Refactors.Refactor
  def prepare(opts), do: Keyword.get(opts, :source_files) |> handle_prepare_get(opts)

  @impl Num42.Refactors.Refactor
  def transform(source, opts), do: Keyword.get(opts, :prepared) |> handle_transform_get(source)

  # ---------------------------------------------------------------------
  # Plan building
  # ---------------------------------------------------------------------

  @doc """
  Build a rewrite plan from `[{path, source_string}]` tuples.

  Plan shape: `%{module => {[helper_def], [rewrite], [import_spec]}}`
  where:

  - `helper_def` is `%{kind, name, args, body_ast}` describing the
    helper to inject (one per clone group landing in this module)
  - each `rewrite` is `%{name, arity, args, kind, replacement}`
    describing one clone instance to rewrite to a one-line wrapper
  - each `import_spec` is `{target_module, [{helper_name, arity}]}`
    describing a `import Target, only: [...]` to add at the top of
    the module body. Only used by cross-file emission (`:suffix` /
    `:lcp_shared`); intra-module emission leaves this list empty.

  Keyed by module (not path) so `transform/2` can look up plan
  entries by the `defmodule` it walks into, the same way
  `ExtractSharedModule` does.

  When multiple clone groups land in the same module, helper names
  are uniqued with `_2`, `_3`, ... suffixes during plan emission.

  ## Cross-file emission side-effect

  For `:suffix` / `:lcp_shared` source-of-truth classes the helper
  body must live in *another* file. Like `ExtractSharedModule`,
  build_plan writes those files itself; `:write_root` defaults to
  `File.cwd!/0`. Pass `dry_run: true` (the engine forwards this from
  `mix refactor --dry-run`) to skip every disk write while still
  returning a fully populated plan.
  """
  @spec build_plan([{String.t(), String.t()}], keyword()) :: %{
          module() => {[map()], [map()], [{module(), [{atom(), arity()}]}]}
        }
  def build_plan(sources, opts \\ []) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)
    write_root = Keyword.get(opts, :write_root, File.cwd!())
    dry_run? = Keyword.get(opts, :dry_run, false)

    # Excluded paths (test/, dev/) are never valid extraction sources,
    # regardless of how they got here. The default-loader filter alone
    # doesn't help when the CLI passes explicit paths — those flow
    # straight to build_plan/2 and would otherwise produce Shared
    # modules in lib/ from dev/ sources via the module-name → path
    # convention.
    sources = sources |> Enum.reject(fn {path, _src} -> excluded_path?(path) end)

    entries =
      sources
      |> Enum.flat_map(&extract_module_info(&1, min_mass))

    # Per-module name registry: a clone group emitting a helper into a
    # module reserves its name; the next group that wants the same
    # name picks `_2`, `_3`, ... .
    #
    # `cross_writes` accumulates one entry per cross-file helper that
    # needs to land somewhere outside the clone-bearing modules. It's
    # processed once at the end so two clone groups landing in the
    # same target module share a single fresh-write / append step.
    {plan_entries, _state} =
      entries
      |> Enum.group_by(fn e -> {e.arity, e.skeleton_hash} end)
      |> Enum.flat_map_reduce(%{used: %{}, write_root: write_root}, fn {_key, group}, state ->
        plan_for_group(group, state)
      end)

    unless dry_run? do
      _state = process_cross_writes(plan_entries, write_root)
    end

    assemble_plan(plan_entries)
  end

  defp assemble_plan(plan_entries) do
    # plan_entries is a list of {module, kind} tuples where
    # kind is either {:helper, helper_def}, {:rewrite, rewrite}, or
    # {:import, {target_module, [{name, arity}]}}.
    plan_entries
    |> Enum.group_by(fn {mod, _} -> mod end)
    |> Map.new(fn {mod, mod_entries} ->
      helpers =
        mod_entries
        |> Enum.flat_map(fn
          {_m, {:helper, h}} -> [h]
          _ -> []
        end)

      rewrites =
        mod_entries
        |> Enum.flat_map(fn
          {_m, {:rewrite, r}} -> [r]
          _ -> []
        end)

      imports =
        mod_entries
        |> Enum.flat_map(fn
          {_m, {:import, spec}} -> [spec]
          _ -> []
        end)
        |> merge_import_specs()

      {mod, {helpers, rewrites, imports}}
    end)
  end

  # Multiple clone groups can request `import Target, ...` from the
  # same caller module. Merge them into one entry per target with a
  # combined, sorted, uniqued `only:` list.
  defp merge_import_specs(imported_specs) do
    imported_specs
    |> Enum.group_by(fn {target, _} -> target end, fn {_, only} -> only end)
    |> Enum.map(fn {target, only_lists} ->
      {target, only_lists |> List.flatten() |> Enum.uniq() |> Enum.sort()}
    end)
  end

  # Cross-file emission writes one helper file per target module,
  # *appending* to existing files (suffix branch where the target
  # already has its own functions) or creating a fresh file (LCP-Shared
  # branch where the target is a synthesised module that didn't exist
  # yet). Two clone groups landing in the same target merge their
  # helpers into a single write.
  defp process_cross_writes(plan_entries, write_root) do
    cross_helpers =
      plan_entries
      |> Enum.flat_map(fn
        {mod, {:cross_helper, info}} -> [{mod, info}]
        _ -> []
      end)
      |> Enum.group_by(fn {mod, _} -> mod end, fn {_, info} -> info end)

    cross_helpers
    |> Enum.each(fn {target, infos} ->
      write_cross_helper_file(target, infos, write_root)
    end)
  end

  defp write_cross_helper_file(target, infos, write_root) do
    path = shared_module_path(target, write_root)
    File.mkdir_p!(Path.dirname(path))

    # Drop helpers that are already in the target file (idempotence).
    existing_keys = read_existing_function_keys(path, target)

    fresh_infos =
      infos
      |> Enum.reject(&MapSet.member?(existing_keys, {&1.helper_def.name, &1.helper_def.arity}))

    case fresh_infos do
      [] ->
        :ok

      list ->
        if File.exists?(path) do
          src = File.read!(path)
          new_src = append_helpers_to_module_source(src, list)
          File.write!(path, new_src)
        else
          File.write!(path, render_fresh_helper_module(target, list))
        end
    end
  end

  defp read_existing_function_keys(path, target_module) do
    with true <- File.exists?(path),
         {:ok, source} <- File.read(path),
         {:ok, ast} <- Sourceror.parse_string(source),
         {:ok, body_exprs} <- find_module_body(ast, target_module) do
      body_exprs
      |> Enum.flat_map(fn
        {kind, _, [head | _]} when kind in [:def, :defp] ->
          case extract_fn_signature(head) do
            {name, args} when is_list(args) -> [{name, length(args)}]
            _ -> []
          end

        _ ->
          []
      end)
      |> MapSet.new()
    else
      _ -> MapSet.new()
    end
  end

  defp find_module_body(ast, target_module) do
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

  # Helpers landing in the target are always promoted to public `def`
  # so the importing modules (the original clone sites) can call them.
  # Migrated `defp` helpers stay private inside the target module.
  # Module attributes and imports are merged across all infos, deduped.
  defp render_fresh_helper_module(target, infos) do
    body = render_target_body(infos)
    indented = indent_lines(body, "  ")

    """
    defmodule #{inspect(target)} do
    #{indented}
    end
    """
  end

  defp append_helpers_to_module_source(source, infos) do
    body = render_target_body_for_append(source, infos)

    case body do
      "" ->
        source

      addition ->
        indented = indent_lines(addition, "  ")
        splice_before_module_end(source, indented)
    end
  end

  defp render_target_body(infos) do
    merged_attr = merge_attrs(infos)
    migrated_helpers = merge_migrated_helpers(infos)
    helper_defs = infos |> Enum.map(& &1.helper_def)

    body_calls = body_unqualified_calls(migrated_helpers, helper_defs)

    imports =
      infos
      |> merge_imports()
      |> prune_unused_imports(body_calls)

    [
      render_attributes(merged_attr),
      render_imports(imports),
      render_migrated_helpers(migrated_helpers),
      render_helper_defs(helper_defs)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # When appending to an existing target file, drop everything that's
  # already present so we don't double-write. Attribute names already
  # declared, import statements already present, helper functions
  # already defined.
  defp render_target_body_for_append(source, infos),
    do: Sourceror.parse_string(source) |> handle_parse_string(infos)

  defp scan_existing_target_body(ast) do
    body_exprs =
      ast
      |> Macro.prewalker()
      |> Enum.find_value(fn
        {:defmodule, _, [_, [{_do, body}]]} -> {:ok, body_to_exprs(body)}
        _ -> nil
      end)
      |> case do
        {:ok, list} -> list
        _ -> []
      end

    function_keys =
      body_exprs
      |> Enum.flat_map(fn
        {kind, _, [head | _]} when kind in [:def, :defp] ->
          case extract_fn_signature(head) do
            {name, args} when is_list(args) -> [{name, length(args)}]
            _ -> []
          end

        _ ->
          []
      end)
      |> MapSet.new()

    attribute_names =
      body_exprs
      |> Enum.flat_map(fn
        {:@, _, [{name, _, [_value]}]} when is_atom(name) -> [name]
        _ -> []
      end)
      |> MapSet.new()

    import_keys =
      body_exprs
      |> Enum.flat_map(fn
        {:import, _, _} = node -> [canonical_import_key(node)]
        _ -> []
      end)
      |> MapSet.new()

    %{
      attribute_names: attribute_names,
      function_keys: function_keys,
      import_keys: import_keys
    }
  end

  defp merge_attrs(infos) do
    infos
    |> Enum.flat_map(&Map.to_list(&1.attrs))
    # Later entries don't overwrite earlier ones; we already verified
    # attrs match across clone modules at emit-time.
    |> Enum.uniq_by(fn {name, _} -> name end)
    |> Map.new()
  end

  defp merge_imports(infos) do
    infos
    |> Enum.flat_map(& &1.imports)
    |> Enum.uniq_by(fn {k, _} -> k end)
    |> Enum.sort_by(fn {k, _} -> k end)
  end

  # Collect every unqualified call (`foo(...)` rather than `Mod.foo(...)`)
  # appearing in the bodies that are about to live in the Shared module.
  # We walk both the migrated `defp` clauses (verbatim helpers from the
  # clone modules) and the freshly synthesised `def *_shared` helper
  # bodies. Names captured here drive `prune_unused_imports/2`: an
  # `import …, only: [name: arity]` whose name we never call is dropped.
  defp body_unqualified_calls(migrated_helpers, helper_defs) do
    helper_calls =
      helper_defs
      |> Enum.reduce(MapSet.new(), fn %{args: args, body_ast: body}, acc ->
        bound = MapSet.new(args)

        body
        |> unqualified_calls_in_ast()
        |> Enum.reject(fn {name, _arity} -> MapSet.member?(bound, name) end)
        |> Enum.into(acc)
      end)

    migrated_helpers
    |> Enum.reduce(helper_calls, fn clause, acc ->
      clause
      |> unqualified_calls_in_ast()
      |> Enum.into(acc)
    end)
  end

  defp unqualified_calls_in_ast(ast) do
    {_, calls} =
      Macro.prewalk(ast, MapSet.new(), fn
        # `Foo.bar(...)` — qualified, not interesting.
        {{:., _, _}, _, _} = node, acc ->
          {node, acc}

        # Unqualified call like `foo(arg, ...)`. The args are also walked
        # by prewalk on their own.
        {name, _meta, args} = node, acc
        when is_atom(name) and is_list(args) and name not in [:., :__aliases__] ->
          if import_call_candidate?(name) do
            {node, MapSet.put(acc, {name, length(args)})}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    calls
  end

  # Conservative whitelist of forms that look like unqualified calls but
  # are syntactic sugar / Kernel constructs we never want to credit to
  # an import. Keeps the pruner from being misled by `case`/`if`/`do`
  # AST nodes whose head atom is also a valid function name.
  defp import_call_candidate?(name),
    do:
      name not in [
        :__block__,
        :->,
        :|>,
        :=,
        :"::",
        :when,
        :case,
        :cond,
        :if,
        :unless,
        :for,
        :with,
        :try,
        :receive,
        :fn,
        :do,
        :%{},
        :%,
        :{},
        :<<>>,
        :&,
        :@
      ] and
        not Macro.special_form?(name, 1) and
        not Macro.special_form?(name, 2) and
        not Macro.special_form?(name, 3) and
        not (function_exported?(Kernel, name, 1) or function_exported?(Kernel, name, 2) or
               function_exported?(Kernel, name, 3) or function_exported?(Kernel, name, 4))

  # Drop `import Mod, only: [...]` entries whose names are never called
  # in the rendered Shared body, and `import Mod` (full) entries that
  # have no plausible caller either. Keeps any import the body actually
  # depends on intact.
  defp prune_unused_imports(imports, body_calls) do
    call_names = MapSet.new(body_calls, fn {name, _arity} -> name end)

    imports
    |> Enum.flat_map(fn {key, ast} ->
      case import_only_pairs(ast) do
        :no_only ->
          # Full `import Mod` — keep only when at least one
          # unqualified call in the body could plausibly resolve
          # through it. Without function-export metadata we can't
          # know for sure, so we err on the conservative side: drop
          # only when the body has no unqualified calls at all,
          # otherwise keep.
          if MapSet.size(call_names) == 0 do
            []
          else
            [{key, ast}]
          end

        {:ok, pairs} ->
          used_pairs = pairs |> Enum.filter(fn {n, _a} -> MapSet.member?(call_names, n) end)

          cond do
            used_pairs == [] -> []
            used_pairs == pairs -> [{key, ast}]
            true -> [{key, rebuild_only_import(ast, used_pairs)}]
          end
      end
    end)
  end

  defp import_only_pairs({:import, _, [_aliases]}), do: :no_only

  defp import_only_pairs({:import, _, [_aliases, opts]}) do
    opts
    |> Enum.find_value(:no_only, fn
      {key, value} ->
        if unblock_atom_for_import(key) == :only do
          {:ok, only_list_pairs(unblock_list_for_import(value))}
        end

      _ ->
        nil
    end)
  end

  defp import_only_pairs(_), do: :no_only

  defp only_list_pairs(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      {name, arity} when is_atom(name) and is_integer(arity) ->
        [{name, arity}]

      {key, value} ->
        with name when is_atom(name) <- unblock_atom_for_import(key),
             arity when is_integer(arity) <- unblock_integer_for_import(value) do
          [{name, arity}]
        else
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp only_list_pairs(_), do: []

  defp unblock_atom_for_import({:__block__, _, [a]}) when is_atom(a), do: a
  defp unblock_atom_for_import(a) when is_atom(a), do: a
  defp unblock_atom_for_import(_), do: nil

  defp unblock_integer_for_import({:__block__, _, [n]}) when is_integer(n), do: n
  defp unblock_integer_for_import(n) when is_integer(n), do: n
  defp unblock_integer_for_import(_), do: nil

  defp unblock_list_for_import({:__block__, _, [list]}) when is_list(list), do: list
  defp unblock_list_for_import(list) when is_list(list), do: list
  defp unblock_list_for_import(_), do: []

  # Rebuild the import AST with a narrower `only:` list. We don't try to
  # preserve every meta detail — `Sourceror.to_string/1` will format it
  # readably enough.
  defp rebuild_only_import({:import, meta, [aliases, _opts]}, pairs) do
    only_kw =
      pairs
      |> Enum.map(fn {n, a} ->
        {{:__block__, [format: :keyword], [n]}, {:__block__, [token: Integer.to_string(a)], [a]}}
      end)

    new_opts = [{{:__block__, [format: :keyword], [:only]}, {:__block__, [], [only_kw]}}]
    {:import, meta, [aliases, new_opts]}
  end

  defp rebuild_only_import(other, _pairs), do: other

  defp merge_migrated_helpers(infos),
    do:
      infos
      |> Enum.flat_map(& &1.migrated_helpers)
      |> Enum.uniq_by(&strip_meta/1)

  defp render_attributes(map) when map == %{}, do: ""

  defp render_attributes(map) do
    map
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map_join("\n", fn {name, value_ast} ->
      "@#{name} #{value_ast |> strip_comments() |> Sourceror.to_string()}"
    end)
  end

  defp render_imports([]), do: ""

  defp render_imports(imports) do
    imports
    |> Enum.map_join("\n", fn {_key, ast} ->
      ast |> strip_comments() |> Sourceror.to_string()
    end)
  end

  defp render_migrated_helpers([]), do: ""

  defp render_migrated_helpers(clauses) do
    clauses
    |> Enum.map_join("\n\n", fn clause ->
      clause |> strip_comments() |> Sourceror.to_string()
    end)
  end

  defp render_helper_defs([]), do: ""

  defp render_helper_defs(helper_defs),
    do: helper_defs |> Enum.map_join("\n\n", &render_public_helper/1)

  # Insert `addition` just before the final `end` line in `source`.
  # Same idea as `ExtractSharedModule.splice_before_module_end/2`: work
  # on the raw source so existing comments/formatting are preserved.
  defp splice_before_module_end(source, addition) do
    lines = String.split(source, "\n")
    {prefix, suffix} = split_at_last_end(lines)

    (prefix ++ ["", addition] ++ suffix) |> Enum.join("\n")
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

  defp indent_lines(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end

  # Cross-file helpers are always public (callers from other modules
  # need to be able to import them). Forces `def` regardless of the
  # `helper_def`'s `:kind`.
  defp render_public_helper(%{args: args, body_ast: body_ast, name: name}) do
    arg_list = args |> Enum.join(", ")
    body_string = body_ast |> strip_comments() |> Sourceror.to_string()

    if String.contains?(body_string, "\n") do
      indented_body = indent_lines(body_string, "  ")
      "def #{name}(#{arg_list}) do\n#{indented_body}\nend"
    else
      "def #{name}(#{arg_list}), do: #{body_string}"
    end
  end

  # Convert a target module to its conventional file path under
  # `write_root`: `MyApp.Bar.Helper` → `<root>/lib/my_app/bar/helper.ex`.
  defp shared_module_path(target_module, write_root) do
    parts = Module.split(target_module)

    {root, rest} =
      case parts do
        [first | tail] -> {Macro.underscore(first), tail |> Enum.map(&Macro.underscore/1)}
        _ -> {"", []}
      end

    rel = Path.join(["lib", root | rest]) <> ".ex"
    Path.join(write_root, rel)
  end

  defp plan_for_group([_only], state), do: {[], state}

  defp plan_for_group(entries, state) when length(entries) >= 2 do
    indexed_entries =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {e, i} -> Map.put(e, :bucket_index, i) end)

    # Pre-process: rewrite every `lhs |> rhs(…)` as the equivalent
    # nested call `rhs(lhs, …)`. Two reasons:
    #   1. Pipes are sugar — two clones differing only in pipe vs.
    #      direct-call form should bucket together.
    #   2. When divergence sits at pipe-RHS, naive emission produces
    #      `param_0 |> param_1` (bare var on RHS) which the compiler
    #      rejects. Inlining pipes turns RHS holes into ordinary
    #      argument-position holes that render correctly as
    #      `helper(arg0, arg1, …)`.
    asts = indexed_entries |> Enum.map(&inline_pipes(&1.body_ast))

    %{holes: holes, skeleton: skeleton} = AstDiff.tree_diff(asts)

    cond do
      holes_land_on_map_keys?(skeleton, holes) ->
        # Map keys (and keyword-list keys) are nearly always semantically
        # load-bearing. Two helpers that only differ in their map keys
        # are not really clones — they construct different things.
        # Consolidating them produces a misleading helper name and
        # actively misleading parameter names (`%{name => …, logo_asset_id => …}`
        # called for a mass-asset).
        {[], state}

      true ->
        case pick_target(indexed_entries) do
          :skip ->
            {[], state}

          {:intra, target_module} ->
            emit_intra_plan(indexed_entries, target_module, skeleton, holes, state)

          {:suffix, target_module} ->
            emit_cross_file_plan(:suffix, indexed_entries, target_module, skeleton, holes, state)

          {:lcp_shared, target_module} ->
            emit_cross_file_plan(
              :lcp_shared,
              indexed_entries,
              target_module,
              skeleton,
              holes,
              state
            )
        end
    end
  end

  # A hole is considered "map-key" when its placeholder appears on the
  # left-hand side of any pair in:
  #
  #   * a map literal, `%{key => value}` — `{:%{}, _, [{key_ast, value_ast}, …]}`
  #   * a keyword-list literal — a bare list of `{key_ast, value_ast}` 2-tuples
  #     where the keys are atom-shaped (the `name: value` shorthand)
  #
  # Walks the skeleton, gathers every path that sits at a key position,
  # and returns true when any hole's path is in that set.
  defp holes_land_on_map_keys?(skeleton, holes) do
    key_paths = collect_map_key_paths(skeleton)

    holes |> Enum.any?(&MapSet.member?(key_paths, &1.path))
  end

  defp collect_map_key_paths(skeleton) do
    {_, paths} =
      Macro.prewalk(skeleton, MapSet.new(), fn
        {:%{}, _, pairs} = node, acc when is_list(pairs) ->
          {node, pairs |> Enum.reduce(acc, &collect_pair_key_path/2)}

        # Keyword-list literal at any position: `[{k, v}, …]` with all
        # keys atom-shaped. Sourceror-style atoms are wrapped in
        # `{:__block__, _, [:atom]}`.
        list, acc when is_list(list) ->
          if keyword_list_pairs?(list) do
            {list, list |> Enum.reduce(acc, &collect_pair_key_path/2)}
          else
            {list, acc}
          end

        node, acc ->
          {node, acc}
      end)

    paths
  end

  defp keyword_list_pairs?([]), do: false

  defp keyword_list_pairs?(list) do
    list
    |> Enum.all?(fn
      {key, _value} -> atom_shaped_key?(key)
      _ -> false
    end)
  end

  defp atom_shaped_key?({:__block__, _, [a]}) when is_atom(a), do: true
  defp atom_shaped_key?(a) when is_atom(a), do: true
  defp atom_shaped_key?({:"$hole", _, _}), do: true
  defp atom_shaped_key?(_), do: false

  defp collect_pair_key_path({key, _value}, acc) do
    case key do
      {:"$hole", _, [path]} -> MapSet.put(acc, path)
      _ -> acc
    end
  end

  defp collect_pair_key_path(_, acc), do: acc

  defp emit_intra_plan(entries, target_module, skeleton, holes, state) do
    # Only emit rewrites for clones in the *same* module as the helper.
    # Lonely cross-module clones in an :intra plan would need their own
    # import + cross-file emission, but if intra is the winning rule
    # there's already a high-concentration host — those lonely siblings
    # are best handled in a future pass.
    intra_entries = entries |> Enum.filter(&(&1.module == target_module))

    case intra_entries do
      [] ->
        {[], state}

      [first | _] ->
        base_name = synth_helper_name(entries)
        used = state.used
        already_used = Map.get(used, target_module, %{})

        {:ok, name_str} = resolve_collision(base_name, already_used)
        helper_name = String.to_atom(name_str)
        new_used = Map.put(used, target_module, Map.put(already_used, name_str, :reserved))

        # Classify holes into outer (real params, passed at call-site)
        # and inner (locally-bound vars, unified inside the helper body
        # to a canonical local name). May return :skip_group when an
        # outer hole references a clone-local variable.
        case classify_holes(skeleton, holes, intra_entries) do
          :skip_group ->
            {[], state}

          {outer_holes, local_groups, all_bound} ->
            emit_intra_plan_with_classification(
              intra_entries,
              target_module,
              skeleton,
              outer_holes,
              local_groups,
              all_bound,
              first,
              helper_name,
              new_used,
              state
            )
        end
    end
  end

  defp emit_intra_plan_with_classification(
         intra_entries,
         target_module,
         skeleton,
         outer_holes,
         local_groups,
         all_bound,
         first,
         helper_name,
         new_used,
         state
       ) do
    # Dedup: holes whose per-clone value vector is identical
    # collapse into one helper param (the same value is used at
    # every path).
    outer_groups = dedupe_outer_holes(outer_holes)

    # Original args that are still referenced inside the skeleton
    # (i.e. NOT entirely replaced by holes) must stay; the rest are
    # dead and would be emitted as unused params (e.g. when the only
    # divergence between two clones is the arg name itself).
    used_arg_names = arg_names_used_in_skeleton(skeleton, first.arg_names)

    param_names = pick_param_names(outer_groups, used_arg_names, all_bound)

    helper_args = used_arg_names ++ param_names

    helper_body =
      skeleton
      |> inflate_skeleton(outer_groups, helper_args)
      |> rename_local_holes(local_groups)

    helper_def = %{
      args: helper_args,
      arity: length(helper_args),
      body_ast: helper_body,
      kind: :defp,
      name: helper_name
    }

    if helper_renderable?(helper_body) do
      helper_entry = {target_module, {:helper, helper_def}}

      kept_arg_indices =
        first.arg_names
        |> Enum.with_index()
        |> Enum.filter(fn {n, _i} -> n in used_arg_names end)
        |> Enum.map(fn {_n, i} -> i end)

      rewrite_entries =
        intra_entries
        |> Enum.map(fn e ->
          outer_values =
            outer_groups |> Enum.map(fn g -> g.values |> Enum.at(e.bucket_index) end)

          kept_args = kept_arg_indices |> Enum.map(&Enum.at(e.arg_names, &1))
          replacement = render_call(helper_name, kept_args ++ outer_values)

          {e.module,
           {:rewrite,
            %{
              args: e.arg_names,
              arity: e.arity,
              kind: e.kind,
              name: e.name,
              replacement: replacement
            }}}
        end)

      {[helper_entry | rewrite_entries], %{state | used: new_used}}
    else
      # Render-unsafe: a hole landed at a position the Elixir
      # formatter rejects. Skip rather than emit code that crashes
      # the formatter.
      {[], state}
    end
  end

  # Split holes into:
  #   * outer holes — values exist in the caller scope; real helper
  #     params, passed at the call-site.
  #   * local groups — holes whose values across all clones are bare
  #     variables that *each clone's body* binds via a pattern
  #     (case/with/fn/comprehension/`=` patterns). Such a var only
  #     exists inside the helper body, never at the caller site —
  #     the helper sees them under a canonical `local_N` name. Holes
  #     with the same per-clone var-name tuple share a local — they
  #     refer to the same locally-bound variable across all clones.
  #
  # Per-clone classification (via each `body_ast`) is more accurate
  # than walking the skeleton because the skeleton has the relevant
  # vars *already replaced by hole placeholders* — they wouldn't be
  # spotted as binding sites there.
  defp classify_holes(_skeleton, holes, entries) do
    bound_per_entry =
      for e <- entries do
        {e.bucket_index, collect_bound_vars(e.body_ast)}
      end
      |> Map.new()

    {outer, inner} =
      holes
      |> Enum.split_with(&(not all_inner_bound?(&1.values, entries, bound_per_entry)))

    cond do
      outer_holes_use_inner_bound_vars?(outer, entries, bound_per_entry) ->
        :skip_group

      outer_holes_contain_captures?(outer) ->
        # `&N` capture refs (e.g. inside `& &1.field`) are valid only
        # within an enclosing `&(...)`. If a hole's value contains one,
        # extracting it as a helper param produces a bare `&1` at the
        # call-site or a bare param-var inside the capture — both are
        # syntax errors. Skip the group.
        :skip_group

      true ->
        # Gather every variable bound anywhere in any clone body. The
        # name picker must avoid these too, otherwise a chosen param
        # name would be shadowed by an inner pattern (e.g. param `slug`
        # vs case-pattern `slug -> …` rebinds the param to a string).
        all_bound =
          bound_per_entry
          |> Map.values()
          |> Enum.reduce(MapSet.new(), &MapSet.union/2)

        {outer_split, locals} = classify_holes_split(outer, inner, entries, bound_per_entry)
        {outer_split, locals, all_bound}
    end
  end

  defp outer_holes_contain_captures?(outer_holes) do
    outer_holes
    |> Enum.any?(fn hole ->
      hole.values |> Enum.any?(&ast_contains_capture_ref?/1)
    end)
  end

  defp ast_contains_capture_ref?(ast) do
    {_, hit?} =
      Macro.prewalk(ast, false, fn
        _node, true ->
          {:ignore, true}

        {:&, _, [n]} = node, false when is_integer(n) ->
          {node, true}

        node, false ->
          {node, false}
      end)

    hit?
  end

  # Outer-hole values may be complex AST (calls, dot-property, …). If
  # any of those references a variable that is only bound inside the
  # clone body (e.g. `Module.fn(local_var, …)` where `local_var` is the
  # LHS of a `=` further up the body), the hole cannot be outer — the
  # caller has no such var in scope. Skip the entire group rather than
  # emit code that fails to compile at the call site.
  defp outer_holes_use_inner_bound_vars?(outer_holes, entries, bound_per_entry) do
    outer_holes
    |> Enum.any?(fn hole ->
      hole.values
      |> Enum.zip(entries)
      |> Enum.any?(fn {value, e} ->
        bound = Map.fetch!(bound_per_entry, e.bucket_index)
        value_uses_any_var?(value, bound)
      end)
    end)
  end

  defp value_uses_any_var?(value, bound_set) do
    {_, hit?} =
      Macro.prewalk(value, false, fn
        _node, true ->
          {:ignore, true}

        {name, _meta, ctx} = node, false when is_atom(name) and is_atom(ctx) ->
          if MapSet.member?(bound_set, name), do: {node, true}, else: {node, false}

        node, false ->
          {node, false}
      end)

    hit?
  end

  defp classify_holes_split(outer, inner, entries, _bound_per_entry) do
    # Group inner holes by the per-clone var-name tuple (same tuple ⇒
    # same locally-bound variable across all clones). The local name
    # taken inside the helper is derived from the FIRST clone's bound
    # name, falling back to `local_N` only when that name would collide
    # with a helper arg or another local.
    local_groups =
      inner
      |> Enum.group_by(
        &for {value, e} <- Enum.zip(&1.values, entries) do
          {:ok, name} = bare_var(value)
          {e.bucket_index, name}
        end
      )
      |> Enum.with_index()
      |> Enum.map(fn {{key, group_holes}, idx} ->
        {pick_local_name(key, idx), group_holes}
      end)

    {outer, local_groups}
  end

  # Try to use the first clone's bound name; fall back to `local_N`
  # only when no usable name is found.
  defp pick_local_name(key, fallback_idx) do
    first_name =
      key
      |> Enum.sort_by(fn {bucket_index, _name} -> bucket_index end)
      |> List.first()
      |> elem(1)

    if is_atom(first_name) and first_name != :_ do
      first_name
    else
      :"local_#{fallback_idx}"
    end
  end

  # Pick names for outer-hole groups: try `name_from_value` on the
  # first clone's value; resolve collisions with existing arg names
  # by appending a numeric suffix; fall back to `param_N` if no name
  # can be derived.
  # Filter `arg_names` to those still referenced as a bare variable
  # somewhere in `skeleton` (i.e. not entirely replaced by `$hole`
  # placeholders). Preserves order. Used to drop dead arg-positions
  # from the helper signature when an arg only appears in divergent
  # positions across clones.
  defp arg_names_used_in_skeleton(skeleton, arg_names) do
    used =
      arg_names
      |> MapSet.new()
      |> filter_to_used_in_ast(skeleton)

    arg_names |> Enum.filter(&MapSet.member?(used, &1))
  end

  defp filter_to_used_in_ast(candidates, ast) do
    {_, found} =
      Macro.prewalk(ast, MapSet.new(), fn
        {name, _meta, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          if MapSet.member?(candidates, name),
            do: {node, MapSet.put(acc, name)},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp pick_param_names(groups, existing_arg_names, body_bound) do
    taken = existing_arg_names |> MapSet.new() |> MapSet.union(body_bound)

    {names, _taken} =
      groups
      |> Enum.with_index()
      |> Enum.map_reduce(taken, fn {group, idx}, taken_acc ->
        first_value = List.first(group.values)
        suggested = AstHelpers.name_from_value(first_value)

        chosen =
          case suggested do
            nil -> :"param_#{idx}"
            str -> resolve_name_collision(String.to_atom(str), taken_acc, idx)
          end

        {chosen, MapSet.put(taken_acc, chosen)}
      end)

    names
  end

  defp resolve_name_collision(name, taken, idx) do
    if MapSet.member?(taken, name) do
      2
      |> Stream.iterate(&(&1 + 1))
      |> Enum.find_value(fn n ->
        candidate = :"#{name}_#{n}"
        if MapSet.member?(taken, candidate), do: nil, else: candidate
      end) || :"param_#{idx}"
    else
      name
    end
  end

  defp all_inner_bound?(values, entries, bound_per_entry) do
    values
    |> Enum.zip(entries)
    |> Enum.all?(fn {v, e} ->
      case bare_var(v) do
        {:ok, name} ->
          MapSet.member?(Map.fetch!(bound_per_entry, e.bucket_index), name)

        :skip ->
          false
      end
    end)
  end

  # Replace `{:"$hole", _, [path]}` placeholders that belong to a local
  # group with the canonical local name (`{name, [], nil}` form).
  defp rename_local_holes(skeleton, local_groups) do
    path_to_local =
      for {local_name, holes} <- local_groups,
          h <- holes,
          into: %{} do
        {h.path, local_name}
      end

    Macro.prewalk(skeleton, fn
      {:"$hole", _, [path]} = node ->
        case Map.get(path_to_local, path) do
          nil -> node
          local_name -> {local_name, [], nil}
        end

      other ->
        other
    end)
  end

  # Cross-file emission (:suffix and :lcp_shared share the same shape):
  #
  #  * synthesise a public helper landing in `target_module`
  #  * each clone module gets a rewrite (call to `target.helper(...)`)
  #    plus an `:import` plan entry so existing call-site syntax keeps
  #    resolving without the source mentioning the host module
  #  * the helper itself is emitted as a `:cross_helper` plan entry
  #    that `process_cross_writes/2` materialises to disk later
  defp emit_cross_file_plan(_kind, entries, target_module, skeleton, holes, state) do
    cond do
      # Reject if any source module's reachability analysis flagged a
      # defp shared between the clone and a non-clone caller.
      entries |> Enum.any?(& &1.helpers_rejected?) ->
        {[], state}

      # Reject if a referenced module attribute is missing or has a
      # non-literal value.
      entries |> Enum.any?(& &1.attrs_rejected?) ->
        {[], state}

      # Reject if attribute *values* diverge across source modules.
      not attrs_consistent_across_entries?(entries) ->
        {[], state}

      # Reject if source modules' import statements diverge — the
      # body's macro calls (e.g. Ecto.Query) wouldn't resolve in a
      # target with mismatched imports.
      not all_imports_match?(entries) ->
        {[], state}

      true ->
        do_emit_cross_file_plan(entries, target_module, skeleton, holes, state)
    end
  end

  defp do_emit_cross_file_plan(entries, target_module, skeleton, holes, state) do
    [first | _] = entries
    used = state.used

    base_name = synth_helper_name(entries)
    already_used = Map.get(used, target_module, %{})
    {:ok, name_str} = resolve_collision(base_name, already_used)
    helper_name = String.to_atom(name_str)
    new_used = Map.put(used, target_module, Map.put(already_used, name_str, :reserved))

    # Same classification as :intra: outer holes become real params,
    # inner-bound holes get unified into canonical local names inside
    # the helper body without showing up at the call-site.
    classify_holes(skeleton, holes, entries)
    |> handle_classify_holes(
      entries,
      first,
      helper_name,
      new_used,
      skeleton,
      state,
      target_module
    )
  end

  defp do_emit_cross_file_plan_with_classification(
         entries,
         target_module,
         skeleton,
         outer_holes,
         local_groups,
         all_bound,
         first,
         helper_name,
         new_used,
         state
       ) do
    outer_groups = dedupe_outer_holes(outer_holes)

    used_arg_names = arg_names_used_in_skeleton(skeleton, first.arg_names)

    param_names = pick_param_names(outer_groups, used_arg_names, all_bound)

    helper_args = used_arg_names ++ param_names

    kept_arg_indices =
      first.arg_names
      |> Enum.with_index()
      |> Enum.filter(fn {n, _i} -> n in used_arg_names end)
      |> Enum.map(fn {_n, i} -> i end)

    # Migratable helpers' names — calls to these stay local in the
    # target module (they get migrated alongside), so we must NOT
    # qualify them.
    migratable_local_calls =
      first.helpers
      |> Enum.map(&clause_name_arity/1)
      |> MapSet.new()

    helper_body =
      skeleton
      |> inflate_skeleton(outer_groups, helper_args)
      |> rename_local_holes(local_groups)
      |> qualify_aliases_skip_locals(first.aliases, migratable_local_calls)

    helper_def = %{
      args: helper_args,
      arity: length(helper_args),
      body_ast: helper_body,
      kind: :def,
      name: helper_name
    }

    # Migrated helpers need their bodies alias-qualified too (they
    # might reference the source module's aliases).
    migrated_helper_clauses =
      first.helpers
      |> Enum.map(&qualify_aliases_skip_locals(&1, first.aliases, migratable_local_calls))

    cross_helper_info = %{
      attrs: first.attrs,
      helper_def: helper_def,
      imports: first.imports,
      migrated_helpers: migrated_helper_clauses
    }

    if helper_renderable?(helper_body) do
      cross_helper_entry = {target_module, {:cross_helper, cross_helper_info}}

      rewrite_and_import_entries =
        entries
        |> Enum.flat_map(fn e ->
          outer_values =
            outer_groups |> Enum.map(fn g -> g.values |> Enum.at(e.bucket_index) end)

          kept_args = kept_arg_indices |> Enum.map(&Enum.at(e.arg_names, &1))
          replacement = render_call(helper_name, kept_args ++ outer_values)

          rewrite_entry =
            {e.module,
             {:rewrite,
              %{
                args: e.arg_names,
                arity: e.arity,
                kind: e.kind,
                name: e.name,
                replacement: replacement
              }}}

          # The host module hosts the helper itself — it doesn't import
          # itself.
          if e.module == target_module do
            [rewrite_entry]
          else
            import_entry =
              {e.module, {:import, {target_module, [{helper_name, length(helper_args)}]}}}

            [rewrite_entry, import_entry]
          end
        end)

      {[cross_helper_entry | rewrite_and_import_entries], %{state | used: new_used}}
    else
      {[], state}
    end
  end

  # Cross-module attribute identity: every entry's `attrs` map must
  # have the same values for the union of attribute names. A
  # divergence (`@retries 3` vs `@retries 5`) blocks the clone group.
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

  # Every clone module's import statement set (canonical keys only)
  # must be identical. A subset/superset would still risk macros
  # silently resolving differently in source vs target.
  defp all_imports_match?([first | rest]) do
    keys = fn e -> e.imports |> Enum.map(fn {k, _} -> k end) end
    first_keys = keys.(first)
    rest |> Enum.all?(&(keys.(&1) == first_keys))
  end

  defp clause_name_arity({_kind, _, [head | _]}), do: strip_when(head) |> handle_strip_when()

  # Walk the AST, replace every {:__aliases__, meta, [Single]} that
  # matches a known alias with the fully-qualified module path.
  # Multi-segment alias keys (`Foo.{A, B}` → short = last segment)
  # are handled by `collect_aliases/1`.
  defp qualify_aliases_skip_locals(ast, aliases, _local_call_set) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, [single]} = node when is_atom(single) ->
        case Map.get(aliases, single) do
          nil ->
            node

          full ->
            full_parts = full |> Module.split() |> Enum.map(&String.to_atom/1)
            {:__aliases__, meta, full_parts}
        end

      other ->
        other
    end)
  end

  # Substitute `{:"$hole", [], [path]}` placeholders in `skeleton` by
  # the corresponding parameter variable. `groups` is the post-dedup
  # outer-hole list — each group carries `:paths` (one or more hole
  # paths that share a value-vector) and maps to a single param name.
  defp inflate_skeleton(skeleton, groups, helper_args) do
    n_orig = length(helper_args) - length(groups)
    param_names = helper_args |> Enum.drop(n_orig)

    path_to_var =
      groups
      |> Enum.zip(param_names)
      |> Enum.flat_map(fn {%{paths: paths}, param} ->
        paths |> Enum.map(&{&1, param})
      end)
      |> Map.new()

    Macro.prewalk(skeleton, fn
      {:"$hole", _, [path]} ->
        case Map.get(path_to_var, path) do
          nil -> {:"$hole", [], [path]}
          var -> {var, [], nil}
        end

      other ->
        other
    end)
  end

  # Group outer holes whose per-clone value vector is identical. Each
  # such group becomes a single helper param (the same value is used
  # at every path it occupies). Returns a list of `%{paths: [...],
  # values: [...]}` groups, in the original hole order (first-seen
  # for each value vector).
  defp dedupe_outer_holes(holes) do
    holes
    |> Enum.reduce([], fn hole, acc ->
      key = strip_meta_for_dedup(hole.values)

      case acc |> Enum.find_index(&(&1.dedup_key == key)) do
        nil ->
          [%{dedup_key: key, paths: [hole.path], values: hole.values} | acc]

        idx ->
          List.update_at(acc, idx, fn g -> %{g | paths: g.paths ++ [hole.path]} end)
      end
    end)
    |> Enum.reverse()
  end

  defp strip_meta_for_dedup(values) do
    values
    |> Enum.map(fn v ->
      Macro.prewalk(v, fn
        {form, meta, args} when is_list(meta) -> {form, [], args}
        other -> other
      end)
    end)
  end

  # ---------------------------------------------------------------------
  # Source extraction
  # ---------------------------------------------------------------------

  defp extract_module_info({path, source}, min_mass),
    do: Sourceror.parse_string(source) |> handle_parse_string_2(min_mass, path)

  defp extract_from_ast(ast, path, min_mass) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, mod} ->
            if shared_module?(mod) do
              # `*.Shared` modules are this refactor's own output (and
              # `ExtractSharedModule`'s). Re-scanning them would extract
              # functions we already extracted and inject imports pointing
              # at the same module being defined — a self-import that
              # fails to compile.
              []
            else
              body_exprs = body_to_exprs(body)
              functions_in_module(mod, body_exprs, path, min_mass)
            end

          :error ->
            []
        end

      _ ->
        []
    end)
  end

  defp shared_module?(module), do: module |> Module.split() |> List.last() == "Shared"

  defp functions_in_module(module, body_exprs, path, min_mass) do
    aliases = collect_aliases(body_exprs)
    imports = collect_imports(body_exprs)
    module_attrs = collect_module_attributes(body_exprs)

    # `rewrite_clause_patch/2` only handles single-clause `def`/`defp`
    # — for multi-clause functions there's no unambiguous "this is THE
    # body to replace". Without skipping them here, the planner would
    # still emit a helper + import, but the loser-rewrite step would
    # silently no-op, leaving the original function in place AND a now
    # unused `import …Shared` at the top of the file.
    multi_clause_keys = multi_clause_signatures(body_exprs)

    body_exprs
    |> Enum.filter(&def_clause?/1)
    |> Enum.reject(&clause_in_multi_clause_set?(&1, multi_clause_keys))
    |> Enum.flat_map(
      &build_clause_entry(
        &1,
        module,
        path,
        min_mass,
        aliases,
        imports,
        module_attrs,
        body_exprs
      )
    )
  end

  defp multi_clause_signatures(body_exprs) do
    body_exprs
    |> Enum.filter(&def_clause?/1)
    |> Enum.frequencies_by(&clause_signature/1)
    |> Enum.flat_map(fn
      {sig, count} when count > 1 -> [sig]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp clause_signature({kind, _, [head | _]}),
    do: extract_fn_signature(head) |> handle_extract_fn_signature(kind)

  defp clause_in_multi_clause_set?(clause, set),
    do: set |> MapSet.member?(clause_signature(clause))

  # Collect `@name value` definitions at module-top-level, returning
  # a `%{name => value_ast}` map.
  defp collect_module_attributes(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {:@, _, [{name, _, [value]}]} when is_atom(name) -> [{name, value}]
      _ -> []
    end)
    |> Map.new()
  end

  # Aliases as `%{ShortAtom => FullModule}`. Handles `alias Foo.Bar`,
  # `alias Foo.Bar, as: B`, and `alias Foo.{A, B}`.
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

  defp unwrap_keyword([{k, v} | rest]), do: [{k, v} | rest]
  defp unwrap_keyword(other), do: other

  # Imports as `[{canonical_key, raw_ast}]`. The canonical key is a
  # meta-stripped, inspect-rendered string used for cross-module
  # equality checks. The raw AST gets serialised into the target
  # module verbatim so things like `import Foo, only: [a: 1]` survive.
  defp collect_imports(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {:import, _, _} = node -> [{canonical_import_key(node), node}]
      _ -> []
    end)
    |> Enum.sort_by(fn {k, _} -> k end)
  end

  defp canonical_import_key(import_node),
    do: import_node |> strip_meta() |> inspect(limit: :infinity, printable_limit: :infinity)

  defp def_clause?({kind, _, [_head, body_kw]}) when kind in [:def, :defp] and is_list(body_kw),
    do: true

  defp def_clause?(_), do: false

  defp build_clause_entry(
         {kind, _, [head, body_kw]} = clause,
         module,
         path,
         min_mass,
         aliases,
         imports,
         module_attrs,
         body_exprs
       ) do
    cond do
      head_has_guard?(head) ->
        # `when`-guards would have to be replicated by the helper.
        # Out of scope for v1.
        []

      true ->
        case extract_fn_signature(head) do
          {name, args} when is_list(args) ->
            arg_bindings = args |> Enum.map(&extract_arg_binding/1)

            cond do
              arg_bindings |> Enum.any?(&(&1 == :error)) ->
                []

              clause_mass(clause) < min_mass ->
                []

              contains_binding_macro_call?(body_kw) ->
                # Macros that bind a variable inside a compile-time
                # keyword list (Ecto `from(bind in Schema, where: …)`,
                # similar query DSLs) cannot be parametrised: their
                # bind name and keyword keys must be atoms at compile
                # time. Skip the clause rather than emit broken code.
                []

              true ->
                arg_names = arg_bindings |> Enum.map(fn {:ok, n} -> n end)
                body_ast = body_kw |> Keyword.values() |> List.first()

                # Reachable defp helpers: those that this clone can
                # call AND that no other public def in the module
                # also calls (otherwise migrating them orphans the
                # other caller). When a clone references a defp that
                # is *also* used by a non-clone def, the clone group
                # gets rejected at emit-time — we record the conflict
                # via `reject_helpers?`.
                {migratable_helpers, reject_helpers?} =
                  reachable_helper_clauses(body_exprs, name, length(args))

                # Module attrs referenced from body or migratable
                # helpers. A non-literal value or a missing attr
                # (e.g. attr declared with `Module.put_attribute`,
                # not `@`) makes migration unsafe.
                attrs_used = collect_attrs_used([body_ast], migratable_helpers)

                {attrs_to_migrate, reject_attrs?} =
                  resolve_attrs_for_migration(attrs_used, module_attrs)

                [
                  %{
                    aliases: aliases,
                    arg_names: arg_names,
                    arity: length(args),
                    attrs: attrs_to_migrate,
                    attrs_rejected?: reject_attrs?,
                    body_ast: body_ast,
                    bucket_index: nil,
                    clause: clause,
                    helpers: migratable_helpers,
                    helpers_rejected?: reject_helpers?,
                    imports: imports,
                    kind: kind,
                    module: module,
                    name: name,
                    path: path,
                    skeleton_hash: skeleton_hash(body_ast)
                  }
                ]
            end

          _ ->
            []
        end
    end
  end

  # Walk `body_exprs`, do a transitive reachability from
  # `(target_name, target_arity)`, and return a tuple
  # `{migratable_clauses, reject?}`. A defp is migratable iff
  # it's reachable from the target AND not reachable from any
  # *other* def. If a defp is reachable from both, we mark
  # `reject?` so the clone group can be dropped — migrating
  # would orphan the other caller.
  defp reachable_helper_clauses(body_exprs, target_name, target_arity) do
    definitions = collect_definitions(body_exprs)

    target_calls =
      definitions
      |> Enum.find(fn d ->
        d.kind in [:def, :defp] and d.name == target_name and d.arity == target_arity
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

    other_def_roots =
      definitions
      |> Enum.filter(fn d ->
        d.kind == :def and not (d.name == target_name and d.arity == target_arity)
      end)
      |> Enum.map(&{&1.name, &1.arity})
      |> MapSet.new()

    reachable_from_others = transitive_closure(other_def_roots, call_graph)

    migratable =
      definitions
      |> Enum.filter(fn d ->
        d.kind == :defp and
          MapSet.member?(reachable_from_target, {d.name, d.arity}) and
          not MapSet.member?(reachable_from_others, {d.name, d.arity})
      end)

    conflicting? =
      definitions
      |> Enum.any?(fn d ->
        d.kind == :defp and
          MapSet.member?(reachable_from_target, {d.name, d.arity}) and
          MapSet.member?(reachable_from_others, {d.name, d.arity})
      end)

    migratable_clauses = migratable |> Enum.flat_map(& &1.clauses)
    {migratable_clauses, conflicting?}
  end

  defp collect_definitions(body_exprs) do
    body_exprs
    |> Enum.filter(fn
      {kind, _, [_h, body_kw]} when kind in [:def, :defp] and is_list(body_kw) -> true
      _ -> false
    end)
    |> Enum.group_by(fn {kind, _, [head | _]} ->
      case strip_when(head) do
        {name, _, args} when is_atom(name) and is_list(args) -> {kind, name, length(args)}
        {name, _, nil} when is_atom(name) -> {kind, name, 0}
        _ -> :skip
      end
    end)
    |> Enum.reject(fn {key, _} -> key == :skip end)
    |> Enum.map(fn {{kind, name, arity}, clauses} ->
      %{
        arity: arity,
        calls: collect_calls_in_clauses(clauses),
        clauses: clauses,
        kind: kind,
        name: name
      }
    end)
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp collect_calls_in_clauses(clauses) do
    clauses
    |> Enum.flat_map(fn
      {_, _, [_h, body_kw]} when is_list(body_kw) ->
        body_kw |> Keyword.values() |> Enum.flat_map(&collect_local_calls/1)

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp collect_local_calls(ast) do
    {_, pipe_rhs_set} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:|>, _, [_lhs, rhs]} = node, acc -> {node, MapSet.put(acc, rhs)}
        node, acc -> {node, acc}
      end)

    {_, calls} =
      Macro.prewalk(ast, [], fn
        {:|>, _, [_lhs, rhs]} = node, acc ->
          case rhs do
            {{:., _, [_, _]}, _, _} ->
              {node, acc}

            {name, _, args} when is_atom(name) and is_list(args) ->
              if local_call_candidate?(name) do
                {node, [{name, length(args) + 1} | acc]}
              else
                {node, acc}
              end

            {name, _, nil} when is_atom(name) ->
              if local_call_candidate?(name), do: {node, [{name, 1} | acc]}, else: {node, acc}

            _ ->
              {node, acc}
          end

        {:&, _, [{:/, _, [{name, _, ctx}, arity]}]} = node, acc
        when is_atom(name) and is_atom(ctx) and is_integer(arity) ->
          {node, [{name, arity} | acc]}

        {:&, _, [{:/, _, [{name, _, ctx}, {:__block__, _, [arity]}]}]} = node, acc
        when is_atom(name) and is_atom(ctx) and is_integer(arity) ->
          {node, [{name, arity} | acc]}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          cond do
            MapSet.member?(pipe_rhs_set, node) -> {node, acc}
            local_call_candidate?(name) -> {node, [{name, length(args)} | acc]}
            true -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    calls
  end

  defp local_call_candidate?(name),
    do:
      not Macro.special_form?(name, 0) and
        not Macro.special_form?(name, 1) and
        not Macro.special_form?(name, 2) and
        not Macro.operator?(name, 1) and
        not Macro.operator?(name, 2)

  defp transitive_closure(roots, graph), do: roots |> do_closure(graph, MapSet.to_list(roots))

  defp do_closure(reached, _graph, []), do: reached

  defp do_closure(reached, graph, [current | rest]) do
    callees = Map.get(graph, current, MapSet.new())
    new = callees |> Enum.reject(&MapSet.member?(reached, &1))
    next = new |> Enum.reduce(reached, &MapSet.put(&2, &1))
    do_closure(next, graph, rest ++ new)
  end

  # Collect attribute references in `body_asts ++ helper_clauses`.
  defp collect_attrs_used(body_asts, helper_clauses) do
    body_attrs =
      body_asts
      |> Enum.flat_map(&attr_refs_in/1)

    helper_attrs =
      helper_clauses
      |> Enum.flat_map(fn {_, _, [_h, body_kw]} ->
        body_kw |> Keyword.values() |> Enum.flat_map(&attr_refs_in/1)
      end)

    (body_attrs ++ helper_attrs) |> MapSet.new()
  end

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

  # Returns `{attrs_map, reject?}`. Every referenced attribute must
  # be (a) defined in this module and (b) have a structural-literal
  # value (atoms, numbers, strings, lists, tuples, maps, struct
  # literals, other `@attr` references). Function calls or captures
  # in the value are unsafe.
  defp resolve_attrs_for_migration(attrs_used, module_attrs) do
    if attrs_used |> Enum.all?(&attr_migratable?(&1, module_attrs)) do
      attrs =
        attrs_used
        |> Enum.map(fn name -> {name, Map.fetch!(module_attrs, name)} end)
        |> Map.new()

      {attrs, false}
    else
      {%{}, MapSet.size(attrs_used) > 0}
    end
  end

  defp attr_migratable?(name, module_attrs),
    do: Map.fetch(module_attrs, name) |> handle_attr_migratable_fetch()

  defp attr_value_literal?(ast) do
    {_, ok?} =
      Macro.prewalk(ast, true, fn
        {{:., _, _}, _, _}, _acc ->
          {nil, false}

        {:&, _, _}, _acc ->
          {nil, false}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) and acc ->
          if attr_local_call?(name), do: {nil, false}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    ok?
  end

  defp attr_local_call?(name),
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

  defp head_has_guard?({:when, _, _}), do: true
  defp head_has_guard?(_), do: false

  @doc """
  Extract the bound variable name from a function argument node.

  Returns `{:ok, var_atom}` when the argument is one of:
    * a bare variable: `x`
    * a pattern with `=`-binding: `pattern = var`, `var = pattern`,
      or `var = _` / `_ = var` (underscore counts as opaque pattern)

  Returns `:error` for: default-args (`x \\\\ default`), bare literals,
  or patterns without an `=`-bound variable.

  When both sides of `=` are bare vars (`a = b`), the LHS wins —
  arbitrary but deterministic.
  """
  @spec extract_arg_binding(Macro.t()) :: {:ok, atom()} | :error
  def extract_arg_binding({:\\, _, _}), do: :error

  def extract_arg_binding({:=, _, [lhs, rhs]}) do
    case {bare_var_name(lhs), bare_var_name(rhs)} do
      {{:ok, name}, _} -> {:ok, name}
      {_, {:ok, name}} -> {:ok, name}
      _ -> :error
    end
  end

  def extract_arg_binding(node), do: node |> bare_var_name()

  # bare_var/1 from AstHelpers already returns {:ok, name_atom} |
  # :skip — adapt :skip → :error for our convention.
  defp bare_var_name(node), do: bare_var(node) |> handle_bare_var()

  defp clause_mass({_kind, _, [_head, body_kw]}),
    do: body_kw |> Keyword.values() |> Enum.map(&node_count/1) |> Enum.sum()

  # Whether `body_kw` (a Sourceror-parsed clause body keyword list)
  # contains a call to one of `@binding_macros` anywhere in its tree.
  # We don't try to be clever about scope — if the macro is used at
  # all inside the clause, we skip it.
  defp contains_binding_macro_call?(body_kw),
    do:
      body_kw
      |> Keyword.values()
      |> Enum.any?(&ast_uses_binding_macro?/1)

  defp ast_uses_binding_macro?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        _node, true ->
          {:ignore, true}

        {name, _meta, args} = node, false when is_atom(name) and is_list(args) ->
          if name in @binding_macros, do: {node, true}, else: {node, false}

        node, false ->
          {node, false}
      end)

    found?
  end

  defp node_count(ast) do
    {_, count} = Macro.prewalk(ast, 0, fn node, acc -> {node, acc + 1} end)
    count
  end

  defp skeleton_hash(body_ast),
    do:
      body_ast
      |> inline_pipes()
      |> normalize_skeleton()
      |> :erlang.phash2()

  # Aggressive skeleton normalisation: collapse not just wrapped
  # literals (`{:__block__, _, [v]}`) but also bare atoms that vary
  # across structurally-identical clauses — function-name atoms in
  # dot-calls, variable names, module aliases. Meta is always stripped
  # so position info doesn't perturb the hash. Two clones that share
  # the same shape but differ in any of these atoms must hash equal so
  # they bucket together; the divergent atoms become holes during the
  # AstDiff pass.
  defp normalize_skeleton(ast) do
    Macro.prewalk(ast, fn
      # Wrapped literal — collapse to a single placeholder.
      {:__block__, _meta, [v]}
      when is_atom(v) or is_integer(v) or is_float(v) or is_binary(v) ->
        {:"$lit", [], [0]}

      # Function dot-call: `{:., _, [target, fn_name]}` — collapse
      # fn_name to a placeholder atom.
      {:., _meta, [target, fn_name]} when is_atom(fn_name) ->
        {:., [], [target, :"$fn"]}

      # Module alias: list of atoms in `{:__aliases__, _, [...]}`.
      {:__aliases__, _meta, segments} when is_list(segments) ->
        {:__aliases__, [], segments |> Enum.map(fn _ -> :"$alias" end)}

      # Variable reference: `{name, meta, ctx}` where name is atom and
      # ctx is atom or nil. Distinguish from function-call shape
      # `{name, meta, [args]}` (args is list).
      {name, _meta, ctx} when is_atom(name) and is_atom(ctx) ->
        {:"$var", [], nil}

      # Strip meta on remaining call/struct/etc. forms.
      {form, meta, args} when is_list(meta) ->
        {form, [], args}

      other ->
        other
    end)
  end

  # ---------------------------------------------------------------------
  # Source-of-truth selection
  # ---------------------------------------------------------------------

  @doc """
  Pick the helper's host module given the clone-group entries.
  """
  @spec pick_target([%{module: module()}]) ::
          {:intra, module()}
          | {:suffix, module()}
          | {:lcp_shared, module()}
          | :skip
  def pick_target(entries) do
    by_module = entries |> Enum.group_by(& &1.module)

    best_intra_concentration(by_module) |> handle_best_intra_concentration(by_module, entries)
  end

  defp best_intra_concentration(by_module) do
    candidates =
      by_module
      |> Enum.filter(fn {_mod, entries} -> length(entries) >= 2 end)
      |> Enum.map(fn {mod, entries} -> {mod, length(entries)} end)

    case candidates do
      [] ->
        :none

      _ ->
        winner =
          candidates
          |> Enum.max_by(fn {mod, count} ->
            # Tie-break order on equal count:
            #   1. Mehr Modul-Tiefe (Punkte) gewinnt → Module.split-Länge
            #   2. Längerer Modulname (String-Länge) gewinnt
            #   3. Alphabetisch erstes (= grösste invertierte Codepoints)
            {count, length(Module.split(mod)), String.length(inspect(mod)), invert_alpha(mod)}
          end)
          |> elem(0)

        {:ok, winner}
    end
  end

  defp first_suffix_match(by_module) do
    modules = Map.keys(by_module)

    @suffix_priority
    |> Enum.find_value(:none, fn suffix ->
      matches =
        modules
        |> Enum.filter(fn mod ->
          mod |> Module.split() |> List.last() |> String.to_atom() == suffix
        end)

      case matches do
        [] -> nil
        _ -> {:ok, matches |> Enum.min_by(&Module.split/1)}
      end
    end)
  end

  defp lcp_shared_module(entries) do
    parts_lists = entries |> Enum.map(&Module.split(&1.module))
    prefix = longest_common_prefix(parts_lists)

    if prefix != [] do
      {:ok, Module.concat(prefix ++ ["Shared"])}
    else
      :skip
    end
  end

  defp longest_common_prefix([]), do: []
  defp longest_common_prefix([single]), do: single

  defp longest_common_prefix(lists) do
    lists
    |> Enum.zip()
    |> Enum.take_while(fn tuple ->
      elements = Tuple.to_list(tuple)
      elements |> Enum.all?(&(&1 == hd(elements)))
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp invert_alpha(mod),
    do:
      mod
      |> inspect()
      |> String.to_charlist()
      |> Enum.map(&(-&1))

  # ---------------------------------------------------------------------
  # Helper naming
  # ---------------------------------------------------------------------

  defp synth_helper_name(entries) do
    # Pick by descending frequency, ascending alphabetical name on tie.
    # Ensures deterministic results regardless of source-file ordering.
    most_common_name =
      entries
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.max_by(fn {name, count} -> {count, invert_atom(name)} end)
      |> elem(0)
      |> Atom.to_string()

    # Predicate (`?`) and bang (`!`) markers stay meaningful on the
    # synthesised helper — `:keep` re-attaches them after the suffix
    # so `references_var?` becomes `references_var_shared?`, not
    # the parse-error `references_var?_shared`.
    AstHelpers.safe_append_suffix(most_common_name, "_shared", :keep)
  end

  defp invert_atom(atom), do: atom |> Atom.to_string() |> String.to_charlist() |> Enum.map(&(-&1))

  # ---------------------------------------------------------------------
  # Per-file rewrite
  # ---------------------------------------------------------------------

  defp rewrite(source, plan),
    do: Sourceror.parse_string(source) |> handle_parse_string_3(plan, source)

  defp apply_plan_to_ast(ast, source, plan) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} = mod_node ->
        case alias_to_module(name_ast) do
          {:ok, mod} ->
            cond do
              shared_module?(mod) ->
                # `*.Shared` is the host file we write to, never a loser.
                # If a stale plan still lists it, ignore — patching would
                # inject a self-import and rewrite the helper into a
                # delegate to itself.
                []

              true ->
                case Map.get(plan, mod) do
                  nil ->
                    []

                  {helpers, rewrites, imports} ->
                    patches_for_module(mod_node, body, helpers, rewrites, imports)
                end
            end

          :error ->
            []
        end

      _ ->
        []
    end)
    |> patch_or_passthrough(source)
  end

  defp patches_for_module(mod_node, body, helpers, rewrites, imports) do
    body_exprs = body_to_exprs(body)

    rewrite_patches =
      rewrites
      |> Enum.flat_map(&rewrite_clause_patch(body_exprs, &1))

    fresh_helpers =
      helpers |> Enum.reject(&helper_already_present?(body_exprs, &1.name, &1.arity))

    helper_patch =
      case fresh_helpers do
        [] -> []
        list -> insert_helpers_patch(mod_node, list)
      end

    import_patches = build_import_patches(body_exprs, imports)

    rewrite_patches ++ helper_patch ++ import_patches
  end

  # For each `{target, [{name, arity}, ...]}` import-spec, produce one
  # `import Target, only: [name: arity, ...]` insertion just before the
  # first body expression of the module. Skip if the module already
  # imports the target (idempotence + redundancy guard).
  defp build_import_patches(body_exprs, imports) do
    imports
    |> Enum.flat_map(fn {target, only_pairs} ->
      cond do
        only_pairs == [] ->
          []

        module_already_imports?(body_exprs, target) ->
          []

        true ->
          only_str =
            only_pairs |> Enum.map_join(", ", fn {n, a} -> "#{n}: #{a}" end)

          replacement = "import #{inspect(target)}, only: [#{only_str}]"
          insertion_anchor = first_body_expr(body_exprs)

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

  defp module_already_imports?(body_exprs, target) do
    body_exprs
    |> Enum.any?(fn
      {:import, _, [{:__aliases__, _, parts}]} -> Module.concat(parts) == target
      {:import, _, [{:__aliases__, _, parts}, _]} -> Module.concat(parts) == target
      _ -> false
    end)
  end

  defp first_body_expr([first | _]), do: first
  defp first_body_expr([]), do: nil

  defp helper_already_present?(body_exprs, name, arity) do
    body_exprs
    |> Enum.any?(fn
      {kind, _, [head | _]} when kind in [:def, :defp] ->
        match?({^name, args} when length(args) == arity, extract_fn_signature(head))

      _ ->
        false
    end)
  end

  defp rewrite_clause_patch(body_exprs, %{arity: arity, name: name, replacement: replacement} = r) do
    clauses = body_exprs |> Enum.filter(&clause_matches?(&1, name, arity))

    case clauses do
      [single] ->
        head_string = render_clause_head(single, r)
        rendered = head_string <> ", do: " <> replacement
        clause_replacement_patch(single, rendered)

      _ ->
        []
    end
  end

  # Render the function clause's head verbatim from its original AST,
  # preserving pattern-match arguments (`%Scope{} = scope`) instead of
  # collapsing them to the bare variable. Falls back to the bare-var
  # form if the original head can't be stringified cleanly.
  defp render_clause_head({kind, _, [head, _body]}, r) do
    head_str = head |> strip_comments() |> Sourceror.to_string()
    "#{kind} #{head_str}"
  rescue
    _ -> "#{r.kind} #{r.name}(#{r.args |> Enum.join(", ")})"
  end

  defp render_clause_head(_, r), do: "#{r.kind} #{r.name}(#{r.args |> Enum.join(", ")})"

  defp clause_matches?({kind, _, [head | _]}, name, arity) when kind in [:def, :defp] do
    match?({^name, args} when length(args) == arity, extract_fn_signature(head))
  end

  defp clause_matches?(_, _, _), do: false

  defp clause_replacement_patch(clause, replacement),
    do: Sourceror.get_range(clause) |> handle_get_range(replacement)

  defp insert_helpers_patch(mod_node, helpers),
    do: Sourceror.get_range(mod_node) |> handle_get_range_2(helpers)

  # Whether `body_ast` survives `Sourceror.to_string`. Some hole
  # positions (Ecto.from `bind in Schema` LHS, alias segments,
  # keyword-key-only positions) crash the Elixir formatter because they
  # require compile-time atoms but the AST has a `param_N` var instead.
  # Cheaper to detect by trying the render than to enumerate every
  # offending shape. Used as a final gate before emitting a helper.
  defp helper_renderable?(body_ast) do
    stripped = strip_comments(body_ast)
    rendered = Sourceror.to_string(stripped)

    # Roundtrip the rendered string. We require:
    #   * it parses (catches `atom_to_binary` formatter crashes)
    #   * the re-parsed AST equals the input AST modulo meta (catches
    #     silent malformations like `:"oz-fragment"` rendered as the
    #     subtraction `:oz - fragment`).
    case Sourceror.parse_string(rendered) do
      {:ok, reparsed} -> ast_equivalent?(reparsed, stripped)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp ast_equivalent?(a, b), do: drop_meta(a) == drop_meta(b)

  defp drop_meta(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) -> {form, [], args}
      other -> other
    end)
  end

  defp render_helper(%{args: args, body_ast: body_ast, kind: kind, name: name}) do
    arg_list = args |> Enum.join(", ")
    body_string = body_ast |> strip_comments() |> Sourceror.to_string()

    if String.contains?(body_string, "\n") do
      indented_body =
        body_string
        |> String.split("\n")
        |> Enum.map_join("\n", fn line -> if line == "", do: "", else: "  " <> line end)

      "#{kind} #{name}(#{arg_list}) do\n#{indented_body}\nend"
    else
      "#{kind} #{name}(#{arg_list}), do: #{body_string}"
    end
  end

  # Strip Sourceror's :leading_comments / :trailing_comments before
  # rendering, otherwise comments from the original clones would print
  # twice (once in the helper, once in the lingering original site).
  defp strip_comments(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        meta =
          meta
          |> Keyword.put(:leading_comments, [])
          |> Keyword.put(:trailing_comments, [])

        {form, meta, args}

      other ->
        other
    end)
  end

  defp render_call(name, args) do
    args_str =
      args
      |> Enum.map_join(", ", fn
        v when is_atom(v) and not is_boolean(v) and not is_nil(v) ->
          if is_atom_var?(v), do: Atom.to_string(v), else: render_literal(v)

        other ->
          render_literal(other)
      end)

    "#{name}(#{args_str})"
  end

  # Distinguish a bare-var atom (used as an arg name) from an actual
  # atom literal. If the atom is a snake_case var name, render it as
  # variable; otherwise as a `:foo` literal.
  defp is_atom_var?(atom) when is_atom(atom) do
    string = Atom.to_string(atom)

    Regex.match?(~r/^[a-z_][a-zA-Z0-9_]*[?!]?$/, string) and
      string not in ["true", "false", "nil"]
  end

  defp render_literal(value) do
    cond do
      is_binary(value) ->
        inspect(value)

      is_integer(value) ->
        Integer.to_string(value)

      is_float(value) ->
        Float.to_string(value)

      is_boolean(value) ->
        Atom.to_string(value)

      is_nil(value) ->
        "nil"

      is_atom(value) ->
        # `inspect/1` quotes the atom when needed (`:"oz-fragment"`)
        # but leaves simple atoms unquoted (`:foo`). Manual `:` prefix
        # would render `:oz-fragment` which then re-parses as
        # subtraction.
        inspect(value)

      # Sourceror-wrapped form
      match?({:__block__, _, [_]}, value) ->
        {:__block__, _, [v]} = value
        render_literal(v)

      true ->
        # Use `strip_comments/1` (not `strip_meta/1`): Sourceror render
        # hints like `no_parens: true` (keeps `position.id` from
        # rendering as the deprecated `position.id()`), `delimiter`,
        # `format` and `closing` live in meta and must survive.
        value |> strip_comments() |> Sourceror.to_string()
    end
  end

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  # ---------------------------------------------------------------------
  # Default source loading
  # ---------------------------------------------------------------------

  defp load_default_sources,
    do: File.read(".refactoring.exs") |> handle_load_default_sources_read()

  defp excluded_path?(path?) do
    normalized = String.trim_leading(path?, "./")
    @excluded_path_prefixes |> Enum.any?(&String.starts_with?(normalized, &1))
  end

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_prepare_get(nil, opts),
    do: load_default_sources() |> handle_load_default_sources(opts)

  defp handle_prepare_get(paths, opts) when is_list(paths) do
    sources = paths |> Enum.map(fn p -> {p, File.read!(p)} end)
    {:ok, build_plan(sources, opts)}
  end

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_transform_get(nil, source), do: source

  defp handle_transform_get(plan, source), do: source |> rewrite(plan)

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_parse_string({:error, _}, infos), do: infos |> render_target_body()

  defp handle_parse_string({:ok, ast}, infos) do
    existing = scan_existing_target_body(ast)

    attrs =
      infos
      |> merge_attrs()
      |> Enum.reject(fn {name, _} -> MapSet.member?(existing.attribute_names, name) end)
      |> Map.new()

    migrated_helpers =
      infos
      |> merge_migrated_helpers()
      |> Enum.reject(&MapSet.member?(existing.function_keys, clause_name_arity(&1)))

    helper_defs =
      infos
      |> Enum.map(& &1.helper_def)
      |> Enum.reject(&MapSet.member?(existing.function_keys, {&1.name, &1.arity}))

    body_calls = body_unqualified_calls(migrated_helpers, helper_defs)

    imports =
      infos
      |> merge_imports()
      |> Enum.reject(fn {key, _} -> MapSet.member?(existing.import_keys, key) end)
      |> prune_unused_imports(body_calls)

    [
      render_attributes(attrs),
      render_imports(imports),
      render_migrated_helpers(migrated_helpers),
      render_helper_defs(helper_defs)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_classify_holes(
         :skip_group,
         _entries,
         _first,
         _helper_name,
         _new_used,
         _skeleton,
         state,
         _target_module
       ),
       do: {[], state}

  defp handle_classify_holes(
         {outer_holes, local_groups, all_bound},
         entries,
         first,
         helper_name,
         new_used,
         skeleton,
         state,
         target_module
       ),
       do:
         entries
         |> do_emit_cross_file_plan_with_classification(
           target_module,
           skeleton,
           outer_holes,
           local_groups,
           all_bound,
           first,
           helper_name,
           new_used,
           state
         )

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_strip_when({name, _, args}) when is_list(args) do
    {name, length(args)}
  end

  defp handle_strip_when({name, _, nil}), do: {name, 0}

  defp handle_strip_when(_), do: {nil, -1}

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_parse_string_2({:ok, ast}, min_mass, path),
    do: ast |> extract_from_ast(path, min_mass)

  defp handle_parse_string_2({:error, _}, _min_mass, _path), do: []

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_extract_fn_signature({name, args}, kind) when is_list(args) do
    {kind, name, length(args)}
  end

  defp handle_extract_fn_signature(_, _kind), do: :__skip__

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_attr_migratable_fetch({:ok, value}), do: value |> attr_value_literal?()

  defp handle_attr_migratable_fetch(:error), do: false

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_bare_var({:ok, name}), do: {:ok, name}

  defp handle_bare_var(:skip), do: :error

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_best_intra_concentration({:ok, mod}, _by_module, _entries), do: {:intra, mod}

  defp handle_best_intra_concentration(:none, by_module, entries),
    do: first_suffix_match(by_module) |> handle_first_suffix_match(entries)

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_parse_string_3({:ok, ast}, plan, source), do: ast |> apply_plan_to_ast(source, plan)

  defp handle_parse_string_3({:error, _}, _plan, source), do: source

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_get_range(%{end: end_pos, start: start_pos}, replacement),
    do: [%{change: replacement, range: %{end: end_pos, start: start_pos}}]

  defp handle_get_range(_, _replacement), do: []

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_get_range_2(%{end: end_pos}, helpers) do
    rendered =
      helpers
      |> Enum.map(&render_helper/1)
      |> Enum.map_join("\n\n", fn block ->
        block
        |> String.split("\n")
        |> Enum.map_join("\n", fn
          "" -> ""
          line -> "  " <> line
        end)
      end)

    # Insert just before the module's closing `end`.
    insert_pos = [line: end_pos[:line], column: 1]
    [%{change: rendered <> "\n", range: %{end: insert_pos, start: insert_pos}}]
  end

  defp handle_get_range_2(_, _helpers), do: []

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_load_default_sources_read({:ok, contents}) do
    {config, _} = Code.eval_string(contents)
    inputs = Keyword.get(config, :inputs, [])

    inputs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&excluded_path?/1)
    |> Enum.map(fn p -> {p, File.read!(p)} end)
  end

  defp handle_load_default_sources_read(_), do: []

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_load_default_sources([], _opts), do: :no_cache

  defp handle_load_default_sources(sources, opts), do: {:ok, build_plan(sources, opts)}

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_first_suffix_match({:ok, mod}, _entries), do: {:suffix, mod}

  defp handle_first_suffix_match(:none, entries),
    do: lcp_shared_module(entries) |> handle_lcp_shared_module()

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_lcp_shared_module({:ok, mod}), do: {:lcp_shared, mod}

  defp handle_lcp_shared_module(:skip), do: :skip
end
