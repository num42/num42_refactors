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

  ## Enabled by default

  This refactor runs unattended. Splicing an RHS across the many shapes
  a use site can take (Ecto pins, macro keyword args, control-flow
  bodies, operator operands) once produced invalid or meaning-changing
  output; each such shape is now a guard in `patches_for_binding/3`
  (pattern LHS, impure/raising RHS, control-flow RHS, fallback/guard
  RHS, multi-line literal RHS, non-adjacent or multi-read use, pin use)
  plus use-site-aware paren-wrapping. With those guards a full-suite
  dogfood run on a real codebase is green, so the conservative opt-in
  gate was removed.

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
  - A **fallback/guard RHS** — a short-circuit operator at the root
    (`x = lookup(k) || []`, `x = a && b`). The name marks a deliberate
    "value-or-its-fallback"; inlining buries it in a call argument.
  - A **multi-line literal RHS** — a map/struct/list spanning more than
    one source line. Inlined it gets crammed into a call argument and
    reads worse than the named binding; a binding is the right tool to
    name such a literal.

  ## Idempotence & determinism

  Each step inlines exactly **one** binding — the first eligible in
  source order, in the first block that has one — then re-parses. A
  single `transform/2` call loops these steps to its own fixpoint, so it
  inlines every eligible binding (including cascades, where inlining one
  binding makes the next eligible) and returns a source with nothing left
  to inline. A second `transform/2` is therefore a no-op — idempotent in
  one call, independent of the engine's (capped) pass loop. Stepping one
  binding at a time and re-parsing keeps every rewrite over fresh byte
  ranges, so overlapping or cascading use sites never collide.
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

  # An inline-to-fixpoint can't exceed one step per binding in the file;
  # this bound is a generous backstop so a degenerate input can never spin
  # forever — far above any real binding count, so it never clips real work.
  @max_inline_steps 10_000

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: inline_to_fixpoint(source, @max_inline_steps)

  # Inline bindings until none remain, within this single `transform/2`
  # call. Each step rewrites exactly one binding (the first eligible, in
  # source order) and re-parses, so cascades — where inlining one binding
  # makes the next eligible — and overlapping use sites resolve naturally
  # without ever applying two interacting patches at once. Reaching the
  # fixpoint here (rather than across the engine's capped pass loop) keeps
  # a single transform idempotent even when a file holds more inline-able
  # bindings than the engine's pass cap.
  defp inline_to_fixpoint(source, 0), do: source

  defp inline_to_fixpoint(source, steps_left) do
    case one_inline(source) do
      ^source -> source
      next -> inline_to_fixpoint(next, steps_left - 1)
    end
  end

  defp one_inline(source),
    do: Sourceror.parse_string(source) |> apply_to_parse_result(source)

  defp apply_to_parse_result({:ok, ast}, source),
    do: ast |> first_block_patches() |> patch_or_passthrough(source)

  defp apply_to_parse_result({:error, _}, source), do: source

  # Inline at most one binding per step — the first eligible across all
  # statement blocks in the file — so each rewrite is deterministic; the
  # `inline_to_fixpoint/2` loop applies the rest.
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
         false <- control_flow_rhs?(rhs),
         false <- fallback_rhs?(rhs),
         false <- multiline_rhs?(rhs),
         {:ok, use_expr} <- next_statement(exprs, idx),
         1 <- read_count(use_expr, var),
         false <- read_after?(var, exprs, idx + 1),
         false <- used_in_pin?(use_expr, var) do
      [delete_binding_patch(binding), inline_patch(use_expr, var, rhs)]
    else
      _ -> nil
    end
  end

  defp patches_for_binding(_, _idx, _exprs), do: nil

  # A control-flow expression (`if`/`case`/`cond`/`with`/`unless`/`fn`)
  # carries `do:`/`else:` keyword args or a multi-clause block. Spliced
  # into a larger expression — `{^if x, do: :a, else: :b, rest}` — the
  # trailing keywords bleed into the surrounding term and the result no
  # longer parses. Paren-wrapping it would compile but reads worse than
  # the named binding, so leave these alone.
  @control_flow_heads [:if, :unless, :case, :cond, :with, :fn]
  defp control_flow_rhs?({head, _, _}) when head in @control_flow_heads, do: true
  defp control_flow_rhs?(_), do: false

  # A short-circuit operator at the RHS root (`x = lookup(k) || []`,
  # `x = a && b`) is a deliberate default/guard: the binding name marks
  # "this is the value-or-its-fallback". Splicing it into the use site —
  # paren-wrapped — buries that intent inside a call's argument list
  # (`use((lookup(k) || []))`). The named form reads better, so skip.
  @fallback_ops [:||, :&&, :or, :and]
  defp fallback_rhs?({op, _, args}) when op in @fallback_ops and is_list(args), do: true
  defp fallback_rhs?(_), do: false

  # The RHS is a literal that spans more than one source line — a
  # multi-line map / struct / list. Inlined, it gets crammed into a
  # call argument (`Map.get(%{...8 lines...}, k, default)`), which reads
  # worse than the named binding it replaces. A binding is exactly the
  # right tool to give such a literal a name, so leave it.
  defp multiline_rhs?(rhs) do
    case Sourceror.get_range(rhs) do
      %{start: start, end: end_} -> end_[:line] > start[:line]
      _ -> false
    end
  end

  # The sole read sits behind a `^` pin (Ecto query / match pin). The
  # inline would land an expression at a pin position (`^(if …)`), which
  # is illegal. Skip — only bare reads are safe to splice.
  defp used_in_pin?(use_expr, var) do
    use_expr
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:^, _, [{^var, _, ctx}]} when is_atom(ctx) -> true
      _ -> false
    end)
  end

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
    text = if needs_paren?(rhs, use_expr, var_node), do: "(" <> rendered <> ")", else: rendered
    %{change: text, range: Sourceror.get_range(var_node)}
  end

  # Whether the spliced RHS must be parenthesised to preserve meaning.
  #
  # Parens matter only when an **operator at the RHS root** lands in a
  # slot that itself is an **operand of an operator** at the use site:
  # there the two operators re-associate by precedence and can change
  # the parse (`brand_ids ++ variants |> Enum.map(f)` binds the map over
  # the whole concat, not just `variants`). The pipe is no exception —
  # `++` binds tighter than `|>`, so an inlined pipe needs the wrap too.
  #
  # Every other slot is self-delimiting — a call argument, a data-
  # structure element, the function side of a pipe — bounded by a comma
  # or bracket. There no operator RHS can capture its neighbours, so no
  # parens are added regardless of the RHS shape.
  defp needs_paren?(rhs, use_expr, var_node) do
    operator_root?(rhs) and operand_of_operator?(use_expr, var_node)
  end

  defp operator_root?({op, _, args}) when is_atom(op) and is_list(args) do
    Macro.operator?(op, length(args)) and length(args) in [1, 2]
  end

  defp operator_root?(_), do: false

  # The splice slot sits directly under an operator node — i.e. the
  # inlined expression becomes one of that operator's operands. Walks
  # the ancestor path to `var_node` and inspects its immediate parent.
  defp operand_of_operator?(use_expr, var_node) do
    case Macro.path(use_expr, &(&1 == var_node)) do
      [_self, parent | _] -> operator_root?(parent)
      _ -> false
    end
  end

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
