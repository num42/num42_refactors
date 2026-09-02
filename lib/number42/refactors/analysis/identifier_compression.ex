defmodule Number42.Refactors.Analysis.IdentifierCompression do
  @moduledoc """
  Shorten an over-long identifier by dropping the tokens that carry the least
  information, keeping the ones that name the thing.

      build_serie_match_conditions_match_fields
      #=> build_serie_match_conditions

  ## Rules

  An identifier is split on word boundaries (`_` and camel humps), with a
  trailing `?`/`!` held aside as a sigil. Below `@trigger` tokens nothing
  happens — a five-token name is where a reader starts losing the thread.

  Tokens are then dropped, weakest first, until `@target` remain:

    1. **Immune positions never go.** The first token is the verb and the last
       is the head noun; together they carry the sentence. Before a `?`/`!` the
       second-to-last is immune as well, since `user?` reads as a different
       question than `current_user?`.
    2. **Repeats are dropped** — matched on a stem, so `position`/`positions`
       and `match`/`matched` count as one token. A name repeating a word says
       nothing the first occurrence did not.
    3. **Filler is dropped** — articles, prepositions, and the words that name
       no domain (`data`, `value`, `info`, `binding`). They read as structure,
       not as meaning.
    4. **Cryptic tokens are dropped** — up to `@cryptic_length` characters and
       not a known short word. A reader cannot recover what `qq` meant anyway.
    5. **The rest goes by corpus rarity.** A token every identifier in the
       codebase carries (`conditions` in a query module) discriminates nothing
       *there*, however meaningful it is in the abstract; the rare token is what
       tells this identifier from its neighbours. Ranked by inverse document
       frequency over the identifier corpus, lowest first.

  Order is never reshuffled and the compression is idempotent: a name that came
  out of it is already at or below `@target`, so it compresses to itself.
  """

  alias Number42.Refactors.Analysis.AstHelpers

  @trigger 5
  @target 4
  @floor 2
  @cryptic_length 2

  # Structural words: they hold a sentence together and name nothing in the domain.
  @filler ~w(
    a an the and or of for with from to in on at by as into per via
    data value values info object obj item items thing things
    binding bindings temp tmp result results helper util utils
    current given some any new old
  )
  # Short by convention rather than by sloppiness, so they read fine mid-name.
  @known_short ~w(id ids db ui js os io ok up to at by of ex px mm cm gl uv)

  @doc """
  Split `name` into its word tokens and its trailing `?`/`!` sigil.

      iex> alias Number42.Refactors.Analysis.IdentifierCompression
      iex> IdentifierCompression.parts("node_search_other_nodes!")
      {["node", "search", "other", "nodes"], "!"}
  """
  @spec parts(String.t() | atom()) :: {[String.t()], String.t()}
  def parts(name) when is_atom(name), do: name |> Atom.to_string() |> parts()

  def parts(name) when is_binary(name) do
    {base, sigil} =
      case String.last(name) do
        s when s in ["?", "!"] -> {String.slice(name, 0..-2//1), s}
        _ -> {name, ""}
      end

    tokens =
      base
      |> Macro.underscore()
      |> String.split("_", trim: true)

    {tokens, sigil}
  end

  @doc """
  How many of `names` each token appears in, counting an identifier once per
  token. This is the document frequency the rarity ranking reads.
  """
  @spec corpus([String.t() | atom()]) :: %{String.t() => pos_integer()}
  def corpus(names) do
    names
    |> Enum.flat_map(fn name ->
      {tokens, _sigil} = parts(name)
      tokens |> Enum.uniq()
    end)
    |> Enum.frequencies()
  end

  @doc """
  A shorter name for `name`, or `:keep` when it is already short enough or
  nothing could be dropped.

  `corpus` is the document-frequency map from `corpus/1`. The ranking needs no
  corpus size: for a fixed codebase, inverse document frequency is monotone in
  the document frequency, so the raw count orders the tokens the same way.
  """
  @spec compress(String.t() | atom(), map(), keyword()) :: {:ok, String.t()} | :keep
  def compress(name, corpus, opts \\ [])

  def compress(name, corpus, opts) when is_atom(name),
    do: compress(Atom.to_string(name), corpus, opts)

  def compress(name, corpus, opts) when is_binary(name) do
    {tokens, sigil} = parts(name)

    if length(tokens) < @trigger do
      :keep
    else
      kept = prune(tokens, sigil, corpus, opts)
      rebuilt = Enum.join(kept, "_") <> sigil

      if rebuilt == name, do: :keep, else: {:ok, rebuilt}
    end
  end

  defp prune(tokens, sigil, corpus, _opts) do
    immune = immune_indexes(tokens, sigil)
    indexed = Enum.with_index(tokens)

    indexed
    |> drop_repeats(immune)
    |> drop_all(immune, &filler?/1)
    |> drop_all(immune, &cryptic?/1)
    |> drop_by_rarity(immune, corpus)
    |> Enum.map(&elem(&1, 0))
  end

  # The verb and the head noun; before a sigil the qualifier in front of it too.
  defp immune_indexes(tokens, sigil) do
    last = length(tokens) - 1
    base = [0, last]

    if sigil != "" and last - 1 >= 0,
      do: MapSet.new([last - 1 | base]),
      else: MapSet.new(base)
  end

  defp drop_repeats(indexed, immune) do
    {kept, _seen} =
      Enum.reduce(indexed, {[], MapSet.new()}, fn {token, index} = entry, {kept, seen} ->
        stem = stem(token)

        cond do
          MapSet.member?(immune, index) -> {[entry | kept], MapSet.put(seen, stem)}
          MapSet.member?(seen, stem) -> {kept, seen}
          true -> {[entry | kept], MapSet.put(seen, stem)}
        end
      end)

    Enum.reverse(kept)
  end

  # Filler and cryptic tokens are dropped whether or not the name is still over
  # target — a slot spent on `data` or `qq` is a slot wasted at any length.
  defp drop_all(indexed, immune, weak?) do
    Enum.reduce(indexed, indexed, fn {token, index} = entry, acc ->
      if length(acc) > @floor and not MapSet.member?(immune, index) and weak?.(token) do
        List.delete(acc, entry)
      else
        acc
      end
    end)
  end

  # Whatever is still over target goes by rarity: the token the corpus repeats
  # most discriminates least here.
  defp drop_by_rarity(indexed, immune, corpus) do
    droppable =
      indexed
      |> Enum.reject(fn {_token, index} -> MapSet.member?(immune, index) end)
      # On equal frequency the earlier token goes: the tail sits closest to the
      # head noun, while a leading qualifier is the part a reader can infer.
      |> Enum.sort_by(fn {token, index} -> {-document_frequency(token, corpus), index} end)

    over = length(indexed) - @target

    droppable
    |> Enum.take(max(over, 0))
    |> Enum.reduce(indexed, fn entry, acc ->
      if length(acc) > @floor, do: List.delete(acc, entry), else: acc
    end)
  end

  # An unseen token is treated as maximally rare, so a name is never shortened
  # by dropping the one word the corpus never says.
  defp document_frequency(token, corpus), do: Map.get(corpus, token, 0)

  defp filler?(token), do: token in @filler

  defp cryptic?(token) do
    String.length(token) <= @cryptic_length and token not in @known_short
  end

  # Cheap stemming: singularize, then strip the inflections that keep two
  # spellings of one word from matching.
  defp stem(token) do
    token
    |> AstHelpers.singularize()
    |> String.replace_suffix("ing", "")
    |> String.replace_suffix("ed", "")
    |> case do
      "" -> token
      stemmed -> stemmed
    end
  end
end
