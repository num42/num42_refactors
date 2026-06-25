defmodule Number42.Refactors.Ex.NearClones do
  @moduledoc """
  Near-clone detection for Elixir `def`/`defp` bodies via tree-edit-distance —
  the Elixir analogue of `Heex.NearClones`.

  The exact-hash clone detectors (`ExtractIntraModuleClone`,
  `ExtractExpressionClone`, `DelegateExactDuplicates`, …) cluster two fragments
  only when their normalized hashes match — two functions that are ~90% the same
  but differ in one spot (a different literal threshold, one swapped operator,
  one extra guard) share no hash in any mode, so they never cluster.
  `NearClones` closes that gap: it measures pairwise structural similarity with
  `Ex.TreeDiff` (Zhang-Shasha over the *same* normalized AST the hashers use —
  pipe-sugar inlined, vars α-renamed) and clusters function bodies whose
  similarity clears a threshold, reporting per occurrence *which* nodes diverge
  and *how*.

  This is read-only analysis. It surfaces refactor targets (functions that want
  to be one parametrised helper) and dead-code / copy-paste diagnostics; an
  actual parametrising extract refactor is a separate, default-OFF slice.

  ## Pipeline

      def/defp bodies (one fragment per clause)
        -> drop fragments below :min_mass
        -> mass-band prefilter      (a pair too different in size can't clear θ)
        -> pairwise TreeDiff.similarity
        -> single-linkage clusters  (union-find over edges with sim >= θ)
        -> per cluster: pick representative (largest mass), diff each occurrence
        -> emit near_cluster maps, with `mergeable` precomputed

  ## Why single-linkage

  Same rationale as `Heex.NearClones`: the cluster is not the contract, the
  per-occurrence diff against one fixed representative is. A transitively
  pulled-in member that is genuinely different produces a `:structural`
  divergence in its diff, which sets `mergeable: false`; any downstream
  merge/extract refactor gates on that.

  ## Output

  Each `near_cluster` carries a `representative` (`file`/`line`/`name`/`arity`),
  `mass` (the representative's), `avg_mass` (mean across occurrences), a
  `mergeable` boolean, and `occurrences`. `mergeable` is true iff **both** hold:
  no occurrence diff contains a `:structural` divergence (every divergence is a
  liftable literal / call / var / atom) **and** `avg_mass` clears
  `:min_merge_mass`. The average-mass floor is what stops a trivial one-liner
  that recurs widely (a copy-pasted `{:noreply, assign(socket, …)}` clause) from
  being flagged mergeable — it *is* a clone, detection reports it, but
  extracting a 12-node block into a named helper reads worse than the inline
  expression no matter how often it recurs. Each occurrence keeps the **raw**
  body AST so a rewriter could use the diff `path` to locate and lift the
  divergent node.
  """

  alias Number42.Refactors.AstHelpers
  alias Number42.Refactors.Ex.TreeDiff

  @type near_occurrence :: %{
          file: String.t(),
          line: pos_integer(),
          kind: :def | :defp,
          name: atom(),
          arity: non_neg_integer(),
          mass: pos_integer(),
          ast: Macro.t(),
          def_ast: Macro.t(),
          arg_strings: [String.t()],
          similarity: float(),
          diffs: [TreeDiff.divergence()]
        }

  @type near_cluster :: %{
          representative: %{
            file: String.t(),
            line: pos_integer(),
            name: atom(),
            arity: non_neg_integer()
          },
          mass: pos_integer(),
          avg_mass: float(),
          mergeable: boolean(),
          occurrences: [near_occurrence()]
        }

  @default_threshold 0.85
  @default_mass_band 0.30
  @default_min_mass 10
  @default_min_occurrences 2
  # Average-block-mass floor for the `mergeable` flag. The decisive question for
  # "worth extracting into a named helper?" is the size of the *individual* block,
  # not the total node-count saved across all copies. A trivial one-liner (mass
  # ~12) recurring 16× nets a huge total savings (12·15) — the same as a fat
  # 84-node block recurring 3× (84·2) — yet extracting the one-liner into
  # `helper(socket, changeset)` reads *worse* than the inline expression. So the
  # gate is the **average** occurrence mass (averaged, not the representative's,
  # so a single fat outlier can't drag an otherwise-trivial near-clone over the
  # line). Measured on position-db: the real merge target (`load_window…`, mass
  # 84) clears 40 comfortably; the `notify_…` (12) and `broadcast_…` (13)
  # one-liners fall below — detection still reports them, the merge declines.
  @default_min_merge_mass 40
  # Bodies above this node count are excluded from the pairwise TED. Zhang-Shasha
  # is ~O(m⁴) per pair, so a handful of very large `def`s dominate the whole
  # scan — and a 120+-node function isn't a clean "parametrise into one helper"
  # target anyway. The histogram/mass-band prefilters cut most pairs, this caps
  # the worst case the prefilters can't see (two large, structurally close
  # bodies). Raise per project if large near-clones matter.
  @default_max_mass 120

  @doc """
  Read each path, enumerate its `def`/`defp` bodies, and cluster by near-equality.
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

  # ---- fragment enumeration ------------------------------------------------

  defp fragments_for_source(source, path, min_mass) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> def_fragments(ast, path, min_mass)
      {:error, _} -> []
    end
  end

  # One fragment per `def`/`defp` clause body. The `do`-block body is the unit;
  # `do:`-shorthand and guard-only heads are skipped (no meaningful body tree).
  defp def_fragments(ast, path, min_mass) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&clause_fragment(&1, path))
    |> Enum.filter(&(&1.mass >= min_mass))
  end

  defp clause_fragment({kind, meta, [head, body_kw]} = def_ast, path)
       when kind in [:def, :defp] and is_list(body_kw) do
    with {:ok, body} <- do_body(body_kw),
         {name, arity} <- signature(head) do
      norm = TreeDiff.normalize(body)

      [
        %{
          file: path,
          line: line_of(meta),
          kind: kind,
          name: name,
          arity: arity,
          ast: body,
          def_ast: def_ast,
          arg_strings: arg_strings(head),
          mass: TreeDiff.mass(norm),
          norm: norm,
          labels: label_histogram(norm),
          hash: :erlang.phash2(norm)
        }
      ]
    else
      _ -> []
    end
  end

  defp clause_fragment(_, _), do: []

  # The head's argument patterns rendered as source strings, for a delegation
  # rewrite (`def name(arg0, arg1), do: helper(arg0, arg1, …)`). A guarded head
  # keeps its guard in the delegation.
  defp arg_strings({:when, _, [inner | _]}), do: arg_strings(inner)

  defp arg_strings({_name, _, args}) when is_list(args),
    do: Enum.map(args, &Sourceror.to_string/1)

  defp arg_strings(_), do: []

  # Multiset of node labels (the TED relabel key) in a normalized tree. The
  # half-symmetric-difference of two such histograms is a sound *lower bound* on
  # the tree-edit distance, so it prunes structurally-unrelated pairs before the
  # O(m⁴) Zhang-Shasha ever runs.
  defp label_histogram(node) do
    do_histogram(node, %{})
  end

  defp do_histogram(node, acc) do
    label = node_label(node)
    acc = Map.update(acc, label, 1, &(&1 + 1))
    Enum.reduce(node_children(node), acc, &do_histogram/2)
  end

  defp node_label({:call, form, _}), do: {:call, form}
  defp node_label({:var, idx}), do: {:var, idx}
  defp node_label({:literal, v}), do: {:literal, v}
  defp node_label({:atom, a}), do: {:atom, a}
  defp node_label({kind, _}), do: {kind, nil}

  defp node_children({:call, _, args}), do: args
  defp node_children({:list, items}), do: items
  defp node_children({:pair, items}), do: items
  defp node_children({:tuple, items}), do: items
  defp node_children(_leaf), do: []

  # Sourceror wraps the `do` key as `{:__block__, _, [:do]}` (both for the
  # `do`-block and the `do:`-shorthand form), so a plain `Keyword.fetch(_, :do)`
  # never matches. Unwrap each key and take the `:do` branch — skip `do:`-less
  # clauses (a bodiless `defp foo(x)` head, a `when`-only guard).
  defp do_body(body_kw) do
    Enum.find_value(body_kw, :error, fn {key, value} ->
      if unwrap_key(key) == :do, do: {:ok, value}
    end)
  end

  defp unwrap_key({:__block__, _, [key]}), do: key
  defp unwrap_key(key), do: key

  defp signature(head) do
    case AstHelpers.extract_fn_signature(strip_when(head)) do
      {name, args} when is_list(args) -> {name, length(args)}
      _ -> :error
    end
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp line_of(meta), do: Keyword.get(meta, :line, 1)

  # ---- clustering ----------------------------------------------------------

  defp cluster(fragments, opts) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    mass_band = Keyword.get(opts, :mass_band, @default_mass_band)
    min_occ = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
    max_mass = Keyword.get(opts, :max_mass, @default_max_mass)
    min_merge_mass = Keyword.get(opts, :min_merge_mass, @default_min_merge_mass)

    indexed =
      fragments
      |> Enum.filter(&(&1.mass <= max_mass))
      |> Enum.with_index()
      |> Enum.map(fn {f, i} -> Map.put(f, :id, i) end)

    edges = similar_pairs(indexed, threshold, mass_band)

    indexed
    |> union_find_groups(edges)
    |> Enum.filter(fn group -> length(group) >= min_occ end)
    |> Enum.map(&build_cluster(&1, min_merge_mass))
    |> Enum.sort_by(&(-&1.mass))
  end

  # All {id_a, id_b} pairs (a < b) that could clear similarity θ. Two cheap
  # sound lower bounds on TED prune a pair before the O(m⁴) Zhang-Shasha runs:
  #
  #   1. the mass band — |mass_a - mass_b| ins/del are forced, and
  #   2. the label histogram — half the symmetric multiset difference of node
  #      labels is a lower bound on the edit distance.
  #
  # Either bound exceeding the allowed-edit budget `max(mass)·(1-θ)` means the
  # pair *cannot* reach θ, so TED is never computed for it. Fragments are sorted
  # by mass so the inner sweep stops as soon as the mass band breaks (masses
  # only grow forward).
  defp similar_pairs(fragments, threshold, mass_band) do
    sorted = Enum.sort_by(fragments, & &1.mass)

    sorted
    |> tails()
    |> Enum.flat_map(fn [f | rest] ->
      rest
      |> Enum.take_while(&mass_compatible?(f, &1, mass_band))
      |> Enum.reject(&histogram_prunes?(f, &1, threshold))
      |> Enum.filter(fn g -> TreeDiff.similarity(f.norm, g.norm) >= threshold end)
      |> Enum.map(fn g -> {f.id, g.id} end)
    end)
  end

  # `bag_distance = |labels_a △ labels_b| / 2` is a sound lower bound on the
  # tree-edit distance. If it already exceeds the edit budget that θ permits at
  # the larger mass, the pair can't reach θ — prune without computing TED.
  defp histogram_prunes?(a, b, threshold) do
    budget = max(a.mass, b.mass) * (1 - threshold)
    bag_distance(a.labels, b.labels) > budget
  end

  defp bag_distance(ha, hb) do
    keys = MapSet.union(MapSet.new(Map.keys(ha)), MapSet.new(Map.keys(hb)))

    diff =
      Enum.reduce(keys, 0, fn k, acc ->
        acc + abs(Map.get(ha, k, 0) - Map.get(hb, k, 0))
      end)

    diff / 2
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

  defp build_cluster(frags, min_merge_mass) do
    rep = Enum.max_by(frags, fn f -> {f.mass, neg_locator(f)} end)

    occurrences =
      frags
      |> Enum.map(fn f -> occurrence(f, rep) end)
      |> Enum.sort_by(&{&1.file, &1.line})

    no_structural? = Enum.all?(occurrences, fn o -> not Enum.any?(o.diffs, &structural?/1) end)
    avg_mass = average_mass(frags)

    %{
      representative: %{file: rep.file, line: rep.line, name: rep.name, arity: rep.arity},
      mass: rep.mass,
      avg_mass: avg_mass,
      mergeable: no_structural? and avg_mass >= min_merge_mass,
      occurrences: occurrences
    }
  end

  # Mean node count across the cluster's occurrences. This is the `mergeable`
  # gate's basis: a substantial block is worth a named helper; a trivial one — no
  # matter how often it recurs — is not. Averaging (vs the representative's mass)
  # keeps one fat outlier from dragging an otherwise-trivial near-clone over the
  # floor.
  defp average_mass(frags) do
    Enum.sum_by(frags, & &1.mass) / length(frags)
  end

  # Largest mass wins; ties broken to the earliest {file, line} for determinism.
  defp neg_locator(f), do: {invert(f.file), -f.line}
  defp invert(file), do: for(<<c <- file>>, into: "", do: <<255 - c>>)

  defp occurrence(%{id: id} = f, %{id: rep_id}) when id == rep_id do
    base_occurrence(f, 1.0, [])
  end

  defp occurrence(f, rep) do
    base_occurrence(
      f,
      TreeDiff.similarity(rep.norm, f.norm),
      TreeDiff.diff(rep.norm, f.norm)
    )
  end

  defp base_occurrence(f, similarity, diffs) do
    %{
      file: f.file,
      line: f.line,
      kind: f.kind,
      name: f.name,
      arity: f.arity,
      mass: f.mass,
      ast: f.ast,
      def_ast: f.def_ast,
      arg_strings: f.arg_strings,
      similarity: similarity,
      diffs: diffs
    }
  end

  defp structural?({:structural, _, _}), do: true
  defp structural?(_), do: false
end
