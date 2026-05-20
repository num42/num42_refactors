defmodule Number42.Refactors.Ex.SortForTopKTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.SortForTopK

  @subject SortForTopK

  # SortForTopK matches two AST shapes: a fully nested call form
  # (`Enum.take(Enum.sort(coll), 1)`) and a fully piped chain headed
  # by the collection (`coll |> Enum.sort() |> Enum.take(1)`). A
  # half-pipe like `Enum.sort(coll) |> Enum.take(1)` is the call form
  # the parser doesn't normalize; the refactor leaves it alone.
  describe "rewrites" do
    test "nested Enum.take(Enum.sort(coll), 1) -> [Enum.min(coll)]" do
      assert_rewrites(@subject, "Enum.take(Enum.sort(list), 1)", "[Enum.min(list)]")
    end

    test "nested hd(Enum.sort(coll)) -> Enum.min(coll)" do
      assert_rewrites(@subject, "hd(Enum.sort(list))", "Enum.min(list)")
    end

    test "full pipe with sort -> take(1) -> Enum.min" do
      assert_rewrites(
        @subject,
        "list |> Enum.sort() |> Enum.take(1)",
        "list |> Enum.min()"
      )
    end

    test ":desc sort with take(1) becomes Enum.max" do
      assert_rewrites(
        @subject,
        "list |> Enum.sort(:desc) |> Enum.take(1)",
        "list |> Enum.max()"
      )
    end
  end

  describe "leaves alone" do
    test "Enum.sort with no take/hd downstream" do
      assert_unchanged(@subject, "Enum.sort(list)")
    end

    test "Enum.take with no upstream sort" do
      assert_unchanged(@subject, "Enum.take(list, 1)")
    end

    test "Enum.take with k > 1 (genuine top-k)" do
      assert_unchanged(@subject, "list |> Enum.sort() |> Enum.take(5)")
    end

    test "custom comparator (semantics can't be safely collapsed)" do
      assert_unchanged(@subject, "list |> Enum.sort(&(&1.x < &2.x)) |> Enum.take(1)")
    end

    test "already Enum.min" do
      assert_unchanged(@subject, "Enum.min(list)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "Enum.take(Enum.sort(list), 1)")
    end
  end
end
