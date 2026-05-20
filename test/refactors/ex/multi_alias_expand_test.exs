defmodule Number42.Refactors.Ex.MultiAliasExpandTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.MultiAliasExpand

  @subject MultiAliasExpand

  describe "rewrites" do
    test "alias Foo.{A, B} expands to two aliases" do
      before_source = """
      defmodule X do
        alias Foo.{A, B}
      end
      """

      after_source = """
      defmodule X do
        alias Foo.A
        alias Foo.B
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "deep multi-alias expands segments correctly" do
      before_source = """
      defmodule X do
        alias My.Deep.{A, B, C}
      end
      """

      after_source = """
      defmodule X do
        alias My.Deep.A
        alias My.Deep.B
        alias My.Deep.C
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "leaves alone" do
    test "single-target alias" do
      assert_unchanged(@subject, """
      defmodule X do
        alias Foo.A
      end
      """)
    end

    test "no alias at all" do
      assert_unchanged(@subject, """
      defmodule X do
        def go, do: :ok
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      defmodule X do
        alias Foo.{A, B}
      end
      """)
    end
  end
end
