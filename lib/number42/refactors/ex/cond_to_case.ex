defmodule Number42.Refactors.Ex.CondToCase do
  @moduledoc """
  Rewrites a `cond` whose every arm tests the **same variable** for
  equality against a literal into a `case` on that variable.

      cond do
        status == :pending -> "wartet"
        status == :active  -> "läuft"
        status == :done    -> "fertig"
        true               -> "unbekannt"
      end
      ↓
      case status do
        :pending -> "wartet"
        :active  -> "läuft"
        :done    -> "fertig"
        _        -> "unbekannt"
      end

  Each `var == literal` arm becomes a `pattern -> body` clause; the
  trailing `true ->` catch-all becomes `_ ->`. The arm bodies are kept
  verbatim.

  ## What fires

    * **Every** non-catch-all arm is `var == literal` (or the symmetric
      `literal == var`) over the **same** bare variable.
    * The right-hand side is a scalar literal that is a valid `case`
      pattern on its own — an atom, number, binary, `nil`, `true` or
      `false`.
    * At least one such equality arm is present.

  ## Catch-all and exhaustiveness

  A trailing `true ->` arm maps to `case`'s `_ ->`. When the `cond` has
  **no** `true ->` arm it is still rewritten: a `cond` with no matching
  arm raises `CondClauseError`, a `case` with no matching clause raises
  `CaseClauseError` — both raise, so the rewrite preserves the
  "no fall-through" behaviour. A non-final `true ->` (dead arms follow
  it) is left alone.

  ## Clause-form chaining (issue #38)

  The multi-clause-`def` target named in the issue
  (`defp label(:pending), do: …`) is **not** produced here. Emitting the
  `case` makes the body eligible for
  `Number42.Refactors.Ex.CaseToFunctionClauses` (#38), which performs the
  `case -> clauses` lift as a downstream pipeline step. This refactor is
  the upstream `cond -> case` half; keeping the two separate avoids
  duplicating the clause-rendering logic and its sibling-clause /
  scrutinee-rebinding safeguards.

  ## What we skip (real semantic change)

    * **Different variables** across arms (`a == 1 -> …; b == 2 -> …`).
      That is not single-variable dispatch — `case` cannot express it.
    * **Relational / range arms** (`x > 5 -> …`). `case` patterns are not
      predicates. These could become `when` guards, but mixing literal
      patterns and guards is out of scope for v1.
    * **A non-literal right-hand side** (`x == other_var`, `x == foo()`,
      `x == @attr`, `x == Mod.const`, `x == ^pinned`). It can't become a
      bare `case` pattern without a pin or guard — a bare variable RHS
      would silently turn into a catch-all binding.
    * **Composite-literal RHS** (tuples, lists, maps). A composite that
      *looks* literal can still embed a bare variable, which would become
      a binding pattern in `case`. Conservative blanket skip in v1.
    * **A function call in any test** (either operand). Evaluation order /
      short-circuit differs between `cond` and `case`.
    * **Duplicate literals** across arms. `case` would warn on the
      unreachable later clause and the arm ordering becomes significant —
      left alone rather than silently reordering semantics.
    * **A non-final `true ->`** arm (the arms after it are dead in the
      `cond` but the `case` translation would drop or reorder them).

  ## Idempotence

  The result is a `case`, not a `cond`, so a second pass finds no `cond`
  to match.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Rewrite a same-variable `==` `cond` as a `case` on that variable"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A `cond` whose every arm re-tests the same variable for equality is
    clause dispatch written as a predicate chain: the reader checks each
    `var == …` line to discover it is always the same `var`. A `case`
    states the dispatch variable once and lists the literals as patterns,
    which reads as the lookup table it is and lines the body up next to
    its key. It also opens the door to the multi-clause-`def` lift.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> ast |> build_patches() |> apply_patches(source)
      {:error, _} -> source
    end
  end

  defp apply_patches([], source), do: source
  defp apply_patches(patches, source), do: Sourceror.patch_string(source, patches)

  defp build_patches(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&maybe_patch/1)
  end

  defp maybe_patch({:cond, _meta, [[{_do_key, clauses}]]} = node) when is_list(clauses) do
    case analyze(clauses) do
      {:ok, scrutinee, pattern_clauses} ->
        [Patch.replace(node, render_case(scrutinee, pattern_clauses))]

      :error ->
        []
    end
  end

  defp maybe_patch(_), do: []

  # Walks the cond arms, decomposing each into either a `{:eq, var, literal,
  # body}` or the terminal `{:default, body}`. Returns the shared scrutinee
  # var and the list of rendered case clauses, or :error to skip.
  defp analyze(clauses) do
    with {:ok, parsed} <- parse_clauses(clauses),
         {:ok, scrutinee} <- single_scrutinee(parsed),
         :ok <- check_no_duplicate_literals(parsed) do
      {:ok, scrutinee, to_case_clauses(parsed)}
    end
  end

  # Each arm → {:eq, var, literal_ast, body} | {:default, body}. The
  # `true ->` arm is only allowed as the very last clause; anywhere else
  # it shadows the arms after it and we skip.
  defp parse_clauses(clauses) do
    last_index = length(clauses) - 1

    clauses
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {clause, idx}, {:ok, acc} ->
      case classify_clause(clause, idx == last_index) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, list} -> require_one_equality(Enum.reverse(list))
      :error -> :error
    end
  end

  defp require_one_equality(parsed) do
    if Enum.any?(parsed, &match?({:eq, _, _, _}, &1)),
      do: {:ok, parsed},
      else: :error
  end

  defp classify_clause({:->, _, [[condition], body]}, is_last?) do
    cond do
      default_arm?(condition) and is_last? -> {:ok, {:default, body}}
      default_arm?(condition) -> :error
      true -> classify_equality(condition, body)
    end
  end

  defp classify_clause(_, _is_last?), do: :error

  defp default_arm?({:__block__, _, [true]}), do: true
  defp default_arm?(true), do: true
  defp default_arm?(_), do: false

  # `var == literal` or `literal == var`, both operands free of calls.
  defp classify_equality({:==, _, [left, right]}, body) do
    cond do
      bare_var?(left) and case_literal?(right) -> {:ok, {:eq, var_name(left), right, body}}
      bare_var?(right) and case_literal?(left) -> {:ok, {:eq, var_name(right), left, body}}
      true -> :error
    end
  end

  defp classify_equality(_, _), do: :error

  defp bare_var?({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp bare_var?(_), do: false

  defp var_name({name, _meta, _ctx}), do: name

  # A scalar literal that is a valid `case` pattern as-is: atom (incl.
  # nil/true/false), number, or binary. Composite literals (tuples,
  # lists, maps) are skipped — a "literal-looking" composite can still
  # embed a bare variable, which would become a binding pattern in `case`.
  defp case_literal?({:__block__, _, [lit]}), do: scalar_literal?(lit)
  defp case_literal?(lit), do: scalar_literal?(lit)

  defp scalar_literal?(lit) when is_atom(lit) or is_number(lit) or is_binary(lit), do: true
  defp scalar_literal?(_), do: false

  defp single_scrutinee(parsed) do
    parsed
    |> Enum.flat_map(fn
      {:eq, var, _lit, _body} -> [var]
      {:default, _body} -> []
    end)
    |> Enum.uniq()
    |> case do
      [scrutinee] -> {:ok, scrutinee}
      _ -> :error
    end
  end

  # `case` warns on a later clause shadowed by an identical earlier pattern
  # and the arm order then carries meaning the `cond` didn't have. Skip.
  defp check_no_duplicate_literals(parsed) do
    literals =
      Enum.flat_map(parsed, fn
        {:eq, _var, lit, _body} -> [strip_meta(lit)]
        {:default, _body} -> []
      end)

    if literals == Enum.uniq(literals), do: :ok, else: :error
  end

  defp to_case_clauses(parsed) do
    Enum.map(parsed, fn
      {:eq, _var, literal, body} -> {pattern_of(literal), body}
      {:default, body} -> {wildcard(), body}
    end)
  end

  # The RHS literal is already a valid pattern AST; reuse it verbatim.
  defp pattern_of(literal), do: literal

  defp wildcard, do: {:_, [line: 1], nil}

  defp render_case(scrutinee, pattern_clauses) do
    clauses =
      Enum.map(pattern_clauses, fn {pattern, body} ->
        {:->, [line: 1], [[pattern], body]}
      end)

    scrutinee_node = {scrutinee, [line: 1], nil}
    case_meta = [do: [line: 1], end: [line: 1], line: 1]
    case_node = {:case, case_meta, [scrutinee_node, [{{:__block__, [], [:do]}, clauses}]]}
    Sourceror.to_string(case_node)
  end

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end
end
