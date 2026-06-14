defmodule Number42.Refactors.Ex.ListWrapConditionalTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ListWrapConditional

  @subject ListWrapConditional

  describe "rewrites" do
    test "if is_list(x), do: x, else: [x] -> List.wrap(x)" do
      assert_rewrites(
        @subject,
        "if is_list(x), do: x, else: [x]",
        "List.wrap(x)"
      )
    end

    test "block form (do/else/end) rewrites the same" do
      assert_rewrites(
        @subject,
        """
        if is_list(value) do
          value
        else
          [value]
        end
        """,
        "List.wrap(value)"
      )
    end
  end

  describe "leaves alone" do
    test "else branch is not the singleton [x] (extra element)" do
      assert_unchanged(@subject, "if is_list(x), do: x, else: [x, y]")
    end

    test "else branch wraps a different variable" do
      assert_unchanged(@subject, "if is_list(x), do: x, else: [other]")
    end

    test "do branch is not the guarded variable" do
      assert_unchanged(@subject, "if is_list(x), do: other, else: [x]")
    end

    test "guard variable differs from branch variable" do
      assert_unchanged(@subject, "if is_list(x), do: y, else: [y]")
    end

    test "guard is not is_list/1" do
      assert_unchanged(@subject, "if is_map(x), do: x, else: [x]")
    end

    test "already List.wrap/1" do
      assert_unchanged(@subject, "List.wrap(x)")
    end

    test "no else branch" do
      assert_unchanged(@subject, "if is_list(x), do: x")
    end
  end

  describe "nil divergence (documented)" do
    # `List.wrap(nil)` is `[]`, but `if is_list(nil), do: nil, else: [nil]`
    # is `[nil]`. The refactor CANNOT prove `x` is non-nil from the
    # conditional, so it still fires on the exact shape (this is why the
    # module is default-off in `.refactor.exs`). This test pins the
    # known, deliberate divergence so a future change to skip-on-nil is a
    # conscious decision, not an accident.
    test "fires on the exact shape even though nil is unprovable" do
      assert_rewrites(
        @subject,
        "if is_list(x), do: x, else: [x]",
        "List.wrap(x)"
      )
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "if is_list(x), do: x, else: [x]")
    end
  end
end
