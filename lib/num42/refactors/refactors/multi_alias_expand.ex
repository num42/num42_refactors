defmodule Num42.Refactors.Refactors.MultiAliasExpand do
  @moduledoc """
  Expands `alias Foo.{Bar, Baz}` into one `alias` per inner module:

      alias Foo.{Bar, Baz}
      ↓
      alias Foo.Bar
      alias Foo.Baz

  Mirrors `Credo.Check.Readability.MultiAlias`, which considers the
  expanded form clearer because each alias gets a dedicated, greppable
  line.

  ## Why this matters for AliasOrder

  Multi-alias forms are opaque to alphabetic sorting: `alias MyApp.{B, A}`
  has a single sort key (the prefix `MyApp`), so `AliasOrder` can't
  reorder its contents nor interleave it with surrounding singles whose
  expansions would alphabetically sit between `B` and `A`. Expanding
  first lets `AliasOrder` see and sort the individual modules.

  ## Procedural mode

  Touches the module top: replaces a single multi-alias node with N
  alias nodes spread over N lines, indented to match the original.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Num42.Refactors.Refactor
  def description, do: "Expand `alias Foo.{A, B}` into one alias per module"

  @impl Num42.Refactors.Refactor
  def priority, do: 220

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    `alias Foo.{A, B}` looks compact but works against the rest of the
    tooling: it can't be sorted alphabetically with neighbouring aliases,
    a grep for `alias Foo.B` misses it, and adding/removing one entry
    diff-pollutes the entire group. One `alias` per line restores
    grep-ability and lets `AliasOrder` keep the file tidy.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: false
  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_patches(ast, source),
    do: module_body_exprs(ast) |> alias_expand_patches_or_skip(source)

  defp leading_indent(source, line) do
    source
    |> String.split("\n")
    |> Enum.at(line - 1, "")
    |> then(fn l ->
      case Regex.run(~r/^[\s]*/, l) do
        [match] -> match
        _ -> ""
      end
    end)
  end

  defp maybe_expand_patch(
         {:alias, _alias_meta,
          [
            {{:., _, [{:__aliases__, _, prefix_segments}, :{}]}, _, group}
          ]} = node,
         source
       ) do
    range = Sourceror.get_range(node)
    indent = leading_indent(source, range.start[:line])

    expanded =
      group
      |> Enum.flat_map(fn
        {:__aliases__, _, segs} -> [render_alias(prefix_segments ++ segs)]
        # Anything weirder (e.g. `as:` opts on an inner element) — bail out
        # by returning [] which triggers the no-op fallthrough below.
        _ -> []
      end)

    cond do
      expanded == [] ->
        []

      true ->
        rendered = expanded |> Enum.intersperse("\n" <> indent) |> IO.iodata_to_binary()
        [Patch.new(range, rendered, false)]
    end
  end

  defp maybe_expand_patch(_, _), do: []

  defp render_alias(segments), do: "alias " <> Enum.map_join(segments, ".", &Atom.to_string/1)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp alias_expand_patches_or_skip(nil, _source), do: []

  defp alias_expand_patches_or_skip(exprs, source),
    do: exprs |> Enum.flat_map(&maybe_expand_patch(&1, source))

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
