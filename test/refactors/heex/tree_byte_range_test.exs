defmodule Number42.Refactors.Heex.TreeByteRangeTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Heex.Tree

  describe "node_byte_range/2 for elements" do
    test "returns the byte range of an element node within its body" do
      body = ~s(<div>\n  <span class="x">hi</span>\n</div>\n)
      {:ok, [{:element, "div", _, [span], _}]} = Tree.parse_body(body)

      {start_byte, end_byte} = Tree.node_byte_range(span, body)

      assert binary_part(body, start_byte, end_byte - start_byte) ==
               ~s(<span class="x">hi</span>)
    end

    test "self-closing tag range covers from `<` through `/>`" do
      body = ~s(<.icon name="x" class="y" />)
      {:ok, [icon]} = Tree.parse_body(body)
      {s, e} = Tree.node_byte_range(icon, body)
      assert binary_part(body, s, e - s) == String.trim(body)
    end

    test "outer element range covers nested children too" do
      body = ~s(<div>\n  <span>{@x}</span>\n  <p>{@y}</p>\n</div>\n)
      {:ok, [div]} = Tree.parse_body(body)
      {s, e} = Tree.node_byte_range(div, body)
      slice = binary_part(body, s, e - s)
      assert String.starts_with?(slice, "<div>")
      assert String.ends_with?(slice, "</div>")
    end
  end

  describe "node_byte_range/2 for eex nodes" do
    test "covers an eex_expr `{...}` interpolation" do
      body = ~s(<span>{@title}</span>)
      {:ok, [{:element, "span", _, [expr], _}]} = Tree.parse_body(body)
      {s, e} = Tree.node_byte_range(expr, body)
      assert binary_part(body, s, e - s) == "{@title}"
    end
  end
end
