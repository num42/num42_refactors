defmodule Number42.Refactors.Ex.LiftLocalLambdaTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.LiftLocalLambda

  @subject LiftLocalLambda

  describe "rewrites" do
    test "lambda with closed-over vars is lifted, closures promoted to params" do
      source = """
      defmodule MyApp.Validation do
        def validate_multi_select(value, allowed) do
          compute_all_valid = fn ->
            value
            |> String.split(",", trim: true)
            |> Enum.map(&String.trim/1)
            |> Enum.all?(&(&1 in allowed))
          end

          cond do
            value in [nil, ""] ->
              :empty

            compute_all_valid.() ->
              :valid

            true ->
              :invalid
          end
        end
      end
      """

      expected = """
      defmodule MyApp.Validation do
        def validate_multi_select(value, allowed) do
          cond do
            value in [nil, ""] ->
              :empty

            all_valid?(value, allowed) ->
              :valid

            true ->
              :invalid
          end
        end

        defp all_valid?(value, allowed) do
          value
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.all?(&(&1 in allowed))
        end
      end
      """

      assert_rewrites(@subject, source, expected, min_mass: 5)
      assert_compiles(apply_refactor(@subject, source, min_mass: 5))
    end

    test "lambda with no free vars is lifted with empty params" do
      source = """
      defmodule MyApp.Plain do
        def run do
          greet = fn ->
            x = build()
            transform(x)
          end

          greet.()
        end

        defp build, do: 1
        defp transform(x), do: x + 1
      end
      """

      expected = """
      defmodule MyApp.Plain do
        def run do
          greet()
        end

        defp build, do: 1
        defp transform(x), do: x + 1

        defp greet do
          x = build()
          transform(x)
        end
      end
      """

      assert_rewrites(@subject, source, expected, min_mass: 3)
      assert_compiles(apply_refactor(@subject, source, min_mass: 3))
    end

    test "lambda taking its own arg keeps it as leading param, closures appended" do
      source = """
      defmodule MyApp.ArgTaking do
        def run(factor) do
          scale = fn x ->
            base = compute(x)
            base * factor
          end

          scale.(10)
        end

        defp compute(x), do: x * 2
      end
      """

      expected = """
      defmodule MyApp.ArgTaking do
        def run(factor) do
          scale(10, factor)
        end

        defp compute(x), do: x * 2

        defp scale(x, factor) do
          base = compute(x)
          base * factor
        end
      end
      """

      assert_rewrites(@subject, source, expected, min_mass: 3)
      assert_compiles(apply_refactor(@subject, source, min_mass: 3))
    end

    test "lambda called more than once is lifted, every call site rewritten" do
      source = """
      defmodule MyApp.MultiCall do
        def run(a, b, flag) do
          combine = fn ->
            x = step(a)
            y = step(b)
            merge(x, y)
          end

          if flag do
            combine.()
          else
            combine.()
          end
        end

        defp step(n), do: n + 1
        defp merge(x, y), do: {x, y}
      end
      """

      expected = """
      defmodule MyApp.MultiCall do
        def run(a, b, flag) do
          if flag do
            combine(a, b)
          else
            combine(a, b)
          end
        end

        defp step(n), do: n + 1
        defp merge(x, y), do: {x, y}

        defp combine(a, b) do
          x = step(a)
          y = step(b)
          merge(x, y)
        end
      end
      """

      assert_rewrites(@subject, source, expected, min_mass: 3)
      assert_compiles(apply_refactor(@subject, source, min_mass: 3))
    end
  end

  describe "skips" do
    test "lambda passed as a value to another function (escapes)" do
      source = """
      defmodule MyApp.Escape do
        def run(items) do
          mapper = fn x ->
            a = compute(x)
            transform(a)
          end

          Enum.map(items, mapper)
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 3)
    end

    test "lambda returned from the function (escapes)" do
      source = """
      defmodule MyApp.Returned do
        def run(factor) do
          scale = fn x ->
            base = compute(x)
            base * factor
          end

          scale
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 3)
    end

    test "recursive lambda referencing its own binding" do
      source = """
      defmodule MyApp.Recursive do
        def run(n) do
          loop = fn next ->
            if next > 0 do
              work(next)
              loop.(next - 1)
            end
          end

          loop.(n)
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 3)
    end

    test "multi-clause lambda" do
      source = """
      defmodule MyApp.MultiClause do
        def run(x) do
          classify = fn
            :a -> first()
            :b -> second()
          end

          classify.(x)
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 1)
    end

    test "lambda called zero times (dead binding)" do
      source = """
      defmodule MyApp.Dead do
        def run(a) do
          unused = fn ->
            x = step(a)
            transform(x)
          end

          a
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 3)
    end

    test "closed-over var is rebound after the lambda is defined" do
      source = """
      defmodule MyApp.Rebound do
        def run(a) do
          snapshot = fn ->
            x = step(a)
            transform(x, a)
          end

          a = mutate(a)
          _ = a
          snapshot.()
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 3)
    end

    test "lambda body below min_mass" do
      source = """
      defmodule MyApp.Tiny do
        def run(a) do
          f = fn -> a + 1 end
          f.()
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 50)
    end

    test "helper name already taken with a different shape" do
      source = """
      defmodule MyApp.Taken do
        def run(a, b) do
          combine = fn ->
            x = step(a)
            y = step(b)
            merge(x, y)
          end

          combine.()
        end

        defp combine(x, y, z) do
          {x, y, z}
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 3)
    end
  end

  describe "idempotence" do
    test "rewriting twice yields the same result" do
      source = """
      defmodule MyApp.Validation do
        defp validate(changeset, field, allowed) do
          value = get_field(changeset, field)

          compute_all_valid = fn ->
            value
            |> String.split(",", trim: true)
            |> Enum.all?(&(&1 in allowed))
          end

          cond do
            value in [nil, ""] -> changeset
            compute_all_valid.() -> changeset
            true -> add_error(changeset, field, "bad")
          end
        end
      end
      """

      assert_idempotent(@subject, source, min_mass: 3)
    end
  end
end
