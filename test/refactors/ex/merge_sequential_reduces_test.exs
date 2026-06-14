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

    test "three consecutive reduces fuse into one 3-tuple pass" do
      assert_rewrites(
        @subject,
        """
        sum = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
        count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
        product = Enum.reduce(xs, 1, fn x, acc -> acc * x end)
        {sum, count, product}
        """,
        """
        {sum, count, product} =
          Enum.reduce(xs, {0, 0, 1}, fn elem, {acc1, acc2, acc3} ->
            {acc1 + elem, acc2 + 1, acc3 * elem}
          end)

        {sum, count, product}
        """
      )
    end

    test "four consecutive reduces fuse into one 4-tuple pass" do
      assert_rewrites(
        @subject,
        """
        a = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
        b = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
        c = Enum.reduce(xs, 1, fn x, acc -> acc * x end)
        d = Enum.reduce(xs, [], fn x, acc -> [x | acc] end)
        {a, b, c, d}
        """,
        """
        {a, b, c, d} =
          Enum.reduce(xs, {0, 0, 1, []}, fn elem, {acc1, acc2, acc3, acc4} ->
            {acc1 + elem, acc2 + 1, acc3 * elem, [elem | acc4]}
          end)

        {a, b, c, d}
        """
      )
    end

    test "a run of three plus a non-fusable fourth fuses only the run" do
      assert_rewrites(
        @subject,
        """
        a = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
        b = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
        c = Enum.reduce(xs, 1, fn x, acc -> acc * x end)
        d = Enum.reduce(ys, 0, fn y, acc -> acc + y end)
        {a, b, c, d}
        """,
        """
        {a, b, c} =
          Enum.reduce(xs, {0, 0, 1}, fn elem, {acc1, acc2, acc3} ->
            {acc1 + elem, acc2 + 1, acc3 * elem}
          end)

        d = Enum.reduce(ys, 0, fn y, acc -> acc + y end)
        {a, b, c, d}
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

    test "two reduces where the second's init reads the first's result (data-flow dep)" do
      # `total` is bound by the first reduce and read by the second's init.
      # Fusing them would read `total` before it is bound. SKIP.
      assert_unchanged(@subject, """
      total = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
      scaled = Enum.reduce(xs, total, fn x, acc -> acc + x end)
      {total, scaled}
      """)
    end

    test "two reduces where the second's body reads the first's result (data-flow dep)" do
      assert_unchanged(@subject, """
      total = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
      offset = Enum.reduce(xs, 0, fn x, acc -> acc + x + total end)
      {total, offset}
      """)
    end
  end

  describe "rewrites — partial runs" do
    test "independent prefix fuses; a reduce reading an earlier result starts fresh" do
      assert_rewrites(
        @subject,
        """
        sum = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
        count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
        scaled = Enum.reduce(xs, sum, fn x, acc -> acc + x end)
        {sum, count, scaled}
        """,
        """
        {sum, count} =
          Enum.reduce(xs, {0, 0}, fn elem, {acc1, acc2} -> {acc1 + elem, acc2 + 1} end)

        scaled = Enum.reduce(xs, sum, fn x, acc -> acc + x end)
        {sum, count, scaled}
        """
      )
    end
  end

  describe "idempotent" do
    test "running twice equals running once (pair)" do
      assert_idempotent(@subject, """
      sum = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
      count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
      {sum, count}
      """)
    end

    test "running twice equals running once (3-way)" do
      assert_idempotent(@subject, """
      sum = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
      count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
      product = Enum.reduce(xs, 1, fn x, acc -> acc * x end)
      {sum, count, product}
      """)
    end
  end

  describe "compiles" do
    test "fused 3-way output is valid Elixir" do
      fused =
        MergeSequentialReduces.transform(
          """
          defmodule M do
            def run(xs) do
              sum = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
              count = Enum.reduce(xs, 0, fn _x, acc -> acc + 1 end)
              product = Enum.reduce(xs, 1, fn x, acc -> acc * x end)
              {sum, count, product}
            end
          end
          """,
          []
        )

      assert_compiles(fused)
    end
  end
end
