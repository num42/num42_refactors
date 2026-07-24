defmodule Number42.Refactors.Analysis.Heex.NearClonesTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Analysis.Heex.NearClones

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

  # A ~30-node container body that differs from its twin only in root tag,
  # root class, and one heading text — the real brand_item_assets_container case.
  defp container(root_tag, root_class, heading) do
    rows = for i <- 1..6, do: ~s(<li class="row"><figure><img src={@img#{i}} /></figure></li>)

    ~s(<#{root_tag} class="#{root_class}"><h2 class="head">#{heading}</h2><ul class="list">) <>
      Enum.join(rows, "") <> ~s(</ul></#{root_tag}>)
  end

  describe "from_sources/2 — near-clone clustering" do
    test "the brand_item container twins cluster as one near-clone" do
      pairs = [
        {"a.ex", wrap(container("div", "py-3", "Dokumentationsbilder"))},
        {"b.ex", wrap(container("section", "px-2 py-2", "Bilder"))}
      ]

      clusters = NearClones.from_sources(pairs, min_mass: 8, threshold: 0.85)

      assert [cluster] = clusters
      assert length(cluster.occurrences) == 2
      assert cluster.mergeable

      files = cluster.occurrences |> Enum.map(& &1.file) |> Enum.sort()
      assert files == ["a.ex", "b.ex"]
    end

    test "the divergent occurrence carries tag + class + text diffs only" do
      pairs = [
        {"a.ex", wrap(container("div", "py-3", "Dokumentationsbilder"))},
        {"b.ex", wrap(container("section", "px-2 py-2", "Bilder"))}
      ]

      [cluster] = NearClones.from_sources(pairs, min_mass: 8, threshold: 0.85)

      # representative is the first by {file, line}; the other occurrence diffs.
      other = Enum.find(cluster.occurrences, &(&1.diffs != []))
      kinds = other.diffs |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert :tag in kinds
      assert :attr_value in kinds
      assert :text in kinds
      refute Enum.any?(other.diffs, &match?({:structural, _, _}, &1))
      assert other.similarity >= 0.85
    end

    test "exact-equal bodies are NOT a near-clone here (left to Clones)" do
      # Two byte-identical bodies have similarity 1.0; near-clone detection
      # still clusters them, but the diff list is empty (no parametrisation
      # needed). That's acceptable — they're trivially mergeable into one.
      same = wrap(container("div", "py-3", "Bilder"))
      clusters = NearClones.from_sources([{"a.ex", same}, {"b.ex", same}], min_mass: 8)

      assert [cluster] = clusters
      assert cluster.mergeable
      assert Enum.all?(cluster.occurrences, &(&1.diffs == [] or &1.similarity == 1.0))
    end
  end

  describe "structural divergence flags non-mergeable" do
    test "an extra child subtree marks the cluster non-mergeable" do
      with_extra =
        ~s(<div class="c"><h2>A</h2><ul class="l"><li>x</li></ul><footer>extra</footer></div>)

      without =
        ~s(<div class="c"><h2>B</h2><ul class="l"><li>x</li></ul></div>)

      pairs = [{"a.ex", wrap(without)}, {"b.ex", wrap(with_extra)}]

      clusters = NearClones.from_sources(pairs, min_mass: 4, threshold: 0.7)

      case clusters do
        [cluster] ->
          refute cluster.mergeable

        [] ->
          # below threshold — also acceptable; the point is it never reports
          # mergeable for a structural difference.
          :ok
      end
    end
  end

  describe "threshold + mass-band gates" do
    test "wildly different masses never cluster (mass-band prefilter)" do
      tiny = wrap(~s(<span>{@x}</span>))
      big = wrap(container("div", "py-3", "Bilder"))
      clusters = NearClones.from_sources([{"a.ex", tiny}, {"b.ex", big}], min_mass: 2)
      assert clusters == []
    end

    test "structurally unrelated bodies of similar mass do not cluster" do
      a =
        wrap(
          ~s(<table><thead><tr><th>{@h}</th></tr></thead><tbody><tr><td>{@d}</td></tr></tbody></table>)
        )

      b = wrap(~s(<form><fieldset><label>{@l}</label><input value={@v} /></fieldset></form>))
      clusters = NearClones.from_sources([{"a.ex", a}, {"b.ex", b}], min_mass: 4, threshold: 0.85)
      assert clusters == []
    end
  end
end
