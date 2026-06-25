defmodule Number42.Refactors.TreeEditDistance do
  @moduledoc """
  Zhang-Shasha ordered-tree edit distance over **any** labelled ordered tree,
  parameterised by an adapter module. The HEEx near-clone detector
  (`Heex.TreeDiff`) and the Elixir-AST one (`Ex.TreeDiff`) are both thin
  adapters over this core — same DP, same traceback, different node shapes.

  ## What an adapter provides

  An adapter is a module implementing `Number42.Refactors.TreeEditDistance.Adapter`:

    * `children/1` — the ordered child list of a node (leaves return `[]`).
    * `label/1` — `{kind, primary}`. `kind` is the relabel/structural class
      (`:element`/`:text`/… for HEEx; `:call`/`:literal`/… for Elixir); a kind
      mismatch across a relabel is always a `:structural` `:kind_change`.
      `primary` is unused by the core but kept so adapters share one shape.
    * `relabel_cost/2` — integer cost of turning node `a` into node `b`
      (`0` when fully equal). The core only calls this with same-kind nodes;
      a different kind is hard-coded to cost `1`.
    * `divergences/3` — `(a, b, path)` → the typed divergence list for a
      same-position relabel. The core supplies the child-index `path`; the
      adapter decides which leaf-level differences it surfaces (a tag swap, a
      changed literal, …) and tags the kind. Returning `[]` means "equal here".

  Everything else — mass (node count via `children/1`), post-order indexing,
  leftmost-leaf descendants, keyroots, the forest-distance DP, the structural
  insert/delete descriptors, and the pre-order sort — is generic.

  ## Cost model (integer, no float drift in the DP)

    * delete a node — `1`
    * insert a node — `1`
    * relabel `a`→`b`: `1` if kinds differ (flagged `:structural`), else
      `adapter.relabel_cost(a, b)`.

  ## Similarity

  `similarity(adapter, a, b) = 1 - distance / max(mass_a, mass_b)`, clamped to
  `>= 0.0`.

  ## Divergence descriptor

  `diff/3` returns a flat list in pre-order of the representative (first) tree.
  The core emits `{:structural, path, :insert | :delete}` for inserted/deleted
  subtrees and `{:structural, path, :kind_change}` for a relabel across kinds;
  everything else comes from the adapter's `divergences/3`. The `path` is the
  child-index path from the root (`[]` is the root), so a rewriter can locate
  the node in the raw tree.
  """

  @type path :: [non_neg_integer()]
  @type label :: {atom(), term()}
  @type divergence :: {:structural, path(), :insert | :delete | :kind_change} | tuple()

  defmodule Adapter do
    @moduledoc "Behaviour an ordered-tree shape implements to plug into the TED core."

    @callback children(node :: term()) :: [term()]
    @callback label(node :: term()) :: {atom(), term()}
    @callback relabel_cost(a :: term(), b :: term()) :: non_neg_integer()
    @callback divergences(a :: term(), b :: term(), path :: [non_neg_integer()]) :: [tuple()]
  end

  @doc "Node count of `tree` under `adapter` (every node counts as 1)."
  @spec mass(module(), term()) :: pos_integer()
  def mass(adapter, tree), do: 1 + Enum.sum_by(adapter.children(tree), &mass(adapter, &1))

  @doc "Zhang-Shasha tree-edit distance between two trees under `adapter`."
  @spec distance(module(), term(), term()) :: non_neg_integer()
  def distance(adapter, a, b) do
    pa = preprocess(adapter, a)
    pb = preprocess(adapter, b)
    td = zhang_shasha(adapter, pa, pb)
    Map.fetch!(td, {pa.size, pb.size})
  end

  @doc "Structural similarity in `[0.0, 1.0]`: `1 - distance / max(mass_a, mass_b)`."
  @spec similarity(module(), term(), term()) :: float()
  def similarity(adapter, a, b) do
    denom = max(mass(adapter, a), mass(adapter, b))
    max(0.0, 1.0 - distance(adapter, a, b) / denom)
  end

  @doc """
  Typed divergence list of `b` relative to representative `a`, in pre-order of
  `a`. `[]` iff the trees are identical under `adapter`.
  """
  @spec diff(module(), term(), term()) :: [divergence()]
  def diff(adapter, a, b) do
    pa = preprocess(adapter, a)
    pb = preprocess(adapter, b)
    {_td, ops} = zhang_shasha_with_ops(adapter, pa, pb)
    traceback(adapter, pa, pb, ops) |> Enum.sort_by(&div_sort_key/1)
  end

  # Pre-order of the representative tree, then by kind for determinism when
  # several divergences land on the same path. Path (element 1) and kind
  # (element 0) are shared across all divergence arities.
  defp div_sort_key(d), do: {elem(d, 1), elem(d, 0)}

  # ---- cost model ----------------------------------------------------------

  defp kind(adapter, node), do: node |> adapter.label() |> elem(0)

  defp relabel_cost(adapter, a, b) do
    if kind(adapter, a) != kind(adapter, b),
      do: 1,
      else: adapter.relabel_cost(a, b)
  end

  # ---- post-order preprocessing --------------------------------------------

  # Build the structures Zhang-Shasha needs: 1-based post-order node array,
  # leftmost-leaf-descendant index per node, keyroots, and each node's
  # child-index path from the root (for the diff descriptor).
  defp preprocess(adapter, tree) do
    {nodes, lld, paths, _next, size} = post_walk(adapter, tree, [], 1, %{}, %{}, %{})

    %{
      nodes: nodes,
      lld: lld,
      paths: paths,
      keyroots: keyroots(lld, size),
      size: size
    }
  end

  # Returns {nodes_map, lld_map, paths_map, next_index, last_index}. Post-order:
  # children first (left to right), then the node. `lld` of a node is the index
  # of its leftmost leaf — the index of its first child's lld, or its own index
  # when it is a leaf.
  defp post_walk(adapter, node, path, next, nodes, lld, paths) do
    children = adapter.children(node)

    {nodes, lld, paths, next, first_lld} =
      children
      |> Enum.with_index()
      |> Enum.reduce({nodes, lld, paths, next, nil}, fn {child, ci},
                                                        {nodes, lld, paths, next, first_lld} ->
        {nodes, lld, paths, next, last} =
          post_walk(adapter, child, path ++ [ci], next, nodes, lld, paths)

        {nodes, lld, paths, next, first_lld || Map.fetch!(lld, last)}
      end)

    idx = next
    nodes = Map.put(nodes, idx, node)
    paths = Map.put(paths, idx, path)
    lld = Map.put(lld, idx, first_lld || idx)
    {nodes, lld, paths, next + 1, idx}
  end

  # Keyroots: the topmost node for each distinct leftmost-leaf value, i.e. every
  # index `i` for which no larger index shares its `lld`.
  defp keyroots(lld, size) do
    {keyroots, _seen} =
      size..1//-1
      |> Enum.reduce({[], MapSet.new()}, fn i, {acc, seen} ->
        l = Map.fetch!(lld, i)
        if MapSet.member?(seen, l), do: {acc, seen}, else: {[i | acc], MapSet.put(seen, l)}
      end)

    keyroots
  end

  # ---- Zhang-Shasha core ---------------------------------------------------

  defp zhang_shasha(adapter, pa, pb) do
    {td, _ops} = run(adapter, pa, pb, false)
    td
  end

  defp zhang_shasha_with_ops(adapter, pa, pb), do: run(adapter, pa, pb, true)

  defp run(adapter, pa, pb, keep_ops?) do
    Enum.reduce(pa.keyroots, {%{}, %{}}, fn i, {td, ops} ->
      Enum.reduce(pb.keyroots, {td, ops}, fn j, {td, ops} ->
        treedist(adapter, i, j, pa, pb, td, ops, keep_ops?)
      end)
    end)
  end

  defp treedist(adapter, i, j, pa, pb, td, ops, keep_ops?) do
    lai = Map.fetch!(pa.lld, i)
    lbj = Map.fetch!(pb.lld, j)

    fd = %{{lai - 1, lbj - 1} => 0}

    # delete left prefix
    fd =
      Enum.reduce(lai..i, fd, fn di, fd ->
        Map.put(fd, {di, lbj - 1}, Map.fetch!(fd, {di - 1, lbj - 1}) + 1)
      end)

    # insert right prefix
    fd =
      Enum.reduce(lbj..j, fd, fn dj, fd ->
        Map.put(fd, {lai - 1, dj}, Map.fetch!(fd, {lai - 1, dj - 1}) + 1)
      end)

    {_fd, td, ops} =
      Enum.reduce(lai..i, {fd, td, ops}, fn di, acc ->
        Enum.reduce(lbj..j, acc, fn dj, {fd, td, ops} ->
          fill_cell(adapter, di, dj, i, j, lai, lbj, pa, pb, fd, td, ops, keep_ops?)
        end)
      end)

    {td, ops}
  end

  defp fill_cell(adapter, di, dj, i, j, lai, lbj, pa, pb, fd, td, ops, keep_ops?) do
    node_a = Map.fetch!(pa.nodes, di)
    node_b = Map.fetch!(pb.nodes, dj)
    on_spine? = Map.fetch!(pa.lld, di) == lai and Map.fetch!(pb.lld, dj) == lbj

    del = Map.fetch!(fd, {di - 1, dj}) + 1
    ins = Map.fetch!(fd, {di, dj - 1}) + 1

    sub =
      if on_spine? do
        Map.fetch!(fd, {di - 1, dj - 1}) + relabel_cost(adapter, node_a, node_b)
      else
        Map.fetch!(fd, {Map.fetch!(pa.lld, di) - 1, Map.fetch!(pb.lld, dj) - 1}) +
          Map.fetch!(td, {di, dj})
      end

    {cost, op} = min3(del, ins, sub)
    fd = Map.put(fd, {di, dj}, cost)

    td = if on_spine?, do: Map.put(td, {di, dj}, cost), else: td

    ops =
      if keep_ops? and on_spine?,
        do: Map.put(ops, {i, j, di, dj}, op),
        else: ops

    {fd, td, ops}
  end

  # delete and insert tie-break before substitute so a same-cost structural edit
  # is reported as a structural op, not a silent match.
  defp min3(del, ins, sub) do
    cond do
      sub <= del and sub <= ins -> {sub, :sub}
      del <= ins -> {del, :del}
      true -> {ins, :ins}
    end
  end

  # ---- traceback → divergences ---------------------------------------------

  defp traceback(adapter, pa, pb, ops) do
    collect(adapter, pa.size, pb.size, pa, pb, ops, [])
  end

  defp collect(_adapter, 0, 0, _pa, _pb, _ops, acc), do: acc

  defp collect(_adapter, i, j, pa, _pb, _ops, acc) when i > 0 and j == 0 do
    Enum.reduce(1..i, acc, fn di, acc ->
      [{:structural, Map.fetch!(pa.paths, di), :delete} | acc]
    end)
  end

  defp collect(_adapter, i, j, _pa, pb, _ops, acc) when i == 0 and j > 0 do
    Enum.reduce(1..j, acc, fn dj, acc ->
      [{:structural, Map.fetch!(pb.paths, dj), :insert} | acc]
    end)
  end

  defp collect(adapter, i, j, pa, pb, ops, acc) do
    ki = keyroot_of(i, pa)
    kj = keyroot_of(j, pb)
    walk_forest(adapter, i, j, ki, kj, pa, pb, ops, acc)
  end

  defp walk_forest(adapter, di, dj, ki, kj, pa, pb, ops, acc) do
    lai = Map.fetch!(pa.lld, ki)
    lbj = Map.fetch!(pb.lld, kj)
    step(adapter, di, dj, ki, kj, lai, lbj, pa, pb, ops, acc)
  end

  defp step(_adapter, di, dj, _ki, _kj, lai, lbj, _pa, _pb, _ops, acc)
       when di < lai and dj < lbj,
       do: acc

  defp step(adapter, di, dj, ki, kj, lai, lbj, pa, pb, ops, acc) when dj < lbj do
    acc = [{:structural, Map.fetch!(pa.paths, di), :delete} | acc]
    step(adapter, di - 1, dj, ki, kj, lai, lbj, pa, pb, ops, acc)
  end

  defp step(adapter, di, dj, ki, kj, lai, lbj, pa, pb, ops, acc) when di < lai do
    acc = [{:structural, Map.fetch!(pb.paths, dj), :insert} | acc]
    step(adapter, di, dj - 1, ki, kj, lai, lbj, pa, pb, ops, acc)
  end

  defp step(adapter, di, dj, ki, kj, lai, lbj, pa, pb, ops, acc) do
    on_spine? = Map.fetch!(pa.lld, di) == lai and Map.fetch!(pb.lld, dj) == lbj

    if on_spine? do
      op = Map.get(ops, {ki, kj, di, dj}, :sub)
      apply_spine_op(adapter, op, di, dj, ki, kj, lai, lbj, pa, pb, ops, acc)
    else
      acc = collect(adapter, di, dj, pa, pb, ops, acc)

      step(
        adapter,
        Map.fetch!(pa.lld, di) - 1,
        Map.fetch!(pb.lld, dj) - 1,
        ki,
        kj,
        lai,
        lbj,
        pa,
        pb,
        ops,
        acc
      )
    end
  end

  defp apply_spine_op(adapter, :del, di, dj, ki, kj, lai, lbj, pa, pb, ops, acc) do
    acc = [{:structural, Map.fetch!(pa.paths, di), :delete} | acc]
    step(adapter, di - 1, dj, ki, kj, lai, lbj, pa, pb, ops, acc)
  end

  defp apply_spine_op(adapter, :ins, di, dj, ki, kj, lai, lbj, pa, pb, ops, acc) do
    acc = [{:structural, Map.fetch!(pb.paths, dj), :insert} | acc]
    step(adapter, di, dj - 1, ki, kj, lai, lbj, pa, pb, ops, acc)
  end

  defp apply_spine_op(adapter, :sub, di, dj, ki, kj, lai, lbj, pa, pb, ops, acc) do
    node_a = Map.fetch!(pa.nodes, di)
    node_b = Map.fetch!(pb.nodes, dj)
    path = Map.fetch!(pa.paths, di)
    acc = divergences(adapter, node_a, node_b, path) ++ acc
    step(adapter, di - 1, dj - 1, ki, kj, lai, lbj, pa, pb, ops, acc)
  end

  defp keyroot_of(idx, p) do
    l = Map.fetch!(p.lld, idx)

    p.keyroots
    |> Enum.filter(fn k -> Map.fetch!(p.lld, k) == l and k >= idx end)
    |> Enum.min()
  end

  # A relabel across kinds is structural; otherwise the adapter decides which
  # leaf-level divergences it surfaces.
  defp divergences(adapter, a, b, path) do
    if kind(adapter, a) != kind(adapter, b),
      do: [{:structural, path, :kind_change}],
      else: adapter.divergences(a, b, path)
  end
end
