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

  # Antonym pairs for `negate/2`. Declared one-directional; the lookup
  # map is built bidirectionally so `valid↔invalid` round-trips. Each
  # word maps to exactly one antonym — no word may appear on both sides
  # of different pairs, or the bidirectional fold would collide.
  @antonym_pairs [
    {"valid", "invalid"},
    {"authorized", "unauthorized"},
    {"enabled", "disabled"},
    {"present", "absent"},
    {"allowed", "forbidden"},
    {"active", "inactive"},
    {"visible", "hidden"},
    {"empty", "full"}
  ]

  @antonyms @antonym_pairs
            |> Enum.flat_map(fn {a, b} -> [{a, b}, {b, a}] end)
            |> Map.new()

  # Prefix-strip rules for morphological negation. Each prefix, when
  # present, is removed to recover the positive form (`unlocked →
  # locked`). The same prefixes are candidates for *adding* on the
  # fallback path, but `un_` is the canonical one we attach.
  @negation_prefixes ~w(un in dis)

  # Irregular past participles that carry no `-ed`/`-en` tell so the
  # ending heuristic can't class them as booleans. Boolean-shaped in
  # code (`found?`, `built?`, `sent?`) → fall back to `not_`. Open set
  # in principle; projects extend the effective behavior via
  # `opts[:known]`.
  @irregular_participles MapSet.new(~w(found built sent held kept met read run done))

  # Family registry for `pattern_family_suffix/1` — one
  # `{predicate, suffix}` per recognized clause shape. The predicate
  # receives the list of leading tags. Add a family by appending here;
  # call sites stay untouched.
  @name_families [{&__MODULE__.result_family?/1, "result"}]

  # Well-known mathematical constants for `derive_constant_name/2`,
  # matched within a float tolerance. Names are snake_case attribute
  # stems (no leading `@`).
  @well_known_floats [
    {"pi", :math.pi()},
    {"e", :math.exp(1)},
    {"sqrt2", :math.sqrt(2)},
    {"golden_ratio", (1 + :math.sqrt(5)) / 2}
  ]

  # Well-known integers for `derive_constant_name/2`. Exact match only —
  # these values carry the same meaning in any project. Extend by
  # appending a `{value, name}` pair.
  @well_known_ints %{
    60 => "seconds_per_minute",
    100 => "percent",
    255 => "max_byte",
    360 => "degrees_full",
    1000 => "kilo",
    1024 => "kibi",
    3600 => "seconds_per_hour",
    65_535 => "max_word",
    86_400 => "seconds_per_day"
  }

  # Call-name → name-stem heuristics for the `opts[:context]` axis. The
  # surrounding call (`String.slice`, `Enum.take`, …) names a bound on
  # its numeric argument. One `{call_substring, stem}` per recognized
  # shape, longest/most-specific first.
  @context_stems [
    {"slice", "max_slice"},
    {"truncate", "max_length"},
    {"take", "max_take"},
    {"chunk", "chunk_size"},
    {"timeout", "timeout"},
    {"retries", "max_retries"},
    {"retry", "max_retries"}
  ]

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

    case resolve_shortcut(short, opts) do
      {:halt, result} -> result
      :cont -> heuristic_resolve(short, candidates, opts)
    end
  end

  @doc """
  Like `resolve/3`, but returns the *full ranked* list of surviving
  long-form candidates instead of just the winner.

  The list is `[long_form]` ordered best-first (highest score first,
  ties broken by candidate order). `resolve/3` is exactly
  `List.first/1` of this list wrapped in `{:ok, _}`, or `:skip` when
  the list is empty.

  Callers that need a *fallback* expansion — e.g. resolving a
  collision where the first-choice long form is already taken by
  another binding in the same scope — walk this list for the next
  non-conflicting choice.

  Whitelist / stop-word / standalone-word shortcuts still suppress
  expansion entirely (empty list). A `known`-mapping shortcut returns
  a single-element list — there is no "second best" for an explicit
  mapping.

  ## Examples

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.resolve_ranked("xyz", [{"changeset", :alias}], %{})
      []
  """
  @spec resolve_ranked(String.t(), [candidate()], opts()) :: [String.t()]
  def resolve_ranked(short, candidates, opts) when is_binary(short) and is_list(candidates) do
    opts = normalize_opts(opts)

    case resolve_shortcut(short, opts) do
      {:halt, {:ok, long}} -> [long]
      {:halt, :skip} -> []
      :cont -> ranked_candidates(short, candidates, opts)
    end
  end

  @doc """
  Derive the antonym of a snake_case identifier.

  Resolution order (first hit wins):

  1. `opts[:known]` override — a project-supplied `.refactor.exs`
     mapping, same mechanism as `resolve/3`'s `known`.
  2. Built-in bidirectional antonym map (`valid↔invalid`, …).
  3. `is_<stem>` / `has_<stem>` predicate shapes — `is_` negates the
     stem recursively (`is_valid → is_invalid`), `has_` inserts `no_`
     (`has_value → has_no_value`).
  4. `not_<x>` strips to `<x>` (round-trip partner of the fallback).
  5. A leading `un`/`in`/`dis` prefix strips to the positive form.
  6. Fallback: prepend `not_`/`un_`. `<stem>` with no other rule gets
     `not_<stem>` so it round-trips with rule 4; everything else gets
     `un_<word>`.

  Always returns a string — never `:skip`. The fallback may produce a
  cosmetically odd name (`un_frobnicate`); callers that need a cleaner
  result should supply an `opts[:known]` override.

  ## Examples

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.negate("valid")
      "invalid"

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.negate("not_found")
      "found"
  """
  @spec negate(String.t(), %{optional(:known) => %{String.t() => String.t()}}) :: String.t()
  def negate(word, opts \\ %{}) when is_binary(word) do
    known = Map.get(opts, :known, %{})

    cond do
      Map.has_key?(known, word) -> Map.fetch!(known, word)
      Map.has_key?(@antonyms, word) -> Map.fetch!(@antonyms, word)
      true -> negate_morphological(word)
    end
  end

  defp negate_morphological(word) do
    cond do
      match?("is_" <> _, word) -> negate_predicate(word, "is_")
      match?("has_" <> _, word) -> "has_no_" <> trim_prefix(word, "has_")
      match?("not_" <> _, word) -> trim_prefix(word, "not_")
      stripped = strippable_prefix(word) -> stripped
      true -> fallback_negation(word)
    end
  end

  # No rule fired — guess the word class from its ending to pick a
  # prefix that reads naturally. Participle/adjective endings
  # (`-ed`/`-able`/`-ible`/`-en`) read as booleans → `not_`
  # (`not_found`, `not_editable`), the round-trip partner of the
  # `not_`-strip rule. Everything else → `un_` (`un_frobnicate`).
  defp fallback_negation(word) do
    if boolean_shaped?(word),
      do: "not_" <> word,
      else: "un_" <> word
  end

  defp boolean_shaped?(word) do
    String.ends_with?(word, ~w(ed able ible en)) or
      MapSet.member?(@irregular_participles, word)
  end

  defp negate_predicate("is_" <> stem, "is_"), do: "is_" <> negate(stem)

  # Strip the first matching `un`/`in`/`dis` prefix that leaves a
  # non-empty remainder. Returns the positive form, or nil when no
  # prefix applies (so the `cond` falls through to the `not_` fallback).
  defp strippable_prefix(word) do
    Enum.find_value(@negation_prefixes, fn prefix ->
      case word do
        <<^prefix::binary, rest::binary>> when rest != "" -> rest
        _ -> nil
      end
    end)
  end

  defp trim_prefix(word, prefix),
    do: binary_part(word, byte_size(prefix), byte_size(word) - byte_size(prefix))

  # Pre-heuristic shortcuts shared by `resolve/3` and
  # `resolve_ranked/3` — they must agree on whitelist/stop/known/
  # standalone-word handling so the ranked head always equals the
  # `resolve/3` winner. `:cont` means "fall through to scoring".
  defp resolve_shortcut(short, opts) do
    short_atom = String.to_atom(short)

    cond do
      # Whitelist: short is explicitly fine as-is.
      MapSet.member?(opts.whitelist, short_atom) ->
        {:halt, :skip}

      # Stop-list: never expand English function words.
      MapSet.member?(opts.stop_words, short_atom) ->
        {:halt, :skip}

      # Known mapping wins over heuristic. Project-supplied keys
      # override the built-in canonical abbreviations.
      Map.has_key?(opts.known, short) ->
        {:halt, {:ok, Map.fetch!(opts.known, short)}}

      Map.has_key?(@builtin_known, short) ->
        {:halt, {:ok, Map.fetch!(@builtin_known, short)}}

      # Standalone-word demotion: `short` is a deliberate subtoken
      # elsewhere in the module → don't expand.
      MapSet.member?(opts.module_subtokens, short) ->
        {:halt, :skip}

      true ->
        :cont
    end
  end

  defp heuristic_resolve(short, candidates, opts) do
    case ranked_candidates(short, candidates, opts) do
      [] -> :skip
      [best | _] -> {:ok, best}
    end
  end

  # Surviving long forms, best-first. `score_candidate` may emit the
  # same long form from several candidates; keep only the highest-
  # scoring occurrence so the list carries distinct expansions.
  defp ranked_candidates(short, candidates, opts) do
    candidates
    |> Enum.flat_map(&score_candidate(short, &1, opts))
    |> filter_by_threshold(opts.min_score)
    |> Enum.sort_by(fn {_long, score} -> score end, :desc)
    |> Enum.uniq_by(fn {long, _score} -> long end)
    |> Enum.map(fn {long, _score} -> long end)
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
    if start_idx == 0 and starts_hit < 2 do
      :skip
    else
      pp_transform_from(start_idx, starts_hit, subtokens, opts)
    end
  end

  defp pp_transform_from(start_idx, starts_hit, subtokens, opts) do
    last_idx = start_idx + starts_hit - 1
    last = Enum.at(subtokens, last_idx)
    head = Enum.take(subtokens, last_idx)

    singular_last = AstHelpers.singularize(last)

    case AstHelpers.maybe_past_participle(head, [last], singular_last, opts.pp_verbs) do
      {:ok, pp} -> {:ok, "#{pp}_#{singular_last}"}
      :skip -> :skip
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
        0..(length(subtokens) - 1)
        |> Enum.flat_map(&latch_candidate_at(short_chars, subtokens, &1))
        |> latch_best_candidate()
    end
  end

  defp latch_candidate_at(short_chars, subtokens, idx) do
    case latch_try_at(short_chars, subtokens, idx) do
      {:ok, starts_hit} -> [{idx, starts_hit}]
      :error -> []
    end
  end

  defp latch_best_candidate([]), do: :error

  defp latch_best_candidate(candidates) do
    {idx, starts_hit} =
      candidates |> Enum.max_by(fn {idx, starts_hit} -> {starts_hit, idx} end)

    {:ok, idx, starts_hit}
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

    if next_sub != nil and String.first(next_sub) == c do
      latch_consume_starts(rest, subtokens, next_idx + 1, next_sub, starts + 1)
    else
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

    if chars_in_last_sub <= 2 do
      true
    else
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

  # -----------------------------------------------------------------
  # Function-name synthesis — the naming root for every refactor that
  # invents a helper name. Consolidated here from the per-refactor
  # `synth_*`/`pattern_family_*` logic that used to live in
  # `extract_case_to_helper` and `AstHelpers`.
  # -----------------------------------------------------------------

  @doc """
  Derive a name for a hoisted constant (a magic number or config
  string lifted into a `@module_attribute`).

  Resolution (first hit wins):

  1. `opts[:key]` — when the literal sat at `key: value` (a config
     keyword or a map entry), the key *is* the name (`base_url`,
     `timeout`). `?`/`!` markers are stripped.
  2. `opts[:clause]` — a `{function_name, pattern}` pair when the
     literal was the body of a guard-free function clause
     (`defp image_width("md"), do: 80`). The function plus its
     discriminating pattern names the value (`image_width_md`); a
     numeric/unnameable pattern leaves the function name alone. Carries
     more meaning than the value, so it outranks the well-known axis.
  3. `opts[:context]` — the surrounding call name (`String.slice`,
     `Enum.take`, …). A recognized call names a bound on its numeric
     argument (`slice → max_slice`, `take → max_take`). No match →
     fall through.
  4. Well-known values — floats (`pi`, `e`, … within a tolerance) and
     integers (`60 → seconds_per_minute`, `1024 → kibi`, …).
  5. Millisecond multiples — a round multiple of `1000` reads as a
     second-scaled timeout: `5000 → timeout_5s_ms`.
  6. Value-in-name fallback — never fails and never collides:
     integer → `int_<value>` (`int_42`, negatives `int_neg_7`),
     float → `default_float`. A URL or absolute path names itself from
     its content — host (sans `www.`/TLD) + path segments + `_url`,
     path segments + `_path`; a value with nothing nameable (a bare IP,
     all-numeric segments) falls back to `default_url`/`default_string`.
     Any other string → `default_string`, anything else → `constant`.

  Always returns a snake_case string (no leading `@`); the caller
  renders the attribute.

  ## Examples

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.derive_constant_name("https://api.example.com", %{key: "base_url"})
      "base_url"

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.derive_constant_name("https://api.example.com/v1", %{})
      "api_example_v1_url"

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.derive_constant_name("/etc/myapp/config.toml", %{})
      "etc_myapp_config_toml_path"

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.derive_constant_name(3600, %{})
      "seconds_per_hour"

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.derive_constant_name(5000, %{})
      "timeout_5s_ms"

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.derive_constant_name(200, %{context: "slice"})
      "max_slice"

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.derive_constant_name(42, %{})
      "int_42"
  """
  @spec derive_constant_name(term(), %{
          optional(:key) => String.t() | atom() | nil,
          optional(:context) => String.t() | atom() | nil,
          optional(:clause) => {String.t(), String.t() | atom() | number() | nil} | nil
        }) :: String.t()
  def derive_constant_name(value, opts \\ %{}) do
    cond do
      key = Map.get(opts, :key) -> strip_marker(key)
      name = clause_name(Map.get(opts, :clause)) -> name
      name = context_name(value, Map.get(opts, :context)) -> name
      true -> derive_constant_name_from_value(value)
    end
  end

  @doc """
  Whether `derive_constant_name/2` produces a *meaningful* name for
  `value` under `opts`, as opposed to a bare value-in-name fallback
  (`int_42`, `default_float`, `default_string`).

  A caller that hoists a literal into a `@name` only gains clarity when
  the name says something the literal does not. When the only available
  derivation is the value itself, the indirection is pure loss — the
  caller should leave the literal inline. Returns `false` exactly for
  those fallback names.
  """
  @spec nameable?(term(), map()) :: boolean()
  def nameable?(value, opts \\ %{}) do
    derive_constant_name(value, opts) not in fallback_names(value)
  end

  defp fallback_names(value) when is_integer(value), do: ["int_#{encode_int(value)}"]
  defp fallback_names(value) when is_float(value), do: ["default_float"]
  defp fallback_names(_value), do: ["default_string", "default_url", "constant"]

  # Clause-head heuristic: a literal returned from a guard-free function
  # clause (`defp image_width("md"), do: 80`) names itself after the
  # function plus its discriminating pattern (`image_width_md`). The
  # pattern carries the meaning the bare value lacks, so this outranks
  # both the call-context and well-known axes. A numeric pattern adds no
  # word, so the function name stands alone; an unnameable pattern (no
  # surviving letters) likewise falls back to the function name.
  defp clause_name(nil), do: nil

  defp clause_name({fun, pattern}) when is_binary(fun) and fun != "" do
    case pattern_token(pattern) do
      nil -> fun
      token -> "#{fun}_#{token}"
    end
  end

  defp clause_name(_), do: nil

  defp pattern_token(pattern) when is_atom(pattern) and not is_nil(pattern),
    do: pattern_token(Atom.to_string(pattern))

  defp pattern_token(pattern) when is_binary(pattern) do
    case sanitize_token(pattern) do
      [token] -> token
      [] -> nil
    end
  end

  defp pattern_token(_), do: nil

  # Call-name heuristic: an integer bounded by a recognized call gets a
  # bound-shaped name. Only fires for integers under a matching call —
  # otherwise nil, so the value fallback takes over.
  defp context_name(value, context) when is_integer(value) and context not in [nil, ""] do
    str = to_string(context)
    Enum.find_value(@context_stems, fn {needle, stem} -> if str =~ needle, do: stem end)
  end

  defp context_name(_value, _context), do: nil

  defp derive_constant_name_from_value(value) when is_float(value) do
    case well_known_float(value) do
      nil -> "default_float"
      name -> name
    end
  end

  defp derive_constant_name_from_value(value) when is_integer(value) do
    cond do
      name = Map.get(@well_known_ints, value) -> name
      ms = millisecond_name(value) -> ms
      true -> "int_#{encode_int(value)}"
    end
  end

  defp derive_constant_name_from_value(value) when is_binary(value) do
    cond do
      url_shaped?(value) -> content_url_name(value) || "default_url"
      absolute_path?(value) -> content_path_name(value) || "default_string"
      true -> "default_string"
    end
  end

  defp derive_constant_name_from_value(_value), do: "constant"

  # A URL names itself after its host (sans `www.` and the TLD) plus its
  # path segments, suffixed `_url`: `https://api.example.com/v1` ->
  # `api_example_v1_url`. A host that survives sanitizing to nothing (a
  # bare IP, all-numeric segments) yields nil so the caller falls back.
  defp content_url_name(value) do
    uri = URI.parse(value)
    host_parts = host_tokens(uri.host)
    path_parts = path_tokens(uri.path)

    name_from_tokens(host_parts ++ path_parts, "url")
  end

  # An absolute path names itself after its segments, suffixed `_path`:
  # `/etc/myapp/config.toml` -> `etc_myapp_config_toml_path`.
  defp content_path_name(value) do
    value |> path_tokens() |> name_from_tokens("path")
  end

  defp host_tokens(nil), do: []

  defp host_tokens(host) do
    host
    |> String.replace_prefix("www.", "")
    |> String.split(".")
    |> drop_tld()
    |> Enum.flat_map(&sanitize_token/1)
  end

  # Drop the last label as a TLD only when more than one remains, so a
  # single-label host (`localhost`) keeps its only token.
  defp drop_tld([_single] = labels), do: labels
  defp drop_tld(labels), do: Enum.drop(labels, -1)

  defp path_tokens(nil), do: []
  defp path_tokens(""), do: []

  defp path_tokens(path),
    do: path |> String.split("/", trim: true) |> Enum.flat_map(&sanitize_token/1)

  # A path/host segment becomes one or more lowercase alphanumeric tokens;
  # any segment with no letters (`:id`, `127`, `*rest`) is dropped, so a
  # `:param`/numeric-only segment can't seed a name.
  defp sanitize_token(segment) do
    cleaned =
      segment |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")

    if cleaned == "" or not String.match?(cleaned, ~r/[a-z]/), do: [], else: [cleaned]
  end

  # Tokens + a kind suffix, deduped in order. Nil when no token carries a
  # letter — a bare-IP URL or all-numeric path has nothing to name itself.
  defp name_from_tokens([], _suffix), do: nil

  defp name_from_tokens(tokens, suffix) do
    (tokens ++ [suffix]) |> Enum.dedup() |> Enum.join("_")
  end

  defp absolute_path?(str), do: String.starts_with?(str, "/")

  # Round multiples of 1000 read as second-scaled ms timeouts.
  defp millisecond_name(value) when value > 1000 and rem(value, 1000) == 0,
    do: "timeout_#{div(value, 1000)}s_ms"

  defp millisecond_name(_value), do: nil

  defp encode_int(value) when value < 0, do: "neg_#{-value}"
  defp encode_int(value), do: Integer.to_string(value)

  # Match a float against well-known mathematical constants within a
  # tolerance — literal `3.14159…` rarely equals the BEAM's full-
  # precision constant bit-for-bit.
  defp well_known_float(value) do
    Enum.find_value(@well_known_floats, fn {name, constant} ->
      if abs(value - constant) < 1.0e-9, do: name
    end)
  end

  defp url_shaped?(str), do: String.starts_with?(str, ["http://", "https://", "ftp://", "ws://"])

  @doc """
  Synthesize a helper-function name from an operation and its
  carrier/output noun.

  This is the semantic entry point: callers say *what the helper does*
  (`operation`) and *what it works on* (`noun`), optionally tagging a
  recognized clause-pattern family via `opts[:clauses]` so result-style
  dispatch helpers get an `on_<noun>_result` shape.

  Resolution:

  - With `opts[:clauses]` that form a recognized pattern family →
    `on_<noun>_<family_suffix>` (the family encodes the dispatch
    identity, so `operation` is dropped as redundant).
  - Otherwise → `<operation>_<host>_<noun>` via `synth_compound_name/4`,
    where `host` (from `opts[:host]`) is dropped when `noun` already
    splits into 2+ subtokens.

  `?`/`!` markers on `operation`/`noun`/`host` are stripped — they'd
  terminate the identifier mid-name.

  ## Examples

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.generate_function_name("handle", "fetch_user_by_id")
      "handle_fetch_user_by_id"

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.generate_function_name("extracted", "", %{host: "render_row"})
      "extracted_render_row"
  """
  @spec generate_function_name(
          String.t() | atom() | nil,
          String.t() | atom() | nil,
          %{optional(:host) => String.t() | atom() | nil, optional(:clauses) => list()}
        ) :: String.t()
  def generate_function_name(operation, noun, opts \\ %{}) do
    op = strip_marker(operation)
    noun = strip_marker(noun)
    host = opts |> Map.get(:host) |> strip_marker()
    clauses = Map.get(opts, :clauses, [])

    case pattern_family_suffix(clauses) do
      nil -> synth_compound_name(op, host, noun, "")
      suffix -> synth_compound_name("on", "", noun, suffix)
    end
  end

  @doc """
  Build a synthesised helper name from up to four snake_case fragments.

  Fragments in order: `prefix`, `host`, `scrutinee`, `suffix`. Each is
  split on `_`, empty strings filtered out, then folded into a single
  list with **overlap-merge** at every seam — if the tail of the
  accumulator equals the head of the next fragment, the overlap is
  taken only once. Overlap is checked longest-first.

      [a, b, c] ⊕ [b, c, d]  →  [a, b, c, d]
      [a]       ⊕ [a]        →  [a]
      [a, b]    ⊕ [c, d]     →  [a, b, c, d]

  ## Host-drop heuristic

  If `scrutinee` splits into **2 or more subtokens**, `host` is treated
  as redundant and dropped — the scrutinee already encodes the dispatch
  identity. `prefix` and `suffix` still merge with the scrutinee.

      synth_compound_name("handle", "host", "fetch_user_by_id", "")
      → "handle_fetch_user_by_id"

  Single-token scrutinees keep `host`:

      synth_compound_name("handle", "host", "fetch", "")
      → "handle_host_fetch"

  Inputs may be strings, atoms, or `nil`/`""` (treated as empty).
  Caller is responsible for stripping `?`/`!` suffixes that would
  otherwise terminate identifiers mid-name.
  """
  @spec synth_compound_name(
          String.t() | atom() | nil,
          String.t() | atom() | nil,
          String.t() | atom() | nil,
          String.t() | atom() | nil
        ) :: String.t()
  def synth_compound_name(prefix, host, scrutinee, suffix) do
    prefix_parts = to_subtokens(prefix)
    host_parts = to_subtokens(host)
    scrutinee_parts = to_subtokens(scrutinee)
    suffix_parts = to_subtokens(suffix)

    fragments =
      if length(scrutinee_parts) >= 2 do
        [prefix_parts, scrutinee_parts, suffix_parts]
      else
        [prefix_parts, host_parts, scrutinee_parts, suffix_parts]
      end

    fragments
    |> Enum.reject(&(&1 == []))
    |> Enum.reduce([], &overlap_merge(&2, &1))
    |> Enum.join("_")
  end

  @doc """
  Recognize a pattern *family* across a list of `case`/`fn` clauses and
  return its semantic name suffix, or `nil` when no family matches.

  Generic by design — a family is "all clauses share a recognizable
  leading-tag shape". Each family is one `{predicate_on_leading_tags,
  suffix}` entry; add a family by appending a tuple to `@name_families`,
  call sites stay untouched. The canonical one is the `:ok`/`:error`
  result family → `"result"`.

  ## Examples

      iex> alias Number42.Refactors.IdentifierExpansion
      iex> IdentifierExpansion.pattern_family_suffix([])
      nil
  """
  @spec pattern_family_suffix(list()) :: String.t() | nil
  def pattern_family_suffix(clauses) do
    tags = Enum.map(clauses, &leading_tag/1)

    Enum.find_value(@name_families, fn {matches?, suffix} ->
      if matches?.(tags), do: suffix
    end)
  end

  @doc false
  # The result family: every clause leads with `:ok` or `:error` (bare
  # atom `:ok`/`:error` or a tagged tuple `{:ok, …}`/`{:error, …}`), with
  # at least one clause actually tagged so we don't fire on a plain
  # `:ok | :other` enum.
  def result_family?(tags) do
    Enum.all?(tags, &(&1 in [:ok, :error])) and :ok in tags
  end

  # The "leading tag" of a clause: the first element's atom when the
  # pattern is a tuple, or the atom itself for a bare-atom pattern. Any
  # other shape (bound var, `nil`, map, list, pin, …) has no leading tag.
  # Sourceror wraps atoms/literals in `:__block__`, hence the unwrapping.
  defp leading_tag({:->, _meta, [[pattern_node], _body]}) do
    {pattern, _guard} = unwrap_when(pattern_node)
    pattern_leading_tag(pattern)
  end

  defp leading_tag(_), do: nil

  # 2-element tuple: Sourceror represents `{a, b}` as a `:__block__`
  # wrapping a raw 2-tuple. The first element is the tag.
  defp pattern_leading_tag({:__block__, _, [{tag_node, _second}]}),
    do: atom_literal(tag_node)

  # 3+-element tuple: `{:{}, _, [first | _]}`.
  defp pattern_leading_tag({:{}, _, [first | _]}), do: atom_literal(first)

  # Bare atom pattern (`:ok`, `:error`, `nil`, …), possibly wrapped.
  defp pattern_leading_tag({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp pattern_leading_tag(atom) when is_atom(atom), do: atom
  defp pattern_leading_tag(_), do: nil

  defp atom_literal({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp atom_literal(atom) when is_atom(atom), do: atom
  defp atom_literal(_), do: nil

  defp unwrap_when({:when, _meta, [pat, guard]}), do: {pat, guard}
  defp unwrap_when(pat), do: {pat, nil}

  defp strip_marker(nil), do: nil

  defp strip_marker(name) do
    name
    |> to_string()
    |> String.replace_suffix("?", "")
    |> String.replace_suffix("!", "")
  end

  defp overlap_merge([], next), do: next
  defp overlap_merge(acc, []), do: acc

  defp overlap_merge(acc, next) do
    max_overlap = min(length(acc), length(next))

    overlap =
      max_overlap..1//-1
      |> Enum.find(0, fn n ->
        Enum.take(acc, -n) == Enum.take(next, n)
      end)

    acc ++ Enum.drop(next, overlap)
  end

  defp to_subtokens(nil), do: []
  defp to_subtokens(atom) when is_atom(atom), do: to_subtokens(Atom.to_string(atom))
  defp to_subtokens(str) when is_binary(str), do: String.split(str, "_", trim: true)
end
