defmodule Number42.Refactors.Ex.RangeToListRedundantTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.RangeToListRedundant

  @subject RangeToListRedundant

  describe "rewrites" do
    test "to_list(range) piped into Enum.map drops the to_list" do
      assert_rewrites(
        @subject,
        "Enum.to_list(1..n) |> Enum.map(fun)",
        "1..n |> Enum.map(fun)"
      )
    end

    test "nested Enum.map(to_list(range), fun) keeps the call shape" do
      assert_rewrites(
        @subject,
        "Enum.map(Enum.to_list(a..b), fun)",
        "Enum.map(a..b, fun)"
      )
    end

    test "range piped through to_list into Enum.each collapses the inner pipe" do
      assert_rewrites(
        @subject,
        "1..n |> Enum.to_list() |> Enum.each(f)",
        "1..n |> Enum.each(f)"
      )
    end

    test "stepped range a..b//step" do
      assert_rewrites(
        @subject,
        "Enum.to_list(a..b//step) |> Enum.map(fun)",
        "a..b//step |> Enum.map(fun)"
      )
    end

    test "Range.new(...) is a provable range" do
      assert_rewrites(
        @subject,
        "Enum.to_list(Range.new(1, n)) |> Enum.map(fun)",
        "Range.new(1, n) |> Enum.map(fun)"
      )
    end

    test "downstream Stream.* call also fires" do
      assert_rewrites(
        @subject,
        "Enum.to_list(1..n) |> Stream.map(fun)",
        "1..n |> Stream.map(fun)"
      )
    end

    test "nested Stream call form" do
      assert_rewrites(
        @subject,
        "Stream.map(Enum.to_list(1..10), fun)",
        "Stream.map(1..10, fun)"
      )
    end
  end

  describe "leaves alone" do
    test "to_list of a variable (could be anything)" do
      assert_unchanged(@subject, "Enum.to_list(some_var) |> Enum.map(fun)")
    end

    test "to_list of a list literal" do
      assert_unchanged(@subject, "Enum.to_list([1, 2, 3]) |> Enum.map(fun)")
    end

    test "to_list of a range without a downstream Enum/Stream call" do
      assert_unchanged(@subject, "Enum.to_list(1..n)")
    end

    test "to_list of a range bound to a variable" do
      assert_unchanged(@subject, "x = Enum.to_list(1..n)")
    end

    test "to_list result piped into a non-Enum function" do
      assert_unchanged(@subject, "Enum.to_list(1..n) |> IO.inspect()")
    end

    test "to_list result passed to an unknown function as nested arg" do
      assert_unchanged(@subject, "process(Enum.to_list(1..n))")
    end

    test "already a bare range into Enum.map" do
      assert_unchanged(@subject, "Enum.map(1..n, fun)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once (pipe form)" do
      assert_idempotent(@subject, "Enum.to_list(1..n) |> Enum.map(fun)")
    end

    test "running twice equals running once (nested form)" do
      assert_idempotent(@subject, "Enum.map(Enum.to_list(a..b), fun)")
    end
  end
end
