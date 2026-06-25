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

      clusters = NearClones.from_sources(pairs, min_mass: 8, threshold: 0.85, min_merge_mass: 0)

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

      [cluster] = NearClones.from_sources(pairs, min_mass: 8, threshold: 0.85, min_merge_mass: 0)

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

      [cluster] = NearClones.from_sources(pairs, min_mass: 8, threshold: 0.85, min_merge_mass: 0)
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

  describe "min_merge_mass gate (the notify_updated_or_show_errors case)" do
    # A trivial one-liner recurring widely IS a clone — it clusters — but
    # extracting a 12-node block into a named helper reads worse than the inline
    # expression no matter how often it recurs, so the average-mass floor
    # withholds the `mergeable` flag the merge refactor gates on. This is the
    # real position-db `notify_updated_or_show_errors` shape (mass ~12, occ 16).
    defp one_liner(name),
      do: "  defp #{name}(socket, changeset), do: {:noreply, assign(socket, form: changeset)}\n"

    # A genuinely fat (~40-node) body — the `load_window…`-class merge target.
    defp fat_def(name),
      do: """
        def #{name}(item_offset, args, limit) do
          start = max(0, item_offset - div(limit, 2))
          {entries, total} = list(args, offset: start, limit: limit)
          rows = index_entries(entries, start)
          top = if start == 0, do: :done, else: Cursor.encode(start)
          bottom = if start + length(rows) >= total, do: :done, else: Cursor.encode(start + length(rows))
          extra = Enum.map(rows, fn r -> {r.id, r.label} end)
          {:ok, rows, %{bottom: bottom, top: top, extra: extra}}
        end
      """

    test "a trivial body still clusters but is NOT mergeable under the mass floor" do
      pairs =
        for i <- 1..6, do: {"m#{i}.ex", mod("M#{i}", one_liner("notify_#{i}"))}

      [cluster] = NearClones.from_sources(pairs, min_mass: 4, threshold: 0.85)

      # detection still groups all six occurrences …
      assert length(cluster.occurrences) == 6
      # … but the block is too small to justify a named helper.
      refute cluster.mergeable
      assert cluster.avg_mass < 40
    end

    test "the same trivial cluster IS mergeable when min_merge_mass is lowered" do
      pairs =
        for i <- 1..6, do: {"m#{i}.ex", mod("M#{i}", one_liner("notify_#{i}"))}

      [cluster] = NearClones.from_sources(pairs, min_mass: 4, threshold: 0.85, min_merge_mass: 0)
      assert cluster.mergeable
    end

    test "a fat verbatim block recurring across files clears the floor" do
      pairs = for i <- 1..3, do: {"s#{i}.ex", mod("S#{i}", fat_def("load_window_#{i}"))}

      [cluster] = NearClones.from_sources(pairs, min_mass: 8, threshold: 0.85)
      assert cluster.mergeable
      assert cluster.avg_mass >= 40
    end
  end
end
