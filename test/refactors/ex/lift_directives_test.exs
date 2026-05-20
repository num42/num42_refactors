defmodule Number42.Refactors.Ex.LiftDirectivesTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.LiftDirectives

  @subject LiftDirectives

  describe "rewrites" do
    test "lifts a function-local alias to the module level" do
      before_source = """
      defmodule Foo do
        def go(x) do
          alias My.Helper
          Helper.run(x)
        end
      end
      """

      after_source = """
      defmodule Foo do
        alias My.Helper

        def go(x) do
          Helper.run(x)
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "lifts a function-local import" do
      before_source = """
      defmodule Foo do
        def go(x) do
          import My.Funcs
          run(x)
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ "import My.Funcs"
      refute result =~ "    import My.Funcs"
    end
  end

  describe "leaves alone" do
    test "directives already at module level" do
      assert_unchanged(@subject, """
      defmodule Foo do
        alias My.Helper

        def go(x), do: Helper.run(x)
      end
      """)
    end

    test "no defmodule wrapper" do
      assert_unchanged(@subject, "x = 1\n")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      defmodule Foo do
        def go(x) do
          alias My.Helper
          Helper.run(x)
        end
      end
      """)
    end
  end
end
