defmodule Number42.Refactors.Heex.Scope do
  @moduledoc """
  Variable-scope analysis over a `Number42.Refactors.Heex.Tree` subtree.

  The question a HEEx component-extraction refactor must answer before
  lifting a subtree into its own function-component: **does this subtree
  reference any variable bound *outside* it that is not an `@assign`?**
  Such a free variable would compile in place but break once the subtree
  becomes a standalone `def name(assigns)` whose only inputs are assigns.

  `@assign` references are always fine — they become the component's
  `attr`s. The dangerous references are bare variables introduced by the
  surrounding template: a `<%= for item <- @items do %>` generator, a
  `<.form :let={f}>` slot binding, a `<% total = ... %>` local, or a
  `case`/`with` clause pattern. A binder *inside* the subtree is fine
  (binder and use travel together); a binder *above* the cut is not.

  The walk is hierarchical: descending into a binding construct adds its
  bound names to the scope visible to that construct's children. A body
  reference is free iff it is neither an `@assign` nor in the accumulated
  scope at that point.
  """

  alias Number42.Refactors.Heex.Tree

  @doc """
  The set of free non-assign variable names referenced anywhere in `node`,
  given an initial `scope` of names already bound by enclosing context
  (empty by default — i.e. treat `node` as the cut root).
  """
  @spec free_nonassign_vars(Tree.node_t(), MapSet.t()) :: MapSet.t()
  def free_nonassign_vars(node, scope \\ MapSet.new()) do
    walk(node, scope, MapSet.new())
  end

  # walk/3 threads the binding `scope` down and accumulates free vars in `free`.
  defp walk({:text, _, _}, _scope, free), do: free

  defp walk({:eex_expr, code, _}, scope, free) do
    add_free(code, scope, free)
  end

  defp walk({:eex_block, header, children, _}, scope, free) do
    # The block header binds vars (`for x <-`, clause patterns) visible to the
    # children, and may itself reference free vars (the generator source).
    free = add_free_header(header, scope, free)
    child_scope = MapSet.union(scope, header_binds(header))
    Enum.reduce(children, free, fn child, acc -> walk(child, child_scope, acc) end)
  end

  defp walk({:element, _tag, attrs, children, _}, scope, free) do
    # Attribute expressions are evaluated in the *current* scope (a `:let`
    # binds only the element's children, not its own other attrs).
    free = Enum.reduce(attrs, free, &attr_free(&1, scope, &2))
    child_scope = MapSet.union(scope, element_binds(attrs))
    Enum.reduce(children, free, fn child, acc -> walk(child, child_scope, acc) end)
  end

  # ---- attribute handling --------------------------------------------------

  # `:let={pat}` binds for children — its expr is a pattern, not a reference.
  defp attr_free({":let", {:expr, _code}}, _scope, free), do: free
  # `:for={x <- @xs}` is an inline comprehension: its LHS names are binders, not
  # references; only the generator source (`@xs` -> none) is a free candidate.
  defp attr_free({":for", {:expr, code}}, scope, free) do
    refs = MapSet.difference(refs_of(code), binds_of(code))
    add_names(refs, scope, free)
  end

  defp attr_free({_name, {:expr, code}}, scope, free), do: add_free(code, scope, free)
  defp attr_free({_name, {:string, _}}, _scope, free), do: free

  defp element_binds(attrs) do
    Enum.reduce(attrs, MapSet.new(), fn
      {":let", {:expr, code}}, acc -> MapSet.union(acc, pattern_vars(code))
      {":for", {:expr, code}}, acc -> MapSet.union(acc, binds_of(code))
      _, acc -> acc
    end)
  end

  # ---- eex block header ----------------------------------------------------

  # Strip the trailing `do`/`->` so the header parses, then split a `for`
  # comprehension into its generator/filter parts. Names on the bound side
  # of `<-` (and plain patterns) are binds; the generator sources are refs.
  defp header_binds(header) do
    header
    |> normalize_header()
    |> binds_of()
  end

  defp add_free_header(header, scope, free) do
    norm = normalize_header(header)
    # the generator/clause LHS names (`item` in `item <- @items`) are binders,
    # not references; only the remaining names (the sources, `@items`->none) count.
    refs = MapSet.difference(refs_of(norm), binds_of(norm))

    Enum.reduce(refs, free, fn name, acc ->
      if MapSet.member?(scope, name), do: acc, else: MapSet.put(acc, name)
    end)
  end

  defp normalize_header(header) do
    header
    |> String.trim()
    |> strip_keyword_prefix()
    |> String.replace_trailing("do", "")
    |> String.replace_trailing("->", "")
    |> String.trim()
  end

  # `for x <- xs`, `if cond`, `case expr`, `cond`, `with x <- y` — drop the
  # leading keyword so the remainder is an expression/generator list.
  defp strip_keyword_prefix(s) do
    Regex.replace(~r/^(for|if|unless|case|cond|with)\b\s*/, s, "")
  end

  # ---- free / bound var extraction via the parser --------------------------

  # add free vars from an arbitrary expression `code` in `scope`
  defp add_free(code, scope, free), do: add_names(refs_of(code), scope, free)

  # add the names in `refs` that are not bound in `scope`
  defp add_names(refs, scope, free) do
    Enum.reduce(refs, free, fn name, acc ->
      if MapSet.member?(scope, name), do: acc, else: MapSet.put(acc, name)
    end)
  end

  # variable references in an expression (not @assigns, not call targets)
  defp refs_of(code) when is_binary(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> referenced_vars(ast)
      _ -> MapSet.new()
    end
  end

  # names bound by a comprehension/expression: the LHS of every `<-` and `=`,
  # plus `fn args ->`. Generator sources (RHS) are NOT binds.
  defp binds_of(code) when is_binary(code) do
    case Code.string_to_quoted("[" <> code <> "]") do
      {:ok, ast} ->
        generator_binds(ast)

      _ ->
        case Code.string_to_quoted(code) do
          {:ok, ast} -> generator_binds(ast)
          _ -> MapSet.new()
        end
    end
  end

  defp referenced_vars(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:@, _, _} = node, acc ->
          {drop_subtree(node), acc}

        # `assigns.field` is an assign read (it becomes the component's `:field`
        # attr), not a free var; neutralise the `assigns` object but keep walking
        # any call args (`assigns.fun(item)` still surfaces a free `item`). A
        # *bare* `assigns` falls through to the var clause below and IS surfaced,
        # so a cut threading the whole map is caught by the free-var gate (#294).
        {{:., dot_meta, [{:assigns, _, ctx}, field]}, call_meta, args}, acc
        when is_atom(ctx) and is_atom(field) ->
          {{{:., dot_meta, [:__assigns_field__, field]}, call_meta, args}, acc}

        # `x :: binary` — the RHS is a bitstring/type specifier, not a variable.
        {:"::", _, [value, _type]}, acc ->
          {value, acc}

        {name, _meta, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, MapSet.put(acc, Atom.to_string(name))}

        node, acc ->
          {node, acc}
      end)

    MapSet.difference(acc, reserved())
  end

  # we must not descend into `@x` (its inner `{:x, _, nil}` is not a free var)
  defp drop_subtree(_), do: :__assign__

  defp generator_binds(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:<-, _, [lhs, _rhs]} = n, acc -> {n, MapSet.union(acc, pattern_vars_ast(lhs))}
        {:=, _, [lhs, _rhs]} = n, acc -> {n, MapSet.union(acc, pattern_vars_ast(lhs))}
        {:fn, _, clauses} = n, acc -> {n, MapSet.union(acc, fn_arg_vars(clauses))}
        n, acc -> {n, acc}
      end)

    acc
  end

  defp pattern_vars(code) when is_binary(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> pattern_vars_ast(ast)
      _ -> MapSet.new()
    end
  end

  # every variable name in a pattern AST is a binder (but `x :: binary` binds
  # only `x`; the type specifier on the RHS is not a variable)
  defp pattern_vars_ast(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:"::", _, [value, _type]}, acc ->
          {value, acc}

        {name, _meta, ctx} = n, acc when is_atom(name) and is_atom(ctx) ->
          {n, MapSet.put(acc, Atom.to_string(name))}

        n, acc ->
          {n, acc}
      end)

    MapSet.difference(acc, reserved())
  end

  defp fn_arg_vars(clauses) do
    Enum.reduce(clauses, MapSet.new(), fn
      {:->, _, [args, _body]}, acc ->
        Enum.reduce(args, acc, fn arg, a -> MapSet.union(a, pattern_vars_ast(arg)) end)

      _, acc ->
        acc
    end)
  end

  # `assigns` is intentionally NOT reserved: a bare `assigns` reference is a real
  # free var (the cut threads the whole map and cannot become a clean attr-only
  # seam), while `assigns.field` is handled as an assign read in `referenced_vars`
  # before it reaches the var clause (#294 Bug A).
  defp reserved, do: MapSet.new(~w(nil true false __MODULE__ _))
end
