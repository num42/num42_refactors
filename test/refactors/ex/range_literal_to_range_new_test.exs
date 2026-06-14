defmodule Number42.Refactors.Ex.RangeLiteralToRangeNewTest do
  use Number42.RefactorCase, async: true

  @subject Number42.Refactors.Ex.RangeLiteralToRangeNew

  describe "default-off gate" do
    test "does nothing without enabled: true" do
      assert_unchanged(@subject, """
      def f(a, b), do: Enum.to_list(a..b)
      """)
    end

    test "does nothing for the step form without enabled: true" do
      assert_unchanged(@subject, """
      def f(a, b, s), do: Enum.to_list(a..b//s)
      """)
    end
  end

  describe "rewrites (enabled: true)" do
    test "a..b -> Range.new(a, b)" do
      assert_rewrites(
        @subject,
        """
        def f(a, b), do: Enum.to_list(a..b)
        """,
        """
        def f(a, b), do: Enum.to_list(Range.new(a, b))
        """,
        enabled: true
      )
    end

    test "literal range 1..10 -> Range.new(1, 10)" do
      assert_rewrites(
        @subject,
        """
        def f, do: Enum.sum(1..10)
        """,
        """
        def f, do: Enum.sum(Range.new(1, 10))
        """,
        enabled: true
      )
    end

    test "a..b//step -> Range.new(a, b, step)" do
      assert_rewrites(
        @subject,
        """
        def f(a, b, s), do: Enum.to_list(a..b//s)
        """,
        """
        def f(a, b, s), do: Enum.to_list(Range.new(a, b, s))
        """,
        enabled: true
      )
    end

    test "dynamic bounds with step preserve operand spelling" do
      assert_rewrites(
        @subject,
        """
        def f(x, y, z), do: Enum.to_list((x + 1)..(y - 1)//z)
        """,
        """
        def f(x, y, z), do: Enum.to_list(Range.new((x + 1), (y - 1), z))
        """,
        enabled: true
      )
    end
  end

  describe "leaves alone (enabled: true)" do
    test "already Range.new is idempotent" do
      assert_unchanged(
        @subject,
        """
        def f(a, b), do: Enum.to_list(Range.new(a, b))
        """,
        enabled: true
      )
    end

    test "full-slice .. (no operands) is left untouched" do
      assert_unchanged(
        @subject,
        """
        def f(s), do: String.slice(s, ..)
        """,
        enabled: true
      )
    end

    test "range in a when guard is left untouched (illegal as a call)" do
      assert_unchanged(
        @subject,
        """
        def f(x) when x in 1..10, do: x
        """,
        enabled: true
      )
    end

    test "range as a case clause pattern is left untouched" do
      assert_unchanged(
        @subject,
        """
        def f(n) do
          case n do
            1..10 -> :small
            _ -> :big
          end
        end
        """,
        enabled: true
      )
    end

    test "range as a match LHS is left untouched" do
      assert_unchanged(
        @subject,
        """
        def f(r) do
          1..10 = r
          r
        end
        """,
        enabled: true
      )
    end
  end

  describe "idempotence (enabled: true)" do
    test "applying twice equals applying once" do
      assert_idempotent(
        @subject,
        """
        def f(a, b, s) do
          Enum.to_list(a..b)
          Enum.to_list(a..b//s)
        end
        """,
        enabled: true
      )
    end
  end
end
