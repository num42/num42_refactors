defmodule Number42.Refactors.Analysis.Heex.TreeDiffTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Analysis.Heex.TreeDiff

  # Normalized nodes (the plain-tuple shape Normalizer.normalize/2 produces).
  # We hand-build them here to test the distance/diff math in isolation.

  defp el(tag, attrs \\ [], children \\ []), do: {:element, tag, attrs, children}
  defp txt(s), do: {:text, s}
  defp expr(c), do: {:eex_expr, c}
  defp block(h, children \\ []), do: {:eex_block, h, children}
  defp class(v), do: {"class", {:string, v}}

  describe "distance/2 — identical trees" do
    test "a leaf equals itself at distance 0" do
      assert TreeDiff.distance(txt("hi"), txt("hi")) == 0
    end

    test "a nested tree equals itself at distance 0" do
      tree = el("div", [class("a")], [el("span", [], [txt("x")]), expr("@y")])
      assert TreeDiff.distance(tree, tree) == 0
    end
  end

  describe "distance/2 — single relabels" do
    test "one differing text node costs 1" do
      a = el("div", [], [txt("Dokumentationsbilder")])
      b = el("div", [], [txt("Bilder")])
      assert TreeDiff.distance(a, b) == 1
    end

    test "a tag-only difference costs 1" do
      assert TreeDiff.distance(el("div"), el("section")) == 1
    end

    test "a class-only difference costs 1" do
      a = el("div", [class("py-3")])
      b = el("div", [class("px-2 py-2")])
      assert TreeDiff.distance(a, b) == 1
    end

    test "tag AND attrs differing on one element costs 2" do
      a = el("div", [class("py-3")])
      b = el("section", [class("px-2 py-2")])
      assert TreeDiff.distance(a, b) == 2
    end
  end

  describe "distance/2 — structural edits" do
    test "an extra child subtree costs its mass (insert)" do
      a = el("ul", [], [el("li", [], [txt("a")])])
      b = el("ul", [], [el("li", [], [txt("a")]), el("li", [], [txt("b")])])
      # inserting <li><text> = 2 nodes
      assert TreeDiff.distance(a, b) == 2
    end

    test "a kind change (text vs element) costs 1 relabel" do
      assert TreeDiff.distance(txt("x"), el("span")) == 1
    end
  end

  describe "similarity/2" do
    test "identical trees score 1.0" do
      tree = el("div", [], [txt("x")])
      assert TreeDiff.similarity(tree, tree) == 1.0
    end

    test "the brand_item target shape lands >= 0.85" do
      # ~root + heading + a list of 30ish nodes; we approximate with a tree
      # whose mass is 30 and exactly 3 edits (tag, class, one text).
      kids = for i <- 1..27, do: el("li", [class("c#{i}")], [txt("row#{i}")])
      a = el("div", [class("py-3")], [el("h2", [], [txt("Dokumentationsbilder")]) | kids])
      b = el("section", [class("px-2 py-2")], [el("h2", [], [txt("Bilder")]) | kids])

      sim = TreeDiff.similarity(a, b)
      assert sim >= 0.85
      assert sim < 1.0
    end

    test "similarity never goes negative" do
      a = el("div", [], [txt("a")])
      b = el("section", [], [el("span", [], [expr("@x")]), block("if @y do")])
      assert TreeDiff.similarity(a, b) >= 0.0
    end
  end

  describe "diff/2 — divergence descriptor" do
    test "identical trees produce no divergence" do
      tree = el("div", [], [txt("x")])
      assert TreeDiff.diff(tree, tree) == []
    end

    test "a text relabel at the root's child is reported with its path" do
      a = el("div", [], [txt("Dokumentationsbilder")])
      b = el("div", [], [txt("Bilder")])
      assert TreeDiff.diff(a, b) == [{:text, [0], "Dokumentationsbilder", "Bilder"}]
    end

    test "a root tag + class divergence reports both kinds at the root path" do
      a = el("div", [class("py-3")])
      b = el("section", [class("px-2 py-2")])

      diffs = TreeDiff.diff(a, b)
      assert {:tag, [], "div", "section"} in diffs

      assert {:attr_value, [], "class", {:string, "py-3"}, {:string, "px-2 py-2"}} in diffs
    end

    test "the brand_item target produces exactly tag + attr_value(class) + text" do
      kids = for i <- 1..5, do: el("li", [class("c#{i}")], [txt("row#{i}")])
      a = el("div", [class("py-3")], [el("h2", [], [txt("Dokumentationsbilder")]) | kids])
      b = el("section", [class("px-2 py-2")], [el("h2", [], [txt("Bilder")]) | kids])

      diffs = TreeDiff.diff(a, b)

      assert {:tag, [], "div", "section"} in diffs
      assert {:attr_value, [], "class", {:string, "py-3"}, {:string, "px-2 py-2"}} in diffs
      assert {:text, [0, 0], "Dokumentationsbilder", "Bilder"} in diffs
      # nothing structural
      refute Enum.any?(diffs, &match?({:structural, _, _}, &1))
      assert length(diffs) == 3
    end

    test "an inserted child subtree is reported as structural" do
      a = el("ul", [], [el("li", [], [txt("a")])])
      b = el("ul", [], [el("li", [], [txt("a")]), el("li", [], [txt("b")])])

      diffs = TreeDiff.diff(a, b)
      assert Enum.any?(diffs, &match?({:structural, _, :insert}, &1))
    end

    test "a kind change is reported as structural" do
      a = el("div", [], [txt("x")])
      b = el("div", [], [el("span")])
      diffs = TreeDiff.diff(a, b)
      assert Enum.any?(diffs, &match?({:structural, _, :kind_change}, &1))
    end

    test "a differing eex_block header is structural (not a soft kind)" do
      a = el("div", [], [block("if @a do", [txt("x")])])
      b = el("div", [], [block("if @b do", [txt("x")])])
      diffs = TreeDiff.diff(a, b)
      assert Enum.any?(diffs, &match?({:structural, _, :kind_change}, &1))
    end

    test "a differing eex_expr is structural" do
      a = el("div", [], [expr("@a")])
      b = el("div", [], [expr("@b")])
      diffs = TreeDiff.diff(a, b)
      assert Enum.any?(diffs, &match?({:structural, _, :kind_change}, &1))
    end
  end
end
