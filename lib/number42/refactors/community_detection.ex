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
      _ -> greedy_merge(initial_communities(nodes), adjacency, total)
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

  defp initial_communities(nodes), do: Enum.map(nodes, &MapSet.new([&1]))

  defp greedy_merge(communities, adjacency, total) do
    case best_merge(communities, adjacency, total) do
      :none -> communities
      {i, j} -> communities |> merge_at(i, j) |> greedy_merge(adjacency, total)
    end
  end

  # The best (highest positive ΔQ) pair of community indices to merge,
  # or `:none` when no merge improves modularity. Only adjacent
  # community pairs (those with at least one connecting edge) can have
  # positive ΔQ, so we restrict candidates to them.
  defp best_merge(communities, adjacency, total) do
    indexed = Enum.with_index(communities)

    indexed
    |> candidate_pairs(adjacency)
    |> Enum.map(fn {i, j} ->
      {merge_gain(Enum.at(communities, i), Enum.at(communities, j), adjacency, total), i, j}
    end)
    |> best_positive_gain()
  end

  defp candidate_pairs(indexed_communities, adjacency) do
    for {ci, i} <- indexed_communities,
        {cj, j} <- indexed_communities,
        i < j,
        connected?(ci, cj, adjacency),
        do: {i, j}
  end

  defp connected?(ci, cj, adjacency) do
    Enum.any?(ci, fn u ->
      neighbours = Map.get(adjacency, u, %{})
      Enum.any?(cj, &Map.has_key?(neighbours, &1))
    end)
  end

  defp best_positive_gain([]), do: :none

  defp best_positive_gain(gains) do
    {gain, i, j} = Enum.max_by(gains, fn {g, i, j} -> {g, -i, -j} end)
    if gain > 0.0, do: {i, j}, else: :none
  end

  # ΔQ for merging communities `u` and `v`:
  #   ΔQ = 2 * (e_uv − a_u * a_v)
  # where e_uv is the fraction of total weight on edges *between* u and
  # v, and a_x is the fraction of total weight incident to community x.
  defp merge_gain(u, v, adjacency, total) do
    e_uv = between_weight(u, v, adjacency) / total
    a_u = incident_weight(u, adjacency) / (2 * total)
    a_v = incident_weight(v, adjacency) / (2 * total)
    2 * (e_uv - a_u * a_v)
  end

  defp merge_at(communities, i, j) do
    {ci, cj} = {Enum.at(communities, i), Enum.at(communities, j)}
    merged = MapSet.union(ci, cj)

    communities
    |> Enum.with_index()
    |> Enum.reject(fn {_c, idx} -> idx in [i, j] end)
    |> Enum.map(fn {c, _idx} -> c end)
    |> List.insert_at(0, merged)
  end

  # ── Weight aggregates ────────────────────────────────────────────

  # Sum of edge weights with exactly one endpoint in `u` and the other
  # in `v` (the cut weight between the two communities).
  defp between_weight(u, v, adjacency) do
    Enum.reduce(u, 0.0, fn node, acc ->
      neighbours = Map.get(adjacency, node, %{})
      acc + Enum.reduce(v, 0.0, fn other, inner -> inner + Map.get(neighbours, other, 0) end)
    end)
  end

  # Total weight incident to community `c` (each intra-community edge
  # counted twice, matching the degree-sum convention `a_c`).
  defp incident_weight(c, adjacency) do
    Enum.reduce(c, 0.0, fn node, acc ->
      acc + (adjacency |> Map.get(node, %{}) |> Map.values() |> Enum.sum())
    end)
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
