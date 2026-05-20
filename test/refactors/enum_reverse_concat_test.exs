defmodule Num42.Refactors.Refactors.EnumReverseConcatTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.EnumReverseConcat

  @subject EnumReverseConcat

  describe "rewrites" do
    test "Enum.reverse(a) ++ b -> Enum.reverse(a, b)" do
      assert_rewrites(@subject, "Enum.reverse(a) ++ b", "Enum.reverse(a, b)")
    end

    test "with computed RHS" do
      assert_rewrites(
        @subject,
        "Enum.reverse(prefix) ++ build_tail(x)",
        "Enum.reverse(prefix, build_tail(x))"
      )
    end

    test "pipe form: a |> Enum.reverse() ++ b -> a |> Enum.reverse(b)" do
      assert_rewrites(@subject, "a |> Enum.reverse() ++ b", "a |> Enum.reverse(b)")
    end

    test "longer pipe + reverse + concat" do
      assert_rewrites(
        @subject,
        "x |> filter() |> Enum.reverse() ++ tail",
        "x |> filter() |> Enum.reverse(tail)"
      )
    end
  end

  describe "leaves alone" do
    test "concat without reverse" do
      assert_unchanged(@subject, "a ++ b")
    end

    test "Enum.reverse without concat" do
      assert_unchanged(@subject, "Enum.reverse(a)")
    end

    test "concat where reverse is on the right" do
      assert_unchanged(@subject, "a ++ Enum.reverse(b)")
    end

    test "Enum.reverse with two args (already there)" do
      assert_unchanged(@subject, "Enum.reverse(a, b)")
    end

    test "List.reverse (different module)" do
      assert_unchanged(@subject, "List.reverse(a) ++ b")
    end
  end

  describe "preserves leading comments" do
    test "comment before the rewritten expression isn't duplicated" do
      before_source = """
      # cycle or missing parent — give up
      Enum.reverse(acc) ++ rest
      """

      after_source = """
      # cycle or missing parent — give up
      Enum.reverse(acc, rest)
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "idempotent" do
    test "rewrites only once" do
      assert_idempotent(@subject, "Enum.reverse(a) ++ b")
    end

    test "already rewritten" do
      assert_idempotent(@subject, "Enum.reverse(a, b)")
    end
  end
end
