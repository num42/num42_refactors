defmodule Number42.Refactors.Ex.ExtractParametricClone.PickTargetTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Ex.ExtractParametricClone

  defp entries(modules), do: modules |> Enum.map(&entry/1)
  defp entry(module), do: %{module: module}

  describe "pick_target/1 — :intra (single file ≥ 2 occurrences)" do
    test "3 in Foo, 1 in Bar → :intra Foo" do
      es = entries([Foo, Foo, Foo, Bar])
      assert {:intra, Foo} = ExtractParametricClone.pick_target(es)
    end

    test "5 in Foo (alone) → :intra Foo" do
      es = entries([Foo, Foo, Foo, Foo, Foo])
      assert {:intra, Foo} = ExtractParametricClone.pick_target(es)
    end

    test "tie 2/2 → longest module chain wins" do
      es = entries([Foo.A, Foo.A, Foo.A.B, Foo.A.B])
      # Foo.A.B has 3 segments vs Foo.A 2 — Foo.A.B wins
      assert {:intra, Foo.A.B} = ExtractParametricClone.pick_target(es)
    end

    test "tie 2/2, equal chain length → longer module name string wins" do
      # Foo.AB and Foo.X both have 2 segments. AB is the longer name.
      es = entries([Foo.AB, Foo.AB, Foo.X, Foo.X])
      assert {:intra, Foo.AB} = ExtractParametricClone.pick_target(es)
    end

    test "tie on count and chain length → alphabetical first" do
      es = entries([Foo.X, Foo.X, Foo.Y, Foo.Y])
      assert {:intra, Foo.X} = ExtractParametricClone.pick_target(es)
    end

    test "tie 3/3, equal chain length, equal name length → alphabetical first" do
      es = entries([Foo.AAA, Foo.AAA, Foo.AAA, Foo.BBB, Foo.BBB, Foo.BBB])
      assert {:intra, Foo.AAA} = ExtractParametricClone.pick_target(es)
    end
  end

  describe "pick_target/1 — :suffix (distributed 1+1+1...)" do
    test "Format wins over Formatter, Helper, Helpers, Shared (full priority order)" do
      es =
        entries([
          My.App.A.Shared,
          My.App.B.Helpers,
          My.App.C.Helper,
          My.App.D.Formatter,
          My.App.E.Format
        ])

      assert {:suffix, My.App.E.Format} = ExtractParametricClone.pick_target(es)
    end

    test "Formatter wins over Helper, Helpers, Shared" do
      es =
        entries([
          My.App.A.Shared,
          My.App.B.Helpers,
          My.App.C.Helper,
          My.App.D.Formatter
        ])

      assert {:suffix, My.App.D.Formatter} = ExtractParametricClone.pick_target(es)
    end

    test "Formatter wins over Helper and Shared" do
      es = entries([My.App.Foo, My.App.Bar.Formatter, My.App.Baz])
      assert {:suffix, My.App.Bar.Formatter} = ExtractParametricClone.pick_target(es)
    end

    test "Helper wins over Shared" do
      es = entries([My.App.Foo, My.App.Bar.Helper, My.App.Baz.Shared])
      assert {:suffix, My.App.Bar.Helper} = ExtractParametricClone.pick_target(es)
    end

    test "Helpers (plural) treated like Helper" do
      es = entries([My.App.Foo, My.App.Bar.Helpers, My.App.Baz])
      assert {:suffix, My.App.Bar.Helpers} = ExtractParametricClone.pick_target(es)
    end

    test "Shared wins when no Formatter/Helper present" do
      es = entries([My.App.Foo, My.App.Bar.Shared, My.App.Baz])
      assert {:suffix, My.App.Bar.Shared} = ExtractParametricClone.pick_target(es)
    end

    test "multiple Formatter modules — alphabetically first" do
      es =
        entries([
          My.App.Z.Formatter,
          My.App.Foo,
          My.App.A.Formatter
        ])

      assert {:suffix, My.App.A.Formatter} = ExtractParametricClone.pick_target(es)
    end

    test "no qualifying suffix → falls through to :lcp_shared" do
      es = entries([My.App.Foo, My.App.Bar, My.App.Baz])

      assert {:lcp_shared, My.App.Shared} = ExtractParametricClone.pick_target(es)
    end
  end

  describe "pick_target/1 — :lcp_shared fallback" do
    test "two distinct modules, no shared/helper/formatter suffix" do
      es = entries([My.App.Items, My.App.Items.Sub])

      assert {:lcp_shared, My.App.Items.Shared} = ExtractParametricClone.pick_target(es)
    end

    test "LCP < 1 segment — returns :skip" do
      es = entries([Foo, Bar])
      assert :skip = ExtractParametricClone.pick_target(es)
    end
  end

  describe "pick_target/1 — precedence between rules" do
    test "intra wins over suffix" do
      # Foo has 2 occurrences (intra concentration); Bar.Helper would
      # otherwise be a suffix winner. Intra wins.
      es = entries([Foo, Foo, Bar.Helper])
      assert {:intra, Foo} = ExtractParametricClone.pick_target(es)
    end

    test "suffix wins over LCP shared" do
      # All 1+1+1, but one is a Helper. Suffix should win.
      es = entries([My.App.A, My.App.B.Helper, My.App.C])
      assert {:suffix, My.App.B.Helper} = ExtractParametricClone.pick_target(es)
    end
  end
end
