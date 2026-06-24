defmodule Number42.Refactors.Heex.ComponentNaming do
  @moduledoc """
  Derive a function-component name for an extracted `Heex.Tree` subtree.

  Measured across well- and badly-factored codebases, no single source
  names every cut, but a priority chain reaches 100% coverage and adapts
  to the codebase (an i18n app names from `gettext` strings; an
  assign-centric one from the dominant assign):

    0. **structural motif, qualified by its collection** — a recognised plural
       skeleton (`StructureMotif`) classifies the block by component *type*
       (`data_table`, `nav_list`, ...). The type word is generic, so the
       *collection the block iterates* qualifies it. That collection is the
       block's `:for` source when present (`:for={bia <- @brand_item.brand_item_assets}`
       → `brand_item_assets`, not the wrapper `@brand_item`), else the dominant
       `@assign`: a `data_table` over `@entries` is an `entries_table`. When the
       list/table is *wrapped* — the root is a generic container with content
       beside the list, not the `<ul>`/`<table>` itself — the type word becomes
       `container`: `brand_item_assets_container`. With no usable collection the
       bare motif (`data_table`) is kept. `:unknown` yields nil, so the chain
       below is unaffected;
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

  alias Number42.Refactors.Heex.{Motif, StructureMotif, Tree}

  @semantic_tags ~w(section article header footer aside main nav table form dialog fieldset details figure)

  # generic wrapper tags that, as the *root* of a recognised list/table motif,
  # mark the block as a container *around* a list rather than the list itself
  @container_tags ~w(section article div main aside)

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
         motif_name(node),
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
  Name an extracted subtree for a **shared public** component, deduplicating
  reuse so two subtrees the caller considers equivalent map to one component
  name (real reuse) instead of `name` + `name_2`.

  `cache` is a `%{dedup_key => atom()}` threaded across the corpus. The dedup
  key defaults to the subtree's structural motif (`Heex.Motif.key/1`); pass
  `:dedup_key` in `opts` to override it — e.g. `{motif_key, sorted_assigns}` so
  that structurally-identical subtrees reading *different* assigns get distinct
  components (a shared `def` declaring `attr :rows` cannot serve a `@records`
  call site). A subtree whose dedup key is already cached returns that same
  name (even when it is in `taken` — a repeat occurrence *should* reuse it). A
  new key derives a fresh name via `derive/2` (disambiguated against `taken`)
  and records it. Returns `{name, updated_cache}`.

  Unlike `derive/2` (private `defp`, always a fresh local name), this is for a
  public `def` in a Components module shared across files: equivalence is the
  reuse signal, so equivalent shapes converge on one definition.
  """
  @spec derive_shared(Tree.node_t(), [atom()], map(), keyword()) :: {atom(), map()}
  def derive_shared(node, taken \\ [], cache \\ %{}, opts \\ []) do
    key = Keyword.get_lazy(opts, :dedup_key, fn -> Motif.key(node) end)

    case Map.get(cache, key) do
      nil ->
        name = derive(node, taken)
        {name, Map.put(cache, key, name)}

      name ->
        {name, cache}
    end
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

  # source #0: a recognised structural motif classifies the block by component
  # type (`data_table`, `nav_list`, ...), then the dominant assign qualifies the
  # type so the name means something in this codebase (`data_table` over
  # `@entries` → `entries_table`). `:unknown` yields nil, so the rest of the
  # chain runs unchanged.
  defp motif_name(node) do
    case StructureMotif.classify(node) do
      {:ok, motif} -> qualify_motif(motif, node)
      :unknown -> nil
    end
  end

  # Replace the motif's generic qualifier with the *thing the block is about*,
  # keeping its type word as a suffix:
  #
  #   * the **collection** comes from the block's `:for` source when present —
  #     `:for={bia <- @brand_item.brand_item_assets}` is *about* the
  #     `brand_item_assets`, not the wrapper `@brand_item`. The last path member
  #     of the source names it. Falls back to the dominant assign otherwise
  #     (`data_table` over `@entries` → `entries_table`).
  #   * the **type word** is normally the motif's own (`data_table` → `table`),
  #     but when the recognised list/table is *wrapped* — the root is a generic
  #     container (`<section>`/`<div>`) with content beside the list, not the
  #     `<ul>`/`<table>` itself — the block is a `_container`, not a bare list.
  #
  # So `item_list` whose root `<section>` wraps a heading + a `:for`-driven `<ul>`
  # over `@brand_item.brand_item_assets` → `brand_item_assets_container`.
  #
  # A reserved/empty qualifier leaves the bare motif so the chain always has a
  # usable name.
  defp qualify_motif(motif, node) do
    type_word = type_word(motif, node)
    collection = for_source_name(node) || dominant_assign(node)

    cond do
      is_nil(collection) -> motif
      collection == Atom.to_string(motif) -> motif
      type_word == Atom.to_string(motif) -> motif
      true -> String.to_atom("#{collection}_#{type_word}")
    end
  end

  # The motif's own type word (`data_table` → `table`, `nav_list` → `list`),
  # except a wrapped list/table reads as a `container`: its root is a generic
  # wrapper rather than the list element itself, with siblings around the list.
  defp type_word(motif, node) do
    bare = motif |> Atom.to_string() |> String.split("_") |> List.last()

    if bare in ~w(list table) and wrapped_collection?(node), do: "container", else: bare
  end

  # True when the recognised list/table is *not* the root — the root is a generic
  # container tag and the list element sits among siblings (a heading, copy, ...).
  # A block whose root IS the `<ul>`/`<table>` is a plain list, not a container.
  defp wrapped_collection?({:element, tag, _attrs, children, _}) do
    tag in @container_tags and Enum.count(children, &element?/1) > 1
  end

  defp wrapped_collection?(_), do: false

  defp element?({:element, _, _, _, _}), do: true
  defp element?(_), do: false

  # The collection named by the first `:for` generator in the block — the last
  # path member of its source (`bia <- @brand_item.brand_item_assets` →
  # `brand_item_assets`, `row <- @rows` → `rows`). The `:for` source is the
  # block's true subject; the wrapper assign (`@brand_item`) is just where it
  # hangs. Reserved names are skipped so the name cannot clash.
  defp for_source_name(node) do
    Tree.walk(node, nil, fn
      {:element, _t, attrs, _ch, _}, acc -> acc || for_member(attrs)
      _o, acc -> acc
    end)
  end

  defp for_member(attrs) do
    Enum.find_value(attrs, fn
      {":for", {:expr, code}} -> for_member_from(code)
      _ -> nil
    end)
  end

  # `bia <- @brand_item.brand_item_assets` → "brand_item_assets";
  # `entry <- @preview.new` → "preview_new"; `row <- @rows` → "rows". Take the
  # RHS of `<-`, then qualify its last path member with the parent member.
  defp for_member_from(code) when is_binary(code) do
    with [_, rhs] <- Regex.run(~r/<-\s*(.+)$/s, code),
         member when is_binary(member) <- qualified_member(rhs),
         name = String.to_atom(member),
         false <- MapSet.member?(reserved(), name) or name in @non_naming_assigns do
      member
    else
      _ -> nil
    end
  end

  defp for_member_from(_), do: nil

  # The last path member of a `@a.b.c` expression, qualified by its immediate
  # parent so a thin/adjective sub-field still names meaningfully:
  # `@preview.new` → "preview_new", `@rows` → "rows". The parent is dropped when
  # the member already carries it as a prefix (`@brand_item.brand_item_assets`
  # stays "brand_item_assets", not "brand_item_brand_item_assets").
  defp qualified_member(rhs) do
    case path_segments(rhs) do
      [] -> nil
      [only] -> only
      segs -> qualify_with_parent(Enum.at(segs, -2), List.last(segs))
    end
  end

  defp qualify_with_parent(parent, member) do
    if String.starts_with?(member, parent <> "_") or member == parent,
      do: member,
      else: "#{parent}_#{member}"
  end

  # dotted segments of a `@a.b.c` / `@xs` expression: ["a","b","c"] / ["xs"]
  defp path_segments(rhs) do
    case Regex.run(~r/@?([a-z_][a-zA-Z0-9_.]*)\s*$/, rhs) do
      [_, path] -> String.split(path, ".")
      _ -> []
    end
  end

  # the single most-referenced, name-worthy assign as a string (or nil); a
  # reserved Phoenix/CoreComponents builtin is skipped so the qualified name
  # cannot itself clash (`form_table` is fine, but a bare `@form`-only table
  # falls through to the next assign).
  defp dominant_assign(node) do
    node
    |> assign_names()
    |> Enum.find(&(not MapSet.member?(reserved(), &1)))
    |> case do
      nil -> nil
      assign -> Atom.to_string(assign)
    end
  end

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
    |> Enum.map(fn {name, _} -> name |> strip_predicate_suffix() |> String.to_atom() end)
    |> Enum.reject(&(&1 in @non_naming_assigns))
  end

  # an assign may end in `?`/`!` (`@valid?`), but a component name cannot, so
  # the trailing predicate/bang char is dropped before naming.
  defp strip_predicate_suffix(name), do: String.replace(name, ~r/[?!]$/, "")

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
    ~r/@([a-z_][a-zA-Z0-9_]*[?!]?)/
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
