defmodule Num42.Refactors.Refactors.MapNewLambdaToForComprehension do
  @moduledoc """
  Rewrites `Map.new(coll, fn x -> {k, v} end)` (and its pipe form
  `coll |> Map.new(fn x -> {k, v} end)`) to

      for x <- coll do
        {k, v}
      end
      |> Map.new()

  The `for`-then-`|> Map.new()` shape composes naturally with filters
  and computed bindings: a reader can extend the comprehension head
  (`for x <- coll, x.active, do: …`) or inline a local binding before
  the tuple without having to convert the lambda first.

  ## Fires only on the shape the rewrite is safe for

  - lambda is single-clause, single-arg, no guard
  - lambda body is a **bare** 2-tuple literal — `{k, v}`, not
    `if/case/with`, not a multi-statement block, not a function call
    that *happens* to return a pair (we can't see that), not a
    parenthesised tuple (Sourceror wraps in `:__block__`)
  - bare `Map.new(coll, fn)` form, OR pipe form where the LHS of the
    `|>` is **not itself a pipe** — `a |> b() |> Map.new(fn)` would
    emit a pipe inside the generator head, which reads worse than
    the original; leave it for the user to pre-extract a binding

  ## Out of scope

  - Module-alias resolution. `alias SomeLib.Map` shadows the stdlib
    Map; the AST-only match cannot tell them apart and WILL rewrite
    the aliased call. Proper resolution needs module-level alias
    tracking (see `ResolveImplTrue`).
  - `quote do … end` blocks. The contents are template AST, not code
    to transform — the walker skips them.

  ## Priority

  `170` — runs after `MapNewToPipe` (`130`) and `EnumMapIntoToMapNew`
  (`140`), both of which can synthesise the input shape this refactor
  consumes.

  ## Reformatting

  Emits the replacement as raw `for`-block text and relies on
  `mix format` (triggered by `reformat_after?, do: true`) to normalise
  indentation. Tests compare whitespace-agnostically.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Num42.Refactors.Refactor
  def description,
    do: "Map.new(coll, fn x -> {k, v} end) -> for x <- coll, do: {k, v} |> Map.new()"

  @impl Num42.Refactors.Refactor
  def priority, do: 170

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    A `Map.new/2` call with a lambda whose body builds a 2-tuple is just
    a `for` comprehension with the final `Map.new/1` written
    out. Rewriting to that shape costs nothing semantically and gains
    composability: the comprehension head is the natural place to add a
    filter or a local binding, and the `|> Map.new()` tail keeps the
    "build a map" intent visible at the end of the pipeline.

    The transform is intentionally narrow — single-clause, single-arg,
    no-guard lambda with a bare 2-tuple body — because anything else
    either changes semantics (multi-clause) or hides a tuple builder
    behind a control-flow construct the rewrite cannot reason about.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  # Walk the AST manually so we can prune `quote do … end` subtrees —
  # `Macro.prewalker` would otherwise recurse into macro templates.
  # `skip` is a MapSet of node references collected by `forbidden_nodes/1`:
  # call sites whose direct parent is a single-expression `, do:`
  # shorthand keyword. Splicing a multi-statement `for…end |> Map.new()`
  # block there would emit unparseable source (`def f, do: for() do … end
  # |> Map.new()`).
  defp walk_for_patches({:quote, _, _}, _skip), do: []

  defp walk_for_patches({_, _, _} = node, skip) do
    own = if MapSet.member?(skip, node_key(node)), do: [], else: maybe_patch(node)
    children = node |> children_of() |> Enum.flat_map(&walk_for_patches(&1, skip))
    own ++ children
  end

  defp walk_for_patches(list, skip) when is_list(list),
    do: list |> Enum.flat_map(&walk_for_patches(&1, skip))

  defp walk_for_patches({left, right}, skip),
    do: walk_for_patches(left, skip) ++ walk_for_patches(right, skip)

  defp walk_for_patches(_, _), do: []

  defp children_of({_form, _meta, args}) when is_list(args), do: args
  defp children_of(_), do: []

  # Identity key for skip-set membership. AST nodes are tuples, which
  # MapSet compares structurally; using `:erlang.phash2` + the node's
  # source position keeps the set small without false-positive
  # collisions across distinct call sites.
  defp node_key({_, meta, _} = node) when is_list(meta),
    do: {:erlang.phash2(node), Keyword.get(meta, :line), Keyword.get(meta, :column)}

  defp node_key(node), do: {:erlang.phash2(node), nil, nil}

  # Pre-pass: collect Map.new(coll, fn) / coll |> Map.new(fn) nodes
  # whose source position can't accept a multi-line `for…end |>
  # Map.new()` block. Two cases:
  #
  # 1. RHS of a `def f, do: …` (or any `, do:` keyword) shorthand —
  #    the AST shape is `{{:__block__, [format: :keyword], [:do]}, value}`.
  #    Splicing a multi-statement block here produces unparseable
  #    source: `def f, do: for() do … end |> Map.new()`.
  #
  # 2. Direct argument of a module attribute `@name <call>`. The `@`
  #    macro accepts a single expression; a multi-statement
  #    `for…end |> Map.new()` argument fails with
  #    "expected 0 or 1 argument for @|>".
  defp forbidden_nodes(ast) do
    {_, skip} = Macro.prewalk(ast, MapSet.new(), &forbidden_step/2)
    skip
  end

  defp forbidden_step({{:__block__, kw_meta, [:do]}, value} = node, acc) when is_list(kw_meta) do
    if Keyword.get(kw_meta, :format) == :keyword,
      do: {node, maybe_forbid(value, acc)},
      else: {node, acc}
  end

  defp forbidden_step({:@, _, [{_attr, _, [value]}]} = node, acc),
    do: {node, maybe_forbid(value, acc)}

  defp forbidden_step(node, acc), do: {node, acc}

  defp maybe_forbid(value, acc) do
    if map_new_call?(value), do: MapSet.put(acc, node_key(value)), else: acc
  end

  defp map_new_call?({{:., _, [{:__aliases__, _, [:Map]}, :new]}, _, [_, {:fn, _, _}]}), do: true

  defp map_new_call?(
         {:|>, _, [_, {{:., _, [{:__aliases__, _, [:Map]}, :new]}, _, [{:fn, _, _}]}]}
       ),
       do: true

  defp map_new_call?(_), do: false

  # Bare call form: Map.new(coll, fn x -> {k, v} end)
  defp maybe_patch(
         {{:., _, [{:__aliases__, _, [:Map]}, :new]}, _,
          [coll, {:fn, _, [{:->, _, [[pattern], body]}]}]} = node
       ) do
    if simple_pattern?(pattern) and tuple_pair?(body),
      do: [replacement_patch(node, pattern, coll, body)],
      else: []
  end

  # Pipe form: coll |> Map.new(fn x -> {k, v} end)
  # Pipe sugar makes the Map.new call look like arity-1 with the
  # lambda as the only argument — `coll` lives on the LHS of `|>`.
  #
  # When `coll` is itself a pipe, we try to peel off Enum.filter /
  # Enum.reject stages and lift their predicates into the
  # comprehension head as `, condition` guards. Anything else on the
  # pipe LHS (Enum.map, Enum.sort, ...) is not safe to lift; we skip
  # in that case to avoid emitting a pipe inside the generator head.
  defp maybe_patch(
         {:|>, _,
          [
            coll,
            {{:., _, [{:__aliases__, _, [:Map]}, :new]}, _,
             [{:fn, _, [{:->, _, [[pattern], body]}]}]}
          ]} = node
       ) do
    cond do
      not simple_pattern?(pattern) ->
        []

      not tuple_pair?(body) ->
        []

      pipe_lhs?(coll) ->
        case lift_filter_chain(coll, pattern) do
          {:ok, base_coll, conditions} ->
            [replacement_patch(node, pattern, base_coll, body, conditions)]

          :skip ->
            []
        end

      true ->
        [replacement_patch(node, pattern, coll, body)]
    end
  end

  defp maybe_patch(_), do: []

  defp pipe_lhs?({:|>, _, _}), do: true
  defp pipe_lhs?(_), do: false

  # Peel filter/reject stages off a `|>`-chain in front of Map.new.
  # Returns `{:ok, base_coll, conditions}` where `conditions` is the
  # list of strings already rendered as splice-ready Elixir source.
  # Returns `:skip` as soon as any stage is not a liftable filter, so
  # we leave the whole expression alone (don't half-rewrite).
  defp lift_filter_chain(node, generator_var), do: lift_filter_chain(node, generator_var, [])

  defp lift_filter_chain(
         {:|>, _, [lhs, {{:., _, [{:__aliases__, _, [:Enum]}, kind]}, _, [pred]}]},
         generator_var,
         acc
       )
       when kind in [:filter, :reject] do
    render_predicate(pred, generator_var, kind)
    |> continue_lift_or_skip(acc, generator_var, lhs)
  end

  defp lift_filter_chain({:|>, _, _}, _generator_var, _acc), do: :skip
  defp lift_filter_chain(base, _generator_var, acc), do: {:ok, base, acc}

  # Render an Enum.filter / Enum.reject predicate as a `for`-guard
  # condition string, substituting `&1` (capture) or the lambda's own
  # parameter for the generator variable. `kind` is `:filter` (pass
  # condition through) or `:reject` (negate).
  defp render_predicate(predicate, generator_var, kind),
    do: predicate_to_expr(predicate, generator_var) |> render_predicate_text(kind)

  # Convert a predicate AST into an expression that references
  # `generator_var` instead of its own binding.
  #
  # - `& &1.foo`           → `generator_var.foo`
  # - `fn x -> body end`   → body with `x` substituted by `generator_var`
  #
  # Skip anything else (captures other than the single-arg `&1` form,
  # multi-clause lambdas, guarded lambdas, destructuring patterns) so
  # we don't risk a name clash or invalid splice.
  #
  # Function-reference captures `&name/arity` parse as `{:&, _, [{:/, _,
  # [name, arity]}]}` — they have no `&1` body to splice into; lifting
  # them produces `for x <- coll, name / 1 do …` (parse error). Reject.
  defp predicate_to_expr({:&, _, [{:/, _, [_, _]}]}, _generator_var), do: :skip

  defp predicate_to_expr({:&, _, [body]}, generator_var),
    do: body |> rebind_capture(generator_var)

  defp predicate_to_expr(
         {:fn, _, [{:->, _, [[{lambda_var, _, ctx}], body]}]},
         generator_var
       )
       when is_atom(lambda_var) and is_atom(ctx) do
    bare_var_name(generator_var) |> rebind_or_skip(body, lambda_var)
  end

  defp predicate_to_expr(_, _), do: :skip

  # Substitute every `&1` capture-arg in `body` with the generator var.
  # Reject the capture if it references `&2`, `&3`, ... (multi-arg).
  defp rebind_capture(body, generator_var) do
    {result, ok?} =
      Macro.prewalk(body, true, fn
        {:&, _, [n]}, _acc when is_integer(n) and n > 1 -> {nil, false}
        {:&, _, [1]}, acc -> {generator_var, acc}
        other, acc -> {other, acc}
      end)

    if ok?, do: {:ok, result}, else: :skip
  end

  # Substitute every bare reference to `from` in `ast` with a bare
  # reference to `to` (an atom). Other shapes pass through unchanged.
  defp rebind_var(ast, from, to) when is_atom(from) and is_atom(to) do
    Macro.prewalk(ast, fn
      {^from, meta, ctx} when is_atom(ctx) -> {to, meta, ctx}
      other -> other
    end)
  end

  defp bare_var_name({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {:ok, name}
  defp bare_var_name(_), do: :skip

  # Reject lambda arg patterns with a `when`-guard. Elixir wraps the
  # guard into the head pattern as `{:when, _, [pattern, guard]}`, and
  # splicing that verbatim into the comprehension head produces
  # `for x when is_map(x) <- coll do …` — `for/1` doesn't accept that
  # form (guards belong after a `,`), so the rewrite would be invalid.
  defp simple_pattern?({:when, _, _}), do: false
  defp simple_pattern?(_), do: true

  # Recognise the lambda body as a bare 2-tuple literal.
  #
  # Sourceror wraps every `do`/`->` body in a `{:__block__, meta, [expr]}`
  # node even when there's only one expression. The natural Lambda body
  # `fn r -> {r.id, r} end` therefore arrives as
  # `{:__block__, [], [{key, value}]}`. We unwrap that single-expression
  # block and inspect the inner node — if it's a 2-tuple at the AST
  # level, we have a pair.
  #
  # Explicitly parenthesised tuples `({k, v})` produce the same shape
  # *except* the outer `:__block__` carries a `:parens` meta key.
  # Reject those to keep the rewrite predictable (the test pins this).
  #
  # Multi-expression blocks (`a = …; {k, v}`), `if`/`case`/`with`
  # bodies, 3-tuples (`{:{}, _, [a, b, c]}`), and opaque calls all
  # fail the inner `is_tuple/tuple_size` check.
  defp tuple_pair?({:__block__, meta, [inner]}) when is_list(meta) do
    not Keyword.has_key?(meta, :parens) and is_tuple(inner) and tuple_size(inner) == 2
  end

  defp tuple_pair?(node), do: is_tuple(node) and tuple_size(node) == 2

  defp unwrap_pair_body({:__block__, _, [inner]}), do: inner
  defp unwrap_pair_body(other), do: other

  defp replacement_patch(node, pattern, coll, body, conditions \\ []) do
    pattern_str = Sourceror.to_string(strip_comments(pattern))
    coll_str = Sourceror.to_string(strip_comments(coll))
    body_str = body |> unwrap_pair_body() |> strip_comments() |> Sourceror.to_string()
    head_tail = conditions |> Enum.map_join(&(", " <> &1))

    replacement = """
    for #{pattern_str} <- #{coll_str}#{head_tail} do
      #{body_str}
    end
    |> Map.new()\
    """

    Patch.replace(node, replacement)
  end

  # Strip leading/trailing comment metadata from every node before
  # re-emitting via `Sourceror.to_string/1`. Without this, comments
  # attached to the original `Map.new` line get re-emitted both at
  # the replacement site AND wherever Sourceror originally tracked
  # them, doubling the comment in the patched source.
  defp strip_comments(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        {form, Keyword.drop(meta, [:leading_comments, :trailing_comments]), args}

      other ->
        other
    end)
  end

  defp apply_patches({:ok, ast}, source),
    do: walk_for_patches(ast, forbidden_nodes(ast)) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  defp continue_lift_or_skip({:ok, condition}, acc, generator_var, lhs),
    do: lhs |> lift_filter_chain(generator_var, [condition | acc])

  defp continue_lift_or_skip(:skip, _acc, _generator_var, _lhs), do: :skip

  defp render_predicate_text({:ok, expr_ast}, kind) do
    text = expr_ast |> strip_comments() |> Sourceror.to_string()

    case kind do
      :filter -> {:ok, text}
      :reject -> {:ok, "not " <> text}
    end
  end

  defp render_predicate_text(:skip, _kind), do: :skip

  defp rebind_or_skip({:ok, gen_name}, body, lambda_var),
    do: {:ok, rebind_var(body, lambda_var, gen_name)}

  defp rebind_or_skip(:skip, _body, _lambda_var), do: :skip
end
