defmodule Number42.Refactors.Ex.DelegateExactDuplicates do
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
  to the project's `.refactor.exs` `:inputs` glob), parse each,
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
    6. Their **transitive local-helper closures** are structurally
       identical. Two bodies can be AST-equal yet call a same-named local
       `defp` that does different work in each module (e.g. a private
       `list/2` querying a different source). Delegating would run the
       winner's helper for the loser's callers → wrong data or a crash on a
       missing key. Every private helper reachable from the candidate is
       hashed by name/arity and normalized body and folded into the match
       key. Public `def`s in the closure are not — delegation preserves the
       public contract wherever it lives.

  ## What we skip

  - Single-occurrence functions (no duplicate to delegate to)
  - Mixed kinds (one `def`, one `defp` — not eligible)
  - Multi-clause groups where any clause fails the criteria above
  - Functions whose loser-side body uses module attributes the winner
    doesn't define
  - Cycles: A delegates to B which would delegate to A (we never plan
    this, but defensive).
  - Functions a module **already delegates**: if the destination already
    has an AST-identical `defdelegate` (same name/arity/target), the
    insertion is skipped. This keeps the refactor idempotent — a second
    pass on its own output is a no-op rather than appending another
    identical delegation (#226).

  ## Format

  After rewriting, `reformat_after?/0 == true` so the engine runs `mix
  format` to normalize whitespace produced by the patch insertion.
  """

  use Number42.Refactors.Refactor

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

  @impl Number42.Refactors.Refactor
  def description, do: "Cross-file: replace exact duplicates with defdelegate"
  @impl Number42.Refactors.Refactor
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

  @impl Number42.Refactors.Refactor
  def prepare(opts), do: Keyword.get(opts, :source_files) |> prepared_for_paths()
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, opts),
    do: Keyword.get(opts, :prepared) |> rewrite_with_plan_or_passthrough(source)

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

  defp apply_plan_to_parse_result({:ok, ast}, plan, source),
    do: ast |> apply_plan_to_ast(source, plan)

  defp apply_plan_to_parse_result({:error, _}, _plan, source), do: source

  defp args_are_plain_vars?({_name, _, args}) when is_list(args) do
    args |> Enum.all?(&plain_var?/1)
  end

  defp args_are_plain_vars?({_name, _, nil}), do: true
  defp args_are_plain_vars?(_), do: false

  defp body_uses_module_attribute?(clauses),
    do: clauses |> Enum.any?(&clause_references_attribute?/1)

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

  defp build_function_entry(
         module,
         name,
         arity,
         clauses,
         body_exprs,
         min_mass,
         call_graph,
         defp_bodies
       ) do
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

        # The match key folds in the transitive local-helper closure: two
        # candidates match only when their own clauses AND every private
        # helper they reach are structurally identical.
        hashed_clause = hash_clauses(clauses)
        reached = closure_hash(name, arity, call_graph, defp_bodies)

        [
          %{
            args: args,
            arity: arity,
            body_exprs: body_exprs,
            hash: {hashed_clause, reached},
            module: module,
            name: name
          }
        ]
    end
  end

  defp clause_arg_names({:def, _, [head | _]}), do: head |> strip_when() |> head_arg_names()

  defp clause_mass({:def, _, [_head, body_kw]}),
    do:
      body_kw
      |> Keyword.values()
      |> Enum.map(&node_count/1)
      |> Enum.sum()

  defp clause_matches?({:def, _, [head | _]}, name, arity) do
    case strip_when(head) do
      {^name, _, args} when is_list(args) and length(args) == arity -> true
      {^name, _, nil} when arity == 0 -> true
      _ -> false
    end
  end

  defp clause_matches?(_, _, _), do: false

  defp clause_references_attribute?({:def, _, [_head, body_kw]}),
    do:
      body_kw
      |> Keyword.values()
      |> Enum.any?(&references_attribute?/1)

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

  defp def_clause?({:def, _, [_head | _]}), do: true
  defp def_clause?(_), do: false
  defp def_name_arity_or_skip({:def, _, [head | _]}), do: strip_when(head) |> name_arity_or_skip()

  defp delete_patch_for(%{clauses: [first | _] = clauses}) do
    last = List.last(clauses)

    with %{start: start_pos} <- Sourceror.get_range(first),
         %{end: end_pos} <- Sourceror.get_range(last) do
      [%{change: "", range: %{end: end_pos, start: start_pos}}]
    else
      _ -> []
    end
  end

  defp drop_node_arg(value, _node), do: value

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

  defp excluded_path?(path?) do
    normalized = String.trim_leading(path?, "./")
    @excluded_path_prefixes |> Enum.any?(&String.starts_with?(normalized, &1))
  end

  defp extract_functions({_path, source}, min_mass),
    do: Sourceror.parse_string(source) |> extract_functions_or_empty(min_mass)

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

  defp extract_functions_or_empty({:ok, ast}, min_mass),
    do: ast |> extract_functions_from_ast(min_mass)

  defp extract_functions_or_empty({:error, _}, _min_mass), do: []

  defp functions_in_module(module, body_exprs, min_mass) do
    # The module's local definitions and their call edges — used to hash the
    # transitive closure of local `defp`s each candidate reaches. Two public
    # bodies can be AST-identical yet call divergent local helpers (a
    # same-named `defp list/2` doing different work per module); delegating
    # then runs the wrong helper. Folding the closure into the match key
    # blocks that. See `closure_hash/3`.
    definitions = collect_definitions(body_exprs)
    call_graph = Map.new(definitions, fn d -> {{d.name, d.arity}, d.calls} end)
    defp_bodies = defp_body_hashes(definitions)

    body_exprs
    |> Enum.filter(&def_clause?/1)
    |> Enum.group_by(&def_name_arity_or_skip/1)
    |> Enum.reject(fn {key, _clauses} -> key == :skip end)
    |> Enum.flat_map(fn {{name, arity}, clauses} ->
      build_function_entry(
        module,
        name,
        arity,
        clauses,
        body_exprs,
        min_mass,
        call_graph,
        defp_bodies
      )
    end)
  end

  # `{name, arity} => structural body hash` for every local `defp`. A `def`
  # in the closure is a public contract that delegation preserves on its own,
  # so only private helpers need to match structurally.
  defp defp_body_hashes(definitions) do
    definitions
    |> Enum.filter(&(&1.kind == :defp))
    |> Map.new(fn d -> {{d.name, d.arity}, hash_clauses(d.clauses)} end)
  end

  # A structural fingerprint of every local `defp` transitively reachable
  # from `{name, arity}`. Reachability uses the module's local call graph;
  # the result hashes each reached private helper by name/arity *and* its
  # normalized body, so two modules match only when their candidate calls
  # the same private helpers AND those helpers are structurally identical.
  # Public `def`s reached in the closure are not hashed — delegation keeps
  # the public contract intact regardless of which module hosts it.
  defp closure_hash(name, arity, call_graph, defp_bodies) do
    MapSet.new([{name, arity}])
    |> transitive_closure(call_graph)
    |> MapSet.delete({name, arity})
    |> Enum.flat_map(fn key ->
      case Map.fetch(defp_bodies, key) do
        {:ok, body_hash} -> [{key, body_hash}]
        :error -> []
      end
    end)
    |> Enum.sort()
    |> :erlang.phash2()
  end

  # A bodiless multi-clause head (`defp foo(a, b)` with no `do`) has AST
  # `{:defp, _, [head]}` — no `body_kw`, so it carries nothing to hash and
  # would crash `normalize_clause/1`. Drop it before hashing; the real
  # clauses fingerprint the body on their own.
  defp hash_clauses(clauses),
    do:
      clauses
      |> Enum.filter(&clause_has_body?/1)
      |> Enum.map(&normalize_clause/1)
      |> :erlang.phash2()

  defp clause_has_body?({kind, _, [_head, _body_kw]}) when kind in [:def, :defp], do: true
  defp clause_has_body?(_), do: false

  defp head_arg_names({_name, _, args}) when is_list(args) do
    args |> Enum.map(fn {n, _, _} -> n end)
  end

  defp head_arg_names({_name, _, nil}), do: []

  defp load_default_sources,
    do: File.read(".refactor.exs") |> parse_inputs_from_config()

  defp module_patches(nil, _body_exprs), do: []

  defp module_patches(entries, body_exprs) do
    # Idempotence guard (#226): a module may already carry the delegation we
    # are about to emit — e.g. a prior pass delegated, then a leftover `def`
    # of the same name/arity was re-introduced. Re-inserting would accumulate
    # identical `defdelegate` clauses. Drop any entry the destination already
    # delegates so a second pass on our own output is a no-op.
    pending = Enum.reject(entries, &already_delegated?(&1, body_exprs))

    delegate_patches =
      pending
      |> Enum.flat_map(fn {name, arity, args, winner} ->
        patch_for_function(body_exprs, name, arity, args, winner)
      end)

    cleanup_patches = dead_helper_patches(body_exprs, pending)
    delegate_patches ++ cleanup_patches
  end

  defp already_delegated?({name, arity, _args, winner}, body_exprs),
    do: Enum.any?(body_exprs, &defdelegate_matches?(&1, name, arity, winner))

  defp defdelegate_matches?(
         {:defdelegate, _, [head, opts]},
         name,
         arity,
         winner
       )
       when is_list(opts) do
    delegate_head_matches?(head, name, arity) and delegate_target?(opts, winner)
  end

  defp defdelegate_matches?(_, _name, _arity, _winner), do: false

  defp delegate_head_matches?({name, _, args}, name, arity) when is_list(args),
    do: length(args) == arity

  defp delegate_head_matches?({name, _, nil}, name, 0), do: true
  defp delegate_head_matches?(_, _name, _arity), do: false

  defp delegate_target?(opts, winner) do
    case Keyword.get(unwrap_opts(opts), :to) do
      {:__aliases__, _, segments} -> Module.concat(segments) == winner
      _ -> false
    end
  end

  # Sourceror wraps keyword keys/values in `:__block__` nodes; unwrap to a
  # plain keyword list so `Keyword.get(opts, :to)` works on both Sourceror
  # and `Code.string_to_quoted` ASTs.
  defp unwrap_opts(opts) do
    Enum.map(opts, fn
      {{:__block__, _, [key]}, value} -> {key, value}
      {key, value} -> {key, value}
    end)
  end

  defp module_segments(module) when is_atom(module) do
    module |> Module.split() |> length()
  end

  defp name_arity_or_skip({name, _, args}) when is_atom(name) and is_list(args) do
    {name, length(args)}
  end

  defp name_arity_or_skip({name, _, nil}) when is_atom(name) do
    {name, 0}
  end

  defp name_arity_or_skip(_), do: :skip

  defp node_count(ast) do
    {_, count} = Macro.prewalk(ast, 0, fn node, acc -> {node, acc + 1} end)
    count
  end

  defp normalize_clause({kind, _, [head, body_kw]}) when kind in [:def, :defp] do
    # Strip meta and rename variables positionally. Result is a pure
    # structural fingerprint: same shape, same vars, regardless of
    # naming or location. Used for the delegate candidate's own `def`
    # clauses and for the private helpers in its transitive closure, so
    # both `:def` and `:defp` reach here.
    stripped_head = strip_meta(head)
    stripped_body = body_kw |> Keyword.values() |> Enum.map(&strip_meta/1)
    rename_vars({stripped_head, stripped_body})
  end

  defp parse_inputs_from_config({:ok, contents}) do
    {config, _} = Code.eval_string(contents)
    inputs = Map.get(config, :inputs, [])

    inputs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&excluded_path?/1)
    |> Enum.map(fn path -> {path, File.read!(path)} end)
  end

  defp parse_inputs_from_config(_), do: []

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

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  defp patches_for_module(module, body_exprs, plan),
    do: Map.get(plan, module) |> module_patches(body_exprs)

  defp plain_var?({:\\, _, _}), do: false

  defp plain_var?({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    not underscore?(name)
  end

  defp plain_var?(_), do: false
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

  defp plan_from_sources([]), do: :no_cache
  defp plan_from_sources(sources), do: {:ok, build_plan(sources)}
  defp prepared_for_paths(nil), do: load_default_sources() |> plan_from_sources()

  defp prepared_for_paths(paths) when is_list(paths) do
    sources = paths |> Enum.map(fn p -> {p, File.read!(p)} end)
    {:ok, build_plan(sources)}
  end

  defp references_attribute?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:@, _, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) -> true
      _ -> false
    end)
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
    {result, _map} = Macro.prewalk(ast, %{}, &rename_var_node/2)
    result
  end

  defp render_defdelegate(name, args, winner) do
    args_src = args |> Enum.join(", ")
    "defdelegate #{name}(#{args_src}), to: #{inspect(winner)}"
  end

  defp rewrite(source, plan),
    do: Sourceror.parse_string(source) |> apply_plan_to_parse_result(plan, source)

  defp rewrite_with_plan_or_passthrough(nil, source), do: source
  defp rewrite_with_plan_or_passthrough(plan, source), do: source |> rewrite(plan)

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other
  defp total_mass(clauses), do: clauses |> Enum.map(&clause_mass/1) |> Enum.sum()
end
