defmodule Number42.Refactors.Ex.RemoveTrivialElseClause do
  @moduledoc """
  Removes `else` clauses on `with` expressions that just propagate the
  error tag verbatim — the `else` is doing nothing the implicit
  fall-through wouldn't do.

  ## Antipattern

      with {:ok, x} <- foo(),
           {:ok, y} <- bar(x) do
        {:ok, y}
      else
        {:error, e} -> {:error, e}
      end

  ## Replacement

      with {:ok, x} <- foo(),
           {:ok, y} <- bar(x) do
        {:ok, y}
      end

  ## Why

  When every `else` arm matches some pattern and returns the bound
  value unchanged (`{:error, e} -> {:error, e}`, `:error -> :error`),
  the `else` block is a no-op: dropping it makes `with` use its default
  fall-through, which produces the same result. Keeping the `else` adds
  visual weight without changing behavior, and obscures the cases where
  an `else` *does* do work (transform, log, branch).

  ## Edge cases to handle in implementation

  - **Trivial-else detection**: an arm is trivial iff every `<-` clause
    in the chain produces only tags that the `else` arm's pattern
    matches by binding-and-returning. The simplest case is
    `{:error, e} -> {:error, e}` — same shape, same name. More
    complex: `e -> e` (catch-any).
  - **Mixed clauses**: an `else` with both trivial *and* non-trivial
    arms must keep the whole `else`. We can't drop one arm without
    changing semantics for the matches it would have caught.
  - **Catch-all `_ -> ...`**: if `_` returns something different from
    what would fall through, it's not trivial. Only `_ -> _` (binding
    and re-emitting) qualifies, which is rare.
  - **Single-clause `with`**: defer to `WithSingleClauseToCase`. If
    that refactor runs first, this one shouldn't see those cases.

  ## Status

  Stub — `transform/2` is a no-op until the implementation lands.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Remove identity-only `else` clauses from `with` expressions"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A `with ... else` whose every clause just rebinds and returns the
    matched value (`{:error, e} -> {:error, e}`) is reproducing the
    default fall-through `with` already gives. Removing it shrinks the
    block and reserves the `else` keyword for the cases where the
    failure path actually does something — transform a tag, log,
    branch. As a bonus, the resulting `with` now matches the codebase's
    "no else needed" pattern used by csv_import, configurator, etc.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 120
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)
  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp else_clauses_or_default({:ok, clauses}) when is_list(clauses) do
    {:ok, clauses}
  end

  defp else_clauses_or_default(:error), do: {:ok, []}
  defp else_clauses_or_default(_), do: :error
  defp fetch_else(keyword), do: fetch_keyword(keyword, :else) |> else_clauses_or_default()

  defp fetch_keyword(keyword, key) do
    keyword
    |> Enum.find_value(:error, fn
      {{:__block__, _, [^key]}, value} -> {:ok, value}
      {^key, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp maybe_patch({:with, _meta, clauses} = node) when is_list(clauses) do
    {kw, head_clauses} = split_keyword(clauses)

    with {:ok, else_clauses} <- fetch_else(kw),
         true <- else_clauses != [],
         true <- Enum.all?(else_clauses, &trivial_arm?/1),
         {:ok, do_body} <- fetch_keyword(kw, :do) do
      [Patch.replace(node, render_with_no_else(head_clauses, do_body))]
    else
      _ -> []
    end
  end

  defp maybe_patch(_), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  defp render_with_no_else(head_clauses, do_body) do
    with_meta = [do: [line: 1], end: [line: 1]]
    with_ast = {:with, with_meta, head_clauses ++ [[{{:__block__, [], [:do]}, do_body}]]}
    Sourceror.to_string(with_ast)
  end

  defp split_keyword(clauses), do: List.last(clauses) |> split_off_keyword(clauses)

  defp split_off_keyword(kw, clauses) when is_list(kw) do
    {kw, clauses |> Enum.drop(-1)}
  end

  defp split_off_keyword(_, clauses), do: {[], clauses}

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp trivial_arm?({:->, _, [[pattern], body]}), do: strip_meta(pattern) == strip_meta(body)
  defp trivial_arm?(_), do: false
end
