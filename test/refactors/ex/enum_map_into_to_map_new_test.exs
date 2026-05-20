defmodule Number42.Refactors.Ex.EnumMapIntoToMapNewTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.EnumMapIntoToMapNew

  @subject EnumMapIntoToMapNew

  describe "rewrites" do
    test "Enum.into(Enum.map(coll, fun), %{}) -> Map.new(coll, fun)" do
      assert_rewrites(@subject, "Enum.into(Enum.map(pairs, fun), %{})", "Map.new(pairs, fun)")
    end

    test "pipe form rewrites the call" do
      assert_rewrites(
        @subject,
        "pairs |> Enum.map(fun) |> Enum.into(%{})",
        "Map.new(pairs, fun)"
      )
    end
  end

  describe "leaves alone" do
    test "Enum.into without a wrapping Enum.map" do
      assert_unchanged(@subject, "Enum.into(pairs, %{})")
    end

    test "non-empty map accumulator" do
      assert_unchanged(@subject, "Enum.into(Enum.map(pairs, fun), %{a: 1})")
    end

    test "already conformant" do
      assert_unchanged(@subject, "Map.new(pairs, fun)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "Enum.into(Enum.map(pairs, fun), %{})")
    end
  end
end
