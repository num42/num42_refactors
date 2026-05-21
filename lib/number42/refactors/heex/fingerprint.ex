defmodule Number42.Refactors.Heex.Fingerprint do
  @moduledoc """
  Compute Mass + structural hash for every subtree of a HEEx tree
  whose Mass meets a threshold. Mirrors `ExDNA.AST.Fingerprint` for
  Elixir ASTs but operates on `Number42.Refactors.Heex.Tree` nodes.

  ## Mass

  Mass = number of nodes in the subtree. Elements, EEx blocks, EEx
  expressions and text are each one node; attributes don't add to
  mass (they are part of the element's "shape", not separate nodes).
  Threshold filters out trivial fragments (`<span>x</span>`) that
  match everywhere and produce noise.

  ## One walk, three modes

  `fragments/3` walks the tree exactly once and produces, per
  qualifying subtree, **one fragment per mode**. The trick: a node's
  hash under any mode depends only on its own shape (tag + mode-
  normalized attrs / EEx header / text) and the hashes of its
  children under the same mode. So we hash bottom-up, never
  re-serializing whole subtrees, and compute all three modes in
  parallel from the same recursion.

  Each fragment also carries `sub_hashes` — the set of every
  descendant's hash under that fragment's mode. The cluster filter
  uses this to ask "is small.hash a sub-hash of big.node?" without
  re-hashing.

  ## Output

  `fragments/3` returns one fragment per (subtree, mode) pair that
  meets `min_mass`:

      %{
        hash: <<...>>,
        mode: :exact | :class_stripped | :attrs_stripped,
        mass: 12,
        node: original_tree_node,
        sub_hashes: MapSet,
        file: "lib/foo.ex",
        line: 42
      }
  """

  alias Number42.Refactors.Heex.Normalizer
  alias Number42.Refactors.Heex.Tree

  @type fragment :: %{
          file: String.t(),
          hash: binary(),
          line: pos_integer(),
          mass: pos_integer(),
          mode: Normalizer.mode(),
          node: Tree.node_t(),
          sub_hashes: MapSet.t(binary())
        }

  @default_min_mass 6
  @all_modes [:exact, :class_stripped, :attrs_stripped]

  @doc """
  Hash a single node under one mode. Convenience for tests and
  ad-hoc lookups; the bulk path uses `fragments/3`.
  """
  @spec compute_hash(Tree.node_t(), Normalizer.mode()) :: binary()
  def compute_hash(node, mode) do
    {summary, _frags} = walk_one(node, [mode], "", :infinity, [])
    summary.hashes[mode]
  end

  @doc """
  Walk `nodes` (a tree or list of trees) once and return all fragments
  for every requested mode whose mass is at least `min_mass`.

  Options:
    * `:min_mass` — defaults to #{@default_min_mass}
    * `:modes`    — defaults to all three modes
  """
  @spec fragments([Tree.node_t()] | Tree.node_t(), String.t(), keyword()) :: [fragment()]
  def fragments(nodes, file, opts \\ []) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)
    modes = Keyword.get(opts, :modes, @all_modes)

    {_summaries, frags} = walk_many(List.wrap(nodes), modes, file, min_mass, [])
    frags
  end

  @doc "Number of nodes in a tree."
  @spec mass(Tree.node_t() | [Tree.node_t()]) :: non_neg_integer()
  def mass(nodes) when is_list(nodes), do: nodes |> Enum.map(&mass/1) |> Enum.sum()
  def mass({:element, _, _, children, _}), do: 1 + mass(children)
  def mass({:eex_block, _, children, _}), do: 1 + mass(children)
  def mass({:eex_expr, _, _}), do: 1
  def mass({:text, _, _}), do: 1

  defp build_summary(mass, hashes, child_summaries, modes) do
    %{
      hashes: hashes,
      mass: mass,
      sub_hashes:
        Map.new(modes, fn mode ->
          combined =
            child_summaries
            |> Enum.reduce(MapSet.new([hashes[mode]]), fn changeset, acc ->
              MapSet.union(acc, changeset.sub_hashes[mode])
            end)

          {mode, combined}
        end)
    }
  end

  defp hash_term(term) do
    binary = :erlang.term_to_binary(term)
    :crypto.hash(:blake2b, binary)
  end

  defp leaf_summary(hashes, modes) do
    %{
      hashes: hashes,
      mass: 1,
      sub_hashes:
        for mode <- modes do
          {mode, MapSet.new([hashes[mode]])}
        end
        |> Map.new()
    }
  end

  defp line_of({:element, _, _, _, %{line: l}}), do: l
  defp line_of({:eex_block, _, _, %{line: l}}), do: l
  defp line_of({:eex_expr, _, %{line: l}}), do: l
  defp line_of({:text, _, %{line: l}}), do: l

  defp maybe_emit(summary, _node, _modes, _file, min_mass, frags)
       when is_integer(min_mass) and summary.mass < min_mass,
       do: frags

  defp maybe_emit(_summary, _node, _modes, _file, :infinity, frags), do: frags

  defp maybe_emit(summary, node, modes, file, _min_mass, frags) do
    line = line_of(node)

    modes
    |> Enum.reduce(frags, fn mode, acc ->
      [
        %{
          file: file,
          hash: summary.hashes[mode],
          line: line,
          mass: summary.mass,
          mode: mode,
          node: node,
          sub_hashes: summary.sub_hashes[mode]
        }
        | acc
      ]
    end)
  end

  defp sum_mass(summaries), do: summaries |> Enum.sum_by(fn s -> s.mass end)

  defp walk_many(nodes, modes, file, min_mass, frags) do
    nodes
    |> Enum.reduce({[], frags}, fn node, {summaries, acc_frags} ->
      {summary, new_frags} = walk_one(node, modes, file, min_mass, acc_frags)
      {[summary | summaries], new_frags}
    end)
    |> then(fn {summaries, frags} -> {summaries |> Enum.reverse(), frags} end)
  end

  defp walk_one({:element, tag, attrs, children, _meta} = node, modes, file, min_mass, frags) do
    {child_summaries, frags} = walk_many(children, modes, file, min_mass, frags)

    hashes =
      Map.new(modes, fn mode ->
        shape = {:element, tag, Normalizer.normalize_attrs(attrs, mode)}
        child_hashes = child_summaries |> Enum.map(& &1.hashes[mode])
        {mode, hash_term({shape, child_hashes})}
      end)

    summary = build_summary(1 + sum_mass(child_summaries), hashes, child_summaries, modes)
    {summary, maybe_emit(summary, node, modes, file, min_mass, frags)}
  end

  defp walk_one({:eex_block, header, children, _meta} = node, modes, file, min_mass, frags) do
    {child_summaries, frags} = walk_many(children, modes, file, min_mass, frags)
    norm_header = Normalizer.normalize_eex(header)

    hashes =
      Map.new(modes, fn mode ->
        child_hashes = child_summaries |> Enum.map(& &1.hashes[mode])
        {mode, hash_term({:eex_block, norm_header, child_hashes})}
      end)

    summary = build_summary(1 + sum_mass(child_summaries), hashes, child_summaries, modes)
    {summary, maybe_emit(summary, node, modes, file, min_mass, frags)}
  end

  defp walk_one({:eex_expr, code, _meta}, modes, _file, _min_mass, frags) do
    eex = Normalizer.normalize_eex(code)
    hash_term = hash_term({:eex_expr, eex})

    hashes =
      for mode <- modes do
        {mode, hash_term}
      end
      |> Map.new()

    {leaf_summary(hashes, modes), frags}
  end

  defp walk_one({:text, text, _meta}, modes, _file, _min_mass, frags) do
    hash_term = hash_term({:text, text})

    hashes =
      for mode <- modes do
        {mode, hash_term}
      end
      |> Map.new()

    {leaf_summary(hashes, modes), frags}
  end
end
