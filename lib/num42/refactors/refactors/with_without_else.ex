defmodule Num42.Refactors.Refactors.WithWithoutElse do
  @moduledoc """
  Drops `with ... else (clause -> clause)` blocks where the `else` is
  redundant: every `<-` clause's failure tag matches the corresponding
  `else` arm pattern, AND each `else` arm just rebinds and re-emits.

  Closely related to `RemoveTrivialElseClause` — both delete trivial
  `else` blocks. The split exists to draw the focus boundary clearly:

    * `RemoveTrivialElseClause` looks at the `else` block alone.
      A `{:error, e} -> {:error, e}` arm is trivial regardless of
      what the `<-` chain produces; the rewrite is purely structural.

    * `WithWithoutElse` looks at the **chain → else relationship**.
      An `else` may have arms that aren't structurally trivial in
      isolation but are redundant *given what the chain emits*. E.g.

          with :ok <- compatible_units?(...) do
            {:ok, row}
          end

      vs.

          with :ok <- compatible_units?(...) do
            {:ok, row}
          else
            :error -> :error
          end

      Both produce identical output in every reachable branch — the
      `else` adds no behavior. `WithWithoutElse` proves that statically
      and removes the redundant block, even when the `else` arm shape
      doesn't match the structural-trivial heuristic.

  ## Antipattern (lib/my_app/reference_buildings/csv_import.ex:139-147 — already in canonical form)

      with :ok <- compatible_units?(a.article_number, a.unit, b.unit) do
        {:ok, %Row{...}}
      end

  ## Antipattern variant we drop

      with :ok <- compatible_units?(a.article_number, a.unit, b.unit) do
        {:ok, %Row{...}}
      else
        :error -> :error
      end
      ↓ (replacement)
      with :ok <- compatible_units?(a.article_number, a.unit, b.unit) do
        {:ok, %Row{...}}
      end

  ## Why

  When the chain has been written precisely enough that its emitted
  failure values are exactly what the caller already expects (e.g. the
  caller treats `:error` and `{:error, _}` uniformly), the `else` block
  reproduces the default fall-through. Removing it leaves the `with`
  free of distractions — the reader sees only the happy path and
  trusts the chain to short-circuit on failure naturally.

  ## Edge cases to handle in implementation

  - **Cross-check chain emission against `else` arms**: each `<-`
    clause produces one or more failure shapes (the negation of its
    pattern). The `else` is redundant iff every shape the chain can
    emit on failure is matched by an arm that returns the matched
    value unchanged.
  - **Multiple `<-` clauses with overlapping failure tags**: when two
    clauses can produce the same failure tag, the `else` arm that
    matches it must be identity for *both* to qualify.
  - **`with` without any `<-` clauses**: out of scope (degenerate).
  - **Defer interaction**: `RemoveTrivialElseClause` should run first.
    What's left for this refactor is the strictly-structural-but-not-
    syntactically-identity case (`:error -> :error` where `:error` is
    the chain's only failure shape, etc.).

  ## Status

  Stub — `transform/2` is a no-op until the implementation lands.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Num42.Refactors.Refactor
  def description, do: "Drop redundant `else` blocks on `with` chains"

  @impl Num42.Refactors.Refactor
  def priority, do: 120

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    A `with ... else` whose `else` arms reproduce, value-for-value, the
    failure tags the chain already emits is dead weight. The reader
    spends focus parsing arms that change nothing. Removing the block
    leaves the `with` lean — happy path on screen, fall-through
    implicit, semantics unchanged.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp maybe_patch({:with, _meta, clauses} = node) when is_list(clauses) do
    {kw, head_clauses} = split_keyword(clauses)

    with {:ok, else_clauses} <- fetch_else(kw),
         true <- else_clauses != [],
         true <- Enum.all?(else_clauses, &redundant_arm?/1),
         {:ok, do_body} <- fetch_keyword(kw, :do) do
      [Patch.replace(node, render_with_no_else(head_clauses, do_body))]
    else
      _ -> []
    end
  end

  defp maybe_patch(_), do: []

  defp split_keyword(clauses), do: List.last(clauses) |> split_off_keyword(clauses)

  defp fetch_keyword(keyword, key) do
    keyword
    |> Enum.find_value(:error, fn
      {{:__block__, _, [^key]}, value} -> {:ok, value}
      {^key, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp fetch_else(keyword), do: fetch_keyword(keyword, :else) |> else_clauses_or_default()

  defp redundant_arm?({:->, _, [[pattern], body]}),
    do: structural_identity?(pattern, body) or alias_identity?(pattern, body)

  defp redundant_arm?(_), do: false

  defp structural_identity?(pattern, body), do: strip_meta(pattern) == strip_meta(body)

  # Matches `<some_pattern> = name -> name` — `=` aliases bind the whole
  # match to `name`, so re-emitting `name` is identity.
  defp alias_identity?({:=, _, [_lhs, {var, _, ctx}]}, {var, _, ctx})
       when is_atom(var) and is_atom(ctx),
       do: true

  defp alias_identity?({:=, _, [{var, _, ctx}, _rhs]}, {var, _, ctx})
       when is_atom(var) and is_atom(ctx),
       do: true

  defp alias_identity?(_, _), do: false

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp render_with_no_else(head_clauses, do_body) do
    with_meta = [do: [line: 1], end: [line: 1]]
    with_ast = {:with, with_meta, head_clauses ++ [[{{:__block__, [], [:do]}, do_body}]]}
    Sourceror.to_string(with_ast)
  end

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp split_off_keyword(kw, clauses) when is_list(kw) do
    {kw, clauses |> Enum.drop(-1)}
  end

  defp split_off_keyword(_, clauses), do: {[], clauses}

  defp else_clauses_or_default({:ok, clauses}) when is_list(clauses) do
    {:ok, clauses}
  end

  defp else_clauses_or_default(:error), do: {:ok, []}

  defp else_clauses_or_default(_), do: :error

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
