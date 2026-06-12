defmodule Number42.Refactors.Ex.MapSumToSumByTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.MapSumToSumBy

  @subject MapSumToSumBy

  describe "rewrites" do
    test "pipe chain re-threads onto the pipe" do
      assert_rewrites(
        @subject,
        "coll |> Enum.map(& &1.amount) |> Enum.sum()",
        "coll |> Enum.sum_by(& &1.amount)"
      )
    end

    test "multi-stage pipe re-threads onto the chain" do
      assert_rewrites(
        @subject,
        "lines |> Enum.with_index() |> Enum.map(fn x -> x end) |> Enum.sum()",
        "lines |> Enum.with_index() |> Enum.sum_by(fn x -> x end)"
      )
    end

    test "nested call form keeps the call shape" do
      assert_rewrites(
        @subject,
        "Enum.sum(Enum.map(coll, &(&1 * &1)))",
        "Enum.sum_by(coll, &(&1 * &1))"
      )
    end

    test "half-piped map call keeps the call shape" do
      assert_rewrites(
        @subject,
        "Enum.map(coll, & &1.count) |> Enum.sum()",
        "Enum.sum_by(coll, & &1.count)"
      )
    end
  end

  describe "leaves alone" do
    test "Enum.sum without an upstream Enum.map" do
      assert_unchanged(@subject, "Enum.sum(list)")
    end

    test "Enum.map without a downstream Enum.sum" do
      assert_unchanged(@subject, "Enum.map(list, & &1.amount)")
    end

    test "already Enum.sum_by" do
      assert_unchanged(@subject, "Enum.sum_by(coll, & &1.amount)")
    end

    test "Enum.map piped into something else" do
      assert_unchanged(@subject, "coll |> Enum.map(& &1.x) |> Enum.max()")
    end

    test "aliased non-stdlib Enum" do
      assert_unchanged(@subject, "coll |> MyEnum.map(& &1.x) |> MyEnum.sum()")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "coll |> Enum.map(& &1.amount) |> Enum.sum()")
    end
  end
end
