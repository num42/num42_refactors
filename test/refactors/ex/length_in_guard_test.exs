defmodule Number42.Refactors.Ex.LengthInGuardTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.LengthInGuard

  @subject LengthInGuard

  # The refactor only fires for `length(list) > 0` (non-empty test) —
  # it splits the function into an empty-list clause inheriting the
  # catch-all body and a `[_ | _]` clause for the non-empty case.
  # `length(list) == 0` is left alone (the catch-all reordering it
  # would require is a judgment call the refactor doesn't make).
  describe "rewrites" do
    test "length(list) > 0 becomes [_ | _] pattern + empty clause" do
      before_source = """
      defmodule Foo do
        def go(list) when length(list) > 0, do: :nonempty
        def go(_), do: :empty
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ "[_ | _]" or result =~ "[_|_]"
      assert result =~ "def go([])"
      refute result == before_source
    end
  end

  describe "leaves alone" do
    test "length(list) == 0 (refactor declines to reorder catch-all)" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def go(list) when length(list) == 0, do: :empty
        def go(list), do: {:nonempty, list}
      end
      """)
    end

    test "length used outside a guard" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def go(list) do
          n = length(list)
          n + 1
        end
      end
      """)
    end

    test "guard that genuinely needs length (e.g. == 3)" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def go(list) when length(list) == 3, do: :triple
        def go(_), do: :other
      end
      """)
    end

    test "no def with a length guard" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def go(_), do: :ok
      end
      """)
    end

    test "length(@module_attr) — `@cache` is not a head-bound var" do
      # The refactor turns `length(var) <op> n` into cons-pattern
      # clauses on `var`, which only makes sense when `var` is a
      # parameter of the head. A module attribute can't be split
      # across patterns — leave it alone.
      assert_unchanged(@subject, """
      defmodule Foo do
        @cache [:a, :b, :c]

        def go(x) when length(@cache) > 0, do: x
        def go(_), do: nil
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      defmodule Foo do
        def go(list) when length(list) > 0, do: :nonempty
        def go(_), do: :empty
      end
      """)
    end
  end
end
