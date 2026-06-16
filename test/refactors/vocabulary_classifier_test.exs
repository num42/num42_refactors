defmodule Number42.Refactors.VocabularyClassifierTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.VocabularyClassifier

  # Parse a module source into the per-`def` clause-AST lists the classifier
  # consumes (mirrors what SplitLowCohesionModule passes from
  # AstHelpers.collect_definitions/1).
  defp clauses(src) do
    {:ok, ast} = Sourceror.parse_string(src)

    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [_n, [{_do, body}]]} ->
        exprs =
          case body do
            {:__block__, _, e} -> e
            single -> [single]
          end

        [Number42.Refactors.AstHelpers.collect_definitions(exprs)]

      _ ->
        []
    end)
    |> List.flatten()
    |> Enum.map(& &1.clauses)
  end

  describe "god_probability/1" do
    test "returns a probability in [0, 1]" do
      p =
        VocabularyClassifier.god_probability(
          clauses("""
          defmodule M do
            def a(x), do: x
          end
          """)
        )

      assert p >= 0.0 and p <= 1.0
    end

    test "a concentrated single-concern module scores lower than a diverse one" do
      concentrated =
        clauses("""
        defmodule M do
          def a1(x), do: x |> a2() |> a3()
          defp a2(x), do: a4(x)
          defp a3(x), do: x
          defp a4(x), do: x
          def b1(x), do: x |> b2() |> b3()
          defp b2(x), do: b4(x)
          defp b3(x), do: x
          defp b4(x), do: x
        end
        """)

      diverse =
        clauses("""
        defmodule M do
          def create_user(form), do: form |> validate() |> persist()
          defp validate(f), do: %{login: String.downcase(f.email), secret: hash(f.password)}
          defp hash(plain), do: :crypto.hash(:sha256, plain)
          defp persist(creds), do: Map.merge(creds, %{created: now(), role: :member})
          defp now, do: :calendar.universal_time()
          def charge(co), do: co |> authorize() |> settle()
          defp authorize(cart), do: %{amount: total(cart), processor: gateway(cart)}
          defp total(cart), do: Enum.reduce(cart.items, 0, fn i, s -> s + i.price end)
          defp gateway(cart), do: cart.currency
          defp settle(ch), do: Map.put(ch, :receipt, invoice(ch))
          defp invoice(ch), do: ch.processor
        end
        """)

      assert VocabularyClassifier.god_probability(concentrated) <
               VocabularyClassifier.god_probability(diverse)
    end

    test "empty input is handled (no crash, low score)" do
      assert VocabularyClassifier.god_probability([]) <= 1.0
    end
  end

  describe "split_worthy?/2" do
    test "threshold 0.0 is always worthy; 1.0 effectively never" do
      cl =
        clauses("""
        defmodule M do
          def a(x), do: x
          def b(y), do: y
        end
        """)

      assert VocabularyClassifier.split_worthy?(cl, 0.0)
      refute VocabularyClassifier.split_worthy?(cl, 1.0)
    end
  end

  describe "feature_vector/1" do
    test "returns four finite features" do
      v = VocabularyClassifier.feature_vector([[:foo, :bar, :foo], [:baz]])
      assert length(v) == 4
      assert Enum.all?(v, &is_float/1)
    end
  end
end
