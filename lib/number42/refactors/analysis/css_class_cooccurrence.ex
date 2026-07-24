defmodule Number42.Refactors.Analysis.CssClassCooccurrence do
  @moduledoc """
  Learn a HEEx codebase's CSS-class co-occurrence conventions and surface
  outliers — class lists that sit one token away from a strongly-supported
  convention cluster.

  **Detection is the entire problem.** Tailwind-style utility soup is
  high-cardinality and noisy: at the element level most exact class sets are
  unique, so a naive "this set is rare → fix it" rule would rewrite almost
  every site. The job of this module is to find the *signal* — a recurring,
  high-support class set (the convention) — and only then flag a near-miss as
  a likely typo/drift, corroborated by the pairwise co-occurrence weights.

  ## Two complementary signals

  1. **Exact class-set support (the cluster).** Every element carrying a
     static `class="..."` contributes its token *set* (order- and
     duplicate-insensitive). Sets that recur form clusters; a cluster's
     support is how many elements use exactly that set. A convention is a
     cluster whose support clears `:min_support`.

  2. **Pairwise co-occurrence weight (the corroboration).** Following #285,
     every *pair* of classes that co-occur near each other in the
     `Heex.Tree` is a weighted observation, pairs alphabetically sorted so
     `{:a, :b}` and `{:b, :a}` collapse to one tuple:

       * **same element** (both in one `class=`) → weight `1.0`
       * **inter-element**, depth `d` apart in the tree → weight `1 / 2^d`
         (direct parent↔child `0.5`, grandparent↔grandchild `0.25`, …)
       * **siblings** → `:sibling_weight` (default `0.5`; tunable, the issue
         leaves this between `/2` and `/√2`)

     A candidate correction `bad → good` is only trusted when, summed over
     the outlier's *other* tokens, `good` co-occurs more strongly than `bad`
     across the whole corpus — i.e. the convention token genuinely "belongs"
     with the rest of the set and the deviating token does not.

  Conservative everywhere: a single missing signal declines the correction.
  Rewriting CSS changes rendered output, so a false positive is expensive.
  """

  alias Number42.Refactors.Analysis.Heex.Tree

  @default_sibling_weight 0.5

  @typedoc """
  One element's static class observation: its token set, the tree depth at
  which it sits (root = 0), and the enclosing element's identity used for
  the sibling/parent proximity walk.
  """
  @type class_site :: %{
          classes: MapSet.t(atom()),
          depth: non_neg_integer(),
          path: [non_neg_integer()]
        }

  @typedoc "Alphabetically-ordered class pair → summed proximity weight."
  @type tuple_weights :: %{{atom(), atom()} => float()}

  @typedoc "An exact class set and how many elements use exactly it."
  @type cluster :: %{classes: MapSet.t(atom()), support: non_neg_integer()}

  @doc """
  All static-class sites in one source string.

  Every element with a literal `class="a b c"` yields one site whose
  `:classes` is the token set. Dynamic `class={…}` attributes carry no
  static tokens and are skipped — we only learn from what is written
  verbatim. Returns `[]` for sources with no parseable `~H` sigil.
  """
  @spec class_sites(String.t()) :: [class_site()]
  def class_sites(source) when is_binary(source) do
    case Tree.from_source(source) do
      {:ok, sigils} -> Enum.flat_map(sigils, &sites_in_tree(&1.tree))
      :error -> []
    end
  end

  @doc """
  Weighted pairwise co-occurrence index over a corpus of `[{path, source}]`.

  Same-element pairs score `1.0`; inter-element pairs decay by tree
  distance. Weights accumulate across every site in every source.
  """
  @spec tuple_weights([{String.t(), String.t()}], keyword()) :: tuple_weights()
  def tuple_weights(sources, opts \\ []) do
    sibling_weight = Keyword.get(opts, :sibling_weight, @default_sibling_weight)

    sources
    |> Enum.flat_map(fn {_path, source} -> weighted_pairs(source, sibling_weight) end)
    |> Enum.reduce(%{}, fn {pair, w}, acc -> Map.update(acc, pair, w, &(&1 + w)) end)
  end

  @doc """
  Exact class-set clusters with their support counts, strongest first.

  A cluster is a distinct token set; its support is the number of sites
  using exactly that set. Singleton-token sets are ignored — a one-class
  element has no internal convention to deviate from.
  """
  @spec clusters([class_site()]) :: [cluster()]
  def clusters(sites) do
    sites
    |> Enum.map(& &1.classes)
    |> Enum.reject(&(MapSet.size(&1) < 2))
    |> Enum.frequencies()
    |> Enum.map(fn {classes, support} -> %{classes: classes, support: support} end)
    |> Enum.sort_by(&{-&1.support, set_key(&1.classes)})
  end

  @doc """
  Weighted pairs for one source — the proximity-decayed observations a
  single file contributes to the corpus index. Public for measurement
  (Phase 0) and testing.
  """
  @spec weighted_pairs(String.t(), float()) :: [{{atom(), atom()}, float()}]
  def weighted_pairs(source, sibling_weight \\ @default_sibling_weight) do
    case Tree.from_source(source) do
      {:ok, sigils} -> Enum.flat_map(sigils, &pairs_in_tree(&1.tree, sibling_weight))
      :error -> []
    end
  end

  # ── per-tree site collection ─────────────────────────────────────

  defp sites_in_tree(tree), do: collect_sites(tree, 0, [], [])

  # Walk the tree carrying depth + a positional path so two sites can be
  # told apart structurally. Each element with a static class becomes a site.
  defp collect_sites(nodes, depth, path, acc) when is_list(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {node, i}, inner ->
      collect_sites(node, depth, [i | path], inner)
    end)
  end

  defp collect_sites({:element, _tag, attrs, children, _meta}, depth, path, acc) do
    acc =
      case static_class_set(attrs) do
        nil -> acc
        classes -> [%{classes: classes, depth: depth, path: Enum.reverse(path)} | acc]
      end

    collect_sites(children, depth + 1, path, acc)
  end

  defp collect_sites({:eex_block, _header, children, _meta}, depth, path, acc),
    do: collect_sites(children, depth, path, acc)

  defp collect_sites(_other, _depth, _path, acc), do: acc

  # ── per-tree weighted pairs ──────────────────────────────────────

  # Two sources of pairs:
  #   * intra-element — every unordered pair within one class set, weight 1.0
  #   * inter-element — every pair of distinct sites, weight 1 / 2^distance
  #     (siblings use the configured sibling weight, not the depth formula)
  defp pairs_in_tree(tree, sibling_weight) do
    sites = collect_sites(tree, 0, [], []) |> Enum.reverse()
    intra_element_pairs(sites) ++ inter_element_pairs(sites, sibling_weight)
  end

  defp intra_element_pairs(sites) do
    Enum.flat_map(sites, fn %{classes: classes} ->
      classes |> unordered_pairs() |> Enum.map(&{&1, 1.0})
    end)
  end

  defp inter_element_pairs(sites, sibling_weight) do
    for {a, ai} <- Enum.with_index(sites),
        {b, bi} <- Enum.with_index(sites),
        ai < bi,
        pair_weight = proximity_weight(a, b, sibling_weight),
        pair_weight > 0.0,
        token_a <- MapSet.to_list(a.classes),
        token_b <- MapSet.to_list(b.classes),
        token_a != token_b do
      {sort_pair(token_a, token_b), pair_weight}
    end
  end

  # Tree distance between two sites from their positional paths: the number
  # of edges on the path connecting them through their lowest common
  # ancestor. Siblings (same parent path, differing only in the last index)
  # get the configurable sibling weight; everything else decays as 1 / 2^d.
  defp proximity_weight(%{path: pa}, %{path: pb}, sibling_weight) do
    common = common_prefix_len(pa, pb)
    da = length(pa) - common
    db = length(pb) - common

    if da == 1 and db == 1,
      do: sibling_weight,
      else: 1.0 / :math.pow(2, da + db)
  end

  defp common_prefix_len(a, b), do: common_prefix_len(a, b, 0)
  defp common_prefix_len([h | ta], [h | tb], n), do: common_prefix_len(ta, tb, n + 1)
  defp common_prefix_len(_, _, n), do: n

  # ── class extraction ─────────────────────────────────────────────

  # Only a literal `class="..."` yields tokens. `class={expr}` is dynamic —
  # nothing static to learn from — and is skipped.
  defp static_class_set(attrs) do
    case List.keyfind(attrs, "class", 0) do
      {"class", {:string, value}} -> class_tokens(value)
      _ -> nil
    end
  end

  defp class_tokens(value) do
    tokens =
      value
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(&String.to_atom/1)

    case tokens do
      [] -> nil
      list -> MapSet.new(list)
    end
  end

  # ── pair helpers ─────────────────────────────────────────────────

  defp unordered_pairs(class_set) do
    list = class_set |> MapSet.to_list() |> Enum.sort()

    for {a, i} <- Enum.with_index(list),
        {b, j} <- Enum.with_index(list),
        i < j,
        do: {a, b}
  end

  defp sort_pair(a, b) when a <= b, do: {a, b}
  defp sort_pair(a, b), do: {b, a}

  defp set_key(set), do: set |> MapSet.to_list() |> Enum.sort()
end
