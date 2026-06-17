defmodule Number42.Refactors.Heex.PluralSkeleton do
  @moduledoc """
  Reduce a `Heex.Tree` subtree to its **plural skeleton** — the structural
  fingerprint that survives once singleton wrapper elements are dropped.

  ## Why repetition, not full structure

  Measured across a real codebase, full tree signatures are ~90% unique: a
  signature precise enough to *identify* a subtree is a near-unique snowflake
  and cannot cluster. The signal that makes a subtree a recognisable *component*
  is **repetition** — a data table is a row of `th`s over a body of repeated
  rows of `td`s; a select is repeated `option`s; a card grid is repeated cards.

  Keeping only the nodes that are (or lead to) a group of ≥2 structurally-equal
  same-tag children — and pruning every singleton wrapper branch — triples
  clustering (14% → 44% of subtrees land in a recurring shape) and the recurring
  shapes are nameable component types.

  ## Skeleton grammar

      parent>child   descend one level
      tags           PLURAL — ≥2 structurally-equal same-tag children collapse
                     (`li` → `lis`); the shared child structure is kept once
      a;b            siblings that are NOT structurally equal, listed in order
      <pruned>       a branch with no plural anywhere below is dropped entirely

  `<ul><li><a></li><li><a></li></ul>` → `ul>lis>a`. A subtree with no plural
  group anywhere is `:amorphous` (a genuine layout wrapper, not a component) and
  returns its bare root tag as the (non-clustering) signature.
  """

  alias Number42.Refactors.Heex.Tree

  @type shape :: :shaped | :amorphous

  @doc """
  The plural skeleton of `node` as `{signature, shape}`.

  `shape` is `:shaped` when a plural group exists anywhere in the subtree
  (a component candidate) and `:amorphous` otherwise (a layout wrapper to leave
  alone). The signature is deterministic and idempotent.
  """
  @spec of(Tree.node_t()) :: {String.t(), shape()}
  def of(node) do
    {sig, plural?} = walk(node)
    shape = if plural?, do: :shaped, else: :amorphous
    {sig || bare_label(node), shape}
  end

  # walk/1 returns {signature_or_nil, plural_anywhere_below?}. The signature is
  # the canonical skeleton with non-plural wrapper branches PRUNED to nil; the
  # boolean reports whether a plural exists at or below this node, independent of
  # pruning. (A node can be plural-bearing yet prune to nil when its sole content
  # is a deeper plural the parent will keep on a sibling branch.)
  defp walk({:text, _, _}), do: {nil, false}
  defp walk({:eex_expr, _, _}), do: {nil, false}

  defp walk({:eex_block, header, children, _} = block) do
    case for_collapsed_child(header, children) do
      {:element, _, _, _, _} ->
        # a `for` comprehension over a single element is a runtime plural
        {canonical(block), true}

      nil ->
        {inner, plural?} = children_skeleton(children)
        {block_label(header) <> inner, plural?}
    end
  end

  defp walk({:element, tag, _attrs, children, _}) do
    {inner, plural?} = children_skeleton(children)
    {label(tag) <> inner, plural?}
  end

  # Group consecutive same-tag element children; a group of ≥2 structurally-equal
  # members collapses to a plural. KEEP only branches that contain a plural at or
  # below them — singleton wrappers with no repetition are pruned (nil).
  #
  # Structural equality is decided on the full canonical skeleton (`canonical/1`,
  # which pluralises but never prunes): two `<div>`s differing only in non-plural
  # children are still different siblings, and two `<li><a>` collapse to `lis>a`
  # (the shared child is kept once via the canonical body, even though the pruned
  # walk alone would have dropped the `<a>`).
  defp children_skeleton(children) do
    groups =
      children
      |> Enum.reject(&leaf?/1)
      |> Enum.chunk_by(&tag_of/1)

    rendered = Enum.map(groups, &render_group/1)
    plural_here? = Enum.any?(rendered, fn {_sig, p?} -> p? end)

    kept =
      rendered
      |> Enum.filter(fn {sig, p?} -> p? and sig not in [nil, ""] end)
      |> Enum.map(fn {sig, _} -> sig end)

    case kept do
      [] -> {"", plural_here?}
      list -> {">" <> Enum.join(list, ";"), plural_here?}
    end
  end

  # render_group/1 → {signature, plural_at_or_below?}
  #
  # A lone element carrying a `:for` directive is a RUNTIME plural — `<tr :for=…>`
  # renders N rows from one tree node, the strongest repetition signal there is —
  # so it pluralises like a static group of equal siblings.
  defp render_group([{:element, tag, attrs, _ch, _} = single]) do
    if for_directive?(attrs) do
      {pluralise(canonical(single), label(tag)), true}
    else
      walk(single)
    end
  end

  defp render_group([single]) do
    walk(single)
  end

  defp render_group([first | _] = group) do
    if all_equal?(group) do
      # all structurally equal → this group IS a plural. The head tag pluralises;
      # the body is the shared member's canonical skeleton (which pluralises any
      # deeper repetition too), so `lis>a` and `trs>tds` fall out naturally.
      {pluralise(canonical(first), tag_of(first)), true}
    else
      # unequal siblings → list each via the pruned walk; plural only if a member
      # carried a plural below it
      walked = Enum.map(group, &walk/1)
      plural_below? = Enum.any?(walked, fn {_, p?} -> p? end)
      sigs = walked |> Enum.map(fn {sig, _} -> sig end) |> Enum.reject(&is_nil/1)
      {Enum.join(sigs, ";"), plural_below?}
    end
  end

  defp all_equal?([first | rest]) do
    c = canonical(first)
    Enum.all?(rest, &(canonical(&1) == c))
  end

  # The canonical skeleton: pluralises ≥2 equal same-tag children but, unlike
  # walk/1, prunes nothing. Used for sibling equality AND as the kept body of a
  # plural group. Depth-capped so deep trees still cluster.
  @max_depth 5
  defp canonical(node), do: canon(node, 0)

  defp canon({:text, _, _}, _d), do: nil
  defp canon({:eex_expr, _, _}, _d), do: nil
  defp canon({:element, tag, _a, ch, _}, d), do: label(tag) <> canon_children(ch, d)

  # a `<%= for %>` whose sole element child is one element collapses to that
  # element pluralised (`%for>li` → `lis`) — the comprehension IS the repetition
  defp canon({:eex_block, h, ch, _}, d) do
    case for_collapsed_child(h, ch) do
      {:element, tag, _a, _ch, _} = child -> pluralise(canon(child, d), label(tag))
      nil -> block_label(h) <> canon_children(ch, d)
    end
  end

  defp canon_children(_ch, d) when d >= @max_depth, do: ""

  defp canon_children(children, d) do
    sigs =
      children
      |> Enum.reject(&leaf?/1)
      |> Enum.chunk_by(&tag_of/1)
      |> Enum.map(fn
        [{:element, tag, attrs, _, _} = single] ->
          if for_directive?(attrs),
            do: pluralise(canon(single, d + 1), label(tag)),
            else: canon(single, d + 1)

        [single] ->
          canon(single, d + 1)

        [first | _] = group ->
          pluralise(canon(first, d + 1), tag_of(first))
      end)
      |> Enum.reject(&is_nil/1)

    case sigs do
      [] -> ""
      list -> ">" <> Enum.join(list, ";")
    end
  end

  # "li>a" → "lis>a";  "" / nil (a bare <li>) → "lis";  "tr>td" → "trs>td"
  defp pluralise(sig, tag) when sig in [nil, ""], do: label(tag) <> "s"

  defp pluralise(sig, tag) do
    head = label(tag)
    head <> "s" <> String.replace_prefix(sig, head, "")
  end

  defp leaf?({:text, _, _}), do: true
  defp leaf?({:eex_expr, _, _}), do: true
  defp leaf?(_), do: false

  # a `:for={x <- xs}` directive on an element — the Phoenix inline comprehension
  defp for_directive?(attrs), do: Enum.any?(attrs, fn {name, _v} -> name == ":for" end)

  # the sole element child of a `<%= for … do %>` / `<%= for … %>` block, if the
  # block is a `for` comprehension wrapping exactly one element (its repetition
  # unit); nil otherwise
  defp for_collapsed_child(header, children) do
    if String.contains?(header, "for ") do
      case Enum.reject(children, &leaf?/1) do
        [{:element, _, _, _, _} = child] -> child
        _ -> nil
      end
    end
  end

  defp tag_of({:element, tag, _, _, _}), do: label(tag)
  defp tag_of({:eex_block, header, _, _}), do: block_label(header)
  defp tag_of(_), do: "?"

  defp label("." <> _ = component), do: component
  defp label(":" <> _), do: ":slot"
  defp label(tag), do: tag

  defp bare_label({:element, tag, _, _, _}), do: label(tag)
  defp bare_label({:eex_block, header, _, _}), do: block_label(header)
  defp bare_label(_), do: "?"

  defp block_label(header) do
    cond do
      String.contains?(header, "for ") -> "%for"
      String.contains?(header, "if ") -> "%if"
      String.contains?(header, "case ") -> "%case"
      String.contains?(header, "cond") -> "%cond"
      true -> "%blk"
    end
  end
end
