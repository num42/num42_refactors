defmodule Number42.Refactors.Ex.HoistInvariantOutOfComprehension do
  @moduledoc """
  Lifts a loop-invariant subexpression out of a `for`/`Enum.map` body
  into a local binding placed immediately before the comprehension:

      for row <- rows, do: format(row, Enum.sum(weights))

  becomes

      total = Enum.sum(weights)
      for row <- rows, do: format(row, total)

  Classic loop-invariant code motion (LICM), here as a source rewrite.

  > #### `Date.utc_today()` is *not* hoisted {: .info}
  >
  > The original issue used `Date.utc_today()` as the motivating
  > example, but a clock read is non-deterministic — it is **not** pure
  > under `AstHelpers.pure?/1`, and hoisting it could change the
  > observed time. The purity layer is the source of truth here:
  > safety over the literal example.

  ## What fires

  - The comprehension is a `for` (any number of generators/filters) or
    a two-arg `Enum.map(coll, fn x -> … end)` with a single-clause,
    single-arg lambda.
  - The body contains a **call** subexpression that references **no**
    loop-bound variable. "Loop-bound" is *all* generator patterns and
    filter `=` bindings (not just the first iteration variable) for
    `for`, and the lambda parameter for `Enum.map`.
  - That subexpression is **pure and total** — see `AstHelpers.pure?/1`.

  ## Why pure AND total is mandatory

  Before the rewrite the subexpression runs once per iteration: `n`
  times, or **zero** times for an empty collection. After the rewrite
  it runs exactly once, unconditionally. For an empty `rows` that is
  0 calls before and 1 call after — observably different the moment the
  expression has a side effect or can raise. Lifting is therefore only
  safe when the expression is pure and total, so the count change is
  unobservable. Anything else is skipped.

  ## What gets lifted

  Only a **call** node (`Mod.fun(args)` or `local(args)`) — never a
  bare variable or a literal, which are already as cheap as the
  binding would be. The largest qualifying subexpression at each
  position wins, so `f(g(h()))` lifts the whole `f(...)` rather than an
  inner piece, when the whole thing is invariant.

  ## One hoist per pass

  We lift one subexpression per `Engine` pass and let the fixpoint loop
  re-run. Keeps each diff a single reviewable lift and sidesteps
  overlapping-patch bookkeeping.

  ## Idempotence

  After a lift the subexpression is a bare-variable binding outside the
  loop and the body references that variable. A bare variable is not a
  call, so a second pass finds no invariant to hoist — the rewrite is a
  fixpoint.

  ## Naming

  Derived from the call (`Date.utc_today()` → `today`, `f(opts)` → `f`),
  falling back to `hoisted`. The name is disambiguated against every
  variable in the enclosing statement so the binding never shadows an
  existing one.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description,
    do: "Hoist a loop-invariant pure subexpression out of a for/Enum.map body"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A subexpression in a comprehension body that depends on no
    loop-bound variable is recomputed on every iteration for no reason.
    Lifting it to a binding before the loop computes it once and names
    the value at the call site.

    The lift is only safe when the expression is pure and total: before,
    it runs n times (zero for an empty collection); after, exactly once
    unconditionally. With side effects or a possible exception that
    count change is observable, so anything not provably pure+total is
    left in place.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 100
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp apply_patches({:ok, ast}, source),
    do: ast |> collect_lifts(nil) |> Enum.take(1) |> emit_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp emit_or_passthrough([], source), do: source

  defp emit_or_passthrough([lift], source),
    do: source |> Sourceror.patch_string(build_patches(lift))

  # ── Tree walk: track the innermost block-member statement that hosts
  #    the comprehension, so the binding lands in a legal position. ──

  defp collect_lifts({:__block__, _, exprs}, _host) when is_list(exprs),
    do: exprs |> Enum.flat_map(&collect_lifts(&1, &1))

  defp collect_lifts(node, host) do
    lifts_here(node, host) ++ descend(node, host)
  end

  defp descend({_, _, args} = node, host) when is_list(args),
    do: child_groups(node, host)

  defp descend({left, right}, host),
    do: collect_lifts(left, host) ++ collect_lifts(right, host)

  defp descend(list, host) when is_list(list),
    do: list |> Enum.flat_map(&collect_lifts(&1, host))

  defp descend(_leaf, _host), do: []

  # `do`/`else`/… block bodies re-root the host to each statement in
  # the block. Everything else keeps the current host and recurses.
  defp child_groups({_form, _meta, args}, host) do
    {head, blocks} = split_block_keyword(args)

    head_lifts = head |> Enum.flat_map(&collect_lifts(&1, host))
    block_lifts = blocks |> Enum.flat_map(&collect_block(&1, host))
    head_lifts ++ block_lifts
  end

  defp collect_block({key, body}, _host) when key in [:do, :else, :rescue, :catch, :after],
    do: body |> body_to_exprs() |> Enum.flat_map(&collect_lifts(&1, &1))

  defp collect_block(other, host), do: collect_lifts(other, host)

  defp split_block_keyword(args) when is_list(args) do
    case List.last(args) do
      kw when is_list(kw) ->
        block_kw = Enum.filter(kw, &block_pair?/1)
        if block_kw == [], do: {args, []}, else: {Enum.drop(args, -1), normalize_block_kw(kw)}

      _ ->
        {args, []}
    end
  end

  defp split_block_keyword(_), do: {[], []}

  defp normalize_block_kw(kw) do
    Enum.map(kw, fn
      {{:__block__, _, [k]}, body} -> {k, body}
      {k, body} -> {k, body}
    end)
  end

  defp block_pair?({{:__block__, _, [k]}, _}), do: k in [:do, :else, :rescue, :catch, :after]
  defp block_pair?({k, _}) when is_atom(k), do: k in [:do, :else, :rescue, :catch, :after]
  defp block_pair?(_), do: false

  # ── Comprehension detection at the current node ──

  defp lifts_here(node, host) when not is_nil(host) do
    case comprehension(node) do
      {:ok, bound, body} -> lift_for_body(node, host, bound, body)
      :no -> []
    end
  end

  defp lifts_here(_node, _host), do: []

  defp comprehension({:for, _, args}) when is_list(args) and args != [] do
    {clauses, body} = for_clauses_and_body(args)
    bound = clauses |> Enum.flat_map(&clause_bound_vars/1) |> MapSet.new()
    {:ok, bound, body}
  end

  defp comprehension(
         {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _,
          [_coll, {:fn, _, [{:->, _, [[param], body]}]}]}
       ) do
    {:ok, MapSet.new(pattern_var_names(param)), body}
  end

  defp comprehension(_), do: :no

  defp for_clauses_and_body(args) do
    {init, last} = Enum.split(args, length(args) - 1)

    case last do
      [kw] when is_list(kw) ->
        case Keyword.fetch(strip_kw(kw), :do) do
          {:ok, body} -> {init, body}
          :error -> {args, nil}
        end

      _ ->
        {args, nil}
    end
  end

  defp strip_kw(kw) do
    Enum.map(kw, fn
      {{:__block__, _, [k]}, v} -> {k, v}
      pair -> pair
    end)
  end

  # Generator `pattern <- coll` and filter `name = expr` both introduce
  # loop-bound names. A bare-boolean filter binds nothing.
  defp clause_bound_vars({:<-, _, [pattern, _coll]}), do: pattern_var_names(pattern)
  defp clause_bound_vars({:=, _, [lhs, _rhs]}), do: pattern_var_names(lhs)
  defp clause_bound_vars(_), do: []

  # ── Candidate selection inside the body ──

  defp lift_for_body(_node, _host, _bound, nil), do: []

  defp lift_for_body(_node, host, bound, body) do
    case invariant_call(body, bound) do
      nil -> []
      expr -> [%{host: host, expr: expr}]
    end
  end

  # First hoistable call in a pre-order walk, picking the *outermost*
  # qualifying node (we don't descend into a call we already accept).
  defp invariant_call(body, bound), do: find_invariant(body, bound)

  defp find_invariant(node, bound) do
    if hoistable_call?(node, bound),
      do: node,
      else: node |> children() |> Enum.find_value(&find_invariant(&1, bound))
  end

  defp children({_form, _meta, args}) when is_list(args), do: args
  defp children({left, right}), do: [left, right]
  defp children(list) when is_list(list), do: list
  defp children(_), do: []

  defp hoistable_call?(node, bound) do
    call_node?(node) and pure?(node) and not depends_on_bound?(node, bound)
  end

  defp call_node?({{:., _, [{:__aliases__, _, _}, fun]}, _, args})
       when is_atom(fun) and is_list(args),
       do: true

  defp call_node?({fun, _, args}) when is_atom(fun) and is_list(args),
    do: not Macro.special_form?(fun, length(args)) and not Macro.operator?(fun, length(args))

  defp call_node?(_), do: false

  defp depends_on_bound?(node, bound) do
    node
    |> used_var_names()
    |> MapSet.intersection(bound)
    |> MapSet.size()
    |> Kernel.>(0)
  end

  # ── Patch emission ──

  # Single replace on the host statement: prepend `name = expr` then
  # render the host with every occurrence of `expr` rebound to `name`.
  # Rewriting the whole host in one patch sidesteps the overlapping-range
  # corruption that two patches would hit when the host *is* the
  # comprehension (a comprehension that is the sole statement of a block).
  defp build_patches(%{host: host, expr: expr}) do
    name = binding_name(expr, host)
    expr_text = Sourceror.to_string(strip_comments(expr))

    range = Sourceror.get_range(host)
    indent = String.duplicate(" ", range.start[:column] - 1)
    host_text = rebind_expr(host, expr, name) |> strip_comments() |> Sourceror.to_string()

    [Patch.new(range, "#{name} = #{expr_text}\n\n#{indent}#{host_text}", false)]
  end

  defp rebind_expr(host, expr, name) do
    stripped_expr = strip_meta(expr)
    var = {String.to_atom(name), [], nil}

    Macro.prewalk(host, fn node ->
      if strip_meta(node) == stripped_expr, do: var, else: node
    end)
  end

  defp binding_name(expr, host) do
    base = name_from_value(expr) || "hoisted"
    uniquify(base, host)
  end

  defp uniquify(base, host) do
    used = host |> used_var_names() |> Enum.map(&Atom.to_string/1) |> MapSet.new()
    if MapSet.member?(used, base), do: next_free_name(base, used), else: base
  end

  defp next_free_name(base, used) do
    2
    |> Stream.iterate(&(&1 + 1))
    |> Enum.find_value(fn n ->
      candidate = "#{base}_#{n}"
      if MapSet.member?(used, candidate), do: nil, else: candidate
    end)
  end

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp strip_comments(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        {form, Keyword.drop(meta, [:leading_comments, :trailing_comments]), args}

      other ->
        other
    end)
  end
end
