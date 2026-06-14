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

  ## Multiple generators and nested comprehensions

  A `for` with several comma-separated generators is treated as one
  scope: a subexpression is invariant only when it references **none** of
  the generator/filter bindings, and then it lifts entirely before the
  `for`. A subexpression that depends on an earlier generator but not a
  later one is *not* lifted — a flat `for` has no statement position
  between its generators to host the binding without restructuring the
  loop, which this rewrite deliberately does not do.

  **Nested** `for`/`Enum.map` get the level right by construction. Each
  comprehension lifts only what is invariant in *its own* body, to just
  before *itself*. So in

      for row <- rows do
        for col <- cols, do: f(row, col, g(row))
      end

  `g(row)` depends on `row` (outer) but not `col` (inner), so it lifts to
  before the inner `for`, inside the outer body — the tightest legal
  level. A fully invariant `g()` lifts all the way out past both.

  The invariance check is **scope-aware**: when scanning a comprehension's
  body it excludes not just that comprehension's own bindings but every
  variable introduced by a *nested* scope inside the body — an inner
  `for`, a `fn`, a `with`, a `case`/`cond`/`receive`/`try` clause. Lifting
  a subexpression that reads a nested-scope variable to before the outer
  comprehension would reference an unbound variable and fail to compile,
  so such a subexpression is left for the inner scope to claim.

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

  ## Capture-shorthand safety

  A `&(...)` capture binds `&1`, `&2`, … only inside its own subtree, so a
  subexpression that references a capture arg (`Atom.to_string(&1)`) is
  **never** hoisted — pulled out of the capture the bare `&1` would no
  longer compile. Conservative skip: any candidate holding a `&n` is left
  in place.
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
  def transform(source, _opts) do
    Sourceror.parse_string(source) |> apply_patches(source)
  end

  defp apply_patches({:ok, ast}, source),
    do: ast |> collect_lifts(no_host()) |> Enum.take(1) |> emit_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp emit_or_passthrough([], source), do: source

  defp emit_or_passthrough([lift], source),
    do: source |> Sourceror.patch_string(build_patches(lift))

  # ── Tree walk: track the innermost block-member statement that hosts
  #    the comprehension, so the binding lands in a legal position. ──
  #
  # `host` is a `%{stmt, convert}` context: `stmt` is the statement the
  # binding is prepended to; `convert` is `{enclosing_node, key}` when
  # that statement is the *sole* expression of a keyword-form `do:`
  # body — inserting a second statement there needs a `do/end` block,
  # so the patch rewrites the enclosing construct instead.

  defp no_host, do: %{stmt: nil, convert: nil}

  defp collect_lifts({:__block__, _, exprs}, _host) when is_list(exprs),
    do: exprs |> Enum.flat_map(&collect_lifts(&1, stmt_host(&1)))

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
  defp child_groups({_form, _meta, _args} = node, host) do
    {head, blocks} = split_block_keyword(node_args(node))

    head_lifts = head |> Enum.flat_map(&collect_lifts(&1, host))
    block_lifts = blocks |> Enum.flat_map(&collect_block(&1, node))
    head_lifts ++ block_lifts
  end

  defp node_args({_form, _meta, args}), do: args

  defp collect_block({key, body}, enclosing) when key in [:do, :else, :rescue, :catch, :after] do
    exprs = body_to_exprs(body)
    convert = keyword_form_convert(enclosing, key, exprs)
    exprs |> Enum.flat_map(&collect_lifts(&1, block_host(&1, convert)))
  end

  defp collect_block(other, enclosing), do: collect_lifts(other, stmt_host(enclosing))

  # A single-statement keyword-form body (`def f(x), do: expr`) can hold
  # only one expression. When the binding has to be prepended there, the
  # enclosing construct must be rewritten as a `do/end` block. Block-form
  # bodies (carrying `:do`/`:end` location meta on the enclosing call)
  # and multi-statement bodies already accept extra statements directly.
  defp keyword_form_convert({_form, meta, _args} = enclosing, key, [_single])
       when is_list(meta) do
    if block_form?(meta), do: nil, else: {enclosing, key}
  end

  defp keyword_form_convert(_enclosing, _key, _exprs), do: nil

  defp block_form?(meta), do: Keyword.has_key?(meta, :do)

  defp stmt_host(stmt), do: %{stmt: stmt, convert: nil}
  defp block_host(stmt, convert), do: %{stmt: stmt, convert: convert}

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

  defp lifts_here(node, %{stmt: stmt} = host) when not is_nil(stmt) do
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

  defp lift_for_body(_node, %{stmt: stmt, convert: convert}, bound, body) do
    case invariant_call(body, bound) do
      nil -> []
      expr -> [%{host: stmt, convert: convert, expr: expr}]
    end
  end

  # First hoistable call in a pre-order walk, picking the *outermost*
  # qualifying node (we don't descend into a call we already accept).
  defp invariant_call(body, bound), do: find_invariant(body, bound)

  # `bound` grows as we descend: a nested scope (an inner `for`, a `fn`,
  # a `with`, a `case`/`cond`/… clause) introduces variables visible only
  # to its own subtree. A candidate that references such a nested-scope
  # variable must NOT be lifted before *this* comprehension — out there
  # the variable is not yet bound and the code no longer compiles. Adding
  # every nested-scope variable to `bound` before recursing keeps the
  # lift at the correct level: the innermost comprehension whose body the
  # candidate is truly invariant in claims it (one hoist per pass).
  defp find_invariant(node, bound) do
    if hoistable_call?(node, bound) do
      node
    else
      inner = MapSet.union(bound, scope_bound(node))
      node |> children() |> Enum.find_value(&find_invariant(&1, inner))
    end
  end

  # Variables a node introduces into its own subtree. Conservative: every
  # name bound *anywhere* under a scope-former is excluded for the whole
  # subtree. This can only narrow what we lift — it never hoists past a
  # binding — which is the safe side for nested generators.
  defp scope_bound({:for, _, args}) when is_list(args) do
    {clauses, _body} = for_clauses_and_body(args)
    clauses |> Enum.flat_map(&clause_bound_vars/1) |> MapSet.new()
  end

  defp scope_bound({:fn, _, clauses}) when is_list(clauses) do
    clauses |> Enum.flat_map(&fn_clause_bound_vars/1) |> MapSet.new()
  end

  defp scope_bound({form, _, args})
       when form in [:with, :case, :cond, :receive, :try] and is_list(args) do
    args |> Enum.flat_map(&scope_clause_bound_vars/1) |> MapSet.new()
  end

  defp scope_bound(_), do: MapSet.new()

  defp fn_clause_bound_vars({:->, _, [params, _body]}) when is_list(params),
    do: Enum.flat_map(params, &pattern_var_names/1)

  defp fn_clause_bound_vars(_), do: []

  # `with`/`case`/… clause heads bind on their left: `pat <- expr`,
  # `pat = expr`, and `pat -> body` (each `->` head is a pattern list).
  defp scope_clause_bound_vars({:<-, _, [pattern, _expr]}), do: pattern_var_names(pattern)
  defp scope_clause_bound_vars({:=, _, [lhs, _rhs]}), do: pattern_var_names(lhs)

  defp scope_clause_bound_vars({:->, _, [heads, _body]}) when is_list(heads),
    do: Enum.flat_map(heads, &pattern_var_names/1)

  defp scope_clause_bound_vars(kw) when is_list(kw),
    do: Enum.flat_map(kw, &scope_clause_bound_vars/1)

  defp scope_clause_bound_vars({_key, value}), do: scope_clause_bound_vars(value)
  defp scope_clause_bound_vars(_), do: []

  defp children({_form, _meta, args}) when is_list(args), do: args
  defp children({left, right}), do: [left, right]
  defp children(list) when is_list(list), do: list
  defp children(_), do: []

  defp hoistable_call?(node, bound) do
    call_node?(node) and pure?(node) and not depends_on_bound?(node, bound) and
      not captures_arg?(node)
  end

  # A `&(...)` capture shorthand binds `&1`, `&2`, … only within its own
  # subtree. A node holding a capture arg loses that binding when hoisted
  # out, leaving a bare `&1` that no longer compiles — never lift it.
  defp captures_arg?(node) do
    node
    |> Macro.prewalk(false, fn
      {:&, _, [n]} = inner, _acc when is_integer(n) -> {inner, true}
      inner, acc -> {inner, acc}
    end)
    |> elem(1)
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

  # Keyword-form host (`def f(x), do: <for>`): a `do:` body holds a
  # single expression, so we can't prepend a binding there. Rewrite the
  # enclosing construct into a `do/end` block whose body is the binding
  # followed by the rebound host — the only legal place for two
  # statements. The whole construct is replaced in one patch.
  defp build_patches(%{host: host, convert: {enclosing, key}, expr: expr}) do
    name = binding_name(expr, enclosing)
    binding = {:=, [], [{String.to_atom(name), [], nil}, strip_comments(expr)]}
    rebound = rebind_expr(host, expr, name) |> strip_comments()
    block = {:__block__, [], [binding, rebound]}

    range = Sourceror.get_range(enclosing)
    new_text = enclosing |> to_do_end_block(key, block) |> Sourceror.to_string()

    [Patch.new(range, new_text, false)]
  end

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

  # Swap the enclosing construct's keyword-form `key:` body for a
  # `do/end` block. Forcing `:do`/`:end` location meta onto the call is
  # what makes Sourceror render the block form instead of the keyword
  # form; the location values themselves are placeholders re-derived by
  # the final `mix format` pass.
  defp to_do_end_block({form, meta, args}, key, block) do
    new_args = replace_block_body(args, key, block)

    new_meta =
      meta
      |> Keyword.put_new(:do, line: 1, column: 1)
      |> Keyword.put_new(:end, line: 1, column: 1)

    {form, new_meta, new_args}
  end

  defp replace_block_body(args, key, block) do
    List.update_at(args, -1, fn kw ->
      Enum.map(kw, fn
        {{:__block__, m, [^key]}, _body} -> {{:__block__, m, [key]}, block}
        {^key, _body} -> {key, block}
        pair -> pair
      end)
    end)
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
