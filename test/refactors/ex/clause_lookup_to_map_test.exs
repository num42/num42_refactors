defmodule Number42.Refactors.Ex.ClauseLookupToMapTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ClauseLookupToMap

  @subject ClauseLookupToMap

  describe "rewrites" do
    test "N atom->string clauses collapse into a @attr map + passthrough" do
      source = """
      defmodule M do
        defp icon(:success), do: "green"
        defp icon(:warning), do: "yellow"
        defp icon(:error), do: "red"
      end
      """

      expected = """
      defmodule M do
        @icons %{success: "green", warning: "yellow", error: "red"}
        defp icon(key), do: @icons[key]
      end
      """

      assert_rewrites(@subject, source, expected)
      assert_compiles(apply_refactor(@subject, source))
    end

    test "trailing catch-all becomes a Map.get/3 default" do
      source = """
      defmodule M do
        defp icon(:ok), do: "green"
        defp icon(:err), do: "red"
        defp icon(:warn), do: "yellow"
        defp icon(_), do: "grey"
      end
      """

      expected = """
      defmodule M do
        @icons %{ok: "green", err: "red", warn: "yellow"}
        defp icon(key), do: Map.get(@icons, key, "grey")
      end
      """

      assert_rewrites(@subject, source, expected)
      assert_compiles(apply_refactor(@subject, source))
    end

    test "public def clauses collapse too" do
      source = """
      defmodule M do
        def code(:a), do: 1
        def code(:b), do: 2
        def code(:c), do: 3
      end
      """

      rewritten = apply_refactor(@subject, source)

      assert rewritten =~ "@codes %{a: 1, b: 2, c: 3}"
      assert rewritten =~ "def code(key), do: @codes[key]"
      assert_compiles(rewritten)
    end

    test "integer literal heads use arrow-form map keys" do
      source = """
      defmodule M do
        defp name(1), do: "one"
        defp name(2), do: "two"
        defp name(3), do: "three"
      end
      """

      rewritten = apply_refactor(@subject, source)

      assert rewritten =~ "@names %{1 => \"one\", 2 => \"two\", 3 => \"three\"}"
      assert rewritten =~ "defp name(key), do: @names[key]"
      assert_compiles(rewritten)
    end

    test "string literal heads collapse" do
      source = """
      defmodule M do
        defp lang("de"), do: :german
        defp lang("en"), do: :english
        defp lang("fr"), do: :french
      end
      """

      rewritten = apply_refactor(@subject, source)

      assert rewritten =~ "@langs %{\"de\" => :german, \"en\" => :english, \"fr\" => :french}"
      assert_compiles(rewritten)
    end

    test "duplicate literal heads keep the first" do
      source = """
      defmodule M do
        defp pick(:a), do: 1
        defp pick(:b), do: 2
        defp pick(:a), do: 99
        defp pick(:c), do: 3
      end
      """

      rewritten = apply_refactor(@subject, source)

      assert rewritten =~ "@picks %{a: 1, b: 2, c: 3}"
      refute rewritten =~ "99"
    end

    test "literal collection bodies (lists/tuples) are constant" do
      source = """
      defmodule M do
        defp range(:low), do: {0, 10}
        defp range(:mid), do: {11, 50}
        defp range(:high), do: {51, 100}
      end
      """

      rewritten = apply_refactor(@subject, source)

      assert rewritten =~ "@ranges %{low: {0, 10}, mid: {11, 50}, high: {51, 100}}"
      assert_compiles(rewritten)
    end

    test "an already-plural function name is not double-pluralized" do
      source = """
      defmodule M do
        defp limits(:low), do: 10
        defp limits(:mid), do: 50
        defp limits(:high), do: 100
      end
      """

      rewritten = apply_refactor(@subject, source)

      assert rewritten =~ "@limits %{low: 10, mid: 50, high: 100}"
      assert rewritten =~ "defp limits(key), do: @limits[key]"
      assert_compiles(rewritten)
    end
  end

  describe "leaves alone" do
    test "fewer than 3 clauses" do
      assert_unchanged(@subject, """
      defmodule M do
        defp icon(:ok), do: "green"
        defp icon(:err), do: "red"
      end
      """)
    end

    test "a guard on any clause" do
      assert_unchanged(@subject, """
      defmodule M do
        defp icon(s) when is_atom(s), do: "x"
        defp icon(:ok), do: "green"
        defp icon(:err), do: "red"
      end
      """)
    end

    test "a non-constant body (function call)" do
      assert_unchanged(@subject, """
      defmodule M do
        defp icon(:ok), do: compute(:ok)
        defp icon(:err), do: "red"
        defp icon(:warn), do: "yellow"
      end
      """)
    end

    test "a body referencing a head-derived value (operator)" do
      assert_unchanged(@subject, """
      defmodule M do
        defp score(:a), do: 1 + 1
        defp score(:b), do: 2
        defp score(:c), do: 3
      end
      """)
    end

    test "multi-arg heads" do
      assert_unchanged(@subject, """
      defmodule M do
        defp icon(:ok, x), do: x
        defp icon(:err, x), do: x
        defp icon(:warn, x), do: x
      end
      """)
    end

    test "destructured (non-literal) head pattern" do
      assert_unchanged(@subject, """
      defmodule M do
        defp icon(%{a: 1}), do: "one"
        defp icon(%{a: 2}), do: "two"
        defp icon(%{a: 3}), do: "three"
      end
      """)
    end

    test "a catch-all that is not the last clause" do
      assert_unchanged(@subject, """
      defmodule M do
        defp icon(_), do: "grey"
        defp icon(:ok), do: "green"
        defp icon(:err), do: "red"
      end
      """)
    end

    test "a catch-all with a non-constant body" do
      assert_unchanged(@subject, """
      defmodule M do
        defp icon(:ok), do: "green"
        defp icon(:err), do: "red"
        defp icon(:warn), do: "yellow"
        defp icon(other), do: to_string(other)
      end
      """)
    end
  end

  describe "idempotence" do
    test "atom-dispatch group is stable after one pass" do
      assert_idempotent(@subject, """
      defmodule M do
        defp icon(:success), do: "green"
        defp icon(:warning), do: "yellow"
        defp icon(:error), do: "red"
      end
      """)
    end

    test "catch-all group is stable after one pass" do
      assert_idempotent(@subject, """
      defmodule M do
        defp icon(:ok), do: "green"
        defp icon(:err), do: "red"
        defp icon(:warn), do: "yellow"
        defp icon(_), do: "grey"
      end
      """)
    end
  end
end
