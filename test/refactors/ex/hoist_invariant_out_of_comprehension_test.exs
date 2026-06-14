defmodule Number42.Refactors.Ex.HoistInvariantOutOfComprehensionTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.HoistInvariantOutOfComprehension

  @subject HoistInvariantOutOfComprehension

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

      actual = apply_refactor(@subject, before_source)

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

      actual = apply_refactor(@subject, before_source)

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

      assert_rewrites(@subject, before_source, expected)
    end

    test "the converted `do/end` output compiles" do
      before_source = """
      defmodule M do
        def f(rows), do: for(row <- rows, do: format(row, Enum.sum([1, 2, 3])))

        defp format(row, sum), do: {row, sum}
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert_compiles(actual)
    end

    test "converting a `do:`-keyword body is idempotent" do
      source = """
      defmodule M do
        def f(rows), do: for(row <- rows, do: format(row, Enum.sum([1, 2, 3])))
      end
      """

      assert_idempotent(@subject, source)
    end
  end

  describe "rewrites — multiple generators" do
    test "hoists an expr invariant w.r.t. ALL generators out of a multi-gen `for`" do
      before_source = """
      defmodule M do
        def run(rows, cols) do
          for row <- rows, col <- cols do
            format(row, col, Enum.sum([1, 2, 3]))
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert {:ok, _} = Code.string_to_quoted(actual)
      assert String.contains?(actual, "= Enum.sum([1, 2, 3])")
      # Binding sits before the whole `for`, body references the binding.
      assert String.match?(
               actual,
               ~r/=\s*Enum\.sum\(\[1, 2, 3\]\)\s*\n.*\bfor row <- rows, col <- cols/s
             )

      refute String.match?(actual, ~r/format\(row, col, Enum\.sum/)
    end

    test "hoists past a filter binding when invariant w.r.t. every binding" do
      before_source = """
      defmodule M do
        def run(rows, cols) do
          for row <- rows, n = score(row), n > 0, col <- cols do
            format(row, col, n, Enum.sum([1, 2, 3]))
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert {:ok, _} = Code.string_to_quoted(actual)
      assert String.match?(actual, ~r/=\s*Enum\.sum\(\[1, 2, 3\]\)\s*\n.*\bfor row <- rows/s)
    end

    test "hoists when an `into:` option is present" do
      before_source = """
      defmodule M do
        def run(rows, cols) do
          for row <- rows, col <- cols, into: %{} do
            {row, format(col, Enum.sum([1, 2, 3]))}
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert {:ok, _} = Code.string_to_quoted(actual)
      assert String.contains?(actual, "= Enum.sum([1, 2, 3])")
      assert String.contains?(actual, "into: %{}")
    end

    test "the multi-generator output compiles" do
      before_source = """
      defmodule M do
        def run(rows, cols) do
          for row <- rows, col <- cols do
            format(row, col, Enum.sum([1, 2, 3]))
          end
        end

        defp format(row, col, sum), do: {row, col, sum}
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert_compiles(actual)
    end

    test "multi-generator hoist is idempotent" do
      source = """
      defmodule M do
        def run(rows, cols) do
          for row <- rows, col <- cols do
            format(row, col, Enum.sum([1, 2, 3]))
          end
        end
      end
      """

      assert_idempotent(@subject, source)
    end

    test "leaves a flat multi-gen expr that depends on an earlier generator only" do
      # `String.upcase(row)` is invariant w.r.t. the inner `col` loop but a
      # flat `for` has no statement position between its generators to host
      # the binding without restructuring — left in place.
      source = """
      defmodule M do
        def run(rows, cols) do
          for row <- rows, col <- cols do
            format(col, String.upcase(row))
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "rewrites — nested comprehensions" do
    test "lifts a fully-invariant expr all the way out of a nested `for`" do
      before_source = """
      defmodule M do
        def run(rows, cols) do
          for row <- rows do
            for col <- cols do
              format(row, col, Enum.sum([1, 2, 3]))
            end
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert {:ok, _} = Code.string_to_quoted(actual)
      # Lands before the OUTER `for`, not between the two.
      assert String.match?(
               actual,
               ~r/=\s*Enum\.sum\(\[1, 2, 3\]\)\s*\n.*\bfor row <- rows do.*\bfor col <- cols/s
             )
    end

    test "lifts an outer-generator-dependent expr to before the inner `for`" do
      before_source = """
      defmodule M do
        def run(rows, cols) do
          for row <- rows do
            for col <- cols do
              format(col, String.upcase(row))
            end
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert {:ok, _} = Code.string_to_quoted(actual)
      # Binding sits inside the outer body, before the inner `for`.
      assert String.match?(
               actual,
               ~r/for row <- rows do\s*\n\s*upcase\s*=\s*String\.upcase\(row\)\s*\n.*\bfor col <- cols/s
             )
    end

    test "lifts an inner-generator-dependent expr to before the deeper `for` (not past its binder)" do
      before_source = """
      defmodule M do
        def run(a, b, c) do
          for x <- a do
            for y <- b do
              for z <- c do
                f(z, String.upcase(y))
              end
            end
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert {:ok, _} = Code.string_to_quoted(actual)
      # `y` is bound by the middle generator: the binding must sit inside
      # that loop, before `for z`, where `y` is in scope.
      assert String.match?(
               actual,
               ~r/for y <- b do\s*\n\s*upcase\s*=\s*String\.upcase\(y\)\s*\n.*\bfor z <- c/s
             )
    end

    test "the nested-comprehension output compiles" do
      before_source = """
      defmodule M do
        def run(a, b, c) do
          for x <- a do
            for y <- b do
              for z <- c do
                f(x, z, String.upcase(y))
              end
            end
          end
        end

        defp f(x, z, u), do: {x, z, u}
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert_compiles(actual)
    end

    test "nested hoist is idempotent" do
      source = """
      defmodule M do
        def run(a, b, c) do
          for x <- a do
            for y <- b do
              for z <- c do
                f(z, String.upcase(y))
              end
            end
          end
        end
      end
      """

      assert_idempotent(@subject, source)
    end
  end

  describe "skip — nested-scope variables" do
    # The candidate must not be hoisted past the binder of a variable it
    # references — a `fn`/`with`/`case` inside the loop body introduces
    # names visible only to that subtree.
    test "leaves a call on a `fn` parameter inside the loop body" do
      source = """
      defmodule M do
        def run(rows, list) do
          for row <- rows do
            Enum.map(list, fn p -> g(row, String.upcase(p)) end)
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves a call on a `with` binding inside the loop body" do
      source = """
      defmodule M do
        def run(rows) do
          for row <- rows do
            with {:ok, u} <- fetch(row) do
              g(String.upcase(u))
            end
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves a call on a `case` clause binding inside the loop body" do
      source = """
      defmodule M do
        def run(rows) do
          for row <- rows do
            case row do
              {:a, v} -> g(String.upcase(v))
              _ -> :skip
            end
          end
        end
      end
      """

      assert_unchanged(@subject, source)
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

      actual = apply_refactor(@subject, before_source)

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

      assert_unchanged(@subject, source)
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

      assert_unchanged(@subject, source)
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

      assert_unchanged(@subject, source)
    end

    test "leaves an Enum.map lambda subexpr that depends on the lambda param" do
      source = """
      defmodule M do
        def run(rows) do
          Enum.map(rows, fn row -> format(row, String.length(row.name)) end)
        end
      end
      """

      assert_unchanged(@subject, source)
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

      assert_unchanged(@subject, source)
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

      assert_unchanged(@subject, source)
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

      assert_unchanged(@subject, source)
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

      assert_unchanged(@subject, source)
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

      assert_unchanged(@subject, source)
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

      actual = apply_refactor(@subject, before_source)

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

      assert_idempotent(@subject, source)
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

      assert_unchanged(@subject, source)
    end
  end

  describe "skip — capture-shorthand arguments" do
    # Dogfood (#122): a `&(...)` capture shorthand whose body holds a call
    # on a capture arg (`Atom.to_string(&1)`) must not be hoisted — pulled
    # out of the `&(...)` context the bare `&1` no longer compiles.
    test "leaves a call on a capture arg inside &(...) in place" do
      source = """
      defmodule M do
        @stage_groups [foo: [:a, :b]]

        def grouped_options do
          Enum.map(@stage_groups, fn {group_label, keys} ->
            {group_label, Enum.map(keys, &{label(&1), Atom.to_string(&1)})}
          end)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves a capture-arg call hoisted out of an Enum.map &(...) capture" do
      source = """
      defmodule M do
        def run(rows) do
          Enum.map(rows, &Integer.to_string(&1))
        end
      end
      """

      assert_unchanged(@subject, source)
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

      assert_unchanged(@subject, source)
    end
  end
end
