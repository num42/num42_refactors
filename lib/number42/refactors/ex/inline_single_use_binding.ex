defmodule Number42.Refactors.Ex.InlineSingleUseBinding do
  @moduledoc """
  Inlines a binding read exactly once and never afterwards into its
  single use site.

      # before
      result = expensive_call(x)
      use(result)

      # after
      use(expensive_call(x))

  The inlined RHS is paren-wrapped when spliced into a larger
  expression so operator precedence is preserved (`(a + b) * 2`, not
  `a + b * 2`).

  ## When we inline

  A `var = rhs` statement is inlined only when **all** hold:

  - The LHS is a **bare variable** — not a pattern match
    (`{:ok, r} = …`, `%X{} = …`). A pattern carries matching semantics
    (and a possible `MatchError`) that a value substitution can't
    reproduce.
  - The RHS is **pure** in the strong sense (`AstHelpers.pure?/1`):
    total, exception-free, eager. Inlining moves the evaluation to the
    use site; if the RHS could raise or has a side effect, moving it
    past — or duplicating it relative to — other statements changes
    observable behaviour.
  - The binding is read by the **immediately following** statement and
    appears there **exactly once**. Adjacency means no intervening
    statement can depend on the binding or be reordered around it; a
    single read means inlining can't duplicate the (now use-site)
    evaluation.
  - The binding is **never read after** that single use
    (`AstHelpers.read_after?/3` is `false` from the use onward) — the
    value is dead past its one consumer, so removing the binding loses
    nothing.

  ## What we skip

  - Pattern-match LHS.
  - Impure / side-effecting / possibly-raising RHS.
  - A binding read more than once (here or downstream).
  - A binding whose use is **not adjacent** to it (an intervening
    statement could observe an ordering or shadowing we'd disturb).
  - A binding that is never read (a *dead* binding — that's
    `UnusedVariable`/dead-code territory, not an inline).
  - Single-expression bodies — there is no following statement to
    inline into.

  ## Idempotence & determinism

  At most **one** binding is inlined per pass — the first eligible in
  source order, in the first block that has one. After the rewrite the
  binding is gone and its RHS sits at the single use site, so a re-run
  finds nothing to inline there; the engine's fixpoint loop picks up
  any remaining bindings on later passes.
  """

  use Number42.Refactors.Refactor

  @impl Number42.Refactors.Refactor
  def description, do: "Inline a use-once, read-never-after binding into its call site"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A binding consumed exactly once and never again is a name with no
    payoff: it forces the reader to hold `result` in their head across
    a line break to learn it's used immediately and then discarded.
    Splicing the RHS into its one use — paren-wrapped for precedence —
    removes the placeholder. Conservative by design: only pure,
    bare-variable bindings whose sole read is the very next statement,
    so the rewrite can neither move a side effect nor duplicate an
    evaluation.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts),
    do: Sourceror.parse_string(source) |> apply_to_parse_result(source)

  defp apply_to_parse_result({:ok, ast}, source),
    do: ast |> first_block_patches() |> patch_or_passthrough(source)

  defp apply_to_parse_result({:error, _}, source), do: source

  # Inline at most one binding per pass — the first eligible across all
  # statement blocks in the file — so output stays deterministic.
  defp first_block_patches(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value([], fn
      {:__block__, _, exprs} when is_list(exprs) and length(exprs) >= 2 ->
        case patches_for_block(exprs) do
          [] -> nil
          patches -> patches
        end

      _ ->
        nil
    end)
  end

  defp patches_for_block(exprs) do
    exprs
    |> Enum.with_index()
    |> Enum.find_value([], fn {expr, idx} -> patches_for_binding(expr, idx, exprs) end)
  end

  defp patches_for_binding({:=, _, [lhs, rhs]} = binding, idx, exprs) do
    with {:ok, var} <- bare_lhs_var(lhs),
         true <- pure?(rhs),
         {:ok, use_expr} <- next_statement(exprs, idx),
         1 <- read_count(use_expr, var),
         false <- read_after?(var, exprs, idx + 1) do
      [delete_binding_patch(binding), inline_patch(use_expr, var, rhs)]
    else
      _ -> nil
    end
  end

  defp patches_for_binding(_, _idx, _exprs), do: nil

  # A bare-variable LHS — `{name, meta, ctx}` with atom context. Anything
  # else (tuple/map/struct pattern, pinned var) is not a simple binding.
  defp bare_lhs_var({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {:ok, name}
  defp bare_lhs_var(_), do: :skip

  defp next_statement(exprs, idx) do
    case Enum.at(exprs, idx + 1) do
      nil -> :skip
      expr -> {:ok, expr}
    end
  end

  # How many times `var` appears as a free read inside `expr`. Bound
  # occurrences (a re-bind/shadow inside the expression) don't count.
  defp read_count(expr, var) do
    bound = collect_bound_vars(expr)

    expr
    |> Macro.prewalker()
    |> Enum.count(fn
      {^var, _, ctx} when is_atom(ctx) -> not MapSet.member?(bound, var)
      _ -> false
    end)
  end

  defp delete_binding_patch(binding) do
    %{change: "", range: Sourceror.get_range(binding)}
  end

  # Replace the single `var` read in `use_expr` with the RHS text,
  # patching only the variable node's range. Parens are added only when
  # the RHS is an operator expression whose precedence could be
  # captured by the surrounding context — a self-contained call,
  # variable, literal or data structure needs none.
  defp inline_patch(use_expr, var, rhs) do
    {:ok, var_node} = find_var_node(use_expr, var)
    rendered = Sourceror.to_string(rhs)
    text = if needs_paren?(rhs), do: "(" <> rendered <> ")", else: rendered
    %{change: text, range: Sourceror.get_range(var_node)}
  end

  # An operator at the RHS root (binary or unary) can bind incorrectly
  # against the surrounding expression once spliced in, so wrap it.
  # Pipes are operators too but read fine unparenthesised; everything
  # else (calls, vars, literals, tuples/maps/lists) is self-delimiting.
  defp needs_paren?({op, _, args}) when is_atom(op) and is_list(args) do
    arity = length(args)
    op != :|> and (Macro.operator?(op, arity) and arity in [1, 2])
  end

  defp needs_paren?(_), do: false

  defp find_var_node(expr, var) do
    bound = collect_bound_vars(expr)

    expr
    |> Macro.prewalker()
    |> Enum.find_value(:error, fn
      {^var, _, ctx} = node when is_atom(ctx) ->
        if MapSet.member?(bound, var), do: nil, else: {:ok, node}

      _ ->
        nil
    end)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
