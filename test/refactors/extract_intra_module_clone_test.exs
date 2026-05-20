defmodule Num42.Refactors.Refactors.ExtractIntraModuleCloneTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.ExtractIntraModuleClone

  @subject ExtractIntraModuleClone

  describe "rewrites" do
    test "second clone delegates to the first within the same module" do
      source = """
      defmodule MyApp.Items do
        def first_op(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end

        def second_op(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      expected = """
      defmodule MyApp.Items do
        def first_op(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end

        def second_op(x, y), do: first_op(x, y)
      end
      """

      assert_rewrites(@subject, source, expected, min_mass: 5)
    end

    test "three clones: second and third both delegate to the first" do
      source = """
      defmodule MyApp.Items do
        def alpha(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end

        def beta(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end

        def gamma(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      expected = """
      defmodule MyApp.Items do
        def alpha(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end

        def beta(x, y), do: alpha(x, y)
        def gamma(x, y), do: alpha(x, y)
      end
      """

      assert_rewrites(@subject, source, expected, min_mass: 5)
    end

    test "two independent clone groups in the same module" do
      source = """
      defmodule MyApp.Items do
        def add_one(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end

        def add_two(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end

        def fmt_a(x) do
          x
          |> Integer.to_string()
          |> String.pad_leading(4, "0")
        end

        def fmt_b(x) do
          x
          |> Integer.to_string()
          |> String.pad_leading(4, "0")
        end
      end
      """

      expected = """
      defmodule MyApp.Items do
        def add_one(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end

        def add_two(x, y), do: add_one(x, y)

        def fmt_a(x) do
          x
          |> Integer.to_string()
          |> String.pad_leading(4, "0")
        end

        def fmt_b(x), do: fmt_a(x)
      end
      """

      assert_rewrites(@subject, source, expected, min_mass: 5)
    end

    test "private functions also get collapsed" do
      source = """
      defmodule MyApp.Items do
        defp first_priv(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end

        defp second_priv(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      expected = """
      defmodule MyApp.Items do
        defp first_priv(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end

        defp second_priv(x, y), do: first_priv(x, y)
      end
      """

      assert_rewrites(@subject, source, expected, min_mass: 5)
    end

    test "is idempotent — second pass leaves the source untouched" do
      source = """
      defmodule MyApp.Items do
        def alpha(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end

        def beta(x, y), do: alpha(x, y)
      end
      """

      assert_idempotent(@subject, source, min_mass: 5)
    end
  end

  describe "skips" do
    test "single occurrence is left alone" do
      source = """
      defmodule MyApp.Items do
        def lonely(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 5)
    end

    test "different bodies are left alone" do
      source = """
      defmodule MyApp.Items do
        def add(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end

        def sub(x, y) do
          x
          |> Kernel.-(y)
          |> Kernel.*(2)
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 5)
    end

    test "different arities are left alone (no compatible call)" do
      # `f/1` and `g/2` happen to have a body that hashes the same
      # ignoring the arity wouldn't make sense — the call rewrite
      # `f(x)` ≠ `g(x, y)`. Skip.
      source = """
      defmodule MyApp.Items do
        def one(x) do
          x
          |> Kernel.+(1)
          |> Kernel.*(2)
        end

        def two(x, _y) do
          x
          |> Kernel.+(1)
          |> Kernel.*(2)
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 5)
    end

    test "non-plain-var head on the loser is left alone" do
      # `dup/1` with `%Foo{}` head can't be rewritten to a one-liner
      # `dup(arg_0), do: source(arg_0)` without losing the pattern
      # match — skip the loser, leave the source alone.
      source = """
      defmodule MyApp.Items do
        def source_op(x) do
          x
          |> Kernel.+(1)
          |> Kernel.*(2)
        end

        def loser_op(%{key: x}) do
          x
          |> Kernel.+(1)
          |> Kernel.*(2)
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 5)
    end

    test "guarded loser head is left alone" do
      source = """
      defmodule MyApp.Items do
        def source_op(x) do
          x
          |> Kernel.+(1)
          |> Kernel.*(2)
        end

        def loser_op(x) when is_integer(x) do
          x
          |> Kernel.+(1)
          |> Kernel.*(2)
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 5)
    end

    test "multi-clause loser is left alone (per-function for v1)" do
      # Multi-clause migration is fiddly: do all clauses match? Do
      # we collapse per-clause? Out of scope for v1 — leave it.
      source = """
      defmodule MyApp.Items do
        def source_op(x) do
          x
          |> Kernel.+(1)
          |> Kernel.*(2)
        end

        def loser_op(0), do: 0

        def loser_op(x) do
          x
          |> Kernel.+(1)
          |> Kernel.*(2)
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 5)
    end

    test "clone body with `||` operator — wrapper is plain call, body unchanged" do
      # The wrapper body is `f(x)`, not the original `||` expression,
      # so re-association can't bite. Pin the behaviour: source keeps
      # its original `||` body, loser collapses to a plain delegating
      # call.
      source = """
      defmodule MyApp.Items do
        def source_op(x) do
          (x || 0)
          |> Kernel.+(1)
          |> Kernel.*(2)
        end

        def loser_op(x) do
          (x || 0)
          |> Kernel.+(1)
          |> Kernel.*(2)
        end
      end
      """

      expected = """
      defmodule MyApp.Items do
        def source_op(x) do
          (x || 0)
          |> Kernel.+(1)
          |> Kernel.*(2)
        end

        def loser_op(x), do: source_op(x)
      end
      """

      assert_rewrites(@subject, source, expected, min_mass: 5)
    end

    test "mass below threshold is left alone" do
      # `add/2` has a tiny body — collapsing it adds noise without
      # benefit. Reuse the same min_mass policy as ExtractSharedModule
      # (default 20). We force min_mass: 100 to be sure.
      source = """
      defmodule MyApp.Items do
        def add(x, y), do: x + y
        def sum(x, y), do: x + y
      end
      """

      assert_unchanged(@subject, source, min_mass: 100)
    end
  end
end
