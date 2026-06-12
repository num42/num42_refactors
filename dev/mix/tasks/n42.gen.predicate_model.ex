defmodule Mix.Tasks.N42.Gen.PredicateModel do
  @shortdoc "Regenerate priv/semantic/predicate_model.json from the source embedding"

  @moduledoc """
  Builds `priv/semantic/predicate_model.json`, the frozen vector table that
  `Number42.Refactors.Semantic` uses to decide whether a function *name* reads
  as a predicate (`valid`, `expired`) or an action (`parse`, `compute`).

  Like the Python `regen/` scripts this is a one-time, offline distillation of
  [`potion-multilingual-128M`](https://huggingface.co/minishlab/potion-multilingual-128M):
  a word's vector is the mean of its token vectors, the prototype of a bucket
  the mean over all its seeds' token vectors. The runtime never runs this — it
  reads the produced JSON. The only difference from `regen/` is the language:
  this task uses the `tokenizers` + `safetensors` Elixir deps (dev-only) to
  read the same source model, producing vectors bit-identical to the Python
  encoder for any in-lexicon word (verified against `verb_model.json`).

      mix n42.gen.predicate_model

  Reads the source model from the local Hugging Face cache; pass the snapshot
  directory explicitly if it lives elsewhere:

      mix n42.gen.predicate_model --model-dir /path/to/potion-snapshot
  """

  use Mix.Task

  @model_repo "models--minishlab--potion-multilingual-128M"
  @out_path "priv/semantic/predicate_model.json"
  @dim 256

  # Two buckets. A name wins a bucket by cosine similarity against the
  # bucket's prototype, gated by an absolute floor + a margin over the
  # runner-up — failing the gate yields :unknown, so the caller falls back
  # to the verb-stem heuristic.
  #
  # predicate: states/conditions a thing can be *in* — adjectives and the
  # few verbs that ask rather than do (check/verify/...). A `?` reads right.
  # action: transitive verbs that *produce* or *mutate*. `parse?`/`update?`
  # is the PR #305 nonsense the gate exists to stop.
  @seeds %{
    "predicate" => ~w(
      valid invalid active inactive empty blank present visible hidden
      enabled disabled expired stale fresh pending complete done ready
      allowed permitted eligible required missing unique duplicate
      equal positive negative zero nil true false
      check verify confirm ensure matches contains exists
    ),
    "action" => ~w(
      parse decode encode compute calculate sum aggregate count
      build create make construct generate render format
      fetch get load list query retrieve
      update merge insert delete replace assign put
      send broadcast notify publish dispatch
      filter reject group split normalize sanitize trim
    )
  }

  @thresh 0.35
  @margin 0.08

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [model_dir: :string])
    snap = opts[:model_dir] || default_snapshot()

    {:ok, tokenizer} = Tokenizers.Tokenizer.from_file(Path.join(snap, "tokenizer.json"))
    embeddings = load_embeddings(Path.join(snap, "model.safetensors"))

    tv = &token_vecs(&1, tokenizer, embeddings)

    all_words = @seeds |> Map.values() |> List.flatten() |> Enum.sort() |> Enum.uniq()
    lexicon = Map.new(all_words, fn w -> {w, Enum.map(tv.(w), &round3_vec/1)} end)

    prototypes =
      Map.new(@seeds, fn {bucket, words} ->
        {bucket, words |> Enum.flat_map(tv) |> mean() |> normalize() |> Enum.map(&round3/1)}
      end)

    out = %{
      "dim" => @dim,
      "lexicon" => lexicon,
      "prototypes" => prototypes,
      "thresh" => @thresh,
      "margin" => @margin
    }

    File.write!(@out_path, :json.encode(out))

    Mix.shell().info(
      "predicate_model.json: #{map_size(lexicon)} words, #{map_size(prototypes)} buckets -> #{@out_path}"
    )
  end

  # The embedding matrix is one `embeddings` tensor [vocab, dim]. read!/1
  # returns a lazy container; copy it to the default backend so per-row
  # slicing below is a plain tensor op.
  defp load_embeddings(path) do
    %{"embeddings" => emb} = Safetensors.read!(path)
    Nx.backend_copy(emb)
  end

  # Token vectors of a word, in token order. `add_special_tokens: false`
  # matches model2vec, which embeds the bare token ids — verified
  # bit-identical to the Python export for in-lexicon words.
  defp token_vecs(word, tokenizer, embeddings) do
    {:ok, enc} = Tokenizers.Tokenizer.encode(tokenizer, word, add_special_tokens: false)

    enc
    |> Tokenizers.Encoding.get_ids()
    |> Enum.map(fn id -> embeddings[id] |> Nx.to_flat_list() end)
  end

  defp mean([first | _] = vectors) do
    n = length(vectors)

    vectors
    |> Enum.reduce(List.duplicate(0.0, length(first)), fn v, acc ->
      Enum.zip_with(v, acc, &+/2)
    end)
    |> Enum.map(&(&1 / n))
  end

  defp normalize(vec) do
    norm = :math.sqrt(Enum.reduce(vec, 0.0, fn x, a -> a + x * x end)) + 1.0e-9
    Enum.map(vec, &(&1 / norm))
  end

  # Match the Python export: vectors rounded to 3 decimals, measured to
  # leave classification unchanged while shrinking the asset.
  defp round3(x), do: Float.round(x * 1.0, 3)
  defp round3_vec(vec), do: Enum.map(vec, &round3/1)

  defp default_snapshot do
    base =
      Path.join([System.user_home!(), ".cache", "huggingface", "hub", @model_repo, "snapshots"])

    case File.ls(base) do
      {:ok, [snap | _]} ->
        Path.join(base, snap)

      _ ->
        Mix.raise("""
        Source model not found under #{base}.
        Download it once (any model2vec-aware tool) or pass --model-dir.
        """)
    end
  end
end
