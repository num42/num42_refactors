defmodule Number42.Refactors.Ex.EnumIntoToMapSetTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.EnumIntoToMapSet

  @subject EnumIntoToMapSet

  describe "rewrites" do
    test "Enum.into(coll, MapSet.new()) -> MapSet.new(coll)" do
      assert_rewrites(@subject, "Enum.into(items, MapSet.new())", "MapSet.new(items)")
    end

    test "pipe form rewrites the call" do
      assert_rewrites(@subject, "stream |> Enum.into(MapSet.new())", "stream |> MapSet.new()")
    end

    test "multi-stage pipe re-threads onto the chain instead of wrapping" do
      assert_rewrites(
        @subject,
        "coll |> step() |> Enum.into(MapSet.new())",
        "coll |> step() |> MapSet.new()"
      )
    end
  end

  describe "leaves alone" do
    test "seeded MapSet.new (semantic difference: merges into existing set)" do
      assert_unchanged(@subject, "Enum.into(items, MapSet.new([1, 2]))")
    end

    test "empty map literal (that is EnumIntoToMapNew's job)" do
      assert_unchanged(@subject, "Enum.into(pairs, %{})")
    end

    test "list accumulator" do
      assert_unchanged(@subject, "Enum.into(items, [])")
    end

    test "already conformant" do
      assert_unchanged(@subject, "MapSet.new(items)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "Enum.into(items, MapSet.new())")
    end
  end
end
