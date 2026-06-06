defmodule Number42.Refactors.Ex.FlattenDeepPipeBranch do
  @moduledoc """
  Factors a `case` whose branches are per-branch pipelines sharing a
  common head and tail into a shared pre-pipe, a branched dispatch
  `defp`, and a shared post-pipe.

      def run(x) do
        case x do
          :a -> x |> prep() |> step_a() |> finalize()
          :b -> x |> prep() |> step_b() |> finalize()
        end
      end
      ↓
      def run(x) do
        x
        |> prep()
        |> run_branch(x)
        |> finalize()
      end

      defp run_branch(piped, :a), do: piped |> step_a()
      defp run_branch(piped, :b), do: piped |> step_b()

  The shared `prep()` prefix and `finalize()` suffix are lifted out of
  the (mutually exclusive) branches; only the divergent middle stays
  per-branch, dispatched by a generated `defp` that re-matches the
  original branch patterns and threads the piped value as its leading
  argument.

  ## When this fires

  A `def`/`defp` body that is exactly one `case` where:

    * the scrutinee is a **bare variable** (so it isn't re-evaluated when
      threaded into the dispatch call),
    * every branch body is a single pipe expression starting from that
      same scrutinee variable,
    * all branches share a non-empty leading prefix **and** a non-empty
      trailing suffix of structurally identical pipe stages,
    * every branch has a non-empty divergent middle,
    * the shared prefix and suffix stages are **pure** (`pure?/1`) — they
      are hoisted to run around the dispatch, so they must be free of
      side effects,
    * no branch's divergent middle references a variable bound by that
      branch's own pattern.

  ## What we skip

    * Non-bare scrutinee (`case fetch(x)`) — would re-evaluate the source.
    * A branch not piping from the scrutinee, or not a pipe at all.
    * Fewer than two branches, or no shared prefix/suffix, or an empty
      divergent middle in any branch.
    * An effectful shared stage (`log!()`), where hoisting could change
      observable behaviour.
    * A `case` that is not the entire function body.
    * `defmacro`/`defmacrop`, or a head with an existing `when`-guard.

  ## Idempotence

  After factoring, the body is a flat pipe (`x |> prep() |>
  run_branch(x) |> finalize()`) — no longer a `case` — and the generated
  `run_branch` clauses have single-pipe bodies with no shared
  prefix/suffix to factor. A second pass finds no match.
  """

  use Number42.Refactors.Refactor

  @impl Number42.Refactors.Refactor
  def description,
    do: "Factor per-branch pipelines into shared pre/post pipes around a dispatch defp"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A `case` whose every branch is `x |> shared_head() |> branch_step()
    |> shared_tail()` buries the one stage that actually differs inside a
    wall of repeated head and tail stages. Hoisting the shared head and
    tail around a generated dispatch `defp` leaves a flat top-level pipe
    and isolates the divergence in named clauses. Only pure shared stages
    are hoisted and the bare-variable scrutinee is threaded unchanged, so
    evaluation order and effect count are preserved.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_to_parse(source)

  defp apply_to_parse({:ok, ast}, source), do: apply_to_ast(ast, source)
  defp apply_to_parse({:error, _}, source), do: source

  defp apply_to_ast(ast, source) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value(source, fn
      {:defmodule, _, _} = mod -> factor_module(mod, source)
      _ -> nil
    end)
  end

  defp factor_module(mod, source) do
    case module_body_exprs(mod) && eligible_patches(mod, source) do
      [_ | _] = patches -> Sourceror.patch_string(source, patches)
      _ -> nil
    end
  end

  defp eligible_patches(mod, _source) do
    existing_names = def_names(mod)

    mod
    |> module_body_exprs()
    |> Enum.flat_map(&factor_def(&1, existing_names))
  end

  defp factor_def({kind, _, [head, body_kw]} = node, existing_names)
       when kind in [:def, :defp] and is_list(body_kw) do
    with false <- has_when_guard?(head),
         {fn_name, [scrutinee_param]} <- extract_fn_signature(head),
         {:ok, scrutinee} <- bare_var(scrutinee_param),
         {:ok, body} <- do_body(body_kw),
         {:ok, branches} <- case_branches(body, scrutinee),
         {:ok, plan} <- build_plan(branches),
         helper = :"#{fn_name}_branch",
         false <- MapSet.member?(existing_names, helper) do
      build_patches(node, kind, fn_name, scrutinee, helper, plan)
    else
      _ -> []
    end
  end

  defp factor_def(_, _existing), do: []

  defp has_when_guard?({:when, _, _}), do: true
  defp has_when_guard?(_), do: false

  # The body must be exactly one `case scrutinee do ... end` over the
  # bare-variable scrutinee, with at least two branches that each pipe
  # from the scrutinee.
  defp case_branches(body, scrutinee) do
    with [{:case, _, [{^scrutinee, _, ctx}, [{_do, clauses}]]}] when is_atom(ctx) <-
           body_to_exprs(body),
         true <- is_list(clauses) and length(clauses) >= 2,
         {:ok, branches} <- decompose_branches(clauses, scrutinee) do
      {:ok, branches}
    else
      _ -> :skip
    end
  end

  # Each clause `pattern -> x |> s1 |> s2 |> ...` becomes
  # `%{pattern, stages}` where stages are the pipe RHS calls.
  defp decompose_branches(clauses, scrutinee) do
    clauses
    |> reduce_ok(fn
      {:->, _, [[pattern], pipe]} -> decompose_branch(pattern, pipe, scrutinee)
      _ -> :skip
    end)
  end

  defp decompose_branch(pattern, pipe, scrutinee) do
    with false <- guarded_pattern?(pattern),
         {:ok, head, stages} <- flatten_pipe(pipe),
         true <- var_ref?(head, scrutinee) do
      {:ok, %{pattern: pattern, stages: stages}}
    else
      _ -> :skip
    end
  end

  # A guarded branch (`pattern when guard ->`) can't be rendered as a
  # positional dispatch argument — the `when` belongs at clause level,
  # not inside the arg list. Skip rather than emit invalid syntax.
  defp guarded_pattern?({:when, _, _}), do: true
  defp guarded_pattern?(_), do: false

  # Flatten a left-nested `|>` chain into `{head, [stage1, stage2, ...]}`.
  defp flatten_pipe({:|>, _, [lhs, rhs]}) do
    case flatten_pipe(lhs) do
      {:ok, head, stages} -> {:ok, head, stages ++ [rhs]}
      :skip -> {:ok, lhs, [rhs]}
    end
  end

  defp flatten_pipe(_), do: :skip

  # Compute the shared prefix/suffix and the per-branch divergent middle,
  # gating on effect-free shared stages and pattern-binding isolation.
  defp build_plan(branches) do
    stage_lists = Enum.map(branches, & &1.stages)
    prefix = common_prefix(stage_lists)
    suffix = common_suffix(stage_lists)
    p = length(prefix)
    s = length(suffix)

    middles =
      Enum.map(stage_lists, fn stages ->
        stages |> Enum.drop(p) |> Enum.drop(-s)
      end)

    with true <- p >= 1 and s >= 1,
         true <- Enum.all?(middles, &(&1 != [])),
         true <- Enum.all?(prefix ++ suffix, &(not effectful_stage?(&1))),
         :ok <- middles_isolated_from_patterns(branches, middles) do
      {:ok, %{prefix: prefix, suffix: suffix, middles: middles, branches: branches}}
    else
      _ -> :skip
    end
  end

  defp middles_isolated_from_patterns(branches, middles) do
    branches
    |> Enum.zip(middles)
    |> Enum.all?(fn {branch, middle} ->
      bound = MapSet.new(pattern_var_names(branch.pattern))
      used = used_var_names({:__block__, [], middle})
      MapSet.disjoint?(bound, used)
    end)
    |> ok_or_skip()
  end

  # A shared stage is hoisted to run around the dispatch. Because case
  # branches are mutually exclusive, the stage already ran exactly once;
  # hoisting preserves that. We still skip on clearly-effectful stages
  # (bang functions, known effect modules, `send`) as a conservative
  # guard against subtle ordering assumptions.
  @effect_modules ~w(Repo Logger GenServer File IO Agent Task Process)a

  defp effectful_stage?(stage) do
    stage
    |> Macro.prewalker()
    |> Enum.any?(&effectful_node?/1)
  end

  defp effectful_node?({{:., _, [{:__aliases__, _, [mod]}, _fun]}, _, _args})
       when mod in @effect_modules,
       do: true

  defp effectful_node?({{:., _, [:ets, _fun]}, _, _args}), do: true
  defp effectful_node?({:send, _, args}) when is_list(args), do: true
  defp effectful_node?({:., _, [_mod, fun]}) when is_atom(fun), do: bang?(fun)
  defp effectful_node?({fun, _, args}) when is_atom(fun) and is_list(args), do: bang?(fun)
  defp effectful_node?(_), do: false

  defp bang?(fun), do: fun |> Atom.to_string() |> String.ends_with?("!")

  defp build_patches(node, kind, fn_name, scrutinee, helper, plan) do
    host_body = render_host_body(scrutinee, helper, plan)
    helpers = render_helpers(helper, plan)

    body_patch = %{
      change: render_def(kind, fn_name, scrutinee, host_body),
      range: node_range(node)
    }

    insert_patch = %{change: "\n\n" <> helpers, range: end_range(node)}
    [body_patch, insert_patch]
  end

  defp render_def(kind, fn_name, scrutinee, host_body),
    do: "#{kind} #{fn_name}(#{scrutinee}) do\n#{host_body}\nend"

  defp render_host_body(scrutinee, helper, plan) do
    prefix_lines = Enum.map(plan.prefix, &("|> " <> stage_text(&1)))
    dispatch_line = "|> #{helper}(#{scrutinee})"
    suffix_lines = Enum.map(plan.suffix, &("|> " <> stage_text(&1)))

    [Atom.to_string(scrutinee) | prefix_lines ++ [dispatch_line] ++ suffix_lines]
    |> Enum.join("\n")
  end

  defp render_helpers(helper, plan) do
    plan.branches
    |> Enum.zip(plan.middles)
    |> Enum.map_join("\n", fn {branch, middle} ->
      pattern = Sourceror.to_string(branch.pattern)
      body = render_middle(middle)
      "defp #{helper}(piped, #{pattern}), do: #{body}"
    end)
  end

  defp render_middle(stages) do
    ["piped" | Enum.map(stages, &stage_text/1)]
    |> Enum.join(" |> ")
  end

  defp stage_text(stage), do: Sourceror.to_string(stage)

  defp common_prefix(lists), do: common_run(lists)

  defp common_suffix(lists) do
    lists
    |> Enum.map(&Enum.reverse/1)
    |> common_run()
    |> Enum.reverse()
  end

  defp common_run([first | _] = lists) do
    first
    |> Enum.with_index()
    |> Enum.take_while(fn {stage, i} ->
      Enum.all?(lists, fn list -> stage_eq?(Enum.at(list, i), stage) end)
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp stage_eq?(nil, _), do: false
  defp stage_eq?(a, b), do: strip_meta(a) == strip_meta(b)

  defp strip_meta(ast),
    do:
      Macro.prewalk(ast, fn
        {f, _, a} -> {f, [], a}
        o -> o
      end)

  defp def_names(mod) do
    mod
    |> module_body_exprs()
    |> Enum.flat_map(fn
      {kind, _, [head | _]} when kind in [:def, :defp] ->
        case extract_fn_signature(strip_when(head)) do
          {name, _} -> [name]
          _ -> []
        end

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp node_range(node), do: Sourceror.get_range(node)

  defp end_range(node) do
    %{end: end_pos} = Sourceror.get_range(node)
    %{start: end_pos, end: end_pos}
  end

  defp do_body(body_kw) do
    body_kw
    |> Enum.find_value(:skip, fn
      {{:__block__, _, [:do]}, value} -> {:ok, value}
      {:do, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp ok_or_skip(true), do: :ok
  defp ok_or_skip(false), do: :skip

  defp reduce_ok(list, fun) do
    list
    |> Enum.reduce_while([], fn item, acc ->
      case fun.(item) do
        {:ok, value} -> {:cont, [value | acc]}
        :skip -> {:halt, :skip}
      end
    end)
    |> case do
      :skip -> :skip
      values -> {:ok, Enum.reverse(values)}
    end
  end
end
