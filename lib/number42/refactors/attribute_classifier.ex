defmodule Number42.Refactors.AttributeClassifier do
  @moduledoc """
  Classifies a filter predicate's field into an optional adjective attribute
  (`active`, `deleted`, `stale`, …) or `:none`.

  Where `Semantic` picks the verb of a helper, this picks the optional middle
  word — `delete_<active>_items`, `fetch_<pending>_orders`. The attribute only
  comes from an explicit boolean predicate (`& &1.active`, `where: [x: true]`);
  most filters carry no such word, so the honest answer is usually `:none`.

  A naive nearest-prototype match guesses an attribute for every field name
  (`position` → `recent`), which is worse than no attribute at all. So this is
  a *trained* linear classifier (logistic regression over the static embedding,
  weights in `priv/semantic/attribute_model.json`) fit against many real
  non-attribute code words as `:none` — it has learned that most field names
  are not attributes and only fires on words close to the adjective set.

  Embedding reuses the per-word token-vector lexicon trick from `Semantic`:
  the model's input vocabulary is the adjective synonyms plus the boolean field
  names seen in real predicates. A field outside that lexicon yields `:none` —
  which is correct, an unknown field is not an attribute.
  """

  # Loaded once at runtime and cached in :persistent_term — see Semantic for
  # the why (compile-time Application.app_dir/2 crashes downstream consumers
  # because the app isn't loaded yet when they compile the dep).
  @external_resource "priv/semantic/attribute_model.json"
  @persistent_key {__MODULE__, :model}
  @model_file "semantic/attribute_model.json"

  @type attribute :: atom()

  @doc """
  Classify a predicate field name. Returns `{:ok, attribute}` for a confident
  adjective, or `:none` for an unknown field or a low-confidence guess.
  """
  @spec classify(String.t()) :: {:ok, attribute()} | :none
  def classify(field) when is_binary(field) do
    model = model()

    case embed(field, model) do
      :empty -> :none
      vec -> vec |> scores(model) |> softmax() |> pick(model)
    end
  end

  # --- model loading (runtime, cached) ---

  defp model do
    case :persistent_term.get(@persistent_key, :miss) do
      :miss ->
        loaded = load_model()
        :persistent_term.put(@persistent_key, loaded)
        loaded

      loaded ->
        loaded
    end
  end

  defp load_model do
    raw =
      :number42_refactors
      |> :code.priv_dir()
      |> Path.join(@model_file)
      |> File.read!()
      |> :json.decode()

    %{
      lexicon: Map.fetch!(raw, "lexicon"),
      classes: Map.fetch!(raw, "classes"),
      weights: Map.fetch!(raw, "W"),
      bias: Map.fetch!(raw, "b"),
      none_floor: Map.fetch!(raw, "none_floor")
    }
  end

  # --- embedding (same lexicon-mean approach as Semantic) ---

  defp embed(field, model) do
    field
    |> String.split("_", trim: true)
    |> Enum.flat_map(&Map.get(model.lexicon, &1, []))
    |> case do
      [] -> :empty
      token_vecs -> token_vecs |> mean() |> normalize()
    end
  end

  defp mean([first | _] = vectors) do
    n = length(vectors)

    vectors
    |> Enum.reduce(List.duplicate(0.0, length(first)), fn vec, acc ->
      Enum.zip_with(vec, acc, &+/2)
    end)
    |> Enum.map(&(&1 / n))
  end

  defp normalize(vec) do
    norm = :math.sqrt(Enum.reduce(vec, 0.0, fn x, a -> a + x * x end)) + 1.0e-9
    Enum.map(vec, &(&1 / norm))
  end

  # --- linear model: scores = W·x + b, then softmax ---

  defp scores(vec, model) do
    Enum.zip_with(model.weights, model.bias, fn row, bias -> dot(row, vec) + bias end)
  end

  defp dot(a, b), do: Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)

  defp softmax(scores) do
    max = Enum.max(scores)
    exps = Enum.map(scores, &:math.exp(&1 - max))
    sum = Enum.sum(exps)
    Enum.map(exps, &(&1 / sum))
  end

  # The winning class wins only if it is not `none` and clears the floor —
  # otherwise no attribute, keeping the two-word verb_object name.
  defp pick(probs, model) do
    {prob, index} = probs |> Enum.with_index() |> Enum.max_by(&elem(&1, 0))
    label = Enum.at(model.classes, index)

    if label == "none" or prob < model.none_floor,
      do: :none,
      else: {:ok, String.to_atom(label)}
  end
end
