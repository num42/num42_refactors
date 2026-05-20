defmodule Number42.Refactors.Ex.LengthZeroToEmptyTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.LengthZeroToEmpty

  @subject LengthZeroToEmpty

  describe "rewrites — Enum.count(x) and length(x) compared to 0" do
    test "Enum.count(x) == 0 -> Enum.empty?(x)" do
      assert_rewrites(@subject, "Enum.count(x) == 0", "Enum.empty?(x)")
    end

    test "0 == Enum.count(x) -> Enum.empty?(x)" do
      assert_rewrites(@subject, "0 == Enum.count(x)", "Enum.empty?(x)")
    end

    test "length(x) == 0 -> Enum.empty?(x)" do
      assert_rewrites(@subject, "length(x) == 0", "Enum.empty?(x)")
    end

    test "0 == length(x) -> Enum.empty?(x)" do
      assert_rewrites(@subject, "0 == length(x)", "Enum.empty?(x)")
    end

    test "Enum.count(x) > 0 -> not Enum.empty?(x)" do
      assert_rewrites(@subject, "Enum.count(x) > 0", "not Enum.empty?(x)")
    end

    test "Enum.count(x) != 0 -> not Enum.empty?(x)" do
      assert_rewrites(@subject, "Enum.count(x) != 0", "not Enum.empty?(x)")
    end

    test "0 < Enum.count(x) -> not Enum.empty?(x)" do
      assert_rewrites(@subject, "0 < Enum.count(x)", "not Enum.empty?(x)")
    end

    test "0 != Enum.count(x) -> not Enum.empty?(x)" do
      assert_rewrites(@subject, "0 != Enum.count(x)", "not Enum.empty?(x)")
    end

    test "length(x) > 0 -> not Enum.empty?(x)" do
      assert_rewrites(@subject, "length(x) > 0", "not Enum.empty?(x)")
    end

    test "length(x) != 0 -> not Enum.empty?(x)" do
      assert_rewrites(@subject, "length(x) != 0", "not Enum.empty?(x)")
    end

    test "0 < length(x) -> not Enum.empty?(x)" do
      assert_rewrites(@subject, "0 < length(x)", "not Enum.empty?(x)")
    end
  end

  describe "rewrites — pipe forms" do
    test "x |> length() == 0 -> x |> Enum.empty?()" do
      assert_rewrites(@subject, "x |> length() == 0", "x |> Enum.empty?()")
    end

    test "x |> Enum.count() == 0 -> x |> Enum.empty?()" do
      assert_rewrites(@subject, "x |> Enum.count() == 0", "x |> Enum.empty?()")
    end

    test "x |> Enum.count() > 0 -> not (x |> Enum.empty?())" do
      assert_rewrites(@subject, "x |> Enum.count() > 0", "not (x |> Enum.empty?())")
    end

    test "longer pipe + count == 0" do
      before_source = "x |> filter() |> Enum.count() == 0"
      after_source = "x |> filter() |> Enum.empty?()"
      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "rewrites — Enum.count(x, fun) becomes Enum.any?" do
    test "Enum.count(x, fun) > 0 -> Enum.any?(x, fun)" do
      assert_rewrites(@subject, "Enum.count(x, &positive?/1) > 0", "Enum.any?(x, &positive?/1)")
    end

    test "Enum.count(x, fun) != 0 -> Enum.any?(x, fun)" do
      assert_rewrites(@subject, "Enum.count(x, &positive?/1) != 0", "Enum.any?(x, &positive?/1)")
    end

    test "0 < Enum.count(x, fun) -> Enum.any?(x, fun)" do
      assert_rewrites(@subject, "0 < Enum.count(x, &positive?/1)", "Enum.any?(x, &positive?/1)")
    end

    test "Enum.count(x, fun) == 0 -> not Enum.any?(x, fun)" do
      assert_rewrites(
        @subject,
        "Enum.count(x, &positive?/1) == 0",
        "not Enum.any?(x, &positive?/1)"
      )
    end

    test "0 == Enum.count(x, fun) -> not Enum.any?(x, fun)" do
      assert_rewrites(
        @subject,
        "0 == Enum.count(x, &positive?/1)",
        "not Enum.any?(x, &positive?/1)"
      )
    end

    test "Enum.count with fn lambda" do
      before_source = "Enum.count(items, fn i -> i.active end) > 0"
      after_source = "Enum.any?(items, fn i -> i.active end)"
      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "rewrites — guard context (length only, becomes == [])" do
    test "length(x) == 0 in def-guard -> x == []" do
      before_source = """
      def f(x) when length(x) == 0, do: :empty
      """

      after_source = "def f(x) when x == [], do: :empty"
      assert_rewrites(@subject, before_source, after_source)
    end

    test "0 == length(x) in def-guard -> x == []" do
      before_source = """
      def f(x) when 0 == length(x), do: :empty
      """

      after_source = "def f(x) when x == [], do: :empty"
      assert_rewrites(@subject, before_source, after_source)
    end

    test "length(x) != 0 in def-guard -> is_list(x) and x != []" do
      before_source = """
      def f(x) when length(x) != 0, do: :nonempty
      """

      after_source = "def f(x) when is_list(x) and x != [], do: :nonempty"
      assert_rewrites(@subject, before_source, after_source)
    end

    test "length in `case` clause guard" do
      before_source = """
      case x do
        x when length(x) == 0 -> :empty
        _ -> :other
      end
      """

      after_source = """
      case x do
        x when x == [] -> :empty
        _ -> :other
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "Enum.count IS NOT touched in guards (it's not allowed there anyway)" do
      assert_unchanged(@subject, """
      def f(x) when Enum.count(x) == 0, do: :empty
      """)
    end
  end

  describe "leaves alone" do
    test "comparison to non-zero literal" do
      assert_unchanged(@subject, "Enum.count(x) == 1")
    end

    test "comparison between two counts" do
      assert_unchanged(@subject, "Enum.count(x) == Enum.count(y)")
    end

    test "Enum.count with three args (not relevant)" do
      assert_unchanged(@subject, "x == 0")
    end

    test "length with non-zero" do
      assert_unchanged(@subject, "length(x) == 5")
    end

    test "0 < y where y is not length/count" do
      assert_unchanged(@subject, "0 < other_func(x)")
    end

    test "Enum.count(x) >= 0 (always true, but not our pattern)" do
      assert_unchanged(@subject, "Enum.count(x) >= 0")
    end

    test "Enum.count(x) < 0 (always false, but not our pattern)" do
      assert_unchanged(@subject, "Enum.count(x) < 0")
    end
  end

  describe "idempotent" do
    test "Enum.count == 0 case" do
      assert_idempotent(@subject, "Enum.count(x) == 0")
    end

    test "length > 0 case" do
      assert_idempotent(@subject, "length(x) > 0")
    end

    test "Enum.count with fun" do
      assert_idempotent(@subject, "Enum.count(x, &positive?/1) > 0")
    end

    test "guard context" do
      assert_idempotent(@subject, """
      def f(x) when length(x) == 0, do: :empty
      """)
    end

    test "already rewritten" do
      assert_idempotent(@subject, "Enum.empty?(x)")
    end
  end
end
