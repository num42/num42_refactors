defmodule Number42.Refactors.Analysis.Heex.MotifTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Analysis.Heex.Motif
  alias Number42.Refactors.Analysis.Heex.Tree

  defp parse!(body) do
    {:ok, tree} = Tree.parse_body(body)
    tree
  end

  defp node!(body) do
    [node] = parse!(body)
    node
  end

  describe "key/1 — assign- and text-agnostic structural key" do
    test "two subtrees differing only in assign names hash equal" do
      a = node!(~s(<article><h2>{@title}</h2><p>{@body}</p></article>))
      b = node!(~s(<article><h2>{@name}</h2><p>{@description}</p></article>))

      assert Motif.key(a) == Motif.key(b)
    end

    test "two subtrees differing only in literal text hash equal" do
      a = node!(~s(<article><h2>{@t}</h2><p>Hello world here</p></article>))
      b = node!(~s(<article><h2>{@t}</h2><p>Goodbye cruel world</p></article>))

      assert Motif.key(a) == Motif.key(b)
    end

    test "different tag structure hashes differently" do
      a = node!(~s(<article><h2>{@t}</h2><p>{@b}</p></article>))
      b = node!(~s(<section><h2>{@t}</h2><p>{@b}</p></section>))

      refute Motif.key(a) == Motif.key(b)
    end

    test "a dynamic slot vs a static slot in the same position hash differently" do
      dynamic = node!(~s(<article><h2>{@t}</h2></article>))
      static = node!(~s(<article><h2>Fixed Title</h2></article>))

      refute Motif.key(dynamic) == Motif.key(static)
    end

    test "differing attribute *values* still hash equal (attrs are part of the seam, not the skeleton)" do
      a = node!(~s(<button phx-click="save" class="a">{@label}</button>))
      b = node!(~s(<button phx-click="cancel" class="b">{@label}</button>))

      assert Motif.key(a) == Motif.key(b)
    end

    test "differing attribute *names* hash differently" do
      a = node!(~s(<button phx-click="x">{@label}</button>))
      b = node!(~s(<button id="x">{@label}</button>))

      refute Motif.key(a) == Motif.key(b)
    end
  end

  describe "slots/1 — positional dynamic slots" do
    test "lists each dynamic EEx expression with its assign references in tree order" do
      node = node!(~s(<article><h2>{@title}</h2><p>{@body}</p></article>))

      assert Motif.slots(node) == [
               %{kind: :expr, assigns: ["title"], code: "@title"},
               %{kind: :expr, assigns: ["body"], code: "@body"}
             ]
    end

    test "treats literal text as a static (non-slot) leaf" do
      node = node!(~s(<article><h2>{@title}</h2><p>fixed</p></article>))

      assert Motif.slots(node) == [%{kind: :expr, assigns: ["title"], code: "@title"}]
    end
  end
end
