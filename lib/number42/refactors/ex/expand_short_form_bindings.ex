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

    # Resolve: short-name → long-name (atom) per binding.
    # Priority: from-schema > call-site > RHS/compound heuristics.
    # `:conflict` at a higher tier short-circuits to `:skip` instead
    # of falling through to weaker signals — disagreement is itself
    # information, not absence.
    resolutions =
      short_bindings
      |> Enum.reject(fn {name, _node, _rhs} -> MapSet.member?(rebound, name) end)
      |> Enum.flat_map(fn {name, _node, rhs} ->
        result =
          case Map.fetch(from_schema_signals, name) do
            {:ok, {:ok, long}} ->
              {:ok, long}

            {:ok, :conflict} ->
              :skip

            :error ->
              case Map.fetch(call_site_signals, name) do
                {:ok, {:ok, long}} ->
                  {:ok, long}

                {:ok, :conflict} ->
                  :skip

                :error ->
                  resolve_long(
                    name,
                    rhs,
                    context_candidates,
                    context_compounds,
                    fn_compound,
                    context_compound
                  )
              end
          end

        case result do
          {:ok, long} ->
            long_atom = String.to_atom(long)

            cond do
              MapSet.member?(occupied, long_atom) -> []
              MapSet.member?(called_in_body, long_atom) -> []
              cryptic_target?(long, context_compound) -> []
              true -> [{name, long_atom}]
            end

          :skip ->
            []
        end
      end)
      |> Map.new()
      |> drop_long_form_collisions()

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
        cond do
          MapSet.member?(pre_shadow_refs, node) ->
            []

          true ->
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
        end

      _ ->
        []
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Symmetric `:conflict` collapse, on the other axis. The per-name
  # resolvers already refuse to rename when ONE short name has
  # disagreeing long-form observations. This catches the mirror case:
  # MULTIPLE DISTINCT short names in the same clause that independently
  # resolve to the SAME long form. Renaming each in isolation would
  # produce two `value = ...` lines in one scope — the second `=`
  # shadows the first, so every later reference to the first short
  # silently picks up the second's value (issue #2: `head_val -
  # base_val` → `value - value == 0`).
  #
  # Group the resolved `%{short => long}` map by long form and drop
  # every group whose cardinality is > 1. The pre-existing "long form
  # already a name in scope" guard covers bindings that exist *before*
  # this pass; this covers the bindings the pass is about to create.
  defp drop_long_form_collisions(resolutions) do
    colliding_longs =
      resolutions
      |> Enum.frequencies_by(fn {_short, long} -> long end)
      |> Enum.filter(fn {_long, count} -> count > 1 end)
      |> Enum.map(fn {long, _count} -> long end)
      |> MapSet.new()

    resolutions
    |> Enum.reject(fn {_short, long} -> MapSet.member?(colliding_longs, long) end)
    |> Map.new()
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

  defp resolve_long(
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
        {:ok, Map.fetch!(context_compound.known, string)}

      # Locality safety: if the short name appears verbatim as a
      # subtoken of any local source (RHS source token, function
      # parameter, sibling binding, function name, module name), the
      # author already used that exact form intentionally — it's a
      # variation, not an abbreviation. Renaming would change the
      # author's chosen vocabulary (e.g. `ids = ..._ids` → `id`
      # inverts the cardinality from collection to element). Keep.
      short_is_subtoken_of_local_source?(string, rhs_compound, context_compounds) ->
        :skip

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

        Number42.Refactors.IdentifierExpansion.resolve(string, candidates_with_rhs, opts)
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
  defp cryptic_target?(long, ctx) do
    cond do
      MapSet.member?(ctx.whitelist, String.to_atom(long)) ->
        false

      true ->
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
