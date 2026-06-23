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

  ## Enabled by default

  The two risks that once kept this opt-in are now gates, not hopes:

  - **Meaningless names** — a group whose only derivation is the bare
    value (`@int_42`) is dropped by `nameable?/1`. A literal is hoisted
    only when an axis (keyword key, clause head, recognized call) gives
    it a name that says something the value does not.
  - **One literal, several meanings** — `LiteralNaming.unambiguous?/1`
    drops a group whose occurrences disagree on the deliberate naming
    axis: two distinct keys, or a keyed site mixed with a key-less one
    (`max_concurrency: 10` must not lend its name to `idx + 10`). The
    call-context stem matches a whole function-name segment, so
    `send_chunked(conn, 200)` is not misread as a chunk size.

  Tune the threshold per project if a value should repeat more before it
  is hoisted:

      configured_modules: [
        {Number42.Refactors.Ex.ExtractMagicNumber, min_occurrences: 3}
      ]
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.IdentifierExpansion
  alias Number42.Refactors.LiteralNaming
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
    min = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
    Sourceror.parse_string(source) |> apply_patches(source, min)
  end

  @impl Number42.Refactors.Refactor
  def patches(ast, _source, opts) do
    min = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
    build_patches(ast, min)
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
      [
        attribute_value_nodes(exprs),
        pattern_literal_nodes(exprs),
        capture_arity_nodes(exprs),
        LiteralNaming.directive_nodes(exprs, &is_number/1)
      ]
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
    |> Enum.flat_map(fn ast -> LiteralNaming.literal_value_nodes(ast, &is_number/1) end)
    |> MapSet.new()
  end

  defp pattern_subtrees({kind, _, [head | _]}) when kind in [:def, :defp, :defmacro, :defmacrop],
    do: head |> LiteralNaming.strip_when() |> head_args()

  defp pattern_subtrees({:->, _, [lhs, _body]}),
    do: lhs |> List.wrap() |> Enum.map(&LiteralNaming.strip_when/1)

  defp pattern_subtrees({:=, _, [lhs, _rhs]}), do: [lhs]
  defp pattern_subtrees({:<-, _, [lhs, _rhs]}), do: [lhs]
  defp pattern_subtrees(_), do: []

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

  # Every numeric literal anywhere in the body of an `@attr value`
  # definition. The body is already a named constant (`@one_mb`,
  # `@gap_map`); a literal inside it — an arithmetic operand
  # (`@one_mb 1024 * 1024`) or a map/keyword entry
  # (`@gap_map %{4 => "gap-4"}`) — is already covered by that name.
  # Hoisting it out trades the name for `@kibi * @kibi` or splices a
  # symbolic key into a literal table. So the whole body subtree is
  # excluded — neither candidate nor counted.
  defp attribute_value_nodes(exprs) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {:@, _, [{name, _, [value_node]}]} when is_atom(name) ->
        LiteralNaming.literal_value_nodes(value_node, &is_number/1)

      _ ->
        []
    end)
    |> MapSet.new()
  end

  # %{value => [%{node, value, key, context, clause}]} — every hoistable
  # numeric-literal node, grouped by value, in source order, tagged with
  # the shared naming axes (keyword key / call context / clause head).
  defp collect_occurrences(exprs, excluded) do
    keys = LiteralNaming.keyword_value_keys(exprs, &is_number/1)
    contexts = LiteralNaming.call_contexts(exprs, &is_number/1)
    clauses = LiteralNaming.clause_contexts(exprs, &is_number/1)

    exprs
    |> Enum.flat_map(&literal_hits(&1, excluded, keys, contexts, clauses))
    |> Enum.group_by(fn %{value: value} -> value end)
  end

  defp literal_hits(expr, excluded, keys, contexts, clauses) do
    {_, hits} =
      Macro.prewalk(expr, [], fn node, acc ->
        {node, prepend_hit(node, acc, excluded, keys, contexts, clauses)}
      end)

    Enum.reverse(hits)
  end

  defp prepend_hit({:__block__, _, [value]} = node, acc, excluded, keys, contexts, clauses)
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
          context: Map.get(contexts, node),
          clause: Map.get(clauses, node)
        }

        [hit | acc]
    end
  end

  defp prepend_hit(_node, acc, _excluded, _keys, _contexts, _clauses), do: acc

  # [{value, hits}] → [{name, value, hits}] with collision-suffixed
  # names. Sorted by source position so name ordering is deterministic.
  # Two groups are dropped before naming:
  #
  #   * the only derivable name is the bare value-in-name fallback
  #     (`int_240`) — the indirection carries no information the literal
  #     does not; and
  #   * the occurrences disagree on what they mean — distinct keyword keys
  #     (`batch_size: 5` vs `max_concurrency: 5`) sharing a value by
  #     coincidence. Naming the group would stamp one site's name onto an
  #     unrelated one; they are not the same constant.
  defp assign_names(groups) do
    groups
    |> Enum.sort_by(fn {_value, hits} -> hit_position(hd(hits)) end)
    |> Enum.filter(fn {value, hits} ->
      LiteralNaming.unambiguous?(hits) and
        IdentifierExpansion.nameable?(value, LiteralNaming.name_opts(hits))
    end)
    |> Enum.reduce({[], MapSet.new()}, fn {value, hits}, {named, taken} ->
      name = unique_name(value, hits, taken)
      {[{name, value, hits} | named], MapSet.put(taken, name)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp unique_name(value, hits, taken) do
    base = IdentifierExpansion.derive_constant_name(value, LiteralNaming.name_opts(hits))

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
