defmodule Number42.Refactors.Heex.Normalizer do
  @moduledoc """
  Normalize a HEEx tree (from `Number42.Refactors.Heex.Tree`) into
  a canonical shape suitable for hashing.

  Three modes are supported, exposed both as detection levels and as
  separate hash inputs:

  - `:exact` — keep tag, attrs, attr-values, text, EEx expression
    bodies. Two trees hash equal only if they are byte-identical
    (modulo whitespace already trimmed by the tree pass).

  - `:class_stripped` — replace every `class` (and `:class`) attribute
    value with a single placeholder. Tailwind-style cosmetic
    differences disappear; structural differences (other attrs, tag
    names, children) still distinguish trees.

  - `:attrs_stripped` — drop **all** attributes from elements. Only
    the tag tree + text + EEx structure survives. Strongest similarity
    bucket; finds parametric clones whose only difference is the
    attribute set (e.g. `<button phx-click="a">` vs `<button
    phx-click="b">`).

  Meta (line numbers) is always dropped — it never participates in
  structural identity.
  """

  alias Number42.Refactors.Heex.Tree

  @type mode :: :exact | :class_stripped | :attrs_stripped

  @class_attrs MapSet.new(["class", ":class"])
  @class_placeholder {:string, "__class__"}
  @attrs_placeholder []

  @doc """
  Normalize a list of nodes (or a single node) for the given mode.
  Returns a structure of plain tuples/lists/strings — no maps with
  line metadata — so `:erlang.term_to_binary/1` produces a stable
  hash input.
  """
  @spec normalize([Tree.node_t()] | Tree.node_t(), mode()) :: term()
  def normalize(nodes, mode) when is_list(nodes) do
    nodes |> Enum.map(&normalize(&1, mode))
  end

  def normalize({:element, tag, attrs, children, _meta}, mode),
    do: {:element, tag, normalize_attrs(attrs, mode), children |> Enum.map(&normalize(&1, mode))}

  def normalize({:eex_block, header, children, _meta}, mode),
    do: {:eex_block, normalize_eex(header), children |> Enum.map(&normalize(&1, mode))}

  def normalize({:eex_expr, code, _meta}, _mode), do: {:eex_expr, normalize_eex(code)}
  def normalize({:text, text, _meta}, _mode), do: {:text, text}
  @doc "Normalize a single attribute list for the given mode."
  @spec normalize_attrs([{String.t(), term()}], mode()) :: [{String.t(), term()}]
  def normalize_attrs(_attrs, :attrs_stripped), do: @attrs_placeholder

  def normalize_attrs(attrs, :class_stripped) do
    attrs
    |> Enum.map(fn {name, value} ->
      if MapSet.member?(@class_attrs, name) do
        {name, @class_placeholder}
      else
        {name, value}
      end
    end)
    |> Enum.sort()
  end

  def normalize_attrs(attrs, :exact), do: attrs |> Enum.sort()
  @doc "Whitespace-canonicalize an EEx code fragment."
  @spec normalize_eex(String.t()) :: String.t()
  def normalize_eex(code) when is_binary(code) do
    code
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
