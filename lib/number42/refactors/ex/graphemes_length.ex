defmodule Number42.Refactors.Ex.GraphemesLength do
  @moduledoc """
  Replaces `String.graphemes/1 |> length/1` (and equivalents) with
  `String.length/1`:

      string |> String.graphemes() |> length()
      length(String.graphemes(string))
      Enum.count(String.graphemes(string))
      ↓
      String.length(string)

  Mirrors `ExSlop.Check.Refactor.GraphemesLength`. The intermediate
  list is wasted work — `String.length/1` walks the codepoints once
  without materializing the grapheme list.

  ## What we match

  Three call shapes, all semantically identical:

  1. `length(String.graphemes(s))` — bare `length/1` wrapping the call.
  2. `Enum.count(String.graphemes(s))` — `Enum.count/1` likewise.
  3. `s |> String.graphemes() |> length()` (and the `Enum.count`
     variant) — pipe chain. We rewrite the **whole two-step segment**
     so `String.graphemes` and the counter both disappear.

  ## Idempotence

  After a rewrite the call is `String.length(s)` — no `String.graphemes`
  remains, so a second pass is a no-op.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "String.graphemes(s) |> length() -> String.length(s)"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Counting via `String.graphemes/1 |> length/1` materialises a list
    of graphemes just to throw it away. `String.length/1` is the
    counter for the same notion of "characters" without the
    intermediate list. The naming also matches reader intent: when the
    code says "length of this string", that's literally the function
    being called.
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
         {:length, _, [{{:., _, [{:__aliases__, _, [:String]}, :graphemes]}, _, [s]}]} = node
       ),
       do: [Patch.replace(node, "String.length(#{Sourceror.to_string(s)})")]

  defp maybe_patch(
         {{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _,
          [{{:., _, [{:__aliases__, _, [:String]}, :graphemes]}, _, [s]}]} = node
       ),
       do: [Patch.replace(node, "String.length(#{Sourceror.to_string(s)})")]

  defp maybe_patch(
         {:|>, _,
          [
            {:|>, _, [inner, {{:., _, [{:__aliases__, _, [:String]}, :graphemes]}, _, []}]},
            counter
          ]} = node
       ) do
    if pipe_counter?(counter) do
      [Patch.replace(node, "#{Sourceror.to_string(inner)} |> String.length()")]
    else
      []
    end
  end

  defp maybe_patch(_), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
  defp pipe_counter?({:length, _, []}), do: true
  defp pipe_counter?({:length, _, nil}), do: true
  defp pipe_counter?({{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, []}), do: true
  defp pipe_counter?({{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, nil}), do: true
  defp pipe_counter?(_), do: false
end
