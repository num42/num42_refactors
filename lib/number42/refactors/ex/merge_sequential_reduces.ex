defmodule Number42.Refactors.Ex.MergeSequentialReduces do
  @moduledoc """
  Fuses a run of **two or more** adjacent `Enum.reduce/3` statements over
  the *same* source collection into a single pass with an n-tuple
  accumulator.

      sum = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
      count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
      product = Enum.reduce(xs, 1, fn x, acc -> acc * x end)
      ↓
      {sum, count, product} =
        Enum.reduce(xs, {0, 0, 1}, fn elem, {acc1, acc2, acc3} ->
          {acc1 + elem, acc2 + 1, acc3 * elem}
        end)

  N reduces traverse the collection N times; the fused pass traverses it
  once. The element-binding patterns of every lambda collapse onto a
  single fresh element parameter; the N accumulators ride in a tuple.

  ## What we match

  - A maximal run of **adjacent** statements in a block, each
    `lhs = Enum.reduce(coll, init, fn elem, acc -> body end)`.
  - All LHS are distinct bare variables.
  - Every lambda is single-clause `fn elem, acc -> body end` with
    **bare-variable** element and accumulator patterns (destructured
    patterns are left for a human).
  - All `coll` ASTs are structurally identical.

  ## Maximal runs, greedily extended

  Statements are walked left-to-right. A run starts at the first
  classifiable reduce and is extended one statement at a time as long as
  the next statement is a reduce over the same collection that does
  **not** read any LHS already bound earlier in the run (see data-flow
  dependency below). A run of length ≥ 2 (whose every result is live) is
  fused into one tuple pass; the walk then resumes past the run. A run of
  length 1 fuses nothing and the walk advances by one.

  Emitting one patch per run keeps the patched source ranges disjoint —
  overlapping ranges corrupt `patch_string`.

  ## Why these statements must be adjacent

  Adjacency guarantees nothing rebinds the source collection between two
  reduces. A `xs = ...` (or any statement) in between ends the run: the
  reduces might be reading different bindings of `xs`, and proving
  otherwise is out of scope. Safety over reach.

  ## Preconditions / SKIP list

  - ⚠ The source must be a **materialised, pure collection** — `pure?/1`
    rejects `Stream.*`, `File.stream!/1`, bang calls, and any lazy or
    side-effecting enumerable. A lazy source yields/side-effects per
    traversal, so N× → 1× changes observable behaviour. SKIP.
  - Every reducer body must be **pure** (`pure?/1`). Shared side effects
    would interleave differently after fusion. SKIP otherwise.
  - **Data-flow dependency** — a later reduce in the run may not read any
    LHS bound by an earlier reduce in the same run, in its collection,
    its init, or its body. After fusion none of those bindings exist
    until the single pass completes, so reading one early would be a
    forward reference. Such a reduce ends the run rather than joining it.
  - **Every result must live** after the run (each LHS is read by a later
    statement in the block). A run of length 1, or one where a member's
    result is dead, fuses nothing. SKIP.
  - No body may **shadow** (rebind) any lambda parameter name — that
    would make the bare-variable rename unsafe. SKIP.

  ## Idempotence

  After fusion there is a single `Enum.reduce/3` whose accumulator is a
  tuple, bound to a `{a, b, ...}` pattern. There is no longer a run of
  reduces over the same collection, so a second pass finds no match.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description,
    do: "Fuse a run of Enum.reduce/3 over the same collection into one n-tuple pass"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    N `Enum.reduce/3` calls over the same list walk it N times for N
    independent accumulations the reader has to mentally group. Folding
    them into one pass with an n-tuple accumulator states the relationship
    directly — these values are derived together, in one traversal — and
    collapses N passes on the hot path to one.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 150
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  @impl Number42.Refactors.Refactor
  def patches(ast, _source, _opts), do: build_patches(ast)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&block_patches/1)

  defp block_patches({:__block__, _, stmts}) when is_list(stmts),
    do: maximal_runs(stmts, 0, [])

  defp block_patches(_), do: []

  # Walk statements left-to-right. At each position grow the longest run
  # of mutually-fusable reduces starting there; if it has ≥ 2 members
  # (and all their results live) emit one patch and skip past the whole
  # run. Skipping the whole run keeps the emitted patch ranges disjoint —
  # overlapping ranges would corrupt `patch_string`.
  defp maximal_runs(stmts, index, acc) do
    case run_at(stmts, index) do
      [_, _ | _] = run ->
        case run_patch(run, stmts, index) do
          {:ok, patch} -> maximal_runs(stmts, index + length(run), [patch | acc])
          :skip -> maximal_runs(stmts, index + 1, acc)
        end

      _ ->
        if index < length(stmts),
          do: maximal_runs(stmts, index + 1, acc),
          else: Enum.reverse(acc)
    end
  end

  # The maximal run of fusable reduces beginning at `index`, as a list of
  # `{stmt, classified}` tuples. Classify the statement there, then extend
  # while the next statement is a reduce over the same collection that
  # doesn't read any earlier member's result. Empty when `index` isn't a
  # reduce.
  defp run_at(stmts, index) do
    case Enum.at(stmts, index) |> classify_stmt() do
      nil -> []
      head -> extend_run(stmts, index, [head])
    end
  end

  defp extend_run(stmts, index, run) do
    case Enum.at(stmts, index + length(run)) |> classify_stmt() do
      nil ->
        run

      candidate ->
        if joins_run?(candidate, run),
          do: extend_run(stmts, index, run ++ [candidate]),
          else: run
    end
  end

  defp classify_stmt(nil), do: nil

  defp classify_stmt(stmt) do
    case classify(stmt) do
      {:ok, member} -> {stmt, member}
      :skip -> nil
    end
  end

  # `candidate` joins the run iff it reduces the same collection as the
  # run's head AND reads no name bound by a member already in the run.
  defp joins_run?({_stmt, candidate}, [{_, head} | _] = run) do
    members = Enum.map(run, fn {_, m} -> m end)

    same_collection?(candidate.coll, head.coll) and
      not depends_on_earlier?(candidate, members)
  end

  defp run_patch(run, stmts, index) do
    members = Enum.map(run, fn {_, m} -> m end)

    if fusable_run?(members, stmts, index) do
      {first_stmt, _} = hd(run)
      {last_stmt, _} = List.last(run)

      range = %{
        start: Sourceror.get_range(first_stmt).start,
        end: Sourceror.get_range(last_stmt).end
      }

      {:ok, Patch.new(range, render(members), false)}
    else
      :skip
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

  # A run (already known to share a collection and be free of cross-member
  # data-flow dependencies) is fusable when every member's collection and
  # body are pure, no body shadows its own lambda params, all LHS names are
  # distinct, and every result is read downstream.
  defp fusable_run?(members, stmts, index) do
    distinct_names?(members) and
      Enum.all?(members, &pure?(&1.coll)) and
      Enum.all?(members, &pure?(&1.body)) and
      not Enum.any?(members, &shadows_param?/1) and
      all_results_live?(members, stmts, index)
  end

  defp distinct_names?(members) do
    names = Enum.map(members, & &1.name)
    length(Enum.uniq(names)) == length(names)
  end

  defp same_collection?(coll_a, coll_b), do: strip_meta(coll_a) == strip_meta(coll_b)

  defp shadows_param?(%{elem: elem, acc: acc, body: body}) do
    bound = bound_in(body)
    MapSet.member?(bound, elem) or MapSet.member?(bound, acc)
  end

  # Whether `candidate` reads any LHS name bound by an earlier `member` —
  # in its collection, init, or body. After fusion those bindings don't
  # exist until the single pass returns, so such a read would be a forward
  # reference and the candidate must not join the run.
  defp depends_on_earlier?(candidate, members) do
    earlier = members |> Enum.map(& &1.name) |> MapSet.new()

    reads =
      [candidate.coll, candidate.init, candidate.body]
      |> Enum.reduce(MapSet.new(), &MapSet.union(used_var_names(&1), &2))

    not MapSet.disjoint?(reads, earlier)
  end

  defp all_results_live?(members, stmts, index) do
    after_index = index + length(members) - 1
    Enum.all?(members, &read_after?(&1.name, stmts, after_index))
  end

  defp render(members) do
    elem = fresh(:elem, members)
    accs = Enum.map(1..length(members), &fresh(:"acc#{&1}", members))

    bodies =
      members
      |> Enum.zip(accs)
      |> Enum.map(fn {m, acc} -> rename(m.body, %{m.elem => elem, m.acc => acc}) end)

    [first | _] = members
    coll = Sourceror.to_string(first.coll)
    init = "{#{Enum.map_join(members, ", ", &Sourceror.to_string(&1.init))}}"
    acc_pattern = "{#{Enum.join(accs, ", ")}}"
    body_tuple = "{#{Enum.map_join(bodies, ", ", &Sourceror.to_string/1)}}"
    lhs_pattern = "{#{Enum.map_join(members, ", ", & &1.name)}}"

    lambda = "fn #{elem}, #{acc_pattern} -> #{body_tuple} end"

    "#{lhs_pattern} = Enum.reduce(#{coll}, #{init}, #{lambda})"
  end

  # A fresh name = the preferred base, suffixed with an integer until it
  # collides with nothing referenced in any reducer's body, init, or
  # collection. Guarantees the tuple-accumulator rename cannot capture.
  defp fresh(base, members) do
    taken = members |> Enum.flat_map(&member_names/1) |> MapSet.new()
    pick(base, taken, nil)
  end

  defp member_names(%{coll: coll, init: init, body: body, elem: elem, acc: acc}) do
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
