defmodule Mix.Tasks.Refactor.Shared do
  @moduledoc false

  # extracted from: Mix.Tasks.Refactor, Mix.Tasks.Refactor.HeexClones
  def expand_inputs_shared(patterns),
    do:
      patterns
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.filter(&File.regular?/1)

  @doc """
  Whether `path` matches `glob`, using `Path.wildcard/1` glob semantics
  against a known path string (rather than the filesystem):

  - `*` matches within one segment (never a `/`)
  - `?` matches a single non-`/` char
  - `**` matches any number of characters, across segments
  - `**/` matches zero or more leading segments (so `test/**/*.exs`
    matches both `test/a.exs` and `test/sub/a.exs`)
  - `{a,b}` expands to alternation
  """
  @spec glob_match?(String.t(), String.t()) :: boolean()
  def glob_match?(glob, path), do: Regex.match?(compile_glob(glob), path)

  defp compile_glob(glob), do: Regex.compile!("\\A" <> translate_glob(glob, []) <> "\\z")

  defp translate_glob(glob, acc) when is_binary(glob),
    do: translate_glob(String.to_charlist(glob), acc)

  defp translate_glob([], acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp translate_glob([?*, ?*, ?/ | rest], acc), do: translate_glob(rest, ["(?:[^/]+/)*" | acc])
  defp translate_glob([?*, ?* | rest], acc), do: translate_glob(rest, [".*" | acc])
  defp translate_glob([?* | rest], acc), do: translate_glob(rest, ["[^/]*" | acc])
  defp translate_glob([?? | rest], acc), do: translate_glob(rest, ["[^/]" | acc])
  defp translate_glob([?{ | rest], acc), do: translate_brace(rest, acc, ["(?:"])

  defp translate_glob([c | rest], acc) when c in ~c".+()[]^$|\\",
    do: translate_glob(rest, [<<?\\, c>> | acc])

  defp translate_glob([c | rest], acc), do: translate_glob(rest, [<<c::utf8>> | acc])

  defp translate_brace([?} | rest], acc, brace),
    do: translate_glob(rest, [IO.iodata_to_binary(Enum.reverse(brace)) <> ")" | acc])

  defp translate_brace([?, | rest], acc, brace), do: translate_brace(rest, acc, ["|" | brace])

  defp translate_brace([c | rest], acc, brace) when c in ~c".+()[]^$|\\*?",
    do: translate_brace(rest, acc, [<<?\\, c>> | brace])

  defp translate_brace([c | rest], acc, brace),
    do: translate_brace(rest, acc, [<<c::utf8>> | brace])
end
