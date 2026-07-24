defmodule Number42.Refactors.Analysis.Semantic do
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

  # Loaded once at runtime and cached in :persistent_term. Reading the model at
  # compile time (via Application.app_dir/2) crashes any consumer of this
  # library: the :number42_refactors app isn't loaded yet when a downstream
  # project compiles the dep. At runtime the app is always loaded, so the path
  # resolves; the table never changes, so a per-key cache fits.
  #
  # @external_resource is a repo-relative literal (no function call), so it
  # only triggers a recompile here without forcing a compile-time path lookup.
  @external_resource "priv/semantic/verb_model.json"
  @external_resource "priv/semantic/predicate_model.json"

  # The classifier serves more than one frozen table: `:verb` names helper
  # functions by their action, `:predicate` decides whether a name reads as
  # a predicate (for the `?`-suffix rewrite). Same nearest-prototype shape,
  # different prototypes — pick by name, default to `:verb` for callers
  # written before the second model existed.
  @models %{
    verb: "semantic/verb_model.json",
    predicate: "semantic/predicate_model.json"
  }

  @type label :: atom()
  @type model_name :: :verb | :predicate
  @type result :: {:ok, label(), float()} | :unknown

  @doc """
  Classify `identifier` against the frozen prototypes of `model_name`.

  Returns `{:ok, label, score}` when one bucket wins clearly, or `:unknown`
  when no word is known or the win is too close to call.
  """
  @spec classify(String.t(), model_name()) :: result()
  def classify(identifier, model_name \\ :verb) when is_binary(identifier) do
    model = model(model_name)

    case embed(identifier, model) do
      :empty -> :unknown
      vec -> vec |> best_two(model) |> gate(model)
    end
  end

  @doc "The labels a model can return, as atoms."
  @spec labels(model_name()) :: [label()]
  def labels(model_name \\ :verb),
    do: model(model_name).prototypes |> Map.keys() |> Enum.map(&String.to_atom/1)

  # --- model loading (runtime, cached) ---

  # Read + parse once per model, then serve from :persistent_term (lock-free
  # reads). The tables are immutable, so caching each once for the node is
  # correct and cheap.
  defp model(model_name) do
    key = {__MODULE__, model_name}

    case :persistent_term.get(key, :miss) do
      :miss ->
        loaded = load_model(model_name)
        :persistent_term.put(key, loaded)
        loaded

      loaded ->
        loaded
    end
  end

  defp load_model(model_name) do
    file = Map.fetch!(@models, model_name)

    raw =
      :number42_refactors
      |> :code.priv_dir()
      |> Path.join(file)
      |> File.read!()
      |> :json.decode()

    %{
      lexicon: Map.fetch!(raw, "lexicon"),
      prototypes: Map.fetch!(raw, "prototypes"),
      min_score: Map.fetch!(raw, "thresh"),
      min_margin: Map.fetch!(raw, "margin")
    }
  end

  # --- embedding ---

  # split at `.`/`_`, keep the last dotted segment (`Mod.fun` -> `fun`),
  # gather every token vector of every known word, mean them, normalize.
  defp embed(identifier, model) do
    identifier
    |> words()
    |> Enum.flat_map(&Map.get(model.lexicon, &1, []))
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
  defp best_two(query, model) do
    model.prototypes
    |> Enum.map(fn {label, proto} -> {label, dot(query, proto)} end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  defp dot(a, b), do: Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)

  # Thresholds live in the model now, so the gate can't be a guard — bind them
  # and compare in the body. Same logic: clear the absolute floor and beat the
  # runner-up by the margin, else `:unknown`.
  defp gate([{label, best}, {_, second} | _], model) do
    if best >= model.min_score and best - second >= model.min_margin,
      do: {:ok, String.to_atom(label), best},
      else: :unknown
  end

  defp gate(_, _), do: :unknown
end
