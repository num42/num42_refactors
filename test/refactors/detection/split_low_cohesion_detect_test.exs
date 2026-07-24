defmodule Number42.Refactors.Detection.SplitLowCohesionDetectTest do
  @moduledoc """
  SplitLowCohesionModule's detection, read through the Detection contract.

  Two properties carry the weight here:

    * **it writes nothing.** `build_plan/2` creates one `.ex` per moved
      cluster unless `dry_run: true`, so a detector that forgot the flag
      would generate files just by looking.
    * **declined modules are reported.** This refactor already tracked
      declines with reasons; detection makes that audit trail readable
      by something other than `report/1`.
  """
  use ExUnit.Case, async: true

  alias Number42.Refactors.Detection.Finding
  alias Number42.Refactors.Ex.SplitLowCohesionModule

  # Two disjoint concerns in one module: user-name formatting and
  # invoice-total arithmetic. No call edge between the groups, so the
  # call graph has two clean communities.
  defp god_module do
    """
    defmodule MyApp.Grab.Bag do
      def user_label(user), do: user_first(user) <> " " <> user_last(user)
      def user_first(user), do: user.first
      def user_last(user), do: user.last
      def user_initials(user), do: user_first(user) <> user_last(user)

      def invoice_total(inv), do: invoice_net(inv) + invoice_tax(inv)
      def invoice_net(inv), do: inv.net
      def invoice_tax(inv), do: invoice_net(inv) * 0.19
      def invoice_rounded(inv), do: round(invoice_total(inv))
    end
    """
  end

  defp cohesive_module do
    """
    defmodule MyApp.Tight do
      def a(x), do: b(x) + c(x)
      def b(x), do: c(x) * 2
      def c(x), do: x + 1
    end
    """
  end

  setup do
    dir = System.tmp_dir!() |> Path.join("cohesion_detect_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  describe "detect_corpus/2 writes nothing" do
    test "creates no files even when it finds a splittable module", %{dir: dir} do
      path = Path.join(dir, "grab_bag.ex")
      File.write!(path, god_module())

      SplitLowCohesionModule.detect_corpus([{path, god_module()}], write_root: dir)

      assert File.ls!(dir) == ["grab_bag.ex"]
    end

    test "leaves the analysed source byte-identical", %{dir: dir} do
      path = Path.join(dir, "grab_bag.ex")
      File.write!(path, god_module())

      SplitLowCohesionModule.detect_corpus([{path, god_module()}], write_root: dir)

      assert File.read!(path) == god_module()
    end

    test "ignores an explicit dry_run: false from the caller", %{dir: dir} do
      path = Path.join(dir, "grab_bag.ex")
      File.write!(path, god_module())

      SplitLowCohesionModule.detect_corpus(
        [{path, god_module()}],
        write_root: dir,
        dry_run: false
      )

      assert File.ls!(dir) == ["grab_bag.ex"]
    end
  end

  describe "findings" do
    test "returns findings for the analysed corpus", %{dir: dir} do
      path = Path.join(dir, "grab_bag.ex")

      findings =
        SplitLowCohesionModule.detect_corpus([{path, god_module()}], write_root: dir)

      assert Enum.all?(findings, &(&1.kind == :low_cohesion_module))
      assert Enum.all?(findings, &(&1.refactor == SplitLowCohesionModule))
    end

    test "names the module it considered in the finding's scope", %{dir: dir} do
      path = Path.join(dir, "grab_bag.ex")

      modules =
        SplitLowCohesionModule.detect_corpus([{path, god_module()}], write_root: dir)
        |> Enum.map(& &1.scope.module)

      assert MyApp.Grab.Bag in modules
    end

    test "an accepted finding lists the submodules the split would create", %{dir: dir} do
      path = Path.join(dir, "grab_bag.ex")

      accepted =
        SplitLowCohesionModule.detect_corpus([{path, god_module()}], write_root: dir)
        |> Finding.accepted()

      for finding <- accepted do
        assert finding.evidence.clusters >= 2
        assert length(finding.evidence.targets) == finding.evidence.clusters
      end
    end

    test "a declined finding carries the reason and the modularity measurement", %{dir: dir} do
      path = Path.join(dir, "tight.ex")

      declined =
        SplitLowCohesionModule.detect_corpus([{path, cohesive_module()}], write_root: dir)
        |> Finding.declined()

      for finding <- declined do
        assert is_binary(finding.decline)
        assert Map.has_key?(finding.evidence, :modularity)
      end
    end

    test "modularity is evidence, never confidence — it can go negative", %{dir: dir} do
      path = Path.join(dir, "tight.ex")

      findings =
        SplitLowCohesionModule.detect_corpus([{path, cohesive_module()}], write_root: dir)

      assert Enum.all?(findings, &(&1.confidence == nil))
    end

    test "is deterministic across runs", %{dir: dir} do
      corpus = [{Path.join(dir, "grab_bag.ex"), god_module()}]

      assert SplitLowCohesionModule.detect_corpus(corpus, write_root: dir) ==
               SplitLowCohesionModule.detect_corpus(corpus, write_root: dir)
    end

    test "returns no findings for an empty corpus", %{dir: dir} do
      assert SplitLowCohesionModule.detect_corpus([], write_root: dir) == []
    end
  end

  describe "wiring" do
    test "declares itself as its own detector" do
      assert SplitLowCohesionModule.detector() == SplitLowCohesionModule
    end

    test "exposes only the corpus entry point — cohesion has no single-file answer" do
      refute function_exported?(SplitLowCohesionModule, :detect, 2)
      assert function_exported?(SplitLowCohesionModule, :detect_corpus, 2)
    end
  end
end
