defmodule Number42.Refactors.Ex.HoistInvariantOutOfComprehensionTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.HoistInvariantOutOfComprehension

  @subject HoistInvariantOutOfComprehension

  # HoistInvariantOutOfComprehension is opt-in / default-off. Every test
  # that exercises the rewrite passes `enabled: true`; a dedicated test
  # asserts the default-off behaviour.
  @on [enabled: true]

  describe "default-off" do
    test "without opt-in config the source is left untouched" do
      source = """
      defmodule M do
        def run(rows) do
          for row <- rows do
            format(row, Enum.sum([1, 2, 3]))
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "rewrites — for" do
    test "hoists a loop-invariant pure call out of a `for` body" do
      before_source = """
      defmodule M do
        def run(rows) do
          for row <- rows do
            format(row, Enum.sum([1, 2, 3]))
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source, @on)

      assert {:ok, _} = Code.string_to_quoted(actual)
      assert String.contains?(actual, "= Enum.sum([1, 2, 3])")
      # The binding sits before the `for`, not inside it.
      assert String.match?(actual, ~r/=\s*Enum\.sum\(\[1, 2, 3\]\)\s*\n.*\bfor row <- rows/s)
      # The body references the binding, not the original call.
      refute String.match?(actual, ~r/format\(row, Enum\.sum/)
    end

    test "hoists out of a single-line `for ... do: ...` comprehension" do
      before_source = """
      defmodule M do
        def run(rows) do
          for row <- rows, do: format(row, String.length("hello"))
        end
      end
      """

      actual = apply_refactor(@subject, before_source, @on)

      assert {:ok, _} = Code.string_to_quoted(actual)
      assert String.contains?(actual, ~s|= String.length("hello")|)
    end

    test "converts a `do:`-keyword function body to `do/end` when hoisting" do
      before_source = """
      defmodule M do
        def f(rows), do: for(row <- rows, do: format(row, Enum.sum([1, 2, 3])))
      end
      """

      expected = """
      defmodule M do
        def f(rows) do
          sum = Enum.sum([1, 2, 3])
          for(row <- rows, do: format(row, sum))
        end
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
    end

    test "the converted `do/end` output compiles" do
      before_source = """
      defmodule M do
        def f(rows), do: for(row <- rows, do: format(row, Enum.sum([1, 2, 3])))

        defp format(row, sum), do: {row, sum}
      end
      """

      actual = apply_refactor(@subject, before_source, @on)

      assert_compiles(actual)
    end

    test "converting a `do:`-keyword body is idempotent" do
      source = """
      defmodule M do
        def f(rows), do: for(row <- rows, do: format(row, Enum.sum([1, 2, 3])))
      end
      """

      assert_idempotent(@subject, source, @on)
    end
  end

  describe "rewrites — Enum.map" do
    test "hoists a loop-invariant pure call out of an `Enum.map` lambda" do
      before_source = """
      defmodule M do
        def run(rows) do
          Enum.map(rows, fn row -> format(row, String.length("x")) end)
        end
      end
      """

      actual = apply_refactor(@subject, before_source, @on)

      assert {:ok, _} = Code.string_to_quoted(actual)
      assert String.contains?(actual, ~s|= String.length("x")|)
      assert String.match?(actual, ~r/=\s*String\.length\("x"\)\s*\n.*Enum\.map\(rows/s)
    end
  end

  describe "skip — depends on loop-bound variable" do
    test "leaves a subexpr that depends on the generator var" do
      source = """
      defmodule M do
        def run(rows) do
          for row <- rows do
            format(row, String.length(row.name))
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "leaves a subexpr that depends on a filter binding" do
      source = """
      defmodule M do
        def run(rows) do
          for row <- rows, n = compute(row), n > 0 do
            format(row, String.length(n))
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "leaves a subexpr that depends on a second generator var" do
      source = """
      defmodule M do
        def run(rows, cols) do
          for row <- rows, col <- cols do
            format(row, String.length(col))
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "leaves an Enum.map lambda subexpr that depends on the lambda param" do
      source = """
      defmodule M do
        def run(rows) do
          Enum.map(rows, fn row -> format(row, String.length(row.name)) end)
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end
  end

  describe "skip — not pure or total" do
    test "leaves an impure/raising subexpr (String.to_integer)" do
      source = """
      defmodule M do
        def run(rows, s) do
          for row <- rows do
            format(row, String.to_integer(s))
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "leaves a bang/raising subexpr (Map.fetch!)" do
      source = """
      defmodule M do
        def run(rows, m) do
          for row <- rows do
            format(row, Map.fetch!(m, :key))
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "leaves an unknown remote call (opaque purity)" do
      source = """
      defmodule M do
        def run(rows) do
          for row <- rows do
            format(row, Repo.all(Query))
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end
  end

  describe "skip — nothing worth hoisting" do
    test "leaves a body that only references the loop var and literals" do
      source = """
      defmodule M do
        def run(rows) do
          for row <- rows do
            format(row, 42)
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "leaves a bare-variable argument alone (already hoisted)" do
      source = """
      defmodule M do
        def run(rows, today) do
          for row <- rows do
            format(row, today)
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end
  end

  describe "naming" do
    test "the hoisted binding does not shadow an existing variable" do
      before_source = """
      defmodule M do
        def run(rows) do
          sum = :sentinel
          for row <- rows do
            format(row, sum, Enum.sum([1, 2, 3]))
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source, @on)

      assert {:ok, _} = Code.string_to_quoted(actual)
      # Existing `sum = :sentinel` is preserved.
      assert String.contains?(actual, "sum = :sentinel")
      # The new binding gets a non-colliding name.
      assert String.match?(actual, ~r/sum_\d+\s*=\s*Enum\.sum\(\[1, 2, 3\]\)/)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      source = """
      defmodule M do
        def run(rows) do
          for row <- rows do
            format(row, Enum.sum([1, 2, 3]))
          end
        end
      end
      """

      assert_idempotent(@subject, source, @on)
    end

    test "already-hoisted code is left unchanged" do
      source = """
      defmodule M do
        def run(rows) do
          total = Enum.sum([1, 2, 3])

          for row <- rows do
            format(row, total)
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end
  end

  describe "skip — clock/non-deterministic reads are not pure" do
    # The issue's illustrative example uses `Date.utc_today()`, but a
    # clock read is non-deterministic (different value across midnight)
    # and so is *not* pure under `AstHelpers.pure?/1`. Hoisting it would
    # also change call count from n (or 0) to exactly 1. Conservative
    # skip — safety over the literal issue example.
    test "leaves Date.utc_today() in place" do
      source = """
      defmodule M do
        def run(rows) do
          for row <- rows do
            format(row, Date.utc_today())
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end
  end
end
