defmodule Number42.Refactors.Ex.SortReverseToDesc do
  @moduledoc """
  Fuses a trailing `Enum.reverse/1` after an ascending sort into the
  sort's `:desc` direction.

      Enum.sort(coll) |> Enum.reverse()           →  Enum.sort(coll, :desc)
      Enum.sort_by(coll, fun) |> Enum.reverse()   →  Enum.sort_by(coll, fun, :desc)
      coll |> Enum.sort() |> Enum.reverse()       →  coll |> Enum.sort(:desc)

  `sort |> reverse` sorts ascending, materialises the sorted list, then
  walks it again to flip it. `Enum.sort/2` and `Enum.sort_by/3` accept a
  sort direction (`:asc` / `:desc`) and produce the descending order in
  one pass. The intent — "sort descending" — is stated rather than
  reconstructed from two steps.

  ## Matched shapes — exact by design

  Both surface forms rewrite:

      Enum.sort(coll) |> Enum.reverse()      (call-fed sort, 1 arg)
      coll |> Enum.sort() |> Enum.reverse()  (pipe-fed sort, 0 args)

  …and the `sort_by` analogue (2 / 1 args). The downstream step must be
  zero-arg `Enum.reverse/1` — `Enum.reverse(list, tail)` (arity 2) is a
  different operation and is left alone.

  ## Skips a sort that already carries a sorter/direction

  `Enum.sort(coll, &>=/2)`, `Enum.sort(coll, :asc)` or
  `Enum.sort_by(coll, fun, :asc)` already have their second/third arg
  filled. Appending `:desc` would blow the arity or change the meaning,
  so these pass through untouched. The gate is purely arity-based: the
  fused arg is only added when the slot is free.

  ## Stability caveat — known, accepted trade-off

  `Enum.sort/1` is **stable**: `sort |> reverse` flips the order of equal
  keys too, whereas `Enum.sort(coll, :desc)` keeps ties in their original
  relative order. For elements with **duplicate sort keys** the relative
  order of those ties differs after the rewrite, so this is **not**
  strictly behaviour-preserving when duplicate keys occur. The rewrite
  targets the dominant case — sortable values whose tie order is not
  observed — and treats the tie reordering as an accepted trade-off (in
  line with the project's best-effort rewrite policy).

  Because that trade-off is real rather than cosmetic, this refactor is
  **default-OFF**: `transform/2` is a no-op unless the module's opts carry
  `enabled: true`. Opt in per project where the trade is wanted:

      configured_modules: [
        {Number42.Refactors.Ex.SortReverseToDesc, enabled: true}
      ]

  ## Idempotence

  `Enum.sort(coll, :desc)` has no trailing `Enum.reverse`; a second pass
  matches nothing. Operands splice via `slice_node/2` (original source
  bytes), not `Sourceror.to_string/1`, to preserve exact source shape.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description,
    do: "Enum.sort(_) |> Enum.reverse() -> Enum.sort(_, :desc) (default-OFF)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `sort |> reverse` makes two passes — sort ascending, then walk the
    result to flip it — to express "sort descending". `Enum.sort/2` and
    `Enum.sort_by/3` take a `:desc` direction and produce that order in
    one pass, stating the intent directly.

    Caveat: `Enum.sort/1` is stable, so `sort |> reverse` reverses the
    order of equal keys while `sort(:desc)` preserves it. When duplicate
    sort keys exist the tie order differs — the rewrite is best-effort,
    targeting sortable values without observed ties, and is default-OFF
    (opt in with `enabled: true`).
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 130
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      source |> Sourceror.parse_string() |> apply_patches(source)
    else
      source
    end
  end

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

  # Enum.sort(coll) |> Enum.reverse()   — call-fed sort, free direction slot.
  defp maybe_patch(
         {:|>, _,
          [
            {{:., _, [{:__aliases__, _, [:Enum]}, :sort]}, _, [coll]},
            {{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, []}
          ]} = node,
         source
       ),
       do: rewrite(node, [coll], :sort, :call, source)

  # Enum.sort_by(coll, fun) |> Enum.reverse()   — call-fed sort_by.
  defp maybe_patch(
         {:|>, _,
          [
            {{:., _, [{:__aliases__, _, [:Enum]}, :sort_by]}, _, [coll, fun]},
            {{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, []}
          ]} = node,
         source
       ),
       do: rewrite(node, [coll, fun], :sort_by, :call, source)

  # coll |> Enum.sort() |> Enum.reverse()   — pipe-fed sort, free direction slot.
  defp maybe_patch(
         {:|>, _,
          [
            {:|>, _, [coll, {{:., _, [{:__aliases__, _, [:Enum]}, :sort]}, _, []}]},
            {{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, []}
          ]} = node,
         source
       ),
       do: rewrite(node, [coll], :sort, :pipe, source)

  # coll |> Enum.sort_by(fun) |> Enum.reverse()   — pipe-fed sort_by.
  defp maybe_patch(
         {:|>, _,
          [
            {:|>, _, [coll, {{:., _, [{:__aliases__, _, [:Enum]}, :sort_by]}, _, [fun]}]},
            {{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, []}
          ]} = node,
         source
       ),
       do: rewrite(node, [coll, fun], :sort_by, :pipe, source)

  defp maybe_patch(_, _), do: []

  defp rewrite(node, args, fun, form, source) do
    case slice_all(source, args) do
      {:ok, texts} -> [Patch.replace(node, replacement(form, fun, texts))]
      :skip -> []
    end
  end

  defp slice_all(source, args) do
    args
    |> Enum.reduce_while({:ok, []}, fn arg, {:ok, acc} ->
      case slice_node(source, arg) do
        {:ok, text} -> {:cont, {:ok, [text | acc]}}
        _ -> {:halt, :skip}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :skip -> :skip
    end
  end

  # Call form keeps the call shape; pipe form re-threads the collection
  # onto the chain so a multi-stage `coll` stays left-to-right.
  defp replacement(:call, :sort, [coll]), do: "Enum.sort(#{coll}, :desc)"
  defp replacement(:call, :sort_by, [coll, fun]), do: "Enum.sort_by(#{coll}, #{fun}, :desc)"
  defp replacement(:pipe, :sort, [coll]), do: "#{coll} |> Enum.sort(:desc)"
  defp replacement(:pipe, :sort_by, [coll, fun]), do: "#{coll} |> Enum.sort_by(#{fun}, :desc)"

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
