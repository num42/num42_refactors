defmodule Number42.Refactors.Ex.CssClassClusterCorrection do
  @moduledoc """
  Learn the project's recurring CSS-class conventions from co-occurrence and
  correct **outliers** — a class list that sits one token away from a
  strongly-supported convention cluster gets that one token moved into the
  convention.

      # codebase convention (47 sites): class="mt1 pb2 gap2"
      # one outlier:
      <div class="mt1 pb3 gap2">…</div>

      # after — the lone deviating token is pulled back to the convention
      <div class="mt1 pb2 gap2">…</div>

  This is orthogonal to the structural-motif work (#278): motifs cluster
  *tree shapes*; this clusters *class sets*. Same philosophy — **detection is
  the entire problem** — but a different signal (#285).

  ## Why this is the hardest kind of refactor to get right

  A `pb3 → pb2` rewrite changes rendered layout. The cluster cannot know
  whether the deviation was a typo/drift (correct it) or a deliberately
  tighter cell (must not touch it). Tailwind utility soup is also
  high-cardinality and noisy — most exact class sets are unique — so a naive
  "rare set → fix it" rule would rewrite nearly everything. Every design
  choice below exists to drive the false-positive rate toward zero, at the
  cost of firing rarely.

  ## Detection (all gates must hold)

  Built on `Number42.Refactors.Analysis.CssClassCooccurrence`, which supplies both
  signals the issue prescribes:

  1. **Exact-set clusters with support.** A *convention* `C` is a class set
     whose support clears `:min_support` (default `#{8}`). Strong support is
     the precondition for trusting that `C` is a real convention and not an
     accident.
  2. **Hamming-distance-1 outlier.** A site's set `S` is an outlier of `C`
     iff `S` and `C` differ by exactly **one** swapped token: there is one
     `bad ∈ S` and one `good ∈ C` with `S \\ {bad} == C \\ {good}`. A
     missing or extra token (size mismatch) is *not* a swap — adding/removing
     a class is a larger edit than this refactor will make.
  3. **Dominance over the deviation.** `C.support` must be at least
     `:dominance_ratio` (default `#{20}`) times the support of `S` itself.
     If the deviating set *also* recurs strongly, it is a second convention,
     not a typo — decline. This is the direct "don't correct an intentional
     one-off" guard.
  4. **Same utility family.** `bad` and `good` must be the *same* utility
     differing only in a trailing scale (prefix `pb`, suffix `3` vs `2`).
     A cross-family swap (`pb3`↔`flex`) is never a typo; restricting to
     same-family swaps removes the entire class of semantically-meaningful
     deviations. This is the per-correction allow-list the issue's
     premeditatio malorum asks for.
  5. **Co-occurrence corroborates.** Summed over the shared tokens
     `S ∩ C`, the convention token `good` must co-occur *strictly more
     strongly* than `bad` across the whole corpus. The proximity-weighted
     pairwise index says `good` genuinely belongs with the rest of the set
     and `bad` does not — independent confirmation of the swap direction.

  When several conventions could claim the same outlier, the one with the
  highest support wins; ties decline (ambiguous → do nothing).

  ## Default-OFF (opt-in only)

  Rewriting styling is high-risk, so both `prepare/1` and `transform/2` are
  no-ops unless the module's own opts carry `enabled: true`:

      configured_modules: [
        {Number42.Refactors.Ex.CssClassClusterCorrection, enabled: true}
      ]

  `--dry-run` is strongly recommended before enabling on real code.

  ## prepare/1

  The convention index is corpus-wide: a single site can only be judged an
  outlier against the whole codebase's class-set distribution. `prepare/1`
  builds the cluster list + co-occurrence weights once per run (like the
  cross-file dedup refactor #280) and threads them into every `transform/2`.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Analysis.CssClassCooccurrence, as: Coocc
  alias Number42.Refactors.Analysis.Heex.Tree
  alias Sourceror.Patch

  @default_min_support 8
  @default_dominance_ratio 20

  @excluded_path_prefixes ["test/", "dev/"]

  @typedoc """
  The corpus-wide model threaded through `transform/2`: the support-ranked
  exact-set clusters and the proximity-weighted pairwise co-occurrence index.
  """
  @type model :: %{
          clusters: [Coocc.cluster()],
          weights: Coocc.tuple_weights()
        }

  @typedoc "A single trusted correction: swap `bad` for `good` in a site's set."
  @type correction :: %{
          classes: MapSet.t(atom()),
          bad: atom(),
          good: atom()
        }

  @impl Number42.Refactors.Refactor
  def description,
    do: "Correct a CSS class outlier toward a strongly-supported co-occurrence cluster"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Learns the codebase's recurring CSS class sets and their proximity-
    weighted co-occurrence. A site whose class set is exactly one swapped
    token away from a high-support convention cluster — same utility family
    (pb3↔pb2), the convention dominating the deviation by a wide margin, and
    the co-occurrence weights confirming the convention token belongs — has
    that one token corrected. Default-OFF and threshold-gated: rewriting CSS
    changes rendered output, so the bar is deliberately high and the
    refactor fires rarely. Idempotent: a corrected site now matches the
    convention exactly and is no longer an outlier.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 100

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    if Keyword.get(opts, :enabled, false) do
      opts |> corpus_sources() |> build_model_or_skip(opts)
    else
      :no_cache
    end
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      opts |> Keyword.get(:prepared) |> rewrite_with_model(source, opts)
    else
      source
    end
  end

  @doc """
  Build the corpus-wide model from `[{path, source}]` tuples.

  Test/dev sources are excluded — we learn conventions from production
  markup only. Pure: no disk writes, safe to call from `prepare/1` or a
  Phase-0 measurement script.
  """
  @spec build_model([{String.t(), String.t()}], keyword()) :: model()
  def build_model(sources, opts \\ []) do
    relevant = Enum.reject(sources, fn {path, _src} -> excluded_path?(path) end)
    sites = Enum.flat_map(relevant, fn {_path, src} -> Coocc.class_sites(src) end)

    %{
      clusters: Coocc.clusters(sites),
      weights: Coocc.tuple_weights(relevant, opts)
    }
  end

  @doc """
  The corrections the model would apply to one source — for `--dry-run`
  reporting and testing without rendering a patch.
  """
  @spec corrections(model(), String.t(), keyword()) :: [correction()]
  def corrections(model, source, opts \\ []) do
    thresholds = thresholds(opts)

    source
    |> Coocc.class_sites()
    |> Enum.map(& &1.classes)
    |> Enum.uniq()
    |> Enum.flat_map(&correction_for_set(&1, model, thresholds))
  end

  # ── transform plumbing ───────────────────────────────────────────

  defp rewrite_with_model(nil, source, _opts), do: source

  defp rewrite_with_model(model, source, opts) do
    case corrections(model, source, opts) do
      [] -> source
      corrections -> apply_corrections(source, corrections)
    end
  end

  defp apply_corrections(source, corrections) do
    by_set = Map.new(corrections, &{&1.classes, &1})

    source
    |> sigil_patches(by_set)
    |> patch_or_passthrough(source)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  # One patch per `class="..."` whose token set matches a correction:
  # rewrite just the attribute string, preserving the original token order
  # and spacing as far as a single-token swap allows.
  defp sigil_patches(source, by_set) do
    source
    |> collect_class_sigils()
    |> Enum.flat_map(&sigil_class_patches(&1, by_set))
  end

  defp sigil_class_patches(%{tree: tree, sigil_node: node, body: body}, by_set) do
    range = Sourceror.get_range(node)
    indent = String.duplicate(" ", range.start[:column] - 1)
    edits = class_edits_in_tree(tree, body, by_set)

    case edits do
      [] -> []
      edits -> [Patch.new(range, render_sigil(apply_edits(body, edits), indent), false)]
    end
  end

  # `{start_byte, replacement}` edits against the dedented sigil body, one per
  # matching `class="..."`. Applied back-to-front so earlier offsets stay
  # valid while later edits splice.
  defp class_edits_in_tree(tree, body, by_set) do
    Tree.walk(tree, [], fn
      {:element, _tag, attrs, _children, _meta} = node, acc ->
        case class_edit(node, attrs, body, by_set) do
          nil -> acc
          edit -> [edit | acc]
        end

      _node, acc ->
        acc
    end)
  end

  defp class_edit(node, attrs, body, by_set) do
    with {"class", {:string, raw}} <- List.keyfind(attrs, "class", 0),
         set when not is_nil(set) <- token_set(raw),
         %{bad: bad, good: good} <- Map.get(by_set, set),
         {s, e} <- class_value_range(node, body, raw) do
      %{start: s, stop: e, replacement: swap_token(raw, bad, good)}
    else
      _ -> nil
    end
  end

  defp apply_edits(body, edits) do
    edits
    |> Enum.sort_by(& &1.start, :desc)
    |> Enum.reduce(body, fn %{start: s, stop: e, replacement: rep}, acc ->
      binary_part(acc, 0, s) <> rep <> binary_part(acc, e, byte_size(acc) - e)
    end)
  end

  # Locate the literal class value (between the quotes) inside `body` for
  # `node`'s open tag. We scan the open tag's bytes for `class="…"` so the
  # patch touches *only* the value, leaving the rest of the markup byte-exact.
  defp class_value_range(node, body, raw) do
    {tag_start, _tag_end} = Tree.node_byte_range(node, body)
    scope = byte_size(body) - tag_start

    case :binary.match(body, "\"" <> raw <> "\"", scope: {tag_start, scope}) do
      {pos, _len} -> {pos + 1, pos + 1 + byte_size(raw)}
      :nomatch -> nil
    end
  end

  # Swap exactly the one deviating token for the convention token in the raw
  # class string, preserving every other token and its position/whitespace.
  defp swap_token(raw, bad, good) do
    bad_s = Atom.to_string(bad)
    good_s = Atom.to_string(good)

    raw
    |> String.split(~r/(\s+)/, include_captures: true)
    |> Enum.map_join("", fn part -> if part == bad_s, do: good_s, else: part end)
  end

  # ── correction decision (per distinct class set) ─────────────────

  defp correction_for_set(set, %{clusters: clusters, weights: weights}, thresholds) do
    own_support = exact_support(clusters, set)

    clusters
    |> Enum.filter(&convention?(&1, thresholds))
    |> Enum.flat_map(&swap_candidate(&1, set, own_support, weights, thresholds))
    |> pick_unambiguous(set)
  end

  defp convention?(%{support: support}, %{min_support: min}), do: support >= min

  # A candidate swap exists iff `set` is Hamming-distance-1 from the
  # convention `C` (one `bad ∈ set`, one `good ∈ C`, the rest identical) and
  # every remaining gate holds.
  defp swap_candidate(%{classes: conv, support: conv_support}, set, own_support, weights, t) do
    with {:ok, bad, good} <- single_swap(set, conv),
         true <- dominates?(conv_support, own_support, t),
         true <- same_family?(bad, good),
         shared = MapSet.delete(set, bad),
         true <- corroborated?(good, bad, shared, weights) do
      [%{classes: set, bad: bad, good: good, support: conv_support}]
    else
      _ -> []
    end
  end

  # Exactly one token differs in each direction → a swap. Equal sets, or sets
  # differing in size or by more than one token, are not swaps.
  defp single_swap(set, conv) do
    removed = MapSet.difference(set, conv) |> MapSet.to_list()
    added = MapSet.difference(conv, set) |> MapSet.to_list()

    case {removed, added} do
      {[bad], [good]} -> {:ok, bad, good}
      _ -> :error
    end
  end

  # A unique deviation (own_support == 0) is trivially dominated — there is
  # no competing convention. Otherwise the convention must outweigh the
  # deviation by the full ratio, which is what rejects an intentional one-off
  # that itself recurs.
  defp dominates?(_conv_support, 0, _thresholds), do: true

  defp dominates?(conv_support, own_support, %{dominance_ratio: ratio}),
    do: conv_support >= ratio * own_support

  # Same utility family: identical non-numeric prefix, differing only in a
  # trailing numeric scale. `pb3`/`pb2` ✓, `mt1`/`mt2` ✓, `pb3`/`flex` ✗,
  # `text-sm`/`text-lg` ✗ (no trailing number → not a scale swap we trust).
  defp same_family?(bad, good) do
    with {prefix_a, scale_a} when scale_a != "" <- split_scale(bad),
         {prefix_b, scale_b} when scale_b != "" <- split_scale(good) do
      prefix_a == prefix_b and prefix_a != "" and scale_a != scale_b
    else
      _ -> false
    end
  end

  defp split_scale(token) do
    s = Atom.to_string(token)

    case Regex.run(~r/^(.*?)(\d+)$/, s) do
      [_, prefix, scale] -> {prefix, scale}
      _ -> {s, ""}
    end
  end

  # Co-occurrence corroboration: across the shared tokens, the convention
  # token must out-co-occur the deviating token. Empty shared set (a 2-class
  # swap leaving one shared token is the minimum) still gives one comparison.
  defp corroborated?(good, bad, shared, weights) do
    good_w = total_weight(good, shared, weights)
    bad_w = total_weight(bad, shared, weights)
    good_w > bad_w
  end

  defp total_weight(token, shared, weights) do
    shared
    |> MapSet.to_list()
    |> Enum.reduce(0.0, fn other, acc -> acc + Map.get(weights, pair(token, other), 0.0) end)
  end

  # Only one trusted correction per set. If multiple conventions tie on
  # support, the situation is ambiguous → decline (do nothing).
  defp pick_unambiguous([], _set), do: []

  defp pick_unambiguous(candidates, _set) do
    sorted = Enum.sort_by(candidates, &(-&1.support))

    case sorted do
      [top] -> [strip(top)]
      [top, second | _] when top.support > second.support -> [strip(top)]
      _ -> []
    end
  end

  defp strip(%{classes: classes, bad: bad, good: good}),
    do: %{classes: classes, bad: bad, good: good}

  defp exact_support(clusters, set) do
    Enum.find_value(clusters, 0, fn
      %{classes: ^set, support: s} -> s
      _ -> false
    end)
  end

  # ── thresholds + corpus loading ──────────────────────────────────

  defp thresholds(opts) do
    %{
      min_support: Keyword.get(opts, :min_support, @default_min_support),
      dominance_ratio: Keyword.get(opts, :dominance_ratio, @default_dominance_ratio)
    }
  end

  defp corpus_sources(opts) do
    case Keyword.get(opts, :source_files) do
      paths when is_list(paths) -> Enum.map(paths, fn p -> {p, File.read!(p)} end)
      _ -> load_default_sources()
    end
  end

  defp build_model_or_skip([], _opts), do: :no_cache
  defp build_model_or_skip(sources, opts), do: {:ok, build_model(sources, opts)}

  defp load_default_sources, do: File.read(".refactor.exs") |> parse_inputs_from_config()

  defp parse_inputs_from_config({:ok, contents}) do
    {config, _} = Code.eval_string(contents)

    config
    |> Map.get(:inputs, [])
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&excluded_path?/1)
    |> Enum.map(fn p -> {p, File.read!(p)} end)
  end

  defp parse_inputs_from_config(_), do: []

  # ── small helpers ────────────────────────────────────────────────

  defp token_set(raw) do
    tokens = raw |> String.split(~r/\s+/, trim: true) |> Enum.map(&String.to_atom/1)
    if tokens == [], do: nil, else: MapSet.new(tokens)
  end

  defp pair(a, b) when a <= b, do: {a, b}
  defp pair(a, b), do: {b, a}

  defp excluded_path?(path) do
    normalized = String.trim_leading(path, "./")
    Enum.any?(@excluded_path_prefixes, &String.starts_with?(normalized, &1))
  end

  defp render_sigil(new_body, indent) do
    indented =
      new_body
      |> String.split("\n", trim: false)
      |> Enum.map_join("\n", fn
        "" -> ""
        line -> indent <> line
      end)

    "~H\"\"\"\n" <> indented <> indent <> "\"\"\""
  end

  # Retain each sigil's AST node + parsed tree so we can range-patch the
  # body and resolve `class="..."` byte offsets.
  defp collect_class_sigils(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> ast |> sigil_nodes() |> Enum.flat_map(&parse_sigil_or_skip/1)
      {:error, _} -> []
    end
  end

  defp sigil_nodes(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:sigil_H, _meta, [{:<<>>, _body_meta, [body]}, _modifiers]} = node when is_binary(body) ->
        [%{body: body, sigil_node: node}]

      _ ->
        []
    end)
  end

  defp parse_sigil_or_skip(%{body: body} = sigil) do
    case Tree.parse_body(body) do
      {:ok, tree} -> [Map.put(sigil, :tree, tree)]
      :error -> []
    end
  end
end
