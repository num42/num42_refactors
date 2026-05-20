defmodule Number42.Refactors.Ex.IdentityPassthrough do
  @moduledoc """
  Removes `case` expressions whose every clause returns exactly the
  pattern it matched — a no-op rewrite of the scrutinee:

      case Jason.decode(response, keys: :atoms) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
      ↓
      Jason.decode(response, keys: :atoms)

  Mirrors `ExSlop.Check.Refactor.IdentityPassthrough`. Same logic
  conceptually applies to single-clause `case` bodies, but a
  single-clause `case` is *also* an assertion that the scrutinee
  matches that pattern — removing it weakens runtime checking.
  We only rewrite when there are two or more clauses, all
  identity-shaped.

  ## What we match

  - `case <expr> do <pat1> -> <pat1>; <pat2> -> <pat2>; ... end`
  - At least two clauses; every clause's body must equal its pattern
    after metadata stripping (so source-position differences don't
    block the match).
  - Each clause has exactly one pattern (no pattern-list, no `when`
    guard — guards filter the cases, so they aren't passthrough).

  ## Why we patch the whole `case` and not just clauses

  The whole expression collapses to its scrutinee. Patching only the
  body of each clause would leave a useless `case` around — and
  `mix format` won't elide it.

  ## Idempotence

  After the rewrite the `case` is gone — a second pass finds nothing
  to rewrite.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Remove `case` expressions where every clause is `pat -> pat`"

  @impl Number42.Refactors.Refactor
  def priority, do: 120

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A `case` in which every clause returns its own pattern is doing
    nothing — the value flows in unchanged. These usually accumulate
    over a refactor's lifetime: arms get deleted one by one until only
    pass-throughs remain, but the `case` scaffolding stays. Removing
    it reveals the actual data flow ("this is just `x`") and prevents
    the next reader from going hunting for which clause does the
    interesting work.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp has_when_guard?({:when, _, _}), do: true
  defp has_when_guard?(_), do: false

  defp identity_clause?({:->, _, [[pattern], body]}),
    do: not has_when_guard?(pattern) and strip(pattern) == strip(body)

  defp identity_clause?(_), do: false

  defp identity_passthrough?({:__block__, _, [clauses]}) when is_list(clauses),
    do: identity_passthrough?(clauses)

  defp identity_passthrough?([]), do: false
  defp identity_passthrough?([_]), do: false

  defp identity_passthrough?([_, _ | _] = clauses) when is_list(clauses) do
    clauses |> Enum.all?(&identity_clause?/1)
  end

  defp identity_passthrough?(_), do: false

  defp maybe_patch({:case, _, [scrutinee, [{_do_block, clauses}]]} = node) do
    if identity_passthrough?(clauses) do
      [Patch.replace(node, Sourceror.to_string(scrutinee))]
    else
      []
    end
  end

  defp maybe_patch(_), do: []

  defp strip(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
