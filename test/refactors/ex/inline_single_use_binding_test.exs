defmodule Number42.Refactors.Ex.InlineSingleUseBindingTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.InlineSingleUseBinding

  @subject InlineSingleUseBinding

  describe "rewrites — canonical inline" do
    test "inlines a use-once, read-never-after binding into its single use" do
      before_source = """
      defmodule M do
        def f(x) do
          result = Map.get(x, :a)
          use_it(result)
        end
      end
      """

      after_source = """
      defmodule M do
        def f(x) do
          use_it(Map.get(x, :a))
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "wraps the inlined RHS in parens to preserve precedence" do
      before_source = """
      defmodule M do
        def f(a, b) do
          sum = a + b
          sum * 2
        end
      end
      """

      after_source = """
      defmodule M do
        def f(a, b) do
          (a + b) * 2
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "inlines from the middle of a block, leaving surrounding statements" do
      before_source = """
      defmodule M do
        def f(x) do
          a = first(x)
          b = String.upcase(x)
          combine(a, b)
        end
      end
      """

      # `b` is the use-once/read-never-after binding adjacent to its use.
      after_source = """
      defmodule M do
        def f(x) do
          a = first(x)
          combine(a, String.upcase(x))
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "skips unsafe inlines" do
    test "skips when the binding is read more than once" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(x) do
          r = Map.get(x, :a)
          r + r
        end
      end
      """)
    end

    test "skips when the binding is read by a later statement" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(x) do
          r = Map.get(x, :a)
          first(r)
          second(r)
        end
      end
      """)
    end

    test "skips when the RHS is impure (could raise)" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(s) do
          n = String.to_integer(s)
          use_it(n)
        end
      end
      """)
    end

    test "skips when the RHS performs a side effect" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(x) do
          r = IO.inspect(x)
          use_it(r)
        end
      end
      """)
    end

    test "skips a pattern-match LHS (not a simple binding)" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(x) do
          {:ok, r} = fetch(x)
          use_it(r)
        end
      end
      """)
    end

    test "skips when the use is not adjacent to the binding" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(x) do
          r = Map.get(x, :a)
          unrelated()
          use_it(r)
        end
      end
      """)
    end

    test "skips when the binding is never read at all (dead binding)" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(x) do
          r = Map.get(x, :a)
          other(x)
        end
      end
      """)
    end

    test "skips a single-expression body (nothing to inline into)" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(x), do: Map.get(x, :a)
      end
      """)
    end
  end

  describe "idempotence & compilation" do
    test "stable after one inline" do
      assert_idempotent(@subject, """
      defmodule M do
        def f(x) do
          r = Map.get(x, :a)
          use_it(r)
        end
      end
      """)
    end

    test "output compiles" do
      source = """
      defmodule InlineSingleUseBindingCompileCheck do
        def f(a, b) do
          sum = a + b
          sum * 2
        end
      end
      """

      assert_compiles(apply_refactor(@subject, source))
    end
  end
end
