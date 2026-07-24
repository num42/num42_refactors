defmodule Mix.Tasks.Refactor.HeexClones do
  @shortdoc "Find duplicate HEEx fragments across the project"

  @moduledoc """
  Scan every HEEx (`~H`) sigil in the project, fingerprint each
  subtree, and report clusters of structurally duplicate fragments.

  Three detection modes are run in parallel; pick what fits the
  refactor you have in mind:

  - `exact` — byte-identical structure including attribute values.
    The strict floor: anything reported here is a literal copy.
  - `class_stripped` — ignore `class`/`:class` attribute values.
    Tailwind-style cosmetic variation merges. Use this to plant
    "same widget, different theme" components.
  - `attrs_stripped` — ignore all attributes. Reveals parametric
    clones whose structure matches but whose props differ — the
    classic "extract a helper component with props" target.

  ## Usage

      mix refactor.heex_clones                  # all modes, all inputs from .refactor.exs
      mix refactor.heex_clones lib/foo.ex       # restrict to specific paths
      mix refactor.heex_clones --mode exact     # one mode only
      mix refactor.heex_clones --mode class_stripped --mode attrs_stripped
      mix refactor.heex_clones --min-mass 12    # default 8 — bump to filter noise
      mix refactor.heex_clones --top 20         # show top N clusters per mode (default 15)
      mix refactor.heex_clones --code           # inline source snippet for each occurrence
      mix refactor.heex_clones --code --context 2  # add 2 lines of context before each snippet

  Inputs default to the `:inputs` glob from `.refactor.exs`. A
  manual list of paths overrides that.

  ## Output

  For each mode the task prints clusters sorted by mass × occurrence
  count (largest impact first). One block per cluster:

      [exact] mass=23 × 3 occurrences
        lib/.../foo.ex:42
        lib/.../bar.ex:17
        lib/.../baz.ex:88

  No diff is rendered — the report is meant for triage. Open the
  files at the listed lines to inspect the actual fragments.
  """

  use Mix.Task

  alias Number42.Refactors.Analysis.Heex.Clones
  import Mix.Tasks.Refactor.Shared, only: [expand_inputs_shared: 1]

  @config_path ".refactor.exs"
  @switches [
    mode: :keep,
    min_mass: :integer,
    min_occurrences: :integer,
    top: :integer,
    code: :boolean,
    context: :integer
  ]
  @aliases [m: :mode]

  @default_min_mass 8
  @default_top 15
  @default_min_occurrences 2
  @default_context 0

  @impl Mix.Task
  def run(argv) do
    {opts, paths} = OptionParser.parse!(argv, strict: @switches, aliases: @aliases)

    files =
      case paths do
        [] -> load_inputs() |> expand_inputs()
        list -> expand_inputs(list)
      end

    modes = resolve_modes(Keyword.get_values(opts, :mode))
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)
    min_occ = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
    top = Keyword.get(opts, :top, @default_top)
    code? = Keyword.get(opts, :code, false)
    context = Keyword.get(opts, :context, @default_context)

    Mix.shell().info(
      "[heex-clones] scanning #{length(files)} file(s), modes: #{modes |> Enum.join(", ")}, min_mass=#{min_mass}"
    )

    result =
      Clones.from_files(files, modes: modes, min_mass: min_mass, min_occurrences: min_occ)

    # Cache file contents lazily — multiple clusters in the same file
    # would otherwise re-read it once per occurrence.
    file_cache = if code?, do: %{}, else: nil

    _ =
      modes
      |> Enum.reduce(file_cache, fn mode, cache ->
        render_mode(mode, Map.get(result, mode, []), top, code?, context, cache)
      end)

    summary = modes |> Enum.map(&"#{&1}=#{length(Map.get(result, &1, []))}")
    Mix.shell().info("\n[heex-clones] cluster totals: #{summary |> Enum.join(" ")}")
  end

  defp cached_or_read_lines({:ok, lines}, cache, _file), do: {lines, cache}

  defp cached_or_read_lines(:error, cache, file) do
    lines = File.read!(file) |> String.split("\n")
    {lines, Map.put(cache, file, lines)}
  end

  defp expand_inputs(patterns), do: expand_inputs_shared(patterns)
  defp file_lines(nil, file), do: {File.read!(file) |> String.split("\n"), nil}

  defp file_lines(cache, file),
    do: Map.fetch(cache, file) |> cached_or_read_lines(cache, file)

  defp load_inputs do
    path = Path.join(File.cwd!(), @config_path)

    File.read(path) |> parse_config_or_raise(path)
  end

  defp parse_config_or_raise({:ok, contents}, path) do
    {config, _} = Code.eval_string(contents, [], file: path)
    Keyword.fetch!(config, :inputs)
  end

  defp parse_config_or_raise({:error, _}, path),
    do:
      "#{@config_path} not found at #{path}. Pass paths explicitly or create the config."
      |> Mix.raise()

  defp parse_mode("exact"), do: :exact
  defp parse_mode("class_stripped"), do: :class_stripped
  defp parse_mode("attrs_stripped"), do: :attrs_stripped

  defp parse_mode(other),
    do:
      "Unknown --mode #{inspect(other)}. Pick from: exact, class_stripped, attrs_stripped"
      |> Mix.raise()

  defp print_snippet(occ, mass, context, cache) do
    {lines, cache} = file_lines(cache, occ.file)
    snippet_height = trunc(mass * 1.5) + 3

    start_idx = max(occ.line - 1 - context, 0)
    finish_idx = min(occ.line - 1 + snippet_height, length(lines) - 1)

    lines
    |> Enum.slice(start_idx..finish_idx//1)
    |> Enum.with_index(start_idx + 1)
    |> Enum.each(fn {line, n} ->
      marker = if n == occ.line, do: ">", else: " "
      Mix.shell().info("       #{marker} #{String.pad_leading(to_string(n), 4)} | #{line}")
    end)

    cache
  end

  defp render_mode(mode, [], _top, _code?, _context, cache) do
    Mix.shell().info("\n=== #{mode} ===")
    Mix.shell().info("  (no clusters)")
    cache
  end

  defp render_mode(mode, clusters, top, code?, context, cache) do
    Mix.shell().info("\n=== #{mode} (#{length(clusters)} cluster(s)) ===")

    cache =
      clusters
      |> Enum.take(top)
      |> Enum.with_index(1)
      |> Enum.reduce(cache, fn {cluster, idx}, c ->
        Mix.shell().info(
          "\n  ##{idx}  mass=#{cluster.mass} × #{length(cluster.occurrences)} occurrences"
        )

        render_occurrences(cluster, code?, context, c)
      end)

    if length(clusters) > top do
      Mix.shell().info("\n  … #{length(clusters) - top} more (raise --top to see them)")
    end

    cache
  end

  defp render_occurrences(cluster, code?, context, cache) do
    cluster.occurrences
    |> Enum.reduce(cache, fn occ, c2 ->
      Mix.shell().info("       #{occ.file}:#{occ.line}")
      if code?, do: print_snippet(occ, cluster.mass, context, c2), else: c2
    end)
  end

  defp resolve_modes([]), do: [:exact, :class_stripped, :attrs_stripped]
  defp resolve_modes(values), do: values |> Enum.map(&parse_mode/1)
end
