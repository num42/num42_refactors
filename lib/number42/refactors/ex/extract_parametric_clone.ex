defmodule Number42.Refactors.Ex.ExtractParametricClone do
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

  use Number42.Refactors.Refactor

  alias Number42.Refactors.AstDiff
  alias Number42.Refactors.AstHelpers

  @default_min_mass 25

  @suffix_priority [:Format, :Formatter, :Helper, :Helpers, :Shared]

  @excluded_path_prefixes ["test/", "dev/"]

  # Macros whose body uses a binding-introducing form `bind in Schema`
  # plus a compile-time keyword-list of clauses. Parametrising any
  # position inside such a call produces an AST that the formatter or
  # the macro itself reject. Treat their presence in a clone body as
  # "skip this clause".
  @binding_macros [:from]

  # Lexically-scoped compile-time macros: their value depends on the
  # module they're expanded in, not on any runtime argument.
  #
  # `__MODULE__` is the *parametrisable* one: when a cross-file clone
  # body uses it, the cross-file emitter threads the module in as an
  # extra argument (`%__MODULE__{...}` → `struct!(module, ...)`, bare
  # `__MODULE__` → the module var) so the lifted helper stays correct
  # in the `*.Shared` module. Intra-module extraction leaves it alone —
  # the helper stays in the clones' own module, where `__MODULE__`
  # already resolves correctly.
  @module_macro :__MODULE__

  # The rest have no runtime value to pass as a parameter, so a clone
  # body (or a migrated helper) using one is skipped: lifting it into a
  # `*.Shared` module would silently rebind it to the wrong module.
  @unsafe_lexical_macros [:__ENV__, :__CALLER__, :__DIR__, :__STACKTRACE__]

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
      _state = process_cross_writes(plan_entries, write_root, source_paths(sources))
    end

    assemble_plan(plan_entries)
  end

  # On-disk paths of the (non-excluded) source files, used to derive the
  # real `lib/<dir>` layout instead of naively underscoring the namespace.
  defp source_paths(sources), do: sources |> Enum.map(fn {path, _src} -> path end)

  @impl Number42.Refactors.Refactor
  def description, do: "Type-II clone extraction: parametrise differing literals into a helper"
  @impl Number42.Refactors.Refactor
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

    best_intra_concentration(by_module) |> target_from_concentration_or_suffix(by_module, entries)
  end

  @impl Number42.Refactors.Refactor
  def prepare(opts), do: Keyword.get(opts, :source_files) |> prepared_for_paths(opts)
  @impl Number42.Refactors.Refactor
  def priority, do: 110
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, opts),
    do: Keyword.get(opts, :prepared) |> rewrite_with_plan_or_passthrough(source)

  defp all_imports_match?([first | rest]) do
    keys = fn e -> e.imports |> Enum.map(fn {k, _} -> k end) end
    first_keys = keys.(first)
    rest |> Enum.all?(&(keys.(&1) == first_keys))
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

  defp apply_plan_to_ast(ast, source, plan) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} = mod_node ->
        patches_for_module_node(mod_node, name_ast, body, plan)

      _ ->
        []
    end)
    |> patch_or_passthrough(source)
  end

  defp patches_for_module_node(mod_node, name_ast, body, plan) do
    case alias_to_module(name_ast) do
      {:ok, mod} -> patches_for_resolved_module(mod_node, mod, body, plan)
      :error -> []
    end
  end

  # `*.Shared` is the host file we write to, never a loser.
  # If a stale plan still lists it, ignore — patching would
  # inject a self-import and rewrite the helper into a
  # delegate to itself.
  defp patches_for_resolved_module(mod_node, mod, body, plan) do
    if shared_module?(mod) do
      []
    else
      case Map.get(plan, mod) do
        nil ->
          []

        {helpers, rewrites, imports} ->
          patches_for_module(mod_node, body, helpers, rewrites, imports)
      end
    end
  end

  defp apply_plan_to_parse_result({:ok, ast}, plan, source),
    do: ast |> apply_plan_to_ast(source, plan)

  defp apply_plan_to_parse_result({:error, _}, _plan, source), do: source

  defp arg_names_used_in_skeleton(skeleton, arg_names) do
    used =
      arg_names
      |> MapSet.new()
      |> filter_to_used_in_ast(skeleton)

    arg_names |> Enum.filter(&MapSet.member?(used, &1))
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

  defp ast_equivalent?(a, b), do: drop_meta(a) == drop_meta(b)

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

  defp ast_uses_macro?(ast, macros) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        _node, true ->
          {:ignore, true}

        {name, _meta, ctx} = node, false when is_atom(name) and is_atom(ctx) ->
          {node, name in macros}

        node, false ->
          {node, false}
      end)

    found?
  end

  defp ast_uses_unsafe_lexical_macro?(ast), do: ast_uses_macro?(ast, @unsafe_lexical_macros)

  defp ast_uses_module_macro?(ast), do: ast_uses_macro?(ast, [@module_macro])

  defp atom_shaped_key?({:__block__, _, [a]}) when is_atom(a), do: true
  defp atom_shaped_key?(a) when is_atom(a), do: true
  defp atom_shaped_key?({:"$hole", _, _}), do: true
  defp atom_shaped_key?(_), do: false

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

  defp attr_migratable?(name, module_attrs),
    do: Map.fetch(module_attrs, name) |> attr_value_or_false()

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

  defp attr_value_or_false({:ok, value}), do: value |> attr_value_literal?()
  defp attr_value_or_false(:error), do: false

  defp attrs_consistent_across_entries?([first | rest]) do
    first.attrs
    |> Enum.all?(fn {name, value} ->
      stripped = strip_meta(value)
      rest |> Enum.all?(&entry_attr_matches?(&1, name, stripped))
    end)
  end

  defp entry_attr_matches?(entry, name, stripped) do
    case Map.fetch(entry.attrs, name) do
      {:ok, other} -> strip_meta(other) == stripped
      :error -> false
    end
  end

  defp bare_var_name(node), do: bare_var(node) |> var_name_or_error()

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
            #   1. Deeper module path wins → Module.split length
            #   2. Longer module name (string length) wins
            #   3. Alphabetically first (= largest inverted codepoints)
            {count, length(Module.split(mod)), String.length(inspect(mod)), invert_alpha(mod)}
          end)
          |> elem(0)

        {:ok, winner}
    end
  end

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
    if head_has_guard?(head) do
      # `when`-guards would have to be replicated by the helper.
      # Out of scope for v1.
      []
    else
      build_clause_entry_for_signature(
        extract_fn_signature(head),
        clause,
        body_kw,
        min_mass,
        %{
          aliases: aliases,
          body_exprs: body_exprs,
          imports: imports,
          kind: kind,
          module: module,
          module_attrs: module_attrs,
          path: path
        }
      )
    end
  end

  defp build_clause_entry_for_signature({name, args}, clause, body_kw, min_mass, ctx)
       when is_list(args) do
    arg_bindings = args |> Enum.map(&extract_arg_binding/1)

    if clause_unparametrisable?(arg_bindings, clause, body_kw, min_mass) do
      []
    else
      [build_parametric_entry(name, args, arg_bindings, clause, body_kw, ctx)]
    end
  end

  defp build_clause_entry_for_signature(_signature, _clause, _body_kw, _min_mass, _ctx), do: []

  # A clause is skipped when any of these hold:
  #   * an argument isn't a plain/var-bindable pattern (default arg, bare literal)
  #   * the clause is below the minimum-mass threshold
  #   * its body uses a binding macro (`from(bind in …)`) — bind/keys must be
  #     compile-time atoms, so it can't be parametrised
  #   * its body uses an unsafe lexical macro (`__ENV__`/`__CALLER__`/…) — no
  #     runtime value to thread through as a parameter. `__MODULE__` is NOT in
  #     this set; the cross-file emitter parametrises it.
  defp clause_unparametrisable?(arg_bindings, clause, body_kw, min_mass) do
    Enum.any?(arg_bindings, &(&1 == :error)) or
      clause_mass(clause) < min_mass or
      contains_binding_macro_call?(body_kw) or
      contains_unsafe_lexical_macro?(body_kw)
  end

  defp build_parametric_entry(name, args, arg_bindings, clause, body_kw, ctx) do
    arg_names = arg_bindings |> Enum.map(fn {:ok, n} -> n end)
    body_ast = body_kw |> Keyword.values() |> List.first()

    # Reachable defp helpers: those that this clone can
    # call AND that no other public def in the module
    # also calls (otherwise migrating them orphans the
    # other caller). When a clone references a defp that
    # is *also* used by a non-clone def, the clone group
    # gets rejected at emit-time — we record the conflict
    # via `reject_helpers?`.
    {migratable_helpers, helpers_conflict?} =
      reachable_helper_clauses(ctx.body_exprs, name, length(args))

    # A migrated `defp` carries its body into the Shared
    # module too. An unsafe lexical macro there is as bad as
    # in the clone body; `__MODULE__` in a migrated helper is
    # also rejected because this change parametrises only the
    # clone body, not migrated helpers.
    reject_helpers? =
      helpers_conflict? or
        Enum.any?(migratable_helpers, &clause_uses_unsafe_lexical_macro?/1) or
        Enum.any?(migratable_helpers, &clause_uses_module_macro?/1)

    # Module attrs referenced from body or migratable
    # helpers. A non-literal value or a missing attr
    # (e.g. attr declared with `Module.put_attribute`,
    # not `@`) makes migration unsafe.
    attrs_used = collect_attrs_used([body_ast], migratable_helpers)

    {attrs_to_migrate, reject_attrs?} =
      resolve_attrs_for_migration(attrs_used, ctx.module_attrs)

    %{
      aliases: ctx.aliases,
      arg_names: arg_names,
      arity: length(args),
      attrs: attrs_to_migrate,
      attrs_rejected?: reject_attrs?,
      body_ast: body_ast,
      bucket_index: nil,
      clause: clause,
      helpers: migratable_helpers,
      helpers_rejected?: reject_helpers?,
      imports: ctx.imports,
      kind: ctx.kind,
      module: ctx.module,
      name: name,
      path: ctx.path,
      skeleton_hash: skeleton_hash(body_ast)
    }
  end

  defp build_import_patches(body_exprs, imports) do
    imports
    |> Enum.flat_map(fn {target, only_pairs} ->
      cond do
        only_pairs == [] ->
          []

        module_already_imports?(body_exprs, target) ->
          []

        true ->
          import_patch_for_target(body_exprs, target, only_pairs)
      end
    end)
  end

  defp import_patch_for_target(body_exprs, target, only_pairs) do
    only_str = only_pairs |> Enum.map_join(", ", fn {n, a} -> "#{n}: #{a}" end)
    replacement = "import #{inspect(target)}, only: [#{only_str}]"

    case insertion_anchor_range(body_exprs) do
      %{start: pos} -> [%{change: replacement <> "\n\n  ", range: %{end: pos, start: pos}}]
      _ -> []
    end
  end

  defp insertion_anchor_range(body_exprs) do
    case first_body_expr(body_exprs) do
      nil -> :no_anchor
      anchor -> Sourceror.get_range(anchor)
    end
  end

  defp canonical_import_key(import_node),
    do: import_node |> strip_meta() |> inspect(limit: :infinity, printable_limit: :infinity)

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

  defp classify_holes_step(
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

  defp classify_holes_step(
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

  defp clause_in_multi_clause_set?(clause, set),
    do: set |> MapSet.member?(clause_signature(clause))

  defp clause_mass({_kind, _, [_head, body_kw]}),
    do: body_kw |> Keyword.values() |> Enum.map(&node_count/1) |> Enum.sum()

  defp clause_matches?({kind, _, [head | _]}, name, arity) when kind in [:def, :defp] do
    match?({^name, args} when length(args) == arity, extract_fn_signature(head))
  end

  defp clause_matches?(_, _, _), do: false
  defp clause_name_arity({_kind, _, [head | _]}), do: strip_when(head) |> name_arity_or_sentinel()

  defp clause_replacement_patch(clause, replacement),
    do: Sourceror.get_range(clause) |> patch_for_range(replacement)

  defp clause_signature({kind, _, [head | _]}),
    do: extract_fn_signature(head) |> signature_or_skip(kind)

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

  defp collect_imports(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {:import, _, _} = node -> [{canonical_import_key(node), node}]
      _ -> []
    end)
    |> Enum.sort_by(fn {k, _} -> k end)
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

  defp collect_module_attributes(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {:@, _, [{name, _, [value]}]} when is_atom(name) -> [{name, value}]
      _ -> []
    end)
    |> Map.new()
  end

  defp collect_pair_key_path({key, _value}, acc) do
    case key do
      {:"$hole", _, [path]} -> MapSet.put(acc, path)
      _ -> acc
    end
  end

  defp collect_pair_key_path(_, acc), do: acc

  defp contains_binding_macro_call?(body_kw),
    do:
      body_kw
      |> Keyword.values()
      |> Enum.any?(&ast_uses_binding_macro?/1)

  defp contains_unsafe_lexical_macro?(body_kw),
    do:
      body_kw
      |> Keyword.values()
      |> Enum.any?(&ast_uses_unsafe_lexical_macro?/1)

  # `__ENV__`/`__CALLER__`/… in a migrated `defp` would break in the
  # `*.Shared` module just like in the clone body, and we don't
  # parametrise migrated helpers — so they still reject the group.
  # The clause body keeps raw Sourceror keys (`{:__block__, _, [:do]}`),
  # so walk the whole clause AST rather than `Keyword.values`-ing it.
  defp clause_uses_unsafe_lexical_macro?(clause),
    do: ast_uses_unsafe_lexical_macro?(clause)

  # A migrated `defp` carrying `__MODULE__` into a `*.Shared` module
  # would break too — this change only parametrises the clone body, not
  # migrated helpers — so such a group is rejected in the cross-file
  # path (see `reject_helpers?`).
  defp clause_uses_module_macro?(clause),
    do: ast_uses_module_macro?(clause)

  defp dedupe_outer_holes(holes) do
    holes
    |> Enum.reduce([], &dedupe_outer_hole/2)
    |> Enum.reverse()
  end

  defp dedupe_outer_hole(hole, acc) do
    key = strip_meta_for_dedup(hole.values)

    case acc |> Enum.find_index(&(&1.dedup_key == key)) do
      nil ->
        [%{dedup_key: key, paths: [hole.path], values: hole.values} | acc]

      idx ->
        List.update_at(acc, idx, &%{&1 | paths: &1.paths ++ [hole.path]})
    end
  end

  defp def_clause?({kind, _, [_head, body_kw]}) when kind in [:def, :defp] and is_list(body_kw),
    do: true

  defp def_clause?(_), do: false

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
    |> classify_holes_step(
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

    inflated_body =
      skeleton
      |> inflate_skeleton(outer_groups, helper_args)
      |> rename_local_holes(local_groups)
      |> qualify_aliases_skip_locals(first.aliases, migratable_local_calls)

    # Cross-file lift moves the body into a *.Shared module, where a
    # `__MODULE__` reference would rebind to the struct-less shared
    # module. Thread the source module in as a first argument and
    # rewrite `%__MODULE__{...}` → `struct!(module, ...)` / bare
    # `__MODULE__` → the module var. The module var is prepended only
    # to the emitted signature — `inflate_skeleton` already ran on the
    # original `helper_args` (its hole-count math depends on that), so
    # the parameter never participates in hole inflation.
    parametrise_module? = ast_uses_module_macro?(inflated_body)
    module_var = if parametrise_module?, do: fresh_module_var(helper_args, all_bound)

    helper_body =
      if parametrise_module?,
        do: parametrize_module_macro(inflated_body, module_var),
        else: inflated_body

    final_args = if parametrise_module?, do: [module_var | helper_args], else: helper_args

    helper_def = %{
      args: final_args,
      arity: length(final_args),
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
          cross_entries_for_clone(e, %{
            outer_groups: outer_groups,
            kept_arg_indices: kept_arg_indices,
            parametrise_module?: parametrise_module?,
            helper_name: helper_name,
            target_module: target_module,
            final_args: final_args
          })
        end)

      {[cross_helper_entry | rewrite_and_import_entries], %{state | used: new_used}}
    else
      {[], state}
    end
  end

  defp cross_entries_for_clone(e, ctx) do
    outer_values = ctx.outer_groups |> Enum.map(fn g -> g.values |> Enum.at(e.bucket_index) end)
    kept_args = ctx.kept_arg_indices |> Enum.map(&Enum.at(e.arg_names, &1))

    # When the helper was parametrised on the module, each caller
    # passes its own `__MODULE__` as the (first) module argument.
    leading_module = if ctx.parametrise_module?, do: [{:__MODULE__, [], nil}], else: []
    replacement = render_call(ctx.helper_name, leading_module ++ kept_args ++ outer_values)

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

    cross_rewrite_and_import_entries(rewrite_entry, e, ctx)
  end

  # The host module hosts the helper itself — it doesn't import itself.
  defp cross_rewrite_and_import_entries(rewrite_entry, %{module: target}, %{target_module: target}),
       do: [rewrite_entry]

  defp cross_rewrite_and_import_entries(rewrite_entry, e, ctx) do
    import_entry =
      {e.module, {:import, {ctx.target_module, [{ctx.helper_name, length(ctx.final_args)}]}}}

    [rewrite_entry, import_entry]
  end

  defp drop_meta(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) -> {form, [], args}
      other -> other
    end)
  end

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

  defp excluded_path?(path?) do
    normalized = String.trim_leading(path?, "./")
    @excluded_path_prefixes |> Enum.any?(&String.starts_with?(normalized, &1))
  end

  defp extract_from_ast(ast, path, min_mass) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        functions_in_module_node(name_ast, body, path, min_mass)

      _ ->
        []
    end)
  end

  defp functions_in_module_node(name_ast, body, path, min_mass) do
    case alias_to_module(name_ast) do
      {:ok, mod} -> functions_in_resolved_module(mod, body, path, min_mass)
      :error -> []
    end
  end

  # `*.Shared` modules are this refactor's own output (and
  # `ExtractSharedModule`'s). Re-scanning them would extract
  # functions we already extracted and inject imports pointing
  # at the same module being defined — a self-import that
  # fails to compile.
  defp functions_in_resolved_module(mod, body, path, min_mass) do
    if shared_module?(mod) do
      []
    else
      functions_in_module(mod, body_to_exprs(body), path, min_mass)
    end
  end

  defp extract_from_parse_result_for_path({:ok, ast}, min_mass, path),
    do: ast |> extract_from_ast(path, min_mass)

  defp extract_from_parse_result_for_path({:error, _}, _min_mass, _path), do: []

  defp extract_module_info({path, source}, min_mass),
    do: Sourceror.parse_string(source) |> extract_from_parse_result_for_path(min_mass, path)

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

  defp first_body_expr([first | _]), do: first
  defp first_body_expr([]), do: nil

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

  defp head_has_guard?({:when, _, _}), do: true
  defp head_has_guard?(_), do: false

  defp helper_already_present?(body_exprs, name, arity) do
    body_exprs
    |> Enum.any?(fn
      {kind, _, [head | _]} when kind in [:def, :defp] ->
        match?({^name, args} when length(args) == arity, extract_fn_signature(head))

      _ ->
        false
    end)
  end

  defp helper_append_patches(%{end: end_pos}, helpers) do
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

  defp helper_append_patches(_, _helpers), do: []

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

  defp holes_land_on_map_keys?(skeleton, holes) do
    key_paths = collect_map_key_paths(skeleton)

    holes |> Enum.any?(&MapSet.member?(key_paths, &1.path))
  end

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

  defp indent_lines(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end

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

  defp insert_helpers_patch(mod_node, helpers),
    do: Sourceror.get_range(mod_node) |> helper_append_patches(helpers)

  defp invert_alpha(mod),
    do:
      mod
      |> inspect()
      |> String.to_charlist()
      |> Enum.map(&(-&1))

  defp invert_atom(atom), do: atom |> Atom.to_string() |> String.to_charlist() |> Enum.map(&(-&1))

  defp is_atom_var?(atom) when is_atom(atom) do
    string = Atom.to_string(atom)

    Regex.match?(~r/^[a-z_][a-zA-Z0-9_]*[?!]?$/, string) and
      string not in ["true", "false", "nil"]
  end

  defp keyword_list_pairs?([]), do: false

  defp keyword_list_pairs?(list) do
    list
    |> Enum.all?(fn
      {key, _value} -> atom_shaped_key?(key)
      _ -> false
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

  defp load_default_sources,
    do: File.read(".refactor.exs") |> parse_inputs_from_config()

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

  defp merge_attrs(infos) do
    infos
    |> Enum.flat_map(&Map.to_list(&1.attrs))
    # Later entries don't overwrite earlier ones; we already verified
    # attrs match across clone modules at emit-time.
    |> Enum.uniq_by(fn {name, _} -> name end)
    |> Map.new()
  end

  defp merge_import_specs(imported_specs) do
    imported_specs
    |> Enum.group_by(fn {target, _} -> target end, fn {_, only} -> only end)
    |> Enum.map(fn {target, only_lists} ->
      {target, only_lists |> List.flatten() |> Enum.uniq() |> Enum.sort()}
    end)
  end

  defp merge_imports(infos) do
    infos
    |> Enum.flat_map(& &1.imports)
    |> Enum.uniq_by(fn {k, _} -> k end)
    |> Enum.sort_by(fn {k, _} -> k end)
  end

  defp merge_migrated_helpers(infos),
    do:
      infos
      |> Enum.flat_map(& &1.migrated_helpers)
      |> Enum.uniq_by(&strip_meta/1)

  defp module_already_imports?(body_exprs, target) do
    body_exprs
    |> Enum.any?(fn
      {:import, _, [{:__aliases__, _, parts}]} -> Module.concat(parts) == target
      {:import, _, [{:__aliases__, _, parts}, _]} -> Module.concat(parts) == target
      _ -> false
    end)
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

  defp name_arity_or_sentinel({name, _, args}) when is_list(args) do
    {name, length(args)}
  end

  defp name_arity_or_sentinel({name, _, nil}), do: {name, 0}
  defp name_arity_or_sentinel(_), do: {nil, -1}

  defp node_count(ast) do
    {_, count} = Macro.prewalk(ast, 0, fn node, acc -> {node, acc + 1} end)
    count
  end

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

  defp outer_holes_contain_captures?(outer_holes) do
    outer_holes
    |> Enum.any?(fn hole ->
      hole.values |> Enum.any?(&ast_contains_capture_ref?/1)
    end)
  end

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

  defp patch_for_range(%{end: end_pos, start: start_pos}, replacement),
    do: [%{change: replacement, range: %{end: end_pos, start: start_pos}}]

  defp patch_for_range(_, _replacement), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

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

    if holes_land_on_map_keys?(skeleton, holes) do
      # Map keys (and keyword-list keys) are nearly always semantically
      # load-bearing. Two helpers that only differ in their map keys
      # are not really clones — they construct different things.
      # Consolidating them produces a misleading helper name and
      # actively misleading parameter names (`%{name => …, logo_asset_id => …}`
      # called for a mass-asset).
      {[], state}
    else
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

  defp plan_from_sources([], _opts), do: :no_cache
  defp plan_from_sources(sources, opts), do: {:ok, build_plan(sources, opts)}

  defp prepared_for_paths(nil, opts),
    do: load_default_sources() |> plan_from_sources(opts)

  defp prepared_for_paths(paths, opts) when is_list(paths) do
    sources = paths |> Enum.map(fn p -> {p, File.read!(p)} end)
    {:ok, build_plan(sources, opts)}
  end

  defp process_cross_writes(plan_entries, write_root, source_paths) do
    cross_helpers =
      plan_entries
      |> Enum.flat_map(fn
        {mod, {:cross_helper, info}} -> [{mod, info}]
        _ -> []
      end)
      |> Enum.group_by(fn {mod, _} -> mod end, fn {_, info} -> info end)

    cross_helpers
    |> Enum.each(fn {target, infos} ->
      write_cross_helper_file(target, infos, write_root, source_paths)
    end)
  end

  defp prune_unused_imports(imports, body_calls) do
    call_names = MapSet.new(body_calls, fn {name, _arity} -> name end)

    imports
    |> Enum.flat_map(fn {key, ast} -> prune_import(key, ast, call_names) end)
  end

  # Full `import Mod` — keep only when at least one unqualified call in
  # the body could plausibly resolve through it. Without function-export
  # metadata we can't know for sure, so we err on the conservative side:
  # drop only when the body has no unqualified calls at all, otherwise keep.
  defp prune_import(key, ast, call_names) do
    case import_only_pairs(ast) do
      :no_only ->
        if MapSet.size(call_names) == 0, do: [], else: [{key, ast}]

      {:ok, pairs} ->
        prune_only_import(key, ast, pairs, call_names)
    end
  end

  defp prune_only_import(key, ast, pairs, call_names) do
    used_pairs = pairs |> Enum.filter(fn {n, _a} -> MapSet.member?(call_names, n) end)

    cond do
      used_pairs == [] -> []
      used_pairs == pairs -> [{key, ast}]
      true -> [{key, rebuild_only_import(ast, used_pairs)}]
    end
  end

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

  defp reachable_helper_clauses(body_exprs, target_name, target_arity) do
    definitions = collect_definitions(body_exprs)

    target_calls =
      definitions
      |> Enum.find(&target_def?(&1, target_name, target_arity))
      |> target_calls_or_empty()

    call_graph =
      for d <- definitions do
        {{d.name, d.arity}, d.calls}
      end
      |> Map.new()

    reachable_from_target = transitive_closure(target_calls, call_graph)

    other_def_roots =
      definitions
      |> Enum.filter(&other_def_root?(&1, target_name, target_arity))
      |> Enum.map(&{&1.name, &1.arity})
      |> MapSet.new()

    reachable_from_others = transitive_closure(other_def_roots, call_graph)

    migratable =
      definitions
      |> Enum.filter(&migratable_defp?(&1, reachable_from_target, reachable_from_others))

    conflicting? =
      definitions
      |> Enum.any?(&conflicting_defp?(&1, reachable_from_target, reachable_from_others))

    migratable_clauses = migratable |> Enum.flat_map(& &1.clauses)
    {migratable_clauses, conflicting?}
  end

  defp target_def?(d, target_name, target_arity),
    do: d.kind in [:def, :defp] and d.name == target_name and d.arity == target_arity

  defp target_calls_or_empty(nil), do: MapSet.new()
  defp target_calls_or_empty(d), do: d.calls

  defp other_def_root?(d, target_name, target_arity),
    do: d.kind == :def and not (d.name == target_name and d.arity == target_arity)

  defp migratable_defp?(d, reachable_from_target, reachable_from_others),
    do:
      d.kind == :defp and
        MapSet.member?(reachable_from_target, {d.name, d.arity}) and
        not MapSet.member?(reachable_from_others, {d.name, d.arity})

  defp conflicting_defp?(d, reachable_from_target, reachable_from_others),
    do:
      d.kind == :defp and
        MapSet.member?(reachable_from_target, {d.name, d.arity}) and
        MapSet.member?(reachable_from_others, {d.name, d.arity})

  defp read_existing_function_keys(path, target_module) do
    with true <- File.exists?(path),
         {:ok, source} <- File.read(path),
         {:ok, ast} <- Sourceror.parse_string(source),
         {:ok, body_exprs} <- find_module_body(ast, target_module) do
      function_keys_from_exprs(body_exprs)
    else
      _ -> MapSet.new()
    end
  end

  defp function_keys_from_exprs(body_exprs) do
    body_exprs
    |> Enum.flat_map(&function_key_for_clause/1)
    |> MapSet.new()
  end

  defp function_key_for_clause({kind, _, [head | _]}) when kind in [:def, :defp] do
    case extract_fn_signature(head) do
      {name, args} when is_list(args) -> [{name, length(args)}]
      _ -> []
    end
  end

  defp function_key_for_clause(_), do: []

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

  defp render_attributes(map) when map == %{}, do: ""

  defp render_attributes(map) do
    map
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map_join("\n", fn {name, value_ast} ->
      "@#{name} #{value_ast |> strip_comments() |> Sourceror.to_string()}"
    end)
  end

  # A parameter name for the threaded-in module, not colliding with
  # any existing helper arg or body-bound var. `module` is the natural
  # first choice; `resolve_name_collision` appends a digit if taken.
  defp fresh_module_var(helper_args, all_bound) do
    taken = MapSet.new(helper_args) |> MapSet.union(all_bound)
    resolve_name_collision(:module, taken, 0)
  end

  # Rewrite lexical `__MODULE__` references in a cross-file helper body
  # so the body is correct in the `*.Shared` module it gets lifted into:
  #
  #   %__MODULE__{a: x}  →  struct!(module, a: x)
  #   {__MODULE__, x}    →  {module, x}   (bare reference)
  #
  # `%__MODULE__{...}` can't become `%module{...}` — that's struct
  # *pattern* syntax, not construction — so it lowers to `struct!/2`
  # (raises on unknown keys, matching the original struct literal's
  # strictness). The struct's `{:%{}, _, pairs}` already carries the
  # field pairs as a keyword list, reused verbatim as `struct!/2`'s
  # second argument.
  defp parametrize_module_macro(ast, module_var) do
    Macro.prewalk(ast, fn
      {:%, meta, [{:__MODULE__, _, ctx}, {:%{}, _, pairs}]} when is_atom(ctx) ->
        {:struct!, meta, [{module_var, [], nil}, pairs]}

      {:__MODULE__, _, ctx} when is_atom(ctx) ->
        {module_var, [], nil}

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

  defp render_clause_head({kind, _, [head, _body]}, r) do
    head_str = head |> strip_comments() |> Sourceror.to_string()
    "#{kind} #{head_str}"
  rescue
    _ -> "#{r.kind} #{r.name}(#{r.args |> Enum.join(", ")})"
  end

  defp render_clause_head(_, r), do: "#{r.kind} #{r.name}(#{r.args |> Enum.join(", ")})"

  defp render_fresh_helper_module(target, infos) do
    body = render_target_body(infos)
    indented = indent_lines(body, "  ")

    """
    defmodule #{inspect(target)} do
    #{indented}
    end
    """
  end

  defp render_helper(%{args: args, body_ast: body_ast, kind: kind, name: name}) do
    arg_list = args |> Enum.join(", ")
    body_string = body_ast |> strip_comments() |> Sourceror.to_string()

    if String.contains?(body_string, "\n") do
      indented_body = indent_lines(body_string, "  ")
      "#{kind} #{name}(#{arg_list}) do\n#{indented_body}\nend"
    else
      "#{kind} #{name}(#{arg_list}), do: #{body_string}"
    end
  end

  defp render_helper_defs([]), do: ""

  defp render_helper_defs(helper_defs),
    do: helper_defs |> Enum.map_join("\n\n", &render_public_helper/1)

  defp render_imports([]), do: ""

  defp render_imports(imports) do
    imports
    |> Enum.map_join("\n", fn {_key, ast} ->
      ast |> strip_comments() |> Sourceror.to_string()
    end)
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

  defp render_migrated_helpers([]), do: ""

  defp render_migrated_helpers(clauses) do
    clauses
    |> Enum.map_join("\n\n", fn clause ->
      clause |> strip_comments() |> Sourceror.to_string()
    end)
  end

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

  defp render_target_body_for_append(source, infos),
    do: Sourceror.parse_string(source) |> render_target_or_apply(infos)

  defp render_target_or_apply({:error, _}, infos), do: infos |> render_target_body()

  defp render_target_or_apply({:ok, ast}, infos) do
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

  defp resolve_name_collision(name, taken, idx) do
    if MapSet.member?(taken, name) do
      first_free_suffixed_name(name, taken) || :"param_#{idx}"
    else
      name
    end
  end

  defp first_free_suffixed_name(name, taken) do
    2
    |> Stream.iterate(&(&1 + 1))
    |> Enum.find_value(&free_suffixed_candidate(name, &1, taken))
  end

  defp free_suffixed_candidate(name, n, taken) do
    candidate = :"#{name}_#{n}"
    if MapSet.member?(taken, candidate), do: nil, else: candidate
  end

  defp rewrite(source, plan),
    do: Sourceror.parse_string(source) |> apply_plan_to_parse_result(plan, source)

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

  defp rewrite_with_plan_or_passthrough(nil, source), do: source
  defp rewrite_with_plan_or_passthrough(plan, source), do: source |> rewrite(plan)

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

    function_keys = function_keys_from_exprs(body_exprs)

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

  defp shared_module?(module), do: module |> Module.split() |> List.last() == "Shared"

  defp signature_or_skip({name, args}, kind) when is_list(args) do
    {kind, name, length(args)}
  end

  defp signature_or_skip(_, _kind), do: :__skip__

  defp skeleton_hash(body_ast),
    do:
      body_ast
      |> inline_pipes()
      |> normalize_skeleton()
      |> :erlang.phash2()

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

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
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

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

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

  defp target_from_concentration_or_suffix({:ok, mod}, _by_module, _entries), do: {:intra, mod}

  defp target_from_concentration_or_suffix(:none, by_module, entries),
    do: first_suffix_match(by_module) |> target_from_suffix_or_lcp(entries)

  defp target_from_lcp_or_skip({:ok, mod}), do: {:lcp_shared, mod}
  defp target_from_lcp_or_skip(:skip), do: :skip
  defp target_from_suffix_or_lcp({:ok, mod}, _entries), do: {:suffix, mod}

  defp target_from_suffix_or_lcp(:none, entries),
    do: lcp_shared_module(entries) |> target_from_lcp_or_skip()

  defp unblock_atom_for_import({:__block__, _, [a]}) when is_atom(a), do: a
  defp unblock_atom_for_import(a) when is_atom(a), do: a
  defp unblock_atom_for_import(_), do: nil
  defp unblock_integer_for_import({:__block__, _, [n]}) when is_integer(n), do: n
  defp unblock_integer_for_import(n) when is_integer(n), do: n
  defp unblock_integer_for_import(_), do: nil
  defp unblock_list_for_import({:__block__, _, [list]}) when is_list(list), do: list
  defp unblock_list_for_import(list) when is_list(list), do: list
  defp unblock_list_for_import(_), do: []

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

  defp unwrap_keyword([{k, v} | rest]), do: [{k, v} | rest]
  defp unwrap_keyword(other), do: other

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

  defp var_name_or_error({:ok, name}), do: {:ok, name}
  defp var_name_or_error(:skip), do: :error

  defp write_cross_helper_file(target, infos, write_root, source_paths) do
    path = shared_module_path(target, write_root, source_paths)
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
end
