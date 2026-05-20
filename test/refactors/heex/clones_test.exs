defmodule Num42.Refactors.Heex.ClonesTest do
  use ExUnit.Case, async: true

  alias Num42.Refactors.Heex.Clones

  defp wrap(body),
    do: """
    defmodule Demo do
      def render(assigns) do
        ~H\"\"\"
        #{body}
        \"\"\"
      end
    end
    """

  describe "from_sources/2" do
    test "groups identical sigil bodies across files into a cluster" do
      pairs = [
        {"a.ex", wrap(~s(<article><h2>{@title}</h2><p>{@body}</p></article>))},
        {"b.ex", wrap(~s(<article><h2>{@title}</h2><p>{@body}</p></article>))}
      ]

      result = Clones.from_sources(pairs, min_mass: 4)

      [cluster] = result[:exact]
      assert length(cluster.occurrences) == 2

      files = cluster.occurrences |> Enum.map(& &1.file) |> Enum.sort()
      assert files == ["a.ex", "b.ex"]
    end

    test ":class_stripped finds clones that :exact misses" do
      pairs = [
        {"a.ex", wrap(~s(<div class="bg-red"><span>{@x}</span></div>))},
        {"b.ex", wrap(~s(<div class="bg-blue"><span>{@x}</span></div>))}
      ]

      result = Clones.from_sources(pairs, min_mass: 3)

      assert result[:exact] == []
      assert [%{occurrences: occ}] = result[:class_stripped]
      assert length(occ) == 2
    end

    test ":attrs_stripped finds parametric clones with diverging attrs" do
      pairs = [
        {"a.ex", wrap(~s(<button phx-click="a" id="x">{@label}</button>))},
        {"b.ex", wrap(~s(<button phx-click="b" id="y">{@label}</button>))}
      ]

      result = Clones.from_sources(pairs, min_mass: 2)

      assert result[:exact] == []

      assert [%{mode: :attrs_stripped, occurrences: occ}] =
               result[:attrs_stripped]
               |> Enum.filter(&match?({:element, "button", _, _, _}, hd(&1.occurrences).node))

      assert length(occ) == 2
    end

    test "respects min_occurrences" do
      pairs = [
        {"a.ex", wrap(~s(<div><span>{@x}</span></div>))}
      ]

      result = Clones.from_sources(pairs, min_mass: 2, min_occurrences: 2)

      assert result == %{attrs_stripped: [], class_stripped: [], exact: []}
    end

    test "drops a smaller cluster when its occurrences are fully contained in a larger one" do
      pairs = [
        {"a.ex", wrap(~s(<article><h2>{@t}</h2><p>{@b}</p></article>))},
        {"b.ex", wrap(~s(<article><h2>{@t}</h2><p>{@b}</p></article>))}
      ]

      result = Clones.from_sources(pairs, min_mass: 2)

      # Only the largest matching unit should survive in :exact, even
      # though the inner h2/p structures also clone identically.
      [outer] = result[:exact]
      assert match?({:element, "article", _, _, _}, hd(outer.occurrences).node)
    end
  end
end
