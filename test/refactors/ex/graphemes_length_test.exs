defmodule Number42.Refactors.Ex.GraphemesLengthTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.GraphemesLength

  @subject GraphemesLength

  # GraphemesLength matches the bare-call forms and the FULL pipe chain
  # `s |> String.graphemes() |> length()`. A half-pipe like
  # `String.graphemes(s) |> length()` is left alone — that's a
  # nested-call shape and the refactor only patches when both sides of
  # the chain are pipes.
  describe "rewrites" do
    test "length(String.graphemes(s)) -> String.length(s)" do
      assert_rewrites(@subject, "length(String.graphemes(s))", "String.length(s)")
    end

    test "Enum.count(String.graphemes(s)) -> String.length(s)" do
      assert_rewrites(@subject, "Enum.count(String.graphemes(s))", "String.length(s)")
    end

    test "full pipe chain with length" do
      assert_rewrites(@subject, "s |> String.graphemes() |> length()", "s |> String.length()")
    end

    test "full pipe chain with Enum.count" do
      assert_rewrites(@subject, "s |> String.graphemes() |> Enum.count()", "s |> String.length()")
    end
  end

  describe "leaves alone" do
    test "length on a non-graphemes list" do
      assert_unchanged(@subject, "length(my_list)")
    end

    test "String.graphemes used as a list (not measured)" do
      assert_unchanged(@subject, "Enum.map(String.graphemes(s), & &1)")
    end

    test "already String.length" do
      assert_unchanged(@subject, "String.length(s)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "length(String.graphemes(s))")
    end
  end
end
