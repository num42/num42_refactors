defmodule Number42.Refactors.Analysis.Heex.TreeTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Analysis.Heex.Tree

  describe "parse_body/1 attribute names" do
    test "keeps a trailing ? in an attribute name" do
      assert {:ok, [{:element, ".w", attrs, _children, _meta}]} =
               Tree.parse_body(~S|<.w back?={@x} />|)

      assert attrs == [{"back?", {:expr, "@x"}}]
    end

    test "keeps a trailing ! in an attribute name" do
      assert {:ok, [{:element, ".w", attrs, _children, _meta}]} =
               Tree.parse_body(~S|<.w reload!={@y} />|)

      assert attrs == [{"reload!", {:expr, "@y"}}]
    end

    test "a ?-suffixed attribute does not break the rest of the tag" do
      assert {:ok, [{:element, ".w", attrs, _children, _meta}]} =
               Tree.parse_body(~S|<.w back?={@x} label="hi" />|)

      assert attrs == [{"back?", {:expr, "@x"}}, {"label", {:string, "hi"}}]
    end
  end

  describe "parse_body/1 tag names" do
    test "keeps a trailing ? in a component tag name" do
      assert {:ok, [{:element, "Mod.shown?", _attrs, _children, _meta}]} =
               Tree.parse_body(~S|<Mod.shown? x={@a} />|)
    end
  end
end
