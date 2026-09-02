defmodule Number42.Refactors.Ex.ShortenVerboseIdentifierTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Ex.ShortenVerboseIdentifier, as: Shorten

  defp run(src, opts \\ []) do
    Shorten.transform(src, Keyword.merge([enabled: true], opts))
  end

  defp compiles?(src), do: match?({:ok, _}, Code.string_to_quoted(src))

  describe "private function names" do
    @over ~S'''
    defmodule M do
      def run(x), do: build_serie_match_conditions_match_binding(x)

      defp build_serie_match_conditions_match_binding(x), do: x
    end
    '''

    test "an over-long defp is renamed together with its call sites" do
      out = run(@over)

      assert compiles?(out)
      refute out =~ "build_serie_match_conditions_match_binding"
      assert out =~ "defp build_match_conditions_binding(x)"
      assert out =~ "do: build_match_conditions_binding(x)"
    end

    test "off by default" do
      assert Shorten.transform(@over, []) == @over
    end

    test "a name under the trigger is left alone" do
      src = ~S'''
      defmodule M do
        defp build_match_conditions(x), do: x
      end
      '''

      assert run(src) == src
    end

    test "every clause of the renamed function moves along" do
      src = ~S'''
      defmodule M do
        def run(x), do: fetch_serie_match_conditions_match_binding(x)

        defp fetch_serie_match_conditions_match_binding([]), do: []
        defp fetch_serie_match_conditions_match_binding(x), do: x
      end
      '''

      out = run(src)

      assert compiles?(out)
      refute out =~ "fetch_serie_match_conditions_match_binding"
      assert out =~ "defp fetch_match_conditions_binding([])"
      assert out =~ "defp fetch_match_conditions_binding(x)"
    end

    test "a public def is never renamed — its callers are out of reach" do
      src = ~S'''
      defmodule M do
        def build_serie_match_conditions_match_binding(x), do: x
      end
      '''

      assert run(src) == src
    end

    test "declines when the shorter name is already taken in the module" do
      src = ~S'''
      defmodule M do
        defp build_match_conditions_binding(x), do: x
        defp build_serie_match_conditions_match_binding(x), do: x
      end
      '''

      assert run(src) == src
    end

    test "a capture of the renamed function follows" do
      src = ~S'''
      defmodule M do
        def run(xs), do: Enum.map(xs, &build_serie_match_conditions_match_binding/1)

        defp build_serie_match_conditions_match_binding(x), do: x
      end
      '''

      out = run(src)

      assert compiles?(out)
      assert out =~ "&build_match_conditions_binding/1"
    end

    test "is idempotent" do
      once = run(@over)

      assert run(once) == once
    end
  end

  describe "bindings" do
    test "an over-long binding is renamed within its clause" do
      src = ~S'''
      defmodule M do
        def run(x) do
          serie_match_conditions_match_fields_binding = compute(x)
          use_it(serie_match_conditions_match_fields_binding)
        end
      end
      '''

      out = run(src)

      assert compiles?(out)
      refute out =~ "serie_match_conditions_match_fields_binding"
      assert out =~ "use_it(serie_conditions_fields_binding)"
    end

    test "a binding in another clause with the same name is untouched by this one" do
      src = ~S'''
      defmodule M do
        def run(x) do
          serie_match_conditions_match_fields_binding = compute(x)
          serie_match_conditions_match_fields_binding
        end

        def other(x) do
          other_thing = x
          other_thing
        end
      end
      '''

      out = run(src)

      assert compiles?(out)
      assert out =~ "other_thing = x"
    end

    test "declines when the shorter binding name is already used in the clause" do
      src = ~S'''
      defmodule M do
        def run(x) do
          serie_conditions_fields_binding = x
          serie_match_conditions_match_fields_binding = compute(x)
          {serie_conditions_fields_binding, serie_match_conditions_match_fields_binding}
        end
      end
      '''

      assert run(src) == src
    end

    test "a function parameter is not a binding this touches" do
      src = ~S'''
      defmodule M do
        def run(serie_match_conditions_match_fields_binding) do
          serie_match_conditions_match_fields_binding
        end
      end
      '''

      assert run(src) == src
    end
  end

  describe "corpus ranking" do
    test "with a corpus the ubiquitous token is the one that goes" do
      src = ~S'''
      defmodule M do
        def run(x), do: build_serie_match_conditions_binding_fields(x)

        defp build_serie_match_conditions_binding_fields(x), do: x
      end
      '''

      out = run(src, identifier_corpus: %{"serie" => 1, "binding" => 99, "match" => 2})

      assert compiles?(out)
      refute out =~ "binding_fields"
      assert out =~ "serie"
    end
  end
end
