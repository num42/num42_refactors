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
  alias Number42.Refactors.LiteralNaming
  alias Sourceror.Patch

  @default_min_length 3
  @default_name_max_words 5
  @doc_attrs ~w(moduledoc doc typedoc shortdoc)a

  # Filler words dropped when naming a constant after a sentence's first
  # words — auxiliaries, articles, pronouns, prepositions. Negations
  # (`not`/`no`/`never`) are deliberately kept: they carry meaning.
  @name_stopwords ~w(
    a an the this that these those
    i you your he she it we they
    is are was were be been being am
    has have had do does did
    to of in on at by for with from as
    and or but
  )

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
      Sourceror.parse_string(source) |> apply_patches(source, settings(opts))
    else
      source
    end
  end

  @impl Number42.Refactors.Refactor
  def patches(ast, _source, opts) do
    if Keyword.get(opts, :enabled, false) do
      build_patches(ast, settings(opts))
    else
      []
    end
  end

  # `:min_occurrences` overrides every context class when set; otherwise
  # the per-role defaults apply (keyword/log need 2, the rest need 1).
  defp settings(opts) do
    %{
      min_override: Keyword.get(opts, :min_occurrences),
      min_length: Keyword.get(opts, :min_length, @default_min_length),
      name_max_words: Keyword.get(opts, :name_max_words, @default_name_max_words)
    }
  end

  defp apply_patches({:ok, ast}, source, settings),
    do: ast |> build_patches(settings) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source, _settings), do: source

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp build_patches(ast, settings) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [_name, [{_do, body}]]} -> module_patches(body, settings)
      _ -> []
    end)
  end

  defp module_patches(body, settings) do
    exprs =
      body
      |> body_to_exprs()
      |> Enum.map(&prune_nested_modules/1)
      |> Enum.map(&prune_quotes/1)
      |> Enum.map(&prune_queries/1)

    existing = existing_attr_names(exprs)

    excluded =
      [
        attribute_value_nodes(exprs),
        doc_value_nodes(exprs),
        pattern_literal_nodes(exprs),
        LiteralNaming.directive_nodes(exprs, &is_binary/1)
      ]
      |> Enum.reduce(&MapSet.union/2)

    exprs
    |> collect_occurrences(excluded, settings)
    |> Enum.filter(fn {_value, hits} -> length(hits) >= required_min(hits, settings) end)
    |> assign_names(existing, settings)
    |> emit_patches(exprs)
  end

  # The occurrence threshold a value group must clear. An explicit
  # `:min_occurrences` overrides every role; otherwise each role carries
  # its own default and the group needs the strictest one any of its
  # occurrences demands (a keyword/log use is not loosened by a sibling
  # plain use).
  @role_min %{keyword: 2, log: 2, other: 1}
  defp required_min(_hits, %{min_override: override}) when is_integer(override), do: override

  defp required_min(hits, _settings) do
    hits
    |> Enum.map(fn %{role: role} -> Map.fetch!(@role_min, role) end)
    |> Enum.max()
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

  # Replace an Ecto `from(...)` query subtree with an inert marker. Query
  # macros nested in it (`ago`, `fragment`, `field`, `type`) read their
  # string arguments at compile time — `ago(n, "day")` needs a literal
  # `"day"`, not `ago(n, @day)`, which fails with `invalid interval`. So
  # strings inside a query are structural, not data, like a quote body.
  # Only the `from` macro is pruned; it wraps the whole query expression,
  # including pipe-chained `where`/`select` keyword clauses.
  defp prune_queries(expr) do
    Macro.prewalk(expr, fn
      {:from, _, args} = node when is_list(args) -> if query_from?(args), do: pruned(), else: node
      node -> node
    end)
  end

  # `Ecto.Query.from/2` takes `binding in source` as its first argument
  # (`from t in "tokens", …`); distinguish it from an unrelated local
  # `from(...)` by that `in` shape.
  defp query_from?([{:in, _, [_binding, _source]} | _]), do: true
  defp query_from?(_), do: false

  defp pruned, do: {:__pruned__, [], nil}

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
    do: head |> LiteralNaming.strip_when() |> head_args()

  defp pattern_subtrees({:->, _, [lhs, _body]}),
    do: lhs |> List.wrap() |> Enum.map(&LiteralNaming.strip_when/1)

  defp pattern_subtrees({:=, _, [lhs, _rhs]}), do: [lhs]
  defp pattern_subtrees({:<-, _, [lhs, _rhs]}), do: [lhs]
  defp pattern_subtrees(_), do: []

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

  # %{value => [%{node, value, key, context, clause, role}]} — every
  # hoistable string-literal node, grouped by value, in source order,
  # tagged with the shared naming axes (keyword key / call context /
  # clause head) and its syntactic role (for the per-role threshold).
  defp collect_occurrences(exprs, excluded, settings) do
    ctx = %{
      excluded: excluded,
      keys: LiteralNaming.keyword_value_keys(exprs, &is_binary/1),
      contexts: LiteralNaming.call_contexts(exprs, &is_binary/1),
      clauses: LiteralNaming.clause_contexts(exprs, &is_binary/1),
      roles: LiteralNaming.occurrence_roles(exprs, &is_binary/1),
      min_length: settings.min_length
    }

    exprs
    |> Enum.flat_map(&literal_hits(&1, ctx))
    |> Enum.group_by(fn %{value: value} -> value end)
  end

  defp literal_hits(expr, ctx) do
    {_, hits} =
      Macro.prewalk(expr, [], fn node, acc -> {node, prepend_hit(node, acc, ctx)} end)

    Enum.reverse(hits)
  end

  defp prepend_hit({:__block__, _, [value]} = node, acc, ctx) when is_binary(value) do
    cond do
      String.length(value) < ctx.min_length ->
        acc

      MapSet.member?(ctx.excluded, node) ->
        acc

      true ->
        hit = %{
          node: node,
          value: value,
          key: Map.get(ctx.keys, node),
          context: Map.get(ctx.contexts, node),
          clause: Map.get(ctx.clauses, node),
          role: Map.get(ctx.roles, node, :other)
        }

        [hit | acc]
    end
  end

  defp prepend_hit(_node, acc, _ctx), do: acc

  # An interpolated string is `{:<<>>, _, segments}`, not a `:__block__`
  # literal — so it never reaches `prepend_hit`. A plain literal is a
  # `:__block__` wrapping a single binary.
  defp plain_string_node?({:__block__, _, [value]}) when is_binary(value), do: true
  defp plain_string_node?(_), do: false

  # [{value, hits}] → [%{name, value, hits}] with collision-suffixed names.
  # Sorted by source position so name ordering is deterministic. A group
  # whose occurrences carry two distinct keyword keys is dropped — a
  # coincidental value clash, not one constant (the same guard the number
  # refactor uses). Strings keep value-only-fallback groups, naming them by
  # slugifying their own content, so the `nameable?` skip does NOT apply.
  defp assign_names(groups, existing, settings) do
    taken = Map.new(existing, &{&1, nil})

    groups
    |> Enum.sort_by(fn {_value, hits} -> hit_position(hd(hits)) end)
    |> Enum.filter(fn {_value, hits} -> LiteralNaming.unambiguous?(hits) end)
    |> Enum.reduce({[], taken}, fn {value, hits}, {named, taken} ->
      case unique_name(value, hits, taken, settings) do
        nil -> {named, taken}
        name -> {[%{name: name, value: value, hits: hits} | named], Map.put(taken, name, nil)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp unique_name(value, hits, taken, settings) do
    case string_constant_name(value, hits, settings) do
      nil ->
        nil

      base ->
        {:ok, name} = resolve_collision(base, taken, on_collision: :suffix)
        name
    end
  end

  # Name a string by its *function* before its content. Try the shared
  # naming axes (key/context/clause/URL/path); a bare generic key is
  # enriched with the value when the value is a short identifier
  # (`as: "collection"` → `as_collection`). Only when no axis names it does
  # the content speak: a word-shaped string is named by its first words
  # (stopwords filtered, capped at `name_max_words`); a punctuation-heavy
  # string (SQL fragment, header) names nothing and is left inline (nil).
  @generic_keys ~w(as id name type key tag kind role slot mode status state)
  defp string_constant_name(value, hits, settings) do
    case IdentifierExpansion.derive_constant_name(value, LiteralNaming.name_opts(hits)) do
      "default_string" -> content_name(value, settings)
      key when key in @generic_keys -> enrich_generic_key(key, value)
      name -> name
    end
  end

  # A generic key gains the value as a qualifier when the value is a short
  # single-word identifier (`as` + `collection` → `as_collection`); a
  # multi-word or punctuation value leaves the key to stand alone.
  defp enrich_generic_key(key, value) do
    case LiteralNaming.sanitize_subtoken(value) do
      [token] -> "#{key}_#{token}"
      _ -> key
    end
  end

  # Name a content string by its leading words: lowercase, split on
  # non-alphanumerics, drop stopwords (keeping negations), take the first
  # `name_max_words`. A string that is mostly punctuation — an SQL
  # fragment, an operator template, a header — is not a label: it returns
  # nil and is left inline.
  defp content_name(value, settings) do
    if wordlike?(value) do
      value
      |> String.downcase()
      |> String.split(~r/[^a-z0-9]+/u, trim: true)
      |> Enum.reject(&(&1 in @name_stopwords))
      |> Enum.take(settings.name_max_words)
      |> LiteralNaming.valid_stem()
      |> case do
        "" -> nil
        stem -> stem
      end
    end
  end

  # A string reads as a label/message when letters and spaces dominate it.
  # An SQL fragment (`"COALESCE(? || '.', '') || ?"`), a CSP/header
  # (`"connect-src 'self' wss: ws:; "`) or a strftime template
  # (`"%B %d, %Y"`) is heavy with operators, quotes and `%`-directives and
  # falls below the floor — it is config, not a label, and carries no name.
  @wordlike_floor 0.8
  defp wordlike?(value) do
    graphemes = String.graphemes(value)
    wordish = Enum.count(graphemes, &String.match?(&1, ~r/[\p{L}\p{N}\s]/u))
    graphemes != [] and wordish / length(graphemes) >= @wordlike_floor
  end

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
