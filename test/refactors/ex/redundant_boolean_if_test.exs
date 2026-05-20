defmodule Number42.Refactors.Ex.RedundantBooleanIfTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.RedundantBooleanIf

  @subject RedundantBooleanIf

  describe "rewrites" do
    test "if cond, do: true, else: false -> cond" do
      assert_rewrites(@subject, "if x > 0, do: true, else: false", "x > 0")
    end

    test "if cond, do: false, else: true -> !(cond)" do
      # Refactor emits `!(...)`, not `not (...)`.
      assert_rewrites(@subject, "if x > 0, do: false, else: true", "!(x > 0)")
    end

    test "block form is also rewritten" do
      before_source = """
      if x > 0 do
        true
      else
        false
      end
      """

      assert_rewrites(@subject, before_source, "x > 0")
    end
  end

  describe "leaves alone" do
    test "if with non-boolean branches" do
      assert_unchanged(@subject, "if x > 0, do: :a, else: :b")
    end

    test "if without else (semantic difference: returns nil for false)" do
      assert_unchanged(@subject, "if x > 0, do: true")
    end

    test "if returning the same on both branches" do
      assert_unchanged(@subject, "if x > 0, do: true, else: true")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "if x > 0, do: true, else: false")
    end
  end
end
