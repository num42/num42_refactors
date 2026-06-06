defmodule Number42.Refactors.Ex.MergeSequentialReducesTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.MergeSequentialReduces

  @subject MergeSequentialReduces

  describe "rewrites" do
    test "two reduces over the same pure collection -> one tuple-accumulator pass" do
      assert_rewrites(
        @subject,
        """
        sum = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
        count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
        {sum, count}
        """,
        """
        {sum, count} =
          Enum.reduce(xs, {0, 0}, fn elem, {acc1, acc2} -> {acc1 + elem, acc2 + 1} end)

        {sum, count}
        """
      )
    end

    test "both reducers reuse the same param names (`acc`)" do
      assert_rewrites(
        @subject,
        """
        total = Enum.reduce(nums, 0, fn n, acc -> acc + n end)
        product = Enum.reduce(nums, 1, fn n, acc -> acc * n end)
        {total, product}
        """,
        """
        {total, product} =
          Enum.reduce(nums, {0, 1}, fn elem, {acc1, acc2} -> {acc1 + elem, acc2 * elem} end)

        {total, product}
        """
      )
    end

    test "three consecutive reduces fuse the first disjoint pair, leave the third" do
      assert_rewrites(
        @subject,
        """
        a = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
        b = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
        c = Enum.reduce(xs, 1, fn x, acc -> acc * x end)
        {a, b, c}
        """,
        """
        {a, b} = Enum.reduce(xs, {0, 0}, fn elem, {acc1, acc2} -> {acc1 + elem, acc2 + 1} end)
        c = Enum.reduce(xs, 1, fn x, acc -> acc * x end)
        {a, b, c}
        """
      )
    end

    test "fresh accumulator name dodges a free variable named acc1 in the body" do
      assert_rewrites(
        @subject,
        """
        sum = Enum.reduce(xs, 0, fn x, acc -> acc + x + acc1 end)
        count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
        {sum, count}
        """,
        """
        {sum, count} =
          Enum.reduce(xs, {0, 0}, fn elem, {acc11, acc2} -> {acc11 + elem + acc1, acc2 + 1} end)

        {sum, count}
        """
      )
    end
  end

  describe "leaves alone (skip conditions)" do
    test "lazy Stream source (2x traversal vs 1x changes semantics)" do
      assert_unchanged(@subject, """
      sum = Enum.reduce(Stream.map(xs, & &1), 0, fn x, acc -> acc + x end)
      count = Enum.reduce(Stream.map(xs, & &1), 0, fn _x, acc -> acc + 1 end)
      {sum, count}
      """)
    end

    test "different source collections" do
      assert_unchanged(@subject, """
      sum = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
      count = Enum.reduce(ys, 0, fn _y, acc -> acc + 1 end)
      {sum, count}
      """)
    end

    test "source rebound between the two reduces" do
      assert_unchanged(@subject, """
      sum = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
      xs = tl(xs)
      count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
      {sum, count}
      """)
    end

    test "only one result used downstream" do
      assert_unchanged(@subject, """
      sum = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
      count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
      sum
      """)
    end

    test "side-effecting reducer body" do
      assert_unchanged(@subject, """
      sum = Enum.reduce(xs, 0, fn x, acc -> IO.inspect(acc + x) end)
      count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
      {sum, count}
      """)
    end

    test "side-effecting source enumerable (File.stream!)" do
      assert_unchanged(@subject, """
      a = Enum.reduce(File.stream!("f"), 0, fn x, acc -> acc + 1 end)
      b = Enum.reduce(File.stream!("f"), 0, fn x, acc -> acc + 1 end)
      {a, b}
      """)
    end

    test "non-adjacent reduces (statement between)" do
      assert_unchanged(@subject, """
      sum = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
      log(sum)
      count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
      {sum, count}
      """)
    end

    test "reducer body shadows an accumulator name" do
      assert_unchanged(@subject, """
      sum = Enum.reduce(xs, 0, fn x, acc -> acc1 = x; acc + acc1 end)
      count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
      {sum, count}
      """)
    end

    test "destructured element pattern" do
      assert_unchanged(@subject, """
      sum = Enum.reduce(xs, 0, fn {a, _b}, acc -> acc + a end)
      count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
      {sum, count}
      """)
    end

    test "a single reduce alone" do
      assert_unchanged(@subject, """
      sum = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
      sum
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      sum = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
      count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
      {sum, count}
      """)
    end
  end
end
