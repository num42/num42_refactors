defmodule Number42.Refactors.Ex.FilterFirstToFind do
  @moduledoc """
  Rewrites `Enum.filter(coll, pred) |> List.first()` (and the
  `|> Enum.at(0)` and call-nested variants) to `Enum.find(coll, pred)`.

      coll |> Enum.filter(pred) |> List.first()  →  coll |> Enum.find(pred)
      coll |> Enum.filter(pred) |> Enum.at(0)    →  coll |> Enum.find(pred)
      Enum.filter(coll, pred) |> List.first()    →  Enum.find(coll, pred)
      Enum.filter(coll, pred) |> Enum.at(0)      →  Enum.find(coll, pred)
      List.first(Enum.filter(coll, pred))        →  Enum.find(coll, pred)
      Enum.at(Enum.filter(coll, pred), 0)        →  Enum.find(coll, pred)

  `filter |> first` evaluates `pred` against **every** element and
  builds the full match list, then discards all but the head.
  `Enum.find/2` stops at the first hit. Both return the first matching
  element, or `nil` when none match — so the rewrite is strictly less
  work for the same result.

  The piped forms re-thread onto the pipe to keep left-to-right reading
  order when `coll` is itself a multi-stage pipe; the call forms have no
  chain to preserve and keep the call shape (mirrors `MapSumToSumBy`).

  ## Scope — sound only on the narrow, provable set

  - Downstream must be exactly `List.first/1` or `Enum.at(_, 0)`.
    `Enum.at(coll, n)` with `n != 0` selects a later element — not the
    first match — and is skipped.
  - The 2-arg default forms (`List.first(list, default)`) are skipped in
    v1: `List.first/2` returns `default` on no match while `Enum.find/2`
    returns `nil`, and the arg order differs from `Enum.find/3`. A
    semantics-preserving rewrite would have to special-case the default,
    deferred.
  - `hd/1` is **not** matched: `hd([])` raises while `Enum.find` and
    `List.first` return `nil` — not equivalent.
  - `pred` must be side-effect-free for the early-stop to be
    observationally equivalent. We cannot prove purity, but we can spot
    the obvious offenders: a predicate that touches a known effect
    module (`IO`, `Logger`, `File`, `Process`, …), `send`s a message, or
    `raise`s/`throw`s is skipped rather than rewritten — short-circuiting
    such a predicate would fire its effect on fewer elements.
  - `Enum.filter` must be arity 2 (collection + predicate); other arities
    are not the matched shape.

  Operands splice via `slice_node/2` (original source bytes), not
  `Sourceror.to_string/1` — re-emission corrupts map-access and string
  escapes (see `UseMapJoin`).

  ## Idempotence

  `Enum.find(coll, pred)` has no `Enum.filter` chain; a second pass
  matches nothing.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  # Modules whose calls carry an observable effect — a predicate that
  # touches one of these is short-circuit-unsafe (same set the
  # pipe-flattening refactors gate on).
  @effect_modules ~w(Repo Logger GenServer File IO Agent Task Process)a

  # Bare effect/control forms that break observational equivalence under
  # early-stop.
  @effect_locals ~w(send raise reraise throw exit spawn)a

  @impl Number42.Refactors.Refactor
  def description,
    do: "Enum.filter(coll, pred) |> List.first()/Enum.at(0) -> Enum.find(coll, pred)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `filter |> first` runs the predicate against every element and
    builds the whole match list just to keep its head. `Enum.find/2`
    stops at the first match — same result (the first match, or `nil`),
    strictly less work.

    Only the provably-safe set rewrites: downstream exactly
    `List.first/1` or `Enum.at(_, 0)`, never `Enum.at(_, n != 0)` or
    `hd/1` (which raises on `[]`). The 2-arg `List.first(list, default)`
    is skipped — it returns `default` on no match where `Enum.find/2`
    returns `nil`. A predicate that performs IO, sends a message, or
    raises is skipped, since early-stop would change how often its
    effect fires.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 130
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast, source),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch(&1, source))
      |> drop_enclosing_patches()

  # A filter-first nested inside another filter-first yields overlapping
  # patches (outer + inner); submitting both corrupts the splice. Keep
  # the innermost only — the enclosing match is left for the engine's
  # fixpoint loop (same regression class as MapSumToSumBy / UseMapJoin).
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

  # List.first(Enum.filter(coll, pred))
  defp maybe_patch(
         {{:., _, [{:__aliases__, _, [:List]}, :first]}, _,
          [{{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, [coll, pred]}]} = node,
         source
       ),
       do: node |> rewrite(coll, pred, source, :call)

  # Enum.at(Enum.filter(coll, pred), 0)
  defp maybe_patch(
         {{:., _, [{:__aliases__, _, [:Enum]}, :at]}, _,
          [{{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, [coll, pred]}, index]} = node,
         source
       ),
       do: if(zero_index?(index), do: rewrite(node, coll, pred, source, :call), else: [])

  # coll |> Enum.filter(pred) |> List.first()
  defp maybe_patch(
         {:|>, _,
          [
            {:|>, _, [coll, {{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, [pred]}]},
            {{:., _, [{:__aliases__, _, [:List]}, :first]}, _, []}
          ]} = node,
         source
       ),
       do: node |> rewrite(coll, pred, source, :pipe)

  # coll |> Enum.filter(pred) |> Enum.at(0)
  defp maybe_patch(
         {:|>, _,
          [
            {:|>, _, [coll, {{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, [pred]}]},
            {{:., _, [{:__aliases__, _, [:Enum]}, :at]}, _, [index]}
          ]} = node,
         source
       ),
       do: if(zero_index?(index), do: rewrite(node, coll, pred, source, :pipe), else: [])

  # Enum.filter(coll, pred) |> List.first()
  defp maybe_patch(
         {:|>, _,
          [
            {{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, [coll, pred]},
            {{:., _, [{:__aliases__, _, [:List]}, :first]}, _, []}
          ]} = node,
         source
       ),
       do: node |> rewrite(coll, pred, source, :call)

  # Enum.filter(coll, pred) |> Enum.at(0)
  defp maybe_patch(
         {:|>, _,
          [
            {{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, [coll, pred]},
            {{:., _, [{:__aliases__, _, [:Enum]}, :at]}, _, [index]}
          ]} = node,
         source
       ),
       do: if(zero_index?(index), do: rewrite(node, coll, pred, source, :call), else: [])

  defp maybe_patch(_, _), do: []

  defp rewrite(_node, _coll, pred, _source, _form) when not is_tuple(pred), do: []

  defp rewrite(node, coll, pred, source, form) do
    with false <- impure_pred?(pred),
         {:ok, coll_text} <- slice_node(source, coll),
         {:ok, pred_text} <- slice_node(source, pred) do
      [Patch.replace(node, replacement(form, coll_text, pred_text))]
    else
      _ -> []
    end
  end

  defp replacement(:pipe, coll, pred), do: "#{coll} |> Enum.find(#{pred})"
  defp replacement(:call, coll, pred), do: "Enum.find(#{coll}, #{pred})"

  defp zero_index?(0), do: true
  defp zero_index?({:__block__, _, [0]}), do: true
  defp zero_index?(_), do: false

  defp impure_pred?(pred) do
    pred
    |> Macro.prewalker()
    |> Enum.any?(&effectful_node?/1)
  end

  defp effectful_node?({{:., _, [{:__aliases__, _, [mod | _]}, _fun]}, _, _args})
       when mod in @effect_modules,
       do: true

  defp effectful_node?({{:., _, [_mod, fun]}, _, _args}) when is_atom(fun), do: bang?(fun)
  defp effectful_node?({fun, _, args}) when fun in @effect_locals and is_list(args), do: true
  defp effectful_node?({fun, _, args}) when is_atom(fun) and is_list(args), do: bang?(fun)
  defp effectful_node?(_), do: false

  defp bang?(fun), do: fun |> Atom.to_string() |> String.ends_with?("!")

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
