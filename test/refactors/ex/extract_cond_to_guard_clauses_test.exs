defmodule Number42.Refactors.Ex.ExtractCondToGuardClausesTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractCondToGuardClauses

  @subject ExtractCondToGuardClauses

  describe "guard-expressible cond" do
    test "comparison branches become guard clauses with a true catch-all" do
      before_source = """
      defmodule M do
        def classify(n) do
          cond do
            n < 0 -> :neg
            n == 0 -> :zero
            true -> :pos
          end
        end
      end
      """

      expected = """
      defmodule M do
        def classify(n) when n < 0, do: :neg
        def classify(n) when n == 0, do: :zero
        def classify(_n), do: :pos
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "BIF and boolean-combined guards lift" do
      before_source = """
      defmodule M do
        def kind(x) do
          cond do
            is_atom(x) -> :atom
            is_integer(x) and x > 10 -> :big_int
            true -> :other
          end
        end
      end
      """

      expected = """
      defmodule M do
        def kind(x) when is_atom(x), do: :atom
        def kind(x) when is_integer(x) and x > 10, do: :big_int
        def kind(_x), do: :other
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "multi-line branch bodies lift into do/end clauses" do
      before_source = """
      defmodule M do
        def step(n) do
          cond do
            n > 0 ->
              x = n * 2
              x + 1

            true ->
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

    test "private functions lift too" do
      before_source = """
      defmodule M do
        defp tier(score) do
          cond do
            score >= 90 -> :gold
            score >= 50 -> :silver
            true -> :bronze
          end
        end
      end
      """

      expected = """
      defmodule M do
        defp tier(score) when score >= 90, do: :gold
        defp tier(score) when score >= 50, do: :silver
        defp tier(_score), do: :bronze
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "unused parameters per lifted clause" do
    test "params unused in a clause are underscored" do
      before_source = """
      defmodule M do
        defp clamp(is, min, max) do
          cond do
            is > max -> max
            is < min -> min
            true -> is
          end
        end
      end
      """

      expected = """
      defmodule M do
        defp clamp(is, _min, max) when is > max, do: max
        defp clamp(is, min, _max) when is < min, do: min
        defp clamp(is, _min, _max), do: is
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "body-only usage keeps the param named" do
      before_source = """
      defmodule M do
        def pick(a, b) do
          cond do
            a > 0 -> b
            true -> a
          end
        end
      end
      """

      expected = """
      defmodule M do
        def pick(a, b) when a > 0, do: b
        def pick(a, _b), do: a
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "skips when a param is already underscored (bare_var rejects it)" do
      source = """
      defmodule M do
        def f(n, _opts) do
          cond do
            n > 0 -> :pos
            true -> :neg
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "idempotence" do
    test "applying twice equals applying once" do
      before_source = """
      defmodule M do
        def classify(n) do
          cond do
            n < 0 -> :neg
            n == 0 -> :zero
            true -> :pos
          end
        end
      end
      """

      assert_idempotent(@subject, before_source)
    end

    test "lifted clauses compile" do
      before_source = """
      defmodule CondCompileCheck do
        def classify(n) do
          cond do
            n < 0 -> :neg
            n == 0 -> :zero
            true -> :pos
          end
        end
      end
      """

      before_source |> then(&apply_refactor(@subject, &1)) |> assert_compiles()
    end

    test "already-lifted guard clauses are left alone" do
      source = """
      defmodule M do
        def classify(n) when n < 0, do: :neg
        def classify(n) when n == 0, do: :zero
        def classify(n), do: :pos
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "skips" do
    test "skips when a branch condition is not guard-safe" do
      source = """
      defmodule M do
        def classify(n) do
          cond do
            valid?(n) -> :ok
            n == 0 -> :zero
            true -> :other
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when a condition references a non-parameter value" do
      source = """
      defmodule M do
        def classify(n) do
          threshold = 10

          cond do
            n > threshold -> :big
            true -> :small
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips a cond without a literal true catch-all" do
      source = """
      defmodule M do
        def classify(n) do
          cond do
            n < 0 -> :neg
            n >= 0 -> :nonneg
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when the def head already has a when-guard" do
      source = """
      defmodule M do
        def classify(n) when is_number(n) do
          cond do
            n < 0 -> :neg
            true -> :nonneg
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when a parameter is not a bare variable" do
      source = """
      defmodule M do
        def classify(%{n: n}) do
          cond do
            n < 0 -> :neg
            true -> :nonneg
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when the cond is not the whole body" do
      source = """
      defmodule M do
        def classify(n) do
          log(n)

          cond do
            n < 0 -> :neg
            true -> :nonneg
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when a guard-shaped branch uses a remote call" do
      source = """
      defmodule M do
        def classify(s) do
          cond do
            String.length(s) > 3 -> :long
            true -> :short
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips macros" do
      source = """
      defmodule M do
        defmacro classify(n) do
          cond do
            n < 0 -> :neg
            true -> :nonneg
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end
end
