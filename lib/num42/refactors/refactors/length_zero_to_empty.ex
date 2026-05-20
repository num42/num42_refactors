defmodule Num42.Refactors.Refactors.LengthZeroToEmpty do
  @moduledoc """
  Rewrites `length(x)`/`Enum.count(x)` comparisons against `0` to the
  named operations they actually express:

      Enum.count(x) == 0   →   Enum.empty?(x)
      length(x) > 0        →   not Enum.empty?(x)

      Enum.count(x, fun) > 0   →   Enum.any?(x, fun)
      Enum.count(x, fun) == 0  →   not Enum.any?(x, fun)

  Mirrors the spirit of Quokka's "length-zero" rewrites in
  `Style.SingleNode`. Catches all eight comparison shapes
  (`== 0`, `!= 0`, `> 0`, `0 == _`, `0 != _`, `0 < _`, etc.) and the
  pipe forms (`x |> length() == 0`).

  ## Why these are real wins, not just style

  - **`length/1` is O(n)** on lists; `Enum.empty?/1` is O(1). On a
    list of size 10⁶ this is millions of cons-cell traversals
    replaced by a single pattern match.
  - **`Enum.count(x, fun) > 0`** evaluates `fun` for *every* element
    even after the first hit. `Enum.any?/2` short-circuits on the
    first truthy result. With an expensive predicate the saving
    can be orders of magnitude.
  - **`Enum.count(x) == 0`** materialises a count that's then
    discarded; `Enum.empty?/1` answers the question directly.

  ## Guard context

  `Enum.empty?/1` is **not allowed in guards** — guards may only
  call a fixed set of BIFs (`length/1` is one, `Enum.empty?/1`
  isn't). When a `length(x) == 0` comparison appears in a `when`
  clause, we rewrite to `x == []` instead, mirroring Quokka's
  decision.

  Note this changes the failure mode subtly: `length(x) == 0`
  raises `BadArg` if `x` isn't a list, while `x == []` evaluates
  to `false`. We accept this trade because (a) Quokka does the
  same and (b) writing `length(x)` in a guard already implies the
  caller expects a list. For the `!= 0` case we wrap with
  `is_list(x) and x != []` to preserve the list-ness assertion.

  `Enum.count` is left alone in guards — it's not callable there
  in the first place, so encountering it inside a `when` is
  user-supplied dead code that the compiler will reject anyway.

  ## What we match

  Comparison operators `==`, `!=`, `>`, `<` (the latter only with
  `0` on the LEFT, since `> 0` and `< 0` of `count`/`length` mean
  opposite things). Either operand may be the count/length call
  and the literal `0`.

  ## Idempotence

  After rewriting, the AST contains `Enum.empty?` or `Enum.any?`
  calls — neither matches our comparison patterns, so a second
  pass is a no-op.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Num42.Refactors.Refactor
  def description, do: "length/Enum.count == 0 / > 0 -> Enum.empty?/Enum.any?"

  @impl Num42.Refactors.Refactor
  def priority, do: 130

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    `length(x) == 0` and `Enum.count(x) > 0` are answers to the
    questions "is this empty?" and "does this have anything?" expressed
    via a count + comparison. The named functions `Enum.empty?/1` and
    `Enum.any?/1` answer the same questions directly — and they're
    cheaper. `Enum.empty?/1` is O(1); `length/1` is O(n) on lists.
    `Enum.any?/2` short-circuits on the first hit; `Enum.count/2`
    walks the entire collection. Replacing the comparison forms gives
    you both a clearer call site and (sometimes dramatic) runtime
    savings.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_patches(ast) do
    guard_nodes = collect_guard_nodes(ast)

    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&maybe_patch(&1, guard_nodes))
  end

  # Collect every node that lives inside a `when` guard. Guards have
  # different rewrite rules (Enum.empty? not allowed). We mark all
  # descendants of the guard subtree as "in-guard".
  defp collect_guard_nodes(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:when, _, [_inner, guard]} ->
        guard |> Macro.prewalker() |> Enum.to_list()

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp maybe_patch({op, _, [lhs, rhs]} = node, guard_nodes)
       when op in [:==, :!=, :>, :<] do
    in_guard? = MapSet.member?(guard_nodes, node)

    classify(op, lhs, rhs)
    |> dispatch_rewrite(node, in_guard?)
  end

  defp maybe_patch(_, _), do: []

  # In a guard, only `length`-shaped comparisons can be rewritten —
  # `Enum.count` isn't even callable there, but if someone wrote it
  # the compiler will reject it; we should leave it for them to see.
  # We tag classified results with their source kind so we can filter.
  defp dispatch_rewrite({:empty, coll, :length}, node, true),
    do: [Patch.replace(node, "#{unwrap_coll_text(coll)} == []")]

  defp dispatch_rewrite({:nonempty, coll, :length}, node, true) do
    coll_text = unwrap_coll_text(coll)
    [Patch.replace(node, "is_list(#{coll_text}) and #{coll_text} != []")]
  end

  defp dispatch_rewrite({_, _, _}, _node, true), do: []
  defp dispatch_rewrite({_, _, _, _}, _node, true), do: []

  defp dispatch_rewrite({:empty, coll, _}, node, false),
    do: [Patch.replace(node, render_empty(coll))]

  defp dispatch_rewrite({:nonempty, coll, _}, node, false),
    do: [Patch.replace(node, render_nonempty(coll))]

  defp dispatch_rewrite({:any, coll, fun, _}, node, false),
    do: [Patch.replace(node, render_any(coll, fun))]

  defp dispatch_rewrite({:none, coll, fun, _}, node, false),
    do: [Patch.replace(node, render_none(coll, fun))]

  defp dispatch_rewrite(:skip, _node, _in_guard?), do: []

  # `==` / `!=` are symmetric in their operands; `>` and `<` aren't.
  # `count > 0` and `0 < count` both mean "non-empty"; `count < 0` and
  # `0 > count` are nonsensical and we leave them alone.
  defp classify(:==, lhs, rhs) do
    cond do
      zero?(rhs) and call_info(lhs) != :skip -> empty_classify(call_info(lhs))
      zero?(lhs) and call_info(rhs) != :skip -> empty_classify(call_info(rhs))
      true -> :skip
    end
  end

  defp classify(:!=, lhs, rhs) do
    cond do
      zero?(rhs) and call_info(lhs) != :skip -> nonempty_classify(call_info(lhs))
      zero?(lhs) and call_info(rhs) != :skip -> nonempty_classify(call_info(rhs))
      true -> :skip
    end
  end

  defp classify(:>, lhs, rhs) do
    if zero?(rhs) and call_info(lhs) != :skip do
      nonempty_classify(call_info(lhs))
    else
      :skip
    end
  end

  defp classify(:<, lhs, rhs) do
    if zero?(lhs) and call_info(rhs) != :skip do
      nonempty_classify(call_info(rhs))
    else
      :skip
    end
  end

  defp empty_classify({:length, coll}), do: {:empty, coll, :length}
  defp empty_classify({:enum_count, coll}), do: {:empty, coll, :enum_count}
  defp empty_classify({:enum_count_with_fun, coll, fun}), do: {:none, coll, fun, :enum_count}

  defp nonempty_classify({:length, coll}), do: {:nonempty, coll, :length}
  defp nonempty_classify({:enum_count, coll}), do: {:nonempty, coll, :enum_count}
  defp nonempty_classify({:enum_count_with_fun, coll, fun}), do: {:any, coll, fun, :enum_count}

  # Identify the AST shapes we care about as the "size side" of the
  # comparison: `length(x)`, `Enum.count(x)`, `Enum.count(x, fun)`,
  # plus all three in pipe form.
  defp call_info({:length, _, [coll]}), do: {:length, coll}

  defp call_info({{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, [coll]}),
    do: {:enum_count, coll}

  defp call_info({{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, [coll, fun]}),
    do: {:enum_count_with_fun, coll, fun}

  # Pipe forms: the left side of `|>` is the collection.
  defp call_info({:|>, _, [coll, {:length, _, []}]}),
    do: {:length, {:__pipe__, coll}}

  defp call_info({:|>, _, [coll, {{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, []}]}),
    do: {:enum_count, {:__pipe__, coll}}

  defp call_info({:|>, _, [coll, {{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, [fun]}]}),
    do: {:enum_count_with_fun, {:__pipe__, coll}, fun}

  defp call_info(_), do: :skip

  defp zero?({:__block__, _, [0]}), do: true
  defp zero?(0), do: true
  defp zero?(_), do: false

  # `coll` is either an AST node, or `{:__pipe__, lhs}` marking the
  # collection as the LHS of a pipe stage we need to reconstruct.
  defp render_empty({:__pipe__, lhs}), do: "#{Sourceror.to_string(lhs)} |> Enum.empty?()"

  defp render_empty(coll), do: "Enum.empty?(#{Sourceror.to_string(coll)})"

  defp render_nonempty({:__pipe__, lhs}), do: "not (#{Sourceror.to_string(lhs)} |> Enum.empty?())"

  defp render_nonempty(coll), do: "not Enum.empty?(#{Sourceror.to_string(coll)})"

  defp render_any({:__pipe__, lhs}, fun),
    do: "#{Sourceror.to_string(lhs)} |> Enum.any?(#{Sourceror.to_string(fun)})"

  defp render_any(coll, fun),
    do: "Enum.any?(#{Sourceror.to_string(coll)}, #{Sourceror.to_string(fun)})"

  defp render_none({:__pipe__, lhs}, fun),
    do: "not (#{Sourceror.to_string(lhs)} |> Enum.any?(#{Sourceror.to_string(fun)}))"

  defp render_none(coll, fun),
    do: "not Enum.any?(#{Sourceror.to_string(coll)}, #{Sourceror.to_string(fun)})"

  defp unwrap_coll_text({:__pipe__, lhs}), do: Sourceror.to_string(lhs)
  defp unwrap_coll_text(coll), do: Sourceror.to_string(coll)

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
