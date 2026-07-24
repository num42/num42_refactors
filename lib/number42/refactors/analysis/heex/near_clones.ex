defmodule Number42.Refactors.Analysis.Heex.NearClones do
  @moduledoc """
  Near-clone detection for HEEx fragments via tree-edit-distance.

  `Heex.Clones` clusters fragments that share a normalized hash in some mode —
  it cannot see two fragments that are the same component hand-written twice
  with small drift (a tag swapped, a class string changed, one heading
  reworded), because such a pair shares no hash in any mode. `NearClones`
  closes that gap: it measures pairwise structural similarity with
  `Heex.TreeDiff` and clusters fragments whose similarity clears a threshold,
  reporting per occurrence *which* nodes diverge and *how*.

  ## Pipeline

      fragments (Fingerprint, :exact mode only)
        -> mass-band prefilter      (a pair too different in size can't clear θ)
        -> pairwise TreeDiff.similarity
        -> single-linkage clusters  (union-find over edges with sim >= θ)
        -> per cluster: pick representative (largest mass), diff each occurrence
        -> emit near_cluster maps, with `mergeable` precomputed

  Only `:exact` fragments are used. Near-clone detection's whole job is to find
  the *small* differences; `:class_stripped`/`:attrs_stripped` pre-erase exactly
  the attr/class drift we want surfaced in the descriptor.

  ## Why single-linkage

  Single-linkage can merge A,B,C transitively even when A and C are not directly
  similar (A~B, B~C, A!~C). That is **safe here** because the cluster is not the
  contract — the per-occurrence diff against the representative is. Every
  occurrence is diffed against one fixed representative, and a transitively-
  pulled-in member that is genuinely structurally different will produce a
  `:structural` divergence in that diff, which sets `mergeable: false`. The
  downstream merge refactor gates on `mergeable`, so a bad transitive member is
  caught at the gate, not silently merged. Single-linkage + representative-diff
  is strictly stronger than complete-linkage's pairwise check, and simpler.

  ## Output

  Each `near_cluster` carries `representative` (file+line), `mass`, a
  `mergeable` boolean (true iff no occurrence diff contains a `:structural`
  divergence), and `occurrences`. Each occurrence keeps the **raw** tree node
  (with meta) so a rewriter can use the diff `path` to locate and edit it.
  """

  alias Number42.Refactors.Analysis.Heex.Fingerprint
  alias Number42.Refactors.Analysis.Heex.Normalizer
  alias Number42.Refactors.Analysis.Heex.Tree
  alias Number42.Refactors.Analysis.Heex.TreeDiff

  @type near_occurrence :: %{
          file: String.t(),
          line: pos_integer(),
          mass: pos_integer(),
          node: Tree.node_t(),
          similarity: float(),
          diffs: [TreeDiff.divergence()]
        }

  @type near_cluster :: %{
          mode: :exact,
          representative: %{file: String.t(), line: pos_integer()},
          mass: pos_integer(),
          mergeable: boolean(),
          occurrences: [near_occurrence()]
        }

  @default_threshold 0.85
  @default_mass_band 0.30
  @default_min_mass 6
  @default_min_occurrences 2

  @doc """
  Read each path, fingerprint its `:exact` fragments, and cluster by near-equality.
  Files that fail to parse contribute nothing.
  """
  @spec from_files([String.t()], keyword()) :: [near_cluster()]
  def from_files(paths, opts \\ []) when is_list(paths) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)

    paths
    |> Task.async_stream(
      fn path ->
        case File.read(path) do
          {:ok, source} -> fragments_for_source(source, path, min_mass)
          {:error, _} -> []
        end
      end,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, frags} -> frags end)
    |> cluster(opts)
  end

  @doc "Cluster across explicit `{path, source}` pairs (test-friendly)."
  @spec from_sources([{String.t(), String.t()}], keyword()) :: [near_cluster()]
  def from_sources(pairs, opts \\ []) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)

    pairs
    |> Enum.flat_map(fn {path, source} -> fragments_for_source(source, path, min_mass) end)
    |> cluster(opts)
  end

  # ---- fragment enumeration (mirrors Clones) -------------------------------

  defp fragments_for_source(source, path, min_mass) do
    case Tree.from_source(source) do
      {:ok, sigils} -> Enum.flat_map(sigils, &sigil_fragments(&1, path, min_mass))
      :error -> []
    end
  end

  defp sigil_fragments(sigil, path, min_mass) do
    sigil.tree
    |> Fingerprint.fragments(path, min_mass: min_mass, modes: [:exact])
    |> Enum.map(&offset_line(&1, sigil.file_line))
    |> Enum.map(&Map.put(&1, :norm, Normalizer.normalize(&1.node, :exact)))
  end

  defp offset_line(frag, 0), do: frag
  defp offset_line(frag, offset), do: %{frag | line: frag.line + offset}

  # ---- clustering ----------------------------------------------------------

  defp cluster(fragments, opts) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    mass_band = Keyword.get(opts, :mass_band, @default_mass_band)
    min_occ = Keyword.get(opts, :min_occurrences, @default_min_occurrences)

    indexed = fragments |> Enum.with_index() |> Enum.map(fn {f, i} -> Map.put(f, :id, i) end)

    edges = similar_pairs(indexed, threshold, mass_band)

    indexed
    |> union_find_groups(edges)
    |> Enum.filter(fn group -> length(group) >= min_occ end)
    |> Enum.map(&build_cluster/1)
    |> drop_subsumed_clusters()
    |> Enum.map(&Map.drop(&1, [:rep_hash, :rep_sub_hashes]))
    |> Enum.sort_by(&(-&1.mass))
  end

  # A near-cluster is subsumed when a larger cluster (more nodes) with at least
  # as many occurrences contains its representative as a descendant. The `<ul>`
  # pair nested inside the clustered `<div>` pair is the same duplication seen
  # one level down — report only the maximal unit. Mirrors
  # `Heex.Clones.drop_subset_clusters/1`.
  defp drop_subsumed_clusters(clusters) do
    sorted = Enum.sort_by(clusters, &(-&1.mass))

    Enum.reject(sorted, fn small ->
      Enum.any?(sorted, fn big ->
        big.rep_hash != small.rep_hash and big.mass > small.mass and
          length(big.occurrences) >= length(small.occurrences) and
          MapSet.member?(big.rep_sub_hashes, small.rep_hash)
      end)
    end)
  end

  # All {id_a, id_b} pairs (a < b) within the mass band whose similarity >= θ,
  # excluding any pair in a containment relation. Fragments are sorted by mass
  # so the inner sweep can stop as soon as the band breaks — masses only grow
  # forward.
  defp similar_pairs(fragments, threshold, mass_band) do
    sorted = Enum.sort_by(fragments, & &1.mass)

    sorted
    |> tails()
    |> Enum.flat_map(fn [f | rest] ->
      rest
      |> Enum.take_while(&mass_compatible?(f, &1, mass_band))
      |> Enum.reject(&contained?(f, &1))
      |> Enum.filter(fn g -> TreeDiff.similarity(f.norm, g.norm) >= threshold end)
      |> Enum.map(fn g -> {f.id, g.id} end)
    end)
  end

  # One fragment nested inside the other (its hash is among the other's
  # descendant hashes), and the two are not the same subtree. Nesting is not
  # cloning: a `<ul>` is structurally "similar" to its enclosing `<div>` only
  # because it IS most of it. Edging the two together would chain a root and its
  # own subtree into one cluster. Equal hashes are exact clones, not nesting —
  # both fragments carry self in their own `sub_hashes`, so guard on inequality.
  defp contained?(%{hash: h}, %{hash: h}), do: false

  defp contained?(%{hash: ha, sub_hashes: sa}, %{hash: hb, sub_hashes: sb}) do
    MapSet.member?(sb, ha) or MapSet.member?(sa, hb)
  end

  defp tails([]), do: []
  defp tails([_ | t] = list), do: [list | tails(t)]

  # A pair can only reach similarity θ if its size gap is within the band —
  # |mass_a - mass_b| forces at least that many ins/del. The band (default 30%)
  # is a safe superset of the tight (1-θ) bound; exact TED still decides.
  defp mass_compatible?(a, b, band) do
    lo = min(a.mass, b.mass)
    hi = max(a.mass, b.mass)
    hi <= lo * (1 + band)
  end

  # Union-find over the edge list, returning the fragment groups.
  defp union_find_groups(fragments, edges) do
    parent = Map.new(fragments, fn f -> {f.id, f.id} end)

    parent =
      Enum.reduce(edges, parent, fn {a, b}, parent ->
        {ra, parent} = find(parent, a)
        {rb, parent} = find(parent, b)
        if ra == rb, do: parent, else: Map.put(parent, ra, rb)
      end)

    fragments
    |> Enum.group_by(fn f -> elem(find(parent, f.id), 0) end)
    |> Map.values()
  end

  defp find(parent, x) do
    case Map.fetch!(parent, x) do
      ^x -> {x, parent}
      p -> with {root, parent} <- find(parent, p), do: {root, Map.put(parent, x, root)}
    end
  end

  # ---- cluster assembly ----------------------------------------------------

  defp build_cluster(frags) do
    rep = Enum.max_by(frags, fn f -> {f.mass, neg_locator(f)} end)

    occurrences =
      frags
      |> Enum.map(fn f -> occurrence(f, rep) end)
      |> Enum.sort_by(&{&1.file, &1.line})

    %{
      mode: :exact,
      representative: %{file: rep.file, line: rep.line},
      mass: rep.mass,
      mergeable: Enum.all?(occurrences, fn o -> not Enum.any?(o.diffs, &structural?/1) end),
      occurrences: occurrences,
      rep_hash: rep.hash,
      rep_sub_hashes: rep.sub_hashes
    }
  end

  # Largest mass wins; ties broken to the earliest {file, line} for determinism.
  defp neg_locator(f), do: {invert(f.file), -f.line}
  defp invert(file), do: for(<<c <- file>>, into: "", do: <<255 - c>>)

  defp occurrence(%{id: id} = f, %{id: rep_id}) when id == rep_id do
    %{file: f.file, line: f.line, mass: f.mass, node: f.node, similarity: 1.0, diffs: []}
  end

  defp occurrence(f, rep) do
    %{
      file: f.file,
      line: f.line,
      mass: f.mass,
      node: f.node,
      similarity: TreeDiff.similarity(rep.norm, f.norm),
      diffs: TreeDiff.diff(rep.norm, f.norm)
    }
  end

  defp structural?({:structural, _, _}), do: true
  defp structural?(_), do: false
end
