defmodule Number42.Refactors.Analysis.BlockSegmentation do
  @moduledoc """
  Per-statement data-flow analysis over a function body, shared by the
  structural-generation refactors (#58).

  A *segment* is one top-level statement of a block paired with the
  variable names it **reads** (referenced free) and **writes** (bound on
  its LHS). From that, two derived views:

  - `carriers/1` — names written by one statement and read by a *later*
    one; the values that must flow between phases if the block is split.
  - `live_out/2` — the carriers crossing a specific cut, i.e. the tuple
    a phase-helper would have to return.
  - `group_phases/2` — a contiguous, *maximally fine* partition of the
    segments into phases whose inter-phase data-flow is narrow (few
    carriers crossing each boundary), honouring `min_statements_per_phase`
    / `min_phases`. Cutting at every eligible boundary in one shot keeps
    callers single-pass idempotent: no phase is left large enough to be
    re-split on a later pass.

  All reads/writes are syntactic over-approximations inherited from
  `AstHelpers.used_var_names/1` and `bound_in/1` — a zero-arg local call
  `foo()` parses identically to a variable reference, so it shows up in
  `reads`. Callers that need to drop those filter against a known scope
  (function params + prior writes), exactly as `free_vars/2` does.
  """

  alias Number42.Refactors.Analysis.AstHelpers

  @type segment :: %{
          ast: Macro.t(),
          index: non_neg_integer(),
          reads: MapSet.t(),
          writes: MapSet.t()
        }

  @doc """
  Turn a list of statement ASTs into segments with per-statement
  `reads` / `writes`. The `reads` of a statement exclude the names it
  binds itself — `subtotal = sum_lines(order)` reads `order` (and the
  call name `sum_lines`), writes `subtotal`, and does *not* read
  `subtotal`.
  """
  @spec segment([Macro.t()]) :: [segment()]
  def segment(exprs) when is_list(exprs) do
    exprs
    |> Enum.with_index()
    |> Enum.map(fn {ast, index} ->
      writes = AstHelpers.bound_in(ast)
      used = AstHelpers.used_var_names(ast)
      reads = used |> MapSet.difference(writes) |> MapSet.union(rhs_reads(ast))

      %{ast: ast, index: index, reads: reads, writes: writes}
    end)
  end

  # A self-rebind (`x = f(x)`, `x = x |> g()`) reads `x` on the RHS before
  # binding it — but `bound_in` reports `x` as written, so `used - writes`
  # drops that genuine read. Add the RHS free vars of a top-level
  # assignment back so the carrier survives into the phase that needs it.
  defp rhs_reads({op, _, [_lhs, rhs]}) when op in [:=, :<-], do: AstHelpers.used_var_names(rhs)
  defp rhs_reads(_), do: MapSet.new()

  @doc """
  The names written by some segment and read by a strictly later one —
  the values that flow across statement boundaries within the block.
  """
  @spec carriers([segment()]) :: MapSet.t()
  def carriers(segments) when is_list(segments) do
    segments
    |> Enum.flat_map(fn %{index: i, writes: writes} ->
      read_after = reads_after(segments, i)
      writes |> MapSet.intersection(read_after) |> MapSet.to_list()
    end)
    |> MapSet.new()
  end

  @doc """
  The carriers crossing a cut placed *after* segment `k - 1` (i.e. the
  block is split into segments `0..k-1` | `k..`). A name is live-out at
  the cut if it is written at or before the cut and read after it — the
  set a phase-helper covering the first part would have to return.
  """
  @spec live_out([segment()], non_neg_integer()) :: MapSet.t()
  def live_out(segments, k) when is_list(segments) and is_integer(k) do
    {before, rest} = Enum.split(segments, k)

    written_before = union_of(before, & &1.writes)
    read_after = union_of(rest, & &1.reads)

    MapSet.intersection(written_before, read_after)
  end

  @doc """
  Partition `segments` into a list of contiguous phases, cutting at every
  eligible data-flow boundary so the partition is *maximally fine*.

  Options:

  - `:min_statements_per_phase` (default `2`) — no phase shorter than this.
  - `:min_phases` (default `3`) — return a single phase if the block
    can't be split into at least this many phases under the floor.
  - `:max_carriers` (default `3`) — a cut is only eligible if at most
    this many carriers cross it (a tuple transition wider than this is a
    semantic smell, not a clean phase boundary).

  Cutting at every eligible boundary (rather than just the narrowest one)
  in a single call is what keeps the caller single-pass idempotent: a
  re-run over the already-partitioned output finds no phase long enough to
  cut again.
  """
  @spec group_phases([segment()], keyword()) :: [[segment()]]
  def group_phases(segments, opts \\ []) when is_list(segments) do
    min_per = Keyword.get(opts, :min_statements_per_phase, 2)
    min_phases = Keyword.get(opts, :min_phases, 3)
    max_carriers = Keyword.get(opts, :max_carriers, 3)

    case maximal_cuts(segments, min_per, max_carriers) do
      cuts when length(cuts) >= min_phases - 1 and cuts != [] -> split_at(segments, cuts)
      _ -> [segments]
    end
  end

  # --- internals ---

  defp reads_after(segments, i) do
    segments
    |> Enum.drop(i + 1)
    |> union_of(& &1.reads)
  end

  defp union_of(segments, project) do
    Enum.reduce(segments, MapSet.new(), fn seg, acc ->
      MapSet.union(acc, project.(seg))
    end)
  end

  # Take as many cuts as the `min_per` floor allows, preferring the
  # narrowest boundaries: rank every eligible cut by crossing count then
  # position, then greedily accept each one whose distance to every
  # already-accepted cut is at least `min_per`. Maximally fine, so a
  # re-run finds no phase long enough to re-split — yet a wide boundary
  # never displaces a narrow one it sits within `min_per` of.
  defp maximal_cuts(segments, min_per, max_carriers) do
    segments
    |> eligible_cuts(min_per, max_carriers)
    |> Enum.reduce([], fn k, chosen ->
      if Enum.all?(chosen, fn c -> abs(c - k) >= min_per end),
        do: [k | chosen],
        else: chosen
    end)
    |> Enum.sort()
  end

  # Cut positions `k` (split before segment k) that leave both sides at
  # least `min_per` long and cross at most `max_carriers` carriers,
  # ranked by crossing count then position for determinism.
  defp eligible_cuts(segments, min_per, max_carriers) do
    n = length(segments)

    min_per..(n - min_per)//1
    |> Enum.map(fn k -> {k, MapSet.size(live_out(segments, k))} end)
    |> Enum.filter(fn {_k, crossing} -> crossing <= max_carriers end)
    |> Enum.sort_by(fn {k, crossing} -> {crossing, k} end)
    |> Enum.map(fn {k, _crossing} -> k end)
  end

  defp split_at(segments, cuts) do
    {phases, last} =
      Enum.reduce(cuts, {[], segments}, fn k, {acc, remaining} ->
        taken = length(segments) - length(remaining)
        {phase, rest} = Enum.split(remaining, k - taken)
        {[phase | acc], rest}
      end)

    Enum.reverse([last | phases])
  end
end
