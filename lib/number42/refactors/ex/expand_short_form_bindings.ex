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
  def priority, do: 250
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

  defp apply_patches({:ok, ast}, ctx, source),
    do: build_patches(ast, ctx) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, _ctx, source), do: source

  defp binding_from_key({:ok, key}, name, node) do
    if underscore?(name), do: [], else: [{name, node, {key, [], []}}]
  end

  defp binding_from_key(:error, _name, _node), do: []

  defp build_ctx(opts) do
    extra_whitelist = opts |> Keyword.get(:whitelist, []) |> Enum.map(&to_atom/1) |> MapSet.new()

    %{
      known: Map.merge(@known, Keyword.get(opts, :known, %{})),
      pp_verbs: opts |> Keyword.get(:pp_verbs, []) |> MapSet.new(),
      whitelist: MapSet.union(@default_whitelist, extra_whitelist)
    }
  end

  defp build_patches(ast, ctx) do
    module_tokens = collect_module_tokens(ast)
    local_param_index = collect_local_param_index(ast, ctx)

    ast
    |> collect_def_clauses()
    |> Enum.flat_map(fn {def_node, body} ->
      patches_for_clause(def_node, body, module_tokens, local_param_index, ctx)
    end)
  end

  # Module-wide index of local function param names. Maps
  # `{function_name, position}` → long-form param name (string), but
  # only when:
  #
  # - all clauses of that `{name, arity}` agree on the position's
  #   param name, and
  # - the chosen name is "long" (not itself a short-form abbreviation),
  #   so we don't propagate one short into another.
  #
  # The index lets `patches_for_clause` answer "if I'm passing `bi`
  # as 1st arg to `load_brand_item/1`, what's the param called there?"
  # That is the strongest contextual signal we have for the binding's
  # intended long form — stronger than module-name latching.
  defp collect_local_param_index(ast, ctx) do
    # Per clause, emit one entry per parameter position: `{:ok, atom}`
    # for bare-var params, `:non_simple` otherwise. We keep the
    # `:non_simple` markers so that a function with even one
    # destructuring or literal clause at a position is recognised as
    # heterogeneous — without that marker, a multi-clause function
    # whose only bare-var clause uses a generic catch-all name (e.g.
    # `defp walk(other)`) would falsely look like every clause agrees
    # on `other`.
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {kind, _, [head, _body]} when def_or_macro_kind?(kind) ->
        case extract_fn_signature(head) do
          {name, params} ->
            params
            |> Enum.with_index()
            |> Enum.map(fn {param, idx} ->
              {{name, length(params), idx}, param_simple_name(param)}
            end)

          :error ->
            []
        end

      _ ->
        []
    end)
    |> Enum.group_by(fn {key, _} -> key end, fn {_, result} -> result end)
    |> Enum.flat_map(fn {{name, arity, idx}, results} ->
      atoms =
        results
        |> Enum.flat_map(fn
          {:ok, atom} -> [atom]
          :error -> [:__non_simple__]
        end)
        |> Enum.uniq()

      case atoms do
        [single] when single != :__non_simple__ ->
          if long?(single, ctx),
            do: [{{name, arity, idx}, Atom.to_string(single)}],
            else: []

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  # A param is "simple" when it's a bare variable (possibly with
  # default `\\` or struct annotation). Destructuring patterns,
  # pinned vars, and literals are not useful as call-site signals.
  defp param_simple_name({:\\, _, [inner, _]}), do: param_simple_name(inner)

  defp param_simple_name({:=, _, [a, b]}),
    do: param_simple_name(a) |> or_else(fn -> param_simple_name(b) end)

  defp param_simple_name({name, _, c}) when is_atom(name) and is_atom(c) do
    string = Atom.to_string(name)
    if String.starts_with?(string, "_"), do: :error, else: {:ok, name}
  end

  defp param_simple_name(_), do: :error

  defp or_else({:ok, _} = ok, _fallback), do: ok
  defp or_else(:error, fallback), do: fallback.()

  defp call_name_string_or_nil({:ok, name}) when is_atom(name) do
    name |> Atom.to_string() |> String.trim_trailing("!") |> String.trim_trailing("?")
  end

  defp call_name_string_or_nil(:error), do: nil

  defp camel_to_snake(atom) when is_atom(atom) do
    atom |> Atom.to_string() |> Macro.underscore()
  end

  defp choose_winner([]), do: :skip
  defp choose_winner([{target, _}]), do: {:ok, target}
  defp choose_winner([{target, s1}, {_other, s2} | _]) when s1 > s2, do: {:ok, target}
  defp choose_winner(_tie), do: :skip

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

  defp for_generator_bindings(pattern, rhs),
    do: top_level_bindings(pattern, rhs) ++ map_key_bindings(pattern)

  defp head_signature(head), do: extract_fn_signature(head) |> name_args_or_unknown()
  defp key_atom({:__block__, _, [atom]}) when is_atom(atom), do: {:ok, atom}
  defp key_atom(atom) when is_atom(atom), do: {:ok, atom}
  defp key_atom(_), do: :error

  defp lambda_param_binding({name, _, ctx} = node) when is_atom(name) and is_atom(ctx) do
    if underscore?(name), do: [], else: [{name, node, node}]
  end

  defp lambda_param_binding(_), do: []
  defp long?(name, ctx), do: not short_name?(name, ctx)

  defp map_key_binding({key_ast, {name, _, ctx} = node})
       when is_atom(name) and is_atom(ctx) do
    key_atom(key_ast) |> binding_from_key(name, node)
  end

  defp map_key_binding(_), do: []

  defp map_key_bindings(pattern) do
    pattern
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:%{}, _, pairs} when is_list(pairs) -> pairs |> Enum.flat_map(&map_key_binding/1)
      _ -> []
    end)
  end

  defp name_args_or_unknown({name, args}), do: {name, args}
  defp name_args_or_unknown(:error), do: {:unknown, []}
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  defp patches_for_clause(head, body, module_compounds, local_param_index, context_compound) do
    {fn_name, params} = head_signature(head)
    fn_compound = Atom.to_string(fn_name)
    param_names = params |> Enum.flat_map(&pattern_var_names/1)
    param_compounds = param_names |> Enum.map(&Atom.to_string/1)

    collected_binding = collect_bindings(body)

    long_names_in_body =
      collected_binding
      |> Enum.map(fn {name, _, _} -> name end)
      |> Enum.filter(&long?(&1, context_compound))

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
      collected_binding |> Enum.filter(fn {name, _, _} -> short_name?(name, context_compound) end)

    # Call-site resolutions per short name — see
    # `resolve_via_call_sites/3`. Per name we get either a single
    # agreed-upon long form (`{:ok, "brand_item"}`), an explicit
    # disagreement (`:conflict`, treat as ambiguous → no signal AND
    # don't fall through to weaker signals), or `:none` (no call
    # sites). Disagreement on call sites is *informative*: it means
    # the binding has multiple plausible names. Refuse to rewrite
    # rather than pick from weaker context signals.
    short_names_set = short_bindings |> Enum.map(fn {name, _, _} -> name end) |> MapSet.new()
    call_site_signals = resolve_via_call_sites(body, short_names_set, local_param_index)

    # Resolve: short-name → long-name (atom) per binding.
    resolutions =
      short_bindings
      |> Enum.reject(fn {name, _node, _rhs} -> MapSet.member?(rebound, name) end)
      |> Enum.flat_map(fn {name, _node, rhs} ->
        result =
          case Map.fetch(call_site_signals, name) do
            {:ok, {:ok, long}} -> {:ok, long}
            {:ok, :conflict} -> :skip
            :error -> resolve_long(name, rhs, context_compounds, context_compound)
          end

        case result do
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
      {name, _meta, context_compound} = node when is_atom(name) and is_atom(context_compound) ->
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

  defp pluralized?(nil), do: false
  defp pluralized?(last), do: singularize(last) != last

  defp prepend_pp_or_keep({:ok, pp}, tail_compound),
    do: {:ok, [pp, tail_compound] |> Enum.join("_")}

  defp prepend_pp_or_keep(:skip, tail_compound), do: {:ok, tail_compound}

  defp resolve_long(name, rhs, context_compounds, context_compound) do
    string = Atom.to_string(name)

    cond do
      Map.has_key?(context_compound.known, string) ->
        {:ok, Map.fetch!(context_compound.known, string)}

      true ->
        {rhs_compound, rhs_is_call?} = rhs_function_compound(rhs)

        compound_candidates =
          score_compound_candidates(string, context_compounds, context_compound)

        # RHS-match is rated higher than any compound-context match.
        # If RHS yielded a hit, take its target (the subtoken slice
        # corresponding to `short`'s initials); otherwise fall back to
        # compound matches.
        case rhs_compound && rhs_target(string, rhs_compound, rhs_is_call?, context_compound) do
          {:ok, target} -> {:ok, target}
          _ -> choose_winner(compound_candidates)
        end
    end
  end

  # Walk the function body and collect, for each short name in
  # `short_names`, every call-site where that name appears as an
  # argument to a local function whose corresponding parameter is in
  # `local_param_index`. Pipe head + Pipe arg are both treated as
  # call positions (`bi |> load_brand_item()` puts `bi` at position 0).
  #
  # Returns `%{short_name => {:ok, long} | :conflict}` — only short
  # names that had at least one local-call observation. Disagreement
  # between observations collapses to `:conflict` so the caller can
  # refuse rather than guess.
  defp resolve_via_call_sites(body, short_names, local_param_index) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(&call_site_observations(&1, short_names, local_param_index))
    |> Enum.group_by(fn {name, _} -> name end, fn {_, long} -> long end)
    |> Enum.map(fn {name, longs} ->
      case Enum.uniq(longs) do
        [single] -> {name, {:ok, single}}
        _ -> {name, :conflict}
      end
    end)
    |> Map.new()
  end

  # Direct call: `load_brand_item(bi, other)`. Each short-named arg
  # contributes one observation if the callee's param-name for that
  # position is in `local_param_index`.
  defp call_site_observations({name, _, args}, short_names, local_param_index)
       when is_atom(name) and is_list(args) do
    arity = length(args)

    args
    |> Enum.with_index()
    |> Enum.flat_map(fn {arg, position} ->
      observe_arg(arg, short_names, local_param_index, name, arity, position)
    end)
  end

  # Pipe: `bi |> load_brand_item(other)` is sugar for
  # `load_brand_item(bi, other)` — `bi` is position 0, every explicit
  # arg shifts right by one. We handle the pipe shape here so the
  # signal isn't lost when the author wrote idiomatic Elixir.
  defp call_site_observations(
         {:|>, _, [lhs, {name, _, args}]},
         short_names,
         local_param_index
       )
       when is_atom(name) and is_list(args) do
    arity = length(args) + 1

    observe_arg(lhs, short_names, local_param_index, name, arity, 0) ++
      (args
       |> Enum.with_index()
       |> Enum.flat_map(fn {arg, position} ->
         observe_arg(arg, short_names, local_param_index, name, arity, position + 1)
       end))
  end

  defp call_site_observations(_, _short_names, _local_param_index), do: []

  defp observe_arg({short, _, c}, short_names, local_param_index, callee, arity, position)
       when is_atom(short) and is_atom(c) do
    if MapSet.member?(short_names, short) do
      case Map.fetch(local_param_index, {callee, arity, position}) do
        {:ok, long} -> [{short, long}]
        :error -> []
      end
    else
      []
    end
  end

  defp observe_arg(_arg, _short_names, _local_param_index, _callee, _arity, _position), do: []

  defp rhs_function_compound(rhs) do
    name = extract_call_name(rhs) |> call_name_string_or_nil()
    {name, name != nil and rhs_is_call?(rhs)}
  end

  defp rhs_is_call?({:|>, _, [_lhs, rhs]}), do: rhs_is_call?(rhs)
  defp rhs_is_call?({{:., _, [_callee, _name]}, _, args}), do: args != []
  defp rhs_is_call?({name, _, args}) when is_atom(name) and is_list(args), do: true
  defp rhs_is_call?(_), do: false

  defp rhs_target(short, rhs_compound, rhs_is_call?, ctx) do
    subtokens = String.split(rhs_compound, "_", trim: true)

    latch_match(short, subtokens)
    |> tail_compound_from_latch(ctx, short, subtokens, rhs_is_call?)
  end

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

  defp score_compound_candidates(short, context_compounds, context_compound) do
    context_compounds
    # Self-match would be a no-op rename; filter early.
    |> Enum.reject(&(&1 == short))
    |> Enum.flat_map(fn compound ->
      case score_compound(short, compound, context_compound) do
        {score, target} when score > 0 -> [{target, score}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {_target, score} -> -score end)
  end

  defp singularize_compound(subtokens, _ctx) when is_list(subtokens) do
    case subtokens |> Enum.split(-1) do
      {head, [last]} -> (head ++ [singularize(last)]) |> Enum.join("_")
      {_, []} -> ""
    end
  end

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
  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_atom(s)

  defp top_level_bindings({name, _, ctx} = node, rhs) when is_atom(name) and is_atom(ctx) do
    if underscore?(name), do: [], else: [{name, node, rhs}]
  end

  defp top_level_bindings({:=, _, [_lhs, rhs_pat]}, rhs),
    do: top_level_bindings(rhs_pat, rhs)

  defp top_level_bindings(_other, _rhs), do: []
end
