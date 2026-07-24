defmodule Number42.Refactors.Analysis.Heex.Motif do
  @moduledoc """
  Reduce a `Number42.Refactors.Analysis.Heex.Tree` subtree to a **motif key** — a
  structural fingerprint that is agnostic to assign names, EEx expression
  bodies, attribute *values*, and literal text content, but keeps the
  tag tree, the set of attribute *names* per element, and **which leaf
  positions are dynamic** (an EEx slot) vs. **static** (literal text).

  ## Why a third fingerprint, distinct from `Heex.Normalizer`

  `Normalizer`'s strongest mode (`:attrs_stripped`) still keeps EEx
  bodies and text byte-identical, so it only clusters subtrees that
  differ in their *attribute sets*. A recurring **motif** — `data_table`,
  `select_field`, a card — recurs across files with *different assign
  names and different label text* in the same shape. Those are exactly
  the differences a motif key must see through, because they are what a
  shared component would *parameterise*. So the motif key:

    * keeps tag names and the tag tree (the skeleton);
    * keeps the **sorted set of attribute names** on each element (a
      `<button phx-click=…>` and an `<img src=…>` are not the same
      motif), but drops attribute *values* (they become per-call args);
    * replaces every dynamic leaf (`{…}` interpolation, `<%= … %>`
      block) with a positional `:slot` marker — its body (and the
      assigns it reads) is per-call, not part of the shape;
    * replaces literal text with a `:static_text` marker — so a fixed
      heading and a dynamic heading in the same position are *different*
      motifs (one is parameterised, the other is not).

  Two subtrees with the same motif key have identical structure and
  identical dynamic-vs-static topology; they differ only in the contents
  of their slots (assigns/text) and their attribute values — precisely
  the per-occurrence inputs a shared function component would accept.

  ## `slots/1`

  Returns the dynamic slots of a subtree in **document (pre-order)**,
  each annotated with the assign names it reads. Because two
  motif-equal subtrees share the same skeleton, their slot lists line up
  positionally — `slots(a)` and `slots(b)` have the same length and the
  i-th slot of each plays the same structural role. That positional
  alignment is what lets the cross-file refactor turn slot i into one
  shared `attr` and pass each occurrence's own value.
  """

  alias Number42.Refactors.Analysis.Heex.Tree

  @type slot :: %{kind: :expr | :block, assigns: [String.t()], code: String.t()}

  @doc """
  Structural motif key for `node`: a blake2b hash over the
  assign/text/value-stripped skeleton. Equal keys ⇒ same motif.
  """
  @spec key(Tree.node_t()) :: binary()
  def key(node) do
    node
    |> skeleton()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:blake2b, &1))
  end

  @doc """
  The dynamic slots of `node` in pre-order, each `%{kind, assigns, code}`.
  Static text leaves are not slots.
  """
  @spec slots(Tree.node_t() | [Tree.node_t()]) :: [slot()]
  def slots(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &slots/1)

  def slots({:element, _tag, attrs, children, _meta}) do
    attr_slots(attrs) ++ slots(children)
  end

  def slots({:eex_block, header, children, _meta}) do
    [%{kind: :block, assigns: assigns_in(header), code: normalize_ws(header)} | slots(children)]
  end

  def slots({:eex_expr, code, _meta}) do
    [%{kind: :expr, assigns: assigns_in(code), code: normalize_ws(code)}]
  end

  def slots({:text, _text, _meta}), do: []

  # ---- skeleton (the hashed shape) -----------------------------------------

  defp skeleton({:element, tag, attrs, children, _meta}) do
    {:element, tag, attr_name_shape(attrs), Enum.map(children, &skeleton/1)}
  end

  defp skeleton({:eex_block, _header, children, _meta}) do
    # block header (`for x <- @xs`) varies in assigns/binding names; keep only
    # that "a block opens here" plus the child shape.
    {:eex_block, :slot, Enum.map(children, &skeleton/1)}
  end

  defp skeleton({:eex_expr, _code, _meta}), do: {:eex_expr, :slot}
  defp skeleton({:text, _text, _meta}), do: {:text, :static_text}

  # Keep the *names* of attributes (and whether each is dynamic), drop values.
  # `phx-click` vs `id` is a real structural difference; `phx-click="a"` vs
  # `phx-click="b"` is not.
  defp attr_name_shape(attrs) do
    attrs
    |> Enum.map(fn
      {name, {:expr, _}} -> {name, :dynamic}
      {name, {:string, _}} -> {name, :static}
    end)
    |> Enum.sort()
  end

  # ---- slot extraction helpers ---------------------------------------------

  defp attr_slots(attrs) do
    Enum.flat_map(attrs, fn
      {_name, {:expr, code}} ->
        [%{kind: :expr, assigns: assigns_in(code), code: normalize_ws(code)}]

      {_name, {:string, _}} ->
        []
    end)
  end

  defp assigns_in(code) when is_binary(code) do
    ~r/@([a-z_][a-zA-Z0-9_]*)/
    |> Regex.scan(code)
    |> Enum.map(fn [_, n] -> n end)
    |> Enum.uniq()
  end

  defp normalize_ws(code) when is_binary(code) do
    code |> String.replace(~r/\s+/, " ") |> String.trim()
  end
end
