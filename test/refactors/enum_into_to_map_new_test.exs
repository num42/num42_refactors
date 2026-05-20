defmodule Num42.Refactors.Refactors.EnumIntoToMapNewTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.EnumIntoToMapNew

  @subject EnumIntoToMapNew

  describe "rewrites" do
    test "Enum.into(coll, %{}) -> Map.new(coll)" do
      assert_rewrites(@subject, "Enum.into(pairs, %{})", "Map.new(pairs)")
    end

    test "pipe form rewrites the call" do
      assert_rewrites(@subject, "stream |> Enum.into(%{})", "Map.new(stream)")
    end
  end

  describe "leaves alone" do
    test "non-empty map (semantic difference: merges into existing map)" do
      assert_unchanged(@subject, "Enum.into(pairs, %{a: 1})")
    end

    test "struct accumulator (not a bare map literal)" do
      assert_unchanged(@subject, "Enum.into(pairs, %SomeStruct{})")
    end

    test "wrapping an Enum.map (defers to EnumMapIntoToMapNew)" do
      assert_unchanged(@subject, "Enum.into(Enum.map(pairs, fun), %{})")
    end

    test "list accumulator" do
      assert_unchanged(@subject, "Enum.into(pairs, [])")
    end

    test "already conformant" do
      assert_unchanged(@subject, "Map.new(pairs)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "Enum.into(pairs, %{})")
    end
  end
end
