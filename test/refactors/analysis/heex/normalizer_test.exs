defmodule Number42.Refactors.Analysis.Heex.NormalizerTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Analysis.Heex.Normalizer
  alias Number42.Refactors.Analysis.Heex.Tree

  defp parse!(body) do
    {:ok, tree} = Tree.parse_body(body)
    tree
  end

  describe ":exact mode" do
    test "two identical bodies normalize to the same term" do
      a = parse!(~s(<div class="x"><span>{@name}</span></div>))
      b = parse!(~s(<div class="x"><span>{@name}</span></div>))

      assert Normalizer.normalize(a, :exact) == Normalizer.normalize(b, :exact)
    end

    test "different class values diverge" do
      a = parse!(~s(<div class="a"><span>x</span></div>))
      b = parse!(~s(<div class="b"><span>x</span></div>))

      refute Normalizer.normalize(a, :exact) == Normalizer.normalize(b, :exact)
    end

    test "drops line metadata so position differences don't matter" do
      # Same content, but at different absolute positions in their host
      # string — line meta on the underlying nodes would differ.
      a = parse!(~s(<div>x</div>))

      with_padding = parse!("\n\n" <> ~s(<div>x</div>))

      assert Normalizer.normalize(a, :exact) == Normalizer.normalize(with_padding, :exact)
    end
  end

  describe ":class_stripped mode" do
    test "different classes hash equal" do
      a = parse!(~s(<div class="bg-red-500 p-4"><span>x</span></div>))
      b = parse!(~s(<div class="bg-blue-300 p-2"><span>x</span></div>))

      assert Normalizer.normalize(a, :class_stripped) ==
               Normalizer.normalize(b, :class_stripped)
    end

    test "non-class attribute differences still diverge" do
      a = parse!(~s(<div class="x" id="a">y</div>))
      b = parse!(~s(<div class="y" id="b">y</div>))

      refute Normalizer.normalize(a, :class_stripped) ==
               Normalizer.normalize(b, :class_stripped)
    end

    test ":class= dynamic class is treated like class" do
      a = parse!(~s(<div class={@cls}>x</div>))
      b = parse!(~s(<div class="static">x</div>))

      assert Normalizer.normalize(a, :class_stripped) ==
               Normalizer.normalize(b, :class_stripped)
    end
  end

  describe ":attrs_stripped mode" do
    test "different attribute sets hash equal" do
      a = parse!(~s(<button phx-click="a" class="x">go</button>))
      b = parse!(~s(<button phx-click="b">go</button>))

      assert Normalizer.normalize(a, :attrs_stripped) ==
               Normalizer.normalize(b, :attrs_stripped)
    end

    test "tag name differences still diverge" do
      a = parse!(~s(<button class="x">go</button>))
      b = parse!(~s(<a class="x">go</a>))

      refute Normalizer.normalize(a, :attrs_stripped) ==
               Normalizer.normalize(b, :attrs_stripped)
    end

    test "child structure differences still diverge" do
      a = parse!(~s(<div><span>x</span></div>))
      b = parse!(~s(<div><span>x</span><span>y</span></div>))

      refute Normalizer.normalize(a, :attrs_stripped) ==
               Normalizer.normalize(b, :attrs_stripped)
    end
  end

  describe "EEx normalization" do
    test "whitespace inside expression is collapsed" do
      a = parse!("<%= @x  +  1 %>")
      b = parse!("<%= @x + 1 %>")

      assert Normalizer.normalize(a, :exact) == Normalizer.normalize(b, :exact)
    end
  end
end
