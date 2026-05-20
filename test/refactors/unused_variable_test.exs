defmodule Num42.Refactors.Refactors.UnusedVariableTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.UnusedVariable

  @subject UnusedVariable

  # The refactor only fires inside a `defmodule` and rewrites bindings
  # that are demonstrably unused — i.e. another binding in the same
  # clause IS used in the body. A def with one arg that returns `:ok`
  # has no contrast, so the refactor declines to flag the arg.
  describe "rewrites" do
    test "def parameter that's unused while a sibling is used" do
      before_source = """
      defmodule Foo do
        def go(unused, used), do: used + 1
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ "_unused"
    end
  end

  describe "leaves alone" do
    test "all parameters are used" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def go(a, b), do: a + b
      end
      """)
    end

    test "already prefixed with underscore" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def go(_unused, b), do: b
      end
      """)
    end

    test "no defmodule wrapper, just an expression" do
      assert_unchanged(@subject, "fn a -> a end")
    end

    test "fn binding outside of any def is left alone" do
      # The refactor only walks bindings in defs; a bare lambda at
      # the top level is out of scope.
      assert_unchanged(@subject, """
      defmodule Foo do
        @x fn a -> :ok end
      end
      """)
    end

    test "capture form `&(...)` has no named binding to rename" do
      # `&(:ok)` and `&(&1.id)` are captures, not lambda parameters
      # — there's no name to underscore-prefix. The refactor must
      # not invent one.
      assert_unchanged(@subject, """
      defmodule Foo do
        def go(list) do
          Enum.map(list, &(:ok))
        end
      end
      """)
    end

    # `def foo(r) do ... rescue _ -> r.x end` looks unused if we only
    # scan the `:do` block — but `r` is referenced from the `:rescue`
    # body, which the compiler ties to the same scope. Renaming the
    # arg to `_r` introduces a compile-error ("undefined variable r")
    # inside the rescue clause. The refactor must treat `:rescue`,
    # `:catch`, and `:after` keyword blocks as part of the def's
    # body when scanning for uses.
    test "parameter used only in rescue body is left alone" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def go(r) do
          :ok
        rescue
          _ -> r.kind
        end
      end
      """)
    end

    test "parameter used only in catch body is left alone" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def go(r) do
          :ok
        catch
          _ -> r
        end
      end
      """)
    end

    test "parameter used only in after body is left alone" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def go(r) do
          :ok
        after
          IO.inspect(r)
        end
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      defmodule Foo do
        def go(unused, used), do: used + 1
      end
      """)
    end
  end
end
