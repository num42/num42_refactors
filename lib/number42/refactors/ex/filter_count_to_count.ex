defmodule Number42.Refactors.Ex.FilterCountToCount do
  @moduledoc """
  Rewrites `Enum.filter(coll, pred) |> Enum.count()` to `Enum.count(coll, pred)`.

  Filtering then counting builds an intermediate list solely to measure
  its length; `Enum.count/2` already takes a predicate and folds both
  steps into a single pass with no temporary allocation. Sits next to
  `MapSumToSumBy`, which fuses the same map-then-aggregate shape.

  ## Surface forms

  All three shapes rewrite:

      coll |> Enum.filter(pred) |> Enum.count()  →  coll |> Enum.count(pred)
      Enum.filter(coll, pred) |> Enum.count()    →  Enum.count(coll, pred)
      Enum.count(Enum.filter(coll, pred))        →  Enum.count(coll, pred)

  The piped form re-threads onto the chain to keep the left-to-right
  reading order when `coll` is itself a multi-stage pipe; the call
  forms have no chain to preserve and keep the call shape (mirrors
  `MapSumToSumBy`).

  ## Scope

  Only the **zero-arg `Enum.count/1`** downstream matches — `Enum.count/2`
  is already the target and is left alone (idempotence). `Enum.filter`
  must be exactly arity 2 (`coll`, `pred`); any other arity is skipped.

  `pred` is fused only in the standard predicate forms — a `fn` lambda
  or a capture (`&active?/1`, `& &1.active`). A bare variable or other
  expression is left alone: `count` walks every element regardless, so
  the fusion is semantically safe, but restricting to lambda/capture
  keeps the rewrite to the shapes the reader recognises as predicates.

  Operands splice via `slice_node/2` (original source bytes), not
  `Sourceror.to_string/1` — re-emission corrupts map-access and string
  escapes (see `UseMapJoin`).

  ## Idempotence

  `Enum.count(coll, pred)` has no `Enum.filter`/zero-arg-`Enum.count`
  chain; a second pass matches nothing.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Enum.filter(coll, pred) |> Enum.count() -> Enum.count(coll, pred)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `filter` then `count` is two passes over the data and an intermediate
    list that exists only to have its length taken. `Enum.count/2` fuses
    the predicate and the tally into a single pass with no temporary
    allocation — and reads as a single intent: "how many elements satisfy
    this predicate", which is what the pipeline meant.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 130
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  @impl Number42.Refactors.Refactor
  def patches(ast, source, _opts), do: build_patches(ast, source)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast, source),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch(&1, source))
      |> drop_enclosing_patches()

  # Nested filter/count chains yield overlapping patches (outer + inner);
  # submitting both corrupts the splice — keep the innermost only
  # (same regression class as MapSumToSumBy / UseMapJoin).
  defp drop_enclosing_patches(patches) do
    patches
    |> Enum.reject(fn p ->
      patches |> Enum.any?(fn other -> other != p and encloses?(p.range, other.range) end)
    end)
  end

  defp encloses?(outer, inner),
    do:
      pos_le(outer.start, inner.start) and pos_le(inner.end, outer.end) and
        not (pos_eq(outer.start, inner.start) and pos_eq(outer.end, inner.end))

  defp pos_eq(a, b), do: a[:line] == b[:line] and a[:column] == b[:column]
  defp pos_le(a, b), do: {a[:line], a[:column]} <= {b[:line], b[:column]}

  # Enum.count(Enum.filter(coll, pred))
  defp maybe_patch(
         {{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _,
          [{{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, [coll, pred]}]} = node,
         source
       ),
       do: node |> rewrite(coll, pred, source, :call)

  # coll |> Enum.filter(pred) |> Enum.count()
  defp maybe_patch(
         {:|>, _,
          [
            {:|>, _, [coll, {{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, [pred]}]},
            {{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, []}
          ]} = node,
         source
       ),
       do: node |> rewrite(coll, pred, source, :pipe)

  # Enum.filter(coll, pred) |> Enum.count()
  defp maybe_patch(
         {:|>, _,
          [
            {{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, [coll, pred]},
            {{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, []}
          ]} = node,
         source
       ),
       do: node |> rewrite(coll, pred, source, :call)

  defp maybe_patch(_, _), do: []

  defp rewrite(node, coll, pred, source, form) do
    with true <- predicate?(pred),
         {:ok, coll_text} <- slice_node(source, coll),
         {:ok, pred_text} <- slice_node(source, pred) do
      [Patch.replace(node, replacement(form, coll_text, pred_text))]
    else
      _ -> []
    end
  end

  # Standard predicate shapes: a capture (&name/1, &Mod.name/1, & &1.x)
  # or an explicit `fn` lambda. Bare vars and other expressions skip.
  defp predicate?({:&, _, _}), do: true
  defp predicate?({:fn, _, _}), do: true
  defp predicate?(_), do: false

  defp replacement(:pipe, coll, pred), do: "#{coll} |> Enum.count(#{pred})"
  defp replacement(:call, coll, pred), do: "Enum.count(#{coll}, #{pred})"
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
