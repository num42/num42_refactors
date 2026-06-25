defmodule Number42.Refactors.Heex.TreeDiff do
  @moduledoc """
  Tree-edit-distance over **normalized** HEEx trees (the plain-tuple shape
  `Heex.Normalizer.normalize/2` produces) — the basis for near-clone detection.

  Exact-hash clustering (`Heex.Clones`/`Heex.Fingerprint`) only sees two
  fragments as the same when their normalized hashes match in some mode. A
  *near* clone — the same component hand-written twice with a tag swapped, a
  class string drifted, one heading reworded — shares no hash in any mode. This
  module measures how far apart two trees are with the classic Zhang-Shasha
  ordered-tree edit distance, and reports *which* nodes diverge and *how*, so a
  merge refactor can decide whether the difference is mechanically reconcilable.

  ## Cost model

  Every operation is an integer (no float drift in the DP):

    * delete a node — `1`
    * insert a node — `1`
    * relabel node `a` into node `b`:
      * different node kind (`:text` vs `:element`) — `1`, flagged `:structural`
      * `:element`: `tag_cost + attr_cost`, each `0` or `1` (so an element
        differing in both tag and attrs costs `2`)
      * `:eex_block` / `:eex_expr` / `:text`: `0` if equal, else `1`

  A node's **label** for relabel purposes is `{kind, primary}` — tag for
  elements, header for blocks, code for exprs, text for text. Attributes are
  *deliberately* excluded from the label and compared inside the relabel cost.
  This keeps a pure class-difference a cheap relabel (cost 1) instead of a
  delete+insert, and — crucially — lets the divergence descriptor recover
  *per-attr* granularity (which attr changed) from the same comparison the cost
  used. Charging one unit per divergent element (not per-attr) keeps `edits`
  commensurate with `mass`, which counts the element as one node.

  ## Similarity

  `similarity(a, b) = 1 - distance(a, b) / max(mass(a), mass(b))`, clamped to
  `>= 0.0`. The real target (two ~30-node components differing by tag + class +
  one text → `distance 3`) lands ~0.90, comfortably above a 0.85 clustering
  floor.

  ## Divergence descriptor

  `diff/2` runs the same recurrence with a traceback and returns a flat list of
  typed divergences in pre-order of the representative (first arg) tree. A
  divergence carries the child-index `path` from the root (`[]` is the root),
  so a downstream rewriter can locate the node in the *raw* tree:

    * `{:tag, path, from, to}` — element tag relabel
    * `{:attr_value, path, name, from, to}` — one attr changed/added/removed
    * `{:text, path, from, to}` — text relabel
    * `{:structural, path, op}` — `op` in `:insert | :delete | :kind_change`:
      an inserted/deleted subtree, or a relabel across node kinds or across
      differing `eex_block`/`eex_expr` bodies. The merge refactor declines any
      cluster with a `:structural` divergence — only `:tag`, `:attr_value`
      (class) and `:text` are mechanically reconcilable.
  """

  @type attr_value :: {:string, String.t()} | {:expr, String.t()}

  @type nnode ::
          {:element, String.t(), [{String.t(), attr_value()}], [nnode()]}
          | {:eex_block, String.t(), [nnode()]}
          | {:eex_expr, String.t()}
          | {:text, String.t()}

  @type path :: [non_neg_integer()]

  @type divergence ::
          {:tag, path(), String.t(), String.t()}
          | {:attr_value, path(), String.t(), attr_value() | nil, attr_value() | nil}
          | {:text, path(), String.t(), String.t()}
          | {:structural, path(), :insert | :delete | :kind_change}

  @doc "Node count of a normalized tree (mirrors `Fingerprint.mass/1` over `nnode`)."
  @spec mass(nnode()) :: pos_integer()
  def mass({:element, _tag, _attrs, children}), do: 1 + Enum.sum_by(children, &mass/1)
  def mass({:eex_block, _header, children}), do: 1 + Enum.sum_by(children, &mass/1)
  def mass({:eex_expr, _code}), do: 1
  def mass({:text, _text}), do: 1

  @doc "Zhang-Shasha tree-edit distance between two normalized trees."
  @spec distance(nnode(), nnode()) :: non_neg_integer()
  def distance(a, b) do
    pa = preprocess(a)
    pb = preprocess(b)
    td = zhang_shasha(pa, pb)
    Map.fetch!(td, {pa.size, pb.size})
  end

  @doc "Structural similarity in `[0.0, 1.0]`: `1 - distance / max(mass_a, mass_b)`."
  @spec similarity(nnode(), nnode()) :: float()
  def similarity(a, b) do
    denom = max(mass(a), mass(b))
    max(0.0, 1.0 - distance(a, b) / denom)
  end

  @doc """
  Typed divergence list of `b` relative to representative `a`, in pre-order of
  `a`. `[]` iff the trees are identical.
  """
  @spec diff(nnode(), nnode()) :: [divergence()]
  def diff(a, b) do
    pa = preprocess(a)
    pb = preprocess(b)
    {td, ops} = zhang_shasha_with_ops(pa, pb)
    traceback(pa, pb, td, ops) |> Enum.sort_by(&div_sort_key/1)
  end

  # Sort divergences in pre-order of the representative tree, then by kind for
  # determinism when several land on the same path. Path (element 1) and kind
  # (element 0) are shared across all divergence arities.
  defp div_sort_key(d), do: {elem(d, 1), elem(d, 0)}

  # ---- cost model ----------------------------------------------------------

  defp label({:element, tag, _attrs, _ch}), do: {:element, tag}
  defp label({:eex_block, header, _ch}), do: {:eex_block, header}
  defp label({:eex_expr, code}), do: {:eex_expr, code}
  defp label({:text, text}), do: {:text, text}

  defp kind(node), do: node |> label() |> elem(0)

  defp relabel_cost(a, b) do
    cond do
      kind(a) != kind(b) -> 1
      true -> same_kind_relabel_cost(a, b)
    end
  end

  defp same_kind_relabel_cost({:element, ta, aa, _}, {:element, tb, ab, _}) do
    tag_cost = if ta == tb, do: 0, else: 1
    attr_cost = if Enum.sort(aa) == Enum.sort(ab), do: 0, else: 1
    tag_cost + attr_cost
  end

  defp same_kind_relabel_cost({:eex_block, ha, _}, {:eex_block, hb, _}),
    do: if(ha == hb, do: 0, else: 1)

  defp same_kind_relabel_cost({:eex_expr, ca}, {:eex_expr, cb}),
    do: if(ca == cb, do: 0, else: 1)

  defp same_kind_relabel_cost({:text, ta}, {:text, tb}), do: if(ta == tb, do: 0, else: 1)

  # ---- post-order preprocessing --------------------------------------------

  # Build the structures Zhang-Shasha needs: 1-based post-order node array,
  # leftmost-leaf-descendant index per node, keyroots, and each node's
  # child-index path from the root (for the diff descriptor).
  defp preprocess(tree) do
    {nodes, lld, paths, _next, size} = post_walk(tree, [], 1, %{}, %{}, %{})

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
  defp post_walk(node, path, next, nodes, lld, paths) do
    children = children_of(node)

    {nodes, lld, paths, next, first_lld} =
      children
      |> Enum.with_index()
      |> Enum.reduce({nodes, lld, paths, next, nil}, fn {child, ci},
                                                        {nodes, lld, paths, next, first_lld} ->
        {nodes, lld, paths, next, last} =
          post_walk(child, path ++ [ci], next, nodes, lld, paths)

        {nodes, lld, paths, next, first_lld || Map.fetch!(lld, last)}
      end)

    idx = next
    nodes = Map.put(nodes, idx, node)
    paths = Map.put(paths, idx, path)
    lld = Map.put(lld, idx, first_lld || idx)
    {nodes, lld, paths, next + 1, idx}
  end

  defp children_of({:element, _t, _a, ch}), do: ch
  defp children_of({:eex_block, _h, ch}), do: ch
  defp children_of(_leaf), do: []

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

  defp zhang_shasha(pa, pb) do
    {td, _ops} = run(pa, pb, false)
    td
  end

  defp zhang_shasha_with_ops(pa, pb), do: run(pa, pb, true)

  # Returns {td, ops} where td maps {i, j} -> tree-distance and ops maps
  # {di, dj} -> the chosen operation at that forest cell (only the spine cells
  # that persist into td also record :rel ops keyed under td-relevant indices;
  # but for traceback we record the full per-cell op map keyed by {i,j,di,dj}).
  defp run(pa, pb, keep_ops?) do
    Enum.reduce(pa.keyroots, {%{}, %{}}, fn i, {td, ops} ->
      Enum.reduce(pb.keyroots, {td, ops}, fn j, {td, ops} ->
        treedist(i, j, pa, pb, td, ops, keep_ops?)
      end)
    end)
  end

  defp treedist(i, j, pa, pb, td, ops, keep_ops?) do
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
          fill_cell(di, dj, i, j, lai, lbj, pa, pb, fd, td, ops, keep_ops?)
        end)
      end)

    {td, ops}
  end

  defp fill_cell(di, dj, i, j, lai, lbj, pa, pb, fd, td, ops, keep_ops?) do
    node_a = Map.fetch!(pa.nodes, di)
    node_b = Map.fetch!(pb.nodes, dj)
    on_spine? = Map.fetch!(pa.lld, di) == lai and Map.fetch!(pb.lld, dj) == lbj

    del = Map.fetch!(fd, {di - 1, dj}) + 1
    ins = Map.fetch!(fd, {di, dj - 1}) + 1

    sub =
      if on_spine? do
        Map.fetch!(fd, {di - 1, dj - 1}) + relabel_cost(node_a, node_b)
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

  # Walk the spine ops of the top-level treedist (roots i=size_a, j=size_b)
  # backward, decomposing each substitution into typed divergences and each
  # delete/insert into a structural op. Because td/ops only persist spine cells,
  # we re-descend through subtree boundaries using the same {i,j} dispatch the
  # forward pass used.
  defp traceback(pa, pb, _td, ops) do
    collect(pa.size, pb.size, pa, pb, ops, [])
  end

  # collect over the forest rooted at the keyroot pair containing (i, j).
  defp collect(0, 0, _pa, _pb, _ops, acc), do: acc

  defp collect(i, j, pa, _pb, _ops, acc) when i > 0 and j == 0 do
    # everything left is deletions
    Enum.reduce(1..i, acc, fn di, acc ->
      [{:structural, Map.fetch!(pa.paths, di), :delete} | acc]
    end)
  end

  defp collect(i, j, _pa, pb, _ops, acc) when i == 0 and j > 0 do
    Enum.reduce(1..j, acc, fn dj, acc ->
      [{:structural, Map.fetch!(pb.paths, dj), :insert} | acc]
    end)
  end

  defp collect(i, j, pa, pb, ops, acc) do
    ki = keyroot_of(i, pa)
    kj = keyroot_of(j, pb)
    walk_forest(i, j, ki, kj, pa, pb, ops, acc)
  end

  # Walk a single forest-distance region backward from (i, j) down to the
  # (lld-1, lld-1) origin of its keyroot pair.
  defp walk_forest(di, dj, ki, kj, pa, pb, ops, acc) do
    lai = Map.fetch!(pa.lld, ki)
    lbj = Map.fetch!(pb.lld, kj)
    step(di, dj, ki, kj, lai, lbj, pa, pb, ops, acc)
  end

  defp step(di, dj, _ki, _kj, lai, lbj, _pa, _pb, _ops, acc)
       when di < lai and dj < lbj,
       do: acc

  defp step(di, dj, ki, kj, lai, lbj, pa, pb, ops, acc) when dj < lbj do
    # only deletes remain
    acc = [{:structural, Map.fetch!(pa.paths, di), :delete} | acc]
    step(di - 1, dj, ki, kj, lai, lbj, pa, pb, ops, acc)
  end

  defp step(di, dj, ki, kj, lai, lbj, pa, pb, ops, acc) when di < lai do
    acc = [{:structural, Map.fetch!(pb.paths, dj), :insert} | acc]
    step(di, dj - 1, ki, kj, lai, lbj, pa, pb, ops, acc)
  end

  defp step(di, dj, ki, kj, lai, lbj, pa, pb, ops, acc) do
    on_spine? = Map.fetch!(pa.lld, di) == lai and Map.fetch!(pb.lld, dj) == lbj

    if on_spine? do
      op = Map.get(ops, {ki, kj, di, dj}, :sub)
      apply_spine_op(op, di, dj, ki, kj, lai, lbj, pa, pb, ops, acc)
    else
      # descend into the subtree pair (di, dj), then continue left of their llds
      acc = collect(di, dj, pa, pb, ops, acc)

      step(
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

  defp apply_spine_op(:del, di, dj, ki, kj, lai, lbj, pa, pb, ops, acc) do
    acc = [{:structural, Map.fetch!(pa.paths, di), :delete} | acc]
    step(di - 1, dj, ki, kj, lai, lbj, pa, pb, ops, acc)
  end

  defp apply_spine_op(:ins, di, dj, ki, kj, lai, lbj, pa, pb, ops, acc) do
    acc = [{:structural, Map.fetch!(pb.paths, dj), :insert} | acc]
    step(di, dj - 1, ki, kj, lai, lbj, pa, pb, ops, acc)
  end

  defp apply_spine_op(:sub, di, dj, ki, kj, lai, lbj, pa, pb, ops, acc) do
    node_a = Map.fetch!(pa.nodes, di)
    node_b = Map.fetch!(pb.nodes, dj)
    path = Map.fetch!(pa.paths, di)
    acc = divergences(node_a, node_b, path) ++ acc
    step(di - 1, dj - 1, ki, kj, lai, lbj, pa, pb, ops, acc)
  end

  defp keyroot_of(idx, p) do
    l = Map.fetch!(p.lld, idx)

    p.keyroots
    |> Enum.filter(fn k -> Map.fetch!(p.lld, k) == l and k >= idx end)
    |> Enum.min()
  end

  # ---- divergence decomposition --------------------------------------------

  defp divergences(a, b, path) do
    cond do
      kind(a) != kind(b) -> [{:structural, path, :kind_change}]
      true -> same_kind_divergences(a, b, path)
    end
  end

  defp same_kind_divergences({:element, ta, aa, _}, {:element, tb, ab, _}, path) do
    tag = if ta == tb, do: [], else: [{:tag, path, ta, tb}]
    tag ++ attr_divergences(aa, ab, path)
  end

  defp same_kind_divergences({:text, ta}, {:text, tb}, path) do
    if ta == tb, do: [], else: [{:text, path, ta, tb}]
  end

  defp same_kind_divergences({:eex_block, ha, _}, {:eex_block, hb, _}, path) do
    if ha == hb, do: [], else: [{:structural, path, :kind_change}]
  end

  defp same_kind_divergences({:eex_expr, ca}, {:eex_expr, cb}, path) do
    if ca == cb, do: [], else: [{:structural, path, :kind_change}]
  end

  # Compare two attr lists by name (both Normalizer-sorted). Emit one
  # :attr_value per name whose value differs or that is present on only one side.
  defp attr_divergences(aa, ab, path) do
    ma = Map.new(aa)
    mb = Map.new(ab)
    names = MapSet.union(MapSet.new(Map.keys(ma)), MapSet.new(Map.keys(mb)))

    names
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      va = Map.get(ma, name)
      vb = Map.get(mb, name)
      if va == vb, do: [], else: [{:attr_value, path, name, va, vb}]
    end)
  end
end
