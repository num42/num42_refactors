defmodule Number42.Refactors.Ex.SortReverseToDescTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.SortReverseToDesc

  @subject SortReverseToDesc

  # Default-OFF: every assertion runs with the opt-in gate flipped on.
  @on [enabled: true]

  describe "rewrites (sort)" do
    test "call-fed sort + reverse -> sort(:desc)" do
      assert_rewrites(
        @subject,
        "Enum.sort(coll) |> Enum.reverse()",
        "Enum.sort(coll, :desc)",
        @on
      )
    end

    test "pipe-fed sort + reverse re-threads onto the chain" do
      assert_rewrites(
        @subject,
        "coll |> Enum.sort() |> Enum.reverse()",
        "coll |> Enum.sort(:desc)",
        @on
      )
    end

    test "multi-stage pipe stays left-to-right" do
      assert_rewrites(
        @subject,
        "coll |> step() |> Enum.sort() |> Enum.reverse()",
        "coll |> step() |> Enum.sort(:desc)",
        @on
      )
    end
  end

  describe "rewrites (sort_by)" do
    test "call-fed sort_by + reverse -> sort_by(:desc)" do
      assert_rewrites(
        @subject,
        "Enum.sort_by(coll, & &1.age) |> Enum.reverse()",
        "Enum.sort_by(coll, & &1.age, :desc)",
        @on
      )
    end

    test "pipe-fed sort_by + reverse re-threads onto the chain" do
      assert_rewrites(
        @subject,
        "coll |> Enum.sort_by(&age/1) |> Enum.reverse()",
        "coll |> Enum.sort_by(&age/1, :desc)",
        @on
      )
    end
  end

  describe "leaves alone" do
    test "default-OFF: no-op without enabled: true" do
      assert_unchanged(@subject, "Enum.sort(coll) |> Enum.reverse()")
    end

    test "sort already carries a direction" do
      assert_unchanged(@subject, "Enum.sort(coll, :asc) |> Enum.reverse()", @on)
    end

    test "sort already carries a custom sorter capture" do
      assert_unchanged(@subject, "Enum.sort(coll, &>=/2) |> Enum.reverse()", @on)
    end

    test "sort_by already carries a direction" do
      assert_unchanged(@subject, "Enum.sort_by(coll, fun, :asc) |> Enum.reverse()", @on)
    end

    test "sort_by already carries :desc" do
      assert_unchanged(@subject, "Enum.sort_by(coll, fun, :desc) |> Enum.reverse()", @on)
    end

    test "reverse/2 (arity 2) is a different operation" do
      assert_unchanged(@subject, "Enum.sort(coll) |> Enum.reverse(tail)", @on)
    end

    test "bare sort without trailing reverse" do
      assert_unchanged(@subject, "Enum.sort(coll)", @on)
    end

    test "already conformant sort(:desc)" do
      assert_unchanged(@subject, "Enum.sort(coll, :desc)", @on)
    end
  end

  describe "idempotent" do
    test "sort: running twice equals running once" do
      assert_idempotent(@subject, "Enum.sort(coll) |> Enum.reverse()", @on)
    end

    test "sort_by: running twice equals running once" do
      assert_idempotent(@subject, "Enum.sort_by(coll, fun) |> Enum.reverse()", @on)
    end
  end
end
