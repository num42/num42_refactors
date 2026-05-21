defmodule Number42.Refactors.Ex.EnumMapIntoToMapNew do
  @moduledoc """
  Rewrites `Enum.map(coll, fun) |> Enum.into(%{})` (and the nested
  call equivalent) to `Map.new(coll, fun)`.

  Mirrors `ExSlop.Check.Refactor.MapIntoLiteral`. The chained form
  walks the input twice — once to map, once to insert into the map.
  `Map.new/2` does both in one pass and reads as a single intent.

  Fires only when the accumulator is the empty-map AST literal
  (`{:%{}, _, []}`); `Enum.into/2` with a non-empty map merges into
  the existing map and is **not** equivalent.

  Both surface forms (`coll |> Enum.map(fun) |> Enum.into(%{})` and
  `Enum.into(Enum.map(coll, fun), %{})`) are matched separately
  because they parse to different AST shapes.

  Source emission goes through `Sourceror.to_string/1`; `mix format`
  re-pipes after the refactor runs.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Enum.map(coll, fun) |> Enum.into(%{}) -> Map.new(coll, fun)"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A `map`-then-`into` pipeline walks the collection twice and
    materialises an intermediate list just to throw it away. `Map.new/2`
    folds the two steps into one pass with no temporary list. The
    reader also gains: instead of "transform every element, then
    collect into a map" the line says "build a map by transforming
    each element" — the same thing in fewer words.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 140
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
         {{:., _, [{:__aliases__, _, [:Enum]}, :into]}, _,
          [
            {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [coll, fun]},
            {:%{}, _, []}
          ]} = node
       ),
       do: [
         Patch.replace(node, "Map.new(#{Sourceror.to_string(coll)}, #{Sourceror.to_string(fun)})")
       ]

  defp maybe_patch(
         {:|>, _,
          [
            {:|>, _, [coll, {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [fun]}]},
            {{:., _, [{:__aliases__, _, [:Enum]}, :into]}, _, [{:%{}, _, []}]}
          ]} = node
       ),
       do: [
         Patch.replace(node, "Map.new(#{Sourceror.to_string(coll)}, #{Sourceror.to_string(fun)})")
       ]

  defp maybe_patch(_), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
