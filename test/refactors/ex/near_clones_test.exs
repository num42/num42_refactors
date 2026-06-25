defmodule Number42.Refactors.Ex.NearClonesTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Ex.NearClones

  defp mod(name, defs),
    do: """
    defmodule #{name} do
    #{defs}
    end
    """

  # A ~14-node body that differs from its twin only in one literal/operator/call.
  defp total_def(name, rate),
    do: """
      def #{name}(order) do
        subtotal = Enum.sum(order.lines)
        taxed = subtotal * #{rate}
        rounded = Float.round(taxed, 2)
        {subtotal, taxed, rounded}
      end
    """

  describe "from_sources/2 — near-clone clustering" do
    test "two def bodies differing only in a literal cluster as one near-clone" do
      pairs = [
        {"a.ex", mod("A", total_def("total", "1.19"))},
        {"b.ex", mod("B", total_def("total", "1.07"))}
      ]

      clusters = NearClones.from_sources(pairs, min_mass: 8, threshold: 0.85)

      assert [cluster] = clusters
      assert length(cluster.occurrences) == 2
      assert cluster.mergeable

      files = cluster.occurrences |> Enum.map(& &1.file) |> Enum.sort()
      assert files == ["a.ex", "b.ex"]
    end

    test "the divergent occurrence carries a :literal diff only" do
      pairs = [
        {"a.ex", mod("A", total_def("total", "1.19"))},
        {"b.ex", mod("B", total_def("total", "1.07"))}
      ]

      [cluster] = NearClones.from_sources(pairs, min_mass: 8, threshold: 0.85)

      other = Enum.find(cluster.occurrences, &(&1.diffs != []))
      assert [{:literal, _path, _from, _to}] = other.diffs
      assert other.similarity >= 0.85
      assert cluster.mergeable
    end

    test "byte-identical bodies (renamed locals) cluster mergeable with empty diff" do
      pairs = [
        {"a.ex", mod("A", total_def("total", "1.19"))},
        # same shape, only the local-variable names differ → α-renamed equal
        {"b.ex",
         mod("B", """
           def total(cart) do
             sub = Enum.sum(cart.lines)
             tax = sub * 1.19
             rnd = Float.round(tax, 2)
             {sub, tax, rnd}
           end
         """)}
      ]

      [cluster] = NearClones.from_sources(pairs, min_mass: 8, threshold: 0.85)
      assert cluster.mergeable
      assert Enum.all?(cluster.occurrences, &(&1.diffs == [] or &1.similarity == 1.0))
    end

    test "the representative carries name + arity" do
      pairs = [
        {"a.ex", mod("A", total_def("compute_total", "1.19"))},
        {"b.ex", mod("B", total_def("compute_net", "1.07"))}
      ]

      [cluster] = NearClones.from_sources(pairs, min_mass: 8, threshold: 0.85)
      assert cluster.representative.arity == 1
      assert cluster.representative.name in [:compute_total, :compute_net]
    end
  end

  describe "structural divergence flags non-mergeable" do
    test "an extra statement marks the cluster non-mergeable" do
      with_extra = """
        def total(order) do
          subtotal = Enum.sum(order.lines)
          taxed = subtotal * 1.19
          logged = Logger.info(taxed)
          rounded = Float.round(taxed, 2)
          {subtotal, taxed, rounded}
        end
      """

      without = total_def("total", "1.19")

      pairs = [{"a.ex", mod("A", without)}, {"b.ex", mod("B", with_extra)}]
      clusters = NearClones.from_sources(pairs, min_mass: 8, threshold: 0.75)

      case clusters do
        [cluster] ->
          refute cluster.mergeable

        [] ->
          # below threshold is also acceptable; the point is it never reports
          # mergeable for a structural difference.
          :ok
      end
    end
  end

  describe "threshold + mass-band + min-occurrence gates" do
    test "wildly different masses never cluster (mass-band prefilter)" do
      tiny = mod("A", "  def f(x), do: x")
      big = mod("B", total_def("total", "1.19"))
      clusters = NearClones.from_sources([{"a.ex", tiny}, {"b.ex", big}], min_mass: 2)
      assert clusters == []
    end

    test "structurally unrelated bodies of similar mass do not cluster" do
      a = """
        def parse(raw) do
          parts = String.split(raw, ",")
          trimmed = Enum.map(parts, &String.trim/1)
          Enum.reject(trimmed, &(&1 == ""))
        end
      """

      b = """
        def schedule(job) do
          delay = compute_delay(job)
          ref = Process.send_after(self(), :run, delay)
          Map.put(job, :ref, ref)
        end
      """

      pairs = [{"a.ex", mod("A", a)}, {"b.ex", mod("B", b)}]
      clusters = NearClones.from_sources(pairs, min_mass: 6, threshold: 0.85)
      assert clusters == []
    end

    test "a lone body is not a cluster (min_occurrences)" do
      pairs = [{"a.ex", mod("A", total_def("total", "1.19"))}]
      clusters = NearClones.from_sources(pairs, min_mass: 8, threshold: 0.85)
      assert clusters == []
    end
  end
end
