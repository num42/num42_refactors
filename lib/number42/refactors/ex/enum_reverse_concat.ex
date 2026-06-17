defmodule Number42.Refactors.Ex.EnumReverseConcat do
  @moduledoc """
  Folds `Enum.reverse(a) ++ b` into the two-arg `Enum.reverse(a, b)`
  form, which both reverses `a` and appends `b` in a single pass:

      Enum.reverse(a) ++ b              →  Enum.reverse(a, b)
      a |> Enum.reverse() ++ b          →  a |> Enum.reverse(b)

  ## Why this is real, not just style

  `Enum.reverse/1` builds a fully-reversed copy of `a`; `++/2` then
  walks that copy front-to-back, allocating fresh cons cells for every
  element. Total work: 2n list operations and 2n allocations.

  `Enum.reverse/2` does both jobs in one fold: it walks `a`, prepending
  each element onto `b`, ending with the reversed-and-appended list.
  Total work: n operations, n allocations. The behaviour is exactly
  the same.

  Mirrors Quokka's `Style.Pipes` rewrite.

  ## What we match

  - `Enum.reverse(a) ++ b` (direct call, then ++)
  - `a |> Enum.reverse() ++ b` (pipe form ending in `Enum.reverse`/0)

  ## What we skip

  - `a ++ Enum.reverse(b)` — different operation; the right-side
    reverse can't be folded into a left-side call.
  - `Enum.reverse(a, b)` — already in the target form.
  - `List.reverse(a) ++ b` — `List.reverse`/1 doesn't exist with this
    semantic; we don't touch other modules.

  ## Idempotence

  After the rewrite the AST is `Enum.reverse(a, b)` — no `++` to match.
  Second pass is a no-op.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Enum.reverse(a) ++ b -> Enum.reverse(a, b)"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `Enum.reverse/1` followed by `++/2` walks the list twice and
    allocates two list copies; `Enum.reverse/2` does both jobs
    (reverse + append) in a single fold with one allocation per
    element. Same observable behaviour, half the work.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 130
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)
  @impl Number42.Refactors.Refactor
  def patches(ast, _source, _opts), do: build_patches(ast)

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp maybe_patch(
         {:++, _,
          [
            {{:., dm, [{:__aliases__, am, [:Enum]}, :reverse]}, cm, [coll]},
            tail
          ]} = node
       ) do
    replacement = {{:., dm, [{:__aliases__, am, [:Enum]}, :reverse]}, cm, [coll, tail]}
    [Patch.replace(node, render_clean(replacement))]
  end

  defp maybe_patch(
         {:|>, pm,
          [
            lhs,
            {:++, _,
             [
               {{:., dm, [{:__aliases__, am, [:Enum]}, :reverse]}, cm, []},
               tail
             ]}
          ]} = node
       ) do
    replacement =
      {:|>, pm, [lhs, {{:., dm, [{:__aliases__, am, [:Enum]}, :reverse]}, cm, [tail]}]}

    [Patch.replace(node, render_clean(replacement))]
  end

  defp maybe_patch(_), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
  defp render_clean(ast), do: ast |> strip_comments() |> Sourceror.to_string()

  defp strip_comments(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        {form, meta |> Keyword.put(:leading_comments, []) |> Keyword.put(:trailing_comments, []),
         args}

      other ->
        other
    end)
  end
end
