defmodule Number42.Refactors.Ex.ExpandShortFormParams do
  alias Sourceror.Patch

  @moduledoc """
  Renames short-form parameter names to their long form in
  single-clause `def`/`defp`/`defmacro`/`defmacrop` functions.

      def render(fb, assigns) do
        FormulaBuilder.draw(fb)
      end
      ↓ (with `alias MyApp.FormulaBuilder` in scope)
      def render(formula_builder, assigns) do
        FormulaBuilder.draw(formula_builder)
      end

  ## How it works

  Only fires on functions with a single clause (per `{name, arity}`
  group inside the module). Multi-clause functions need their
  parameter names to stay aligned across clauses, which we don't try
  to coordinate — that's a future refactor.

  For each parameter:

  1. **Underscore params skip.** `_x` is intentionally unused.
  2. **Whitelisted shorts skip.** `id`, `idx`, `ctx`, ...
  3. **`known` mapping wins** if the parameter name is in the
     project-configured map.
  4. **Struct pattern wins** when present: `def go(%Foo.Bar{} = bb)`
     is read as `bb` ↔ `bar` regardless of other signals.
  5. **Plural -s rule.** If the param ends in `s` and length > 1,
     try resolving the singular form (`fbs` → resolve `fb`); on
     success the result is pluralized.
  6. **Compound match** against, in order of strength:
     - Module aliases (`alias Ecto.Changeset` → `changeset`).
     - Imports (`import Ecto.Changeset` → `changeset`).
     - Enclosing function name (`render_formula_builder` → tokens).
     - Enclosing module name (`MyApp.FormulaBuilder` → tokens).
     - Other parameter names and body bindings (long forms only).

  The compound matcher uses the same latch-on-subtoken algorithm as
  `ExpandShortFormBindings`: the short's first char must be the
  initial of some compound subtoken; the remaining short chars must
  appear as a subsequence in the rest of that subtoken or as initials
  of following subtokens.

  ## Skip conditions

  - Multi-clause function (any arity match in the same module).
  - Underscore-prefixed param (`_cs`).
  - Pin-operator param (`^cs`) — it's a lookup, not a binding.
  - Whitelisted name.
  - Resolved long form collides with another param or any body
    binding.
  - No signal resolves the short to a single long form.

  ## Why procedural

  The walker needs to gather aliases/imports from the module top,
  detect single-clause groups, and rename a parameter and its body
  references in concert. The declarative DSL doesn't reach that far.
  """

  use Number42.Refactors.Refactor

  @impl Number42.Refactors.Refactor
  def description, do: "Expand short-form parameter names to long forms"

  @impl Number42.Refactors.Refactor
  def priority, do: 250

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Single-character and short-form parameter names (`cs`, `fb`,
    `org_id`) save typing for the author and cost reading time for
    everyone else. When the surrounding module's aliases/imports plus
    the function name plus the body usage all point unambiguously at
    one long form, expanding it makes the signature self-describing.
    Multi-clause functions are skipped because the cross-clause
    rename has to stay in sync — that's a separate refactor.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  # Whitelist and known mapping live in `.refactor.exs` — single
  # source of truth shared by all ExpandShortForm refactors. The
  # defaults here are empty so config drives everything.
  @default_whitelist MapSet.new()

  @known %{}

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    ctx = build_ctx(opts)

    Sourceror.parse_string(source) |> apply_patches(ctx, source)
  end

  @doc """
  Collects every field name declared by an `Ecto.Schema` module under
  `lib/`, plus the individual subtokens of each field. The engine calls
  this once per pipeline run and threads the result through every
  `transform/2` invocation as `opts[:prepared]`.

  Why: schema field names are project-defined identifiers. A param
  named after a field (`oz_fragment`, `parent`, `item_positions`) must
  not be heuristically rewritten — that would diverge from the schema
  and break callers. Subtokens of field names are also protected so
  that `oz_chain` doesn't get its `oz` rewritten just because the
  refactor noticed an `oz_*` field elsewhere.
  """
  @impl Number42.Refactors.Refactor
  def prepare(_opts) do
    fields = collect_schema_fields()

    subtokens =
      fields
      |> Enum.flat_map(&String.split(&1, "_", trim: true))
      |> MapSet.new()

    {:ok, %{schema_fields: MapSet.new(fields), schema_subtokens: subtokens}}
  end

  defp build_ctx(opts) do
    prepared = Keyword.get(opts, :prepared, %{})
    extra_whitelist = opts |> Keyword.get(:whitelist, []) |> Enum.map(&to_atom/1) |> MapSet.new()

    %{
      known: Map.merge(@known, Keyword.get(opts, :known, %{})),
      pp_verbs: opts |> Keyword.get(:pp_verbs, []) |> MapSet.new(),
      schema_fields: Map.get(prepared, :schema_fields, MapSet.new()),
      schema_subtokens: Map.get(prepared, :schema_subtokens, MapSet.new()),
      whitelist: MapSet.union(@default_whitelist, extra_whitelist)
    }
  end

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_atom(s)

  # Walks `lib/**/*.ex`, parses each file, collects field declarations
  # from modules that `use Ecto.Schema`. Tolerant: a parse failure on
  # any single file just yields `[]` for that file.
  defp collect_schema_fields,
    do:
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(&fields_in_file/1)
      |> Enum.uniq()

  defp fields_in_file(patch), do: File.read(patch) |> parse_schema_file()

  defp fields_in_source(source), do: Code.string_to_quoted(source) |> extract_fields_from_quoted()

  defp uses_ecto_schema?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:use, _, [{:__aliases__, _, [:Ecto, :Schema]} | _]} -> true
      _ -> false
    end)
  end

  # The schema DSL keywords whose first arg is the field/association
  # name. `field/2` and `field/3` both fit `field :name, ...`.
  @schema_decls ~w(field belongs_to has_many has_one many_to_many embeds_one embeds_many)a

  defp extract_field_names(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {decl, _, [name | _]} when decl in @schema_decls and is_atom(name) ->
        [Atom.to_string(name)]

      # `timestamps` and `timestamps(opts)` produce `inserted_at` and
      # `updated_at` fields universally. Always include them.
      {:timestamps, _, _} ->
        ["inserted_at", "updated_at"]

      _ ->
        []
    end)
  end

  defp build_patches(ast, ctx) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, _} = mod_node -> patches_for_module(mod_node, ctx)
      _ -> []
    end)
  end

  defp patches_for_module({:defmodule, _, [name_ast, [{_, body}]]}, ctx) do
    module_compounds = module_name_compounds(name_ast)
    body_exprs = body_to_exprs(body)
    alias_compounds = collect_alias_compounds(body_exprs)
    import_compounds = collect_import_compounds(body_exprs)

    def_groups = collect_def_groups(body_exprs)

    def_groups
    |> Enum.flat_map(fn
      {{_name, _arity}, [single_clause]} ->
        patches_for_clause(single_clause, %{
          aliases: alias_compounds,
          ctx: ctx,
          imports: import_compounds,
          module: module_compounds
        })

      _ ->
        []
    end)
  end

  defp patches_for_module(_, _), do: []

  defp module_name_compounds({:__aliases__, _, parts}) when is_list(parts) do
    parts
    |> Enum.map(fn p -> p |> Atom.to_string() |> Macro.underscore() end)
    |> Enum.map(&strip_test_suffix/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp module_name_compounds(_), do: []

  # `FooTest` and `FooLiveTest` shouldn't seed `view → view_test` or
  # `live_view → live_view_test` matches. Drop the trailing `_test`
  # subtoken from any module-name compound that has it.
  defp strip_test_suffix(compound), do: String.split(compound, "_") |> drop_test_suffix(compound)

  # `alias Foo.Bar.Baz` → "baz" (Macro.underscore on the last segment).
  # `alias Foo.{Bar, Baz}` → ["bar", "baz"].
  # `alias Foo, as: F` → skip (the user already chose a short alias).
  defp collect_alias_compounds(exprs) do
    exprs
    |> Enum.flat_map(fn
      {:alias, _, [{:__aliases__, _, parts}]} when is_list(parts) ->
        [parts |> List.last() |> Atom.to_string() |> Macro.underscore()]

      {:alias, _, [{{:., _, [{:__aliases__, _, _}, :{}]}, _, multi}]} ->
        multi
        |> Enum.flat_map(fn
          {:__aliases__, _, parts} when is_list(parts) ->
            [parts |> List.last() |> Atom.to_string() |> Macro.underscore()]

          _ ->
            []
        end)

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp collect_import_compounds(exprs) do
    exprs
    |> Enum.flat_map(fn
      {:import, _, [{:__aliases__, _, parts} | _]} when is_list(parts) ->
        [parts |> List.last() |> Atom.to_string() |> Macro.underscore() |> strip_test_suffix()]

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
  end

  # Group `def`/`defp`/... by `{name, arity}` so we can detect
  # multi-clause functions and skip them wholesale.
  defp collect_def_groups(exprs) do
    exprs
    |> Enum.flat_map(fn
      {kind, _, [head, _body_kw]} = def_node
      when def_or_macro_kind?(kind) ->
        case extract_fn_signature(head) do
          {name, params} -> [{{name, length(params)}, def_node}]
          :error -> []
        end

      _ ->
        []
    end)
    |> Enum.group_by(fn {key, _} -> key end, fn {_, node} -> node end)
  end

  defp patches_for_clause({_kind, _meta, [head, body_kw]}, env) do
    {fn_name, params} = extract_fn_signature(head)
    guard = head_guard(head)
    fn_compound = Atom.to_string(fn_name)

    body =
      body_kw
      |> Enum.find_value(nil, fn
        {{:__block__, _, [:do]}, body} -> body
        {:do, body} -> body
        _ -> nil
      end)

    if is_nil(body) do
      []
    else
      param_infos =
        params
        |> Enum.map(&analyze_param/1)
        |> Enum.reject(&is_nil/1)

      param_atoms = param_infos |> Enum.map(& &1.name)
      param_compounds = param_atoms |> Enum.map(&Atom.to_string/1)

      body_bindings = collect_body_bindings(body)

      body_long_compounds =
        body_bindings |> Enum.filter(&long?(&1, env.ctx)) |> Enum.map(&Atom.to_string/1)

      occupied = MapSet.new(param_atoms ++ body_bindings)

      context_compounds =
        ([fn_compound] ++
           env.aliases ++ env.imports ++ env.module ++ param_compounds ++ body_long_compounds)
        |> Enum.uniq()
        |> Enum.reject(&(&1 == ""))

      resolutions =
        param_infos
        |> Enum.filter(&short?(&1.name, env.ctx))
        |> Enum.flat_map(fn info ->
          case resolve_param(info, context_compounds, env.ctx) do
            {:ok, long} ->
              long_atom = String.to_atom(long)
              short_string = Atom.to_string(info.name)

              cond do
                long_atom == info.name -> []
                long == fn_compound -> []
                MapSet.member?(occupied, long_atom) -> []
                # Trivial pluralize/singularize is not a meaningful
                # resolution: `kws -> kw`, `ops -> op` are just
                # singularizing the param itself, not adding info.
                singularize(short_string) == long -> []
                # `var -> var_arg`, `vec -> vec_a`: long is just the
                # short with extra subtokens glued on. The short was
                # matched only as initials of the start of some
                # compound; that's a weak signal — usually means we
                # latched on the function name and walked rightward.
                String.starts_with?(long, short_string <> "_") -> []
                true -> [{info.name, long_atom}]
              end

            :skip ->
              []
          end
        end)
        |> Map.new()

      if map_size(resolutions) == 0 do
        []
      else
        # Patches: every reference to a resolved name in head AND body.
        # The guard (`when length(xs) >= 2`) lives in `head` but is
        # stripped by `extract_fn_signature/1`; include it explicitly so
        # guard variables get renamed in lockstep with their params.
        scope_nodes = Enum.map(params, & &1) ++ List.wrap(guard) ++ [body]

        ast_patches =
          scope_nodes
          |> Enum.flat_map(&Macro.prewalker/1)
          |> Enum.flat_map(fn
            {name, _meta, atom_ctx} = node when is_atom(name) and is_atom(atom_ctx) ->
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

        ast_patches ++ heex_patches(body, resolutions)
      end
    end
  end

  defp head_guard({:when, _, [_inner, guard]}), do: guard
  defp head_guard(_), do: nil

  # When a renamed param is referenced inside a `~H` sigil — `{dep.x}`,
  # `<input value={dep}>`, `&dep.method/1` — the AST walker can't see
  # those references (the sigil body is an opaque binary). Patch the
  # sigil text directly with a word-boundary regex so the rename stays
  # consistent across AST and HEEx, mirroring the same fix landed in
  # ExpandShortFormFunctions (commit 9bab5c07).
  defp heex_patches(body, resolutions) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:sigil_H, meta, [{:<<>>, _, [content]}, _]} = node when is_binary(content) ->
        new_content = patch_heex_var_content(content, resolutions)

        if new_content == content do
          []
        else
          delim = Keyword.get(meta, :delimiter, "\"")
          prefix = if delim in ["\"\"\"", "'''"], do: "\n", else: ""
          new_text = "~H#{delim}#{prefix}#{new_content}#{delim}"
          [Patch.new(Sourceror.get_range(node), new_text)]
        end

      _ ->
        []
    end)
  end

  defp patch_heex_var_content(content, resolutions) do
    resolutions
    |> Enum.reduce(content, fn {old, new}, acc ->
      old_re = old |> Atom.to_string() |> Regex.escape()
      new_str = Atom.to_string(new)
      String.replace(acc, ~r/(?<![A-Za-z0-9_])#{old_re}(?![A-Za-z0-9_])/, new_str)
    end)
  end

  # Strip pattern wrappers and recover the parameter's bare-var atom
  # plus any struct hint. Returns nil for shapes that can't be
  # renamed (literals, full destructuring, pin).
  defp analyze_param({:\\, _, [inner, _default]}), do: analyze_param(inner)
  defp analyze_param({:^, _, _}), do: nil

  defp analyze_param({:=, _, [a, b]}) do
    case {analyze_param(a), analyze_param(b)} do
      {%{name: name_a} = info_a, %{struct: s}}
      when not is_nil(name_a) and not is_nil(s) ->
        %{info_a | struct: s}

      {%{struct: s}, %{name: name_b} = info_b}
      when not is_nil(name_b) and not is_nil(s) ->
        %{info_b | struct: s}

      {%{name: name_a} = info, _} when not is_nil(name_a) ->
        info

      {_, %{name: name_b} = info} when not is_nil(name_b) ->
        info

      _ ->
        nil
    end
  end

  defp analyze_param({:%, _, [struct_ast, {:%{}, _, _}]}),
    do: struct_compound(struct_ast) |> param_compound_or_default()

  defp analyze_param({name, _meta, ctx} = node) when is_atom(name) and is_atom(ctx) do
    string = Atom.to_string(name)

    if String.starts_with?(string, "_") or name in [:__MODULE__, :__CALLER__, :__ENV__] do
      nil
    else
      %{name: name, node: node, struct: nil}
    end
  end

  defp analyze_param(_), do: nil

  defp struct_compound({:__aliases__, _, parts}) when is_list(parts) and parts != [] do
    parts |> List.last() |> Atom.to_string() |> Macro.underscore()
  end

  defp struct_compound(_), do: nil

  defp collect_body_bindings(body) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:=, _, [{name, _, ctx}, _rhs]} when is_atom(name) and is_atom(ctx) ->
        [name]

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  # Schema-defined names (`oz_fragment`, `parent`, `item_positions`)
  # are project identifiers, not shorts. Skip those before falling
  # through to the shared `short_name?/2` heuristic.
  defp short?(name, ctx) do
    string = Atom.to_string(name)

    if MapSet.member?(ctx.schema_fields, string) do
      false
    else
      short_name?(name, ctx)
    end
  end

  defp long?(name, ctx), do: not short?(name, ctx)

  # Resolve order:
  # 1. Known table
  # 2. Struct pattern (%X{} = name)
  # 3. Plural -s rule (param ends in `s` → resolve singular, pluralize)
  # 4. Compound-context match
  defp resolve_param(%{name: name} = info, context_compounds, ctx) do
    string = Atom.to_string(name)

    cond do
      Map.has_key?(ctx.known, string) ->
        {:ok, Map.fetch!(ctx.known, string)}

      not is_nil(info.struct) ->
        {:ok, info.struct}

      # Plural-looking param: ONLY resolve via the plural rule. A
      # direct compound match for a plural-looking short would
      # silently singularize (`cts ↔ formula_picker_components` →
      # `component`), losing the plurality the author chose.
      String.ends_with?(string, "s") and String.length(string) >= 3 ->
        maybe_plural_resolve(string, context_compounds, ctx)

      true ->
        resolve_via_compounds(string, context_compounds, ctx)
    end
  end

  defp resolve_param(_, _, _), do: :skip

  # If the param ends in `s` and is long enough that the trailing `s`
  # is plausibly a plural marker (>= 3 chars total — `xs` is too short
  # for a real signal), try resolving the singular form. On success,
  # pluralize the result.
  defp maybe_plural_resolve(string, context_compounds, ctx) do
    if String.ends_with?(string, "s") and String.length(string) >= 3 do
      singular = String.slice(string, 0..-2//1)
      # The plural form `string` itself often appears in context (it's
      # the param name); a self-match would just turn `cts` into the
      # singular `ct`, which isn't a resolution. Drop both `string`
      # and `singular` from candidates so we only consider real
      # external compounds.
      compounds = context_compounds |> Enum.reject(&(&1 == string or &1 == singular))

      case resolve_via_compounds(singular, compounds, ctx) do
        {:ok, long} -> {:ok, pluralize_compound(long)}
        :skip -> :skip
      end
    else
      :skip
    end
  end

  # Single-char shorts can't be resolved via compound matching: any
  # subtoken starting with that char would latch with score 100, giving
  # silent false positives across the codebase. Single chars must come
  # from `known` or struct hints if they're going to be renamed at all.
  defp resolve_via_compounds(short, _context_compounds, _ctx) when byte_size(short) < 2,
    do: :skip

  defp resolve_via_compounds(short, context_compounds, ctx) do
    candidates =
      context_compounds
      |> Enum.reject(&(&1 == short))
      |> Enum.flat_map(fn compound ->
        case match_compound(short, compound, ctx) do
          {:ok, target, score} -> [{target, score}]
          :error -> []
        end
      end)
      |> Enum.sort_by(fn {_target, score} -> -score end)

    case candidates do
      [] -> :skip
      [{target, _}] -> {:ok, target}
      [{target, s1}, {_, s2} | _] when s1 > s2 -> {:ok, target}
      _ -> :skip
    end
  end

  # Match `short` against `compound` using the latch-on-subtoken
  # algorithm. Returns `{:ok, target, score}` or `:error`.
  #
  # Score:
  # - 100 when ALL short chars are subtoken initials (a clean acronym).
  # - 80 when only the first short char is a subtoken initial and the
  #   rest fit as a subsequence inside that subtoken.
  # - 0 otherwise (we return :error).
  defp match_compound(short, compound, ctx) do
    subtokens = String.split(compound, "_", trim: true)

    latch_match(short, subtokens) |> score_latch_result(ctx, short, subtokens)
  end

  # Would shifting head=[verb], tail=[last] produce a valid PP? Only
  # then is it worth giving up the full-tail interpretation.
  defp pp_promotable?(subtokens, ctx) do
    {head, [last]} = subtokens |> Enum.split(-1)

    List.last(head) |> pp_target_for_last_token(ctx, last)
  end

  defp build_target(subtokens, n, ctx) do
    {head, tail} = subtokens |> Enum.split(-n)
    singularized = tail |> List.last() |> singularize()
    tail_compound = (Enum.drop(tail, -1) ++ [singularized]) |> Enum.join("_")

    maybe_past_participle(head, tail, singularized, ctx.pp_verbs)
    |> apply_pp_or_keep_singular(tail_compound)
  end

  defp apply_patches({:ok, ast}, ctx, source),
    do: build_patches(ast, ctx) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, _ctx, source), do: source

  defp parse_schema_file({:ok, source}), do: source |> fields_in_source()

  defp parse_schema_file(_), do: []

  defp extract_fields_from_quoted({:ok, ast}) do
    if uses_ecto_schema?(ast) do
      extract_field_names(ast)
    else
      []
    end
  end

  defp extract_fields_from_quoted({:error, _}), do: []

  defp drop_test_suffix([], compound), do: compound

  defp drop_test_suffix([_], compound), do: compound

  defp drop_test_suffix([_, _ | _] = tokens, compound),
    do: List.last(tokens) |> pop_test_suffix_from_tokens(compound, tokens)

  defp drop_test_suffix(_, compound), do: compound

  defp param_compound_or_default(nil), do: nil

  defp param_compound_or_default(compound), do: %{name: nil, node: nil, struct: compound}

  defp score_latch_result({:ok, start_idx, starts_hit}, ctx, short, subtokens) do
    effective_start =
      if start_idx == 0 and String.length(short) > 1 and length(subtokens) > 1 and
           pp_promotable?(subtokens, ctx) do
        length(subtokens) - 1
      else
        start_idx
      end

    n = length(subtokens) - effective_start
    target = build_target(subtokens, n, ctx)
    score = if starts_hit == String.length(short), do: 100, else: 80
    {:ok, target, score}
  end

  defp score_latch_result(:error, _ctx, _short, _subtokens), do: :error

  defp pp_target_for_last_token(nil, _ctx, _last), do: false

  defp pp_target_for_last_token(verb, ctx, last),
    do:
      MapSet.member?(ctx.pp_verbs, verb) and String.ends_with?(verb, "e") and
        singularize(last) != last

  defp apply_pp_or_keep_singular({:ok, pp}, tail_compound),
    do: [pp, tail_compound] |> Enum.join("_")

  defp apply_pp_or_keep_singular(:skip, tail_compound), do: tail_compound

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  defp pop_test_suffix_from_tokens("test", _compound, tokens),
    do: tokens |> Enum.drop(-1) |> Enum.join("_")

  defp pop_test_suffix_from_tokens(_, compound, _tokens), do: compound
end
