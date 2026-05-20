defmodule Number42.Refactors.Ex.FlatMapToFilterTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.FlatMapToFilter

  @subject FlatMapToFilter

  describe "rewrites" do
    test "Enum.flat_map(coll, fn x -> if c, do: [x], else: [] end) -> Enum.filter" do
      assert_rewrites(
        @subject,
        "Enum.flat_map(list, fn x -> if x > 0, do: [x], else: [] end)",
        "Enum.filter(list, fn x -> x > 0 end)"
      )
    end

    test "swapped branches (else first) still becomes filter" do
      assert_rewrites(
        @subject,
        "Enum.flat_map(list, fn x -> if x > 0, do: [], else: [x] end)",
        "Enum.filter(list, fn x -> not (x > 0) end)"
      )
    end
  end

  describe "leaves alone" do
    test "non-filter shape (different return value)" do
      assert_unchanged(@subject, "Enum.flat_map(list, fn x -> [x, x] end)")
    end

    test "lambda with multi-statement body" do
      assert_unchanged(@subject, """
      Enum.flat_map(list, fn x ->
        y = transform(x)
        if y, do: [y], else: []
      end)
      """)
    end

    test "already an Enum.filter" do
      assert_unchanged(@subject, "Enum.filter(list, fn x -> x > 0 end)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(
        @subject,
        "Enum.flat_map(list, fn x -> if x > 0, do: [x], else: [] end)"
      )
    end
  end
end
