defmodule Number42.Refactors.Ex.MergeClausesIntoCondOrGuardTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.MergeClausesIntoCondOrGuard

  @subject MergeClausesIntoCondOrGuard

  describe "merges guard-only clauses into a cond" do
    test "canonical merge with guard-less catch-all → true ->" do
      before_source = """
      defmodule M do
        def label(n) when n < 0, do: "neg"
        def label(n) when n == 0, do: "zero"
        def label(n), do: "rest"
      end
      """

      expected = """
      defmodule M do
        def label(n) do
          cond do
            n < 0 -> "neg"
            n == 0 -> "zero"
            true -> "rest"
          end
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "block-body clauses merge" do
      before_source = """
      defmodule M do
        def label(n) when n < 0 do
          "neg"
        end

        def label(n) when n == 0 do
          "zero"
        end

        def label(n) do
          "pos"
        end
      end
      """

      expected = """
      defmodule M do
        def label(n) do
          cond do
            n < 0 -> "neg"
            n == 0 -> "zero"
            true -> "pos"
          end
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "`when true` catch-all maps to true ->" do
      before_source = """
      defmodule M do
        def label(n) when n < 0, do: "neg"
        def label(n) when true, do: "rest"
      end
      """

      expected = """
      defmodule M do
        def label(n) do
          cond do
            n < 0 -> "neg"
            true -> "rest"
          end
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "multiple bare-var params" do
      before_source = """
      defmodule M do
        def cmp(a, b) when a < b, do: :lt
        def cmp(a, b) when a > b, do: :gt
        def cmp(a, b), do: :eq
      end
      """

      expected = """
      defmodule M do
        def cmp(a, b) do
          cond do
            a < b -> :lt
            a > b -> :gt
            true -> :eq
          end
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "defp merges too" do
      before_source = """
      defmodule M do
        defp label(n) when n < 0, do: "neg"
        defp label(n), do: "rest"
      end
      """

      expected = """
      defmodule M do
        defp label(n) do
          cond do
            n < 0 -> "neg"
            true -> "rest"
          end
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "sibling functions of other names are untouched" do
      before_source = """
      defmodule M do
        def other(x), do: x

        def label(n) when n < 0, do: "neg"
        def label(n), do: "rest"

        def last(y), do: y
      end
      """

      expected = """
      defmodule M do
        def other(x), do: x

        def label(n) do
          cond do
            n < 0 -> "neg"
            true -> "rest"
          end
        end

        def last(y), do: y
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "output is valid Elixir" do
    test "merged cond compiles" do
      before_source = """
      defmodule CompileCheckMergeClauses do
        def classify(n) when n < 0, do: {:neg, abs(n)}
        def classify(n) when n == 0, do: :zero
        def classify(n), do: {:pos, n}
      end
      """

      out = apply_refactor(@subject, before_source)

      assert_compiles(out)
    end
  end

  describe "idempotent" do
    test "canonical merge is stable on a second pass" do
      source = """
      defmodule M do
        def label(n) when n < 0, do: "neg"
        def label(n) when n == 0, do: "zero"
        def label(n), do: "rest"
      end
      """

      assert_idempotent(@subject, source)
    end

    test "already-merged cond passes through unchanged" do
      source = """
      defmodule M do
        def label(n) do
          cond do
            n < 0 -> "neg"
            n == 0 -> "zero"
            true -> "rest"
          end
        end
      end
      """

      assert_idempotent(@subject, source)
      assert_unchanged(@subject, source)
    end
  end

  describe "leaves alone (skip cases)" do
    test "no total fallback → would-be CondClauseError, skip" do
      source = """
      defmodule M do
        def label(n) when n < 0, do: "neg"
        def label(n) when n > 0, do: "pos"
      end
      """

      assert_unchanged(@subject, source)
    end

    test "pattern-binding clause (destructuring) → skip" do
      source = """
      defmodule M do
        def f({:ok, v}) when v > 0, do: :a
        def f(_), do: :b
      end
      """

      assert_unchanged(@subject, source)
    end

    test "literal param (not a bare var) → skip" do
      source = """
      defmodule M do
        def f(0) when is_integer(0), do: :zero
        def f(n), do: :other
      end
      """

      assert_unchanged(@subject, source)
    end

    test "interleaved sibling definition breaks contiguity → skip" do
      source = """
      defmodule M do
        def f(n) when n < 0, do: :a
        def g(x), do: x
        def f(n), do: :b
      end
      """

      assert_unchanged(@subject, source)
    end

    test "single clause only → nothing to merge" do
      source = """
      defmodule M do
        def f(n) when n < 0, do: :neg
      end
      """

      assert_unchanged(@subject, source)
    end

    test "differing param names across clauses → skip" do
      source = """
      defmodule M do
        def f(a) when a < 0, do: :neg
        def f(b), do: :rest
      end
      """

      assert_unchanged(@subject, source)
    end

    test "catch-all is not the last clause → skip (no reorder)" do
      source = """
      defmodule M do
        def f(n), do: :rest
        def f(n) when n < 0, do: :neg
      end
      """

      assert_unchanged(@subject, source)
    end

    test "defmacro is out of scope" do
      source = """
      defmodule M do
        defmacro f(n) when n < 0, do: :neg
        defmacro f(n), do: :rest
      end
      """

      assert_unchanged(@subject, source)
    end

    test "different arities are not the same group" do
      source = """
      defmodule M do
        def f(n) when n < 0, do: :neg
        def f(a, b), do: {a, b}
      end
      """

      assert_unchanged(@subject, source)
    end
  end
end
