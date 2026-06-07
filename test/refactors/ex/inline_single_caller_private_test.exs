defmodule Number42.Refactors.Ex.InlineSingleCallerPrivateTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.InlineSingleCallerPrivate

  @subject InlineSingleCallerPrivate

  # InlineSingleCallerPrivate is default-OFF: transform/2 is a no-op
  # unless its own opts carry `enabled: true`. Every behaviour test below
  # passes `@on` as the trailing opts so it exercises the enabled
  # refactor; the default-OFF gate has its own dedicated test.
  @on [enabled: true]

  describe "default-OFF (opt-in only)" do
    test "without enabled: true, transform is a no-op" do
      source = """
      defmodule M do
        defp helper(x), do: x * 2 + offset()
        def f(n), do: helper(n) + 1
      end
      """

      assert apply_refactor(@subject, source) == source
    end
  end

  describe "rewrites — canonical inline" do
    test "single-call-site defp is inlined and deleted" do
      before_source = """
      defmodule M do
        defp helper(x), do: x * 2 + offset()
        def f(n), do: helper(n) + 1
      end
      """

      after_source = """
      defmodule M do
        def f(n), do: (n * 2 + offset()) + 1
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "paren-wrap preserves precedence inside a larger expression" do
      before_source = """
      defmodule M do
        defp double(x), do: x + x
        def f(n), do: 1 + helper_wrap() * double(n)
      end
      """

      # `double(n)` → `(n + n)` so `* (n + n)` binds correctly.
      after_source = """
      defmodule M do
        def f(n), do: 1 + helper_wrap() * (n + n)
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "deletes the helper's preceding @doc and @spec" do
      before_source = """
      defmodule M do
        @doc false
        @spec helper(integer()) :: integer()
        defp helper(x), do: x * 2

        def f(n), do: helper(n) + 1
      end
      """

      after_source = """
      defmodule M do
        def f(n), do: (n * 2) + 1
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "multi-arg helper substitutes each param" do
      before_source = """
      defmodule M do
        defp combine(a, b), do: a + b * 2
        def f(x, y), do: combine(x, y) - 1
      end
      """

      after_source = """
      defmodule M do
        def f(x, y), do: (x + y * 2) - 1
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end
  end

  describe "multiple-evaluation trap" do
    test "param used twice with trivially-safe (literal) arg is inlined" do
      before_source = """
      defmodule M do
        defp twice(x), do: x + x
        def f, do: twice(5)
      end
      """

      after_source = """
      defmodule M do
        def f, do: (5 + 5)
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "param used twice with bare-var arg is inlined" do
      before_source = """
      defmodule M do
        defp twice(x), do: x + x
        def f(n), do: twice(n)
      end
      """

      after_source = """
      defmodule M do
        def f(n), do: (n + n)
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "param used twice with impure call arg is left unchanged" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp twice(x), do: x + x
          def f, do: twice(side_effect())
        end
        """,
        @on
      )
    end
  end

  describe "leaves alone — out of scope kinds" do
    test "public def is never inlined" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def helper(x), do: x * 2
          def f(n), do: helper(n) + 1
        end
        """,
        @on
      )
    end

    test "defmacrop is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defmacrop helper(x), do: quote(do: unquote(x) * 2)
          def f(n), do: helper(n) + 1
        end
        """,
        @on
      )
    end
  end

  describe "leaves alone — non-substitutable defp shapes" do
    test "multi-clause defp is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(0), do: :zero
          defp helper(x), do: x * 2
          def f(n), do: helper(n)
        end
        """,
        @on
      )
    end

    test "when-guarded defp is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x) when x > 0, do: x * 2
          def f(n), do: helper(n) + 1
        end
        """,
        @on
      )
    end

    test "recursive defp is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x), do: helper(x - 1) + x
          def f(n), do: helper(n)
        end
        """,
        @on
      )
    end

    test "pattern param is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(%X{a: a}), do: a * 2
          def f(s), do: helper(s) + 1
        end
        """,
        @on
      )
    end

    test "body with a binding (=) is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x) do
            y = x * 2
            y + 1
          end

          def f(n), do: helper(n)
        end
        """,
        @on
      )
    end
  end

  describe "leaves alone — call-site count" do
    test "two call sites are skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2
          def f(n), do: helper(n) + helper(n + 1)
        end
        """,
        @on
      )
    end

    test "zero call sites are skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2
          def f(n), do: n + 1
        end
        """,
        @on
      )
    end

    test "capture-only use is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2
          def f(xs), do: Enum.map(xs, &helper/1)
        end
        """,
        @on
      )
    end

    test "apply mentioning the name is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2
          def f(n), do: apply(__MODULE__, :helper, [n])
        end
        """,
        @on
      )
    end
  end

  describe "idempotent" do
    test "canonical inline is stable across passes" do
      assert_idempotent(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2 + offset()
          def f(n), do: helper(n) + 1
        end
        """,
        @on
      )
    end

    test "non-matching code is left alone across passes" do
      assert_idempotent(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2
          def f(n), do: helper(n) + helper(n)
        end
        """,
        @on
      )
    end
  end

  describe "output compiles" do
    test "inlined output is valid Elixir" do
      before_source = """
      defmodule InlineCompileSample do
        def f(n), do: helper(n) + 1
        defp helper(x), do: x * 2 + 3
      end
      """

      assert_compiles(apply_refactor(@subject, before_source, @on))
    end
  end
end
