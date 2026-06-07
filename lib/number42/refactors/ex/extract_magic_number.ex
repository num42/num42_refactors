defmodule Number42.Refactors.Ex.ExtractMagicNumber do
  @moduledoc """
  Hoists repeated numeric literals into a `@module_attribute`.

      defmodule M do
        def a, do: connect(timeout: 5000)
        def b, do: reconnect(timeout: 5000)
      end
      ↓
      defmodule M do
        @timeout 5000
        def a, do: connect(timeout: @timeout)
        def b, do: reconnect(timeout: @timeout)
      end

  A literal that appears `min_occurrences` times (default `2`) in a
  module is a magic number: its meaning lives only in the reader's
  head. Lifting it into a named attribute gives the value one
  authoritative definition and a name that documents intent.

  ## Naming

  Via `IdentifierExpansion.derive_constant_name/2`, first hit wins:

  - The keyword key, when the literal sits at `key: value` (`@timeout`).
  - The surrounding call name (`String.slice(x, 0, 200)` → `@max_slice`).
  - Well-known values — integers (`3600 → @seconds_per_hour`,
    `1024 → @kibi`) and floats (`@pi`).
  - A millisecond multiple (`5000 → @timeout_5s_ms`).
  - Value-in-name as a last resort (`@int_42`) — never the bare
    `@magic_number`, so distinct values never collide on one name.

  ## Configuring `min_occurrences`

      configured_modules: [
        {Number42.Refactors.Ex.ExtractMagicNumber, min_occurrences: 3}
      ]

  ## Skip conditions

  - **Idiomatic numbers** — `0 1 2 0.0 1.0 0.5` are never hoisted;
    they read clearly inline.
  - **Below threshold** — a value occurring fewer than
    `min_occurrences` times stays inline.
  - **Already an attribute value** — a literal that *is* the value of
    an `@attr` definition is already named; it is excluded both as a
    candidate and from the occurrence count.
  - **Pattern literals** — a literal in a match position (`def f(404)`,
    `x = 404`) can't become a `@attr`; excluded and uncounted.
  - **Capture arities** — the `3` in `&fun/3` is an arity, not data;
    `&fun/@attr` is invalid, so it is excluded and uncounted.
  - **Quote bodies** — a literal inside `quote do … end` would hoist
    into a `@attr` that resolves in the *calling* module at expansion
    time, where it does not exist; quote subtrees are pruned.

  ## Idempotence

  After the rewrite each occurrence is `@name`, no longer a bare
  literal, so the second pass counts zero occurrences and stops.

  ## Default-OFF (opt-in only)

  Disabled by default — `transform/2` is a no-op unless its own opts
  carry `enabled: true`. The derived attribute names are frequently
  meaningless (`@int_42`, `@timeout_5s_ms`) and the same literal can
  carry different meanings within one module, so hoisting trades a clear
  inline value for an opaquely-named indirection. Enable per project
  once name derivation is trustworthy for that codebase:

      configured_modules: [
        {Number42.Refactors.Ex.ExtractMagicNumber, enabled: true}
      ]
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.IdentifierExpansion
  alias Sourceror.Patch

  @idiomatic [0, 1, 2, 0.0, 1.0, 0.5]
  @default_min_occurrences 2

  @impl Number42.Refactors.Refactor
  def description, do: "Hoist repeated numeric literals into a named `@module_attribute`"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A bare `5000` repeated across a module forces every reader to infer
    what it means and trust that all copies stay in sync. Naming it
    `@timeout` once gives the value a single source of truth and turns
    each use site self-documenting. Idiomatic small numbers (0, 1, 2
    and their float forms) are exempt — they read clearly as-is.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      min = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
      Sourceror.parse_string(source) |> apply_patches(source, min)
    else
      source
    end
  end

  defp apply_patches({:ok, ast}, source, min),
    do: ast |> build_patches(min) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source, _min), do: source

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp build_patches(ast, min) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [_name, [{_do, body}]]} -> module_patches(body, min)
      _ -> []
    end)
  end

  defp module_patches(body, min) do
    exprs =
      body |> body_to_exprs() |> Enum.map(&prune_nested_modules/1) |> Enum.map(&prune_quotes/1)

    excluded =
      [attribute_value_nodes(exprs), pattern_literal_nodes(exprs), capture_arity_nodes(exprs)]
      |> Enum.reduce(&MapSet.union/2)

    occurrences = collect_occurrences(exprs, excluded)

    occurrences
    |> Enum.filter(fn {_value, hits} -> length(hits) >= min end)
    |> assign_names()
    |> emit_patches(exprs)
  end

  # Replace nested `defmodule` subtrees with an inert marker so a
  # module's literal walk never reaches into a sibling/inner module —
  # each module is processed when the prewalk visits its own node.
  defp prune_nested_modules(expr) do
    Macro.prewalk(expr, fn
      {:defmodule, _, _} -> {:__pruned__, [], nil}
      node -> node
    end)
  end

  # Replace `quote do … end` subtrees with an inert marker. A `@attr`
  # hoisted out of a quote-body resolves at expansion time in the
  # *calling* module, where the attribute does not exist — so literals
  # inside a quote are off-limits, like nested modules.
  defp prune_quotes(expr) do
    Macro.prewalk(expr, fn
      {:quote, _, _} -> {:__pruned__, [], nil}
      node -> node
    end)
  end

  # Literal nodes sitting in a *pattern* position. A module attribute is
  # an expression and is illegal in a match pattern — replacing
  # `def f(404)` with `def f(@magic_number)` would not compile. So
  # pattern literals are neither candidates nor counted: function-head
  # args, `->`-clause patterns, and the LHS of `=`/`<-`.
  defp pattern_literal_nodes(exprs) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(&pattern_subtrees/1)
    |> Enum.flat_map(&numeric_literal_nodes/1)
    |> MapSet.new()
  end

  defp pattern_subtrees({kind, _, [head | _]}) when kind in [:def, :defp, :defmacro, :defmacrop],
    do: head |> strip_when() |> head_args()

  defp pattern_subtrees({:->, _, [lhs, _body]}), do: lhs |> List.wrap() |> Enum.map(&strip_when/1)
  defp pattern_subtrees({:=, _, [lhs, _rhs]}), do: [lhs]
  defp pattern_subtrees({:<-, _, [lhs, _rhs]}), do: [lhs]
  defp pattern_subtrees(_), do: []

  defp strip_when({:when, _, [pat | _]}), do: pat
  defp strip_when(other), do: other

  defp head_args({name, _, args}) when is_atom(name) and is_list(args), do: args
  defp head_args(_), do: []

  # Literal nodes in the *arity* position of a `&fun/N` capture. The `N`
  # is an arity, not data — `&fun/@magic_number` is an invalid capture.
  # So arity literals are neither candidates nor counted.
  defp capture_arity_nodes(exprs) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {:&, _, [{:/, _, [{fun, _, _}, {:__block__, _, [arity]} = node]}]}
      when is_atom(fun) and is_integer(arity) ->
        [node]

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp numeric_literal_nodes(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:__block__, _, [value]} = node when is_number(value) -> [node]
      _ -> []
    end)
  end

  # Literal nodes that ARE the value of an `@attr value` definition.
  # They are already named constants — neither candidates nor counted.
  defp attribute_value_nodes(exprs) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {:@, _, [{name, _, [value_node]}]} when is_atom(name) -> [value_node]
      _ -> []
    end)
    |> MapSet.new()
  end

  # %{value => [%{node, value, key, context}]} — every hoistable
  # numeric-literal node, grouped by value, in source order, tagged with
  # the keyword key it sat under (or nil) and the name of the call that
  # took it as an argument (or nil).
  defp collect_occurrences(exprs, excluded) do
    keys = keyword_value_keys(exprs)
    contexts = call_contexts(exprs)

    exprs
    |> Enum.flat_map(&literal_hits(&1, excluded, keys, contexts))
    |> Enum.group_by(fn %{value: value} -> value end)
  end

  defp literal_hits(expr, excluded, keys, contexts) do
    {_, hits} =
      Macro.prewalk(expr, [], fn node, acc ->
        {node, prepend_hit(node, acc, excluded, keys, contexts)}
      end)

    Enum.reverse(hits)
  end

  defp prepend_hit({:__block__, _, [value]} = node, acc, excluded, keys, contexts)
       when is_number(value) do
    cond do
      value in @idiomatic ->
        acc

      MapSet.member?(excluded, node) ->
        acc

      true ->
        hit = %{
          node: node,
          value: value,
          key: Map.get(keys, node),
          context: Map.get(contexts, node)
        }

        [hit | acc]
    end
  end

  defp prepend_hit(_node, acc, _excluded, _keys, _contexts), do: acc

  # Map a literal value-node to the name of the call that took it as a
  # positional argument (`String.slice(x, 0, 200)` → `200 ↦ "slice"`).
  # Names the constant by its bound when no keyword key applies.
  defp call_contexts(exprs) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(&call_arg_contexts/1)
    |> Map.new()
  end

  defp call_arg_contexts({{:., _, [_mod, fun]}, _, args}) when is_atom(fun) and is_list(args),
    do: tag_literal_args(fun, args)

  defp call_arg_contexts({fun, _, args}) when is_atom(fun) and is_list(args),
    do: tag_literal_args(fun, args)

  defp call_arg_contexts(_), do: []

  defp tag_literal_args(fun, args) do
    args
    |> Enum.filter(&match?({:__block__, _, [value]} when is_number(value), &1))
    |> Enum.map(&{&1, Atom.to_string(fun)})
  end

  # Map a literal value-node to the keyword key it sat under, for
  # genuine keyword *arguments* only. Block keywords (`do:`/`else:`/…)
  # are structural, not data, so they are excluded — their key would
  # name the attribute `do`.
  @block_keywords ~w(do else after catch rescue)a
  defp keyword_value_keys(exprs) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {{:__block__, _, [key]}, {:__block__, _, [value]} = value_node}
      when is_atom(key) and is_number(value) and key not in @block_keywords ->
        [{value_node, key}]

      _ ->
        []
    end)
    |> Map.new()
  end

  # [{value, hits}] → [{name, value, hits}] with collision-suffixed
  # names. Sorted by source position so name ordering is deterministic.
  defp assign_names(groups) do
    groups
    |> Enum.sort_by(fn {_value, hits} -> hit_position(hd(hits)) end)
    |> Enum.reduce({[], MapSet.new()}, fn {value, hits}, {named, taken} ->
      name = unique_name(value, hits, taken)
      {[{name, value, hits} | named], MapSet.put(taken, name)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp unique_name(value, hits, taken) do
    opts = %{key: key_for(hits), context: context_for(hits)}
    base = IdentifierExpansion.derive_constant_name(value, opts)

    base
    |> Stream.iterate(&next_name(&1, base))
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  defp next_name(current, base) do
    suffix =
      case current do
        ^base -> 2
        _ -> current |> String.split("_") |> List.last() |> String.to_integer() |> Kernel.+(1)
      end

    "#{base}_#{suffix}"
  end

  defp key_for(hits), do: Enum.find_value(hits, fn %{key: key} -> key end)

  defp context_for(hits), do: Enum.find_value(hits, fn %{context: context} -> context end)

  defp emit_patches([], _exprs), do: []

  defp emit_patches(named, exprs) do
    occurrence_patches(named) ++ [attribute_block_patch(named, exprs)]
  end

  defp occurrence_patches(named) do
    Enum.flat_map(named, fn {name, _value, hits} ->
      Enum.map(hits, fn %{node: node} -> Patch.replace(node, "@#{name}") end)
    end)
  end

  # One line-anchored insertion carrying every `@name value` line,
  # placed at the first top-level expression's line, column 1.
  defp attribute_block_patch(named, exprs) do
    line = exprs |> hd() |> line_of()

    text =
      named
      |> Enum.map_join("\n", fn {name, value, _hits} -> "@#{name} #{render(value)}" end)

    range = %{start: [line: line, column: 1], end: [line: line, column: 1]}
    Patch.new(range, text <> "\n\n", false)
  end

  defp render(value) when is_float(value), do: Float.to_string(value)
  defp render(value) when is_integer(value), do: Integer.to_string(value)

  defp hit_position(%{node: node}) do
    {_, meta, _} = node
    {Keyword.get(meta, :line, 0), Keyword.get(meta, :column, 0)}
  end
end
