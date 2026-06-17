defmodule Number42.Refactors.Ex.MapSumToSumBy do
  @moduledoc """
  Rewrites `Enum.map(coll, fun) |> Enum.sum()` to `Enum.sum_by(coll, fun)`.

  Mapping then summing allocates an intermediate list of numbers solely
  to fold it; `Enum.sum_by/2` does the projection and the addition in a
  single pass. Sits right next to `EnumReduceToSum`, which rewrites
  summing `Enum.reduce/3` lambdas to the same target.

  Requires Elixir >= 1.18, where `Enum.sum_by/2` was introduced — the
  project floor (`~> 1.18`) satisfies this.

  ## Surface forms

  All three shapes rewrite:

      coll |> Enum.map(fun) |> Enum.sum()   →  coll |> Enum.sum_by(fun)
      Enum.map(coll, fun) |> Enum.sum()     →  Enum.sum_by(coll, fun)
      Enum.sum(Enum.map(coll, fun))         →  Enum.sum_by(coll, fun)

  The piped form re-threads onto the chain to keep the left-to-right
  reading order when `coll` is itself a multi-stage pipe; the call
  forms have no chain to preserve and keep the call shape (mirrors
  `UseMapJoin`).

  ## Scope

  Only the zero-arg `Enum.sum/1` downstream matches. Operands splice
  via `slice_node/2` (original source bytes), not `Sourceror.to_string/1`
  — re-emission corrupts map-access and string escapes (see `UseMapJoin`).

  ## Idempotence

  `Enum.sum_by(coll, fun)` has no `Enum.map`/`Enum.sum` chain; a second
  pass matches nothing.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Enum.map(coll, fun) |> Enum.sum() -> Enum.sum_by(coll, fun)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `map` then `sum` is two passes over the data and an intermediate
    list of numbers that exists only to be folded away. `Enum.sum_by/2`
    (Elixir 1.18+) fuses projection and addition into a single pass —
    and the call site reads as "sum this projection", which is what the
    original pipeline meant.
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

  # Nested map/sum chains yield overlapping patches (outer + inner);
  # submitting both corrupts the splice — keep the innermost only
  # (same regression class as UseMapJoin).
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

  # Enum.sum(Enum.map(coll, fun))
  defp maybe_patch(
         {{:., _, [{:__aliases__, _, [:Enum]}, :sum]}, _,
          [{{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [coll, fun]}]} = node,
         source
       ),
       do: node |> rewrite(coll, fun, source, :call)

  # coll |> Enum.map(fun) |> Enum.sum()
  defp maybe_patch(
         {:|>, _,
          [
            {:|>, _, [coll, {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [fun]}]},
            {{:., _, [{:__aliases__, _, [:Enum]}, :sum]}, _, []}
          ]} = node,
         source
       ),
       do: node |> rewrite(coll, fun, source, :pipe)

  # Enum.map(coll, fun) |> Enum.sum()
  defp maybe_patch(
         {:|>, _,
          [
            {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [coll, fun]},
            {{:., _, [{:__aliases__, _, [:Enum]}, :sum]}, _, []}
          ]} = node,
         source
       ),
       do: node |> rewrite(coll, fun, source, :call)

  defp maybe_patch(_, _), do: []

  defp rewrite(node, coll, fun, source, form) do
    case {slice_node(source, coll), slice_node(source, fun)} do
      {{:ok, coll_text}, {:ok, fun_text}} ->
        [Patch.replace(node, replacement(form, coll_text, fun_text))]

      _ ->
        []
    end
  end

  defp replacement(:pipe, coll, fun), do: "#{coll} |> Enum.sum_by(#{fun})"
  defp replacement(:call, coll, fun), do: "Enum.sum_by(#{coll}, #{fun})"
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
