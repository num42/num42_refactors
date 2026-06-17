defmodule Number42.Refactors.Ex.EnumIntoToMapSet do
  @moduledoc """
  Rewrites `Enum.into(coll, MapSet.new())` to `MapSet.new(coll)`.

  Fires only when the accumulator is the zero-arg `MapSet.new()` AST
  (`{{:., _, [{:__aliases__, _, [:MapSet]}, :new]}, _, []}`).
  `Enum.into/2` with a seeded `MapSet.new(seed)` merges into an existing
  set and is **not** equivalent to `MapSet.new/1` — leaving those alone
  is intentional, hence the empty-args match on the accumulator.

  ## Preserves the pipe flow

  When the source is the tail of a `|>` chain
  (`coll |> ... |> Enum.into(MapSet.new())`), the rewrite re-threads onto
  that chain — `coll |> ... |> MapSet.new()` — rather than wrapping the
  whole chain in `MapSet.new(...)`, which would invert the left-to-right
  reading order into an inside-out call. The non-piped call form
  (`Enum.into(coll, MapSet.new())`) keeps the `MapSet.new(coll)` call
  shape.

  Source emission goes through `Sourceror.to_string/1`; `mix format`
  re-pipes after the refactor runs.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Enum.into(coll, MapSet.new()) -> MapSet.new(coll)"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `Enum.into/2` is the general "fold into a collectable" interface and
    its second argument can be *any* set — meaning the reader has to check
    whether the accumulator is `MapSet.new()` or a seeded set before they
    know if this is "build a fresh set" or "merge into an existing one".
    `MapSet.new/1` is the dedicated constructor and removes that
    ambiguity: it can only mean the first thing.
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

  defp maybe_patch(
         {{:., _, [{:__aliases__, _, [:Enum]}, :into]}, _,
          [coll, {{:., _, [{:__aliases__, _, [:MapSet]}, :new]}, _, []}]} = node
       ),
       do: [Patch.replace(node, "MapSet.new(#{Sourceror.to_string(coll)})")]

  defp maybe_patch(
         {:|>, _,
          [
            coll,
            {{:., _, [{:__aliases__, _, [:Enum]}, :into]}, _,
             [{{:., _, [{:__aliases__, _, [:MapSet]}, :new]}, _, []}]}
          ]} = node
       ),
       do: [Patch.replace(node, "#{Sourceror.to_string(coll)} |> MapSet.new()")]

  defp maybe_patch(_), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
