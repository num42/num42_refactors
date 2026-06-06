defmodule Number42.Refactors.Ex.PipelineFromRebindChainTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.PipelineFromRebindChain

  @subject PipelineFromRebindChain

  describe "collapses rebind chains" do
    test "collapses a three-step chain into a single pipe" do
      before_source = """
      defmodule M do
        def f(input, opt) do
          x = transform_a(input)
          x = transform_b(x, opt)
          x = transform_c(x)
        end
      end
      """

      expected = """
      defmodule M do
        def f(input, opt) do
          input |> transform_a() |> transform_b(opt) |> transform_c()
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "collapses a two-step chain" do
      before_source = """
      defmodule M do
        def f(input) do
          x = transform_a(input)
          x = transform_b(x)
        end
      end
      """

      expected = """
      defmodule M do
        def f(input) do
          input |> transform_a() |> transform_b()
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "collapses a chain that seeds from a call expression" do
      before_source = """
      defmodule M do
        def f(input) do
          x = transform_a(fetch(input))
          x = transform_b(x)
          x = transform_c(x)
        end
      end
      """

      expected = """
      defmodule M do
        def f(input) do
          fetch(input) |> transform_a() |> transform_b() |> transform_c()
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "preserves extra arguments on consuming steps" do
      before_source = """
      defmodule M do
        def f(input, a, b) do
          x = step_one(input, a)
          x = step_two(x, b)
        end
      end
      """

      expected = """
      defmodule M do
        def f(input, a, b) do
          input |> step_one(a) |> step_two(b)
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "collapses a module-qualified chain" do
      before_source = """
      defmodule M do
        def f(list, fun, pred) do
          x = Enum.map(list, fun)
          x = Enum.filter(x, pred)
        end
      end
      """

      expected = """
      defmodule M do
        def f(list, fun, pred) do
          list |> Enum.map(fun) |> Enum.filter(pred)
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
        def f(input, opt) do
          x = transform_a(input)
          x = transform_b(x, opt)
          x = transform_c(x)
        end
      end
      """

      assert_idempotent(@subject, before_source)
    end

    test "an already-collapsed pipe is left alone" do
      source = """
      defmodule M do
        def f(input, opt) do
          input |> transform_a() |> transform_b(opt) |> transform_c()
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "the rewritten chain compiles" do
      before_source = """
      defmodule PipelineRebindCompileCheck do
        def f(input) do
          x = abs(input)
          x = to_string(x)
        end
      end
      """

      before_source |> then(&apply_refactor(@subject, &1)) |> assert_compiles()
    end
  end

  describe "skips" do
    test "skips when the previous x appears more than once in the RHS" do
      source = """
      defmodule M do
        def f(input) do
          x = transform_a(input)
          x = transform_b(x, g(x))
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when x is not at the first pipe position" do
      source = """
      defmodule M do
        def f(input, other) do
          x = transform_a(input)
          x = transform_b(other, x)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when x is still read after the chain" do
      source = """
      defmodule M do
        def f(input, opt) do
          x = transform_a(input)
          x = transform_b(x, opt)
          finalize(x, x)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when an intermediate rebind dependency exists" do
      source = """
      defmodule M do
        def f(input) do
          x = transform_a(input)
          y = side(input)
          x = transform_b(x, y)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when the head statement already reads x" do
      source = """
      defmodule M do
        def f(x, opt) do
          x = transform_a(x)
          x = transform_b(x, opt)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips a single rebind (no chain)" do
      source = """
      defmodule M do
        def f(input) do
          x = transform_a(input)
          x
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when a step RHS is not a call" do
      source = """
      defmodule M do
        def f(input) do
          x = transform_a(input)
          x = x + 1
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips a non-bare binding LHS" do
      source = """
      defmodule M do
        def f(input) do
          {x, _} = split(input)
          x = transform_b(x)
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "boundary with MergePipeableAssignments" do
    test "does not fire on a chain of distinct variables" do
      source = """
      defmodule M do
        def f(order) do
          a = step_one(order)
          b = step_two(a)
          step_three(b)
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end
end
