defmodule Number42.Refactors.Ex.MergeClausesIntoCondOrGuard do
  @moduledoc """
  Collapses several `def`/`defp` clauses of the same function that
  differ **only** in a guard over the same bare-variable parameter(s)
  into one clause whose body is a `cond`.

      def label(n) when n < 0, do: "neg"
      def label(n) when n == 0, do: "zero"
      def label(n), do: "rest"
      ↓
      def label(n) do
        cond do
          n < 0 -> "neg"
          n == 0 -> "zero"
          true -> "rest"
        end
      end

  Each guard becomes a `cond` condition verbatim (guard syntax is a
  subset of valid expressions, so it stays valid as a `cond` clause
  head). The catch-all clause — a guard-less clause, or a `when true`
  clause — becomes the `true ->` branch.

  This is the inverse direction of `IfLiftToClauses`; its output is a
  single `def` whose body is a `cond`, which `IfLiftToClauses` won't
  touch (that one matches single-`if` bodies, not `cond`).

  ## Why a total fallback is mandatory

  A function with no matching clause raises `FunctionClauseError`. A
  `cond` with no matching branch raises `CondClauseError`. These are
  observably different. So we only emit a `cond` when we can supply a
  `true ->` branch derived from an EXISTING total fallback among the
  clauses. We never synthesize `true -> raise` — that would change
  behaviour. With no catch-all clause present, we SKIP.

  ## What merges

  A **contiguous run** of clauses at one `{visibility, name, arity}`
  where:

    * every clause is `def` or `defp` (never `defmacro`/`defmacrop`),
    * every clause's parameter list is the IDENTICAL list of bare
      variables (`def f(a, b)` everywhere — same names, same order),
    * each clause is either guarded by a single `when` expression or is
      the total fallback (guard-less, or `when true`),
    * exactly one total fallback exists and it is the LAST clause,
    * at least two clauses are present, and
    * the run is ALL the clauses of that name/arity in the module body
      (no sibling clauses elsewhere we can't account for).

  Multiple parameters are fine, as long as the bare-var list is
  identical across every clause.

  ## What we skip

    * **Pattern bindings.** `def f({:ok, v})` binds `v` via the head;
      `cond` can't. Any clause head with a non-bare-variable parameter
      (destructuring, literal, struct, `_`) makes the run unmergeable —
      SKIP the whole group.
    * **Differing param lists.** If the bare-var param lists aren't
      identical across all clauses, SKIP.
    * **No total fallback.** If none of the clauses is a guard-less /
      `when true` catch-all, emitting a `cond` would raise
      `CondClauseError` where the original raised `FunctionClauseError`
      — SKIP (we do not invent `true -> raise`).
    * **Interleaved siblings / non-contiguous clauses.** If clauses of
      the name/arity are split by another definition, or the run isn't
      a clean block of guard-only-differing clauses plus a trailing
      catch-all, SKIP. Conservative v1: require the clauses to be
      contiguous in the module body.
    * **Single clause.** Need ≥2 clauses to have anything to merge.
    * **`defmacro`/`defmacrop`.**
    * **Fallback not last.** A catch-all that isn't the final clause is
      shadowing later guarded clauses (dead code, or already a
      compile warning) — we don't reorder; SKIP.

  ## Idempotence

  After the merge the function is a single clause whose body is a
  `cond`. A second pass finds no guard-only clause SET (it needs ≥2
  clauses at the name/arity) and is a no-op.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description,
    do: "Merge guard-only-differing def clauses (with a total fallback) into one `cond`"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Several clauses of the same function that share an identical
    bare-variable head and differ only in their `when` guard are a
    `cond` written long-hand. Collapsing them into one clause with a
    `cond` body puts every condition next to its result, reads
    top-to-bottom, and removes the repeated function head. The rewrite
    is only safe when an existing catch-all supplies the `true ->`
    branch — otherwise a `cond` would raise `CondClauseError` where the
    clause list raised `FunctionClauseError`, so we skip.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> ast |> build_patches(source) |> apply_patches(source)
      {:error, _} -> source
    end
  end

  defp apply_patches([], source), do: source
  defp apply_patches(patches, source), do: Sourceror.patch_string(source, patches)

  defp build_patches(ast, source) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&module_patches(&1, source))
    # One merge per pass keeps the diff focused; the engine's fixpoint
    # loop re-runs until stable.
    |> Enum.take(1)
  end

  defp module_patches({:defmodule, _, [_name, [{_do, body}]]}, source) do
    exprs = body_to_exprs(body)

    exprs
    |> contiguous_def_runs()
    |> Enum.find_value([], fn run -> run_patch_or_nil(run, exprs, source) end)
  end

  defp module_patches(_, _), do: []

  # Group consecutive top-level def/defp expressions by {kind, name,
  # arity}. A run breaks when the next expression's key differs (or the
  # next expression isn't a def/defp at all). Non-def expressions split
  # runs so contiguity is enforced.
  defp contiguous_def_runs(exprs) do
    exprs
    |> Enum.map(&def_clause/1)
    |> chunk_by_key()
    |> Enum.filter(&(length(&1) >= 2))
  end

  defp chunk_by_key(tagged) do
    tagged
    |> Enum.chunk_while(
      [],
      fn
        {:def_clause, key, entry}, [] ->
          {:cont, [{key, entry}]}

        {:def_clause, key, entry}, [{prev_key, _} | _] = acc ->
          if key == prev_key,
            do: {:cont, [{key, entry} | acc]},
            else: {:cont, Enum.reverse(acc), [{key, entry}]}

        :other, [] ->
          {:cont, []}

        :other, acc ->
          {:cont, Enum.reverse(acc), []}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp def_clause({kind, _, [head, body_kw]} = node) when def_kind?(kind) and is_list(body_kw) do
    case extract_fn_signature(head) do
      {name, args} -> {:def_clause, {kind, name, length(args)}, {head, body_kw, node}}
      :error -> :other
    end
  end

  defp def_clause(_), do: :other

  # A run is `[{key, {head, body_kw}}, ...]` for one {kind, name, arity}.
  defp run_patch_or_nil(run, all_exprs, source) do
    [{key, _} | _] = run
    {kind, _name, _arity} = key

    with true <- only_run_for_key?(key, all_exprs, length(run)),
         {:ok, clauses} <- analyze_clauses(run),
         {:ok, param_text} <- identical_bare_params(clauses, source),
         {:ok, guarded, fallback} <- split_guarded_and_fallback(clauses) do
      replacement = render_merged(kind, fn_name(key), param_text, guarded, fallback)
      run_nodes = Enum.map(run, fn {_k, {_head, _body_kw, node}} -> node end)
      [merge_patch(run_nodes, replacement)]
    else
      _ -> nil
    end
  end

  defp fn_name({_kind, name, _arity}), do: name

  # The run must be EVERY clause of this key in the module body — no
  # sibling clause elsewhere we'd silently drop from dispatch.
  defp only_run_for_key?(key, all_exprs, run_len) do
    total =
      all_exprs
      |> Enum.map(&def_clause/1)
      |> Enum.count(fn
        {:def_clause, ^key, _} -> true
        _ -> false
      end)

    total == run_len
  end

  # For each clause: classify head as guarded or fallback, capture the
  # bare-var param patterns and the do-body. Any clause whose head isn't
  # a bare-var param list, or whose body isn't a single do-body, aborts
  # the whole run.
  defp analyze_clauses(run) do
    run
    |> Enum.reduce_while({:ok, []}, fn {_key, {head, body_kw, _node}}, {:ok, acc} ->
      case analyze_clause(head, body_kw) do
        {:ok, clause} -> {:cont, {:ok, [clause | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp analyze_clause(head, body_kw) do
    with {:ok, params, guard} <- split_head(head),
         true <- all_bare_vars?(params),
         {:ok, body} <- single_do_body(body_kw) do
      {:ok, %{params: params, guard: guard, body: body}}
    else
      _ -> :error
    end
  end

  defp split_head({:when, _, [inner, guard]}) do
    case inner do
      {name, _, args} when is_atom(name) and is_list(args) -> {:ok, args, guard}
      _ -> :error
    end
  end

  defp split_head({name, _, args}) when is_atom(name) and is_list(args),
    do: {:ok, args, nil}

  defp split_head(_), do: :error

  defp all_bare_vars?(params), do: Enum.all?(params, &match?({:ok, _}, bare_var(&1)))

  defp single_do_body(body_kw) do
    bodies =
      body_kw
      |> Enum.flat_map(fn
        {{:__block__, _, [:do]}, value} -> [value]
        {:do, value} -> [value]
        _ -> []
      end)

    case bodies do
      [body] -> {:ok, body}
      _ -> :error
    end
  end

  # Every clause's bare-var param list must be identical (same names,
  # same order). Returns the rendered param text for the merged head.
  defp identical_bare_params(clauses, source) do
    [%{params: first} | _] = clauses

    same? =
      clauses
      |> Enum.all?(fn %{params: params} -> param_names(params) == param_names(first) end)

    if same?, do: {:ok, render_params(first, source)}, else: :error
  end

  defp param_names(params), do: Enum.map(params, &elem(bare_var(&1), 1))

  defp render_params(params, source),
    do: params |> Enum.map_join(", ", &node_text(&1, source))

  # Partition into guarded clauses (single `when` expr) and exactly one
  # total fallback (guard-less, or `when true`). The fallback must be
  # the LAST clause — we don't reorder. At least one guarded clause must
  # remain (otherwise there's nothing to merge into a cond head).
  defp split_guarded_and_fallback(clauses) do
    {init, [last]} = Enum.split(clauses, -1)

    cond do
      Enum.any?(init, &fallback?/1) -> :error
      not fallback?(last) -> :error
      init == [] -> :error
      true -> {:ok, init, last}
    end
  end

  defp fallback?(%{guard: nil}), do: true
  defp fallback?(%{guard: guard}), do: when_true?(guard)

  defp when_true?({:__block__, _, [true]}), do: true
  defp when_true?(true), do: true
  defp when_true?(_), do: false

  defp render_merged(kind, name, param_text, guarded, fallback) do
    cond_clauses =
      Enum.map(guarded, fn %{guard: guard, body: body} ->
        "    #{render_guard(guard)} -> #{render_body(body)}"
      end)

    true_clause = "    true -> #{render_body(fallback.body)}"

    """
    #{kind} #{name}(#{param_text}) do
      cond do
    #{Enum.join(cond_clauses ++ [true_clause], "\n")}
      end
    end\
    """
  end

  defp render_guard(guard), do: Sourceror.to_string(guard)
  defp render_body(body), do: Sourceror.to_string(body)

  # Replace the run's whole source span (first clause `def` keyword →
  # last clause body end) with the single merged clause.
  defp merge_patch(run_nodes, replacement) do
    %{start: start_pos} = Sourceror.get_range(List.first(run_nodes))
    %{end: end_pos} = Sourceror.get_range(List.last(run_nodes))

    Patch.new(%{start: start_pos, end: end_pos}, replacement)
  end

  defp node_text(node, source) do
    case slice_node(source, node) do
      {:ok, text} -> text
      :error -> Sourceror.to_string(node)
    end
  end
end
