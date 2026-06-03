defmodule Number42.Refactors.IdentifierExpansion do
  @moduledoc """
  Shared latch / candidate-resolution logic for the three
  `ExpandShortForm*` refactors (bindings, params, functions).

  ## Concept

  Given a *short* identifier (e.g. `cs`, `bi`, `ip`) and a list of
  *candidate compounds* drawn from the surrounding code (aliases,
  imports, module name, sibling identifiers, …), the resolver tries
  to pick the most plausible long-form expansion (`changeset`,
  `brand_item`, `item_position`).

  Each candidate is tagged with a **source trust level**:

  - `:alias`, `:import`, `:module_name` → `:strong` — the author
    deliberately named a module/alias this way, so 2-char shorts may
    latch against them.
  - `:local_def`, `:body_binding`, `:param`, `:rhs_call` → `:weak` —
    incidental local vocabulary; 2-char shorts are too noisy to
    expand against these.

  ## Pipeline

  1. `resolve/3` runs `latch_match/2` on each candidate.
  2. `score_latch/4` returns a base score (100/80/60/0) with
     trust-level and subsequence-in-tail penalties applied.
  3. A series of gates rejects pathological matches: standalone-word
     demotion (`module_subtokens`), inflection-symmetric self
     reference (`self` + plural/singular), subtoken-overlap with
     self (penalty, hard-reject if also in `scope_callables`).
  4. The highest scoring survivor at or above `min_score` (default
     `80`) wins.

  ## Bugs this guards against

  Each guard exists because of a real false-positive observed in
  refactor runs against `position-db`:

  - `op → operator_with_placeholder` — fn name latched against
    itself (singular-of-self).
  - `ast → asset_preview` — `st` slipped past `s,s,e` in `sset` via
    subsequence-in-tail.
  - `id → item_discontinuation` — 2-char short, weak source.
  - `is → image_signer` — same.
  - `oz → organization` — `z` skipped 5 chars in tail.
  - `ref → reference_building_item_position` — `e,f` as subsequence
    in `eference`.
  - `run → runner` — `run` is a standalone word elsewhere in the
    module; latching it as an abbreviation contradicts the author's
    intent.
  """

  alias Number42.Refactors.AstHelpers

  @type source_kind ::
          :alias
          | :import
          | :module_name
          | :enclosing_fn
          | :rhs_call
          | :local_def
          | :body_binding
          | :param
  @type candidate :: {String.t(), source_kind()}

  @type opts :: %{
          optional(:self) => String.t() | nil,
          optional(:module_subtokens) => MapSet.t(String.t()),
          optional(:scope_callables) => MapSet.t(String.t()),
          optional(:whitelist) => MapSet.t(atom()),
          optional(:stop_words) => MapSet.t(atom()),
          optional(:known) => %{String.t() => String.t()},
          optional(:pp_verbs) => MapSet.t(String.t()),
          optional(:treat_all_as_strong) => boolean(),
          optional(:min_score) => integer()
        }

  @strong_sources [:alias, :import, :module_name, :enclosing_fn, :rhs_call]

  # Canonical Elixir abbreviations whose expansion is unambiguous in
  # any project. These are merged into `opts[:known]` so projects
  # can still override them, but the default does the right thing
  # without per-project config.
  @builtin_known %{
    "attrs" => "attribute",
    "args" => "argument",
    "opts" => "option",
    "params" => "param"
  }

  @doc """
  Try to expand `short` against the given `candidates`.

  Returns `{:ok, long_form}` if a candidate scores at or above
  `opts[:min_score]` (default `80`) and survives all gates;
  otherwise `:skip`.

  ## Examples

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.resolve("cs", [{"changeset", :alias}], %{})
      {:ok, "changeset"}

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.resolve("xyz", [{"changeset", :alias}], %{})
      :skip
  """
  @spec resolve(String.t(), [candidate()], opts()) :: {:ok, String.t()} | :skip
  def resolve(short, candidates, opts) when is_binary(short) and is_list(candidates) do
    opts = normalize_opts(opts)
    short_atom = String.to_atom(short)

    cond do
      # Whitelist: short is explicitly fine as-is.
      MapSet.member?(opts.whitelist, short_atom) ->
        :skip

      # Stop-list: never expand English function words.
      MapSet.member?(opts.stop_words, short_atom) ->
        :skip

      # Known mapping wins over heuristic. Project-supplied keys
      # override the built-in canonical abbreviations.
      Map.has_key?(opts.known, short) ->
        {:ok, Map.fetch!(opts.known, short)}

      Map.has_key?(@builtin_known, short) ->
        {:ok, Map.fetch!(@builtin_known, short)}

      # Standalone-word demotion: `short` is a deliberate subtoken
      # elsewhere in the module → don't expand.
      MapSet.member?(opts.module_subtokens, short) ->
        :skip

      true ->
        heuristic_resolve(short, candidates, opts)
    end
  end

  defp heuristic_resolve(short, candidates, opts) do
    candidates
    |> Enum.flat_map(&score_candidate(short, &1, opts))
    |> filter_by_threshold(opts.min_score)
    |> pick_best()
  end

  defp score_candidate(short, {compound, source}, opts) do
    subtokens = String.split(compound, "_", trim: true)
    latch = latch_match(short, subtokens)

    case latch do
      :error ->
        []

      {:ok, _, _} = ok ->
        long = build_long(ok, subtokens, opts)
        base = score_latch(ok, short, subtokens, source, opts)
        penalized = apply_self_gates(base, long, source, opts)

        cond do
          penalized == :reject -> []
          penalized > 0 -> [{long, penalized}]
          true -> []
        end
    end
  end

  defp apply_self_gates(score, _long, _source, %{self: nil}), do: score

  defp apply_self_gates(score, long, source, %{self: self} = opts) do
    cond do
      inflection_variant_of_self?(long, self) ->
        :reject

      # When the candidate IS the enclosing function name, a subtoken
      # overlap is expected: the param `fb` in `render_formula_builder`
      # SHOULD resolve to `formula_builder`. No penalty.
      source == :enclosing_fn ->
        score

      subtoken_overlap_with_self?(long, self) ->
        if MapSet.member?(opts.scope_callables, long), do: :reject, else: score - 20

      true ->
        score
    end
  end

  defp inflection_variant_of_self?(long, self) do
    long == self or long == AstHelpers.singularize(self) or long == pluralize_simple(self)
  end

  defp subtoken_overlap_with_self?(long, self) do
    long_subs = String.split(long, "_", trim: true) |> MapSet.new()
    self_subs = String.split(self, "_", trim: true) |> MapSet.new()
    not MapSet.disjoint?(long_subs, self_subs)
  end

  defp pluralize_simple(word) do
    cond do
      String.ends_with?(word, "s") -> word
      String.ends_with?(word, "y") -> String.slice(word, 0..-2//1) <> "ies"
      true -> word <> "s"
    end
  end

  defp build_long({:ok, start_idx, starts_hit}, subtokens, opts) do
    case maybe_pp_transform(start_idx, starts_hit, subtokens, opts) do
      {:ok, pp_long} ->
        pp_long

      :skip ->
        subtokens
        |> Enum.drop(start_idx)
        |> Enum.take(starts_hit)
        |> singularize_last()
        |> Enum.join("_")
    end
  end

  # PP-promotion: when the candidate compound is `[verb, ..., plural_noun]`,
  # build `<past_participle>_<singular_noun>` instead of the plain
  # singularization. Two firing paths:
  #
  # 1. Full latch from idx 0 (`nk ↔ normalize_keys`): the latch
  #    consumed every subtoken, the verb is the head, the plural is
  #    the last consumed subtoken.
  # 2. Partial latch starting at idx > 0 with tail plural and at
  #    least one verb subtoken before the latch start
  #    (`cs ↔ build_changesets`: the latch only hit `changesets`, but
  #    `build` is the verb that explains the compound).
  #
  # In either case we ask AstHelpers.maybe_past_participle whether the
  # verb qualifies (verb-shaped suffix OR explicit pp_verbs entry).
  defp maybe_pp_transform(start_idx, starts_hit, subtokens, opts) do
    cond do
      start_idx == 0 and starts_hit < 2 ->
        :skip

      true ->
        last_idx = start_idx + starts_hit - 1
        last = Enum.at(subtokens, last_idx)
        head = Enum.take(subtokens, last_idx)

        singular_last = AstHelpers.singularize(last)

        case AstHelpers.maybe_past_participle(head, [last], singular_last, opts.pp_verbs) do
          {:ok, pp} -> {:ok, "#{pp}_#{singular_last}"}
          :skip -> :skip
        end
    end
  end

  defp singularize_last([]), do: []

  defp singularize_last(subs) do
    {head, [last]} = Enum.split(subs, -1)
    head ++ [AstHelpers.singularize(last)]
  end

  defp filter_by_threshold(scored, min_score) do
    scored |> Enum.filter(fn {_, score} -> score >= min_score end)
  end

  defp pick_best([]), do: :skip

  defp pick_best(scored) do
    {long, _score} = scored |> Enum.max_by(fn {_, s} -> s end)
    {:ok, long}
  end

  # -----------------------------------------------------------------
  # Latch matching — moved from AstHelpers, behavior preserved
  # -----------------------------------------------------------------

  @doc """
  Match a short identifier against a list of subtokens.

  Returns `{:ok, start_idx, starts_hit}` on success — where
  `start_idx` is the subtoken index where the match began and
  `starts_hit` is how many subtokens had their first character
  consumed by `short`.

  ## Examples

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.latch_match("bi", ~w(brand item))
      {:ok, 0, 2}

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.latch_match("cs", ~w(build changeset))
      {:ok, 1, 1}

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.latch_match("xyz", ~w(build changeset))
      :error
  """
  @spec latch_match(String.t(), [String.t()]) ::
          {:ok, non_neg_integer(), pos_integer()} | :error
  def latch_match(short, subtokens) when is_binary(short) and is_list(subtokens) do
    short_chars = String.graphemes(short)

    case {short_chars, subtokens} do
      {[], _} ->
        :error

      {_, []} ->
        :error

      _ ->
        candidates =
          0..(length(subtokens) - 1)
          |> Enum.flat_map(fn idx ->
            case latch_try_at(short_chars, subtokens, idx) do
              {:ok, starts_hit} -> [{idx, starts_hit}]
              :error -> []
            end
          end)

        case candidates do
          [] ->
            :error

          _ ->
            {idx, starts_hit} =
              candidates |> Enum.max_by(fn {idx, starts_hit} -> {starts_hit, idx} end)

            {:ok, idx, starts_hit}
        end
    end
  end

  defp latch_try_at([first | rest], subtokens, idx) do
    sub = Enum.at(subtokens, idx)

    if sub != nil and String.first(sub) == first do
      latch_consume_starts(rest, subtokens, idx + 1, sub, 1)
    else
      :error
    end
  end

  defp latch_consume_starts([], _subtokens, _next_idx, _last_sub, starts), do: {:ok, starts}

  defp latch_consume_starts([c | rest] = remaining, subtokens, next_idx, last_sub, starts) do
    next_sub = Enum.at(subtokens, next_idx)

    cond do
      next_sub != nil and String.first(next_sub) == c ->
        latch_consume_starts(rest, subtokens, next_idx + 1, next_sub, starts + 1)

      true ->
        last_sub_rest = String.slice(last_sub, 1..-1//1)
        if subsequence?(remaining, last_sub_rest), do: {:ok, starts}, else: :error
    end
  end

  defp subsequence?([], _haystack), do: true
  defp subsequence?(_chars, ""), do: false

  defp subsequence?([c | rest], haystack) do
    case :binary.match(haystack, c) do
      :nomatch -> false
      {pos, _} -> subsequence?(rest, String.slice(haystack, (pos + 1)..-1//1))
    end
  end

  # -----------------------------------------------------------------
  # Subsequence-in-tail detector — used both by score_latch and as a
  # public predicate (for tests / debugging).
  # -----------------------------------------------------------------

  @doc """
  Whether `latch_match(short, subtokens)` would have used a
  subsequence-with-skips inside the last consumed subtoken.

  `true` means: at least one character of `short` was matched at a
  position > 0 within a single subtoken, with intervening chars
  skipped. Pure initials matches are `false`; single-char tail
  matches (`cs ↔ changeset`: just `s` lands somewhere in
  `hangeset`) are also `false` — there is no "skip" if only one
  char remains.

  Used by `score_latch/4` to apply a -30 penalty.
  """
  @spec consumed_via_subsequence_in_tail?(String.t(), [String.t()]) :: boolean()
  def consumed_via_subsequence_in_tail?(short, subtokens) when is_binary(short) do
    case latch_match(short, subtokens) do
      :error ->
        false

      {:ok, start_idx, starts_hit} ->
        consumed_chars = starts_hit
        short_len = String.length(short)
        tail_chars = short_len - consumed_chars

        # Only count it as "subsequence" if 2+ chars went into the tail
        # of a single subtoken (so there was room for a skip).
        tail_chars >= 2 and last_sub_has_skips?(short, subtokens, start_idx, starts_hit)
    end
  end

  defp last_sub_has_skips?(short, subtokens, start_idx, starts_hit) do
    short_chars = String.graphemes(short)
    consumed_initials = Enum.take(short_chars, starts_hit)
    tail_chars = Enum.drop(short_chars, starts_hit)
    last_sub = Enum.at(subtokens, start_idx + starts_hit - 1)

    _ = consumed_initials
    last_sub_rest = String.slice(last_sub, 1..-1//1)

    # "Contiguous" means tail_chars appear as a contiguous block in
    # last_sub_rest. If they appear contiguously, no skip. Otherwise,
    # subsequence-with-skips happened.
    tail_str = tail_chars |> Enum.join()
    not contiguous_substring?(tail_str, last_sub_rest)
  end

  defp contiguous_substring?(needle, haystack) do
    case :binary.match(haystack, needle) do
      :nomatch -> false
      _ -> true
    end
  end

  # -----------------------------------------------------------------
  # Scoring
  # -----------------------------------------------------------------

  @doc """
  Score a latch result.

  Returns 0–100. Threshold for acceptance lives in `resolve/3` via
  `opts[:min_score]` (default `80`).

  ## Scoring rules

  - **100** — all subtokens consumed by initials of `short` (at
    least 2 initials).
  - **80** — initials of a prefix of `subtokens` consumed (at least
    2 initials).
  - **100** — single initial + tail that fits the in-subtoken
    contribution rule (see below).
  - **0** — no match; weak source with `length(short) < 3`; or any
    single subtoken contributed > 2 chars to the match AND those
    chars include a vowel.

  ## In-subtoken contribution rule

  At most 2 chars of `short` may land inside a single subtoken
  (1 initial + 1 tail char). More than that is a coincidence-match
  — unless the contributed chars are *all consonants*, indicating a
  deliberate consonant-only abbreviation like `mngr ↔ manager` or
  `brnd ↔ brand`.

  Examples:
  - `cs ↔ changeset`: 2 chars in `changeset` → ok → 100.
  - `oz ↔ organization`: 2 chars → ok → 100.
  - `ast ↔ asset`: 3 chars (`a,s,t`), `a` is a vowel → 0.
  - `mngr ↔ manager`: 4 chars, all consonants → ok → 100.
  """
  @spec score_latch(
          {:ok, non_neg_integer(), pos_integer()} | :error,
          String.t(),
          [String.t()],
          source_kind()
        ) :: integer()
  def score_latch(:error, _short, _subtokens, _source), do: 0

  def score_latch({:ok, start_idx, starts_hit}, short, subtokens, source, opts \\ %{}) do
    trust = source_trust(source, opts)
    short_len = String.length(short)

    cond do
      trust == :weak and short_len < 3 ->
        0

      not in_subtoken_contribution_ok?(short, starts_hit) ->
        0

      true ->
        base_score(starts_hit, length(subtokens), start_idx)
    end
  end

  defp source_trust(_source, %{treat_all_as_strong: true}), do: :strong
  defp source_trust(source, _opts) when source in @strong_sources, do: :strong
  defp source_trust(_, _), do: :weak

  # The last consumed subtoken absorbs 1 initial + all leftover chars
  # of `short`. If that's > 2, we require the contributed chars to be
  # consonant-only.
  defp in_subtoken_contribution_ok?(short, starts_hit) do
    short_len = String.length(short)
    tail_len = short_len - starts_hit
    chars_in_last_sub = 1 + tail_len

    cond do
      chars_in_last_sub <= 2 ->
        true

      true ->
        # Take the first `chars_in_last_sub` chars from `short` starting
        # at the last consumed initial's index. Those are the chars that
        # ended up in the last subtoken.
        last_sub_chars =
          short
          |> String.graphemes()
          |> Enum.drop(starts_hit - 1)

        Enum.all?(last_sub_chars, &consonant?/1)
    end
  end

  defp consonant?(c) when c in ~w(a e i o u y A E I O U Y), do: false
  defp consonant?(_), do: true

  defp base_score(starts_hit, subtoken_count, _start_idx) do
    cond do
      starts_hit >= 2 and starts_hit == subtoken_count -> 100
      starts_hit >= 2 -> 80
      starts_hit == 1 -> 100
      true -> 0
    end
  end

  # -----------------------------------------------------------------
  # Internal helpers
  # -----------------------------------------------------------------

  defp normalize_opts(opts) do
    %{
      self: Map.get(opts, :self, nil),
      module_subtokens: Map.get(opts, :module_subtokens, MapSet.new()),
      scope_callables: Map.get(opts, :scope_callables, MapSet.new()),
      whitelist: Map.get(opts, :whitelist, MapSet.new()),
      stop_words: Map.get(opts, :stop_words, MapSet.new()),
      known: Map.get(opts, :known, %{}),
      pp_verbs: Map.get(opts, :pp_verbs, MapSet.new()),
      treat_all_as_strong: Map.get(opts, :treat_all_as_strong, false),
      min_score: Map.get(opts, :min_score, 80)
    }
  end
end
