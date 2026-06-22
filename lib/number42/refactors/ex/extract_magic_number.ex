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

  @impl Number42.Refactors.Refactor
  def patches(ast, _source, opts) do
    if Keyword.get(opts, :enabled, false) do
      min = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
      build_patches(ast, min)
    else
      []
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
      [
        attribute_value_nodes(exprs),
        pattern_literal_nodes(exprs),
        capture_arity_nodes(exprs),
        directive_nodes(exprs)
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

  # Every numeric literal under a directive or declaration call whose
  # numbers are not repeated data:
  #
  #   * `import`/`alias`/`require` — the only number is a function arity
  #     in an `only:`/`except:` list (`import M, only: [foo: 4]`); an
  #     arity must stay a literal, `only: [foo: @attr]` would not compile.
  #   * `attr`/`slot` — a component declaration's `default:` is a spec,
  #     not a recurring magic value; `attr :gap, default: 4` reads as the
  #     declaration it is, and hoisting `4` into `@gap_default` only adds
  #     indirection.
  #
  # These literals are neither candidate nor counted.
  @directive_calls [:import, :alias, :require, :attr, :slot]
  defp directive_nodes(exprs) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {directive, _, _} = node when directive in @directive_calls ->
        numeric_literal_nodes(node)

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
        numeric_literal_nodes(value_node)

      _ ->
        []
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
    clauses = clause_contexts(exprs)

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

  # Map a literal value-node to the `{function_name, pattern}` of the
  # guard-free function clause whose body it *is* — `def image_width("md"),
  # do: 80` ↦ `80 ↦ {"image_width", "md"}`. Only a clause whose entire
  # body is the bare literal qualifies; a multi-statement body or a
  # literal nested deeper carries no single discriminating pattern.
  defp clause_contexts(exprs) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(&clause_body_context/1)
    |> Map.new()
  end

  defp clause_body_context({kind, _, [head, [{{:__block__, _, [:do]}, body_node}]]})
       when kind in [:def, :defp] do
    with {fun, pattern} <- clause_name_and_pattern(head),
         {:__block__, _, [value]} = node when is_number(value) <- body_node do
      [{node, {fun, pattern}}]
    else
      _ -> []
    end
  end

  defp clause_body_context(_), do: []

  defp clause_name_and_pattern(head) do
    case strip_when(head) do
      {fun, _, [first | _]} when is_atom(fun) -> {Atom.to_string(fun), literal_pattern(first)}
      _ -> :error
    end
  end

  # The discriminating token of a clause's first argument. A `nil`
  # literal and the `_` wildcard both name their clause — `nil` and
  # `default` — so a `f(nil)`/`f(_)` pair yields `@f_nil`/`@f_default`
  # rather than a `@f`/`@f_2` collision. Other non-literal patterns carry
  # no token (the function name stands alone).
  defp literal_pattern({:__block__, _, [nil]}), do: "nil"
  defp literal_pattern(nil), do: "nil"
  defp literal_pattern({:_, _, ctx}) when is_atom(ctx), do: "default"

  defp literal_pattern({:__block__, _, [value]}) when is_binary(value) or is_atom(value),
    do: value

  defp literal_pattern(value) when is_binary(value) or is_atom(value), do: value
  defp literal_pattern(_), do: nil

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

  # Map a literal value-node to the name derived from the keyword key it
  # sat under, enriched with the surrounding call: the call's first
  # literal param and the call's noun (its name with a leading verb like
  # `validate_`/`put_`/`set_` stripped) join the key, deduped and ordered
  # `param_key_noun` — `validate_length(:email, max: 160)` → `email_max_length`.
  # A bare keyword arg with no enriching call keeps just its key
  # (`connect(timeout: 5000)` → `timeout`). Block keywords (`do:`/`else:`/…)
  # are structural, not data, and excluded — their key would name the
  # attribute `do`.
  @block_keywords ~w(do else after catch rescue)a
  @call_verbs ~w(validate put set cast get fetch assign update build make)
  defp keyword_value_keys(exprs) do
    exprs
    |> Enum.flat_map(&keyword_names_in_scope(&1, nil))
    |> Map.new()
  end

  # Walk carrying the nearest enclosing function name as scope, so a call
  # with no literal param of its own can borrow the function as the
  # subject (`def show, do: JS.show(time: 300)` → `show_time`). A `def`
  # sets the scope for its whole body; the walk recurses with that scope
  # instead of re-descending scope-less, so each call is named exactly
  # once.
  defp keyword_names_in_scope({kind, _, [head | rest]}, _scope)
       when kind in [:def, :defp] do
    fun = enclosing_function_name(head)
    Enum.flat_map(rest, &keyword_names_in_scope(&1, fun))
  end

  defp keyword_names_in_scope({_, _, args} = node, scope) when is_list(args) do
    call_keyword_names(node, scope) ++ Enum.flat_map(args, &keyword_names_in_scope(&1, scope))
  end

  defp keyword_names_in_scope({left, right}, scope) do
    keyword_names_in_scope(left, scope) ++ keyword_names_in_scope(right, scope)
  end

  defp keyword_names_in_scope(list, scope) when is_list(list) do
    Enum.flat_map(list, &keyword_names_in_scope(&1, scope))
  end

  defp keyword_names_in_scope(_node, _scope), do: []

  defp enclosing_function_name(head) do
    case strip_when(head) do
      {fun, _, _} when is_atom(fun) -> Atom.to_string(fun)
      _ -> nil
    end
  end

  defp call_keyword_names({{:., _, [_mod, fun]}, _, args}, scope)
       when is_atom(fun) and is_list(args),
       do: keyword_names_in_call(fun, args, scope)

  defp call_keyword_names({fun, _, args}, scope) when is_atom(fun) and is_list(args),
    do: keyword_names_in_call(fun, args, scope)

  defp call_keyword_names(_, _scope), do: []

  defp keyword_names_in_call(fun, args, scope) do
    subject = first_literal_param(args) || scope_subject(scope, fun)
    noun = call_noun(fun)

    for kw_list <- args,
        is_list(kw_list),
        {{:__block__, _, [key]}, {:__block__, _, [value]} = value_node} <- kw_list,
        is_atom(key) and is_number(value) and key not in @block_keywords do
      {value_node, enriched_name([subject, Atom.to_string(key), noun])}
    end
  end

  # The enclosing function names the value only when the function is a
  # thin wrapper around the like-named call — `def show, do: JS.show(time:
  # 300)` (`show` == call `show`). A function whose name differs from the
  # call it makes (`def a, do: connect(timeout: 5000)`) is not the
  # subject; using it would split one constant across unrelated clause
  # names (`a_timeout`/`b_timeout`).
  defp scope_subject(nil, _fun), do: nil
  defp scope_subject(scope, fun), do: if(scope == Atom.to_string(fun), do: scope, else: nil)

  # The first positional argument that is a plain atom/string literal —
  # `validate_length(:email, max: 160)` → `"email"`. Names the subject the
  # call acts on. nil when no such param precedes the keywords.
  defp first_literal_param(args) do
    Enum.find_value(args, fn
      {:__block__, _, [value]} when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      {:__block__, _, [value]} when is_binary(value) -> value
      _ -> nil
    end)
  end

  # The call's noun: its name with a leading domain verb stripped
  # (`validate_length` → `length`, `put_resp` → `resp`). nil when the name
  # is a bare verb or carries no recognized verb prefix, so a plain call
  # like `connect`/`reconnect` contributes nothing.
  defp call_noun(fun) do
    str = Atom.to_string(fun)

    Enum.find_value(@call_verbs, fn verb ->
      case String.split(str, verb <> "_", parts: 2) do
        ["", noun] when noun != "" -> noun
        _ -> nil
      end
    end)
  end

  # Join the available tokens into a single snake_case name, dropping nils
  # and de-duplicating repeats while preserving order
  # (`["email", "max", "length"]` → `"email_max_length"`,
  # `["size", "size", nil]` → `"size"`).
  defp enriched_name(tokens) do
    tokens
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.flat_map(&String.split(&1, "_", trim: true))
    |> Enum.dedup()
    |> Enum.uniq()
    |> Enum.join("_")
  end

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
      unambiguous?(hits) and IdentifierExpansion.nameable?(value, name_opts(hits))
    end)
    |> Enum.reduce({[], MapSet.new()}, fn {value, hits}, {named, taken} ->
      name = unique_name(value, hits, taken)
      {[{name, value, hits} | named], MapSet.put(taken, name)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # Occurrences agree on meaning when they carry at most one distinct
  # keyword key — `nil` (no key) is compatible with any single named key,
  # but two different keys are a coincidental value clash, not one
  # constant.
  defp unambiguous?(hits) do
    hits |> Enum.map(& &1.key) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length() <= 1
  end

  defp unique_name(value, hits, taken) do
    base = IdentifierExpansion.derive_constant_name(value, name_opts(hits))

    base
    |> Stream.iterate(&next_name(&1, base))
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  defp name_opts(hits) do
    %{key: key_for(hits), context: context_for(hits), clause: clause_for(hits)}
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

  defp clause_for(hits), do: Enum.find_value(hits, fn %{clause: clause} -> clause end)

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
