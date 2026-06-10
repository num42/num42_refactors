defmodule Number42.Refactors.Semantic do
  @moduledoc """
  Static-embedding classifier shared by the naming refactors.

  Maps an identifier (a call name, a block label) to one of a *fixed* set of
  semantic buckets by cosine-matching its static embedding against frozen
  prototype vectors. It classifies into a closed set — it never invents a
  token — so it stays deterministic and idempotent like every other refactor.

  The embedding is a Model2Vec static lookup: a word is the unweighted mean of
  its token vectors, a phrase the mean over all its words' tokens. No neural
  forward pass at runtime — just a vector table (`priv/semantic/verb_model.json`,
  distilled once from `potion-multilingual-128M`) plus arithmetic. The exported
  table stores per-word token vectors, so the Elixir mean is bit-identical to
  the Python encoder for any phrase whose words are all in the lexicon.

  A word outside the lexicon is dropped from the mean — coverage, not crash. A
  string with no known word, or whose best match fails the confidence gate
  (`min_score` absolute, `min_margin` over the runner-up), returns `:unknown`,
  letting the caller keep its mechanical fallback rather than guess.
  """

  @model_path Application.app_dir(:number42_refactors, "priv/semantic/verb_model.json")
  @external_resource @model_path

  # Parsed once at compile time and frozen into the module — the table never
  # changes at runtime, so there is nothing to load per call.
  @model @model_path |> File.read!() |> :json.decode()

  @lexicon Map.fetch!(@model, "lexicon")
  @prototypes Map.fetch!(@model, "prototypes")
  @min_score Map.fetch!(@model, "thresh")
  @min_margin Map.fetch!(@model, "margin")

  @type label :: atom()
  @type result :: {:ok, label(), float()} | :unknown

  @doc """
  Classify `identifier` against the frozen prototypes.

  Returns `{:ok, label, score}` when one bucket wins clearly, or `:unknown`
  when no word is known or the win is too close to call.
  """
  @spec classify(String.t()) :: result()
  def classify(identifier) when is_binary(identifier) do
    case embed(identifier) do
      :empty -> :unknown
      vec -> vec |> best_two() |> gate()
    end
  end

  @doc "The labels this classifier can return, as atoms."
  @spec labels() :: [label()]
  def labels, do: Enum.map(Map.keys(@prototypes), &String.to_atom/1)

  # --- embedding ---

  # split at `.`/`_`, keep the last dotted segment (`Mod.fun` -> `fun`),
  # gather every token vector of every known word, mean them, normalize.
  defp embed(identifier) do
    identifier
    |> words()
    |> Enum.flat_map(&Map.get(@lexicon, &1, []))
    |> case do
      [] -> :empty
      token_vecs -> token_vecs |> mean() |> normalize()
    end
  end

  defp words(identifier) do
    identifier
    |> String.split(".")
    |> List.last()
    |> String.split("_", trim: true)
  end

  defp mean([first | _] = vectors) do
    n = length(vectors)

    vectors
    |> Enum.reduce(List.duplicate(0.0, length(first)), &add/2)
    |> Enum.map(&(&1 / n))
  end

  defp add(vec, acc), do: Enum.zip_with(vec, acc, &+/2)

  defp normalize(vec) do
    norm = :math.sqrt(Enum.reduce(vec, 0.0, fn x, a -> a + x * x end)) + 1.0e-9
    Enum.map(vec, &(&1 / norm))
  end

  # --- matching ---

  # prototypes are pre-normalized, the query is normalized, so the dot product
  # IS the cosine similarity.
  defp best_two(query) do
    @prototypes
    |> Enum.map(fn {label, proto} -> {label, dot(query, proto)} end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  defp dot(a, b), do: Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)

  defp gate([{label, best}, {_, second} | _])
       when best >= @min_score and best - second >= @min_margin,
       do: {:ok, String.to_atom(label), best}

  defp gate(_), do: :unknown
end
