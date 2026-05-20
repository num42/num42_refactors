defmodule Num42.Refactors.Refactors.DelegateExactDuplicates do
  @moduledoc """
  Replaces exact-duplicate public functions across modules with
  `defdelegate` to a single canonical implementation.

      # before
      defmodule MyApp.Items do
        def assign(scope, attrs) do
          ...big shared body...
        end
      end

      defmodule MyApp.Items.Positions do
        def assign(scope, attrs) do
          ...same big shared body...
        end
      end

      # after
      defmodule MyApp.Items do
        defdelegate assign(scope, attrs), to: MyApp.Items.Positions
      end

      defmodule MyApp.Items.Positions do
        def assign(scope, attrs) do
          ...big shared body...
        end
      end

  ## Winner selection

  When N modules share the same function, the **longest module name**
  (most segments) keeps the implementation. Ties are broken by
  alphabetical order — the alphabetically *later* module wins, so the
  result is deterministic across runs.

  Example: `MyApp.A`, `MyApp.A.B`, `MyApp.A.B.C` → `C` keeps the body,
  `A` and `B` get `defdelegate ..., to: MyApp.A.B.C`.

  ## Cross-file context (`prepare/1`)

  Detecting duplicates requires seeing every input file, not just the
  one being rewritten. The engine calls `prepare/1` once per pipeline
  run; we read every source listed in `opts[:source_files]` (defaults
  to the project's `.refactoring.exs` `:inputs` glob), parse each,
  hash every public function body, and emit a per-module rewrite plan.
  `transform/2` then just looks up the plan for the current module.

  When called outside the engine (e.g. test helpers, `mix refactor
  --only DelegateExactDuplicates lib/foo.ex` with a single file), the
  plan can also be computed inline by passing
  `opts[:prepared] = build_plan(sources)` where `sources` is a list of
  `{path, source_string}` tuples.

  ## Match criteria

  Two function definitions are considered the **same** when:

    1. They share `{name, arity}` and `kind == :def` (public only —
       `defp` can't be `defdelegate`'d, `defmacro`/`defmacrop` neither).
    2. All clauses (in order) hash identically after AST normalization
       — meta is stripped, variables are positionally renamed (`a, b
       -> $0, $1`), so cosmetic differences don't matter.
    3. Heads contain only **plain variable arguments**: no
       `%Struct{} = x`, no defaults `\\\\`, no `when`-guards. These
       can't be expressed as `defdelegate name(arg, ...)` without
       semantic loss — skip rather than guess.
    4. Bodies don't reference module attributes (`@foo`). Those would
       break after delegation since the attribute is per-module.
    5. Body has at least 5 AST nodes (`min_mass`). Tiny bodies aren't
       worth the indirection.

  ## What we skip

  - Single-occurrence functions (no duplicate to delegate to)
  - Mixed kinds (one `def`, one `defp` — not eligible)
  - Multi-clause groups where any clause fails the criteria above
  - Functions whose loser-side body uses module attributes the winner
    doesn't define
  - Cycles: A delegates to B which would delegate to A (we never plan
    this, but defensive).

  ## Format

  After rewriting, `reformat_after?/0 == true` so the engine runs `mix
  format` to normalize whitespace produced by the patch insertion.
  """

  use Num42.Refactors.Refactor

  @default_min_mass 20

  # Path patterns excluded from cross-file matching. The default-source
  # loader filters them out because:
  #
  # - test/ — fixtures often define stub modules with identical bodies
  #   on purpose; delegating between them changes test semantics.
  # - dev/refactors/refactors/ — refactor modules are auto-discovered
  #   via filename → module-name; delegating a refactor's `transform/2`
  #   to another refactor would silently swap implementations.
  @excluded_path_prefixes ["test/", "dev/"]

  @impl Num42.Refactors.Refactor
  def description, do: "Cross-file: replace exact duplicates with defdelegate"

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    Same function body in two modules → keep the implementation in the
    module with the longer name, replace the others with
    `defdelegate name(args), to: WinnerModule`. Reduces duplication
    without forcing a structural extraction; downstream callers don't
    notice the rename because `defdelegate` preserves the public
    contract.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Num42.Refactors.Refactor
  def prepare(opts), do: Keyword.get(opts, :source_files) |> handle_prepare_get()

  @impl Num42.Refactors.Refactor
  def transform(source, opts), do: Keyword.get(opts, :prepared) |> handle_transform_get(source)

  @doc """
  Build a rewrite plan from a list of `{path, source_string}` pairs.

  The plan is a map keyed by module atom. Each value is a list of
  `{name, arity, args, winner_module}` entries describing which
  functions in that module should be replaced with a defdelegate.
  Modules absent from the map need no rewrite.

  Exposed publicly so tests can construct a plan inline without the
  full pipeline. The engine calls it indirectly via `prepare/1`.
  """
  @spec build_plan([{String.t(), String.t()}], keyword()) :: %{
          module() => [{atom(), arity(), [atom()], module()}]
        }
  def build_plan(sources, opts \\ []) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)

    sources
    |> Enum.reject(fn {path, _src} -> excluded_path?(path) end)
    |> Enum.flat_map(&extract_functions(&1, min_mass))
    |> Enum.group_by(fn entry -> {entry.name, entry.arity, entry.hash} end)
    |> Enum.flat_map(&plan_for_group/1)
    |> Enum.group_by(fn {loser_module, _entry} -> loser_module end, fn {_loser, entry} ->
      entry
    end)
  end

  # ---- Plan building --------------------------------------------------

  defp plan_for_group({{_name, _arity, _hash}, [_only]}), do: []

  defp plan_for_group({{name, arity, _hash}, entries}) do
    # All entries share `{name, arity, hash}`. Pick a winner by module-
    # name length (more segments = longer = winner). Tie-break by
    # alphabetical order, alphabetically later wins.
    winner = entries |> Enum.max_by(&{module_segments(&1.module), Atom.to_string(&1.module)})

    entries
    |> Enum.reject(&(&1.module == winner.module))
    |> Enum.map(fn loser -> {loser.module, {name, arity, loser.args, winner.module}} end)
  end

  defp module_segments(module) when is_atom(module) do
    module |> Module.split() |> length()
  end

  # ---- Source extraction ----------------------------------------------

  # Returns a list of %{module:, name:, arity:, args:, hash:, clause_asts:}
  # entries — one per public function group in `source`. Multi-clause
  # functions are collapsed into a single entry whose hash combines all
  # clauses; that way `def foo(0)` + `def foo(n)` is treated atomically.
  defp extract_functions({_path, source}, min_mass),
    do: Sourceror.parse_string(source) |> handle_parse_string(min_mass)

  defp extract_functions_from_ast(ast, min_mass) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, mod} -> functions_in_module(mod, body_to_exprs(body), min_mass)
          :error -> []
        end

      _ ->
        []
    end)
  end

  defp functions_in_module(module, body_exprs, min_mass) do
    body_exprs
    |> Enum.filter(&def_clause?/1)
    |> Enum.group_by(&def_name_arity_or_skip/1)
    |> Enum.reject(fn {key, _clauses} -> key == :skip end)
    |> Enum.flat_map(fn {{name, arity}, clauses} ->
      build_function_entry(module, name, arity, clauses, body_exprs, min_mass)
    end)
  end

  defp def_clause?({:def, _, [_head | _]}), do: true
  defp def_clause?(_), do: false

  defp def_name_arity_or_skip({:def, _, [head | _]}), do: strip_when(head) |> handle_strip_when()

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp build_function_entry(module, name, arity, clauses, body_exprs, min_mass) do
    cond do
      not Enum.all?(clauses, &eligible_clause?/1) ->
        []

      total_mass(clauses) < min_mass ->
        []

      body_uses_module_attribute?(clauses) ->
        []

      true ->
        # Args of the first clause define the delegate signature. Since
        # we already filtered to plain-variable heads, every clause has
        # the same arg names by structural equality (different clauses
        # may bind different names — that's fine for the body hash, but
        # for the delegate we just take clause-1's names).
        args = clause_arg_names(hd(clauses))
        hashed_clause = hash_clauses(clauses)

        [
          %{
            args: args,
            arity: arity,
            body_exprs: body_exprs,
            hash: hashed_clause,
            module: module,
            name: name
          }
        ]
    end
  end

  # ---- Clause eligibility ---------------------------------------------

  defp eligible_clause?({:def, _, [head | _]} = node) do
    case strip_when(head) do
      ^head ->
        # No `when` wrapper. Check that all args are plain vars and no
        # defaults are present. Body check happens via `body_uses_module_attribute?/1`.
        args_are_plain_vars?(head)

      _stripped ->
        # Has a `when`-guard — skip.
        false
    end
    |> drop_node_arg(node)
  end

  defp drop_node_arg(value, _node), do: value

  defp args_are_plain_vars?({_name, _, args}) when is_list(args) do
    args |> Enum.all?(&plain_var?/1)
  end

  defp args_are_plain_vars?({_name, _, nil}), do: true
  defp args_are_plain_vars?(_), do: false

  defp plain_var?({:\\, _, _}), do: false

  defp plain_var?({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    not underscore?(name)
  end

  defp plain_var?(_), do: false

  defp clause_arg_names({:def, _, [head | _]}), do: head |> strip_when() |> head_arg_names()

  defp head_arg_names({_name, _, args}) when is_list(args) do
    args |> Enum.map(fn {n, _, _} -> n end)
  end

  defp head_arg_names({_name, _, nil}), do: []

  # ---- Body inspection ------------------------------------------------

  defp body_uses_module_attribute?(clauses),
    do: clauses |> Enum.any?(&clause_references_attribute?/1)

  defp clause_references_attribute?({:def, _, [_head, body_kw]}),
    do:
      body_kw
      |> Keyword.values()
      |> Enum.any?(&references_attribute?/1)

  defp references_attribute?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:@, _, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) -> true
      _ -> false
    end)
  end

  # ---- Hashing --------------------------------------------------------

  defp hash_clauses(clauses),
    do:
      clauses
      |> Enum.map(&normalize_clause/1)
      |> :erlang.phash2()

  defp normalize_clause({:def, _, [head, body_kw]}) do
    # Strip meta and rename variables positionally. Result is a pure
    # structural fingerprint: same shape, same vars, regardless of
    # naming or location.
    stripped_head = strip_meta(head)
    stripped_body = body_kw |> Keyword.values() |> Enum.map(&strip_meta/1)
    rename_vars({stripped_head, stripped_body})
  end

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  # Walk the AST, build a {var_name -> positional_index} map, and
  # replace every variable occurrence with `{:"$var", [], idx}`. This
  # makes `(a, b) -> a + b` and `(x, y) -> x + y` hash identically.
  defp rename_vars(ast) do
    {result, _map} = Macro.prewalk(ast, %{}, &rename_var_node/2)
    result
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

  defp total_mass(clauses), do: clauses |> Enum.map(&clause_mass/1) |> Enum.sum()

  defp clause_mass({:def, _, [_head, body_kw]}),
    do:
      body_kw
      |> Keyword.values()
      |> Enum.map(&node_count/1)
      |> Enum.sum()

  defp node_count(ast) do
    {_, count} = Macro.prewalk(ast, 0, fn node, acc -> {node, acc + 1} end)
    count
  end

  # ---- Per-file rewrite -----------------------------------------------

  defp rewrite(source, plan),
    do: Sourceror.parse_string(source) |> handle_parse_string_2(plan, source)

  defp apply_plan_to_ast(ast, source, plan) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, mod} -> patches_for_module(mod, body_to_exprs(body), plan)
          :error -> []
        end

      _ ->
        []
    end)
    |> patch_or_passthrough(source)
  end

  defp patches_for_module(module, body_exprs, plan),
    do: Map.get(plan, module) |> handle_patches_for_module_get(body_exprs)

  # Find defps that, after delegation, are only reachable from the
  # functions we just delegated away. They become unused — emit delete
  # patches for them.
  #
  # Algorithm:
  # 1. Build a call graph: for each def/defp, what {name, arity} pairs
  #    does its body reference?
  # 2. Mark "live roots" — every def NOT being delegated away.
  # 3. Compute the transitive closure of live roots over the call graph
  #    (which {name, arity} pairs are reachable from any live def).
  # 4. Any defp not in the closure is dead — emit a patch removing its
  #    entire clause group.
  defp dead_helper_patches(body_exprs, delegated_entries) do
    delegated_set =
      delegated_entries
      |> Enum.map(fn {name, arity, _args, _winner} -> {name, arity} end)
      |> MapSet.new()

    definitions = collect_definitions(body_exprs)

    live_roots =
      definitions
      |> Enum.filter(fn %{arity: arity, kind: kind, name: name} ->
        kind == :def and not MapSet.member?(delegated_set, {name, arity})
      end)
      |> Enum.map(&{&1.name, &1.arity})
      |> MapSet.new()

    call_graph =
      for def_info <- definitions do
        {{def_info.name, def_info.arity}, def_info.calls}
      end
      |> Map.new()

    reachable = transitive_closure(live_roots, call_graph)

    definitions
    |> Enum.filter(fn %{arity: arity, kind: kind, name: name} ->
      kind == :defp and not MapSet.member?(reachable, {name, arity})
    end)
    |> Enum.flat_map(&delete_patch_for/1)
  end

  defp collect_definitions(body_exprs) do
    body_exprs
    |> Enum.filter(fn
      {kind, _, [_head | _]} when kind in [:def, :defp] -> true
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

  defp collect_calls_in_clauses(clauses) do
    clauses
    |> Enum.flat_map(fn {_kind, _, [_head, body_kw]} ->
      body_kw |> Keyword.values() |> Enum.flat_map(&collect_calls/1)
    end)
    |> MapSet.new()
  end

  # Walk the AST and collect every local call shape {name, arity}.
  # We record:
  # - direct calls:        foo(x, y)            → {:foo, 2}
  # - pipe targets:        x |> foo(y)          → {:foo, 2}  (NOT 1)
  # - captures:            &foo/2               → {:foo, 2}
  # We deliberately do NOT chase remote calls (Foo.bar(x)) — those
  # don't reference local helpers. Pipe rhs are handled specially: the
  # rhs `foo(y)` parses as a 1-arg call, but the actual call site is
  # 2-arg (the lhs flows in as arg 0). To avoid double-counting we
  # mark every pipe rhs and skip its naked-call accounting in the
  # generic clause.
  defp collect_calls(ast) do
    {_, pipe_rhs_set} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:|>, _, [_lhs, rhs]} = node, acc -> {node, MapSet.put(acc, rhs)}
        node, acc -> {node, acc}
      end)

    {_, calls} =
      Macro.prewalk(ast, [], fn
        {:|>, _, [_lhs, rhs]} = node, acc ->
          # Record the rhs with arity+1.
          case rhs do
            {{:., _, [_remote, _name]}, _, _} ->
              # Remote call on rhs — skip.
              {node, acc}

            {name, _, args} when is_atom(name) and is_list(args) ->
              if local_call_candidate?(name) do
                {node, [{name, length(args) + 1} | acc]}
              else
                {node, acc}
              end

            {name, _, nil} when is_atom(name) ->
              if local_call_candidate?(name) do
                {node, [{name, 1} | acc]}
              else
                {node, acc}
              end

            _ ->
              {node, acc}
          end

        {:&, _, [{:/, _, [{name, _, ctx}, arity]}]} = node, acc
        when is_atom(name) and is_atom(ctx) and is_integer(arity) ->
          {node, [{name, arity} | acc]}

        {:&, _, [{:/, _, [{name, _, ctx}, {:__block__, _, [arity]}]}]} = node, acc
        when is_atom(name) and is_atom(ctx) and is_integer(arity) ->
          {node, [{name, arity} | acc]}

        {name, _, args} = node, acc
        when is_atom(name) and is_list(args) ->
          cond do
            MapSet.member?(pipe_rhs_set, node) ->
              # Already accounted for in the |> branch above with
              # the corrected arity.
              {node, acc}

            local_call_candidate?(name) ->
              {node, [{name, length(args)} | acc]}

            true ->
              {node, acc}
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

  defp transitive_closure(roots, graph),
    do: roots |> transitive_closure_step(graph, MapSet.to_list(roots))

  defp transitive_closure_step(reached, _graph, []), do: reached

  defp transitive_closure_step(reached, graph, [current | rest]) do
    callees = Map.get(graph, current, MapSet.new())

    new_callees =
      callees
      |> Enum.reject(&MapSet.member?(reached, &1))

    next_reached = new_callees |> Enum.reduce(reached, &MapSet.put(&2, &1))
    transitive_closure_step(next_reached, graph, rest ++ new_callees)
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

  defp patch_for_function(body_exprs, name, arity, args, winner) do
    clauses = body_exprs |> Enum.filter(&clause_matches?(&1, name, arity))

    case clauses do
      [] ->
        []

      [first | _] = list ->
        last = List.last(list)
        replacement = render_defdelegate(name, args, winner)
        build_clause_group_patch(first, last, replacement)
    end
  end

  defp clause_matches?({:def, _, [head | _]}, name, arity) do
    case strip_when(head) do
      {^name, _, args} when is_list(args) and length(args) == arity -> true
      {^name, _, nil} when arity == 0 -> true
      _ -> false
    end
  end

  defp clause_matches?(_, _, _), do: false

  defp render_defdelegate(name, args, winner) do
    args_src = args |> Enum.join(", ")
    "defdelegate #{name}(#{args_src}), to: #{inspect(winner)}"
  end

  defp build_clause_group_patch(first_node, last_node, replacement) do
    with %{start: start_pos} <- Sourceror.get_range(first_node),
         %{end: end_pos} <- Sourceror.get_range(last_node) do
      [
        %{
          change: replacement,
          range: %{end: end_pos, start: start_pos}
        }
      ]
    else
      _ -> []
    end
  end

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  # ---- Default source loading -----------------------------------------

  defp load_default_sources,
    do: File.read(".refactoring.exs") |> handle_load_default_sources_read()

  defp excluded_path?(path?) do
    normalized = String.trim_leading(path?, "./")
    @excluded_path_prefixes |> Enum.any?(&String.starts_with?(normalized, &1))
  end

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_prepare_get(nil), do: load_default_sources() |> handle_load_default_sources()

  defp handle_prepare_get(paths) when is_list(paths) do
    sources = paths |> Enum.map(fn p -> {p, File.read!(p)} end)
    {:ok, build_plan(sources)}
  end

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_transform_get(nil, source), do: source

  defp handle_transform_get(plan, source), do: source |> rewrite(plan)

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_parse_string({:ok, ast}, min_mass), do: ast |> extract_functions_from_ast(min_mass)

  defp handle_parse_string({:error, _}, _min_mass), do: []

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_strip_when({name, _, args}) when is_atom(name) and is_list(args) do
    {name, length(args)}
  end

  defp handle_strip_when({name, _, nil}) when is_atom(name) do
    {name, 0}
  end

  defp handle_strip_when(_), do: :skip

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_parse_string_2({:ok, ast}, plan, source), do: ast |> apply_plan_to_ast(source, plan)

  defp handle_parse_string_2({:error, _}, _plan, source), do: source

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_patches_for_module_get(nil, _body_exprs), do: []

  defp handle_patches_for_module_get(entries, body_exprs) do
    delegate_patches =
      entries
      |> Enum.flat_map(fn {name, arity, args, winner} ->
        patch_for_function(body_exprs, name, arity, args, winner)
      end)

    cleanup_patches = dead_helper_patches(body_exprs, entries)
    delegate_patches ++ cleanup_patches
  end

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
    |> Enum.map(fn path -> {path, File.read!(path)} end)
  end

  defp handle_load_default_sources_read(_), do: []

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_load_default_sources([]), do: :no_cache

  defp handle_load_default_sources(sources), do: {:ok, build_plan(sources)}
end
