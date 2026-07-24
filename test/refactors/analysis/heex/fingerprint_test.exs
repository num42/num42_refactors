defmodule Number42.Refactors.Analysis.Heex.FingerprintTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Analysis.Heex.Fingerprint
  alias Number42.Refactors.Analysis.Heex.Tree

  defp parse!(body) do
    {:ok, tree} = Tree.parse_body(body)
    tree
  end

  describe "mass/1" do
    test "counts every element, eex node and text node" do
      [div] = parse!(~s(<div><span>{@a}</span></div>))
      assert Fingerprint.mass(div) == 3
    end

    test "ignores attributes for mass" do
      [a] = parse!(~s(<div class="big" id="x" phx-click="go">a</div>))
      [b] = parse!(~s(<div>a</div>))

      assert Fingerprint.mass(a) == Fingerprint.mass(b)
    end

    test "counts EEx blocks and their children" do
      [_ul] =
        tree =
        parse!("""
        <ul>
          <%= for x <- @xs do %>
            <li>{x}</li>
          <% end %>
        </ul>
        """)

      # ul + eex_block + li + eex_expr = 4
      assert Fingerprint.mass(tree) == 4
    end
  end

  describe "fragments/3" do
    test "filters subtrees below min_mass" do
      tree = parse!(~s(<div><span>x</span></div>))

      large = Fingerprint.fragments(tree, "f.ex", min_mass: 100, modes: [:exact])
      assert large == []
    end

    test "emits one fragment per requested mode for each qualifying subtree" do
      tree = parse!(~s(<div class="x"><span>hello</span><span>world</span></div>))

      frags = Fingerprint.fragments(tree, "f.ex", min_mass: 2, modes: [:exact, :class_stripped])

      modes = frags |> Enum.map(& &1.mode) |> Enum.uniq() |> Enum.sort()
      assert modes == [:class_stripped, :exact]
    end

    test "structurally identical subtrees produce the same hash" do
      tree =
        parse!("""
        <div>
          <span class="a">hi</span>
          <span class="b">hi</span>
        </div>
        """)

      frags =
        Fingerprint.fragments(tree, "f.ex", min_mass: 2, modes: [:class_stripped])
        |> Enum.filter(&match?({:element, "span", _, _, _}, &1.node))

      assert length(frags) == 2
      [%{hash: h1}, %{hash: h2}] = frags
      assert h1 == h2
    end

    test "exact mode separates spans whose only difference is class" do
      tree =
        parse!("""
        <div>
          <span class="a">hi</span>
          <span class="b">hi</span>
        </div>
        """)

      frags =
        Fingerprint.fragments(tree, "f.ex", min_mass: 2, modes: [:exact])
        |> Enum.filter(&match?({:element, "span", _, _, _}, &1.node))

      [%{hash: h1}, %{hash: h2}] = frags
      refute h1 == h2
    end

    test "preserves the original tree node and absolute line in fragment" do
      tree = parse!("\n\n<div><span>hi</span></div>")

      [frag | _] =
        Fingerprint.fragments(tree, "myfile.ex", min_mass: 2, modes: [:exact])

      assert frag.file == "myfile.ex"
      assert frag.line >= 1
      assert match?({:element, _, _, _, _}, frag.node)
    end
  end
end
