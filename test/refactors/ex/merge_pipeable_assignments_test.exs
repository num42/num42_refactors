defmodule Number42.Refactors.Ex.MergePipeableAssignmentsTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.MergePipeableAssignments

  @subject MergePipeableAssignments

  describe "linear assignment chains" do
    test "collapses a three-step chain into a pipe" do
      before_source = """
      defmodule M do
        def f(order) do
          a = step_one(order)
          b = step_two(a)
          step_three(b)
        end
      end
      """

      expected = """
      defmodule M do
        def f(order) do
          order
          |> step_one()
          |> step_two()
          |> step_three()
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "threads the var as first arg, keeping extra args" do
      before_source = """
      defmodule M do
        def f(list) do
          mapped = Enum.map(list, &double/1)
          Enum.filter(mapped, &positive?/1)
        end
      end
      """

      expected = """
      defmodule M do
        def f(list) do
          list
          |> Enum.map(&double/1)
          |> Enum.filter(&positive?/1)
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "starts the pipe from a non-var seed expression" do
      before_source = """
      defmodule M do
        def f(order) do
          a = transform(fetch(order))
          finalize(a)
        end
      end
      """

      expected = """
      defmodule M do
        def f(order) do
          fetch(order)
          |> transform()
          |> finalize()
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "rewrites a chain that already ends in a binding-free tail call" do
      before_source = """
      defmodule M do
        def f(x) do
          a = g(x)
          b = h(a)
          c = i(b)
          j(c)
        end
      end
      """

      expected = """
      defmodule M do
        def f(x) do
          x
          |> g()
          |> h()
          |> i()
          |> j()
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "idempotence" do
    test "applying twice equals applying once" do
      before_source = """
      defmodule M do
        def f(order) do
          a = step_one(order)
          b = step_two(a)
          step_three(b)
        end
      end
      """

      assert_idempotent(@subject, before_source)
    end

    test "rewritten chain compiles" do
      before_source = """
      defmodule MergeCompileCheck do
        def f(list) do
          mapped = Enum.map(list, &(&1 * 2))
          Enum.sum(mapped)
        end
      end
      """

      before_source |> then(&apply_refactor(@subject, &1)) |> assert_compiles()
    end

    test "an existing pipe chain is left alone" do
      source = """
      defmodule M do
        def f(order) do
          order
          |> step_one()
          |> step_two()
          |> step_three()
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "skips" do
    test "skips when an intermediate var is read after the chain" do
      source = """
      defmodule M do
        def f(order) do
          a = step_one(order)
          b = step_two(a)
          {a, b}
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when an intermediate var is used twice in one step" do
      source = """
      defmodule M do
        def f(order) do
          a = step_one(order)
          combine(a, a)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when the next step does not use the var as a leading first arg" do
      source = """
      defmodule M do
        def f(order) do
          a = step_one(order)
          wrap(other(), a)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips a single assignment with no consuming tail" do
      source = """
      defmodule M do
        def f(order) do
          a = step_one(order)
          a
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when an intermediate value is not consumed by a call" do
      source = """
      defmodule M do
        def f(order) do
          a = step_one(order)
          a + 1
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips bodies containing control flow" do
      source = """
      defmodule M do
        def f(order) do
          a = step_one(order)
          if a, do: step_two(a), else: nil
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when the LHS is not a bare variable" do
      source = """
      defmodule M do
        def f(order) do
          {a, b} = split(order)
          combine(a, b)
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end
end
