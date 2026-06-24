defmodule Number42.Refactors.Ex.UnusedVariable do
  @moduledoc """
  Prefixes unused variable bindings with `_`.

  Mirrors the compiler warning *"variable X is unused"*. Two construct
  kinds are handled:

  - **Function clauses** (`def`, `defp`): bindings introduced in the
    argument patterns; uses scanned in guard and body.
  - **Branch clauses** (`{:->, _, [patterns, body]}`): everything that
    parses as a `->` clause — `case`, `cond`, `fn`, `with` `else`,
    `try` `rescue`/`catch`. Bindings come from the patterns (LHS),
    uses from the guard (if `when`) and the body (RHS).

  In both cases, a binding is rewritten by replacing its AST node
  with `_<name>` — only the binding site changes, references stay
  untouched.

  ## Scope

  Out of scope on purpose:

  - Bindings introduced inside a body via free `=`-matches
    (`{:ok, x} = call()`).
  - `with` `<-`-clauses in the header (their pattern lives in a
    `{:<-, _, [pat, expr]}` node, which we don't walk).
  - Comprehension generators.
  - Macro-introduced variables that don't appear literally in the
    parsed AST.

  The compiler already warns for all of those, and supporting them
  needs construct-specific binding-vs-use analysis we don't have.

  ## What counts as a use

  - Any `{name, meta, ctx}` variable reference in the guard or body.
  - The pin operator (`^var`) — pinned variables are reads, not new
    bindings.

  ## What we leave alone

  - Names that already start with `_`.
  - The `_` wildcard itself.
  - Names that appear anywhere in the body or guard.
  - Names in the configurable whitelist (`:whitelist` opt, default
    `[:assigns]`). Phoenix components reference `assigns` implicitly
    via `@field` expansion inside `~H` sigils — that use is invisible
    to the AST walk, so renaming would break the component.

  ## Configuring the whitelist

  Add an entry under `configured_modules` in `.refactor.exs`:

      configured_modules: [
        {Number42.Refactors.Ex.UnusedVariable,
         whitelist: [:assigns, :socket]}
      ]

  The list overrides the default — include `:assigns` if you want it
  preserved.

  ## Idempotence

  After the rewrite the binding is `_name`, which never matches the
  candidate filter (`String.starts_with?(name, "_")`). A second pass
  finds nothing to rewrite.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Prefix unused bindings in def/case/with/fn/cond clauses with `_`"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    The compiler warns about an unused binding for a reason: either the
    variable is genuinely unused (rename to `_name`) or there's a bug
    where the value was meant to be used but isn't. Underscore-
    prefixing the unused ones silences the noise so the warnings that
    remain are signal rather than background. Names like `_user` (over
    bare `_`) keep the documentation value: a future reader sees the
    function still receives a user, just doesn't consult it.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: false

  # Default whitelist: names we never rename even if they look unused.
  # `assigns` is the canonical Phoenix component arg — `~H` sigils
  # reference it implicitly via `@field` expansion, which our AST walk
  # can't see. Override via `:whitelist` in `.refactor.exs`:
  #
  #     configured_modules: [
  #       {Number42.Refactors.Ex.UnusedVariable,
  #        whitelist: [:assigns, :socket]}
  #     ]
  @default_whitelist [:assigns]

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    whitelist = opts |> Keyword.get(:whitelist, @default_whitelist) |> MapSet.new()

    Sourceror.parse_string(source) |> apply_patches(source, whitelist)
  end

  @impl Number42.Refactors.Refactor
  def patches(ast, _source, opts) do
    whitelist = opts |> Keyword.get(:whitelist, @default_whitelist) |> MapSet.new()
    build_patches(ast, whitelist)
  end

  defp all_clauses(args), do: List.last(args) |> all_clauses_last()

  defp all_clauses_last(kw) when is_list(kw) do
    kw
    |> fetch_keyword(:do)
    |> List.wrap()
  end

  defp all_clauses_last(_), do: []

  defp apply_patches({:ok, ast}, source, whitelist),
    do: build_patches(ast, whitelist) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source, _whitelist), do: source
  defp bindings_in({:^, _, [_pinned]}), do: []
  defp bindings_in({:@, _, _}), do: []
  defp bindings_in({:"::", _, [lhs, _type_spec]}), do: lhs |> bindings_in()

  defp bindings_in({name, _meta, ctx} = node)
       when is_atom(name) and is_atom(ctx) do
    name_str = Atom.to_string(name)

    cond do
      name == :_ -> []
      String.starts_with?(name_str, "_") -> []
      reserved?(name) -> []
      true -> [{name, node}]
    end
  end

  defp bindings_in({_form, _meta, args}) when is_list(args) do
    args |> Enum.flat_map(&bindings_in/1)
  end

  defp bindings_in({left, right}), do: bindings_in(left) ++ bindings_in(right)

  defp bindings_in(list) when is_list(list) do
    list |> Enum.flat_map(&bindings_in/1)
  end

  defp bindings_in(_), do: []

  defp branch_patches({:->, _, [lhs, body]}, whitelist) when is_list(lhs) do
    {patterns, guard} = split_branch_lhs(lhs)
    patches_for(patterns, guard, body, whitelist)
  end

  defp branch_patches(_, _), do: []
  defp build_patches(ast, whitelist), do: ast |> walk_for_patches(whitelist)
  defp call_args({_name, _meta, args}) when is_list(args), do: args
  defp call_args(_), do: []
  defp children_of({_form, _meta, args}) when is_list(args), do: args
  defp children_of(_), do: []
  defp collect_bindings(args), do: args |> Enum.flat_map(&bindings_in/1)

  defp collect_def_body(body_kw) do
    blocks =
      [:do, :rescue, :catch, :after, :else]
      |> Enum.map(&fetch_keyword(body_kw, &1))
      |> Enum.reject(&is_nil/1)

    case blocks do
      [] -> nil
      [single] -> single
      many -> {:__block__, [], many}
    end
  end

  defp collect_uses(nil), do: MapSet.new()

  defp collect_uses(expr) do
    expr
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {name, _meta, ctx} when is_atom(name) and is_atom(ctx) ->
        [name]

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp fetch_keyword(kw, key) when is_list(kw) and is_atom(key) do
    kw
    |> Enum.find_value(fn
      {{:__block__, _, [^key]}, value} -> value
      {^key, value} -> value
      _ -> nil
    end)
  end

  defp fetch_keyword(_, _), do: nil

  defp node_patches({def_kind, _, [head, body_kw]}, whitelist)
       when def_kind?(def_kind) and is_list(body_kw) do
    {args, guard} = split_head(head)
    body = collect_def_body(body_kw)
    patches_for(args, guard, body, whitelist)
  end

  defp node_patches({op, _, args}, whitelist)
       when op in [:case, :fn, :receive] and is_list(args) do
    args
    |> all_clauses()
    |> Enum.flat_map(&branch_patches(&1, whitelist))
  end

  defp node_patches({:try, _, [body_kw]}, whitelist) when is_list(body_kw) do
    [:rescue, :catch, :else]
    |> Enum.flat_map(fn key ->
      case fetch_keyword(body_kw, key) do
        nil -> []
        clauses -> clauses |> List.wrap() |> Enum.flat_map(&branch_patches(&1, whitelist))
      end
    end)
  end

  defp node_patches({:with, _, args}, whitelist) when is_list(args) do
    List.last(args) |> node_patches_last(whitelist)
  end

  defp node_patches(_, _), do: []

  defp node_patches_last(kw, whitelist) when is_list(kw) do
    fetch_keyword(kw, :else) |> patches_for_clauses_or_skip(whitelist)
  end

  defp node_patches_last(_, _whitelist), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  defp patches_for(patterns, guard, body, whitelist) do
    collected_binding = collect_bindings(patterns)

    # Names that occur more than once in the patterns enforce equality
    # between the two positions ("pin via repeated name") — that is a
    # use, even if the body never references the name. Renaming both
    # to `_name` is wrong (and the compiler rejects repeated `_name`
    # bindings outright).
    repeated =
      collected_binding
      |> Enum.frequencies_by(fn {name, _} -> name end)
      |> Enum.filter(fn {_, count} -> count > 1 end)
      |> Enum.map(fn {name, _} -> name end)
      |> MapSet.new()

    used =
      guard
      |> collect_uses()
      |> MapSet.union(collect_uses(body))
      |> MapSet.union(repeated)

    collected_binding
    |> Enum.reject(fn {name, _node} ->
      MapSet.member?(used, name) or MapSet.member?(whitelist, name)
    end)
    |> Enum.map(fn {_name, node} -> rename_patch(node) end)
  end

  defp patches_for_clauses_or_skip(nil, _whitelist), do: []

  defp patches_for_clauses_or_skip(clauses, whitelist),
    do: clauses |> List.wrap() |> Enum.flat_map(&branch_patches(&1, whitelist))

  defp rename_patch({name, _meta, _ctx} = node),
    do: node |> Patch.replace("_" <> Atom.to_string(name))

  defp reserved?(name), do: name in [nil, true, false]

  defp split_branch_lhs([{:when, _, when_args}]) do
    {guard, pattern_list} = List.pop_at(when_args, -1)
    {pattern_list, guard}
  end

  defp split_branch_lhs(patterns), do: {patterns, nil}
  defp split_head({:when, _, [call, guard]}), do: {call_args(call), guard}
  defp split_head(call), do: {call_args(call), nil}
  defp walk_for_patches({:quote, _, _}, _whitelist), do: []

  defp walk_for_patches({_, _, _} = node, whitelist) do
    own = node_patches(node, whitelist)
    children = node |> children_of() |> Enum.flat_map(&walk_for_patches(&1, whitelist))
    own ++ children
  end

  defp walk_for_patches(list, whitelist) when is_list(list) do
    list |> Enum.flat_map(&walk_for_patches(&1, whitelist))
  end

  defp walk_for_patches({left, right}, whitelist),
    do: walk_for_patches(left, whitelist) ++ walk_for_patches(right, whitelist)

  defp walk_for_patches(_, _), do: []
end
