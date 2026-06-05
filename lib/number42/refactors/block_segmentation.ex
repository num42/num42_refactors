defmodule Number42.Refactors.BlockSegmentation do
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
  - `group_phases/2` — a contiguous partition of the segments into
    phases whose inter-phase data-flow is narrow (few carriers crossing
    each boundary), honouring `min_statements_per_phase` / `min_phases`.

  All reads/writes are syntactic over-approximations inherited from
  `AstHelpers.used_var_names/1` and `bound_in/1` — a zero-arg local call
  `foo()` parses identically to a variable reference, so it shows up in
  `reads`. Callers that need to drop those filter against a known scope
  (function params + prior writes), exactly as `free_vars/2` does.
  """

  alias Number42.Refactors.AstHelpers

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
      reads = MapSet.difference(AstHelpers.used_var_names(ast), writes)
      %{ast: ast, index: index, reads: reads, writes: writes}
    end)
  end

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
  Partition `segments` into a list of contiguous phases, cutting at the
  data-flow boundaries with the fewest crossing carriers.

  Options:

  - `:min_statements_per_phase` (default `2`) — no phase shorter than this.
  - `:min_phases` (default `2`) — return a single phase if the block
    can't be split into at least this many phases under the floor.
  - `:max_carriers` (default `3`) — a cut is only eligible if at most
    this many carriers cross it (a tuple transition wider than this is a
    semantic smell, not a clean phase boundary).
  """
  @spec group_phases([segment()], keyword()) :: [[segment()]]
  def group_phases(segments, opts \\ []) when is_list(segments) do
    min_per = Keyword.get(opts, :min_statements_per_phase, 2)
    min_phases = Keyword.get(opts, :min_phases, 2)
    max_carriers = Keyword.get(opts, :max_carriers, 3)

    cuts = eligible_cuts(segments, min_per, max_carriers)

    case best_cuts(cuts, length(segments), min_per, min_phases) do
      [] -> [segments]
      chosen -> split_at(segments, chosen)
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

  # Cut positions `k` (split before segment k) that leave both sides at
  # least `min_per` long and cross at most `max_carriers` carriers,
  # ranked by crossing count then position for determinism.
  defp eligible_cuts(segments, min_per, max_carriers) do
    n = length(segments)

    min_per..(n - min_per)//1
    |> Enum.filter(fn k -> k >= min_per and n - k >= min_per end)
    |> Enum.map(fn k -> {k, MapSet.size(live_out(segments, k))} end)
    |> Enum.filter(fn {_k, crossing} -> crossing <= max_carriers end)
    |> Enum.sort_by(fn {k, crossing} -> {crossing, k} end)
  end

  # Greedily take the narrowest eligible cut; if a single cut yields the
  # required number of phases, that's enough for v1. Wider partitioning
  # is a later concern — one clean split already shrinks the host.
  defp best_cuts([], _n, _min_per, _min_phases), do: []

  defp best_cuts(cuts, _n, _min_per, min_phases) do
    cuts
    |> Enum.map(fn {k, _crossing} -> k end)
    |> Enum.take(max(min_phases - 1, 1))
    |> Enum.sort()
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
