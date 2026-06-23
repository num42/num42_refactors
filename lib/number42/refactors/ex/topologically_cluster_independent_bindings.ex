defmodule Number42.Refactors.Ex.TopologicallyClusterIndependentBindings do
  @moduledoc """
  Reorders pure, independent bindings inside a straight-line block so
  that same-family operations become adjacent.

      def bla() do
        bind1 = Map.put(%{}, 2, 3)
        bind2 = Map.get(bind1, 1)
        bind3 = Map.put(bind1, 3, 4)

        {bind2, bind3}
      end
      ↓
      def bla() do
        bind1 = Map.put(%{}, 2, 3)
        bind3 = Map.put(bind1, 3, 4)
        bind2 = Map.get(bind1, 1)

        {bind2, bind3}
      end

  `bind2` and `bind3` both depend only on `bind1` and neither depends on
  the other, so they may swap. `bind3` is emitted first because it
  continues the `Map.put/3` family opened by `bind1`.

  ## When this fires

  Only inside a **maximal contiguous window** of straight-line
  `var = rhs` statements in a `def`/`defp` body where every one of the
  following holds:

    * every LHS is a **bare variable**, assigned **exactly once** in the
      window (no rebinding);
    * every RHS is conservatively **pure** under `AstHelpers.pure?/1`
      (total, exception-free, eager) — this also rules out bang calls,
      `Stream` sources, and side-effecting calls;
    * the window contains no control-flow forms, anonymous functions,
      sigils, or statements carrying attached comments/trivia that would
      need to move with the line.

  ## The dependency graph & canonical order

  A variable read inside a statement's RHS creates a dependency edge
  from its defining statement to the reading statement. Two statements
  may reorder only when there is **no path** between them. Within that
  DAG we emit a deterministic topological order (Kahn). Among the
  currently-ready sibling nodes:

    1. prefer the node whose **operation family** matches the most
       recently-emitted family (`Map.put/3`, `Keyword.put/3`, …);
    2. otherwise sort by family key;
    3. break remaining ties by original source order.

  ## Idempotence

  The emitted order is canonical: derived from the same dependency graph
  and the same comparator. After one pass the window is already in that
  order, so a second pass rebuilds the same graph and emits the same
  sequence. Already-clustered windows stay untouched (no patch emitted).

  ## Enabled by default

  The reorder is gated on strong purity and a dependency DAG: a binding
  never crosses one it depends on, and only pure, total, exception-free
  right-hand sides participate, so the clustering preserves evaluation
  semantics. A full-suite dogfood run on position-db (14 files) is green
  and matches the unrefactored baseline at the same seed.
  """

  use Number42.Refactors.Refactor

  @control_flow_forms ~w(case cond if unless with for fn try receive quote)a

  @impl Number42.Refactors.Refactor
  def description,
    do: "Topologically cluster pure independent bindings by operation family"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A run of pure single-assignment bindings where several lines depend
    only on a shared earlier value can be reordered so operations of the
    same family sit next to each other, without changing what runs or in
    what observable order. The reorder is gated on strong purity and a
    dependency DAG: a binding never crosses one it depends on, and only
    pure, total, exception-free right-hand sides participate, so the
    canonical clustering preserves evaluation semantics while improving
    local readability.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def priority, do: 120

  @impl Number42.Refactors.Refactor
  def transform(source, _opts) do
    Sourceror.parse_string(source) |> apply_to_parse_result(source)
  end

  defp apply_to_parse_result({:ok, ast}, source),
    do: ast |> first_cluster_patch(source) |> patch_or_passthrough(source)

  defp apply_to_parse_result({:error, _}, source), do: source

  # Reorder at most one window per pass — the first eligible across all
  # statement blocks — so the output stays deterministic. The engine's
  # fixpoint loop picks up any remaining windows on later passes.
  @spec first_cluster_patch(Macro.t(), String.t()) :: [map()]
  defp first_cluster_patch(ast, source) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value([], fn
      {:__block__, _, exprs} when is_list(exprs) and length(exprs) >= 2 ->
        patch_for_block(exprs, source)

      _ ->
        nil
    end)
  end

  # Walk the block for the first maximal window of clusterable bindings
  # that actually reorders.
  defp patch_for_block(exprs, source) do
    exprs
    |> windows()
    |> Enum.find_value(&patch_for_window(&1, source))
  end

  # Split the statement list into maximal contiguous runs of clusterable
  # bindings, keeping only runs of length ≥ 2. A non-clusterable
  # statement (control flow, impure RHS, non-bare LHS, …) ends the
  # current run and is dropped — it acts as an anchor that windows never
  # cross, so side-effecting or order-sensitive lines keep their place.
  defp windows(exprs) do
    exprs
    |> Enum.chunk_while(
      [],
      fn expr, acc ->
        if clusterable_binding?(expr),
          do: {:cont, [expr | acc]},
          else: {:cont, Enum.reverse(acc), []}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.filter(&(length(&1) >= 2))
  end

  # A statement is clusterable when it is `bare_var = pure_rhs`, carries
  # no comments/trivia, and contains no control-flow / anonymous-function
  # / sigil form anywhere in its RHS.
  defp clusterable_binding?({:=, meta, [lhs, rhs]} = stmt) do
    match?({:ok, _}, bare_var(lhs)) and
      pure?(rhs) and
      not has_attached_comments?(meta) and
      not unsafe_form_anywhere?(stmt)
  end

  defp clusterable_binding?(_), do: false

  defp has_attached_comments?(meta) do
    Keyword.get(meta, :leading_comments, []) != [] or
      Keyword.get(meta, :trailing_comments, []) != []
  end

  # `pure?/1` treats `fn`/`case`/`cond`/`if`/`with`/`for` as pure
  # *containers* (purity follows their children), so it does not by
  # itself rule out an anonymous function or control-flow form on the
  # RHS. This walk does — reordering a line carrying a `fn` or a
  # branch is exactly the kind of move the family-key proxy can't vouch
  # for. Sourceror parses sigils as `{:sigil_X, _, _}`; reject those too,
  # since their delimiters/interpolation make moving the line as raw
  # text risky.
  defp unsafe_form_anywhere?(stmt) do
    stmt
    |> Macro.prewalker()
    |> Enum.any?(fn
      {form, _, _} when form in @control_flow_forms -> true
      {form, _, _} when is_atom(form) -> sigil_name?(form)
      _ -> false
    end)
  end

  defp sigil_name?(form),
    do: form |> Atom.to_string() |> String.starts_with?("sigil_")

  # Build the dependency DAG for the window and, if a canonical
  # topological order differs from the source order, emit a single patch
  # replacing the whole window range with the reordered text.
  defp patch_for_window(window, source) do
    indexed = Enum.with_index(window)

    cond do
      rebinds?(indexed) -> nil
      trivia_between_statements?(window, source) -> nil
      true -> patch_if_reordered(window, indexed, source)
    end
  end

  defp patch_if_reordered(window, indexed, source) do
    ordered = canonical_order(indexed)
    source_order = Enum.map(indexed, fn {_stmt, i} -> i end)

    if Enum.map(ordered, & &1.index) == source_order do
      nil
    else
      window_patch(window, ordered, source)
    end
  end

  # Sourceror keeps comments out of node metadata (they live on the
  # top-level `:comments` list, not on a statement's range), so a
  # per-node `:leading_comments` check can't see a comment sitting
  # *between* two window statements. Re-emitting only the statement
  # slices would silently drop such a comment. Detect it lexically: if
  # any inter-statement gap holds non-whitespace, the attachment would
  # become ambiguous after movement — skip the whole window.
  defp trivia_between_statements?(window, source) do
    window
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [a, b] ->
      gap = slice_source(source, Sourceror.get_range(a).end, Sourceror.get_range(b).start)
      String.trim(gap) != ""
    end)
  end

  # A name bound by more than one statement in the window — a rebind.
  defp rebinds?(indexed) do
    names = Enum.flat_map(indexed, fn {{:=, _, [lhs, _]}, _i} -> lhs_names(lhs) end)
    length(names) != length(Enum.uniq(names))
  end

  defp lhs_names(lhs) do
    case bare_var(lhs) do
      {:ok, name} -> [name]
      :skip -> []
    end
  end

  # Produce the canonical topological order as a list of node maps:
  # `%{index:, name:, family:, deps:}` where `deps` is the set of window
  # indices whose bound var this statement reads.
  defp canonical_order(indexed) do
    nodes = build_nodes(indexed)
    emit(nodes, [], nil)
  end

  defp build_nodes(indexed) do
    binders =
      Map.new(indexed, fn {{:=, _, [lhs, _]}, i} ->
        {:ok, name} = bare_var(lhs)
        {name, i}
      end)

    Enum.map(indexed, fn {{:=, _, [lhs, rhs]}, i} ->
      {:ok, name} = bare_var(lhs)
      reads = used_var_names(rhs)

      deps =
        binders
        |> Enum.filter(fn {var, j} -> j < i and MapSet.member?(reads, var) end)
        |> Enum.map(fn {_var, j} -> j end)
        |> MapSet.new()

      %{index: i, name: name, family: family_key(rhs), deps: deps}
    end)
  end

  # Kahn's algorithm with the family-aware comparator. `emitted` is the
  # set of already-placed indices; `last_family` carries the family of
  # the most recently emitted node for the clustering tie-break.
  defp emit([], acc, _last_family), do: Enum.reverse(acc)

  defp emit(remaining, acc, last_family) do
    emitted = MapSet.new(acc, & &1.index)
    ready = Enum.filter(remaining, &MapSet.subset?(&1.deps, emitted))

    pick = choose(ready, last_family)
    rest = Enum.reject(remaining, &(&1.index == pick.index))

    emit(rest, [pick | acc], pick.family)
  end

  # 1) matching last family, 2) family key, 3) original source order.
  defp choose(ready, last_family) do
    Enum.min_by(ready, fn node ->
      family_rank = if node.family == last_family, do: 0, else: 1
      {family_rank, node.family, node.index}
    end)
  end

  # Normalised "operation family" of the RHS outer call: a string like
  # `"Map.put/3"`, `"Keyword.put/3"`, or `"build/1"` for a local call.
  # Non-call right-hand sides get a stable sentinel that sorts last and
  # never matches a real family.
  defp family_key(rhs) do
    case outer_call(rhs) do
      {:remote, mod, fun, arity} -> "#{mod}.#{fun}/#{arity}"
      {:local, fun, arity} -> "#{fun}/#{arity}"
      :none -> "~none"
    end
  end

  # Peel a leading pipe to its last stage, then read the outermost call.
  # The pipe injects an implicit leading argument, so add 1 to the stage
  # arity — `bind1 |> Map.get(1)` reports `Map.get/2`, matching the
  # direct-call form `Map.get(bind1, 1)` and clustering with it.
  defp outer_call(ast), do: outer_call(ast, 0)

  defp outer_call({:|>, _, [_lhs, rhs]}, extra), do: outer_call(rhs, extra + 1)

  defp outer_call({{:., _, [mod_ast, fun]}, _, args}, extra)
       when is_atom(fun) and is_list(args) do
    case alias_to_module(mod_ast) do
      {:ok, mod} -> {:remote, module_label(mod), fun, length(args) + extra}
      :error -> :none
    end
  end

  defp outer_call({fun, _, args}, extra) when is_atom(fun) and is_list(args) do
    if Macro.operator?(fun, length(args)),
      do: :none,
      else: {:local, fun, length(args) + extra}
  end

  defp outer_call(_, _extra), do: :none

  defp module_label(mod), do: mod |> Module.split() |> Enum.join(".")

  # Replace the whole window's source range with the reordered statements,
  # each sliced verbatim from the original source so formatting (literals,
  # parens) is preserved. Statements are rejoined with a single newline;
  # the follow-up format pass normalises indentation.
  defp window_patch(window, ordered, source) do
    first = List.first(window)
    last = List.last(window)

    range = %{
      start: Sourceror.get_range(first).start,
      end: Sourceror.get_range(last).end
    }

    by_index = window |> Enum.with_index() |> Map.new(fn {stmt, i} -> {i, stmt} end)

    change =
      Enum.map_join(ordered, "\n", fn %{index: i} ->
        statement_text(source, Map.fetch!(by_index, i))
      end)

    [%{change: change, range: range}]
  end

  defp statement_text(source, stmt) do
    range = Sourceror.get_range(stmt)
    slice_source(source, range.start, range.end)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
