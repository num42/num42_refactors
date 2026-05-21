defmodule Number42.Refactors.Ex.ListLastOfReverse do
  @moduledoc """
  Rewrites `List.last(Enum.reverse(list))` to `List.first(list)`.

  `List.last/1` is O(n) and `Enum.reverse/1` is O(n) — chaining them
  walks the list twice to reach the first element. `List.first/1` does
  it in one O(n) pass (and is O(1) on lists where the head is what you
  want, which it always is here).

  Mirrors the spirit of `ExSlop.Check.Refactor.ListLast`, but narrows
  the rewrite to the one shape where the replacement is mechanically
  obvious. Bare `List.last(x)` calls without the reverse wrapper need
  a human to restructure the data flow and are left alone.

  Source emission goes through `Sourceror.to_string/1`; `mix format`
  re-pipes after the refactor runs.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "List.last(Enum.reverse(list)) -> List.first(list)"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Reversing a list to grab its last element walks the whole list and
    allocates a fresh one, all to read the head of the original. The
    last element of `reverse(list)` is the first of `list` — `List.first`
    answers it in `O(1)` with no allocation. Beyond the runtime saving,
    "first of the original" matches the human description of what's
    being asked for.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 130
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

  defp maybe_patch(
         {{:., _, [{:__aliases__, _, [:List]}, :last]}, _,
          [{{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, [list]}]} = node
       ),
       do: [Patch.replace(node, "List.first(#{Sourceror.to_string(list)})")]

  defp maybe_patch(
         {:|>, _,
          [
            {:|>, _, [list, {{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, []}]},
            {{:., _, [{:__aliases__, _, [:List]}, :last]}, _, []}
          ]} = node
       ),
       do: [Patch.replace(node, "List.first(#{Sourceror.to_string(list)})")]

  defp maybe_patch(_), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
