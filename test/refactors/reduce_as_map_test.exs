defmodule Num42.Refactors.Refactors.ReduceAsMapTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.ReduceAsMap

  @subject ReduceAsMap

  # ReduceAsMap targets the O(n²) `acc ++ [x]` accumulation pattern.
  # The cons form `[x | acc]` is intentionally left alone — that's the
  # idiomatic O(n) accumulator (combined with a final `Enum.reverse`),
  # and rewriting it to `Enum.map` would also drop the implicit reverse.
  describe "rewrites" do
    test "Enum.reduce with `acc ++ [x]` -> Enum.map" do
      assert_rewrites(
        @subject,
        "Enum.reduce(list, [], fn x, acc -> acc ++ [x] end)",
        "Enum.map(list, fn x -> x end)"
      )
    end
  end

  describe "leaves alone" do
    test "cons form `[x | acc]` (idiomatic O(n) accumulator)" do
      assert_unchanged(@subject, "Enum.reduce(list, [], fn x, acc -> [x | acc] end)")
    end

    test "non-empty list seed" do
      assert_unchanged(@subject, "Enum.reduce(list, [seed], fn x, acc -> acc ++ [x] end)")
    end

    test "already Enum.map" do
      assert_unchanged(@subject, "Enum.map(list, fn x -> transform(x) end)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "Enum.reduce(list, [], fn x, acc -> acc ++ [x] end)")
    end
  end
end
