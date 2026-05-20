defmodule Num42.Refactors.Refactors.ExtractLambdaBlockTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.ExtractLambdaBlock

  @subject ExtractLambdaBlock

  describe "rewrites" do
    test "two anonymous lambdas with identical bodies become a shared helper" do
      source = """
      defmodule MyApp.Pricing do
        def first(items) do
          Enum.map(items, fn item ->
            x = compute(item)
            y = transform(x)
            %{item: item, score: y}
          end)
        end

        def second(items) do
          Enum.map(items, fn item ->
            x = compute(item)
            y = transform(x)
            %{item: item, score: y}
          end)
        end
      end
      """

      expected = """
      defmodule MyApp.Pricing do
        def first(items) do
          Enum.map(items, &extracted_lambda/1)
        end

        def second(items) do
          Enum.map(items, &extracted_lambda/1)
        end

        defp extracted_lambda(item) do
          x = compute(item)
          y = transform(x)
          %{item: item, score: y}
        end
      end
      """

      assert_rewrites(@subject, source, expected, min_mass: 5)
    end
  end

  describe "skips" do
    test "single lambda — no clone, nothing to extract" do
      source = """
      defmodule MyApp.Solo do
        def lonely(items) do
          Enum.map(items, fn item ->
            x = compute(item)
            y = transform(x)
            %{item: item, score: y}
          end)
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 5)
    end

    test "lambda body below min_mass" do
      source = """
      defmodule MyApp.Tiny do
        def first(items), do: Enum.map(items, fn x -> x + 1 end)
        def second(items), do: Enum.map(items, fn x -> x + 1 end)
      end
      """

      assert_unchanged(@subject, source, min_mass: 50)
    end

    test "lambda closes over outer-scope var (not just its own params)" do
      source = """
      defmodule MyApp.Closure do
        def first(items, multiplier) do
          Enum.map(items, fn item ->
            a = compute(item)
            b = transform(a, multiplier)
            %{result: b}
          end)
        end

        def second(items, multiplier) do
          Enum.map(items, fn item ->
            a = compute(item)
            b = transform(a, multiplier)
            %{result: b}
          end)
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 5)
    end

    test "different arity — no clone (fn item -> vs fn item, acc ->)" do
      source = """
      defmodule MyApp.DiffArity do
        def first(items) do
          Enum.map(items, fn item ->
            x = compute(item)
            y = transform(x)
            %{score: y}
          end)
        end

        def second(items) do
          Enum.reduce(items, %{}, fn item, acc ->
            x = compute(item)
            y = transform(x)
            Map.put(acc, item, y)
          end)
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 5)
    end
  end

  describe "idempotence" do
    test "rewriting twice yields the same result" do
      source = """
      defmodule MyApp.Pricing do
        def first(items) do
          Enum.map(items, fn item ->
            x = compute(item)
            y = transform(x)
            %{item: item, score: y}
          end)
        end

        def second(items) do
          Enum.map(items, fn item ->
            x = compute(item)
            y = transform(x)
            %{item: item, score: y}
          end)
        end
      end
      """

      assert_idempotent(@subject, source, min_mass: 5)
    end
  end
end
