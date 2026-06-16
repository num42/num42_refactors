defmodule Number42.Refactors.CommunityDetection do
  @moduledoc """
  Greedy modularity-maximising community detection over a weighted,
  undirected graph. Used by `SplitLowCohesionModule` to find call-graph
  communities inside a single module.

  ## Why modularity and not connected components

  Connected components is too blunt for a god module: one shared helper
  called from every island fuses the whole graph into a single
  component, so the seams vanish. Modularity instead measures whether a
  partition has *more* intra-community edges than you'd expect from a
  random graph with the same degree sequence. A single bridge edge
  between two otherwise-dense clusters contributes almost nothing to
  modularity, so the clusters stay apart — exactly the seam we want.

  ## Algorithm (Clauset-Newman-Moore greedy agglomeration)

  Standard greedy modularity maximisation:

    1. Start with every node in its own community.
    2. Repeatedly merge the *pair of communities* whose merge yields the
       largest positive modularity gain `ΔQ`.
    3. Stop when no merge would increase modularity (every candidate
       `ΔQ <= 0`).

  The returned partition is the one with maximal modularity reachable by
  greedy agglomeration. `modularity/2` scores any partition so callers
  can apply a quality threshold and *decline* on a tangled blob (low
  modularity = no real community structure).

  Modularity is defined as

      Q = (1 / 2m) * Σ_ij [ A_ij − k_i k_j / 2m ] δ(c_i, c_j)

  with `A` the weighted adjacency matrix, `k_i` the weighted degree of
  node `i`, `m` the total edge weight, and `δ` the same-community
  indicator. The implementation works on community-level aggregates
  (`e_c` = intra-community weight fraction, `a_c` = total incident
  weight fraction) so a merge gain is the closed form
  `ΔQ = 2 (e_uv − a_u a_v)`.

  ## Graph shape

  `edges` is a map `%{{u, v} => weight}` where `{u, v}` is an unordered
  pair (the helper normalises orientation) and `weight > 0`. Nodes that
  appear in no edge must be supplied via `nodes` so they survive as
  singleton communities. Self-loops are ignored.
  """

  @typedoc "An opaque node identifier — for the refactor, a `{name, arity}`."
  @type node_id :: term()

  @typedoc "Unordered weighted edges keyed by a `{u, v}` pair."
  @type edges :: %{{node_id(), node_id()} => number()}

  @typedoc "A partition: list of communities, each a set of node ids."
  @type partition :: [MapSet.t(node_id())]

  @doc """
  Partition `nodes` into communities by greedy modularity maximisation
  over the weighted undirected `edges`.

  Returns a list of communities (each a `MapSet` of node ids). Every
  node in `nodes` appears in exactly one community; isolated nodes come
  back as singletons. The partition is deterministic — ties in the
  merge gain break on a stable sort of the community key.
  """
  @spec detect([node_id()], edges()) :: partition()
  def detect(nodes, edges) do
    adjacency = build_adjacency(nodes, edges)
    total = total_weight(edges)

    case total do
      +0.0 -> Enum.map(nodes, &MapSet.new([&1]))
      _ -> greedy_merge(nodes, adjacency, total)
    end
  end

  @doc """
  Modularity `Q` of `partition` over the weighted undirected `edges`.

  Ranges in `(-0.5, 1)`. Values at or below ~`0.3` indicate no
  meaningful community structure (a tangled blob); callers should
  decline to split such a graph. Returns `0.0` for an empty graph.
  """
  @spec modularity(partition(), edges()) :: float()
  def modularity(partition, edges) do
    total = total_weight(edges)
    modularity_for_total(partition, edges, total)
  end

  @doc """
  Fraction of total edge weight that crosses community boundaries under
  `partition`. `0.0` means a perfect cut (no edge spans two
  communities); `1.0` means every edge crosses. Returns `0.0` for an
  empty graph.

  This is the direct "how weak are the cross-links" signal — distinct
  from modularity, which also rewards intra-density. A split is only
  trustworthy when this ratio is low.
  """
  @spec cut_ratio(partition(), edges()) :: float()
  def cut_ratio(partition, edges) do
    total = total_weight(edges)
    cut_ratio_for_total(partition, edges, total)
  end

  # ── Greedy agglomeration ─────────────────────────────────────────
  #
  # Clauset-Newman-Moore on community-level aggregates, so a merge never
  # re-scans node membership:
  #
  #   * `members`  — `%{cid => MapSet(node)}`, the live communities
  #   * `a`        — `%{cid => incident weight}` of each community
  #   * `between`  — `%{cid => %{neighbour_cid => cross weight}}`, the
  #     weight on edges between two distinct communities (symmetric)
  #
  # `cid`s are the node-keyed singleton ids at the start; a merge keeps
  # the smaller id and folds the larger into it, so ids stay stable for
  # the deterministic tie-break (`{gain, -i, -j}` on the original
  # node-derived ids). Each merge touches only the union of the two
  # communities' neighbours — O(degree), not O(N).

  defp greedy_merge(nodes, adjacency, total) do
    members = Map.new(nodes, &{&1, MapSet.new([&1])})
    a = Map.new(nodes, &{&1, node_incident(&1, adjacency)})
    between = initial_between(nodes, adjacency)

    {final_members, _a, _between} = merge_loop(members, a, between, total)
    Map.values(final_members)
  end

  defp merge_loop(members, a, between, total) do
    case best_merge(between, a, total) do
      :none ->
        {members, a, between}

      {i, j} ->
        {members, a, between} = apply_merge(members, a, between, i, j)
        merge_loop(members, a, between, total)
    end
  end

  # The best (highest positive ΔQ) pair of community ids to merge, or
  # `:none` when no merge improves modularity. Only adjacent community
  # pairs can have positive ΔQ, and `between` holds exactly those, so we
  # scan its entries directly. ΔQ comes straight from the aggregates:
  #   ΔQ = 2 * (e_uv/total − a_u a_v / (2·total)²)
  # The `e_uv > 0` invariant of `between` lets us pre-divide once.
  defp best_merge(between, a, total) do
    two_total = 2 * total

    best =
      Enum.reduce(between, :none, fn {i, neighbours}, outer ->
        Enum.reduce(neighbours, outer, fn {j, e_uv}, acc ->
          if i < j do
            a_u = Map.fetch!(a, i) / two_total
            a_v = Map.fetch!(a, j) / two_total
            gain = 2 * (e_uv / total - a_u * a_v)
            better?(acc, {gain, i, j})
          else
            acc
          end
        end)
      end)

    case best do
      {gain, i, j} when gain > 0.0 -> {i, j}
      _ -> :none
    end
  end

  # Keep the candidate with the larger gain. On a gain tie the pair with
  # the lexicographically smaller `{i, j}` wins — a total, input-order-
  # independent order over the node-id pairs (ids being `{name, arity}`),
  # so the partition is deterministic regardless of how `between` happens
  # to enumerate.
  defp better?(:none, candidate), do: candidate

  defp better?({g0, i0, j0} = current, {g1, i1, j1} = candidate) do
    cond do
      g1 > g0 -> candidate
      g1 < g0 -> current
      {i1, j1} < {i0, j0} -> candidate
      true -> current
    end
  end

  # Merge community `j` into `i` (i kept). Updates incident weights, the
  # member sets, and rewrites every neighbour's `between` entry to point
  # at `i`, folding any edge they had to both `i` and `j`.
  defp apply_merge(members, a, between, i, j) do
    members =
      members
      |> Map.update!(i, &MapSet.union(&1, Map.fetch!(members, j)))
      |> Map.delete(j)

    a = a |> Map.update!(i, &(&1 + Map.fetch!(a, j))) |> Map.delete(j)

    between = rewire_between(between, i, j)
    {members, a, between}
  end

  # Fold j's cross-edges into i's, drop j everywhere, and remove the
  # now-internal i↔j edge. `between` stays symmetric throughout.
  defp rewire_between(between, i, j) do
    i_neighbours = Map.get(between, i, %{})
    j_neighbours = Map.get(between, j, %{})

    # New i row: union of i's and j's external neighbours, summed,
    # excluding i and j themselves (the i↔j edge becomes internal).
    merged_row =
      j_neighbours
      |> Map.drop([i, j])
      |> Enum.reduce(Map.drop(i_neighbours, [i, j]), fn {k, w}, acc ->
        Map.update(acc, k, w, &(&1 + w))
      end)

    # Point every external neighbour `k` back at `i`: add its weight to k,
    # remove its old j entry, and (for k that touched both) sum them.
    neighbours = merged_row |> Map.keys()

    between
    |> Map.put(i, merged_row)
    |> Map.delete(j)
    |> redirect_neighbours(neighbours, i, j, merged_row)
  end

  defp redirect_neighbours(between, neighbours, i, j, merged_row) do
    Enum.reduce(neighbours, between, fn k, acc ->
      Map.update(acc, k, %{i => Map.fetch!(merged_row, k)}, fn row ->
        row |> Map.delete(j) |> Map.put(i, Map.fetch!(merged_row, k))
      end)
    end)
  end

  # ── Aggregate construction ───────────────────────────────────────

  # Weight incident to a single node (its singleton community's `a`).
  defp node_incident(node, adjacency) do
    adjacency |> Map.get(node, %{}) |> Map.values() |> Enum.sum()
  end

  # `%{cid => %{neighbour_cid => weight}}` for the singleton partition:
  # this is just the adjacency, since every node is its own community.
  defp initial_between(nodes, adjacency) do
    Map.new(nodes, fn node -> {node, Map.get(adjacency, node, %{})} end)
  end

  # ── Adjacency / totals ───────────────────────────────────────────

  # Symmetric adjacency `%{node => %{neighbour => weight}}`. Self-loops
  # are dropped — they don't affect community membership.
  defp build_adjacency(nodes, edges) do
    base = Map.new(nodes, &{&1, %{}})

    Enum.reduce(edges, base, fn {{u, v}, w}, acc ->
      if u == v or w <= 0 do
        acc
      else
        acc
        |> ensure_node(u)
        |> ensure_node(v)
        |> put_edge(u, v, w)
        |> put_edge(v, u, w)
      end
    end)
  end

  defp ensure_node(adjacency, node), do: Map.put_new(adjacency, node, %{})

  defp put_edge(adjacency, from, to, w) do
    Map.update!(adjacency, from, fn neighbours -> Map.update(neighbours, to, w, &(&1 + w)) end)
  end

  defp total_weight(edges) do
    edges
    |> Enum.reject(fn {{u, v}, w} -> u == v or w <= 0 end)
    |> Enum.reduce(0.0, fn {_pair, w}, acc -> acc + w end)
  end

  defp modularity_for_total(_partition, _edges, +0.0), do: 0.0

  # Q = Σ_c [ L_c/m − (D_c/2m)² ], with `m` the total edge weight, `L_c`
  # the weight of edges fully inside community c, and `D_c` the degree
  # sum of c's nodes. Trivial all-in-one partition → Q = m/m − 1 = 0;
  # the more intra-density beyond chance, the closer to 1.
  defp modularity_for_total(partition, edges, total) do
    membership = membership_index(partition)
    degrees = node_degrees(edges)
    live_edges = Enum.reject(edges, fn {{u, v}, w} -> u == v or w <= 0 end)

    intra_by_community = intra_weight_by_community(live_edges, membership)

    partition
    |> Enum.with_index()
    |> Enum.reduce(0.0, fn {community, idx}, acc ->
      l_c = Map.get(intra_by_community, idx, 0.0)
      d_c = community |> Enum.reduce(0.0, &(&2 + Map.get(degrees, &1, 0)))
      acc + l_c / total - :math.pow(d_c / (2 * total), 2)
    end)
  end

  # `%{community_index => intra-community edge weight}`.
  defp intra_weight_by_community(live_edges, membership) do
    Enum.reduce(live_edges, %{}, fn {{u, v}, w}, acc ->
      cu = Map.get(membership, u)

      if cu != nil and cu == Map.get(membership, v),
        do: Map.update(acc, cu, w, &(&1 + w)),
        else: acc
    end)
  end

  defp node_degrees(edges) do
    edges
    |> Enum.reject(fn {{u, v}, w} -> u == v or w <= 0 end)
    |> Enum.reduce(%{}, fn {{u, v}, w}, acc ->
      acc |> Map.update(u, w, &(&1 + w)) |> Map.update(v, w, &(&1 + w))
    end)
  end

  defp membership_index(partition) do
    partition
    |> Enum.with_index()
    |> Enum.flat_map(fn {community, idx} -> Enum.map(community, &{&1, idx}) end)
    |> Map.new()
  end

  defp cut_ratio_for_total(_partition, _edges, +0.0), do: 0.0

  defp cut_ratio_for_total(partition, edges, total) do
    membership = membership_index(partition)

    crossing =
      edges
      |> Enum.reject(fn {{u, v}, w} -> u == v or w <= 0 end)
      |> Enum.reduce(0.0, fn {{u, v}, w}, acc ->
        if Map.get(membership, u) == Map.get(membership, v), do: acc, else: acc + w
      end)

    crossing / total
  end
end
