defmodule Number42.Refactors.Ex.EnumIntoToMapNew do
  @moduledoc """
  Rewrites `Enum.into(coll, %{})` to `Map.new(coll)`.

  Fires only when the accumulator is the empty-map AST literal
  (`{:%{}, _, []}`). `Enum.into/2` with a non-empty map merges into the
  existing map and is **not** equivalent to `Map.new/1` — leaving those
  alone is intentional, hence the capture guard on `acc`.

  ## Defers to `EnumMapIntoToMapNew`

  When `coll` is itself `Enum.map(_, _)`, the more specific refactor
  (`EnumMapIntoToMapNew`) collapses the whole pipe into `Map.new/2`
  with the mapper as the second arg. We exclude that case here so
  the alphabetic dispatch order doesn't have us rewrite to
  `Map.new(Enum.map(...))` first and starve the more specific match.

  ## Preserves the pipe flow

  When the source is the tail of a `|>` chain
  (`coll |> ... |> Enum.into(%{})`), the rewrite re-threads onto that
  chain — `coll |> ... |> Map.new()` — rather than wrapping the whole
  chain in `Map.new(...)`, which would invert the left-to-right reading
  order into an inside-out call. The non-piped call form
  (`Enum.into(coll, %{})`) keeps the `Map.new(coll)` call shape.

  Source emission goes through `Sourceror.to_string/1`; `mix format`
  re-pipes after the refactor runs.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Enum.into(coll, %{}) -> Map.new(coll)"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `Enum.into/2` is the general "fold into a collectable" interface and
    its second argument can be *any* map — meaning the reader has to
    check whether `acc` is `%{}` or a non-empty map before they know if
    this is "build a fresh map" or "merge into an existing one".
    `Map.new/1` is the dedicated constructor and removes that ambiguity:
    it can only mean the first thing.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 140
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

  defp defers_to_enum_map?({{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _}), do: true
  defp defers_to_enum_map?(_), do: false

  defp maybe_patch(
         {{:., _, [{:__aliases__, _, [:Enum]}, :into]}, _, [coll, {:%{}, _, []}]} = node
       ) do
    if defers_to_enum_map?(coll) do
      []
    else
      [Patch.replace(node, "Map.new(#{Sourceror.to_string(coll)})")]
    end
  end

  defp maybe_patch(
         {:|>, _,
          [
            coll,
            {{:., _, [{:__aliases__, _, [:Enum]}, :into]}, _, [{:%{}, _, []}]}
          ]} = node
       ) do
    if defers_to_enum_map?(coll) do
      []
    else
      [Patch.replace(node, "#{Sourceror.to_string(coll)} |> Map.new()")]
    end
  end

  defp maybe_patch(_), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
