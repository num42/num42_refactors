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

  # Arity-1 function-components imported into every `use Phoenix.Component` /
  # `use Phoenix.LiveView` module. A `defp <name>(assigns)` of the same name
  # shadows the import and fails to compile ("conflicts with local function"),
  # so a derived name landing on one of these must be suffixed away, exactly
  # like a caller-supplied taken name. (Authoritative list via
  # `Phoenix.Component.__info__(:functions)`.)
  @phoenix_builtins ~w(form link live_component live_title live_img_preview
                       live_file_input focus_wrap inputs_for intersperse
                       dynamic_tag async_result portal to_form)a

  # The function-components every `mix phx.new` project generates in its
  # `CoreComponents` module and imports app-wide via `use MyAppWeb, :html`.
  # Several share a name with an HTML tag (`header`, `table`, `list`), so a
  # subtree on such a tag would otherwise be named into a clash with the
  # imported component. Reserve the canonical generator set across Phoenix
  # versions (current + legacy).
  @core_component_defaults ~w(flash header input list table modal button error
                              simple_form back icon label)a

  # Semantic HTML tags that are also conventionally lifted into a project's
  # `CoreComponents`/`Layouts` (a `<.header>`, `<.footer>`, `<.article>`). Their
  # bare tag name is both a weak component name *and* a likely import clash, so
  # the chain prefers a more meaningful source and only suffixes them as a last
  # resort. Measured: `footer`/`article`/`header` recur as imported components
  # across Phoenix apps; `section`/`main`/`nav`/`aside` rarely do.
  @reusable_layout_tags ~w(header footer article)a

  # LiveView/LiveComponent boilerplate assigns present in almost every template.
  # They are forwarded as `attr`s when read, but they never make a meaningful
  # component *name* — naming a card `<.current_scope>` or `<.myself>` is noise.
  @non_naming_assigns ~w(current_scope myself live_action flash socket rest
                         inner_block streams uploads conn)a

  @doc """
  The component name for `node` as a snake_case atom, avoiding any name in
  `taken` (a list of atoms) via a numeric suffix.
  """
  @spec derive(Tree.node_t(), [atom()]) :: atom()
  def derive(node, taken \\ []) do
    taken = MapSet.new(taken)

    # the naming sources in priority order; the dominant-assign source expands to
    # ALL assigns by descending frequency so a reserved top assign (`@form`) can
    # fall through to the next meaningful one (`@collection`) instead of `form_2`
    candidates =
      ([
         semantic_name(node),
         class_hint_name(node),
         heading_name(node),
         gettext_name(node)
       ] ++ assign_names(node))
      |> Enum.reject(&is_nil/1)

    # A *reserved* name (a Phoenix/CoreComponents builtin) is a poorly chosen
    # source — a `<footer>` tag clashes with the imported `footer/1` — so prefer
    # the next, more meaningful source. A merely *taken* name (already used in
    # this module/pass) is the right name on a colliding instance, so suffix it.
    base =
      Enum.find(candidates, fn name -> not MapSet.member?(reserved(), name) end) ||
        List.first(candidates) || @fallback

    disambiguate(base, MapSet.union(taken, reserved()))
  end

  @doc """
  Names that an extracted `defp` must never take because they would shadow an
  imported function-component: the `Phoenix.Component` builtins plus the
  `mix phx.new` `CoreComponents` defaults. Callers add module-local names
  (local `def`s, invoked `<.foo>` components) via `derive/2`'s `taken` arg.
  """
  @spec reserved() :: MapSet.t(atom())
  def reserved do
    [@phoenix_builtins, @core_component_defaults, @reusable_layout_tags]
    |> Enum.map(&MapSet.new/1)
    |> Enum.reduce(&MapSet.union/2)
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

  # all assign names by descending frequency (alphabetical tiebreak for a
  # deterministic order independent of map ordering), as naming candidates;
  # infrastructure assigns are dropped — they are never a meaningful name
  defp assign_names(node) do
    node
    |> assign_occurrences()
    |> Enum.frequencies()
    |> Enum.sort_by(fn {name, count} -> {-count, name} end)
    |> Enum.map(fn {name, _} -> String.to_atom(name) end)
    |> Enum.reject(&(&1 in @non_naming_assigns))
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
