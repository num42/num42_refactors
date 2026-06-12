defmodule Number42.Refactors.Ex.EnumFindToKeyfindTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.EnumFindToKeyfind

  @subject EnumFindToKeyfind

  describe "rewrites" do
    test "2-tuple destructure on position 0" do
      assert_rewrites(
        @subject,
        "Enum.find(list, fn {k, _} -> k == key end)",
        "List.keyfind(list, key, 0)"
      )
    end

    test "2-tuple destructure on position 1" do
      assert_rewrites(
        @subject,
        "Enum.find(list, fn {_, v} -> v == target end)",
        "List.keyfind(list, target, 1)"
      )
    end

    test "3-tuple destructure" do
      assert_rewrites(
        @subject,
        "Enum.find(children, fn {t, _, _} -> t == :price end)",
        "List.keyfind(children, :price, 0)"
      )
    end

    test "named underscore wildcards count as wildcards" do
      assert_rewrites(
        @subject,
        "Enum.find(tree, fn {p, _depth} -> p == target end)",
        "List.keyfind(tree, target, 0)"
      )
    end

    test "elem form with literal position" do
      assert_rewrites(
        @subject,
        "Enum.find(list, fn tuple -> elem(tuple, 1) == x end)",
        "List.keyfind(list, x, 1)"
      )
    end

    test "flipped comparison" do
      assert_rewrites(
        @subject,
        "Enum.find(list, fn {k, _} -> key == k end)",
        "List.keyfind(list, key, 0)"
      )
    end

    test "pipe form re-threads onto the chain" do
      assert_rewrites(
        @subject,
        "grouped |> Enum.find(fn {t, _} -> t == type end)",
        "grouped |> List.keyfind(type, 0)"
      )
    end

    test "multi-stage pipe keeps the chain" do
      assert_rewrites(
        @subject,
        "results |> group() |> Enum.find(fn {t, _} -> t == :assets end)",
        "results |> group() |> List.keyfind(:assets, 0)"
      )
    end
  end

  describe "leaves alone" do
    test "strict === comparison has different equality" do
      assert_unchanged(@subject, "Enum.find(list, fn {k, _} -> k === key end)")
    end

    test "field access on the bound element" do
      assert_unchanged(@subject, "Enum.find(tree, fn {p, _} -> p.id == pid end)")
    end

    test "key referencing the lambda param" do
      assert_unchanged(@subject, "Enum.find(list, fn t -> elem(t, 0) == elem(t, 1) end)")
    end

    test "multi-condition body" do
      assert_unchanged(@subject, "Enum.find(list, fn {k, _} -> k == key and k != nil end)")
    end

    test "second tuple element bound, not wildcard" do
      assert_unchanged(@subject, "Enum.find(list, fn {k, v} -> k == v end)")
    end

    test "guarded lambda clause" do
      assert_unchanged(@subject, "Enum.find(list, fn {k, _} when is_atom(k) -> k == key end)")
    end

    test "Enum.find/3 with explicit default" do
      assert_unchanged(@subject, "Enum.find(list, :none, fn {k, _} -> k == key end)")
    end

    test "non-comparison predicate" do
      assert_unchanged(@subject, "Enum.find(list, fn {p, _} -> String.starts_with?(t, p) end)")
    end

    test "already List.keyfind" do
      assert_unchanged(@subject, "List.keyfind(list, key, 0)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "Enum.find(list, fn {k, _} -> k == key end)")
    end
  end
end
