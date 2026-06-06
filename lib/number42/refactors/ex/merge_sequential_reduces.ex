defmodule Number42.Refactors.Ex.MergeSequentialReduces do
  @moduledoc """
  Fuses two adjacent `Enum.reduce/3` statements over the *same* source
  collection into a single pass with a tuple accumulator.

      sum = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
      count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
      ↓
      {sum, count} =
        Enum.reduce(xs, {0, 0}, fn elem, {acc1, acc2} -> {acc1 + x, acc2 + 1} end)

  Two reduces traverse the collection twice; the fused pass traverses
  it once. The element-binding patterns of both lambdas collapse onto a
  single fresh element parameter; the two accumulators ride in a tuple.

  ## What we match

  - Two **adjacent** statements in a block, each
    `lhs = Enum.reduce(coll, init, fn elem, acc -> body end)`.
  - Both LHS are distinct bare variables.
  - Both lambdas are single-clause `fn elem, acc -> body end` with
    **bare-variable** element and accumulator patterns (destructured
    patterns are left for a human).
  - The two `coll` ASTs are structurally identical.

  ## Why these statements must be adjacent

  Adjacency guarantees nothing rebinds the source collection between the
  two reduces. A `xs = ...` (or any statement) in between is left alone:
  the reduces might be reading different bindings of `xs`, and proving
  otherwise is out of scope. Safety over reach.

  ## Preconditions / SKIP list

  - ⚠ The source must be a **materialised, pure collection** — `pure?/1`
    rejects `Stream.*`, `File.stream!/1`, bang calls, and any lazy or
    side-effecting enumerable. A lazy source yields/side-effects per
    traversal, so 2× → 1× changes observable behaviour. SKIP.
  - Both reducer bodies must be **pure** (`pure?/1`). Shared side
    effects would interleave differently after fusion. SKIP otherwise.
  - **Both results must live** after the pair (each LHS is read by a
    later statement in the block). If only one is used, there is nothing
    to fuse. SKIP.
  - Neither body may **shadow** (rebind) any lambda parameter name —
    that would make the bare-variable rename unsafe. SKIP.

  ## Idempotence

  After fusion there is a single `Enum.reduce/3` whose accumulator is a
  tuple, bound to a `{a, b}` pattern. There is no longer a *pair* of
  reduces over the same collection, so a second pass finds no match.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Fuse two Enum.reduce/3 over the same collection into one tuple pass"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Two `Enum.reduce/3` calls over the same list walk it twice for two
    independent accumulations the reader has to mentally pair up. Folding
    them into one pass with a tuple accumulator states the relationship
    directly — these values are derived together, in one traversal — and
    halves the work on the hot path.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 150
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&block_patches/1)

  defp block_patches({:__block__, _, stmts}) when is_list(stmts),
    do: disjoint_pairs(stmts, 0, [])

  defp block_patches(_), do: []

  # Walk statements left-to-right; on a fusable adjacent pair emit one
  # patch and skip past both. Consuming both keeps the emitted patch
  # ranges disjoint — overlapping ranges would corrupt `patch_string`
  # (three reduces in a row produce two overlapping candidate pairs).
  defp disjoint_pairs(stmts, index, acc) do
    case Enum.drop(stmts, index) do
      [first, second | _] ->
        case pair_patch(first, second, stmts, index) do
          [patch] -> disjoint_pairs(stmts, index + 2, [patch | acc])
          [] -> disjoint_pairs(stmts, index + 1, acc)
        end

      _ ->
        Enum.reverse(acc)
    end
  end

  defp pair_patch(first, second, stmts, index) do
    with {:ok, a} <- classify(first),
         {:ok, b} <- classify(second),
         true <- fusable?(a, b, stmts, index) do
      range = %{start: Sourceror.get_range(first).start, end: Sourceror.get_range(second).end}
      [Patch.new(range, render(a, b), false)]
    else
      _ -> []
    end
  end

  defp classify(
         {:=, _, [lhs, {{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [coll, init, fun]}]}
       ) do
    with {:ok, name} <- bare_var(lhs),
         {:ok, elem, acc, body} <- reducer(fun) do
      {:ok, %{name: name, coll: coll, init: init, elem: elem, acc: acc, body: body}}
    else
      _ -> :skip
    end
  end

  defp classify(_), do: :skip

  defp reducer({:fn, _, [{:->, _, [[elem_pat, acc_pat], body]}]}) do
    with {:ok, elem} <- elem_var(elem_pat),
         {:ok, acc} <- bare_var(acc_pat),
         {:ok, expr} <- single_expr(body) do
      {:ok, elem, acc, expr}
    else
      _ -> :skip
    end
  end

  defp reducer(_), do: :skip

  # The fused body becomes a tuple element `{body_a, body_b}` — only a
  # single expression fits there. A multi-statement block (internal
  # `acc = ...` rebinds, sequencing) is left alone.
  defp single_expr({:__block__, _, [expr]}), do: {:ok, expr}
  defp single_expr({:__block__, _, _}), do: :skip
  defp single_expr(expr), do: {:ok, expr}

  # The element pattern may be ignored (`_`, `_x`) — a counting reducer
  # never reads it. Accept any bare variable, underscored or not; the
  # accumulator pattern below must be a real (read) bare variable.
  defp elem_var({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {:ok, name}
  defp elem_var(_), do: :skip

  defp fusable?(a, b, stmts, index) do
    a.name != b.name and
      same_collection?(a.coll, b.coll) and
      pure?(a.coll) and pure?(b.coll) and
      pure?(a.body) and pure?(b.body) and
      not shadows_param?(a) and not shadows_param?(b) and
      both_results_live?(a.name, b.name, stmts, index)
  end

  defp same_collection?(coll_a, coll_b), do: strip_meta(coll_a) == strip_meta(coll_b)

  defp shadows_param?(%{elem: elem, acc: acc, body: body}) do
    bound = bound_in(body)
    MapSet.member?(bound, elem) or MapSet.member?(bound, acc)
  end

  defp both_results_live?(name_a, name_b, stmts, index) do
    read_after?(name_a, stmts, index + 1) and read_after?(name_b, stmts, index + 1)
  end

  defp render(a, b) do
    elem = fresh(:elem, [a, b])
    acc1 = fresh(:acc1, [a, b])
    acc2 = fresh(:acc2, [a, b])

    body_a = rename(a.body, %{a.elem => elem, a.acc => acc1})
    body_b = rename(b.body, %{b.elem => elem, b.acc => acc2})

    coll = Sourceror.to_string(a.coll)
    init = "{#{Sourceror.to_string(a.init)}, #{Sourceror.to_string(b.init)}}"

    lambda =
      "fn #{elem}, {#{acc1}, #{acc2}} -> " <>
        "{#{Sourceror.to_string(body_a)}, #{Sourceror.to_string(body_b)}} end"

    "{#{a.name}, #{b.name}} = Enum.reduce(#{coll}, #{init}, #{lambda})"
  end

  # A fresh name = the preferred base, suffixed with an integer until it
  # collides with nothing referenced in either reducer's body, init, or
  # collection. Guarantees the tuple-accumulator rename cannot capture.
  defp fresh(base, halves) do
    taken = halves |> Enum.flat_map(&half_names/1) |> MapSet.new()
    pick(base, taken, nil)
  end

  defp half_names(%{coll: coll, init: init, body: body, elem: elem, acc: acc}) do
    [coll, init, body]
    |> Enum.flat_map(&MapSet.to_list(used_var_names(&1)))
    |> List.delete(elem)
    |> List.delete(acc)
  end

  defp pick(base, taken, suffix) do
    candidate = candidate_name(base, suffix)

    if MapSet.member?(taken, candidate),
      do: pick(base, taken, (suffix || 0) + 1),
      else: candidate
  end

  defp candidate_name(base, nil), do: base
  defp candidate_name(base, suffix), do: :"#{base}#{suffix}"

  # Substitute bare-variable references by `mapping`. Safe because the
  # caller has verified the body neither shadows nor re-binds any of the
  # names involved (`shadows_param?/1`), so a flat prewalk cannot capture.
  defp rename(body, mapping) do
    Macro.prewalk(body, fn
      {name, meta, ctx} when is_atom(name) and is_atom(ctx) ->
        {Map.get(mapping, name, name), meta, ctx}

      other ->
        other
    end)
  end

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
