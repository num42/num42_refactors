defmodule Number42.Refactors.CssClassCooccurrenceTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.CssClassCooccurrence, as: Coocc

  defp wrap(body) do
    """
    defmodule Demo do
      use Phoenix.Component

      def render(assigns) do
        ~H\"\"\"
    #{body}
        \"\"\"
      end
    end
    """
  end

  describe "class_sites/1 (Slice 1 — collect class token sets per element)" do
    test "extracts the token set from a single static class attribute" do
      source = wrap(~s|    <div class="mt1 pb2 text-hase">hi</div>|)

      assert [%{classes: classes}] = Coocc.class_sites(source)
      assert classes == MapSet.new([:mt1, :pb2, :"text-hase"])
    end

    test "collects one site per element with a static class" do
      source =
        wrap("""
            <div class="card shadow">
              <span class="red bold">x</span>
            </div>
        """)

      sets = source |> Coocc.class_sites() |> Enum.map(& &1.classes)
      assert MapSet.new([:card, :shadow]) in sets
      assert MapSet.new([:red, :bold]) in sets
    end

    test "ignores dynamic class={expr} attributes" do
      source = wrap(~s|    <div class={@dynamic}>x</div>|)
      assert Coocc.class_sites(source) == []
    end

    test "is order- and duplicate-insensitive (a set, not a list)" do
      a = wrap(~s|    <div class="pb2 mt1 pb2">x</div>|) |> Coocc.class_sites()
      b = wrap(~s|    <div class="mt1 pb2">x</div>|) |> Coocc.class_sites()
      assert hd(a).classes == hd(b).classes
    end

    test "returns [] for a source with no parseable sigil" do
      assert Coocc.class_sites("defmodule Plain do\n  def x, do: 1\nend\n") == []
    end
  end

  describe "tuple_weights/2 (Slice 2 — co-occurrence statistics)" do
    test "same-element pairs score 1.0 each" do
      source = wrap(~s|    <div class="mt1 pb2 text-hase">x</div>|)
      weights = Coocc.tuple_weights([{"a.ex", source}])

      assert weights[{:mt1, :pb2}] == 1.0
      assert weights[{:mt1, :"text-hase"}] == 1.0
      assert weights[{:pb2, :"text-hase"}] == 1.0
    end

    test "pairs are alphabetically sorted so {:a,:b} and {:b,:a} collapse" do
      source = wrap(~s|    <div class="zebra alpha">x</div>|)
      weights = Coocc.tuple_weights([{"a.ex", source}])

      assert Map.has_key?(weights, {:alpha, :zebra})
      refute Map.has_key?(weights, {:zebra, :alpha})
    end

    test "direct parent↔child co-occurrence scores 0.5" do
      source =
        wrap("""
            <div class="card">
              <span class="red">x</span>
            </div>
        """)

      weights = Coocc.tuple_weights([{"a.ex", source}])
      assert weights[{:card, :red}] == 0.5
    end

    test "weights accumulate across the corpus" do
      one = wrap(~s|    <div class="mt1 pb2">x</div>|)
      weights = Coocc.tuple_weights([{"a.ex", one}, {"b.ex", one}])
      assert weights[{:mt1, :pb2}] == 2.0
    end
  end

  describe "clusters/1 (Slice 2 — dominant exact class sets)" do
    test "support counts exact repeated class sets, strongest first" do
      sites =
        1..3
        |> Enum.map(fn _ -> wrap(~s|    <div class="mt1 pb2 gap2">x</div>|) end)
        |> Enum.flat_map(&Coocc.class_sites/1)

      one_off = wrap(~s|    <div class="mt1 pb3 gap2">x</div>|) |> Coocc.class_sites()

      clusters = Coocc.clusters(sites ++ one_off)
      assert [%{classes: top, support: 3} | _] = clusters
      assert top == MapSet.new([:mt1, :pb2, :gap2])
    end

    test "ignores single-token sets (no internal convention to deviate from)" do
      sites = wrap(~s|    <div class="solo">x</div>|) |> Coocc.class_sites()
      assert Coocc.clusters(sites) == []
    end
  end
end
