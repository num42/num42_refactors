defmodule Number42.Refactors.Ex.ExtractCondIfGuardClausesTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractCondIfGuardClauses

  @subject ExtractCondIfGuardClauses

  describe "guard-safe if/else lifts to two clauses" do
    test "keyword-form if/else over a comparison guard" do
      before_source = """
      defmodule M do
        def classify(n) do
          if n < 0, do: :neg, else: :pos
        end
      end
      """

      expected = """
      defmodule M do
        def classify(n) when n < 0, do: :neg

        def classify(_n), do: :pos
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "block-form if/else over a BIF guard" do
      before_source = """
      defmodule M do
        def kind(x) do
          if is_atom(x) do
            :atom
          else
            :other
          end
        end
      end
      """

      expected = """
      defmodule M do
        def kind(x) when is_atom(x), do: :atom

        def kind(_x), do: :other
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "boolean-combined guard lifts; unused param underscored in a branch" do
      before_source = """
      defmodule M do
        def pick(a, b) do
          if is_integer(a) and a > b, do: a, else: 0
        end
      end
      """

      expected = """
      defmodule M do
        def pick(a, b) when is_integer(a) and a > b, do: a

        def pick(_a, _b), do: 0
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "multi-statement branch lifts into a do/end clause" do
      before_source = """
      defmodule M do
        def step(n) do
          if n > 0 do
            x = n * 2
            x + 1
          else
            0
          end
        end
      end
      """

      expected = """
      defmodule M do
        def step(n) when n > 0 do
          x = n * 2
          x + 1
        end

        def step(_n), do: 0
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "defp lifts the same way" do
      before_source = """
      defmodule M do
        defp sign(n) do
          if n >= 0, do: :pos, else: :neg
        end
      end
      """

      expected = """
      defmodule M do
        defp sign(n) when n >= 0, do: :pos

        defp sign(_n), do: :neg
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "truthiness-safe guards (bare/non-boolean conditions)" do
    test "a bare-variable condition is wrapped in `not in [nil, false]`" do
      before_source = """
      defmodule M do
        defp table(name, prefix) do
          if prefix, do: ~s("\#{prefix}".\#{name}), else: name
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ "not in [nil, false]"
      # No bare-variable guard — a guard `when prefix` would require literal
      # `true` and silently take the else-branch for any truthy non-true value.
      refute result =~ "when prefix,"
      refute result =~ "when prefix do"
      assert_compiles(result)
    end

    test "bare-variable truthiness matches `if` at runtime (string takes the then-branch)" do
      before_source = """
      defmodule TruthyM do
        def pick(x) do
          if x, do: :present, else: :absent
        end
      end
      """

      result = apply_refactor(@subject, before_source)
      assert_compiles(result)

      [{mod, _}] = Code.compile_string(result)

      try do
        assert mod.pick("truthy string") == :present
        assert mod.pick(0) == :present
        assert mod.pick(nil) == :absent
        assert mod.pick(false) == :absent
      after
        :code.purge(mod)
        :code.delete(mod)
      end
    end

    test "a non-boolean guard-legal term (elem) is wrapped" do
      before_source = """
      defmodule M do
        def first(t) do
          if elem(t, 0), do: :set, else: :unset
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ "not in [nil, false]"
      assert_compiles(result)
    end
  end

  describe "boolean-proven conditions keep their guard unchanged" do
    test "a comparison is not wrapped in `not in [nil, false]`" do
      before_source = """
      defmodule M do
        def classify(n) do
          if n > 0, do: :pos, else: :nonpos
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ "when n > 0"
      refute result =~ "not in [nil, false]"
    end

    test "a boolean combinator of comparisons is not wrapped" do
      before_source = """
      defmodule M do
        def between(n) do
          if n > 0 and n < 10, do: :inside, else: :outside
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ "when n > 0 and n < 10"
      refute result =~ "not in [nil, false]"
    end

    test "a bare BIF predicate is not wrapped" do
      before_source = """
      defmodule M do
        def kind(x) do
          if is_atom(x), do: :atom, else: :other
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ "when is_atom(x)"
      refute result =~ "not in [nil, false]"
    end
  end

  describe "leaves alone" do
    test "non-guard-safe condition (function call) is skipped" do
      source = """
      defmodule M do
        def go(s) do
          if String.length(s) > 3, do: :long, else: :short
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "condition referencing a non-parameter binding is skipped" do
      source = """
      defmodule M do
        def go(n) do
          limit = 10
          if n < limit, do: :lo, else: :hi
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "if without else is skipped" do
      source = """
      defmodule M do
        def go(n) do
          if n < 0, do: :neg
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "if embedded in a larger body is not liftable" do
      source = """
      defmodule M do
        def go(n) do
          y = n + 1
          if y < 0, do: :neg, else: :pos
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "head with an existing when-guard is skipped" do
      source = """
      defmodule M do
        def go(n) when is_integer(n) do
          if n < 0, do: :neg, else: :pos
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "head with a non-bare parameter is skipped" do
      source = """
      defmodule M do
        def go(%{val: v}) do
          if v < 0, do: :neg, else: :pos
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "a cond body is left to ExtractCondToGuardClauses" do
      source = """
      defmodule M do
        def go(n) do
          cond do
            n < 0 -> :neg
            true -> :pos
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "idempotence" do
    test "lifted clauses are not re-lifted" do
      source = """
      defmodule M do
        def classify(n) do
          if n < 0, do: :neg, else: :pos
        end
      end
      """

      assert_idempotent(@subject, source)
    end
  end

  describe "compiles" do
    test "lifted output is valid Elixir (clauses grouped, no unused vars)" do
      before_source = """
      defmodule CompilesM do
        def classify(n) do
          if n < 0, do: :neg, else: :pos
        end

        def pick(a, b) do
          if is_integer(a) and a > b, do: a, else: 0
        end
      end
      """

      rewritten = apply_refactor(@subject, before_source)

      assert ungrouped_clauses(rewritten) == []
      assert_compiles(rewritten)
    end
  end
end
