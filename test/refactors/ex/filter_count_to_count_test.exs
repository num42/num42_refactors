defmodule Number42.Refactors.Ex.FilterCountToCountTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.FilterCountToCount

  @subject FilterCountToCount

  describe "rewrites" do
    test "pipe chain re-threads onto the pipe" do
      assert_rewrites(
        @subject,
        "coll |> Enum.filter(& &1.active) |> Enum.count()",
        "coll |> Enum.count(& &1.active)"
      )
    end

    test "multi-stage pipe re-threads onto the chain" do
      assert_rewrites(
        @subject,
        "rows |> Enum.with_index() |> Enum.filter(fn {x, _} -> x end) |> Enum.count()",
        "rows |> Enum.with_index() |> Enum.count(fn {x, _} -> x end)"
      )
    end

    test "half-piped filter call keeps the call shape" do
      assert_rewrites(
        @subject,
        "Enum.filter(coll, & &1.active) |> Enum.count()",
        "Enum.count(coll, & &1.active)"
      )
    end

    test "nested call form keeps the call shape" do
      assert_rewrites(
        @subject,
        "Enum.count(Enum.filter(coll, &active?/1))",
        "Enum.count(coll, &active?/1)"
      )
    end

    test "capture predicate" do
      assert_rewrites(
        @subject,
        "coll |> Enum.filter(&active?/1) |> Enum.count()",
        "coll |> Enum.count(&active?/1)"
      )
    end

    test "fn lambda predicate" do
      assert_rewrites(
        @subject,
        "Enum.filter(coll, fn x -> x > 0 end) |> Enum.count()",
        "Enum.count(coll, fn x -> x > 0 end)"
      )
    end
  end

  describe "leaves alone" do
    test "Enum.count/2 is already the target" do
      assert_unchanged(@subject, "Enum.count(coll, & &1.active)")
    end

    test "Enum.count/1 without an upstream Enum.filter" do
      assert_unchanged(@subject, "Enum.count(list)")
    end

    test "Enum.filter without a downstream Enum.count" do
      assert_unchanged(@subject, "Enum.filter(list, & &1.active)")
    end

    test "Enum.filter piped into something else" do
      assert_unchanged(@subject, "coll |> Enum.filter(& &1.active) |> Enum.sum()")
    end

    test "bare-variable predicate is not fused" do
      assert_unchanged(@subject, "coll |> Enum.filter(pred) |> Enum.count()")
    end

    test "aliased non-stdlib Enum" do
      assert_unchanged(@subject, "coll |> MyEnum.filter(& &1.x) |> MyEnum.count()")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "coll |> Enum.filter(& &1.active) |> Enum.count()")
    end
  end
end
