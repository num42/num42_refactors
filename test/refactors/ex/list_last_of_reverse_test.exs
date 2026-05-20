defmodule Number42.Refactors.Ex.ListLastOfReverseTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ListLastOfReverse

  @subject ListLastOfReverse

  describe "rewrites" do
    test "List.last(Enum.reverse(list)) -> List.first(list)" do
      assert_rewrites(@subject, "List.last(Enum.reverse(list))", "List.first(list)")
    end

    test "pipe form" do
      assert_rewrites(@subject, "list |> Enum.reverse() |> List.last()", "List.first(list)")
    end
  end

  describe "leaves alone" do
    test "List.last on a non-reversed list" do
      assert_unchanged(@subject, "List.last(list)")
    end

    test "Enum.reverse used standalone" do
      assert_unchanged(@subject, "Enum.reverse(list)")
    end

    test "already List.first" do
      assert_unchanged(@subject, "List.first(list)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "List.last(Enum.reverse(list))")
    end
  end
end
