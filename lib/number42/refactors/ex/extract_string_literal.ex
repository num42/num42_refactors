defmodule Number42.Refactors.Ex.ExtractStringLiteral do
  @moduledoc """
  Hoists repeated string literals into a `@module_attribute`.

      defmodule M do
        def a, do: log("connection refused")
        def b, do: warn("connection refused")
      end
      ↓
      defmodule M do
        @connection_refused "connection refused"
        def a, do: log(@connection_refused)
        def b, do: warn(@connection_refused)
      end

  The string sibling of `ExtractMagicNumber`. A literal string repeated
  `min_occurrences` times (default `2`) across one module is a magic
  string: re-typed by hand, easy to desync, its meaning implicit. Lifting
  it into a named attribute gives the value one authoritative definition.

  Distinct from `HoistHardcodedConfig`, which only targets URL- and
  path-shaped strings regardless of repetition — this fires on *any*
  repeated string that clears the length floor.

  ## Naming

  Via `IdentifierExpansion.derive_constant_name/2`, first hit wins: the
  keyword key (`status: "active"` → `@status`), then a URL/path content
  name, then the string's own content slugified to snake_case
  (`"connection refused" → @connection_refused`). A string with no
  nameable content (punctuation only) falls back to `@string_<n>`.

  ## Configuring thresholds

      configured_modules: [
        {Number42.Refactors.Ex.ExtractStringLiteral,
         min_occurrences: 3, min_length: 5}
      ]

  ## Skip conditions

  - **Trivial strings** — a literal shorter than `min_length` (default
    `3`) stays inline: `""`, `" "`, `"a"` read clearly as-is.
  - **Below threshold** — a string occurring fewer than `min_occurrences`
    times stays inline.
  - **Interpolation** — `"id=\#{x}"` is not a plain literal; it carries a
    runtime expression and is neither candidate nor counted.
  - **Doc strings** — the value of `@moduledoc`/`@doc`/`@typedoc` is
    documentation, not data; excluded.
  - **Already an attribute value** — a string that *is* the value of an
    `@attr` definition is already named; excluded both as a candidate and
    from the count (idempotence).
  - **Pattern literals** — a string in a match position (`def f("GET")`,
    `x = "GET"`) can't become a `@attr`; excluded and uncounted.
  - **Quote bodies** — a literal inside `quote do … end` would hoist into
    a `@attr` that resolves in the *calling* module at expansion time;
    quote subtrees are pruned.
  - **Cross-module** — each `defmodule` is processed on its own; a string
    shared across sibling/nested modules is never merged.

  ## Idempotence

  After the rewrite each occurrence is `@name`, no longer a bare literal,
  so the second pass counts zero occurrences and stops.

  ## Default-OFF (opt-in only)

  Disabled by default — `transform/2` is a no-op unless its own opts carry
  `enabled: true`. A slugified content name (`@connection_refused`) can be
  long or awkward, and the same string can carry different meanings within
  one module, so hoisting trades a clear inline value for a named
  indirection. Enable per project once naming is trustworthy there:

      configured_modules: [
        {Number42.Refactors.Ex.ExtractStringLiteral, enabled: true}
      ]
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.IdentifierExpansion
  alias Sourceror.Patch

  @default_min_occurrences 2
  @default_min_length 3
  @doc_attrs ~w(moduledoc doc typedoc shortdoc)a

  @impl Number42.Refactors.Refactor
  def description, do: "Hoist repeated string literals into a named `@module_attribute`"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A bare `"connection refused"` repeated across a module forces every
    reader to trust that all copies stay in sync and re-derive what it
    means. Naming it `@connection_refused` once gives the value a single
    source of truth and turns each use site self-documenting. Trivial
    strings (empty, blank, single-char) are exempt — they read clearly
    as-is.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      min = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
      min_length = Keyword.get(opts, :min_length, @default_min_length)
      Sourceror.parse_string(source) |> apply_patches(source, min, min_length)
    else
      source
    end
  end

  @impl Number42.Refactors.Refactor
  def patches(ast, _source, opts) do
    if Keyword.get(opts, :enabled, false) do
      min = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
      min_length = Keyword.get(opts, :min_length, @default_min_length)
      build_patches(ast, min, min_length)
    else
      []
    end
  end

  defp apply_patches({:ok, ast}, source, min, min_length),
    do: ast |> build_patches(min, min_length) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source, _min, _min_length), do: source

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp build_patches(ast, min, min_length) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [_name, [{_do, body}]]} -> module_patches(body, min, min_length)
      _ -> []
    end)
  end

  defp module_patches(body, min, min_length) do
    exprs =
      body |> body_to_exprs() |> Enum.map(&prune_nested_modules/1) |> Enum.map(&prune_quotes/1)

    existing = existing_attr_names(exprs)

    excluded =
      [attribute_value_nodes(exprs), doc_value_nodes(exprs), pattern_literal_nodes(exprs)]
      |> Enum.reduce(&MapSet.union/2)

    exprs
    |> collect_occurrences(excluded, min_length)
    |> Enum.filter(fn {_value, hits} -> length(hits) >= min end)
    |> assign_names(existing)
    |> emit_patches(exprs)
  end

  # Replace nested `defmodule` subtrees with an inert marker so a module's
  # literal walk never reaches into a sibling/inner module — each module is
  # processed when the prewalk visits its own node.
  defp prune_nested_modules(expr) do
    Macro.prewalk(expr, fn
      {:defmodule, _, _} -> {:__pruned__, [], nil}
      node -> node
    end)
  end

  # Replace `quote do … end` subtrees with an inert marker. A `@attr`
  # hoisted out of a quote-body resolves at expansion time in the *calling*
  # module, where the attribute does not exist.
  defp prune_quotes(expr) do
    Macro.prewalk(expr, fn
      {:quote, _, _} -> {:__pruned__, [], nil}
      node -> node
    end)
  end

  # String literals sitting in a *pattern* position. A module attribute is
  # an expression and is illegal in a match pattern — `def f(@attr)` against
  # `def f("GET")` does not compile. Excluded as candidate and from count:
  # function-head args, `->`-clause patterns, and the LHS of `=`/`<-`.
  defp pattern_literal_nodes(exprs) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(&pattern_subtrees/1)
    |> Enum.flat_map(&string_literal_nodes/1)
    |> MapSet.new()
  end

  defp pattern_subtrees({kind, _, [head | _]}) when def_or_macro_kind?(kind),
    do: head |> strip_when() |> head_args()

  defp pattern_subtrees({:->, _, [lhs, _body]}), do: lhs |> List.wrap() |> Enum.map(&strip_when/1)
  defp pattern_subtrees({:=, _, [lhs, _rhs]}), do: [lhs]
  defp pattern_subtrees({:<-, _, [lhs, _rhs]}), do: [lhs]
  defp pattern_subtrees(_), do: []

  defp strip_when({:when, _, [pat | _]}), do: pat
  defp strip_when(other), do: other

  defp head_args({name, _, args}) when is_atom(name) and is_list(args), do: args
  defp head_args(_), do: []

  defp string_literal_nodes(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.filter(&plain_string_node?/1)
  end

  # String literals that ARE the value of an `@attr value` definition. They
  # are already named constants — neither candidates nor counted.
  defp attribute_value_nodes(exprs) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {:@, _, [{name, _, [value_node]}]} when is_atom(name) -> [value_node]
      _ -> []
    end)
    |> MapSet.new()
  end

  # Doc-attribute values (`@moduledoc "…"`, `@doc "…"`) are documentation,
  # not data. Even though they're caught by `attribute_value_nodes`, name
  # them explicitly so heredoc docs are clearly off-limits.
  defp doc_value_nodes(exprs) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {:@, _, [{name, _, [value_node]}]} when name in @doc_attrs -> [value_node]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp existing_attr_names(exprs) do
    exprs
    |> Enum.flat_map(fn
      {:@, _, [{name, _, [_value]}]} when is_atom(name) -> [Atom.to_string(name)]
      _ -> []
    end)
    |> MapSet.new()
  end

  # %{value => [%{node, value, key}]} — every hoistable string-literal node,
  # grouped by value, in source order, tagged with the keyword key it sat
  # under (or nil).
  defp collect_occurrences(exprs, excluded, min_length) do
    keys = keyword_value_keys(exprs)

    exprs
    |> Enum.flat_map(&literal_hits(&1, excluded, keys, min_length))
    |> Enum.group_by(fn %{value: value} -> value end)
  end

  defp literal_hits(expr, excluded, keys, min_length) do
    {_, hits} =
      Macro.prewalk(expr, [], fn node, acc ->
        {node, prepend_hit(node, acc, excluded, keys, min_length)}
      end)

    Enum.reverse(hits)
  end

  defp prepend_hit({:__block__, _, [value]} = node, acc, excluded, keys, min_length)
       when is_binary(value) do
    cond do
      String.length(value) < min_length -> acc
      MapSet.member?(excluded, node) -> acc
      true -> [%{node: node, value: value, key: Map.get(keys, node)} | acc]
    end
  end

  defp prepend_hit(_node, acc, _excluded, _keys, _min_length), do: acc

  # Map a string-literal value-node to the keyword key it sat under, for
  # genuine keyword *arguments* only. Block keywords (`do:`/`else:`/…) are
  # structural, not data, so they are excluded.
  @block_keywords ~w(do else after catch rescue)a
  defp keyword_value_keys(exprs) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {{:__block__, _, [key]}, {:__block__, _, [value]} = value_node}
      when is_atom(key) and is_binary(value) and key not in @block_keywords ->
        [{value_node, key}]

      _ ->
        []
    end)
    |> Map.new()
  end

  # An interpolated string is `{:<<>>, _, segments}`, not a `:__block__`
  # literal — so it never reaches `prepend_hit`. A plain literal is a
  # `:__block__` wrapping a single binary.
  defp plain_string_node?({:__block__, _, [value]}) when is_binary(value), do: true
  defp plain_string_node?(_), do: false

  # [{value, hits}] → [%{name, value, hits}] with collision-suffixed names.
  # Sorted by source position so name ordering is deterministic.
  defp assign_names(groups, existing) do
    taken = Map.new(existing, &{&1, nil})

    groups
    |> Enum.sort_by(fn {_value, hits} -> hit_position(hd(hits)) end)
    |> Enum.reduce({[], taken}, fn {value, hits}, {named, taken} ->
      name = unique_name(value, hits, taken)
      {[%{name: name, value: value, hits: hits} | named], Map.put(taken, name, nil)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp unique_name(value, hits, taken) do
    base = string_constant_name(value, key_for(hits))
    {:ok, name} = resolve_collision(base, taken, on_collision: :suffix)
    name
  end

  # Prefer `derive_constant_name/2` (key, URL, path), then slugify the
  # string's own content. A content string with no usable name falls back
  # to `string` (collision-suffixed to `string_2`, … by the caller).
  defp string_constant_name(value, key) do
    case IdentifierExpansion.derive_constant_name(value, %{key: key}) do
      "default_string" -> slugify(value) || "string"
      name -> name
    end
  end

  # Lowercase, keep alphanumerics, collapse every other run to `_`, trim
  # leading/trailing `_`, cap length so a long sentence doesn't become a
  # 200-char attribute. Returns nil when nothing alphanumeric survives.
  @slug_max_chars 40
  defp slugify(value) do
    slug =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "_")
      |> String.trim("_")
      |> String.slice(0, @slug_max_chars)
      |> String.trim("_")

    if slug == "" or not String.match?(slug, ~r/[a-z]/), do: nil, else: slug
  end

  defp key_for(hits), do: Enum.find_value(hits, fn %{key: key} -> key end)

  defp emit_patches([], _exprs), do: []

  defp emit_patches(named, exprs) do
    occurrence_patches(named) ++ [attribute_block_patch(named, exprs)]
  end

  defp occurrence_patches(named) do
    Enum.flat_map(named, fn %{name: name, hits: hits} ->
      Enum.map(hits, fn %{node: node} -> Patch.replace(node, "@#{name}") end)
    end)
  end

  # One line-anchored insertion carrying every `@name value` line, placed at
  # the first top-level expression's line, column 1.
  defp attribute_block_patch(named, exprs) do
    line = exprs |> hd() |> line_of()

    text =
      Enum.map_join(named, "\n", fn %{name: name, value: value} ->
        "@#{name} #{inspect(value)}"
      end)

    range = %{start: [line: line, column: 1], end: [line: line, column: 1]}
    Patch.new(range, text <> "\n\n", false)
  end

  defp hit_position(%{node: node}) do
    {_, meta, _} = node
    {Keyword.get(meta, :line, 0), Keyword.get(meta, :column, 0)}
  end
end
