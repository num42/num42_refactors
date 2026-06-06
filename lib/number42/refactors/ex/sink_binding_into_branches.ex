defmodule Number42.Refactors.Ex.SinkBindingIntoBranches do
  @moduledoc """
  Sinks a binding read in exactly one branch of the immediately
  following `case`/`if` down into that branch.

      # before
      config = load_config()

      case mode do
        :fast -> run_fast()
        :full -> run_full(config)
      end

      # after
      case mode do
        :fast ->
          run_fast()

        :full ->
          config = load_config()
          run_full(config)
      end

  ## Why this is safe

  Sinking moves the evaluation of `rhs` from "always" into "only when
  that branch runs" — it changes **strictness**. That is observable
  unless the RHS is **pure, total and exception-free**: a side effect
  would stop firing on the other branches, and a raise (even
  `String.to_integer/1`) would stop happening on inputs that no longer
  reach the binding. So the rewrite is gated on `AstHelpers.pure?/1`,
  the same strong-purity check the inline/move refactors use.

  ## When we sink

  A `var = rhs` statement is sunk only when **all** hold:

  - The LHS is a **bare variable** — a pattern (`{:ok, c} = …`) carries
    matching semantics (and a possible `MatchError`) the move can't keep
    on the always-runs schedule.
  - The RHS is **pure** in the strong sense (`AstHelpers.pure?/1`):
    total, exception-free, eager.
  - The **immediately following** statement is a `case` or `if`.
  - The scrutinee/condition does **not** read `var` — otherwise the
    branch the value would be sunk into can't even be reached without it
    (a cycle).
  - `var` is read in **exactly one** branch
    (`AstHelpers.live_in_single_branch?/2`). Two branches would mean
    duplicating the evaluation; zero branches is a dead binding, not a
    sink.
  - `var` is **never read after** the `case`/`if`
    (`AstHelpers.read_after?/3`) — a downstream read would lose the
    value when we move the binding inside a branch.

  ## What we skip

  - Pattern-match LHS.
  - Impure / side-effecting / possibly-raising RHS.
  - A following statement that is not a `case`/`if`.
  - A scrutinee/condition that depends on the binding (cycle).
  - A binding read in zero or in two-plus branches.
  - A binding still read after the `case`/`if`.

  ## Idempotence & determinism

  At most **one** binding is sunk per pass — the first eligible in
  source order. After the rewrite the binding lives inside the branch
  and the pre-block binding is gone, so a re-run finds no `var = rhs`
  immediately followed by a `case`/`if` that reads it in one branch; the
  engine's fixpoint loop picks up any remaining bindings on later
  passes.
  """

  use Number42.Refactors.Refactor

  @impl Number42.Refactors.Refactor
  def description, do: "Sink a single-branch binding down into that branch of a following case/if"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A binding consumed in only one arm of the next `case`/`if` runs
    eagerly for arms that never use it. Sinking it into the one arm that
    reads it makes the cost pay only when needed and puts the value next
    to its use. Gated on strong purity so the strictness change the sink
    introduces stays unobservable: no side effect is suppressed, no
    raise is deferred onto a now-unreachable input.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts),
    do: Sourceror.parse_string(source) |> apply_to_parse_result(source)

  defp apply_to_parse_result({:ok, ast}, source),
    do: ast |> first_sink_patches() |> patch_or_passthrough(source)

  defp apply_to_parse_result({:error, _}, source), do: source

  # Sink at most one binding per pass — the first eligible across all
  # statement blocks in the file — so output stays deterministic.
  @spec first_sink_patches(Macro.t()) :: [map()]
  defp first_sink_patches(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value([], fn
      {:__block__, _, exprs} when is_list(exprs) and length(exprs) >= 2 ->
        patches_for_block(exprs)

      _ ->
        nil
    end)
  end

  defp patches_for_block(exprs) do
    exprs
    |> Enum.with_index()
    |> Enum.find_value(fn {expr, idx} -> patches_for_binding(expr, idx, exprs) end)
  end

  defp patches_for_binding({:=, _, [lhs, rhs]} = binding, idx, exprs) do
    with {:ok, var} <- bare_lhs_var(lhs),
         true <- pure?(rhs),
         {:branchy, scrutinee, branches} <- next_branchy(exprs, idx),
         false <- reads_var?(scrutinee, var),
         true <- live_in_single_branch?(var, branches),
         false <- read_after?(var, exprs, idx + 1) do
      [delete_binding_patch(binding), sink_patch(branches, var, binding)]
    else
      _ -> nil
    end
  end

  defp patches_for_binding(_, _idx, _exprs), do: nil

  # A bare-variable LHS — `{name, meta, ctx}` with atom context. Anything
  # else (pattern, pinned var) is not a simple binding.
  defp bare_lhs_var({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {:ok, name}
  defp bare_lhs_var(_), do: :skip

  # The statement after the binding, when it is a `case`/`if`. Returns
  # the node, its scrutinee/condition, and the list of branch bodies.
  defp next_branchy(exprs, idx), do: Enum.at(exprs, idx + 1) |> branchy()

  defp branchy({:case, _, [scrutinee, [{_do, clauses}]]}) when is_list(clauses) do
    {:branchy, scrutinee, Enum.map(clauses, &clause_body/1)}
  end

  defp branchy({:if, _, [condition, kw]}) when is_list(kw) do
    {:branchy, condition, if_branch_bodies(kw)}
  end

  defp branchy(_), do: :skip

  defp clause_body({:->, _, [_pattern, body]}), do: body

  defp if_branch_bodies(kw) do
    kw
    |> Enum.filter(&match?({{:__block__, _, [arm]}, _} when arm in [:do, :else], &1))
    |> Enum.map(fn {_arm, body} -> body end)
  end

  defp reads_var?(ast, var), do: MapSet.member?(used_var_names(ast), var)

  defp delete_binding_patch(binding),
    do: %{change: "", range: Sourceror.get_range(binding)}

  # Prepend the binding into the one branch that reads `var`, by
  # replacing that branch body with `binding_text\nbody_text`. The
  # follow-up format pass normalises the indentation.
  defp sink_patch(branches, var, binding) do
    target = Enum.find(branches, &reads_var?(&1, var))
    binding_text = Sourceror.to_string(binding)
    body_text = Sourceror.to_string(target)

    %{
      change: binding_text <> "\n" <> body_text,
      range: Sourceror.get_range(target)
    }
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
