defmodule Number42.Refactors.Heex.Clones do
  @moduledoc """
  Public entry point for HEEx clone detection.

  Given a list of source files (or `{path, source}` pairs), produces
  clusters of structurally identical HEEx fragments grouped per
  detection mode (`:exact`, `:class_stripped`, `:attrs_stripped`).

  Intended uses:

  - **As a library** for upcoming refactors that want to plant a
    private component or a shared module wherever ≥2 occurrences of
    the same HEEx subtree exist.
  - **As CLI input** via `mix refactor.heex_clones`, which prints
    cluster reports per mode.

  ## API

      Clones.from_files(["lib/.../foo.ex", "lib/.../bar.ex"], min_mass: 8)
      #=> %{
      #     exact: [%{hash: ..., mass: 12, occurrences: [...]}, ...],
      #     class_stripped: [...],
      #     attrs_stripped: [...]
      #   }

  Each `occurrence` is `%{file: path, line: line, node: tree_node, mass: m}`.

  ## Subset deduplication

  An entry is suppressed if it is fully contained inside another
  entry that *also* clusters (same number of occurrences, every
  occurrence sits at a deeper line in the same file as a parent
  occurrence). This keeps the report focused on the largest matching
  unit instead of repeating it once per matching subtree.
  """

  alias Number42.Refactors.Heex.Fingerprint
  alias Number42.Refactors.Heex.Normalizer
  alias Number42.Refactors.Heex.Tree

  @type occurrence :: %{
          file: String.t(),
          line: pos_integer(),
          mass: pos_integer(),
          node: Tree.node_t()
        }

  @type cluster :: %{
          hash: binary(),
          mass: pos_integer(),
          mode: Normalizer.mode(),
          occurrences: [occurrence()]
        }

  @default_min_mass 6
  @default_min_occurrences 2

  @doc """
  Read each path in `paths` from disk and produce per-mode clusters.
  Files that fail to parse contribute nothing — partial coverage is
  preferable to crashing on one bad file.
  """
  @spec from_files([String.t()], keyword()) :: %{Normalizer.mode() => [cluster()]}
  def from_files(paths, opts \\ []) when is_list(paths) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)
    min_occ = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
    modes = Keyword.get(opts, :modes, [:exact, :class_stripped, :attrs_stripped])

    # Read + parse + fingerprint per file in parallel. The per-file
    # phase is the bulk of the work (HTML/EEx tokenizing + bottom-up
    # hashing) and shares no state across files. Cluster aggregation
    # at the end stays serial.
    fragments =
      paths
      |> Task.async_stream(
        fn path ->
          case File.read(path) do
            {:ok, source} -> fragments_for_source(source, path, min_mass, modes)
            {:error, _} -> []
          end
        end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, frags} -> frags end)

    cluster_fragments(fragments, modes, min_occ)
  end

  @doc """
  Cluster across an explicit list of `{path, source}` pairs. Useful
  for tests that want to feed in-memory sources without touching the
  filesystem.
  """
  @spec from_sources([{String.t(), String.t()}], keyword()) :: %{
          Normalizer.mode() => [cluster()]
        }
  def from_sources(pairs, opts \\ []) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)
    min_occ = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
    modes = Keyword.get(opts, :modes, [:exact, :class_stripped, :attrs_stripped])

    fragments =
      pairs
      |> Enum.flat_map(fn {path, source} ->
        fragments_for_source(source, path, min_mass, modes)
      end)

    cluster_fragments(fragments, modes, min_occ)
  end

  defp cluster_fragments(clustered_fragments, modes, min_occ) do
    by_mode =
      clustered_fragments
      |> Enum.group_by(&{&1.mode, &1.hash})
      |> Enum.flat_map(fn {{mode, hash}, frags} ->
        if length(frags) >= min_occ do
          [build_cluster(hash, mode, frags)]
        else
          []
        end
      end)
      |> Enum.group_by(& &1.mode)

    # Always emit one entry per requested mode, even if empty, so
    # callers can do `result[:exact]` without nil checks.
    Map.new(modes, fn mode ->
      clusters = Map.get(by_mode, mode, [])

      {mode,
       clusters |> drop_subset_clusters() |> Enum.sort_by(&{-&1.mass, -length(&1.occurrences)})}
    end)
  end

  defp fragments_for_source(source, path, min_mass, modes),
    do: Tree.from_source(source) |> fragments_from_tree_result(min_mass, modes, path)

  defp offset_line(frag, 0), do: frag

  defp offset_line(frag, offset), do: %{frag | line: frag.line + offset}

  defp build_cluster(hash, mode, frags) do
    [%{mass: mass, sub_hashes: rep_subs} | _] = frags

    %{
      hash: hash,
      mass: mass,
      mode: mode,
      occurrences:
        frags
        |> Enum.map(fn f -> %{file: f.file, line: f.line, mass: f.mass, node: f.node} end)
        |> Enum.sort_by(&{&1.file, &1.line}),
      sub_hashes: rep_subs
    }
  end

  # Suppress a smaller cluster if its hash already appears among the
  # sub-hashes of a larger cluster's representative, and the larger
  # cluster covers at least as many occurrences. Both sub-hash sets
  # come from the per-file fingerprint walk — no re-hashing here.
  defp drop_subset_clusters(subseted_clusters) do
    sorted = subseted_clusters |> Enum.sort_by(& &1.mass, :desc)

    sorted
    |> Enum.reject(fn small ->
      sorted
      |> Enum.any?(fn big ->
        big.hash != small.hash and big.mass > small.mass and
          length(big.occurrences) >= length(small.occurrences) and
          MapSet.member?(big.sub_hashes, small.hash)
      end)
    end)
    |> Enum.map(&Map.delete(&1, :sub_hashes))
  end

  defp fragments_from_tree_result({:ok, sigils}, min_mass, modes, path) do
    sigils
    |> Enum.flat_map(fn sigil ->
      # Tree lines are relative to the sigil body; offset them to
      # absolute file lines so reports point at real source.
      # Sourceror reports `file_line` at the `~H"""` opening line.
      # The first content line inside the sigil starts one line
      # below, where EEx's tokenizer counts as `line: 1`. So body
      # line N maps to file line `file_line + N`, not `file_line + N - 1`.
      offset = sigil.file_line

      sigil.tree
      |> Fingerprint.fragments(path, min_mass: min_mass, modes: modes)
      |> Enum.map(&offset_line(&1, offset))
    end)
  end

  defp fragments_from_tree_result(:error, _min_mass, _modes, _path), do: []
end
