defmodule Number42.Refactors.Analysis.CommunityDetectionTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Analysis.CommunityDetection, as: CD

  # Communities come back as a list of MapSets in an order that is an
  # implementation detail; compare them as a set of sets so the assertions
  # pin the partition, not the ordering.
  defp as_set_of_sets(partition), do: MapSet.new(partition)

  describe "detect/2" do
    test "isolated nodes come back as singletons" do
      assert as_set_of_sets(CD.detect([:a, :b, :c], %{})) ==
               as_set_of_sets([MapSet.new([:a]), MapSet.new([:b]), MapSet.new([:c])])
    end

    test "an empty graph yields no communities" do
      assert CD.detect([], %{}) == []
    end

    test "two dense cliques joined by one weak bridge stay apart" do
      edges = %{
        {:a1, :a2} => 5.0,
        {:a2, :a3} => 5.0,
        {:a1, :a3} => 5.0,
        {:b1, :b2} => 5.0,
        {:b2, :b3} => 5.0,
        {:b1, :b3} => 5.0,
        {:a1, :b1} => 1.0
      }

      partition = CD.detect([:a1, :a2, :a3, :b1, :b2, :b3], edges)

      assert as_set_of_sets(partition) ==
               as_set_of_sets([MapSet.new([:a1, :a2, :a3]), MapSet.new([:b1, :b2, :b3])])
    end

    test "a single dense clique stays one community" do
      edges = %{
        {:a, :b} => 1.0,
        {:b, :c} => 1.0,
        {:a, :c} => 1.0
      }

      assert as_set_of_sets(CD.detect([:a, :b, :c], edges)) ==
               as_set_of_sets([MapSet.new([:a, :b, :c])])
    end

    test "is deterministic across repeated runs" do
      edges = %{
        {:a1, :a2} => 4.0,
        {:a2, :a3} => 4.0,
        {:b1, :b2} => 4.0,
        {:b2, :b3} => 4.0,
        {:a1, :b1} => 1.0,
        {:c, :a1} => 2.0,
        {:c, :b1} => 2.0
      }

      nodes = [:a1, :a2, :a3, :b1, :b2, :b3, :c]
      first = CD.detect(nodes, edges)
      assert Enum.all?(1..20, fn _ -> CD.detect(nodes, edges) == first end)
    end

    test "self-loops are ignored" do
      edges = %{{:a, :a} => 99.0, {:a, :b} => 1.0, {:b, :b} => 99.0}

      assert as_set_of_sets(CD.detect([:a, :b], edges)) ==
               as_set_of_sets([MapSet.new([:a, :b])])
    end
  end

  describe "modularity/2" do
    test "is 0.0 for an empty graph" do
      assert CD.modularity([], %{}) == 0.0
    end

    test "the all-in-one partition has modularity 0.0" do
      edges = %{{:a, :b} => 1.0, {:b, :c} => 1.0}
      assert_in_delta CD.modularity([MapSet.new([:a, :b, :c])], edges), 0.0, 1.0e-9
    end

    test "a good split scores higher than the tangled all-in-one" do
      edges = %{
        {:a1, :a2} => 5.0,
        {:a2, :a3} => 5.0,
        {:a1, :a3} => 5.0,
        {:b1, :b2} => 5.0,
        {:b2, :b3} => 5.0,
        {:b1, :b3} => 5.0,
        {:a1, :b1} => 1.0
      }

      split = [MapSet.new([:a1, :a2, :a3]), MapSet.new([:b1, :b2, :b3])]
      blob = [MapSet.new([:a1, :a2, :a3, :b1, :b2, :b3])]

      assert CD.modularity(split, edges) > CD.modularity(blob, edges)
    end
  end

  describe "cut_ratio/2" do
    test "is 0.0 for an empty graph" do
      assert CD.cut_ratio([], %{}) == 0.0
    end

    test "is 0.0 for a perfect cut and positive when an edge crosses" do
      edges = %{{:a, :b} => 2.0, {:c, :d} => 2.0, {:b, :c} => 1.0}

      perfect = [MapSet.new([:a, :b]), MapSet.new([:c, :d])]
      assert CD.cut_ratio(perfect, edges) == 1.0 / 5.0

      assert CD.cut_ratio([MapSet.new([:a, :b, :c, :d])], edges) == 0.0
    end
  end

  # A randomised differential check: the optimised detect/2 must agree with a
  # straightforward reference implementation of the same greedy CNM step on
  # many random graphs. Deterministic seed so the test never flakes.
  describe "differential vs reference greedy CNM" do
    test "agrees with a naive reference on random graphs" do
      seeds = 1..60

      for seed <- seeds do
        {nodes, edges} = random_graph(seed)
        actual = CD.detect(nodes, edges) |> MapSet.new()
        expected = reference_detect(nodes, edges) |> MapSet.new()

        assert actual == expected,
               "partition mismatch on seed #{seed}\nnodes=#{inspect(nodes)}\nedges=#{inspect(edges)}\n" <>
                 "actual=#{inspect(actual)}\nexpected=#{inspect(expected)}"
      end
    end
  end

  # ── deterministic random graph generator (no :rand, pure LCG) ───────

  defp random_graph(seed) do
    n = 4 + rem(seed, 6)
    nodes = Enum.map(1..n, &:"n#{&1}")

    {edges, _state} =
      for u <- 1..n, v <- (u + 1)..n//1, reduce: {%{}, seed * 2_654_435_761} do
        {acc, state} ->
          {bit, state} = next(state)
          {wbits, state} = next(state)

          if rem(bit, 3) == 0 do
            w = 1.0 + rem(wbits, 5)
            {Map.put(acc, {:"n#{u}", :"n#{v}"}, w), state}
          else
            {acc, state}
          end
      end

    {nodes, edges}
  end

  # 32-bit LCG (Numerical Recipes constants), returns {value, next_state}.
  defp next(state) do
    s = rem(state * 1_664_525 + 1_013_904_223, 4_294_967_296)
    {div(s, 65_536), s}
  end

  # ── reference greedy CNM (naive, node-id tie-break) ─────────────────
  #
  # Independent O(N^4) recompute-from-adjacency formulation. It shares the
  # production tie-break (max gain; tie → lexicographically smaller pair of
  # community keys, a key being the community's minimum node-id) but none
  # of the incremental aggregate maintenance, so a match cross-checks the
  # optimised module's *math*, not merely its tie-break.

  defp reference_detect(nodes, edges) do
    adjacency = ref_adjacency(nodes, edges)
    total = ref_total(edges)

    case total do
      +0.0 -> Enum.map(nodes, &MapSet.new([&1]))
      _ -> ref_greedy(Enum.map(nodes, &MapSet.new([&1])), adjacency, total)
    end
  end

  defp ref_greedy(communities, adjacency, total) do
    case ref_best(communities, adjacency, total) do
      :none ->
        communities

      {ka, kb} ->
        ca = Enum.find(communities, &(ref_key(&1) == ka))
        cb = Enum.find(communities, &(ref_key(&1) == kb))
        merged = MapSet.union(ca, cb)
        rest = Enum.reject(communities, &(&1 == ca or &1 == cb))
        ref_greedy([merged | rest], adjacency, total)
    end
  end

  defp ref_best(communities, adjacency, total) do
    keyed = Enum.map(communities, &{ref_key(&1), &1})

    pairs =
      for {ka, ca} <- keyed,
          {kb, cb} <- keyed,
          ka < kb,
          ref_connected?(ca, cb, adjacency),
          do: {ka, kb, ca, cb}

    gains =
      Enum.map(pairs, fn {ka, kb, ca, cb} -> {ref_gain(ca, cb, adjacency, total), ka, kb} end)

    case gains do
      [] ->
        :none

      _ ->
        {gain, ka, kb} =
          Enum.reduce(gains, fn {g1, ka1, kb1} = cand, {g0, ka0, kb0} = best ->
            cond do
              g1 > g0 -> cand
              g1 < g0 -> best
              {ka1, kb1} < {ka0, kb0} -> cand
              true -> best
            end
          end)

        if gain > 0.0, do: {ka, kb}, else: :none
    end
  end

  # A community's stable key: its minimum node-id.
  defp ref_key(community), do: Enum.min(community)

  defp ref_connected?(ci, cj, adjacency) do
    Enum.any?(ci, fn u ->
      ns = Map.get(adjacency, u, %{})
      Enum.any?(cj, &Map.has_key?(ns, &1))
    end)
  end

  defp ref_gain(u, v, adjacency, total) do
    e_uv = ref_between(u, v, adjacency) / total
    a_u = ref_incident(u, adjacency) / (2 * total)
    a_v = ref_incident(v, adjacency) / (2 * total)
    2 * (e_uv - a_u * a_v)
  end

  defp ref_between(u, v, adjacency) do
    Enum.reduce(u, 0.0, fn node, acc ->
      ns = Map.get(adjacency, node, %{})
      acc + Enum.reduce(v, 0.0, fn other, inner -> inner + Map.get(ns, other, 0) end)
    end)
  end

  defp ref_incident(c, adjacency) do
    Enum.reduce(c, 0.0, fn node, acc ->
      acc + (adjacency |> Map.get(node, %{}) |> Map.values() |> Enum.sum())
    end)
  end

  defp ref_adjacency(nodes, edges) do
    base = Map.new(nodes, &{&1, %{}})

    Enum.reduce(edges, base, fn {{u, v}, w}, acc ->
      if u == v or w <= 0 do
        acc
      else
        acc
        |> Map.put_new(u, %{})
        |> Map.put_new(v, %{})
        |> Map.update!(u, &Map.update(&1, v, w, fn x -> x + w end))
        |> Map.update!(v, &Map.update(&1, u, w, fn x -> x + w end))
      end
    end)
  end

  defp ref_total(edges) do
    edges
    |> Enum.reject(fn {{u, v}, w} -> u == v or w <= 0 end)
    |> Enum.reduce(0.0, fn {_pair, w}, acc -> acc + w end)
  end
end
