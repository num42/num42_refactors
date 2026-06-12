defmodule Number42.Refactors.Ex.MemberToInOperatorTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.MemberToInOperator

  @subject MemberToInOperator

  describe "rewrites" do
    test "call form flips the args" do
      assert_rewrites(@subject, "Enum.member?(allowed, role)", "role in allowed")
    end

    test "inside an if condition" do
      assert_rewrites(
        @subject,
        "if Enum.member?(ids, id), do: :found",
        "if id in ids, do: :found"
      )
    end

    test "single-stage pipe form drops the pipe" do
      assert_rewrites(@subject, "allowed |> Enum.member?(role)", "role in allowed")
    end

    test "module attribute as collection" do
      assert_rewrites(
        @subject,
        "if @allowed_extensions |> Enum.member?(ext), do: :ok",
        "if ext in @allowed_extensions, do: :ok"
      )
    end

    test "not-negated call becomes not in" do
      assert_rewrites(@subject, "not Enum.member?(ids, id)", "id not in ids")
    end

    test "bang-negated call becomes not in" do
      assert_rewrites(@subject, "!Enum.member?(ids, id)", "id not in ids")
    end

    test "literal list inside a guard" do
      assert_rewrites(
        @subject,
        "def f(x) when Enum.member?([1, 2, 3], x), do: x",
        "def f(x) when x in [1, 2, 3], do: x"
      )
    end

    test "operator-rooted element gets parenthesized" do
      assert_rewrites(@subject, "Enum.member?(coll, a || b)", "(a || b) in coll")
    end

    test "operator-rooted collection gets parenthesized" do
      assert_rewrites(@subject, "Enum.member?(a || b, x)", "x in (a || b)")
    end
  end

  describe "leaves alone" do
    test "non-literal collection inside a guard" do
      assert_unchanged(@subject, "def f(x, coll) when Enum.member?(coll, x), do: x")
    end

    test "multi-stage pipe keeps its chain" do
      assert_unchanged(
        @subject,
        "modules() |> Enum.filter(&active?/1) |> Enum.member?(__MODULE__)"
      )
    end

    test "already the in operator" do
      assert_unchanged(@subject, "role in allowed")
    end

    test "capture reference has no args to flip" do
      assert_unchanged(@subject, "Enum.zip_with(colls, xs, &Enum.member?/2)")
    end

    test "aliased non-stdlib Enum" do
      assert_unchanged(@subject, "MyEnum.member?(coll, x)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "if Enum.member?(ids, id), do: :found")
    end

    test "conformant code is untouched" do
      assert_idempotent(@subject, "if id in ids, do: :found")
    end
  end
end
