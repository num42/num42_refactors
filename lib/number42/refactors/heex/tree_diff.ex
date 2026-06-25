defmodule Number42.Refactors.Heex.TreeDiff do
  @moduledoc """
  Tree-edit-distance over **normalized** HEEx trees (the plain-tuple shape
  `Heex.Normalizer.normalize/2` produces) — the basis for near-clone detection.

  This is a thin HEEx adapter over the tree-agnostic Zhang-Shasha core in
  `Number42.Refactors.TreeEditDistance`. All the DP, traceback, and structural
  insert/delete bookkeeping live in the core; this module only supplies the four
  HEEx-specific hooks (`children/1`, `label/1`, `relabel_cost/2`,
  `divergences/3`) and re-exports the same `mass/distance/similarity/diff` API
  the near-clone detector already depends on.

  Exact-hash clustering (`Heex.Clones`/`Heex.Fingerprint`) only sees two
  fragments as the same when their normalized hashes match in some mode. A
  *near* clone — the same component hand-written twice with a tag swapped, a
  class string drifted, one heading reworded — shares no hash in any mode. TED
  measures how far apart two trees are and reports *which* nodes diverge and
  *how*, so a merge refactor can decide whether the difference is mechanically
  reconcilable.

  ## Cost model

    * delete / insert a node — `1`
    * relabel `a`→`b`:
      * different node kind (`:text` vs `:element`) — `1`, flagged `:structural`
      * `:element`: `tag_cost + attr_cost`, each `0` or `1` (an element
        differing in both tag and attrs costs `2`)
      * `:eex_block` / `:eex_expr` / `:text`: `0` if equal, else `1`

  A node's **label** for relabel purposes is `{kind, primary}` — tag for
  elements, header for blocks, code for exprs, text for text. Attributes are
  *deliberately* excluded from the label and compared inside the relabel cost,
  so a pure class-difference is a cheap relabel (cost 1) and the divergence
  descriptor can recover *per-attr* granularity.

  ## Similarity

  `similarity(a, b) = 1 - distance(a, b) / max(mass(a), mass(b))`, clamped to
  `>= 0.0`. The real target (two ~30-node components differing by tag + class +
  one text → `distance 3`) lands ~0.90, above a 0.85 clustering floor.

  ## Divergence descriptor

  `diff/2` returns a flat list of typed divergences in pre-order of the
  representative (first arg) tree, each carrying the child-index `path` from the
  root (`[]` is the root):

    * `{:tag, path, from, to}` — element tag relabel
    * `{:attr_value, path, name, from, to}` — one attr changed/added/removed
    * `{:text, path, from, to}` — text relabel
    * `{:structural, path, op}` — `op` in `:insert | :delete | :kind_change`.
      The merge refactor declines any cluster with a `:structural` divergence —
      only `:tag`, `:attr_value` (class) and `:text` are mechanically
      reconcilable.
  """

  @behaviour Number42.Refactors.TreeEditDistance.Adapter

  alias Number42.Refactors.TreeEditDistance

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
  def mass(tree), do: TreeEditDistance.mass(__MODULE__, tree)

  @doc "Zhang-Shasha tree-edit distance between two normalized trees."
  @spec distance(nnode(), nnode()) :: non_neg_integer()
  def distance(a, b), do: TreeEditDistance.distance(__MODULE__, a, b)

  @doc "Structural similarity in `[0.0, 1.0]`: `1 - distance / max(mass_a, mass_b)`."
  @spec similarity(nnode(), nnode()) :: float()
  def similarity(a, b), do: TreeEditDistance.similarity(__MODULE__, a, b)

  @doc """
  Typed divergence list of `b` relative to representative `a`, in pre-order of
  `a`. `[]` iff the trees are identical.
  """
  @spec diff(nnode(), nnode()) :: [divergence()]
  def diff(a, b), do: TreeEditDistance.diff(__MODULE__, a, b)

  # ---- adapter hooks -------------------------------------------------------

  @impl true
  def children({:element, _t, _a, ch}), do: ch
  def children({:eex_block, _h, ch}), do: ch
  def children(_leaf), do: []

  @impl true
  def label({:element, tag, _attrs, _ch}), do: {:element, tag}
  def label({:eex_block, header, _ch}), do: {:eex_block, header}
  def label({:eex_expr, code}), do: {:eex_expr, code}
  def label({:text, text}), do: {:text, text}

  @impl true
  def relabel_cost({:element, ta, aa, _}, {:element, tb, ab, _}) do
    tag_cost = if ta == tb, do: 0, else: 1
    attr_cost = if Enum.sort(aa) == Enum.sort(ab), do: 0, else: 1
    tag_cost + attr_cost
  end

  def relabel_cost({:eex_block, ha, _}, {:eex_block, hb, _}), do: bool_cost(ha == hb)
  def relabel_cost({:eex_expr, ca}, {:eex_expr, cb}), do: bool_cost(ca == cb)
  def relabel_cost({:text, ta}, {:text, tb}), do: bool_cost(ta == tb)

  defp bool_cost(true), do: 0
  defp bool_cost(false), do: 1

  @impl true
  def divergences({:element, ta, aa, _}, {:element, tb, ab, _}, path) do
    tag = if ta == tb, do: [], else: [{:tag, path, ta, tb}]
    tag ++ attr_divergences(aa, ab, path)
  end

  def divergences({:text, ta}, {:text, tb}, path) do
    if ta == tb, do: [], else: [{:text, path, ta, tb}]
  end

  def divergences({:eex_block, ha, _}, {:eex_block, hb, _}, path) do
    if ha == hb, do: [], else: [{:structural, path, :kind_change}]
  end

  def divergences({:eex_expr, ca}, {:eex_expr, cb}, path) do
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
