defmodule Num42.Refactors.Refactors.ImportAfterAliasTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.ImportAfterAlias

  @subject ImportAfterAlias

  describe "rewrites" do
    test "single import before alias is moved after the alias block" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          import Foo
          alias My.Mod

          def go, do: Mod.run()
        end
        """,
        """
        defmodule M do
          alias My.Mod
          import Foo

          def go, do: Mod.run()
        end
        """
      )
    end

    test "multiple imports before aliases are all moved after the alias block" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          import Foo
          import Bar
          alias My.A
          alias My.B

          def go, do: :ok
        end
        """,
        """
        defmodule M do
          alias My.A
          alias My.B
          import Foo
          import Bar

          def go, do: :ok
        end
        """
      )
    end

    test "imports interleaved with aliases get gathered after the alias block" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          alias My.A
          import Foo
          alias My.B
          import Bar

          def go, do: :ok
        end
        """,
        """
        defmodule M do
          alias My.A
          alias My.B
          import Foo
          import Bar

          def go, do: :ok
        end
        """
      )
    end

    test "use stays at the top; imports go after aliases" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          use SomeBehaviour
          import Foo
          alias My.Mod

          def go, do: Mod.run()
        end
        """,
        """
        defmodule M do
          use SomeBehaviour
          alias My.Mod
          import Foo

          def go, do: Mod.run()
        end
        """
      )
    end
  end

  describe "leaves alone" do
    test "no aliases — nothing to move imports past" do
      assert_unchanged(@subject, """
      defmodule M do
        import Foo
        import Bar

        def go, do: :ok
      end
      """)
    end

    test "imports already after aliases" do
      assert_unchanged(@subject, """
      defmodule M do
        alias My.Mod
        import Foo

        def go, do: Mod.run()
      end
      """)
    end

    test "no imports at all" do
      assert_unchanged(@subject, """
      defmodule M do
        alias My.Mod

        def go, do: Mod.run()
      end
      """)
    end

    test "function-local import is not lifted (LiftDirectives does that)" do
      assert_unchanged(@subject, """
      defmodule M do
        alias My.Mod

        def go do
          import Foo
          Mod.run()
        end
      end
      """)
    end

    test "no defmodule wrapper" do
      assert_unchanged(@subject, """
      import Foo
      alias My.Mod
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      defmodule M do
        import Foo
        alias My.Mod

        def go, do: Mod.run()
      end
      """)
    end
  end
end
