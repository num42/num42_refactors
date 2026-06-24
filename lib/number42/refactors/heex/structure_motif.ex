defmodule Number42.Refactors.Heex.StructureMotif do
  @moduledoc """
  Classify a `Heex.Tree` subtree into a component-type motif from its plural
  skeleton (`PluralSkeleton`).

  ## Why motifs, not unique names

  Measured across a real codebase, exact tree signatures are ~90% unique — a
  unique name cannot cluster. The signal that names a *component* is repetition:
  the recurring plural skeletons map to a small set of recognisable types
  (`data_table`, `select_field`, `card_grid`, ...). This is a hand-curated motif
  table over structural features, mirroring `Semantic`'s nearest-prototype verb
  classifier — and like it, returns `:unknown` on no match so the caller keeps
  its mechanical fallback (`ComponentNaming`'s tag/class/heading/assign chain).

  A motif fires only on a `:shaped` subtree (one with a plural group); amorphous
  layout wrappers are always `:unknown`. Generic `div>divs` / `div>spans`
  skeletons — repetition without a semantic tag — are deliberately `:unknown`:
  "a wrapper of wrappers" names no component type.
  """

  alias Number42.Refactors.Heex.{PluralSkeleton, Tree}

  @type motif ::
          :data_table
          | :select_field
          | :item_list
          | :nav_list
          | :link_group
          | :button_group
          | :card_grid

  # tags that make a group of links *navigation* rather than a static link group:
  # a `<nav>`, or a genuine list (`<ul>`/`<ol>`). A generic wrapper (`<div>`,
  # `<section>`) holding a few static links is a link group, not navigation.
  @nav_tags ~w(nav ul ol menu)

  # class nouns that, when repeated, mark a card grid (the only motif that needs
  # a class signal rather than a tag — a card is a styled div, not a semantic tag)
  @card_classes ~w(card tile)

  @doc """
  Classify `node` as `{:ok, motif}` or `:unknown`.

  Ordered most-specific to most-generic so an overlapping structure (a table
  also contains repeated `tr`s) resolves to its richest type.
  """
  @spec classify(Tree.node_t()) :: {:ok, motif()} | :unknown
  def classify(node) do
    case PluralSkeleton.of(node) do
      {_sig, :amorphous} -> :unknown
      {sig, :shaped} -> motif(sig, node)
    end
  end

  # The skeleton tokens (`ths`, `tds`, `options`, `lis`, `buttons`, `.links`, ...)
  # are the discriminating features; a few need a class signal on top.
  defp motif(sig, node) do
    tokens = tokens(sig)

    cond do
      # a header row of `th`s plus any body rows is a table; the body is often a
      # single `:for`-driven `<tr>` (a runtime plural `trs`) rather than static
      # `<td>`s, so `ths` + (`tds` | `trs`) — or a `table` tag — all qualify
      has?(tokens, "ths") and (has?(tokens, "tds") or has?(tokens, "trs")) ->
        {:ok, :data_table}

      has?(tokens, "table") and (has?(tokens, "trs") or has?(tokens, "tds")) ->
        {:ok, :data_table}

      has?(tokens, "options") ->
        {:ok, :select_field}

      has?(tokens, ".links") ->
        {:ok, links_motif(node)}

      has?(tokens, "buttons") ->
        {:ok, :button_group}

      card_grid?(tokens, node) ->
        {:ok, :card_grid}

      has?(tokens, "lis") ->
        {:ok, :item_list}

      true ->
        :unknown
    end
  end

  # split the skeleton into its node labels: "table>thead>tr>ths;tbody>trs>tds"
  # → ["table", "thead", "tr", "ths", "tbody", "trs", "tds"]
  defp tokens(sig), do: String.split(sig, ~r/[>;]/, trim: true)

  defp has?(tokens, label), do: label in tokens

  # A group of links is *navigation* (`nav_list`) when it is a dynamic list
  # (`:for`-driven) or sits in a `<nav>`/`<ul>`/`<ol>`. A handful of STATIC links
  # in a generic wrapper (`<div>`/`<section>` of two action `<.link class="btn">`s)
  # is a `link_group` — not a list, not navigation.
  defp links_motif(node) do
    if for_driven?(node) or nav_rooted?(node), do: :nav_list, else: :link_group
  end

  defp nav_rooted?({:element, tag, _attrs, _ch, _}), do: tag in @nav_tags
  defp nav_rooted?(_), do: false

  defp for_driven?(node) do
    Tree.walk(node, false, fn
      {:element, _tag, attrs, _ch, _}, acc -> acc or has_for?(attrs)
      _node, acc -> acc
    end)
  end

  defp has_for?(attrs), do: Enum.any?(attrs, fn {name, _v} -> name == ":for" end)

  # a card grid is a plural of `div`s each carrying a `card`/`tile` class
  defp card_grid?(tokens, node) do
    (has?(tokens, "divs") or has?(tokens, "articles")) and repeated_card?(node)
  end

  defp repeated_card?(node) do
    classes_per_element = card_class_counts(node)
    Enum.count(classes_per_element, & &1) >= 2
  end

  # for each element, whether its class carries a card noun (flat list over tree)
  defp card_class_counts(node) do
    Tree.walk(node, [], fn
      {:element, _tag, attrs, _ch, _}, acc -> [card_class?(attrs) | acc]
      _node, acc -> acc
    end)
  end

  defp card_class?(attrs) do
    class =
      Enum.find_value(attrs, "", fn
        {"class", {:string, s}} -> s
        {"class", {:expr, s}} -> s
        _ -> nil
      end) || ""

    ~r/[a-z]+/
    |> Regex.scan(String.downcase(class))
    |> List.flatten()
    |> Enum.any?(&(&1 in @card_classes))
  end
end
