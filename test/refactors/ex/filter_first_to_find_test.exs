defmodule Number42.Refactors.Ex.FilterFirstToFindTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.FilterFirstToFind

  @subject FilterFirstToFind

  describe "rewrites" do
    test "pipe chain into List.first re-threads onto the pipe" do
      assert_rewrites(
        @subject,
        "coll |> Enum.filter(fn x -> x.active end) |> List.first()",
        "coll |> Enum.find(fn x -> x.active end)"
      )
    end

    test "pipe chain into Enum.at(0) re-threads onto the pipe" do
      assert_rewrites(
        @subject,
        "coll |> Enum.filter(fn x -> x.active end) |> Enum.at(0)",
        "coll |> Enum.find(fn x -> x.active end)"
      )
    end

    test "half-piped filter call into List.first keeps the call shape" do
      assert_rewrites(
        @subject,
        "Enum.filter(coll, &(&1 > 3)) |> List.first()",
        "Enum.find(coll, &(&1 > 3))"
      )
    end

    test "half-piped filter call into Enum.at(0) keeps the call shape" do
      assert_rewrites(
        @subject,
        "Enum.filter(coll, &(&1 > 3)) |> Enum.at(0)",
        "Enum.find(coll, &(&1 > 3))"
      )
    end

    test "nested call form List.first(Enum.filter(...))" do
      assert_rewrites(
        @subject,
        "List.first(Enum.filter(coll, pred))",
        "Enum.find(coll, pred)"
      )
    end

    test "nested call form Enum.at(Enum.filter(...), 0)" do
      assert_rewrites(
        @subject,
        "Enum.at(Enum.filter(coll, pred), 0)",
        "Enum.find(coll, pred)"
      )
    end

    test "capture predicate is preserved verbatim" do
      assert_rewrites(
        @subject,
        "coll |> Enum.filter(&match?(%{ok: true}, &1)) |> List.first()",
        "coll |> Enum.find(&match?(%{ok: true}, &1))"
      )
    end

    test "multi-stage pipe re-threads onto the chain" do
      assert_rewrites(
        @subject,
        "rows |> Enum.map(& &1.user) |> Enum.filter(& &1.admin) |> List.first()",
        "rows |> Enum.map(& &1.user) |> Enum.find(& &1.admin)"
      )
    end
  end

  describe "leaves alone" do
    test "Enum.at with a non-zero index" do
      assert_unchanged(@subject, "coll |> Enum.filter(pred) |> Enum.at(2)")
    end

    test "nested Enum.at call with a non-zero index" do
      assert_unchanged(@subject, "Enum.at(Enum.filter(coll, pred), 1)")
    end

    test "List.first with a non-nil default" do
      assert_unchanged(@subject, "Enum.filter(coll, pred) |> List.first(:none)")
    end

    test "nested List.first call with a default" do
      assert_unchanged(@subject, "List.first(Enum.filter(coll, pred), :none)")
    end

    test "already Enum.find" do
      assert_unchanged(@subject, "Enum.find(coll, pred)")
    end

    test "filter piped into something other than first/at" do
      assert_unchanged(@subject, "coll |> Enum.filter(pred) |> Enum.count()")
    end

    test "List.first without an upstream Enum.filter" do
      assert_unchanged(@subject, "List.first(list)")
    end

    test "hd is not equivalent and is left alone" do
      assert_unchanged(@subject, "coll |> Enum.filter(pred) |> hd()")
    end

    test "impure predicate doing IO is skipped" do
      assert_unchanged(
        @subject,
        "coll |> Enum.filter(fn x -> IO.inspect(x); x.ok end) |> List.first()"
      )
    end

    test "impure predicate sending a message is skipped" do
      assert_unchanged(
        @subject,
        "coll |> Enum.filter(fn x -> send(self(), x); true end) |> List.first()"
      )
    end

    test "predicate that raises is skipped" do
      assert_unchanged(
        @subject,
        "coll |> Enum.filter(fn x -> if x.bad, do: raise(\"no\"); x.ok end) |> List.first()"
      )
    end

    test "Enum.filter at the wrong arity is left alone" do
      assert_unchanged(@subject, "Enum.filter(coll) |> List.first()")
    end

    test "aliased non-stdlib Enum/List" do
      assert_unchanged(@subject, "coll |> MyEnum.filter(pred) |> MyList.first()")
    end
  end

  describe "idempotent" do
    test "running twice equals running once (pipe form)" do
      assert_idempotent(@subject, "coll |> Enum.filter(fn x -> x.active end) |> List.first()")
    end

    test "running twice equals running once (nested call form)" do
      assert_idempotent(@subject, "List.first(Enum.filter(coll, pred))")
    end
  end
end
