defmodule Number42.Refactors.Heex.ComponentNaming do
  @moduledoc """
  Derive a function-component name for an extracted `Heex.Tree` subtree.

  Measured across well- and badly-factored codebases, no single source
  names every cut, but a priority chain reaches 100% coverage and adapts
  to the codebase (an i18n app names from `gettext` strings; an
  assign-centric one from the dominant assign):

    1. **semantic tag** — `<section>`, `<article>`, `<table>`, ... the tag
       already declares what the block is;
    2. **class-hint noun** — a recognised UI noun in the `class` attribute
       (`card`, `panel`, `list`, ...);
    3. **heading text** — the first `<h1>`–`<h6>`/`<.header>` text;
    4. **gettext literal** — the first `gettext("...")` string;
    5. **dominant assign** — the most-referenced `@assign` name.

  The chosen source is slugified to a snake_case atom and disambiguated
  against already-taken names with a numeric suffix.
  """

  alias Number42.Refactors.Heex.Tree

  @semantic_tags ~w(section article header footer aside main nav table form dialog fieldset details figure)

  @class_nouns ~w(card panel sidebar list item row cell modal dialog badge avatar banner hero
                  toolbar menu nav tab breadcrumb pagination alert toast tooltip dropdown
                  accordion stepper timeline grid gallery thumbnail preview summary detail
                  widget tile chip pill)

  @slug_max_chars 40
  @fallback :component

  @doc """
  The component name for `node` as a snake_case atom, avoiding any name in
  `taken` (a list of atoms) via a numeric suffix.
  """
  @spec derive(Tree.node_t(), [atom()]) :: atom()
  def derive(node, taken \\ []) do
    base =
      semantic_name(node) ||
        class_hint_name(node) ||
        heading_name(node) ||
        gettext_name(node) ||
        dominant_assign_name(node) ||
        @fallback

    disambiguate(base, MapSet.new(taken))
  end

  # ---- sources -------------------------------------------------------------

  defp semantic_name({:element, tag, _, _, _}) when tag in @semantic_tags,
    do: String.to_atom(tag)

  defp semantic_name(_), do: nil

  defp class_hint_name({:element, _tag, attrs, _ch, _}) do
    classes =
      Enum.find_value(attrs, "", fn
        {"class", {:string, s}} -> s
        {"class", {:expr, s}} -> s
        _ -> nil
      end)

    ~r/[a-z]+/
    |> Regex.scan(String.downcase(classes))
    |> List.flatten()
    |> Enum.find(&(&1 in @class_nouns))
    |> case do
      nil -> nil
      noun -> String.to_atom(noun)
    end
  end

  defp class_hint_name(_), do: nil

  defp heading_name(node) do
    Tree.walk(node, nil, fn
      {:element, t, _, ch, _}, acc when t in ~w(h1 h2 h3 h4 h5 h6 .header) ->
        acc || ch |> first_text() |> slug_to_atom()

      _o, acc ->
        acc
    end)
  end

  defp gettext_name(node) do
    Tree.walk(node, nil, fn
      {:eex_expr, code, _}, acc -> acc || code |> gettext_literal() |> slug_to_atom()
      {:eex_block, code, _, _}, acc -> acc || code |> gettext_literal() |> slug_to_atom()
      {:element, _t, attrs, _ch, _}, acc -> acc || gettext_in_attrs(attrs)
      _o, acc -> acc
    end)
  end

  defp dominant_assign_name(node) do
    node
    |> assign_occurrences()
    |> Enum.frequencies()
    |> Enum.to_list()
    # most frequent wins; alphabetical name as a deterministic tiebreaker so the
    # chosen name never depends on map ordering
    |> Enum.sort_by(fn {name, count} -> {-count, name} end)
    |> case do
      [{name, _} | _] -> String.to_atom(name)
      [] -> nil
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp first_text(children) do
    Enum.find_value(children, fn
      {:text, s, _} -> String.trim(s)
      _ -> nil
    end)
  end

  defp gettext_in_attrs(attrs) do
    Enum.find_value(attrs, fn
      {_n, {:expr, code}} -> code |> gettext_literal() |> slug_to_atom()
      _ -> nil
    end)
  end

  defp gettext_literal(code) when is_binary(code) do
    case Regex.run(~r/d?gettext\(\s*"([^"]{2,60})"/, code) do
      [_, s] -> s
      _ -> nil
    end
  end

  defp gettext_literal(_), do: nil

  defp assign_occurrences(node) do
    Tree.walk(node, [], fn
      {:eex_expr, code, _}, acc -> assigns(code) ++ acc
      {:eex_block, code, _, _}, acc -> assigns(code) ++ acc
      {:element, _t, attrs, _ch, _}, acc -> attr_assigns(attrs) ++ acc
      _o, acc -> acc
    end)
  end

  defp attr_assigns(attrs) do
    Enum.flat_map(attrs, fn
      {_n, {:expr, code}} -> assigns(code)
      _ -> []
    end)
  end

  defp assigns(code) when is_binary(code) do
    ~r/@([a-z_][a-zA-Z0-9_]*)/
    |> Regex.scan(code)
    |> Enum.map(fn [_, n] -> n end)
  end

  defp assigns(_), do: []

  defp slug_to_atom(nil), do: nil

  defp slug_to_atom(text) do
    slug =
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "_")
      |> String.trim("_")
      |> String.split("_")
      |> Enum.take(4)
      |> Enum.join("_")
      |> String.slice(0, @slug_max_chars)
      |> String.trim("_")

    if slug == "" or not String.match?(slug, ~r/[a-z]/), do: nil, else: String.to_atom(slug)
  end

  defp disambiguate(base, taken) do
    if MapSet.member?(taken, base) do
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n ->
        candidate = String.to_atom("#{base}_#{n}")
        if MapSet.member?(taken, candidate), do: false, else: candidate
      end)
    else
      base
    end
  end
end
