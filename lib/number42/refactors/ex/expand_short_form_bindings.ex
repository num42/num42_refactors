defmodule Number42.Refactors.Ex.ExpandShortFormBindings do
  @moduledoc """
  Renames short-form local bindings to their long form within a single
  function body.

      def render(formula_builder, assigns) do
        fb = formula_builder
        cs = build_changeset(fb)
        ...
      end
      ↓
      def render(formula_builder, assigns) do
        formula_builder = formula_builder
        changeset = build_changeset(formula_builder)
        ...
      end

  ## How it works

  For each `def`/`defp`/`defmacro`/`defmacrop` clause body, we walk
  every `name = rhs` binding where the LHS is a bare-var atom (not a
  destructuring pattern). For each short-form name we resolve a single
  unambiguous long form via:

  1. **Known mapping** — a hand-curated table for terms that recur in
     this codebase: `org_id → organization_id`, `cs → changeset`, etc.
  2. **Smart match** against context tokens drawn from (in order of
     locality) the enclosing function name, function parameters,
     other long-form bindings in the body, and the module name.

  The smart match scores each candidate token:

  - **100** — initial-of-each-subtoken match (`fb` ↔ `formula_builder`).
  - **80**  — initial match over a subset of subtokens (`fbn` ↔
    `formula_builder_node`, ignoring inner subtokens).
  - **40**  — subsequence inside a single subtoken (`cs` ↔ `changeset`).

  The highest-scoring candidate wins. Ties between distinct long forms
  → skip (ambiguous; the human disambiguates).

  ## When we skip

  - Whitelisted names (`id`, `pid`, `key`, ..., plus the universally-OK
    short forms like `ast`, `ids`, `new`, `idx`, `api`, `top`, `has`,
    `had`, `all`).
  - The name is bound more than once in the same function (potential
    rebinding / shadowing — too risky to rename without scope tracking).
  - The long form is already a name in scope (parameter, other binding,
    or a previously-resolved short form in the same function).
  - No long-form candidate scores above zero.
  - Multiple long-form candidates tie at the same top score.

  ## Why procedural

  Scope-aware token collection plus per-function multi-site rename
  needs cross-node coordination. The declarative DSL can't express
  "find all `cs` references in this body and rename them together".
  """

  use Number42.Refactors.Refactor

  @impl Number42.Refactors.Refactor
  def description, do: "Expand short-form local bindings to long forms"

  @impl Number42.Refactors.Refactor
  def priority, do: 250

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Short-form bindings (`cs`, `fb`, `org_id`) save keystrokes for the
    author and cost reading time for everyone after — readers have to
    scan the surrounding code to learn what each abbreviation means.
    Renaming to long forms (`changeset`, `formula_builder`,
    `organization_id`) makes the data flow self-describing. We only
    rename when a single long form is unambiguous from context, so the
    rewrite is safe and reviewable.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  # Universal short names: Elixir keywords, Phoenix/Ecto idioms,
  # math/loop conventions, single letters. Project-specific shorts
  # (domain acronyms like `oz`, `ip`) belong in `.refactor.exs`
  # under `whitelist:` and are merged in at runtime.
  # Whitelist and known mapping live in `.refactor.exs` — single
  # source of truth shared by all ExpandShortForm refactors.
  @default_whitelist MapSet.new()

  # Project-specific abbreviations live in `.refactor.exs` under
  # `configured_modules` for this refactor — keeps domain knowledge
  # out of the engine module. The empty default here means: with no
  # config, only the smart matchers (RHS / compound context) fire.
  @known %{}

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    ctx = build_ctx(opts)

    Sourceror.parse_string(source) |> apply_patches(ctx, source)
  end

  # Per-call context bag: collects every config-driven knob so we can
  # thread one value through the walk instead of multiple parameters.
  defp build_ctx(opts) do
    extra_whitelist = opts |> Keyword.get(:whitelist, []) |> Enum.map(&to_atom/1) |> MapSet.new()

    %{
      known: Map.merge(@known, Keyword.get(opts, :known, %{})),
      pp_verbs: opts |> Keyword.get(:pp_verbs, []) |> MapSet.new(),
      whitelist: MapSet.union(@default_whitelist, extra_whitelist)
    }
  end

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_atom(s)

  defp build_patches(ast, ctx) do
    module_tokens = collect_module_tokens(ast)

    ast
    |> collect_def_clauses()
    |> Enum.flat_map(fn {def_node, body} ->
      patches_for_clause(def_node, body, module_tokens, ctx)
    end)
  end

  defp collect_module_tokens(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [{:__aliases__, _, parts}, _]} when is_list(parts) ->
        parts |> Enum.map(&camel_to_snake/1)

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp camel_to_snake(atom) when is_atom(atom) do
    atom |> Atom.to_string() |> Macro.underscore()
  end

  defp collect_def_clauses(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {kind, _, [head, body_kw]}
      when def_or_macro_kind?(kind) and is_list(body_kw) ->
        body_kw
        |> Enum.flat_map(fn
          {{:__block__, _, [:do]}, body} -> [{head, body}]
          {:do, body} -> [{head, body}]
          _ -> []
        end)

      _ ->
        []
    end)
  end

  defp patches_for_clause(head, body, module_compounds, ctx) do
    {fn_name, params} = head_signature(head)
    fn_compound = Atom.to_string(fn_name)
    param_names = params |> Enum.flat_map(&pattern_var_names/1)
    param_compounds = param_names |> Enum.map(&Atom.to_string/1)

    collected_binding = collect_bindings(body)

    long_names_in_body =
      collected_binding |> Enum.map(fn {name, _, _} -> name end) |> Enum.filter(&long?(&1, ctx))

    long_compounds_in_body = long_names_in_body |> Enum.map(&Atom.to_string/1)

    # Every var the rename could shadow if it picked that long-form.
    # `bound_in/1` covers every binder shape — `=` LHS, lambda params,
    # case/cond/with patterns, comprehension generators — so we don't
    # need to special-case lambdas vs assignments here. Plus function
    # params for completeness (they're bound at the head, not in body).
    occupied =
      body
      |> bound_in()
      |> MapSet.union(MapSet.new(param_names))

    # Names bound more than once in the body — skip (rebinding makes
    # rename unsafe without scope tracking).
    rebound =
      collected_binding
      |> Enum.frequencies_by(fn {name, _, _} -> name end)
      |> Enum.filter(fn {_n, c} -> c > 1 end)
      |> Enum.map(fn {n, _} -> n end)
      |> MapSet.new()

    # Context candidates are FULL underscore-joined compounds, in order
    # of locality (innermost first wins ties). The smart matcher needs
    # the whole compound to compute initial-of-each-subtoken matches —
    # splitting first would lose `formula_builder` as a unit.
    context_compounds =
      (param_compounds ++ long_compounds_in_body ++ [fn_compound] ++ module_compounds)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == ""))

    short_bindings =
      collected_binding |> Enum.filter(fn {name, _, _} -> short_name?(name, ctx) end)

    # Resolve: short-name → long-name (atom) per binding.
    resolutions =
      short_bindings
      |> Enum.reject(fn {name, _node, _rhs} -> MapSet.member?(rebound, name) end)
      |> Enum.flat_map(fn {name, _node, rhs} ->
        case resolve_long(name, rhs, context_compounds, ctx) do
          {:ok, long} ->
            long_atom = String.to_atom(long)
            if MapSet.member?(occupied, long_atom), do: [], else: [{name, long_atom}]

          :skip ->
            []
        end
      end)
      |> Map.new()

    # Build patches: every reference to a resolved name in the body
    # becomes the long form.
    body
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {name, _meta, ctx} = node when is_atom(name) and is_atom(ctx) ->
        case Map.fetch(resolutions, name) do
          {:ok, long_atom} ->
            replacement = Atom.to_string(long_atom)

            case build_patch(node, replacement) do
              nil -> []
              patch -> [patch]
            end

          :error ->
            []
        end

      _ ->
        []
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Match-failure means we couldn't recover a name for the head; signal
  # that to the caller so it skips this clause.
  defp head_signature(head), do: extract_fn_signature(head) |> name_args_or_unknown()

  defp collect_bindings(body) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:=, _, [{name, _, ctx} = lhs, rhs]} when is_atom(name) and is_atom(ctx) ->
        [{name, lhs, rhs}]

      {:fn, _, [{:->, _, [params, _body]}]} when is_list(params) ->
        params |> Enum.flat_map(&lambda_param_binding/1)

      {:<-, _, [pattern, rhs]} ->
        for_generator_bindings(pattern, rhs)

      _ ->
        []
    end)
  end

  defp lambda_param_binding({name, _, ctx} = node) when is_atom(name) and is_atom(ctx) do
    if underscore?(name), do: [], else: [{name, node, node}]
  end

  defp lambda_param_binding(_), do: []

  defp for_generator_bindings(pattern, rhs),
    do: top_level_bindings(pattern, rhs) ++ map_key_bindings(pattern)

  defp top_level_bindings({name, _, ctx} = node, rhs) when is_atom(name) and is_atom(ctx) do
    if underscore?(name), do: [], else: [{name, node, rhs}]
  end

  defp top_level_bindings({:=, _, [_lhs, rhs_pat]}, rhs),
    do: top_level_bindings(rhs_pat, rhs)

  defp top_level_bindings(_other, _rhs), do: []

  defp map_key_bindings(pattern) do
    pattern
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:%{}, _, pairs} when is_list(pairs) -> pairs |> Enum.flat_map(&map_key_binding/1)
      _ -> []
    end)
  end

  defp map_key_binding({key_ast, {name, _, ctx} = node})
       when is_atom(name) and is_atom(ctx) do
    key_atom(key_ast) |> binding_from_key(name, node)
  end

  defp map_key_binding(_), do: []

  defp key_atom({:__block__, _, [atom]}) when is_atom(atom), do: {:ok, atom}
  defp key_atom(atom) when is_atom(atom), do: {:ok, atom}
  defp key_atom(_), do: :error

  defp long?(name, ctx), do: not short_name?(name, ctx)

  # Resolve order:
  # 1. Known table (explicit human-curated mapping).
  # 2. RHS-based match — extract the function name from the right-hand
  #    side, score `short` against it. Strongest contextual signal:
  #    `cs = build_changeset(x)` → `cs` clearly means `changeset`. Also
  #    the only path that fires for single-letter names.
  # 3. Compound-context match — initial-of-each-subtoken against
  #    function-name / parameters / body bindings / module-name
  #    compounds.
  defp resolve_long(name, rhs, context_compounds, ctx) do
    string = Atom.to_string(name)

    cond do
      Map.has_key?(ctx.known, string) ->
        {:ok, Map.fetch!(ctx.known, string)}

      true ->
        {rhs_compound, rhs_is_call?} = rhs_function_compound(rhs)
        compound_candidates = score_compound_candidates(string, context_compounds, ctx)

        # RHS-match is rated higher than any compound-context match.
        # If RHS yielded a hit, take its target (the subtoken slice
        # corresponding to `short`'s initials); otherwise fall back to
        # compound matches.
        case rhs_compound && rhs_target(string, rhs_compound, rhs_is_call?, ctx) do
          {:ok, target} -> {:ok, target}
          _ -> choose_winner(compound_candidates)
        end
    end
  end

  # Pick the single winning candidate or `:skip` on tie / empty.
  # Each candidate is `{target, score}` where `target` is the resolved
  # long form (already subtoken-sliced and singularized).
  defp choose_winner([]), do: :skip
  defp choose_winner([{target, _}]), do: {:ok, target}
  defp choose_winner([{target, s1}, {_other, s2} | _]) when s1 > s2, do: {:ok, target}
  defp choose_winner(_tie), do: :skip

  defp score_compound_candidates(short, context_compounds, ctx) do
    context_compounds
    # Self-match would be a no-op rename; filter early.
    |> Enum.reject(&(&1 == short))
    |> Enum.flat_map(fn compound ->
      case score_compound(short, compound, ctx) do
        {score, target} when score > 0 -> [{target, score}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {_target, score} -> -score end)
  end

  # Compound-context score (function/param/body/module names).
  # Returns `{score, target}` or `{0, nil}`.
  #
  # 100: every char of `short` is the initial of a subtoken of compound,
  #      consuming subtokens left-to-right. `fb` ↔ `formula_builder`,
  #      target = whole compound (singularized).
  # 80:  initial-prefix of compound. `fb` ↔ `formula_builder_node` —
  #      first 2 initials match; target = first 2 subtokens (singularized).
  # 0:   anything else. We deliberately do NOT score subsequence or
  #      Prefix-of-Single-Subtoken matches: too many spurious hits for
  #      tiny names (`c` ↔ `color`, `cs` ↔ `coords`/`cycles`/`cells`).
  #
  # Single-letter shorts can never score here: the `>= 2` guard.
  defp score_compound(short, compound, ctx) do
    subtokens = String.split(compound, "_", trim: true)
    initials = subtokens |> Enum.map_join("", &String.first/1)
    n = String.length(short)

    cond do
      short == initials and n >= 2 ->
        {100, singularize_compound(subtokens, ctx)}

      String.starts_with?(initials, short) and n >= 2 ->
        {80, subtokens |> Enum.take(n) |> singularize_compound(ctx)}

      true ->
        {0, nil}
    end
  end

  # RHS-based match. We extract the *function name* from the right-hand
  # side — the strongest hint of what the bound value represents:
  #
  #   cs = build_changeset(x)         → rhs compound: `build_changeset`
  #   c  = build_changeset(x)         → rhs compound: `build_changeset`
  #   pl = Pricing.get_price_list(id) → rhs compound: `get_price_list`
  #   pls = list_price_lists()         → rhs compound: `list_price_lists`
  #
  # Match algorithm: find the earliest subtoken `i` such that
  # subtokens[i] starts with short[0] AND the remaining short chars
  # appear as an in-order subsequence within the concatenated text of
  # subtokens[i..]. The tail is subtokens[i..]; the head is the
  # preceding subtokens (kept for past-participle promotion).
  #
  # Examples:
  #   cs ↔ build_changeset    → tail=[changeset]            → "changeset"
  #   pls ↔ list_price_lists   → tail=[price, lists]         → "price_list"
  #   pl ↔ get_price_list      → tail=[price, list]          → "price_list"
  #   bc ↔ build_changesets    → tail=[changesets]           → "changeset"
  #
  # Length-1 shorts are accepted here because the RHS function name
  # disambiguates the intent. The compound-context path forbids
  # length-1 shorts because they have no intent signal.
  defp rhs_target(short, rhs_compound, rhs_is_call?, ctx) do
    subtokens = String.split(rhs_compound, "_", trim: true)

    latch_match(short, subtokens)
    |> tail_compound_from_latch(ctx, short, subtokens, rhs_is_call?)
  end

  # Compose the RHS target. Default: drop the head, keep the
  # singularized tail. The head is only revived for past-participle
  # promotion (`nk = normalize_keys(...)` → `normalized_key`).
  #
  # We don't sanity-check whether the tail is "good enough" — `t =
  # String.trim(line)` becoming `trim` is a borderline case, but the
  # programmer chose `t`; the rewrite to `trim` is at worst no worse.
  defp rhs_target_from_split(subtokens, n, ctx, rhs_is_call?) do
    {head, tail} = subtokens |> Enum.split(-n)
    singularized = tail |> List.last() |> singularize()
    tail_compound = (Enum.drop(tail, -1) ++ [singularized]) |> Enum.join("_")

    pp =
      if rhs_is_call? do
        maybe_past_participle(head, tail, singularized, ctx.pp_verbs)
      else
        :skip
      end

    prepend_pp_or_keep(pp, tail_compound)
  end

  # Compound-context path: param names, module names, function names.
  # Those are noun compounds, not verb phrases — singularize the
  # trailing subtoken only, no PP promotion.
  defp singularize_compound(subtokens, _ctx) when is_list(subtokens) do
    case subtokens |> Enum.split(-1) do
      {head, [last]} -> (head ++ [singularize(last)]) |> Enum.join("_")
      {_, []} -> ""
    end
  end

  # Returns `{compound_string | nil, is_call?}`. `is_call?` distinguishes
  # `cs = build_changeset(x)` (real call → PP-promotion allowed for
  # matching pluralized tails) from `rbip <- record.field_path`
  # (property access → no PP, the field IS the long form). Synthetic
  # call ASTs built by `map_key_binding/1` (`{key, [], []}`) count as
  # calls so a map-key compound can promote a pluralized tail.
  defp rhs_function_compound(rhs) do
    name = extract_call_name(rhs) |> call_name_string_or_nil()
    {name, name != nil and rhs_is_call?(rhs)}
  end

  defp rhs_is_call?({:|>, _, [_lhs, rhs]}), do: rhs_is_call?(rhs)
  defp rhs_is_call?({{:., _, [_callee, _name]}, _, args}), do: args != []
  defp rhs_is_call?({name, _, args}) when is_atom(name) and is_list(args), do: true
  defp rhs_is_call?(_), do: false

  defp apply_patches({:ok, ast}, ctx, source),
    do: build_patches(ast, ctx) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, _ctx, source), do: source

  defp name_args_or_unknown({name, args}), do: {name, args}

  defp name_args_or_unknown(:error), do: {:unknown, []}

  defp tail_compound_from_latch(:error, _ctx, _short, _subtokens, _rhs_is_call?), do: :error

  defp tail_compound_from_latch(
         {:ok, start_idx, starts_hit},
         ctx,
         short,
         subtokens,
         rhs_is_call?
       ) do
    # When the latch hit every subtoken in order (`full_latch`):
    # - RHS NOT a call (property access, map-key compound) → keep all.
    # - RHS IS a call AND tail NOT plural → keep all.
    # - RHS IS a call AND tail plural → drop head to last hit so PP fires.
    #
    # Partial latch starting at 0 (`cs ↔ build_changeset`: 1 hit out of
    # 2) — leading subtokens are noise; drop everything before the
    # last hit so the tail captures just the noun.
    full_latch? = starts_hit == length(subtokens)
    keep_all? = full_latch? and (not rhs_is_call? or not tail_pluralized?(subtokens))

    effective_start =
      cond do
        keep_all? ->
          start_idx

        start_idx == 0 and String.length(short) > 1 and length(subtokens) > 1 ->
          length(subtokens) - 1

        true ->
          start_idx
      end

    n = length(subtokens) - effective_start
    rhs_target_from_split(subtokens, n, ctx, rhs_is_call?)
  end

  defp tail_pluralized?(subtokens), do: List.last(subtokens) |> pluralized?()

  defp prepend_pp_or_keep({:ok, pp}, tail_compound),
    do: {:ok, [pp, tail_compound] |> Enum.join("_")}

  defp prepend_pp_or_keep(:skip, tail_compound), do: {:ok, tail_compound}

  # Strip a trailing `!` (bang convention for raising variants). The
  # variable we're about to bind can't legally contain `!`, so the
  # bang must come off the RHS function name before it becomes a name.
  defp call_name_string_or_nil({:ok, name}) when is_atom(name) do
    name |> Atom.to_string() |> String.trim_trailing("!") |> String.trim_trailing("?")
  end

  defp call_name_string_or_nil(:error), do: nil

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  defp binding_from_key({:ok, key}, name, node) do
    if underscore?(name), do: [], else: [{name, node, {key, [], []}}]
  end

  defp binding_from_key(:error, _name, _node), do: []

  defp pluralized?(nil), do: false

  defp pluralized?(last), do: singularize(last) != last
end
