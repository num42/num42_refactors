defmodule Number42.Refactors.Ex.EnumReduceToSumTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.EnumReduceToSum

  @subject EnumReduceToSum

  describe "rewrites" do
    test "Enum.reduce(coll, 0, fn x, acc -> x + acc end) -> Enum.sum(coll)" do
      assert_rewrites(
        @subject,
        "Enum.reduce(list, 0, fn x, acc -> x + acc end)",
        "Enum.sum(list)"
      )
    end

    test "Enum.reduce(coll, 0, fn x, acc -> acc + x end) -> Enum.sum(coll)" do
      assert_rewrites(
        @subject,
        "Enum.reduce(list, 0, fn x, acc -> acc + x end)",
        "Enum.sum(list)"
      )
    end

    test "summing a projection becomes Enum.sum_by/2" do
      assert_rewrites(
        @subject,
        "Enum.reduce(list, 0, fn x, acc -> x.qty + acc end)",
        "Enum.sum_by(list, fn x -> x.qty end)"
      )
    end
  end

  describe "leaves alone" do
    test "non-zero seed (semantic difference)" do
      assert_unchanged(@subject, "Enum.reduce(list, 1, fn x, acc -> x + acc end)")
    end

    test "non-additive lambda" do
      assert_unchanged(@subject, "Enum.reduce(list, 0, fn x, acc -> x * acc end)")
    end

    test "already Enum.sum" do
      assert_unchanged(@subject, "Enum.sum(list)")
    end

    test "already Enum.sum_by" do
      assert_unchanged(@subject, "Enum.sum_by(list, & &1.qty)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "Enum.reduce(list, 0, fn x, acc -> x + acc end)")
    end
  end
end
