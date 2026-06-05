defmodule Number42.Refactors.Ex.AliasOrder do
  @moduledoc """
  Sorts contiguous groups of `alias` statements alphabetically
  (case-insensitive), mirroring `Credo.Check.Readability.AliasOrder`
  with its default `sort_method: :alpha`.

  A *group* is a run of consecutive `alias` statements at the module
  top level with no blank line and no other expression separating
  them. Groups are sorted independently — visual blank-line groupings
  are preserved.

  Multi-alias forms (`alias Foo.{Bar, Baz}`) are sorted as a single
  unit by their leading path (`Foo`); the inner list ordering is left
  alone for now.

  ## Procedural mode

  Reordering can't be expressed as a single ExAST pattern rewrite —
  we walk the module top, find runs, and emit one whole-group
  `Sourceror.Patch` per run that replaces the original lines with a
  sorted version.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Sort contiguous alias groups alphabetically"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Alphabetical alias order is one of those tiny consistencies that pays
    off mostly in diffs and code review: when a new alias is inserted at
    its sort position instead of "wherever I happened to type it", the
    resulting hunk shows only the new line — no incidental reordering
    noise. Two reviewers can also predict where to look for `Foo`
    without scanning the whole block.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: false
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp alias_groups(exprs) do
    exprs
    |> Enum.chunk_while(
      [],
      &chunk_step/2,
      fn
        [] -> {:cont, []}
        acc -> {:cont, acc |> Enum.reverse(), []}
      end
    )
    |> Enum.filter(&(length(&1) >= 2))
  end

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source
  defp blank_line_after?(meta), do: Keyword.get(meta, :end_of_expression) |> has_blank_line?()
  defp build_patches(ast, source), do: module_body_exprs(ast) |> group_patches_or_skip(source)

  defp build_replace_patch(group, sorted, source) do
    first = List.first(group)
    last = List.last(group)

    first_range = Sourceror.get_range(first)
    last_range = Sourceror.get_range(last)

    # Reuse each statement's *original* source slice, then concatenate
    # them in sorted order with newlines + the original indent. This
    # avoids reformatting / requoting the alias bodies themselves.
    indent = leading_indent(source, first_range.start[:line])

    rendered =
      sorted
      |> Enum.map(&original_slice(&1, source))
      |> Enum.intersperse("\n" <> indent)
      |> IO.iodata_to_binary()

    range = %{
      end: [line: last_range.end[:line], column: last_range.end[:column]],
      start: [line: first_range.start[:line], column: first_range.start[:column]]
    }

    Patch.new(range, rendered, false)
  end

  defp chunk_step({:alias, meta, _} = node, []) do
    if blank_line_after?(meta) do
      {:cont, [node], []}
    else
      {:cont, [node | []]}
    end
  end

  defp chunk_step({:alias, meta, _} = node, [{:alias, _, _} | _] = acc) do
    if blank_line_after?(meta) do
      {:cont, [node | acc] |> Enum.reverse(), []}
    else
      {:cont, [node | acc]}
    end
  end

  defp chunk_step(_other, []), do: {:cont, []}
  defp chunk_step(_other, acc), do: {:cont, acc |> Enum.reverse(), []}

  defp group_patch(group, source) do
    sorted = group |> Enum.sort_by(&sort_key/1)

    if sorted == group do
      []
    else
      [build_replace_patch(group, sorted, source)]
    end
  end

  defp group_patches_or_skip(nil, _source), do: []

  defp group_patches_or_skip(exprs, source),
    do: exprs |> alias_groups() |> Enum.flat_map(&group_patch(&1, source))

  defp has_blank_line?(nil), do: false
  defp has_blank_line?(eoe), do: Keyword.get(eoe, :newlines, 1) >= 2

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

  defp original_slice(node, source) do
    range = Sourceror.get_range(node)
    lines = String.split(source, "\n")

    if range.start[:line] == range.end[:line] do
      line = lines |> Enum.at(range.start[:line] - 1)
      String.slice(line, (range.start[:column] - 1)..(range.end[:column] - 2))
    else
      first_line =
        lines
        |> Enum.at(range.start[:line] - 1)
        |> String.slice((range.start[:column] - 1)..-1//1)

      middle_lines =
        lines
        |> Enum.slice(range.start[:line]..(range.end[:line] - 2))

      last_line =
        lines
        |> Enum.at(range.end[:line] - 1)
        |> String.slice(0..(range.end[:column] - 2))

      ([first_line | middle_lines] ++ [last_line]) |> Enum.join("\n")
    end
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
  defp path_atoms({:__aliases__, _, segments}), do: segments
  defp path_atoms({{:., _, [{:__aliases__, _, segments}, :{}]}, _, _}), do: segments
  defp path_atoms(_), do: []

  defp path_string(atoms),
    do:
      atoms
      |> Enum.map_join(".", &Atom.to_string/1)
      |> String.downcase()

  defp sort_key({:alias, _, [arg | _]}), do: arg |> path_atoms() |> path_string()
end
