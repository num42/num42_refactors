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
  3. **host name without the suffix** — `load_brands_block` → `load_brands`
     when the host already reads as more than a bare verb.
  4. **fallback** — the caller's idiomatic last resort (`<fn>_block` or
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

  @boilerplate ~w(scope socket conn assigns)a

  # Verb inferred from the *function name* of the call that produces the
  # block's result. Order matters: the first matching predicate wins, so
  # the most specific signals (errors, string ops) precede the generic
  # "touches a collection → compute" catch-all.
  @verb_rules [
    {:validate, ~w(add_error validate validate_change validate_required put_error)},
    {:format, ~w(to_string humanize topic render_to_string)},
    {:normalize, ~w(downcase upcase trim capitalize normalize)},
    {:build, ~w(build new create changeset struct cast)},
    {:fetch, ~w(get fetch list all one get_field get_change get_assoc preload load find)}
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
    verb = infer_verb(stmts)
    object = object_part(live_out)
    fallback = Keyword.get(opts, :fallback, suffixed(host, "_block"))

    # `object` may be a single name (`filters`) or a join (`a_and_b`).
    # As a *standalone* name a single object always equals its live-out
    # and would shadow it — only a join is safe standalone. With a verb
    # the composed name (`fetch_filters`) differs from the live-out, so a
    # single object is fine there.
    derived =
      [compose(verb, object), standalone(object), strip_suffix(host)]
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

  # The producing call is the RHS of the last binding, or the bare tail
  # expression — that is what the block's result flows out of.
  defp infer_verb(stmts) do
    stmts
    |> dominant_call_name()
    |> verb_for_call()
  end

  defp dominant_call_name([]), do: nil

  defp dominant_call_name(stmts) do
    last = List.last(stmts)

    case last do
      {:=, _, [_lhs, rhs]} -> call_name(rhs)
      other -> call_name(other)
    end
  end

  # Unwrap a pipe to its final call; pull the function name out of a
  # remote (`Mod.fun`) or local (`fun`) call.
  defp call_name({:|>, _, [_lhs, rhs]}), do: call_name(rhs)
  defp call_name({{:., _, [_callee, fun]}, _, _}) when is_atom(fun), do: fun
  defp call_name({fun, _, args}) when is_atom(fun) and is_list(args), do: fun
  defp call_name(_), do: nil

  defp verb_for_call(nil), do: nil

  defp verb_for_call(fun) do
    name = Atom.to_string(fun)

    Enum.find_value(@verb_rules, fn {verb, stems} ->
      if Enum.any?(stems, &stem_match?(name, &1)), do: verb
    end)
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
