defmodule Num42.Refactors.Refactors.RemoveBlankBetweenAttrAndDefTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.RemoveBlankBetweenAttrAndDef

  @subject RemoveBlankBetweenAttrAndDef

  describe "rewrites" do
    test "strips blank line between @doc and def" do
      before_source = """
      defmodule Foo do
        @doc "go"
        def go(x), do: x
      end
      """

      after_source = """
      defmodule Foo do
        @doc "go"
        def go(x), do: x
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "strips blank line between @spec and def" do
      before_source = """
      defmodule Foo do
        @spec go(integer()) :: integer()
        def go(x), do: x
      end
      """

      after_source = """
      defmodule Foo do
        @spec go(integer()) :: integer()
        def go(x), do: x
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "leaves alone" do
    test "@doc directly followed by def (no blank line)" do
      assert_unchanged(@subject, """
      defmodule Foo do
        @doc "go"
        def go(x), do: x
      end
      """)
    end

    test "module-level @ attribute not attached to a function" do
      assert_unchanged(@subject, """
      defmodule Foo do
        @config [a: 1]

        def go, do: @config
      end
      """)
    end

    test "comment between @doc and def — left alone" do
      # A comment between `@doc` and `def` is intentional content the
      # author wrote — squeezing it out would lose information. Skip
      # the rewrite; the user can clean it up by hand.
      assert_unchanged(@subject, """
      defmodule Foo do
        @doc "go"

        # explains why this is special
        def go(x), do: x
      end
      """)
    end

    test "multiple blank lines between @doc and def — left alone" do
      # 2+ blank lines is also a deliberate visual break. Don't
      # collapse silently.
      assert_unchanged(@subject, """
      defmodule Foo do
        @doc "go"


        def go(x), do: x
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      defmodule Foo do
        @doc "go"
        def go(x), do: x
      end
      """)
    end
  end
end
