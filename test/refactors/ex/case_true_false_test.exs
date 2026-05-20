defmodule Number42.Refactors.Ex.CaseTrueFalseTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.CaseTrueFalse

  @subject CaseTrueFalse

  describe "rewrites" do
    test "case x do true -> a; false -> b end -> if/else" do
      before_source = """
      case x do
        true -> a
        false -> b
      end
      """

      after_source = """
      if x do
        a
      else
        b
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "swapped clause order (false first) still becomes if/else" do
      before_source = """
      case x do
        false -> b
        true -> a
      end
      """

      after_source = """
      if x do
        a
      else
        b
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "leaves alone" do
    test "case with non-boolean clauses" do
      assert_unchanged(@subject, """
      case x do
        :ok -> a
        :err -> b
      end
      """)
    end

    test "case with three clauses (true/false/_)" do
      assert_unchanged(@subject, """
      case x do
        true -> a
        false -> b
        _ -> c
      end
      """)
    end

    test "already an if expression" do
      assert_unchanged(@subject, """
      if x do
        a
      else
        b
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      case x do
        true -> a
        false -> b
      end
      """)
    end
  end
end
