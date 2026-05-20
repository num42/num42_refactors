defmodule Num42.Refactors.Refactors.ReduceMapPutTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.ReduceMapPut

  @subject ReduceMapPut

  describe "rewrites" do
    test "Enum.reduce building a map via Map.put -> Map.new/2" do
      assert_rewrites(
        @subject,
        "Enum.reduce(list, %{}, fn x, acc -> Map.put(acc, x.k, x.v) end)",
        "Map.new(list, fn x -> {x.k, x.v} end)"
      )
    end
  end

  describe "leaves alone" do
    test "non-empty map seed" do
      assert_unchanged(
        @subject,
        "Enum.reduce(list, %{a: 1}, fn x, acc -> Map.put(acc, x.k, x.v) end)"
      )
    end

    test "Map.update instead of Map.put (different semantic)" do
      assert_unchanged(
        @subject,
        "Enum.reduce(list, %{}, fn x, acc -> Map.update(acc, x.k, 1, &(&1 + 1)) end)"
      )
    end

    test "already Map.new/2" do
      assert_unchanged(@subject, "Map.new(list, fn x -> {x.k, x.v} end)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(
        @subject,
        "Enum.reduce(list, %{}, fn x, acc -> Map.put(acc, x.k, x.v) end)"
      )
    end
  end
end
