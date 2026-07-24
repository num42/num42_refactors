defmodule Number42.Refactors.Analysis.VocabularyClassifier do
  @moduledoc """
  Decides whether a module's *vocabulary* looks like a genuine god module
  (worth splitting) or a single-concern module (leave alone). Used by
  `SplitLowCohesionModule` to break the non-idempotence of issue #258.

  ## The problem it solves

  Modularity is *relative*: every module with a handful of functions
  partitions into sub-communities with `Q > min_modularity`, so the
  splitter happily re-splits its own freshly-created submodules and the
  fixpoint never converges. There is no *call-graph* signal that tells a
  good submodule apart from a god module — a good split, by construction,
  produces cohesive modules, and a cohesive module is exactly what we must
  not split. So the discriminator has to come from a different axis:
  the module's working **vocabulary**.

  A god module fuses several concerns, so its identifier vocabulary is
  large and diverse. A single-concern module (or a freshly-split
  submodule) repeats a small vocabulary. That difference is measurable
  per file, with no marker, no file-tree lookup, and no cross-pass state —
  every pass derives it identically from the module's own tokens, so
  `2 runs == 1 run + 1 run` stays true.

  ## The model

  A small logistic regression over four features derived from the
  identifier atoms of the module's `def`/`defp` clause bodies:

    * `mattr` — moving-average type-token ratio (vocabulary diversity)
    * `entropy` — Shannon entropy of the token distribution
    * `mattr * repeat_rate` — diversity weighted by how much repeats
    * `hapax_ratio` — fraction of identifiers used exactly once

  Features are standardised (z-score) with frozen means/stds, then scored.
  The constants below were fitted on 17 labelled modules (7 known
  split-artefacts, 10 real god modules) of this codebase and validated by
  leave-one-out cross-validation at ~77% — a few false positives are
  acceptable for a default-OFF refactor, and the gate is configurable
  (`:vocab_split_threshold`, default `0.5`; raise it to split less).

  Re-fitting: feed the same labelled corpus through
  `feature_vector/1`, standardise, train logistic regression, and replace
  the four `@feature_*`/`@weights`/`@bias` constants.
  """

  @feature_means [0.420263, 5.899142, 0.30891, 0.275787]
  @feature_stds [0.078555, 0.769656, 0.060406, 0.094452]
  @weights [0.431562, 0.345762, 0.480687, 0.098488]
  @bias 0.486314

  @mattr_window 100

  # AST node names that are syntactic scaffolding, not vocabulary — dropped
  # so the token stream reflects the module's *working* identifiers.
  @scaffolding ~w(def defp do end fn when -> :: __block__ __aliases__ . %{} {} <<>>)a

  @typedoc "A list of `def`/`defp` clause ASTs, as `collect_definitions/1` yields."
  @type clauses :: [[Macro.t()]]

  @doc """
  Probability in `[0, 1]` that the module is a genuine god module worth
  splitting. `clauses` is a list of per-`def` clause-AST lists (each
  definition's `:clauses`).

  Higher means more god-like (diverse vocabulary); lower means
  single-concern. Compare against a threshold (default `0.5`) to decide.
  """
  @spec god_probability(clauses()) :: float()
  def god_probability(clauses) do
    clauses
    |> Enum.map(&clause_atoms/1)
    |> feature_vector()
    |> standardize()
    |> logistic()
  end

  @doc """
  Whether the module's vocabulary clears `threshold` — i.e. looks diverse
  enough to be a real split candidate rather than a single concern.
  """
  @spec split_worthy?(clauses(), float()) :: boolean()
  def split_worthy?(clauses, threshold) do
    god_probability(clauses) >= threshold
  end

  # Identifier atoms of one definition's clauses: every atom the AST walk
  # surfaces (variable/call/atom names), minus syntactic scaffolding.
  defp clause_atoms(clause_asts) do
    clause_asts
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {name, _meta, _args} when is_atom(name) -> [name]
      atom when is_atom(atom) -> [atom]
      _ -> []
    end)
    |> Enum.reject(&(&1 in @scaffolding))
  end

  @doc """
  The raw `[mattr, entropy, mattr*repeat_rate, hapax_ratio]` feature
  vector from per-clause identifier-atom lists. Exposed so the model can
  be re-fitted on a fresh corpus.
  """
  @spec feature_vector([[atom()]]) :: [float()]
  def feature_vector(token_lists) do
    tokens = List.flatten(token_lists)
    total = length(tokens)
    unique = tokens |> Enum.uniq() |> length()

    m = mattr(tokens, total)
    repeat_rate = ratio(total - unique, total)
    hapax_ratio = ratio(hapax_count(tokens), unique)

    [m, entropy(tokens, total), m * repeat_rate, hapax_ratio]
  end

  # ── Features ─────────────────────────────────────────────────────

  # Moving-average type-token ratio: mean unique/window over a sliding
  # window. Below the window it degrades to plain TTR. Length-invariant —
  # the whole point, so a big god module and a small one are comparable.
  defp mattr([], _total), do: 0.0

  defp mattr(tokens, total) when total < @mattr_window do
    ratio(tokens |> Enum.uniq() |> length(), total)
  end

  defp mattr(tokens, total) do
    windows = for i <- 0..(total - @mattr_window), do: Enum.slice(tokens, i, @mattr_window)

    windows
    |> Enum.map(fn w -> length(Enum.uniq(w)) / @mattr_window end)
    |> mean()
  end

  defp entropy(_tokens, 0), do: 0.0

  defp entropy(tokens, total) do
    tokens
    |> Enum.frequencies()
    |> Map.values()
    |> Enum.reduce(0.0, fn count, acc ->
      p = count / total
      acc - p * :math.log2(p)
    end)
  end

  defp hapax_count(tokens) do
    tokens |> Enum.frequencies() |> Map.values() |> Enum.count(&(&1 == 1))
  end

  # ── Logistic head ────────────────────────────────────────────────

  defp standardize(features) do
    [features, @feature_means, @feature_stds]
    |> Enum.zip_with(fn [x, mean, std] -> (x - mean) / std end)
  end

  defp logistic(z_features) do
    z = @bias + (Enum.zip_with(z_features, @weights, &(&1 * &2)) |> Enum.sum())
    1.0 / (1.0 + :math.exp(-clamp(z)))
  end

  defp clamp(z), do: z |> max(-30.0) |> min(30.0)

  defp ratio(_numer, 0), do: 0.0
  defp ratio(numer, denom), do: numer / denom

  defp mean([]), do: 0.0
  defp mean(list), do: Enum.sum(list) / length(list)
end
