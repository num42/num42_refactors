defmodule Number42.Refactors.Ex.AliasOrderTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.AliasOrder

  @subject AliasOrder

  describe "rewrites" do
    test "sorts a contiguous alias group alphabetically" do
      before_source = """
      defmodule Foo do
        alias My.C
        alias My.A
        alias My.B
      end
      """

      after_source = """
      defmodule Foo do
        alias My.A
        alias My.B
        alias My.C
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "leaves alone" do
    test "already sorted" do
      assert_unchanged(@subject, """
      defmodule Foo do
        alias My.A
        alias My.B
        alias My.C
      end
      """)
    end

    test "single alias" do
      assert_unchanged(@subject, """
      defmodule Foo do
        alias My.Only
      end
      """)
    end

    test "no aliases at all" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def go, do: :ok
      end
      """)
    end
  end

  describe "idempotent" do
    test "sort then sort = sort" do
      assert_idempotent(@subject, """
      defmodule Foo do
        alias My.C
        alias My.A
        alias My.B
      end
      """)
    end
  end
end
