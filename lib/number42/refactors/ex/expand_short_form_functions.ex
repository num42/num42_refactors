defmodule Number42.Refactors.Ex.ExpandShortFormFunctions do
  alias Number42.Refactors.IdentifierExpansion
  alias Sourceror.Patch

  @moduledoc """
  Renames short-form `defp`/`defmacrop` function names to their long
  form. Patches the definition (all clauses) and every call site
  inside the same module.

      defmodule M do
        alias Ecto.Changeset

        defp fetch_cs(arg), do: arg

        def go(x), do: fetch_cs(x)
      end
      ↓
      defmodule M do
        alias Ecto.Changeset

        defp fetch_changeset(arg), do: arg

        def go(x), do: fetch_changeset(x)
      end

  ## How it works

  Walks each module top-level. For every private definition
  (`defp`/`defmacrop`), splits the name on `_` and expands each
  subtoken that is short (≤ 3 chars) and not whitelisted:

  1. **`@known` mapping wins** if a subtoken is in the project map
     (e.g. `kw → keyword`).
  2. **Compound-resolve** otherwise: try to resolve the subtoken
     against the module's aliases / imports / module-name tokens
     using the same latch-on-subtoken algorithm as
     `ExpandShortFormBindings`.

  If every short subtoken resolves, the new name is the join of the
  expanded parts. The refactor patches:

  - The definition head (every clause of the same `{name, arity}` group).
  - Every internal call site (`fetch_cs(...)` and `&fetch_cs/1` inside
    the module body, but not `M.fetch_cs(...)` — those don't appear
    for private functions anyway).

  ## Skip conditions

  - **Public defs.** A `def`/`defmacro` rename would silently break
    cross-module callers; we don't walk the rest of the codebase.
  - **No short subtoken.** All parts are long or whitelisted.
  - **No subtoken resolves.** The name is short but neither
    `@known` nor compound-resolve produces an expansion.
  - **Collision.** The expanded name already exists as another
    function (any kind, any arity) in the same module, OR it is a
    macro injected into the module by a `use` statement (e.g.
    `use ExUnit.Case` exports `test/2`, `describe/2`). Renaming a
    short helper onto such a name shadows the macro and breaks
    compilation.
  - **Single-char subtokens.** `f(...)` etc. — no signal strong
    enough to expand without false positives.

  ## Why procedural

  The walk needs to gather aliases/imports from the module top, group
  defs by `{name, arity}`, and patch the definition together with
  every call site. The declarative DSL doesn't reach that far.
  """

  use Number42.Refactors.Refactor

  @impl Number42.Refactors.Refactor
  def description, do: "Expand short-form private function names to long forms"

  @impl Number42.Refactors.Refactor
  def priority, do: 250

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Short private function names (`fetch_kw`, `do_cs`, `pos_eq`) save
    typing and cost reading time. When the surrounding module's
    aliases/imports plus the project's `known` mapping point
    unambiguously at a long form, expanding the name makes the
    callsite self-describing. Public `def`/`defmacro` are left alone
    to avoid breaking cross-module callers.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  # Whitelist and known mapping live in `.refactor.exs` — single
  # source of truth shared by all ExpandShortForm refactors. The
  # defaults here are empty so config drives everything.
  @default_whitelist MapSet.new()

  @known %{}

  # English function words that carry semantic meaning when they
  # appear as a subtoken of a function name (`pair_sort_key`,
  # `patches_for_node`, `length_of_list`). They look like
  # abbreviations to the ≤ 3-char heuristic but they aren't — they
  # name a relation, not a thing. Expanding them silently produces
  # nonsense names (`pair_sort_keywords`, `patches_form_node`) and
  # — worse — kills compilation when the rename only patches some
  # call sites. The list is intentionally conservative: only words
  # that are unambiguous English function words AND short enough
  # (≤ 3 chars) to fall into the heuristic's expansion window.
  # Treated as a hard guarantee — even an explicit `known` mapping
  # for these tokens is refused.
  @stop_words MapSet.new(~w(
                add all and any as at
                be but by
                do
                end
                for
                get
                if in is
                key
                new not
                of old on one or out
                put
                set
                the to top two
                up
              )a)

  # Callable names that `use <Module>` injects into the surrounding
  # module. Renaming a short helper onto one of these shadows the
  # macro (`defp test/2` shadows `ExUnit.Case.test/2`) and breaks
  # compilation: the parser binds the later `test "..." do ... end`
  # to the new local 2-arity function instead of the macro, and
  # `Kernel.def/2`'s no-function-scope guard fires.
  #
  # Keyed on the full `use` alias path so we never refuse a rename
  # in a module that doesn't actually `use` that framework. The
  # table is intentionally conservative: only the well-known
  # test/spec macros whose names fall in the short-helper expansion
  # window are listed. Extend here when a new framework's injected
  # callables collide with plausible long forms.
  @use_injected_callables %{
    [:ExUnit, :Case] => ~w(test describe setup setup_all)a,
    [:ExUnit, :CaseTemplate] => ~w(test describe setup setup_all)a
  }

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    ctx = build_ctx(opts)

    Sourceror.parse_string(source) |> apply_patches(ctx, source)
  end

  defp build_ctx(opts) do
    extra_whitelist =
      opts |> Keyword.get(:whitelist, []) |> Enum.map(&to_atom/1) |> MapSet.new()

    %{
      known: Map.merge(@known, Keyword.get(opts, :known, %{})),
      whitelist: MapSet.union(@default_whitelist, extra_whitelist)
    }
  end

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_atom(s)

  defp build_patches(ast, ctx) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, _} = mod_node -> patches_for_module(mod_node, ctx)
      _ -> []
    end)
  end

  defp patches_for_module({:defmodule, _, [name_ast, [{_, body}]]}, ctx) do
    body_exprs = body_to_exprs(body)

    candidates =
      tagged_candidates(
        module_name_compounds(name_ast),
        collect_alias_compounds(body_exprs),
        collect_import_compounds(body_exprs)
      )

    {private_groups, def_names} = collect_private_def_groups(body_exprs)
    all_def_subtokens_by_name = collect_def_subtokens_by_name(body_exprs)

    # A rename target is occupied if it's already a def in the module
    # OR a macro injected by a `use` statement (`use ExUnit.Case` →
    # `test`, `describe`, ...). Shadowing either breaks compilation.
    occupied_names = MapSet.union(def_names, collect_use_injected_callables(body_exprs))

    resolutions =
      private_groups
      |> Enum.flat_map(fn {{name, _arity}, _nodes} ->
        # standalone-word demotion: include subtokens from every def
        # EXCEPT the one currently being resolved. Otherwise a self-
        # subtoken (`cs` in `fetch_cs`) would block its own expansion.
        module_subtokens =
          all_def_subtokens_by_name
          |> Map.delete(name)
          |> Map.values()
          |> Enum.reduce(MapSet.new(), &MapSet.union/2)

        case resolve_name(name, candidates, module_subtokens, ctx) do
          {:ok, new_name_atom} -> rename_or_skip(name, new_name_atom, occupied_names)
          :skip -> []
        end
      end)
      |> Map.new()

    if map_size(resolutions) == 0 do
      []
    else
      build_rename_patches(body, resolutions) ++ heex_patches(body, resolutions)
    end
  end

  defp patches_for_module(_, _), do: []

  # A resolved rename is dropped if it's a no-op or would collide with
  # an occupied name; otherwise it becomes a {old, new} pair.
  defp rename_or_skip(name, new_name_atom, occupied_names) do
    cond do
      new_name_atom == name -> []
      MapSet.member?(occupied_names, new_name_atom) -> []
      true -> [{name, new_name_atom}]
    end
  end

  defp tagged_candidates(module_compounds, alias_compounds, import_compounds) do
    (Enum.map(module_compounds, &{&1, :module_name}) ++
       Enum.map(alias_compounds, &{&1, :alias}) ++
       Enum.map(import_compounds, &{&1, :import}))
    |> Enum.uniq_by(fn {compound, _} -> compound end)
    |> Enum.reject(fn {compound, _} -> compound == "" end)
  end

  defp collect_def_subtokens_by_name(exprs) do
    exprs
    |> Enum.flat_map(fn
      {kind, _, [head, _body]} when kind in [:def, :defp, :defmacro, :defmacrop] ->
        case extract_fn_signature(head) do
          {name, _params} ->
            subs = name |> Atom.to_string() |> String.split("_", trim: true) |> MapSet.new()
            [{name, subs}]

          :error ->
            []
        end

      _ ->
        []
    end)
    |> Enum.reduce(%{}, fn {name, subs}, acc ->
      Map.update(acc, name, subs, &MapSet.union(&1, subs))
    end)
  end

  defp module_name_compounds({:__aliases__, _, parts}) when is_list(parts) do
    parts
    |> Enum.map(fn p -> p |> Atom.to_string() |> Macro.underscore() end)
    |> Enum.reject(&(&1 == ""))
  end

  defp module_name_compounds(_), do: []

  defp collect_alias_compounds(exprs) do
    exprs
    |> Enum.flat_map(fn
      {:alias, _, [{:__aliases__, _, parts}]} when is_list(parts) ->
        [parts |> List.last() |> Atom.to_string() |> Macro.underscore()]

      {:alias, _, [{{:., _, [{:__aliases__, _, _}, :{}]}, _, multi}]} ->
        Enum.flat_map(multi, &alias_compound/1)

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp alias_compound({:__aliases__, _, parts}) when is_list(parts),
    do: [parts |> List.last() |> Atom.to_string() |> Macro.underscore()]

  defp alias_compound(_), do: []

  defp collect_import_compounds(exprs) do
    exprs
    |> Enum.flat_map(fn
      {:import, _, [{:__aliases__, _, parts} | _]} when is_list(parts) ->
        [parts |> List.last() |> Atom.to_string() |> Macro.underscore()]

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
  end

  # Macros pulled into the module by `use <Module>`. Looks each
  # used module up in `@use_injected_callables` (keyed on the full
  # alias path) and unions the injected callable names. Modules not
  # in the table contribute nothing — the guard never widens beyond
  # the frameworks we know inject short-helper-colliding macros.
  defp collect_use_injected_callables(exprs) do
    exprs
    |> Enum.flat_map(fn
      {:use, _, [{:__aliases__, _, parts} | _]} when is_list(parts) ->
        Map.get(@use_injected_callables, parts, [])

      _ ->
        []
    end)
    |> MapSet.new()
  end

  # Returns {private_groups, all_def_names_set}.
  # private_groups: %{{name, arity} => [def_node, ...]} for defp/defmacrop only.
  # all_def_names_set: every def name in the module (any kind, any arity)
  #   — used to detect rename collisions.
  defp collect_private_def_groups(exprs) do
    {priv_pairs, all_names} =
      exprs
      |> Enum.reduce({[], MapSet.new()}, fn
        {kind, _, [head, _body_kw]} = node, {pairs, names}
        when kind in [:def, :defp, :defmacro, :defmacrop] ->
          reduce_def_node(kind, node, head, pairs, names)

        _, acc ->
          acc
      end)

    grouped = priv_pairs |> Enum.group_by(fn {key, _} -> key end, fn {_, node} -> node end)
    {grouped, all_names}
  end

  defp reduce_def_node(kind, node, head, pairs, names) do
    case extract_fn_signature(head) do
      {name, params} ->
        names = names |> MapSet.put(name)

        if kind in [:defp, :defmacrop] do
          {[{{name, length(params)}, node} | pairs], names}
        else
          {pairs, names}
        end

      :error ->
        {pairs, names}
    end
  end

  # Try to expand each short non-whitelisted subtoken of the function
  # name. Returns {:ok, new_atom} when EVERY short subtoken resolves
  # AND at least one expansion actually changes the name; otherwise :skip.
  defp resolve_name(name, candidates, module_subtokens, ctx) do
    self = Atom.to_string(name)
    parts = String.split(self, "_")
    other_parts = MapSet.new(parts)

    resolve_opts = build_resolve_opts(self, module_subtokens, ctx)

    parts
    |> expand_parts(candidates, resolve_opts, other_parts)
    |> finalize_name(self)
  end

  defp expand_parts(parts, candidates, resolve_opts, other_parts) do
    Enum.reduce_while(parts, [], fn part, acc ->
      # Long enough: keep as-is.
      if String.length(part) > 3 do
        {:cont, [part | acc]}
      else
        resolve_part(part, candidates, resolve_opts, other_parts, acc)
      end
    end)
  end

  defp finalize_name(:skip, _self), do: :skip

  defp finalize_name(reversed_parts, self) do
    new_name_string = reversed_parts |> Enum.reverse() |> Enum.join("_")

    if new_name_string == self do
      :skip
    else
      {:ok, String.to_atom(new_name_string)}
    end
  end

  defp build_resolve_opts(self, module_subtokens, ctx) do
    %{
      self: self,
      module_subtokens: module_subtokens,
      whitelist: ctx.whitelist,
      stop_words: @stop_words,
      known: ctx.known,
      min_score: 80
    }
  end

  defp resolve_part(part, candidates, resolve_opts, other_parts, acc) do
    case IdentifierExpansion.resolve(part, candidates, resolve_opts) do
      {:ok, expansion} ->
        cond do
          # Weak singular/plural flip — the expansion is just
          # `part`'s plural (`row → rows`) or singular form.
          # That's almost certainly a false positive: the
          # subtoken latched on a module-name tail whose only
          # similarity to the short is cardinality. Changing
          # `build_item_row` → `build_item_rows` silently
          # flips the semantic the author chose; refuse.
          trivial_inflection?(part, expansion) ->
            {:halt, :skip}

          # Overlap with the rest of the function name. The
          # expansion's subtokens already appear elsewhere in
          # the original name (`ip` → `item_picker_component`
          # in `ip_item_component` would duplicate
          # `item`/`component`). That's a duplicate, not an
          # expansion.
          expansion_overlaps_other_parts?(expansion, other_parts, part) ->
            {:halt, :skip}

          # Prefix-truncation auto-complete (#15). The heuristic
          # latched a short that is a *contiguous prefix* of a
          # single-word expansion (`str` → `stream` off the module
          # name `Stream`). That's not decoding an abbreviation
          # (`cs → changeset`, `kw → keyword` drop internal letters)
          # — it just lengthens a word the author already started
          # typing. Treating it as an expansion fights the author:
          # the rename re-fires on every run, and once a human
          # renames `stream_token` back to the deliberate
          # `str_token`, the loop repeats. A short that the author
          # wrote as a leading truncation is part of a full,
          # deliberate name — keep it verbatim. Explicit `known`
          # mappings stay authoritative; this gate only tempers the
          # heuristic guess.
          heuristic_prefix_truncation?(part, expansion, resolve_opts) ->
            {:cont, [part | acc]}

          true ->
            {:cont, [expansion | acc]}
        end

      :skip ->
        resolve_skipped_part(part, resolve_opts, acc)
    end
  end

  # If the part itself is whitelisted or stop-word, IdentifierExpansion
  # returns :skip — but for those we want to keep the part verbatim,
  # not abandon the whole name. Disambiguate.
  defp resolve_skipped_part(part, resolve_opts, acc) do
    part_atom = String.to_atom(part)

    cond do
      MapSet.member?(resolve_opts.whitelist, part_atom) -> {:cont, [part | acc]}
      MapSet.member?(resolve_opts.stop_words, part_atom) -> {:cont, [part | acc]}
      true -> {:halt, :skip}
    end
  end

  # `row` ↔ `rows`, `id` ↔ `ids`: the expansion adds no information,
  # it just toggles cardinality. The author already picked one form
  # deliberately; respect that.
  defp trivial_inflection?(short, expansion) do
    short_str = to_string(short)
    expansion_str = to_string(expansion)

    expansion_str == pluralize_word(short_str) or
      expansion_str == singularize(short_str)
  end

  # True if any subtoken of `expansion` already appears elsewhere in
  # the function name (i.e. in `other_parts \ {short}`). When this
  # fires, splicing the expansion in would produce a name like
  # `item_picker_component_item_component` — duplicates rather than
  # disambiguation.
  defp expansion_overlaps_other_parts?(expansion, other_parts, short) do
    siblings = MapSet.delete(other_parts, short)

    expansion
    |> String.split("_", trim: true)
    |> Enum.any?(&MapSet.member?(siblings, &1))
  end

  # True when the heuristic merely auto-completed a leading truncation:
  # `short` is a contiguous prefix of a single-word `expansion`
  # (`str` of `stream`). Genuine abbreviations (`cs`, `kw`, `bi`) are
  # NOT prefixes — they drop internal letters or span words — so they
  # pass through and still expand. An explicit project `known` mapping
  # for `short` overrides this: the user asked for it, so we never
  # second-guess it.
  defp heuristic_prefix_truncation?(short, expansion, resolve_opts) do
    not Map.has_key?(resolve_opts.known, short) and
      not String.contains?(expansion, "_") and
      short != expansion and
      String.starts_with?(expansion, short)
  end

  # Walk the entire module body, patching every reference to a
  # renamed name: definition heads (def/defp/...) and call sites
  # (`name(...)` and `&name/arity`).
  defp build_rename_patches(body, resolutions),
    do:
      body
      |> Macro.prewalker()
      |> Enum.flat_map(
        &patches_for_node(
          &1,
          resolutions
        )
      )
      |> Enum.reject(&is_nil/1)

  # Capture `&name/arity`. AST shape:
  #   {:&, _, [{:/, _, [{name, meta, ctx}, {:__block__, _, [_arity]}]}]}
  # The inner `{name, meta, ctx}` is a bare-atom reference, not a
  # call — `ctx` is `nil` or a context atom, never a list — so the
  # general call-site clause below (which guards on `is_list(args)`)
  # never fires for it. Matching the whole `&/2` shape here patches
  # the name token while preserving the surrounding `&…/arity`
  # syntax untouched.
  defp patches_for_node({:&, _, [{:/, _, [{name, meta, ctx}, _arity]}]}, resolutions)
       when is_atom(name) and is_atom(ctx) do
    Map.fetch(resolutions, name) |> name_patch_or_skip(meta, name)
  end

  defp patches_for_node({name, meta, args}, resolutions)
       when is_atom(name) and is_list(args) do
    Map.fetch(resolutions, name) |> name_patch_or_skip(meta, name)
  end

  defp patches_for_node(_, _), do: []

  # Patch ~H sigil bodies textually for every renamed function:
  # `<.old`, `</.old`, `old(`, `&old/`. Word-boundary on the function
  # call form so `my_old(` doesn't match.
  defp heex_patches(body, resolutions) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:sigil_H, meta, [{:<<>>, _, [content]}, _]} = node when is_binary(content) ->
        new_content = patch_heex_content(content, resolutions)
        heex_patch_for_sigil(node, meta, content, new_content)

      _ ->
        []
    end)
  end

  defp heex_patch_for_sigil(_node, _meta, content, new_content) when new_content == content,
    do: []

  defp heex_patch_for_sigil(node, meta, _content, new_content) do
    delim = Keyword.get(meta, :delimiter, "\"")
    prefix = if delim in ["\"\"\"", "'''"], do: "\n", else: ""
    new_text = "~H#{delim}#{prefix}#{new_content}#{delim}"
    [Patch.new(Sourceror.get_range(node), new_text)]
  end

  defp patch_heex_content(content, resolutions) do
    resolutions
    |> Enum.reduce(content, fn {old, new}, acc ->
      old_re = old |> Atom.to_string() |> Regex.escape()
      new_str = Atom.to_string(new)

      acc
      |> String.replace(~r/<\.#{old_re}\b/, "<.#{new_str}")
      |> String.replace(~r/<\/\.#{old_re}\b/, "</.#{new_str}")
      |> String.replace(~r/(?<![a-zA-Z0-9_])#{old_re}\(/, "#{new_str}(")
      |> String.replace(~r/&#{old_re}\//, "&#{new_str}/")
    end)
  end

  # Build a Sourceror patch that replaces just the function name token,
  # leaving the argument list, parens, and surrounding whitespace
  # untouched. The call/def's `meta` carries [:line, :column] of the
  # name itself; the replacement spans `byte_size(old_name_string)`.
  defp name_patch(meta, old_name, new_name) do
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)

    if is_integer(line) and is_integer(column) do
      old_string = Atom.to_string(old_name)

      range = %{
        end: [line: line, column: column + String.length(old_string)],
        start: [line: line, column: column]
      }

      [Patch.new(range, Atom.to_string(new_name))]
    else
      []
    end
  end

  defp apply_patches({:ok, ast}, ctx, source),
    do: build_patches(ast, ctx) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, _ctx, source), do: source

  defp name_patch_or_skip({:ok, new_atom}, meta, name), do: meta |> name_patch(name, new_atom)

  defp name_patch_or_skip(:error, _meta, _name), do: []

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
