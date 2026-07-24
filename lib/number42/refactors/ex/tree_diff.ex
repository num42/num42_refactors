defmodule Number42.Refactors.Ex.TreeDiff do
  @moduledoc """
  Tree-edit-distance over **normalized Elixir AST** — the basis for Elixir
  near-clone detection (`Ex.NearClones`), and the Elixir analogue of
  `Heex.TreeDiff`. A thin adapter over the tree-agnostic Zhang-Shasha core in
  `Number42.Refactors.Analysis.TreeEditDistance`.

  ## Why normalize first

  The exact-hash clone detectors (`ExtractIntraModuleClone`,
  `ExtractExpressionClone`) only cluster fragments whose normalized hash matches
  — they cannot see a fragment that is ~90% the same but differs in one spot. To
  measure that "near" distance meaningfully, the two ASTs are first put through
  the *same* normalization the hashers use, so the differences TED reports are
  genuine structural/semantic ones and not noise from formatting, pipe-sugar, or
  variable naming:

    * `AstHelpers.inline_pipes/1` — `x |> f(y)` and `f(x, y)` normalize equal.
    * metadata stripped — line/column never count as a divergence.
    * variables α-renamed to de-Bruijn-style indices (`$var0`, `$var1`, …) — two
      blocks that differ only in local names are *not* a near-clone, they're an
      exact one.

  After normalization the tree is reshaped into a small tagged node form so the
  divergence descriptor can speak in meaningful kinds (`:literal`, `:call`,
  `:var`, …) instead of raw AST tuples:

      {:call, form, [child]}     # a `{form, _, args}` call/operator node
      {:list, [child]}           # an AST list (arg lists, blocks, do-bodies)
      {:pair, [k, v]}            # a 2-tuple (keyword pair, map entry)
      {:tuple, [child]}          # a 2-/n-tuple literal `{:{}, _, ...}`
      {:var, idx}                # a renamed local variable (leaf)
      {:literal, value}          # an atom/number/string literal (leaf)
      {:atom, name}              # a bare form atom in arg position (leaf)

  ## Cost model

    * delete / insert a node — `1`
    * relabel `a`→`b`:
      * different kind (`:call` vs `:literal`) — `1`, flagged `:structural`
      * same kind, equal payload — `0`
      * same kind, differing payload — `1`

  ## Divergence descriptor

  `diff/2` returns typed divergences in pre-order of the representative tree:

    * `{:literal, path, from, to}` — a changed literal (the liftable case: a
      differing literal becomes a parameter)
    * `{:call, path, from, to}` — a changed call/operator form (e.g. `+` vs `-`)
    * `{:var, path, from, to}` — a renamed-variable slot mismatch
    * `{:atom, path, from, to}` — a changed bare atom
    * `{:structural, path, op}` — `:insert | :delete | :kind_change`: a node
      present on only one side, or a relabel across kinds. A merge/extract
      refactor declines any cluster with a `:structural` divergence.
  """

  @behaviour Number42.Refactors.Analysis.TreeEditDistance.Adapter

  alias Number42.Refactors.Analysis.AstHelpers
  alias Number42.Refactors.Analysis.TreeEditDistance

  defguardp is_literal(v)
            when is_integer(v) or is_float(v) or is_binary(v) or is_boolean(v) or is_nil(v)

  @type nnode ::
          {:call, atom(), [nnode()]}
          | {:list, [nnode()]}
          | {:pair, [nnode()]}
          | {:tuple, [nnode()]}
          | {:var, non_neg_integer()}
          | {:literal, term()}
          | {:atom, atom()}

  @type path :: [non_neg_integer()]

  @type divergence ::
          {:literal, path(), term(), term()}
          | {:call, path(), atom(), atom()}
          | {:var, path(), non_neg_integer(), non_neg_integer()}
          | {:atom, path(), atom(), atom()}
          | {:structural, path(), :insert | :delete | :kind_change}

  @doc """
  Normalize a raw Elixir AST into the tagged near-clone node form: pipe-sugar
  inlined, metadata stripped, local variables α-renamed to de-Bruijn indices.
  Two structurally-equal-modulo-renaming fragments normalize to equal trees.
  """
  @spec normalize(Macro.t()) :: nnode()
  def normalize(ast) do
    ast
    |> AstHelpers.inline_pipes()
    |> strip_meta()
    |> rename_vars()
    |> to_node()
  end

  @doc "Node count of a normalized tree (every node counts as 1)."
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

  # ---- normalization (shared with ExtractExpressionClone's fingerprint) ----

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp rename_vars(ast) do
    {result, _} = Macro.prewalk(ast, %{}, &rename_var_node/2)
    result
  end

  defp rename_var_node({name, [], ctx} = node, acc)
       when is_atom(name) and is_atom(ctx) do
    cond do
      AstHelpers.underscore?(name) ->
        {node, acc}

      Map.has_key?(acc, name) ->
        {{:"$var", [], [Map.fetch!(acc, name)]}, acc}

      true ->
        idx = map_size(acc)
        {{:"$var", [], [idx]}, Map.put(acc, name, idx)}
    end
  end

  defp rename_var_node(node, acc), do: {node, acc}

  # ---- reshape normalized AST into the tagged node form --------------------

  # Renamed variable (set by rename_vars) — a leaf carrying its de-Bruijn slot.
  defp to_node({:"$var", [], [idx]}), do: {:var, idx}

  # Sourceror/Code wraps a single literal as `{:__block__, [], [value]}`; after
  # strip_meta the literal-bearing block is a leaf if `value` is a literal.
  defp to_node({:__block__, [], [value]}) when is_literal(value), do: {:literal, value}

  # An n-tuple literal node `{:{}, [], elems}`.
  defp to_node({:{}, [], elems}), do: {:tuple, Enum.map(elems, &to_node/1)}

  # A map literal `{:%{}, [], pairs}`.
  defp to_node({:%{}, [], pairs}), do: {:list, Enum.map(pairs, &to_node/1)}

  # A variable node `{name, [], ctx}` where the third element is the context
  # atom (not an arg list) — this is what distinguishes a var from a 0-arity
  # call. `rename_vars` left underscore-prefixed names alone (they never
  # disambiguate a clone), so collapse every `_foo` to one stable `:_` slot so
  # two ASTs differing only in underscore-var names stay equal.
  defp to_node({name, [], ctx}) when is_atom(name) and is_atom(ctx) do
    if AstHelpers.underscore?(name), do: {:var, :_}, else: {:atom, name}
  end

  # A general call/operator/macro node.
  defp to_node({form, [], args}) when is_list(args),
    do: {:call, form, Enum.map(args, &to_node/1)}

  # A 2-tuple in AST position (keyword pair, map entry, do-block kw).
  defp to_node({a, b}), do: {:pair, [to_node(a), to_node(b)]}

  # An AST list (argument lists, block exprs).
  defp to_node(list) when is_list(list), do: {:list, Enum.map(list, &to_node/1)}

  # Bare literals and atoms.
  defp to_node(value) when is_literal(value), do: {:literal, value}
  defp to_node(atom) when is_atom(atom), do: {:atom, atom}

  # Defensive catch-all: any AST shape not modelled above (a charlist, a
  # 3-tuple with a non-atom form, …) collapses to one opaque leaf rather than
  # crashing a whole-corpus scan. Two such nodes compare equal iff identical.
  defp to_node(other), do: {:literal, other}

  # ---- adapter hooks -------------------------------------------------------

  @impl true
  def children({:call, _form, args}), do: args
  def children({:list, items}), do: items
  def children({:pair, items}), do: items
  def children({:tuple, items}), do: items
  def children(_leaf), do: []

  @impl true
  def label({:call, form, _}), do: {:call, form}
  def label({:list, _}), do: {:list, nil}
  def label({:pair, _}), do: {:pair, nil}
  def label({:tuple, _}), do: {:tuple, nil}
  def label({:var, idx}), do: {:var, idx}
  def label({:literal, value}), do: {:literal, value}
  def label({:atom, atom}), do: {:atom, atom}

  @impl true
  def relabel_cost({:call, fa, _}, {:call, fb, _}), do: bool_cost(fa == fb)
  def relabel_cost({:var, ia}, {:var, ib}), do: bool_cost(ia == ib)
  def relabel_cost({:literal, va}, {:literal, vb}), do: bool_cost(va == vb)
  def relabel_cost({:atom, aa}, {:atom, ab}), do: bool_cost(aa == ab)
  # :list / :pair / :tuple carry no payload — equal kind ⇒ equal label.
  def relabel_cost(_, _), do: 0

  defp bool_cost(true), do: 0
  defp bool_cost(false), do: 1

  @impl true
  def divergences({:call, fa, _}, {:call, fb, _}, path),
    do: if(fa == fb, do: [], else: [{:call, path, fa, fb}])

  def divergences({:var, ia}, {:var, ib}, path),
    do: if(ia == ib, do: [], else: [{:var, path, ia, ib}])

  def divergences({:literal, va}, {:literal, vb}, path),
    do: if(va == vb, do: [], else: [{:literal, path, va, vb}])

  def divergences({:atom, aa}, {:atom, ab}, path),
    do: if(aa == ab, do: [], else: [{:atom, path, aa, ab}])

  def divergences(_a, _b, _path), do: []
end
