defmodule Number42.Refactors.Ex.RepeatedPatternToMacro do
  @moduledoc """
  Collapse **N structurally identical functions** that differ only in
  literal/atom values into a single compile-time `for` block that
  generates the clauses with `def unquote(...)`. Handles zero-arity
  functions and single-parameter functions whose param is the same bare
  variable across the group (passed through to the generated clause
  unchanged).

      # before
      defmodule Palette do
        def red, do: %Color{name: "red", hex: "#ff0000"}
        def green, do: %Color{name: "green", hex: "#00ff00"}
        def blue, do: %Color{name: "blue", hex: "#0000ff"}
      end

      # after
      defmodule Palette do
        for {fun, arg1, arg2} <- [
              {:red, "red", "#ff0000"},
              {:green, "green", "#00ff00"},
              {:blue, "blue", "#0000ff"}
            ] do
          def unquote(fun)(), do: %Color{name: unquote(arg1), hex: unquote(arg2)}
        end
      end

  The single-parameter case threads the param through verbatim:

      # before
      def red(mode), do: Color.new("red", mode)
      def green(mode), do: Color.new("green", mode)
      def blue(mode), do: Color.new("blue", mode)

      # after
      for {fun, arg1} <- [{:red, "red"}, {:green, "green"}, {:blue, "blue"}] do
        def unquote(fun)(mode), do: Color.new(unquote(arg1), mode)
      end

  Only the literals (`"red"`, …) become `unquote` holes; the param
  (`mode`) is reproduced as a normal head var, so its reads in the body
  resolve to it without any `var!`/hygiene escape — param and body share
  the same quote scope, and the value table never carries the param.

  Structural identity is decided with
  `AstHelpers.replace_literals_with_holes/1`: two bodies are in the same
  group when their literal-stripped skeletons are equal. Within a group,
  each literal leaf that *varies* across the members becomes one `unquote`
  hole + one tuple column; literals that are *constant* across the whole
  group stay inline. The function name is always the first column.

  ## Default-OFF (opt-in only)

  This refactor is **disabled by default**. It trades local readability
  and tooling support for deduplication: generated clauses don't show up
  for go-to-definition, `@doc`/`@spec` can't be attached per clause, and
  Dialyzer sees the synthesised heads, not the source. Enable it
  deliberately, per project, via `.refactor.exs`:

      configured_modules: [
        {Number42.Refactors.Ex.RepeatedPatternToMacro,
         enabled: true, min_functions: 3}
      ]

  Without `enabled: true` in its own opts, `transform/2` is a no-op.

  ## Threshold

  `:min_functions` (default `3`) — the minimum group size that triggers
  generation. Below it the functions stay as-is.

  ## Skip list (source left unchanged when any holds)

  - **Not opted in.** No `enabled: true` → no-op (see above).
  - **Below threshold.** Fewer than `min_functions` members in the
    largest eligible group.
  - **Arity > 1, or a non-bare-var single param.** Only `def name, do:
    ...` (arity 0) and `def name(var), do: ...` with a single plain
    variable param are handled. A pattern/literal/default param, or two+
    params, would need co-parameterisation we don't attempt. An arity-1
    group must also agree on the param *name* (`mode` and `m` are
    different groups).
  - **Guards / multi-clause.** A guarded head, or a `{name, arity}` that
    appears in more than one clause, disqualifies the function —
    pattern/guard semantics must not be flattened into a value table.
  - **Attached `@doc`/`@spec`/`@impl`.** Per-clause documentation and
    specs cannot survive `def unquote(...)`; a documented member blocks
    the whole group rather than silently dropping the doc.
  - **Free variables beyond the param.** A body may read only the head's
    param; any other free variable would be undefined after generation,
    so the lifted tuple (plus the passed-through param) must fully
    determine the clause.
  - **No varying literal.** If only the name differs and the body is
    byte-identical, a `for` over names is pure obfuscation — left for the
    exact-duplicate pass.
  - **`def`/`defp` mix or `defmacro`.** Only same-visibility `def` *or*
    `defp` groups; macros are never touched.
  - **A group member already lives in a generated block.** `def
    unquote(...)` heads are not bare atoms, so they never enter a group —
    the pass is idempotent by construction.

  ## v1 scope

  One group is collapsed per module per pass (the first eligible, in
  source order). Further groups are handled by subsequent passes.
  """

  use Number42.Refactors.Refactor

  @default_min_functions 3

  defguardp is_literal_value(v)
            when is_atom(v) or is_integer(v) or is_float(v) or is_binary(v)

  @impl Number42.Refactors.Refactor
  def description,
    do:
      "Collapse N structurally identical zero- or single-param functions into a generated for-block"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Group zero-arity or single-bare-var-param, guard-free, single-clause,
    undocumented functions whose bodies share one literal-stripped
    skeleton and differ only in literal/atom values. Emit a single `for
    {fun, arg1, ...} <- [...]` block whose `def unquote(fun)(param)`
    clause carries the shared skeleton with the varying literals unquoted
    and the param threaded through verbatim. Constant literals stay
    inline. Opt-in and threshold-gated; skips guards, multi/pattern
    params, docs, non-param free vars, and identical-body groups.
    Idempotent: generated heads are not bare atoms, so they never re-enter
    a group.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      min = Keyword.get(opts, :min_functions, @default_min_functions)
      Sourceror.parse_string(source) |> apply_to_parse_result(source, min)
    else
      source
    end
  end

  defp apply_to_parse_result({:ok, ast}, source, min), do: apply_to_ast(ast, source, min)
  defp apply_to_parse_result({:error, _}, source, _min), do: source

  defp apply_to_ast(ast, source, min) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value(:no_match, fn
      {:defmodule, _, [_name, [{_do, body}]]} ->
        body |> body_to_exprs() |> patches_for_module(min)

      _ ->
        nil
    end)
    |> patch_or_passthrough(source)
  end

  defp patch_or_passthrough(:no_match, source), do: source
  defp patch_or_passthrough(nil, source), do: source
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  # Returns the patch list for the first eligible group, or `nil` to keep
  # scanning further modules.
  defp patches_for_module(body_exprs, min) do
    multi = multi_clause_keys(body_exprs)
    documented = documented_nodes(body_exprs)

    body_exprs
    |> Enum.filter(&candidate?(&1, multi, documented))
    |> Enum.group_by(&group_key/1)
    |> Map.values()
    |> Enum.filter(&(length(&1) >= min))
    |> Enum.sort_by(fn [first | _] -> line_of(first) end)
    |> Enum.find_value(&emit_group/1)
  end

  # --- candidate filtering ---------------------------------------------

  defp candidate?({kind, _, [head, body_kw]} = node, multi, documented)
       when kind in [:def, :defp] and is_list(body_kw) do
    with {name, param} <- bare_head(head),
         false <- MapSet.member?(multi, {kind, name}),
         false <- node in documented,
         false <- has_attached_meta?(node),
         body when not is_nil(body) <- do_body(body_kw) do
      extractable_body?(body, param)
    else
      _ -> false
    end
  end

  defp candidate?(_, _, _), do: false

  # Defs immediately preceded by an attached attribute (`@doc`, `@spec`,
  # `@impl`, …). Per-clause docs/specs can't survive generation, so a
  # documented member disqualifies its whole group.
  @attached_attrs ~w(doc spec impl deprecated dialyzer typedoc since)a

  defp documented_nodes(body_exprs) do
    body_exprs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [prev, def_node] -> if attached_attr?(prev), do: [def_node], else: []
    end)
    |> MapSet.new()
  end

  defp attached_attr?({:@, _, [{attr, _, _}]}) when is_atom(attr), do: attr in @attached_attrs
  defp attached_attr?(_), do: false

  # Eligible head shapes, returning `{name, param}`:
  #
  #   - Zero-arity: `{name, meta, nil}` → `{name, nil}`.
  #   - Single bare-var param: `{name, meta, [{var, _, ctx}]}` →
  #     `{name, var}`. The param must be a plain variable (atom name +
  #     atom context, not underscored); patterns, literals and defaults
  #     are rejected so the value table never has to co-parameterise a
  #     destructuring head.
  #
  # Anything else — a guard (`:when`), arity > 1, an unquote head, or a
  # non-var single arg — fails here.
  defp bare_head({name, _, nil}) when is_atom(name), do: {name, nil}

  defp bare_head({name, _, [{var, _, ctx}]})
       when is_atom(name) and is_atom(var) and is_atom(ctx) do
    if reserved_var?(var), do: :error, else: {name, var}
  end

  defp bare_head(_), do: :error

  defp reserved_var?(var) do
    string = Atom.to_string(var)
    String.starts_with?(string, "_") or var in [:__MODULE__, :__CALLER__, :__ENV__]
  end

  # A body is extractable when its free variables are *exactly* the names
  # the head supplies as params — every value the clause depends on is
  # then fully determined by the lifted tuple plus the passed-through
  # param. `free_vars/2` filters against a *known* scope and so can't find
  # them with an empty scope — compute the free set directly: every used
  # var name minus the names bound within the body itself.
  #
  #   - Arity 0 (`param == nil`): free set must be empty (literal-only).
  #   - Arity 1 (`param` is the bare-var name): free set must be a subset
  #     of `{param}`. The param read stays inline in the generated clause
  #     (`def unquote(fun)(mode), do: ... mode ...`); any *other* free var
  #     would be undefined after generation, so the body is rejected.
  @spec extractable_body?(term(), atom() | nil) :: boolean()
  defp extractable_body?(body, param) do
    body
    |> free_var_names()
    |> MapSet.subset?(allowed_free_vars(param))
  end

  defp allowed_free_vars(nil), do: MapSet.new()
  defp allowed_free_vars(param), do: MapSet.new([param])

  defp free_var_names(body),
    do: MapSet.difference(used_var_names(body), bound_in(body))

  # A def carrying leading/trailing comments (a `@doc` attaches as a
  # comment in Sourceror's view) or `@doc`/`@spec` is blocked: per-clause
  # docs/specs cannot survive generation.
  defp has_attached_meta?({_kind, meta, _}) when is_list(meta) do
    leading = Keyword.get(meta, :leading_comments, [])
    leading != []
  end

  defp has_attached_meta?(_), do: false

  # --- grouping --------------------------------------------------------

  # Group key carries the param name so only same-arity, same-param
  # members merge: arity-0 (`nil`) never joins arity-1, and an arity-1
  # group must agree on its bare-var name (`mode` and `m` are distinct
  # groups). The skeleton hash already separates them via the var node,
  # but keying on the param makes the "uniform bare var" rule explicit.
  defp group_key({kind, _, [head, body_kw]}) do
    {_name, param} = bare_head(head)
    body = do_body(body_kw)
    {kind, param, body |> replace_literals_with_holes() |> :erlang.phash2()}
  end

  defp multi_clause_keys(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {kind, _, [head | _]} when kind in [:def, :defp] ->
        case fn_key(strip_when(head)) do
          {name, arity} -> [{kind, name, arity}]
          :error -> []
        end

      _ ->
        []
    end)
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {{kind, name, _arity}, count} when count > 1 -> [{kind, name}]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp fn_key({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp fn_key({name, _, nil}) when is_atom(name), do: {name, 0}
  defp fn_key(_), do: :error

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  # --- emit ------------------------------------------------------------

  defp emit_group([first | _] = group) do
    bodies = Enum.map(group, &def_body/1)
    emit_with_varying(group, first, varying_literal_positions(bodies))
  end

  # No varying literal → identical bodies, name-only divergence. A `for`
  # over names with one fixed body is obfuscation, not dedup → skip.
  defp emit_with_varying(_group, _first, []), do: nil

  defp emit_with_varying(group, {kind, _, [head, _]} = first, varying) do
    {_name, param} = bare_head(head)
    col_names = column_names(varying)
    hole_body = build_hole_body(def_body(first), varying, col_names)
    rows = Enum.map(group, &row_tuple(&1, varying))
    block = render_for_block(kind, param, col_names, rows, hole_body)

    [replace_patch(first, block) | Enum.map(tl(group), &delete_patch/1)]
  end

  # Positions (pre-order literal-leaf index) whose value is not identical
  # across every body in the group.
  defp varying_literal_positions(bodies) do
    leaf_lists = Enum.map(bodies, &literal_leaves/1)
    [first | _] = leaf_lists

    0..(length(first) - 1)//1
    |> Enum.filter(fn idx ->
      leaf_lists |> Enum.map(&(Enum.at(&1, idx) |> strip_all_meta())) |> Enum.uniq() |> length() >
        1
    end)
  end

  defp literal_leaves(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:__block__, _meta, [v]} = node, acc when is_literal_value(v) -> {node, [node | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp column_names(varying), do: Enum.map(1..length(varying)//1, &:"arg#{&1}")

  # Replace each varying literal leaf with `unquote(arg_k)`, leave the
  # rest untouched.
  defp build_hole_body(body, varying, col_names) do
    idx_to_var = varying |> Enum.zip(col_names) |> Map.new()

    {result, _} =
      Macro.prewalk(body, 0, fn
        {:__block__, _meta, [v]} = node, idx when is_literal_value(v) ->
          case Map.fetch(idx_to_var, idx) do
            {:ok, var} -> {{:unquote, [], [{var, [], nil}]}, idx + 1}
            :error -> {node, idx + 1}
          end

        node, idx ->
          {node, idx}
      end)

    result
  end

  defp row_tuple({_kind, _, [head, body_kw]}, varying) do
    {name, _param} = bare_head(head)
    body = do_body(body_kw)
    leaves = literal_leaves(body)
    values = Enum.map(varying, &(leaves |> Enum.at(&1) |> render_node()))

    "{" <> Enum.join([inspect(name) | values], ", ") <> "}"
  end

  # --- rendering -------------------------------------------------------

  defp render_for_block(kind, param, col_names, rows, hole_body) do
    pattern = "{fun, " <> Enum.join(col_names, ", ") <> "}"
    body_str = hole_body |> strip_comments() |> Sourceror.to_string()
    rows_str = Enum.map_join(rows, ",\n", &("        " <> &1))

    """
    for #{pattern} <- [
    #{rows_str}
        ] do
      #{kind} unquote(fun)(#{param_head(param)}), do: #{body_str}
    end\
    """
  end

  # The generated clause head: empty parens for arity 0, the original
  # bare-var name for arity 1. The param is emitted verbatim — `def
  # unquote(fun)(mode)` reuses the source name, so `mode` reads in the
  # body resolve to it. No `var!`/hygiene escape is needed: the param and
  # its body reads share one quote scope, and the only `unquote`d holes
  # are literals from the value table, never the param.
  defp param_head(nil), do: ""
  defp param_head(param) when is_atom(param), do: Atom.to_string(param)

  defp render_node(node), do: node |> strip_comments() |> Sourceror.to_string()

  defp replace_patch(node, change) do
    %{start: start_pos, end: end_pos} = Sourceror.get_range(node)
    %{change: change, range: %{end: end_pos, start: start_pos}}
  end

  defp delete_patch(node) do
    %{} = range = Sourceror.get_range(node)
    %{change: "", range: range}
  end

  # --- small utils -----------------------------------------------------

  defp def_body({_kind, _, [_head, body_kw]}), do: do_body(body_kw)

  defp do_body(body_kw) when is_list(body_kw) do
    Enum.find_value(body_kw, nil, fn
      {{:__block__, _, [:do]}, value} -> value
      {:do, value} -> value
      _ -> nil
    end)
  end

  defp do_body(_), do: nil

  defp strip_all_meta(ast),
    do:
      Macro.prewalk(ast, fn
        {f, _m, a} -> {f, [], a}
        other -> other
      end)

  defp strip_comments(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        meta =
          meta
          |> Keyword.put(:leading_comments, [])
          |> Keyword.put(:trailing_comments, [])

        {form, meta, args}

      other ->
        other
    end)
  end
end
