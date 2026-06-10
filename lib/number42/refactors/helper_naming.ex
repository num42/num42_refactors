defmodule Number42.Refactors.HelperNaming do
  @moduledoc """
  Derives a meaningful name for a `defp` helper extracted out of a
  function body (by `ExtractFunctionFromBlock` or
  `SplitPipeableResponsibilities`).

  A mechanical `<parent>_block` / `<parent>_phase_n` says where the code
  came from, not what it does. This module names the helper after **what
  it does** (a verb inferred from the block's dominant call) and **what
  it produces** (the live-out bindings), e.g.

      {brands} <- Pricing.list_brands(scope)        → fetch_brands
      {masses, options} <- Enum.map(…)/Enum.filter(…) → compute_masses_and_options
      {mass_type, unit} <- get_field(…)             → fetch_mass_type_and_unit

  ## Composition

  `name/6` takes the host name, the live-out variable names (in source
  order), the block's statement ASTs, the helper's params and the set of
  existing names, and returns `{:ok, atom}` or `:skip`. Preference order:

  1. **verb + object** — a verb inferred from the dominant call
     (`fetch`/`build`/`validate`/`format`/`normalize`) joined to the
     live-out object (`fetch_brands`, `fetch_mass_type_and_unit`).
  2. **object only** (`<a>_and_<b>`) — when no verb is inferable but the
     live-outs are two meaningful names. A *single* object name is never
     used standalone — it equals its live-out and would shadow it.
  3. **verb + source** — when the live-outs give no object (3+ names, or
     none) but the block is an accessor ladder fanning one container into
     many bindings, the object comes from that *container*:
     `Keyword.get(opts, …) × 5` → `fetch_opts`. Only fires for accessor
     calls (`get`/`fetch`/`get_in`/…) sharing one non-boilerplate carrier.
  4. **host name without the suffix** — `load_brands_block` → `load_brands`
     when the host already reads as more than a bare verb.
  5. **fallback** — the caller's idiomatic last resort (`<fn>_block` or
     `<fn>_phase_n`).

  ## Shadow safety

  A candidate equal to any live-out or parameter name is rejected — the
  helper call must not shadow a variable in scope. A `?`/`!` live-out is
  never spliced into the middle of a joined name (the marker is only
  legal as the final character of an identifier). If even the
  `<parent>_block` fallback collides with an existing definition the
  caller gets `:skip` and leaves the code untouched.

  ## Boilerplate carriers

  `scope`, `socket`, `conn`, `assigns` thread through LiveView/Plug code
  as pure plumbing. They are dropped from the object part of the name —
  `{scope, filters}` reads as `filters`, not `scope_and_filters` — but
  they still count for shadow-safety.
  """

  alias Number42.Refactors.AttributeClassifier
  alias Number42.Refactors.Semantic

  @boilerplate ~w(scope socket conn assigns)a

  # Verb inferred from the *function name* of the call that produces the
  # block's result. Order matters: the first matching predicate wins, so
  # the most specific signals (errors, string ops) precede the generic
  # "touches a collection → compute" catch-all.
  @verb_rules [
    {:validate,
     ~w(add_error validate validate_change validate_required put_error verify ensure confirm)},
    {:format, ~w(to_string humanize topic render_to_string render format)},
    {:normalize, ~w(downcase upcase trim capitalize normalize sanitize finalize tokenize clean)},
    {:build, ~w(build new create changeset struct cast assemble generate prepare)},
    {:fetch,
     ~w(get fetch list all one get_field get_change get_assoc preload load find collect reload resolve)},
    {:compute,
     ~w(compute calculate sum count aggregate accumulate consolidate reduce total tally)},
    {:filter, ~w(filter reject exclude prune select)},
    {:group, ~w(group partition bucket cluster chunk split batch)},
    {:extract, ~w(extract parse decode walk traverse capture pluck)},
    {:update, ~w(update merge put replace insert delete drop assign wrap expand attach)},
    {:notify, ~w(notify send broadcast publish emit dispatch deliver announce inform)}
  ]

  @doc """
  Derive a helper name. Returns `{:ok, atom}` or `:skip`.

  - `host` — the enclosing function's name (atom).
  - `live_out` — variable names the block returns, in source order.
  - `stmts` — the block's statement ASTs (used to infer the verb).
  - `params` — the helper's parameter names (for shadow-safety).
  - `existing` — a `MapSet` of names already defined in the module, to
    avoid collisions.
  - `opts` — `:fallback` is the caller's idiomatic last-resort name
    (`<fn>_block` for `ExtractFunctionFromBlock`, `<fn>_phase_n` for
    `SplitPipeableResponsibilities`). Defaults to `<host>_block`. It
    keeps a trailing `!`/`?` legal (`verify!` → `verify_block!`).

  The fallback is the *only* candidate that is allowed to collide with an
  in-scope variable name (it is host-derived, not live-out-derived, so it
  won't shadow); every earlier candidate that would shadow is dropped. If
  even the fallback collides with an existing definition, returns `:skip`.
  """
  @spec name(atom(), [atom()], [Macro.t()], [atom()], MapSet.t(), keyword()) ::
          {:ok, atom()} | :skip
  def name(host, live_out, stmts, params, existing, opts \\ []) do
    in_scope = MapSet.new(live_out ++ params)
    verb = infer_verb(stmts, live_out)
    object = object_part(live_out)
    source = source_object(stmts, live_out)
    attribute = infer_attribute(stmts)
    fallback = Keyword.get(opts, :fallback, suffixed(host, "_block"))

    # `object` may be a single name (`filters`) or a join (`a_and_b`).
    # As a *standalone* name a single object always equals its live-out
    # and would shadow it — only a join is safe standalone. With a verb
    # the composed name (`fetch_filters`) differs from the live-out, so a
    # single object is fine there. An attribute, when present, slots between
    # verb and object (`delete_active_items`); it is preferred over the plain
    # `verb_object` but both are offered so a shadow falls back cleanly.
    derived =
      [
        compose(verb, attribute, object),
        compose(verb, object),
        standalone(object),
        compose(verb, source),
        strip_suffix(host)
      ]
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(in_scope, &1)))

    first_free(derived ++ [fallback], existing)
  end

  # A join (`a_and_b`) names the helper on its own; a single object name
  # would shadow its live-out, so it is not offered standalone.
  defp standalone(nil), do: nil

  defp standalone(object) do
    if object |> Atom.to_string() |> String.contains?("_and_"), do: object, else: nil
  end

  # --- verb inference ---

  # The verb comes from the call that *produces a live-out* — the value that
  # flows out of the block. A binding whose RHS is a call (`total = sum(...)`)
  # names the verb; one built from a tuple/literal/arithmetic (`total = a + b`,
  # `{tax, total}`) does not, and the object-only name (`tax_and_total`) is
  # right there — ~31% of real blocks end that way. Tail calls that bind no
  # live-out (`format(total, tax)` as a side-effecting last line) are ignored.
  #
  # Producing calls are checked latest-first against the stem table (cheap,
  # exact); the verb-bearing live-out is not always the last one bound. Only if
  # none hit the table does the embedding classifier get a shot, at the
  # dominant (latest) producing call — table always wins, model runs at most once.
  defp infer_verb(stmts, live_out) do
    case producing_calls(stmts, MapSet.new(live_out)) do
      [] -> nil
      [dominant | _] = calls -> Enum.find_value(calls, &table_verb/1) || semantic_verb(dominant)
    end
  end

  # Call names of the bindings that produce a live-out, latest-first.
  defp producing_calls(stmts, live_outs) do
    stmts
    |> Enum.reverse()
    |> Enum.flat_map(&live_out_call(&1, live_outs))
  end

  # A binding whose LHS binds a live-out and whose RHS is a call yields that
  # call name. The LHS may be a bare var (`token = build(user)`) or a tuple
  # pattern that destructures the result (`{token, _} = build(user)`) — both
  # let the producing call name the verb. Anything else (non-call RHS, no
  # live-out bound, bare expression) yields nothing.
  defp live_out_call({:=, _, [lhs, rhs]}, live_outs) do
    # `call_name/1` returns nil for a non-call RHS; nil is itself an atom, so a
    # `is_atom` guard would swallow it — match nil explicitly first.
    if binds_live_out?(lhs, live_outs) do
      case call_name(rhs) do
        nil -> []
        fun when is_atom(fun) -> [fun]
      end
    else
      []
    end
  end

  defp live_out_call(_stmt, _live_outs), do: []

  # True when the LHS binds at least one live-out name — directly as a bare
  # var, or as one element of a tuple pattern.
  defp binds_live_out?({var, _, ctx}, live_outs) when is_atom(var) and is_atom(ctx),
    do: MapSet.member?(live_outs, var)

  defp binds_live_out?({:{}, _, elems}, live_outs) when is_list(elems),
    do: Enum.any?(elems, &binds_live_out?(&1, live_outs))

  defp binds_live_out?({a, b}, live_outs),
    do: binds_live_out?(a, live_outs) or binds_live_out?(b, live_outs)

  defp binds_live_out?(_lhs, _live_outs), do: false

  # Unwrap a pipe to its final call; pull the function name out of a
  # remote (`Mod.fun`) or local (`fun`) call. A `socket.assigns.field` /
  # `conn.assigns.field` read is treated as a `get` — reading an assign is a
  # fetch, and `call_name` is the single point the verb table consults.
  defp call_name({:|>, _, [_lhs, rhs]}), do: call_name(rhs)

  defp call_name({{:., _, [{{:., _, [_root, :assigns]}, _, _}, field]}, _, _})
       when is_atom(field),
       do: :get

  defp call_name({{:., _, [_callee, fun]}, _, _}) when is_atom(fun), do: fun
  defp call_name({fun, _, args}) when is_atom(fun) and is_list(args), do: fun
  defp call_name(_), do: nil

  # Stem-table lookup for one call name. The table is exhaustive for the verbs
  # we name by hand; first matching rule wins.
  defp table_verb(nil), do: nil

  defp table_verb(fun) do
    name = fun |> Atom.to_string() |> String.trim_trailing("!") |> String.trim_trailing("?")

    Enum.find_value(@verb_rules, fn {verb, stems} ->
      if Enum.any?(stems, &stem_match?(name, &1)), do: verb
    end)
  end

  # The static-embedding fallback, only reached when no call hit the table. It
  # maps synonyms the table doesn't enumerate (`accumulate`/`consolidate` →
  # compute, `finalize`/`tokenize` → normalize) to a bucket, or returns
  # `:unknown` for a semantically empty name (`do_thing`, `process`) — in which
  # case the verb stays nil and the caller keeps its `_block` fallback.
  defp semantic_verb(nil), do: nil

  defp semantic_verb(fun) do
    case Semantic.classify(Atom.to_string(fun)) do
      {:ok, verb, _score} -> verb
      :unknown -> nil
    end
  end

  # A stem matches when it is a whole `_`-delimited token of the call
  # name — `list` matches `list`, `list_brands`, `do_list`, but not
  # `enlist`. Keeps `get` from matching `forget`, `build` from `rebuild`
  # is intentional (a rebuild still builds).
  defp stem_match?(name, stem) do
    name == stem or
      String.starts_with?(name, stem <> "_") or
      String.ends_with?(name, "_" <> stem) or
      String.contains?(name, "_" <> stem <> "_")
  end

  # --- object part (from live-out) ---

  defp object_part(live_out) do
    meaningful =
      live_out
      |> Enum.reject(&(&1 in @boilerplate))
      |> Enum.filter(&meaningful_name?/1)

    case meaningful do
      [single] -> single
      [a, b] -> :"#{a}_and_#{b}"
      _ -> nil
    end
  end

  defp compose(nil, _object), do: nil
  defp compose(_verb, nil), do: nil
  defp compose(verb, object), do: :"#{verb}_#{object}"

  # --- source object (carrier the producing calls read from) ---

  # Accessor calls that *read out of* their first argument — `Keyword.get`,
  # `Map.get`, `Map.fetch!`, `get_in`, … A binding whose RHS is one of these
  # treats its first argument as a container being unpacked, not a value being
  # transformed. That distinction is what makes the source carrier a sound
  # object: `Keyword.get(opts, :x)` reads *from* opts, `one(order)` builds
  # *from* order — only the former names the helper after its input.
  @accessor_calls ~w(get get! fetch fetch! get_in get_lazy take)a

  # A boilerplate carrier (`assigns`, `socket`, …) is too generic to name a
  # helper after — except when it is fanned into this many or more bindings,
  # at which point `fetch_assigns` genuinely describes a container-unpacking
  # block better than the `<fn>_block` fallback does.
  @boilerplate_source_floor 3

  # When the live-outs give no object (3+ meaningful names, or none), the
  # block is usually a `Keyword.get(opts, …)` / `Map.get(filters, …)` ladder
  # that fans one container into many bindings. The name then comes from that
  # *container*, not the outputs: `fetch_opts`, `fetch_filters`. Only fires
  # when every *accessor* producing call reads from the *same* meaningful
  # first argument — a single shared carrier. Non-accessor lines (a transform
  # like `search = opts |> get(:s) |> trim()`, or `deduped = query(…)`)
  # contribute no carrier and are simply skipped, so one transforming line
  # among the reads doesn't block naming the rest. A boilerplate carrier
  # counts only past `@boilerplate_source_floor` reads. Skipped when
  # `object_part` already found one (this is a `compose(verb, source)`
  # fallback after the live-out objects).
  defp source_object(stmts, live_out) do
    case stmts |> Enum.flat_map(&live_out_source(&1, MapSet.new(live_out))) do
      [carrier | _] = carriers ->
        if Enum.all?(carriers, &(&1 == carrier)) and usable_source?(carrier, length(carriers)),
          do: carrier,
          else: nil

      [] ->
        nil
    end
  end

  defp usable_source?(name, count) do
    meaningful_name?(name) and (name not in @boilerplate or count >= @boilerplate_source_floor)
  end

  # The first-argument variable of a binding `var = accessor(arg, …)` whose
  # `var` is a live-out and whose RHS is an accessor call — the container the
  # call reads from. A non-accessor RHS (`one(order)`, a transforming pipe)
  # yields no carrier, so a transforming line never names the block after its
  # input and never poisons the shared-carrier check.
  defp live_out_source({:=, _, [lhs, rhs]}, live_outs) do
    with {var, _, ctx} when is_atom(var) and is_atom(ctx) <- lhs,
         true <- MapSet.member?(live_outs, var),
         carrier when is_atom(carrier) and not is_nil(carrier) <- accessor_source(rhs) do
      [carrier]
    else
      _ -> []
    end
  end

  defp live_out_source(_stmt, _live_outs), do: []

  # The first-argument variable of an accessor call. Two shapes:
  #   * direct — `Keyword.get(opts, :x)` → carrier is the first arg `opts`.
  #   * piped  — `opts |> Keyword.get(:x)` → carrier is the pipe's bare-var
  #     LHS, accessor name from the RHS. A longer pipe whose immediate RHS is
  #     not an accessor (`opts |> Keyword.get(:x) |> then(…)`) yields nil — the
  #     value is transformed past the read, no longer a clean container access.
  # Yields nil unless the call name is in `@accessor_calls` and the carrier is
  # a bare variable.
  defp accessor_source({:|>, _, [{name, _, ctx}, {{:., _, [_mod, fun]}, _, _}]})
       when fun in @accessor_calls and is_atom(name) and is_atom(ctx),
       do: name

  defp accessor_source({{:., _, [_mod, fun]}, _, [{name, _, ctx} | _]})
       when fun in @accessor_calls and is_atom(name) and is_atom(ctx),
       do: name

  defp accessor_source(_), do: nil

  # The three-part name only forms when verb, attribute AND object are all
  # present; otherwise nil and the plain `verb_object` is used.
  defp compose(nil, _attribute, _object), do: nil
  defp compose(_verb, nil, _object), do: nil
  defp compose(_verb, _attribute, nil), do: nil
  defp compose(verb, attribute, object), do: :"#{verb}_#{attribute}_#{object}"

  # --- attribute inference (optional middle word) ---

  # Pull boolean predicate fields out of the block's filter/where calls and
  # classify the first one that is an adjective. Most blocks carry no such
  # field, so this is usually nil — the attribute is a bonus, never forced.
  defp infer_attribute(stmts) do
    stmts
    |> Enum.flat_map(&predicate_fields/1)
    |> Enum.find_value(&classify_attribute/1)
  end

  defp classify_attribute(field) do
    case AttributeClassifier.classify(Atom.to_string(field)) do
      {:ok, attribute} -> attribute
      :none -> nil
    end
  end

  # Field names read off a boolean predicate, surgically — only the access on
  # the lambda/row variable inside an `Enum.filter`/`Enum.reject`/`where` call,
  # not arbitrary block words. `Enum.reject(xs, & &1.archived)` → [:archived].
  defp predicate_fields(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&fields_in_filter_call/1)
  end

  defp fields_in_filter_call({{:., _, [{:__aliases__, _, [:Enum]}, fun]}, _, args})
       when fun in [:filter, :reject] do
    args |> Enum.flat_map(&access_fields/1)
  end

  defp fields_in_filter_call({:where, _, args}) when is_list(args) do
    args |> Enum.flat_map(&access_fields/1)
  end

  defp fields_in_filter_call(_), do: []

  # Field accesses `x.field` anywhere inside a predicate expression.
  defp access_fields(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {{:., _, [_obj, field]}, _, []} when is_atom(field) -> [field]
      _ -> []
    end)
  end

  # One- and two-letter names (`x`, `cs`), `_`-prefixed throwaways, and
  # `?`/`!`-marked names (the marker is only legal as the last character
  # of an identifier, so it can't sit inside a joined name) describe
  # nothing usable.
  defp meaningful_name?(name) do
    str = Atom.to_string(name)

    String.length(str) > 2 and
      not String.starts_with?(str, "_") and
      not String.ends_with?(str, ["?", "!"])
  end

  # --- host-derived fallbacks ---

  # `load_brands_block` would drop to `load_brands` — but only as a
  # candidate when the host name already reads as more than a bare verb
  # (`load_brands`, not `run`); a one-token host gives no object and
  # would just re-add the `_block`.
  defp strip_suffix(host) do
    name = Atom.to_string(host)
    if String.contains?(name, "_"), do: host, else: nil
  end

  @doc """
  Append a suffix to a host name, keeping a trailing `!`/`?` at the very
  end: `verify!` + `_block` → `verify_block!`, not the illegal
  `verify!_block` (a marker is only legal as an identifier's final
  character). Exposed so callers can build their own idiomatic fallback
  (`<fn>_phase_n`) the same bang-safe way.
  """
  @spec suffixed(atom(), String.t()) :: atom()
  def suffixed(host, suffix) do
    name = Atom.to_string(host)

    case String.split_at(name, -1) do
      {stem, marker} when marker in ["!", "?"] -> :"#{stem}#{suffix}#{marker}"
      {_, _} -> :"#{name}#{suffix}"
    end
  end

  defp first_free([], _existing), do: :skip

  defp first_free([candidate | rest], existing) do
    if MapSet.member?(existing, candidate),
      do: first_free(rest, existing),
      else: {:ok, candidate}
  end
end
