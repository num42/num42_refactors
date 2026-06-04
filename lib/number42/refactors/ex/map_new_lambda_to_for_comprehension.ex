defmodule Number42.Refactors.Ex.MapNewLambdaToForComprehension do
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

  ## Threshold — single-line bodies are left alone

  A one-line `Map.new(coll, fn x -> {k, v} end)` is *already* compact;
  expanding it to a 3-line `for`/`|> Map.new()` block pays a verbosity
  tax for composability that the call site isn't using. So the bare
  and simple-pipe expansions only fire when the lambda's tuple body
  spans **≥ 2 source lines** (measured via `Sourceror.get_range/1`),
  where the vertical room already exists and the `for` head becomes a
  natural slot for a later filter or local binding.

  The one exception is the **filter/reject lift** below: when a
  `coll |> Enum.filter(...) |> Map.new(fn)` pipeline collapses into a
  single `for x <- coll, cond do … end`, the rewrite *removes* a pipe
  stage — a structural win — so it fires regardless of body length.

  This also fixes the asymmetric-nesting wart from issue #16: a nested
  inner `Map.new(keys, fn {k, v} -> {…, v} end)` with a single-line
  body is now below the threshold and stays put, instead of being
  expanded while its multi-statement outer sibling is left untouched.

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

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description,
    do: "Map.new(coll, fn x -> {k, v} end) -> for x <- coll, do: {k, v} |> Map.new()"

  @impl Number42.Refactors.Refactor
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

    It also only fires when the tuple body spans two or more lines: a
    one-liner is already compact, so expanding it would cost three
    lines for composability the call site isn't using. The lone
    exception is when an `Enum.filter`/`reject` stage folds into the
    comprehension head — that removes a pipe stage, so it's worth it
    even for a one-line body.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 170
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp apply_patches({:ok, ast}, source),
    do: walk_for_patches(ast, forbidden_nodes(ast)) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source
  defp bare_var_name({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {:ok, name}
  defp bare_var_name(_), do: :skip
  defp children_of({_form, _meta, args}) when is_list(args), do: args
  defp children_of(_), do: []

  defp continue_lift_or_skip({:ok, condition}, acc, generator_var, lhs),
    do: lhs |> lift_filter_chain(generator_var, [condition | acc])

  defp continue_lift_or_skip(:skip, _acc, _generator_var, _lhs), do: :skip

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
  defp map_new_call?({{:., _, [{:__aliases__, _, [:Map]}, :new]}, _, [_, {:fn, _, _}]}), do: true

  defp map_new_call?(
         {:|>, _, [_, {{:., _, [{:__aliases__, _, [:Map]}, :new]}, _, [{:fn, _, _}]}]}
       ),
       do: true

  defp map_new_call?(_), do: false

  defp maybe_forbid(value, acc) do
    if map_new_call?(value), do: MapSet.put(acc, node_key(value)), else: acc
  end

  defp maybe_patch(
         {{:., _, [{:__aliases__, _, [:Map]}, :new]}, _,
          [coll, {:fn, _, [{:->, _, [[pattern], body]}]}]} = node
       ) do
    if simple_pattern?(pattern) and tuple_pair?(body) and multi_line_body?(body),
      do: [replacement_patch(node, pattern, coll, body)],
      else: []
  end

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
            patch_if_worth_it(node, pattern, base_coll, body, conditions)

          :skip ->
            []
        end

      multi_line_body?(body) ->
        [replacement_patch(node, pattern, coll, body)]

      true ->
        []
    end
  end

  defp maybe_patch(_), do: []

  # A lifted filter chain (non-empty conditions) collapses a pipe stage —
  # a structural win that earns the `for` shape regardless of body length.
  # With no lifted conditions, fall back to the line-span threshold.
  defp patch_if_worth_it(node, pattern, coll, body, [_ | _] = conditions),
    do: [replacement_patch(node, pattern, coll, body, conditions)]

  defp patch_if_worth_it(node, pattern, coll, body, []) do
    if multi_line_body?(body),
      do: [replacement_patch(node, pattern, coll, body)],
      else: []
  end

  # Threshold (issue #16): a single-line tuple body — `fn x -> {k, v} end`
  # — pays a 2-line verbosity tax for composability nobody is using, so we
  # leave it. A body whose tuple already spans ≥ 2 source lines has the
  # vertical room; the `for`/`|> Map.new()` shape costs nothing extra and
  # opens a natural slot for filters and local bindings.
  defp multi_line_body?(body) do
    case Sourceror.get_range(body) do
      %Sourceror.Range{start: start_pos, end: end_pos} ->
        Keyword.fetch!(end_pos, :line) > Keyword.fetch!(start_pos, :line)

      nil ->
        false
    end
  end

  defp node_key({_, meta, _} = node) when is_list(meta),
    do: {:erlang.phash2(node), Keyword.get(meta, :line), Keyword.get(meta, :column)}

  defp node_key(node), do: {:erlang.phash2(node), nil, nil}
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
  defp pipe_lhs?({:|>, _, _}), do: true
  defp pipe_lhs?(_), do: false
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

  defp rebind_capture(body, generator_var) do
    {result, ok?} =
      Macro.prewalk(body, true, fn
        {:&, _, [n]}, _acc when is_integer(n) and n > 1 -> {nil, false}
        {:&, _, [1]}, acc -> {generator_var, acc}
        other, acc -> {other, acc}
      end)

    if ok?, do: {:ok, result}, else: :skip
  end

  defp rebind_or_skip({:ok, gen_name}, body, lambda_var),
    do: {:ok, rebind_var(body, lambda_var, gen_name)}

  defp rebind_or_skip(:skip, _body, _lambda_var), do: :skip

  defp rebind_var(ast, from, to) when is_atom(from) and is_atom(to) do
    Macro.prewalk(ast, fn
      {^from, meta, ctx} when is_atom(ctx) -> {to, meta, ctx}
      other -> other
    end)
  end

  defp render_predicate(predicate, generator_var, kind),
    do: predicate_to_expr(predicate, generator_var) |> render_predicate_text(kind)

  defp render_predicate_text({:ok, expr_ast}, kind) do
    text = expr_ast |> strip_comments() |> Sourceror.to_string()

    case kind do
      :filter -> {:ok, text}
      :reject -> {:ok, "not " <> text}
    end
  end

  defp render_predicate_text(:skip, _kind), do: :skip

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

  defp simple_pattern?({:when, _, _}), do: false
  defp simple_pattern?(_), do: true

  defp strip_comments(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        {form, Keyword.drop(meta, [:leading_comments, :trailing_comments]), args}

      other ->
        other
    end)
  end

  defp tuple_pair?({:__block__, meta, [inner]}) when is_list(meta) do
    not Keyword.has_key?(meta, :parens) and is_tuple(inner) and tuple_size(inner) == 2
  end

  defp tuple_pair?(node), do: is_tuple(node) and tuple_size(node) == 2
  defp unwrap_pair_body({:__block__, _, [inner]}), do: inner
  defp unwrap_pair_body(other), do: other
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
end
