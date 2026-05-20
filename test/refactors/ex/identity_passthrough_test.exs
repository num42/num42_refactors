defmodule Number42.Refactors.Ex.IdentityPassthroughTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.IdentityPassthrough

  @subject IdentityPassthrough

  describe "rewrites" do
    test "case where every clause returns its pattern is removed" do
      before_source = """
      case x do
        :a -> :a
        :b -> :b
      end
      """

      after_source = "x"

      assert_rewrites(@subject, before_source, after_source)
    end

    test "case with bound var clauses returning the var" do
      before_source = """
      case fetch() do
        {:ok, v} -> {:ok, v}
        {:error, e} -> {:error, e}
      end
      """

      after_source = "fetch()"

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "leaves alone" do
    test "case where any clause transforms its pattern" do
      assert_unchanged(@subject, """
      case x do
        :a -> :alpha
        :b -> :b
      end
      """)
    end

    test "case with a catch-all clause that doesn't match the pattern" do
      assert_unchanged(@subject, """
      case x do
        :a -> :a
        _ -> :other
      end
      """)
    end

    test "non-case expression" do
      assert_unchanged(@subject, "if x, do: x, else: y")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      case x do
        :a -> :a
        :b -> :b
      end
      """)
    end
  end
end
