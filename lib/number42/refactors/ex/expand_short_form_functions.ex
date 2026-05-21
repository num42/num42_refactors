defmodule Number42.Refactors.Ex.ExpandShortFormFunctions do
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
    function (any kind, any arity) in the same module.
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
    module_compounds = module_name_compounds(name_ast)
    alias_compounds = collect_alias_compounds(body_exprs)
    import_compounds = collect_import_compounds(body_exprs)

    context_compounds =
      (module_compounds ++ alias_compounds ++ import_compounds)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == ""))

    {private_groups, occupied_names} = collect_private_def_groups(body_exprs)

    resolutions =
      private_groups
      |> Enum.flat_map(fn {{name, _arity}, _nodes} ->
        case resolve_name(name, context_compounds, ctx) do
          {:ok, new_name_atom} ->
            cond do
              new_name_atom == name -> []
              MapSet.member?(occupied_names, new_name_atom) -> []
              true -> [{name, new_name_atom}]
            end

          :skip ->
            []
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
        [parts |> List.last() |> Atom.to_string() |> Macro.underscore()]

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
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

        _, acc ->
          acc
      end)

    grouped = priv_pairs |> Enum.group_by(fn {key, _} -> key end, fn {_, node} -> node end)
    {grouped, all_names}
  end

  # Try to expand each short non-whitelisted subtoken of the function
  # name. Returns {:ok, new_atom} when EVERY short subtoken resolves
  # AND at least one expansion actually changes the name; otherwise :skip.
  defp resolve_name(name, context_compounds, ctx) do
    parts = name |> Atom.to_string() |> String.split("_")

    expanded =
      parts
      |> Enum.reduce_while([], fn part, acc ->
        cond do
          # Long enough or whitelisted: keep as-is.
          String.length(part) > 3 ->
            {:cont, [part | acc]}

          MapSet.member?(ctx.whitelist, String.to_atom(part)) ->
            {:cont, [part | acc]}

          # Hard-coded stop list of English function words. Refusing
          # before the `known` check is intentional — a misconfigured
          # `known: %{"key" => ...}` must not be able to silently
          # rewrite identifiers where the token is meaningful.
          MapSet.member?(@stop_words, String.to_atom(part)) ->
            {:cont, [part | acc]}

          # Project mapping wins.
          Map.has_key?(ctx.known, part) ->
            {:cont, [Map.fetch!(ctx.known, part) | acc]}

          # Heuristic: try to compound-resolve against context.
          true ->
            case resolve_subtoken(part, context_compounds) do
              {:ok, expansion} -> {:cont, [expansion | acc]}
              :skip -> {:halt, :skip}
            end
        end
      end)

    case expanded do
      :skip ->
        :skip

      reversed_parts ->
        new_name_string = reversed_parts |> Enum.reverse() |> Enum.join("_")

        if new_name_string == Atom.to_string(name) do
          :skip
        else
          {:ok, String.to_atom(new_name_string)}
        end
    end
  end

  # Single-char subtokens have no signal strong enough to disambiguate.
  defp resolve_subtoken(short, _) when byte_size(short) < 2, do: :skip

  defp resolve_subtoken(short, context_compounds) do
    candidates =
      context_compounds
      |> Enum.reject(&(&1 == short))
      |> Enum.flat_map(fn compound ->
        case match_subtoken(short, compound) do
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

  defp match_subtoken(short, compound) do
    subtokens = String.split(compound, "_", trim: true)

    latch_match(short, subtokens) |> scored_target_or_skip(short, subtokens)
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

  defp scored_target_or_skip({:ok, start_idx, starts_hit}, short, subtokens) do
    n = length(subtokens) - start_idx
    {_head, tail} = subtokens |> Enum.split(-n)
    target = tail |> Enum.join("_")

    # Reentrance guard: if the target contains the short as one of
    # its subtokens (typically as the first one), running the
    # refactor again would expand it again — `db` → `db_web` →
    # `db_web_web` → ... Skip these matches; they're the gier
    # cases where the heuristic latched on the leading subtoken
    # without absorbing it.
    if short in String.split(target, "_") do
      :error
    else
      score = if starts_hit == String.length(short), do: 100, else: 80
      {:ok, target, score}
    end
  end

  defp scored_target_or_skip(:error, _short, _subtokens), do: :error

  defp name_patch_or_skip({:ok, new_atom}, meta, name), do: meta |> name_patch(name, new_atom)

  defp name_patch_or_skip(:error, _meta, _name), do: []

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
