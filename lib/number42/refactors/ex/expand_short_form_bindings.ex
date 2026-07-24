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
  - The only candidate is a field read off the binding itself: `fn spi ->
    spi.surcharge_package_id ...` reads `surcharge_package_id` *out of*
    `spi`, so it names a part of the row, not the row. Such field names are
    struck from the candidate ranking before resolution — expanding `spi` to
    `surcharge_package_id` would produce `surcharge_package_id.surcharge_package_id`.
    A non-field candidate (e.g. a `from(spi in SurchargePackageItem)` schema
    signal) still wins; only the field names are forbidden.

  ## Why procedural

  Scope-aware token collection plus per-function multi-site rename
  needs cross-node coordination. The declarative DSL can't express
  "find all `cs` references in this body and rename them together".
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Analysis.IdentifierExpansion

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

  # Macro/special-form atoms that look like function calls in the AST
  # (`{name, meta, args}` with args=list) but aren't runtime functions
  # we can shadow. Used by `called_function_names/1` to keep the
  # shadow-detection set free of false positives like `if`, `case`,
  # binary-op atoms, def-heads.
  @non_call_atoms ~w(
    __block__ __aliases__ -> = |> & ^ when
    if unless case cond with try receive for fn
    def defp defmacro defmacrop defmodule defstruct
    quote unquote unquote_splicing
    -> :: . :: + - * / ++ -- <> == != < > <= >= && || ! not and or in
  )a

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    ctx = build_ctx(opts)

    Sourceror.parse_string(source) |> apply_patches(ctx, source)
  end

  @impl Number42.Refactors.Refactor
  def patches(ast, _source, opts), do: build_patches(ast, build_ctx(opts))

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
      whitelist: MapSet.union(@default_whitelist, extra_whitelist),
      # Default: single-letter bindings (r, g, b, a, b, f, i, v, x, y)
      # are idiomatic — math vars, geometric coordinates, fold-step vars —
      # and a single letter rarely carries a stable "long form". Opt in
      # only when the project's style intentionally avoids them.
      cryptic_includes_single_letters: Keyword.get(opts, :cryptic_includes_single_letters, false)
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
        param_index_entries(head)

      _ ->
        []
    end)
    |> Enum.group_by(fn {key, _} -> key end, fn {_, result} -> result end)
    |> Enum.flat_map(fn {key, results} -> agreed_long_param(key, results, ctx) end)
    |> Map.new()
  end

  # Per-clause parameter observations: one `{{name, arity, idx}, result}`
  # entry per parameter position, where `result` is `param_simple_name/1`
  # (`{:ok, atom}` for bare-var params, `:error` otherwise).
  defp param_index_entries(head) do
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
  end

  # One grouped `{name, arity, idx}` position: emit a single index entry
  # only when every clause agrees on one bare-var param name AND that
  # name is "long". `:__non_simple__` marks a destructuring/literal
  # clause at this position, which makes the group heterogeneous.
  defp agreed_long_param({name, arity, idx}, results, ctx) do
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

    # Names invoked as functions in the body. A rename target landing
    # here would shadow the call — e.g. `r = round(...)` renamed to
    # `round` makes the subsequent `round(...)` calls resolve to the
    # local var instead of `Kernel.round/1`. Kernel BIFs are baked in
    # because they're always callable without explicit reference.
    called_in_body = called_function_names(body)

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

    # Context candidates, tagged with their source kind. Order matters
    # for tie-breaks (earlier wins): innermost-first locality.
    context_candidates =
      tagged_candidates(
        param_compounds,
        long_compounds_in_body,
        fn_compound,
        module_compounds
      )

    # Legacy untagged list — still passed to `short_is_subtoken_of_local_source?`
    # which only needs the raw strings.
    context_compounds =
      (param_compounds ++ long_compounds_in_body ++ [fn_compound] ++ module_compounds)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == ""))

    short_bindings =
      collected_binding
      |> Enum.filter(fn {name, _, _} -> short_name?(name, context_compound) end)
      |> Enum.reject(fn {name, _, _} -> single_letter_excluded?(name, context_compound) end)

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

    # `from(bi in BrandItem, ...)` is an explicit, local statement
    # that `bi` represents a `BrandItem` row. That's the strongest
    # signal we can get for the binding's intended long form —
    # stronger than param-name latching, RHS-based matching, or any
    # compound-context heuristic.
    from_schema_signals = resolve_via_from_schemas(body, short_names_set)

    # Resolve: short-name → *ranked* long-name candidates per binding.
    # Priority: from-schema > call-site > RHS/compound heuristics.
    # `:conflict` at a higher tier short-circuits to `[]` instead of
    # falling through to weaker signals — disagreement is itself
    # information, not absence. The from-schema / call-site signals are
    # single-valued (`[long]`); only the heuristic tier produces a
    # multi-element ranking, used as fallback when the first choice
    # collides with another binding in the same scope (see
    # `assign_long_forms/3`).
    # Fields read off each binding via `name.field`. A binding accessed as
    # `spi.surcharge_package_id` is a struct/map row, and that field is one
    # of its *parts* — never a sound new name for the row itself (the #305
    # `surcharge_package_id.surcharge_package_id` absurdity). These field
    # names are stripped from each binding's candidate ranking.
    accessed_fields = accessed_fields_by_var(body)

    ranked =
      short_bindings
      |> Enum.reject(fn {name, _node, _rhs} -> MapSet.member?(rebound, name) end)
      |> Enum.map(fn {name, _node, rhs} ->
        forbidden = Map.get(accessed_fields, name, MapSet.new())

        # A curated `known` mapping is an explicit project opt-in; it
        # wins even if it happens to drop subtokens. The shortening guard
        # only polices heuristic candidates.
        curated = Map.get(context_compound.known, Atom.to_string(name))

        candidates =
          ranked_long_forms(
            name,
            rhs,
            from_schema_signals,
            call_site_signals,
            context_candidates,
            context_compounds,
            fn_compound,
            context_compound
          )
          |> Enum.reject(&MapSet.member?(forbidden, &1))
          |> Enum.reject(&(&1 != curated and shortens?(name, &1)))

        {name, candidates}
      end)

    # Assign in source order, resolving same-scope collisions by walking
    # each later binding's own ranking for the next free expansion. A
    # `gate` rejects targets that would shadow an existing binding/call
    # or that are still cryptic — applied to *every* candidate tried,
    # not just the first.
    gate = fn long_atom ->
      not MapSet.member?(occupied, long_atom) and
        not MapSet.member?(called_in_body, long_atom) and
        not cryptic_target?(Atom.to_string(long_atom), context_compound)
    end

    resolutions = assign_long_forms(ranked, gate, context_compound)

    # Pre-shadow references: in `x = ...x...` the `x` on the RHS is a
    # reference to the OUTER (pre-shadow) binding of `x` — typically a
    # function parameter that this assignment is about to shadow. When
    # we rename the LHS to a new name, that RHS reference must stay
    # bound to the outer name, otherwise we synthesize a reference to
    # an undefined variable. Collect these refs by identity (their
    # AST nodes) so we can exclude them from the rename walk.
    pre_shadow_refs = collect_pre_shadow_refs(collected_binding, resolutions)

    # Build patches: every reference to a resolved name in the body
    # becomes the long form, EXCEPT pre-shadow refs (see above).
    body
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {name, _meta, context_compound} = node when is_atom(name) and is_atom(context_compound) ->
        patch_for_ref(node, name, pre_shadow_refs, resolutions)

      _ ->
        []
    end)
    |> Enum.reject(&is_nil/1)
  end

  # One var-reference node: skip pre-shadow refs (the RHS reference to
  # an outer binding the assignment is about to shadow), otherwise build
  # a rename patch when the name resolved to a long form.
  defp patch_for_ref(node, name, pre_shadow_refs, resolutions) do
    if MapSet.member?(pre_shadow_refs, node) do
      []
    else
      rename_patch(node, name, resolutions)
    end
  end

  defp rename_patch(node, name, resolutions) do
    case Map.fetch(resolutions, name) do
      {:ok, long_atom} ->
        node |> build_patch(Atom.to_string(long_atom)) |> patch_or_empty()

      :error ->
        []
    end
  end

  defp patch_or_empty(nil), do: []
  defp patch_or_empty(patch), do: [patch]

  # Ranked long-form candidates for one short binding, best-first, as
  # strings. Tier priority is unchanged (from-schema > call-site >
  # heuristic); the first two tiers are single-valued, so only the
  # heuristic tier (`resolve_ranked`) yields a multi-element ranking.
  # `:conflict` at a higher tier returns `[]` — disagreement suppresses
  # the rename rather than falling through to weaker signals.
  defp ranked_long_forms(
         name,
         rhs,
         from_schema_signals,
         call_site_signals,
         context_candidates,
         context_compounds,
         fn_compound,
         context_compound
       ) do
    case Map.fetch(from_schema_signals, name) do
      {:ok, {:ok, long}} ->
        [long]

      {:ok, :conflict} ->
        []

      :error ->
        case Map.fetch(call_site_signals, name) do
          {:ok, {:ok, long}} ->
            [long]

          {:ok, :conflict} ->
            []

          :error ->
            resolve_long_ranked(
              name,
              rhs,
              context_candidates,
              context_compounds,
              fn_compound,
              context_compound
            )
        end
    end
  end

  # Assign each short binding a long form, in source order, so that no
  # two bindings in the same scope collapse to the same name. The first
  # binding to want a given long form keeps it; every later binding
  # walks its OWN ranking for the next candidate the `gate` accepts and
  # that isn't already `taken`. Only when the whole ranking is
  # exhausted do we fall back to a `<long>_2` suffix — and that only
  # when the original short is itself cryptic (an expressive short like
  # `base_val` is left untouched rather than disfigured into
  # `value_2`). Returns `%{short_atom => long_atom}`.
  defp assign_long_forms(ranked, gate, context_compound) do
    {assignments, _taken} =
      Enum.reduce(ranked, {[], MapSet.new()}, fn binding, acc ->
        assign_one_long_form(binding, acc, gate, context_compound)
      end)

    Map.new(assignments)
  end

  # One reduce step: pick the first free long form for this binding, or
  # fall back to a suffix. `acc` is `{assignments, taken}`. Returns the
  # next `{assignments, taken}`.
  defp assign_one_long_form({name, longs}, {acc, taken}, gate, context_compound) do
    case pick_free_long(longs, gate, taken) do
      {:ok, long_atom} ->
        {[{name, long_atom} | acc], MapSet.put(taken, long_atom)}

      :exhausted ->
        case suffix_fallback(longs, gate, taken, name, context_compound) do
          {:ok, long_atom} -> {[{name, long_atom} | acc], MapSet.put(taken, long_atom)}
          :skip -> {acc, taken}
        end
    end
  end

  # First long form in the ranking that passes the gate and is not yet
  # taken. `:exhausted` when none qualifies.
  defp pick_free_long(longs, gate, taken) do
    longs
    |> Enum.map(&String.to_atom/1)
    |> Enum.find(fn long_atom -> gate.(long_atom) and not MapSet.member?(taken, long_atom) end)
    |> case do
      nil -> :exhausted
      long_atom -> {:ok, long_atom}
    end
  end

  # All ranked choices collided. If the short is itself cryptic, derive
  # `<first_gated_long>_<n>` (n ≥ 2) — the lowest free suffix that
  # passes the gate. If the short is already expressive, leave it
  # alone (`:skip`).
  defp suffix_fallback([], _gate, _taken, _name, _ctx), do: :skip

  defp suffix_fallback([first | _] = _longs, gate, taken, name, context_compound) do
    cond do
      not cryptic_target?(Atom.to_string(name), context_compound) ->
        :skip

      not gate.(String.to_atom(first)) ->
        :skip

      true ->
        2
        |> Stream.iterate(&(&1 + 1))
        |> Stream.map(&String.to_atom("#{first}_#{&1}"))
        |> Enum.find(fn long_atom -> not MapSet.member?(taken, long_atom) end)
        |> then(&{:ok, &1})
    end
  end

  # For each resolved `=` binding `name = rhs`, return every
  # var-reference to `name` *inside `rhs`* — those are pre-shadow
  # references to the outer binding (typically a function parameter
  # the assignment is about to shadow). Lambda parameters and
  # comprehension generators don't shadow in the same way (their
  # binding range starts inside the construct, not at a sequence
  # point in a body), so we restrict the check to true `=` bindings
  # where the LHS node is structurally distinct from the RHS.
  defp collect_pre_shadow_refs(collected_binding, resolutions) do
    collected_binding
    |> Enum.flat_map(fn {name, lhs, rhs} ->
      cond do
        not Map.has_key?(resolutions, name) -> []
        lhs == rhs -> []
        true -> var_refs_to(rhs, name)
      end
    end)
    |> MapSet.new()
  end

  # Map each variable to the set of field names read off it via dot access
  # (`var.field`). Only a paren-less field read counts: `var.field` carries
  # `no_parens: true`, while `var.field()` is a zero-arg call (no parens flag)
  # and `var.fun(args)` a remote call — neither names a struct field. A
  # chained `var.a.b` records only the first hop `a` (the var owns `a`, not
  # `b`). Field names are returned as strings to match the candidate ranking.
  defp accessed_fields_by_var(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {{:., _, [{var, _, ctx}, field]}, call_meta, []}
      when is_atom(var) and is_atom(ctx) and is_atom(field) ->
        if Keyword.get(call_meta, :no_parens, false),
          do: [{var, Atom.to_string(field)}],
          else: []

      _ ->
        []
    end)
    |> Enum.group_by(fn {var, _} -> var end, fn {_, field} -> field end)
    |> Map.new(fn {var, fields} -> {var, MapSet.new(fields)} end)
  end

  # Walk an AST and return every `{name, _, ctx}` var-reference node
  # whose name matches `target`. Variable references are 3-tuples with
  # both atoms; this filters out function calls and other 3-tuples.
  defp var_refs_to(ast, target) do
    ast
    |> Macro.prewalker()
    |> Enum.filter(fn
      {n, _, c} -> is_atom(n) and is_atom(c) and n == target
      _ -> false
    end)
  end

  # Ranked heuristic expansion for one short name, best-first strings.
  # Same guards as the single-pick path used to have; `known` yields a
  # one-element ranking (an explicit mapping has no runner-up) and the
  # locality-safety skip yields `[]`.
  defp resolve_long_ranked(
         name,
         rhs,
         context_candidates,
         context_compounds,
         fn_compound,
         context_compound
       ) do
    string = Atom.to_string(name)
    {rhs_compound, rhs_is_call?} = rhs_function_compound(rhs)

    cond do
      Map.has_key?(context_compound.known, string) ->
        [Map.fetch!(context_compound.known, string)]

      # Locality safety: if the short name appears verbatim as a
      # subtoken of any local source (RHS source token, function
      # parameter, sibling binding, function name, module name), the
      # author already used that exact form intentionally — it's a
      # variation, not an abbreviation. Renaming would change the
      # author's chosen vocabulary (e.g. `ids = ..._ids` → `id`
      # inverts the cardinality from collection to element). Keep.
      short_is_subtoken_of_local_source?(string, rhs_compound, context_compounds) ->
        []

      true ->
        # RHS source (call name or property access) gets prepended as
        # a strong candidate when present. PP-promotion in
        # IdentifierExpansion handles `build_changesets ↔ cs →
        # built_changeset`, but only fires when `rhs_is_call?` so
        # property-access RHS just contributes the raw name.
        candidates_with_rhs =
          cond do
            is_binary(rhs_compound) and rhs_is_call? ->
              [{rhs_compound, :rhs_call} | context_candidates]

            is_binary(rhs_compound) ->
              [{rhs_compound, :alias} | context_candidates]

            true ->
              context_candidates
          end

        opts = %{
          self: fn_compound,
          whitelist: context_compound.whitelist,
          known: %{},
          pp_verbs: context_compound.pp_verbs,
          # A binding lives inside a function whose entire local
          # vocabulary (params, sibling bindings, fn name, module
          # tokens) is intentional context. Trust all sources equally.
          treat_all_as_strong: true,
          min_score: 80
        }

        IdentifierExpansion.resolve_ranked(string, candidates_with_rhs, opts)
    end
  end

  # The short name appears verbatim as one of the underscore-separated
  # subtokens of any local source. We include the RHS source-token
  # (`...selected_price_list_ids`) plus all context compounds (params,
  # sibling bindings, fn name, module name). Subtoken-level match
  # avoids false matches with longer words that happen to contain the
  # short as a character substring (e.g. `bid` does not "contain" `id`
  # under this rule — only `["b", "id"]`-style splits would).
  # Rule 2: collect every name that appears as a *function call* in
  # the body. A rename target landing in this set would shadow the
  # call — the rewritten LHS binds a variable with the same name as
  # a function the body still tries to invoke. Result is undefined
  # behaviour at best, hard crash at worst (`round = round(...)` →
  # the next `round(...)` line is a no-arity call on an integer).
  #
  # Body-relative on purpose: the BIF `node/0` exists, but if the body
  # never calls `node()`, picking `node` as a target is harmless. A
  # broader "all Kernel BIFs" block was tried and overshot — it
  # rejected legitimate targets like `node` in code that doesn't use
  # the BIF.
  #
  # Special forms (`def`, `defp`, `case`, `if`, etc.) are NOT call
  # shapes in the runtime sense — they're macros that introduce
  # bindings — and don't belong in this set. Macro-call shapes
  # `{name, meta, args}` with `name in @special_forms` slip through
  # `is_atom(name) and is_list(args)` so we filter them out
  # explicitly via `@non_call_atoms`.
  defp called_function_names(body) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {name, _, args}
      when is_atom(name) and is_list(args) and name not in @non_call_atoms ->
        [name]

      _ ->
        []
    end)
    |> MapSet.new()
  end

  # Rule 4: refuse a rename whose target is itself too short to be
  # meaningfully clearer than the original. Two failure modes:
  #
  # 1. Module-name latching produces nonsense short names. `a = Enum.at(...)`
  #    would rename `a` to `at` — the RHS subtoken slice. `at` is still
  #    cryptic (length 2), the rename swaps one short name for another.
  # 2. Compound expansion leaves a cryptic component: `fb` → `fb_node`
  #    keeps the original cryptic prefix. If we couldn't fully resolve
  #    the abbreviation, leave the binding alone rather than ship a
  #    half-expanded name.
  #
  # We use a length-only test (≤ 3) and inspect only the LEADING
  # subtoken. Trailing short subtokens are idiomatic suffix conventions
  # (`organization_id`, `normalized_key`, `foreign_key`, `primary_pk`)
  # and must not disqualify an otherwise good target. Leading short
  # subtokens are the failure mode this rule catches — `fb_node`,
  # `bi_summary`, `at` (single-subtoken degenerate case).
  #
  # An explicit whitelist entry for the full target wins — the project
  # has opted into that short form as acceptable (e.g. `str` is
  # idiomatic in some codebases).
  #
  # `consonant_heavy?` is deliberately not used here. It's calibrated
  # to decide what *needs* expanding (catches `brnd`, `mngr`), but
  # legit English words like `string`/`script` also trip it.
  # Refuse a "long form" that merely drops subtokens from the original
  # name — that's a *shortening*, never an expansion. `hit_paths` →
  # `paths` (subtokens {paths} ⊂ {hit, paths}) is the canonical case: a
  # leading full word (`hit`) is short enough to flag the whole name as
  # cryptic, then the ranker latches onto the `paths` subtoken and
  # silently truncates a perfectly descriptive name. A genuine expansion
  # always *adds* meaning; if the candidate's subtokens are a subset of
  # the original's, it removes meaning instead.
  defp shortens?(name, long) do
    original = name |> Atom.to_string() |> String.split("_", trim: true) |> MapSet.new()
    candidate = long |> String.split("_", trim: true) |> MapSet.new()

    MapSet.size(original) > 1 and MapSet.subset?(candidate, original)
  end

  defp cryptic_target?(long, ctx) do
    if MapSet.member?(ctx.whitelist, String.to_atom(long)) do
      false
    else
      case long |> String.split("_", trim: true) do
        [] -> true
        [first | _] -> String.length(first) <= 3
      end
    end
  end

  # Rule 5 (default-on): refuse to rename a single-letter binding.
  # Single letters are idiomatic in BEAM/math code (r/g/b for colour
  # channels, a/b for compare-pair, i/j for indices, f for float, x/y
  # for coords). Picking a "long form" from RHS or context is almost
  # always wrong — the name is intentional brevity, not an abbreviation
  # of a concept the reader needs reminded of.
  #
  # A whitelist entry for the single letter still wins (handled
  # upstream via `short_name?/2` returning `false`). This guard only
  # fires when the letter is otherwise short, and stays inactive when
  # the project opts in via `cryptic_includes_single_letters: true`.
  defp single_letter_excluded?(name, ctx) do
    not ctx.cryptic_includes_single_letters and
      name |> Atom.to_string() |> String.length() == 1
  end

  defp short_is_subtoken_of_local_source?(short, rhs_compound, context_compounds) do
    sources =
      if is_binary(rhs_compound), do: [rhs_compound | context_compounds], else: context_compounds

    Enum.any?(sources, fn compound ->
      compound
      |> String.split("_", trim: true)
      |> Enum.member?(short)
    end)
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

  # Walk the body for Ecto `from`-style bindings: `from(short in Schema, ...)`,
  # also covered by named subqueries like `join: x in assoc(...)` /
  # `join: x in Schema`. For each short name in `short_names`, take
  # the schema-alias's last segment, underscore it, and use that as
  # the long form. Multiple observations of the same short name must
  # agree on the schema; otherwise `:conflict`.
  #
  # Returns `%{short_name => {:ok, long} | :conflict}` — only short
  # names with at least one schema observation.
  defp resolve_via_from_schemas(body, short_names) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(&from_schema_observations(&1, short_names))
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

  # `from(short in Schema, ...)` and `join: short in Schema` /
  # `join: short in assoc(parent, :field)`. We accept both the
  # top-level `from`/`join` shapes and any nested `in`-expression
  # whose LHS is a bare var — Ecto's macros normalize these.
  defp from_schema_observations({:in, _, [{short, _, c}, schema_ast]}, short_names)
       when is_atom(short) and is_atom(c) do
    if MapSet.member?(short_names, short) do
      case schema_long_form(schema_ast) do
        {:ok, long} -> [{short, long}]
        :error -> []
      end
    else
      []
    end
  end

  defp from_schema_observations(_, _short_names), do: []

  # Extract the long form from an Ecto query source. Schemas are
  # `__aliases__` nodes whose last segment is the human-readable
  # name (e.g. `BrandItem` → `brand_item`). Anything else (raw
  # strings, dynamic queries, `assoc/2` joins) yields `:error` and
  # leaves the binding alone — those don't carry a name signal.
  defp schema_long_form({:__aliases__, _, parts}) when is_list(parts) and parts != [] do
    last = List.last(parts)
    if is_atom(last), do: {:ok, camel_to_snake(last)}, else: :error
  end

  defp schema_long_form(_), do: :error

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

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_atom(s)

  defp top_level_bindings({name, _, ctx} = node, rhs) when is_atom(name) and is_atom(ctx) do
    if underscore?(name), do: [], else: [{name, node, rhs}]
  end

  defp top_level_bindings({:=, _, [_lhs, rhs_pat]}, rhs),
    do: top_level_bindings(rhs_pat, rhs)

  defp top_level_bindings(_other, _rhs), do: []

  # Build the typed candidate list IdentifierExpansion expects.
  # Order matters for tie-breaks: innermost (params, body bindings,
  # enclosing fn) wins over module-level (module name tokens).
  defp tagged_candidates(param_compounds, body_long_compounds, fn_compound, module_compounds) do
    (Enum.map(param_compounds, &{&1, :param}) ++
       Enum.map(body_long_compounds, &{&1, :body_binding}) ++
       [{fn_compound, :enclosing_fn}] ++
       Enum.map(module_compounds, &{&1, :module_name}))
    |> Enum.uniq_by(fn {compound, _} -> compound end)
    |> Enum.reject(fn {compound, _} -> compound == "" end)
  end
end
