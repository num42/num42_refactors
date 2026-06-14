defmodule Number42.Refactors.Ex.ExtractCondToGuardClausesTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractCondToGuardClauses

  @subject ExtractCondToGuardClauses

  describe "guard-expressible cond with a clause-worthy branch" do
    test "a multi-stage pipe branch lifts the whole cond" do
      before_source = """
      defmodule M do
        def classify(n) do
          cond do
            n < 0 -> n |> abs() |> Integer.to_string()
            n == 0 -> :zero
            true -> :pos
          end
        end
      end
      """

      expected = """
      defmodule M do
        def classify(n) when n < 0, do: n |> abs() |> Integer.to_string()
        def classify(n) when n == 0, do: :zero
        def classify(_n), do: :pos
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "BIF and boolean-combined guards lift around a block branch" do
      before_source = """
      defmodule M do
        def kind(x) do
          cond do
            is_atom(x) -> :atom
            is_integer(x) and x > 10 ->
              doubled = x * 2
              {:big_int, doubled}
            true -> :other
          end
        end
      end
      """

      expected = """
      defmodule M do
        def kind(x) when is_atom(x), do: :atom

        def kind(x) when is_integer(x) and x > 10 do
          doubled = x * 2
          {:big_int, doubled}
        end

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
            score >= 90 -> score |> Integer.to_string() |> String.pad_leading(3)
            score >= 50 -> :silver
            true -> :bronze
          end
        end
      end
      """

      expected = """
      defmodule M do
        defp tier(score) when score >= 90, do: score |> Integer.to_string() |> String.pad_leading(3)
        defp tier(score) when score >= 50, do: :silver
        defp tier(_score), do: :bronze
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "truthiness-safe guards (bare/non-boolean conditions)" do
    test "a bare-variable branch condition is wrapped in `not in [nil, false]`" do
      before_source = """
      defmodule M do
        defp table(name, prefix) do
          cond do
            prefix ->
              x = prefix
              ~s("\#{x}".\#{name})

            true ->
              name
          end
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ "not in [nil, false]"
      refute result =~ "when prefix do"
      refute result =~ "when prefix,"
      assert_compiles(result)
    end

    test "bare-variable truthiness matches `cond` at runtime" do
      before_source = """
      defmodule CondTruthyM do
        def pick(x) do
          cond do
            x ->
              y = x
              {:present, y}

            true ->
              :absent
          end
        end
      end
      """

      result = apply_refactor(@subject, before_source)
      assert_compiles(result)

      [{mod, _}] = Code.compile_string(result)

      try do
        assert mod.pick("truthy string") == {:present, "truthy string"}
        assert mod.pick(0) == {:present, 0}
        assert mod.pick(nil) == :absent
        assert mod.pick(false) == :absent
      after
        :code.purge(mod)
        :code.delete(mod)
      end
    end
  end

  describe "boolean-proven conditions keep their guard unchanged" do
    test "comparison branch conditions are not wrapped" do
      before_source = """
      defmodule M do
        def classify(n) do
          cond do
            n < 0 -> n |> abs() |> Integer.to_string()
            n == 0 -> :zero
            true -> :pos
          end
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ "when n < 0"
      assert result =~ "when n == 0"
      refute result =~ "not in [nil, false]"
    end
  end

  describe "unused parameters per lifted clause" do
    test "params unused in a clause are underscored" do
      before_source = """
      defmodule M do
        defp describe_range(n, min, max) do
          cond do
            n < min -> n |> Kernel.-(min) |> abs()
            n > max -> :above
            true -> :inside
          end
        end
      end
      """

      expected = """
      defmodule M do
        defp describe_range(n, min, _max) when n < min, do: n |> Kernel.-(min) |> abs()
        defp describe_range(n, _min, max) when n > max, do: :above
        defp describe_range(_n, _min, _max), do: :inside
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "body-only usage keeps the param named" do
      before_source = """
      defmodule M do
        def pick(a, b) do
          cond do
            a > 0 ->
              doubled = b * 2
              doubled

            true ->
              a
          end
        end
      end
      """

      expected = """
      defmodule M do
        def pick(a, b) when a > 0 do
          doubled = b * 2
          doubled
        end

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
            n > 0 ->
              x = n * 2
              x + 1

            true ->
              :neg
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

      assert_idempotent(@subject, before_source)
    end

    test "lifted clauses compile" do
      before_source = """
      defmodule CondCompileCheck do
        def classify(n) do
          cond do
            n < 0 -> n |> abs() |> Integer.to_string()
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

  describe "skips — complexity heuristic (inverse of MergeClausesIntoCondOrGuard)" do
    test "skips when every branch body is simple" do
      source = """
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

      assert_unchanged(@subject, source)
    end

    test "a single-stage pipe is still a simple body" do
      source = """
      defmodule M do
        def classify(n) do
          cond do
            n < 0 -> n |> abs()
            true -> n
          end
        end
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
            valid?(n) -> n |> abs() |> Integer.to_string()
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
            n > threshold -> n |> abs() |> Integer.to_string()
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
            n < 0 -> n |> abs() |> Integer.to_string()
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
            n < 0 -> n |> abs() |> Integer.to_string()
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
            n < 0 -> n |> abs() |> Integer.to_string()
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
            n < 0 -> n |> abs() |> Integer.to_string()
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
            String.length(s) > 3 -> s |> String.upcase() |> String.reverse()
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
            n < 0 -> n |> abs() |> Integer.to_string()
            true -> :nonneg
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end
end
