defmodule Number42.Refactors.Ex.CanonicalStatementOrder do
  @moduledoc """
  Reorders independent statements inside a `def`/`defp` body into a
  deterministic **canonical order**, so two bodies that differ only in
  the ordering of order-independent statements collapse to the same
  shape — and the same normalized-AST fingerprint.

      def f(input) do
        c = build_c(input)
        a = build_a(input)
        b = build_b(input)

        {a, b, c}
      end
      ↓  (canonical order, hash-driven)
      def f(input) do
        a = build_a(input)
        b = build_b(input)
        c = build_c(input)

        {a, b, c}
      end

  ## Why

  Clone detectors like `DelegateExactDuplicates` decide "same function"
  via a normalized-AST fingerprint (`clauses |> Enum.map(&normalize/1)
  |> :erlang.phash2()`). The fingerprint is **order-sensitive**: a
  statement list `[a, b]` hashes differently from `[b, a]`. Two
  functions with the same statements in a different order are therefore
  *not* recognised as clones. Running this refactor first (higher
  `priority/0`) canonicalises the order so the detector finds them.

  ## The canonical order

  Within a reorderable segment we build a dependency DAG and emit a
  deterministic topological order (Kahn's algorithm). Among the
  currently-ready nodes we always pick the one with the smallest
  **canonical key**:

    1. `:erlang.phash2(normalize_for_sort(stmt))` — a variable-name
       *independent* fingerprint (meta stripped + positional variable
       renaming). Two statements that do the same work under different
       variable names get the same hash, so the order does not depend
       on incidental naming.
    2. `Sourceror.to_string(strip_meta(stmt))` lexicographically — a
       total tie-break for genuine hash collisions.
    3. the statement's original index — the final, always-unique
       fallback.

  The three-stage key is a **total order**, which makes the topological
  output unique and therefore idempotent: a second pass rebuilds the
  same graph and emits the same sequence.

  ## Correctness foundation — the dependency DAG

  For every statement we compute what it **defs** (binds) and **reads**
  (uses), then add an edge `Si → Sj` (Si before Sj) when:

    * **RAW** — `Sj` reads a variable `Si` defines;
    * **WAW** — `Sj` redefines a variable `Si` defines;
    * **WAR** — `Sj` defines a variable `Si` reads.

  Rebinding is handled correctly: `socket = f(socket)` both reads and
  writes `socket`, so a run of `socket = ...` statements forms a hard
  chain that never reorders. Destructuring patterns (`{a, b} = …`,
  `%S{x: y} = …`) contribute every bound name via
  `AstHelpers.pattern_var_names/1`.

  **Side-effect ordering**: two statements that are not provably pure
  (`AstHelpers.pure?/1` is the negative filter) may have observable
  side effects, so their relative source order is pinned with an extra
  edge — even when they are data-independent. Conservative by design:
  anything not provably pure is treated as effectful.

  ## Barriers and segmentation

  Statements that cannot be safely modelled are **barriers**: they stay
  fixed in place and split the body into independent segments that are
  sorted on their own. Barriers are:

    * control-flow / block forms (`case`, `cond`, `if`, `unless`,
      `with`, `for`, `try`, `receive`, `fn`, `quote`, `unquote`)
      anywhere in the statement;
    * a pin `^x` in a match LHS, or a dynamic (non-static) map/struct
      key in a pattern — its def-use is not cleanly determinable.

  The **last statement of the whole body** (the return value) is always
  treated as a fixed barrier — never sorted forward.

  ## Default-OFF (opt-in only)

  Disabled by default — `transform/2` is a no-op unless its own opts
  carry `enabled: true`. Statement reordering is heavyweight and
  judgement-laden; opt in per project:

      configured_modules: [
        {Number42.Refactors.Ex.CanonicalStatementOrder,
         enabled: true, min_block_statements: 3}
      ]

  ## Source slicing

  Each statement's original source bytes are sliced verbatim
  (`AstHelpers.slice_source/3`) and reassembled in canonical order as a
  single Sourceror patch over the segment's range. Re-rendering via
  `Sourceror.to_string/1` would corrupt string escapes and pipe shape —
  slicing preserves the user's exact formatting; the follow-up
  `mix format` pass normalises indentation.
  """

  use Number42.Refactors.Refactor

  @default_min_block_statements 3

  @control_flow_forms ~w(case cond if unless with for fn try receive quote unquote)a

  @impl Number42.Refactors.Refactor
  def description,
    do: "Reorder independent statements into a canonical, deterministic order (default-OFF)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Two functions that do the same work but list their order-independent
    statements differently hash differently under the clone detectors'
    order-sensitive AST fingerprint, so they are never recognised as
    clones. This refactor builds a def-use + side-effect dependency DAG
    over a function body's top-level statements and emits a deterministic
    canonical topological order: a statement never crosses one it depends
    on, effectful statements keep their relative order, and the tie-break
    is a variable-name-independent hash. Running before the detectors
    collapses such near-clones into identical form. The reorder is gated
    on a conservative purity + dependency analysis, so it preserves
    evaluation semantics while making structure comparable.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 300

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      min = Keyword.get(opts, :min_block_statements, @default_min_block_statements)
      Sourceror.parse_string(source) |> apply_to_parse_result(source, min)
    else
      source
    end
  end

  defp apply_to_parse_result({:ok, ast}, source, min),
    do: ast |> first_body_patch(source, min) |> patch_or_passthrough(source)

  defp apply_to_parse_result({:error, _}, source, _min), do: source

  # Reorder at most one def body per pass — the first that actually
  # reorders — so output stays deterministic. The engine's fixpoint loop
  # picks up the rest on later passes.
  @spec first_body_patch(Macro.t(), String.t(), pos_integer()) :: [map()]
  defp first_body_patch(ast, source, min) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value([], fn
      {kind, _, [_head, body_kw]} when def_kind?(kind) ->
        patch_for_def_body(body_kw, source, min)

      _ ->
        nil
    end)
  end

  defp patch_for_def_body(body_kw, source, min) do
    with {:ok, body} <- fetch_do_body(body_kw),
         exprs when length(exprs) >= min <- body_to_exprs(body) do
      patch_for_statements(exprs, source)
    else
      _ -> nil
    end
  end

  # The trailing statement (return value) is pinned. Reorder only the
  # leading statements, segmented at barriers.
  defp patch_for_statements(exprs, source) do
    {leading, _return} = Enum.split(exprs, -1)

    leading
    |> Enum.with_index()
    |> segments()
    |> Enum.find_value(&segment_patch(&1, source))
  end

  # Split the indexed leading statements into maximal runs of
  # reorderable statements, breaking at every barrier. A barrier is
  # dropped from the runs — it stays fixed in place.
  defp segments(indexed) do
    indexed
    |> Enum.chunk_while(
      [],
      fn {stmt, _i} = entry, acc ->
        if barrier?(stmt),
          do: {:cont, Enum.reverse(acc), []},
          else: {:cont, [entry | acc]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.filter(&(length(&1) >= 2))
  end

  # A statement is a barrier when it contains a control-flow / block
  # form anywhere, or a match whose LHS pattern can't be safely modelled
  # (pin operator, dynamic key).
  defp barrier?(stmt), do: control_flow_anywhere?(stmt) or unsafe_match?(stmt)

  defp control_flow_anywhere?(stmt) do
    stmt
    |> Macro.prewalker()
    |> Enum.any?(fn
      {form, _, _} when form in @control_flow_forms -> true
      _ -> false
    end)
  end

  # Match statements whose LHS carries a pin (`^x`) or a non-static
  # (interpolated / variable) map or struct key — def-use isn't cleanly
  # determinable, so we treat the whole statement as a barrier.
  defp unsafe_match?({:=, _, [lhs, _rhs]}), do: unsafe_pattern?(lhs)
  defp unsafe_match?(_), do: false

  defp unsafe_pattern?(lhs) do
    lhs
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:^, _, _} -> true
      {:%{}, _, pairs} when is_list(pairs) -> Enum.any?(pairs, &dynamic_key?/1)
      _ -> false
    end)
  end

  defp dynamic_key?({key, _value}), do: not static_key?(key)

  defp static_key?({:__block__, _, [atom]}) when is_atom(atom), do: true
  defp static_key?(atom) when is_atom(atom), do: true
  defp static_key?(_), do: false

  defp segment_patch(segment, source) do
    nodes = build_nodes(segment)
    ordered = canonical_order(nodes)
    source_order = Enum.map(segment, fn {_stmt, i} -> i end)

    cond do
      Enum.map(ordered, & &1.index) == source_order -> nil
      trivia_between_statements?(segment, source) -> nil
      true -> segment_reorder_patch(segment, ordered, source)
    end
  end

  # Build one node per statement: original index, the names it defs and
  # reads, whether it is impure, plus its canonical sort key.
  defp build_nodes(segment) do
    Enum.map(segment, fn {stmt, i} ->
      %{
        index: i,
        defs: stmt_defs(stmt),
        reads: stmt_reads(stmt),
        impure: not pure_statement?(stmt),
        key: canonical_key(stmt, i)
      }
    end)
  end

  # Names this statement binds. For an assignment, the LHS pattern's
  # vars (handles destructuring); otherwise nothing (a bare call binds
  # nothing).
  defp stmt_defs({:=, _, [lhs, _rhs]}), do: MapSet.new(pattern_var_names(lhs))
  defp stmt_defs(_), do: MapSet.new()

  # Names this statement reads. For an assignment, only the RHS counts
  # as a read — names on the LHS are bindings, except a self-rebind
  # (`socket = f(socket)`) where the RHS legitimately reads `socket`.
  # The RHS walk via `used_var_names/1` captures exactly that.
  defp stmt_reads({:=, _, [_lhs, rhs]}), do: used_var_names(rhs)
  defp stmt_reads(stmt), do: used_var_names(stmt)

  defp pure_statement?({:=, _, [_lhs, rhs]}), do: pure?(rhs)
  defp pure_statement?(stmt), do: pure?(stmt)

  # Canonical, total sort key — variable-name independent hash first,
  # then a structural string, then the original index.
  defp canonical_key(stmt, index) do
    normalized = normalize_for_sort(stmt)
    {:erlang.phash2(normalized), Sourceror.to_string(normalized), index}
  end

  # Strip meta and rename variables positionally so the key does not
  # depend on incidental variable names — mirrors the clone detector's
  # normalization, which is what we are trying to align with.
  defp normalize_for_sort(stmt), do: stmt |> strip_meta() |> rename_vars()

  # Kahn's algorithm over the dependency DAG. At each step pick the
  # ready node with the smallest canonical key.
  defp canonical_order(nodes) do
    emit(nodes, [])
  end

  defp emit([], acc), do: Enum.reverse(acc)

  defp emit(remaining, acc) do
    pick =
      remaining
      |> Enum.filter(&ready?(&1, remaining))
      |> Enum.min_by(& &1.key)

    rest = Enum.reject(remaining, &(&1.index == pick.index))
    emit(rest, [pick | acc])
  end

  # A node is ready when no *other still-unemitted* node must precede
  # it. Once a predecessor is picked it leaves `remaining`, so "ready"
  # reduces to "no remaining node is a predecessor of this one".
  # `depends_on?/2` covers data hazards (RAW/WAW/WAR) and side-effect
  # ordering between impure statements.
  defp ready?(node, remaining) do
    remaining
    |> Enum.filter(&(&1.index != node.index))
    |> Enum.all?(&(not depends_on?(node, &1)))
  end

  # Does `node` depend on `other` (must `other` come first)? Only when
  # `other` is *earlier* in source — the dependency edges are oriented
  # by original position, which keeps the relation a DAG.
  defp depends_on?(node, other) do
    other.index < node.index and
      (data_hazard?(node, other) or effect_order?(node, other))
  end

  # RAW: node reads what other defines. WAW: both define the same name.
  # WAR: node defines what other reads.
  defp data_hazard?(node, other) do
    not MapSet.disjoint?(node.reads, other.defs) or
      not MapSet.disjoint?(node.defs, other.defs) or
      not MapSet.disjoint?(node.defs, other.reads)
  end

  # Two effectful statements keep their relative source order.
  defp effect_order?(node, other), do: node.impure and other.impure

  # Sourceror keeps comments off node metadata, so a comment sitting
  # *between* two segment statements is invisible to a per-node check.
  # Re-emitting only the statement slices would silently drop it; detect
  # it lexically and skip the whole segment if any inter-statement gap
  # holds non-whitespace.
  defp trivia_between_statements?(segment, source) do
    segment
    |> Enum.map(fn {stmt, _i} -> stmt end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [a, b] ->
      with %{end: a_end} <- Sourceror.get_range(a),
           %{start: b_start} <- Sourceror.get_range(b) do
        String.trim(slice_source(source, a_end, b_start)) != ""
      else
        _ -> true
      end
    end)
  end

  # Replace the segment's whole source range with the canonically
  # ordered statements, each sliced verbatim. Rejoined with newlines;
  # the format pass normalises indentation.
  defp segment_reorder_patch(segment, ordered, source) do
    stmts = Enum.map(segment, fn {stmt, _i} -> stmt end)
    first = List.first(stmts)
    last = List.last(stmts)

    with %{start: start_pos} <- Sourceror.get_range(first),
         %{end: end_pos} <- Sourceror.get_range(last) do
      by_index = Map.new(segment, fn {stmt, i} -> {i, stmt} end)

      change =
        Enum.map_join(ordered, "\n", fn %{index: i} ->
          statement_text(source, Map.fetch!(by_index, i))
        end)

      [%{change: change, range: %{end: end_pos, start: start_pos}}]
    else
      _ -> []
    end
  end

  defp statement_text(source, stmt) do
    case slice_node(source, stmt) do
      {:ok, text} -> text
      :error -> ""
    end
  end

  defp fetch_do_body(body_kw) do
    body_kw
    |> Enum.find_value(:error, fn
      {{:__block__, _, [:do]}, value} -> {:ok, value}
      {:do, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp rename_vars(ast) do
    {result, _map} = Macro.prewalk(ast, %{}, &rename_var_node/2)
    result
  end

  defp rename_var_node({name, [], ctx} = node, acc)
       when is_atom(name) and is_atom(ctx) do
    cond do
      underscore?(name) ->
        {node, acc}

      Map.has_key?(acc, name) ->
        {{:"$var", [], [Map.fetch!(acc, name)]}, acc}

      true ->
        idx = map_size(acc)
        {{:"$var", [], [idx]}, Map.put(acc, name, idx)}
    end
  end

  defp rename_var_node(node, acc), do: {node, acc}

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
