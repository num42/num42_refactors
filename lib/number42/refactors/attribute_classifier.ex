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

  @model_path Application.app_dir(:number42_refactors, "priv/semantic/attribute_model.json")
  @external_resource @model_path

  @model @model_path |> File.read!() |> :json.decode()

  @lexicon Map.fetch!(@model, "lexicon")
  @classes Map.fetch!(@model, "classes")
  @weights Map.fetch!(@model, "W")
  @bias Map.fetch!(@model, "b")
  @none_floor Map.fetch!(@model, "none_floor")

  @type attribute :: atom()

  @doc """
  Classify a predicate field name. Returns `{:ok, attribute}` for a confident
  adjective, or `:none` for an unknown field or a low-confidence guess.
  """
  @spec classify(String.t()) :: {:ok, attribute()} | :none
  def classify(field) when is_binary(field) do
    case embed(field) do
      :empty -> :none
      vec -> vec |> scores() |> softmax() |> pick()
    end
  end

  # --- embedding (same lexicon-mean approach as Semantic) ---

  defp embed(field) do
    field
    |> String.split("_", trim: true)
    |> Enum.flat_map(&Map.get(@lexicon, &1, []))
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

  defp scores(vec) do
    Enum.zip_with(@weights, @bias, fn row, bias -> dot(row, vec) + bias end)
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
  defp pick(probs) do
    {prob, index} = probs |> Enum.with_index() |> Enum.max_by(&elem(&1, 0))
    label = Enum.at(@classes, index)

    if label == "none" or prob < @none_floor,
      do: :none,
      else: {:ok, String.to_atom(label)}
  end
end
