defmodule Number42.Refactors.Ex.AliasUsageTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.AliasUsage

  @subject AliasUsage

  describe "rewrites" do
    test "single FQN call introduces an alias and shortens the call site" do
      before_source = """
      defmodule Foo do
        def go(x), do: My.Deep.Mod.run(x)
      end
      """

      after_source = """
      defmodule Foo do
        alias My.Deep.Mod

        def go(x), do: Mod.run(x)
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "multiple distinct FQNs each get their own alias" do
      before_source = """
      defmodule Foo do
        def go(x) do
          A.B.one(x)
          C.D.two(x)
        end
      end
      """

      after_source = """
      defmodule Foo do
        alias A.B
        alias C.D

        def go(x) do
          B.one(x)
          D.two(x)
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "inserts alias after a leading @moduledoc, not before it" do
      before_source = """
      defmodule Foo do
        @moduledoc "Orchestrates things."

        def go(x), do: My.Deep.Mod.run(x)
      end
      """

      after_source = """
      defmodule Foo do
        @moduledoc "Orchestrates things."

        alias My.Deep.Mod

        def go(x), do: Mod.run(x)
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "inserts alias after @moduledoc that precedes an existing alias block" do
      before_source = """
      defmodule Foo do
        @moduledoc "Orchestrates things."

        alias Already.Here

        def go(x), do: My.Deep.Mod.run(Here.f(x))
      end
      """

      after_source = """
      defmodule Foo do
        @moduledoc "Orchestrates things."

        alias Already.Here
        alias My.Deep.Mod

        def go(x), do: Mod.run(Here.f(x))
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "inserts alias after existing prefix block" do
      before_source = """
      defmodule Foo do
        use SomeBehaviour
        import OtherStuff

        def go(x), do: My.Deep.Mod.run(x)
      end
      """

      after_source = """
      defmodule Foo do
        use SomeBehaviour
        import OtherStuff
        alias My.Deep.Mod

        def go(x), do: Mod.run(x)
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "leaves alone" do
    test "stdlib namespaces (Enum, String, IO, ...)" do
      source = """
      defmodule Foo do
        def go(x) do
          Enum.map(x, & &1)
          String.upcase(x)
          IO.inspect(x)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "single-segment module reference" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def go(x), do: Bar.run(x)
      end
      """)
    end

    test "FQN that would collide with an existing alias" do
      assert_unchanged(@subject, """
      defmodule Foo do
        alias Other.Mod

        def go(x), do: My.Deep.Mod.run(x)
      end
      """)
    end

    test "module attribute RHS is skipped (alias would be too late at compile time)" do
      assert_unchanged(@subject, """
      defmodule Foo do
        @config My.Deep.Mod.default_config()

        def go, do: @config
      end
      """)
    end

    test "no defmodule wrapper" do
      assert_unchanged(@subject, "x = My.Deep.Mod.run(1)\n")
    end

    test "two FQNs sharing the same last segment leave both alone" do
      # `SomeModuleA.Edit` and `SomeOtherB.Edit` would both want
      # `alias … .Edit`. Lifting both produces two `alias` lines with
      # the same `Edit` last segment — the second silently shadows the
      # first and call sites bind to the wrong module. Skip both.
      assert_unchanged(@subject, """
      defmodule Foo do
        def go(x) do
          SomeModuleA.Edit.some_function(x)
          SomeOtherB.Edit.some_other_fun(x)
        end
      end
      """)
    end

    test "ambiguous + unambiguous: only the unambiguous one is lifted" do
      before_source = """
      defmodule Foo do
        def go(x) do
          SomeModuleA.Edit.f(x)
          SomeOtherB.Edit.g(x)
          Unique.Solo.h(x)
        end
      end
      """

      after_source = """
      defmodule Foo do
        alias Unique.Solo

        def go(x) do
          SomeModuleA.Edit.f(x)
          SomeOtherB.Edit.g(x)
          Solo.h(x)
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "already aliased and shortened" do
      assert_unchanged(@subject, """
      defmodule Foo do
        alias My.Deep.Mod

        def go(x), do: Mod.run(x)
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      defmodule Foo do
        def go(x), do: My.Deep.Mod.run(x)
      end
      """)
    end

    test "running twice equals running once with a leading @moduledoc" do
      assert_idempotent(@subject, """
      defmodule Foo do
        @moduledoc "Orchestrates things."

        def go(x), do: My.Deep.Mod.run(x)
      end
      """)
    end
  end
end
