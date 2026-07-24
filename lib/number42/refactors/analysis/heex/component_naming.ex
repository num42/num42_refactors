defmodule Number42.Refactors.Analysis.Heex.ComponentNaming do
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

  alias Number42.Refactors.Analysis.Heex.{Motif, StructureMotif, Tree}

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

    # PRIMARY: a functional name = `{noun}_{functional_suffix}`, where the noun
    # comes from the heading / assign-path leaf / class noun (NOT the bare
    # dominant assign) and the suffix is the block's functional role (`_panel`,
    # `_alert`, `_selector`, `_actions`, ...), NOT its structural tag. Measured
    # to match hand-picked names far better than the motif chain below; see
    # `compose_functional_name/1`.
    #
    # FALLBACK: the structural motif / tag / class / heading / assign chain, used
    # only when the functional source declines (no usable noun).
    candidates =
      ([
         compose_functional_name(node),
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

  # ---- functional naming (primary) -----------------------------------------

  # A functional name = `{noun}_{suffix}`: the noun the block is *about* + the
  # role it *plays*. Fires only when it has REAL signal — a heading/class/`:for`
  # noun, or a distinctive (non-panel) functional role — so a block named only
  # by a weak dominant assign with no role falls through to the structural
  # chain, which handles semantic tags/motifs better. Returns nil to decline.
  defp compose_functional_name(node) do
    strong_noun = heading_noun(node) || path_leaf_noun(node) || class_noun(node)
    suffix = functional_suffix(node)
    # `_panel`/`_list`/`_table` are weak roles the structural motif expresses at
    # least as well (it also knows `_container`/`_grid`/`_field`). A *distinctive*
    # role (`_alert`/`_selector`/`_form`/`_actions`/`_nav`/`_header`/`_images`)
    # has no motif equivalent, so it wins even over a strong motif.
    distinctive_suffix = suffix not in [nil, "panel", "list", "table"]

    cond do
      # a distinctive functional role → it names the block, with the best noun
      distinctive_suffix ->
        compose_noun_suffix(strong_noun || assign_noun(node), suffix)

      # a real heading/class/`:for` noun AND the motif has no opinion → use the
      # noun as a headed display block
      strong_noun != nil and motif_name(node) == nil ->
        compose_noun_suffix(strong_noun, suffix)

      # otherwise defer to the structural motif — it owns the weak/structural
      # suffixes (`_container`/`_grid`/`_field`/`_list`/`_table`)
      true ->
        nil
    end
  end

  # Join noun + suffix, but drop the suffix when the noun already ends in it
  # (singular or plural) so `manufacturers` + `list` stays `manufacturers_list`
  # but `price_lists` + `list` does not become `price_lists_list`. A nil suffix
  # (a bare display block with no distinctive role) keeps just the noun.
  # no noun at all (a distinctive role on a node with no nameable assign) → use
  # the role word itself (`actions`, `alert`) rather than the generic fallback.
  defp compose_noun_suffix(nil, nil), do: @fallback
  defp compose_noun_suffix(nil, suffix), do: String.to_atom(suffix)
  defp compose_noun_suffix(noun, nil), do: String.to_atom(noun)

  defp compose_noun_suffix(noun, suffix) do
    if suffix_redundant?(noun, suffix),
      do: String.to_atom(noun),
      else: String.to_atom("#{noun}_#{suffix}")
  end

  # ---- noun stem: ranked chain (heading → path-leaf → class → assign) -------

  # generic single-word headings that are column/section labels, not the
  # component subject — they must not win the noun, so the chain falls through
  @generic_headings ~w(typ type bilder images attribute attributes schlüssel
                       schluessel key wert value name bezeichnung label preis
                       price details detail info)

  # N1: the first heading/legend text, slugified as-is (German kept — an honest
  # `dokumentationsbilder` beats a fragile dictionary). A single generic word
  # (a column/section label) does not qualify.
  defp heading_noun(node) do
    case heading_text(node) do
      nil -> nil
      text -> text |> slug_to_atom() |> reject_generic()
    end
  end

  defp reject_generic(nil), do: nil

  defp reject_generic(atom) do
    s = Atom.to_string(atom)
    if s in @generic_headings, do: nil, else: s
  end

  # the first heading-ish text in the subtree: h1–h6, `<.header>`, `<legend>`,
  # or a `<p>`/`<span>` whose class marks it a heading (`fixating`/`announcing`).
  defp heading_text(node) do
    Tree.walk(node, nil, fn
      {:element, t, _attrs, ch, _}, acc when t in ~w(h1 h2 h3 h4 h5 h6 .header legend) ->
        acc || deep_text(ch)

      _o, acc ->
        acc
    end)
  end

  # N2: the assign-path leaf — `@preview.new` → "preview_new",
  # `@usages.manufacturers` → "manufacturers". The block's `:for` source is the
  # subject when present (`qualified_member` already takes the path leaf and
  # de-stutters against its parent). A non-`:for` path leaf is left to N5 for
  # now (the measured cases all carry a `:for`).
  defp path_leaf_noun(node), do: for_source_name(node)

  # N3: a recognised UI class noun used as the block's identity
  # (`breadcrumb`/`dock`/`card`...). Pure layout/structure classes (`grid`,
  # `row`, `cell`, `item`, `list`) are NEVER a subject noun — they describe the
  # arrangement, not the thing — so they are excluded here (they still feed the
  # suffix ladder and the motif).
  @non_noun_classes ~w(grid row cell item list)a
  defp class_noun(node) do
    case class_hint_name(node) do
      nil -> nil
      atom when atom in @non_noun_classes -> nil
      atom -> Atom.to_string(atom)
    end
  end

  # N5: the root dominant assign as the noun, last resort (`@asset` → "asset",
  # `@mass` → "mass" — the subject IS the assign).
  defp assign_noun(node) do
    case dominant_assign(node) do
      nil -> nil
      assign -> assign
    end
  end

  # ---- functional suffix: role ladder, top-down -----------------------------

  # The block's functional role as a suffix, evaluated most-specific first. nil
  # = a plain headed display block with no distinctive role (the noun stands
  # alone, or `compose` may leave it bare).
  defp functional_suffix(node) do
    sig = role_signals(node)

    cond do
      sig.alert -> "alert"
      sig.selector -> "selector"
      sig.form -> "form"
      sig.actions -> "actions"
      sig.nav -> "nav"
      sig.header -> "header"
      sig.grid -> "grid"
      sig.table -> "table"
      sig.images -> "images"
      sig.list -> "list"
      # a headed display block with no distinctive role reads as a panel
      sig.headed -> "panel"
      true -> nil
    end
  end

  defp role_signals(node) do
    classes = all_classes(node)
    tags = all_tags(node)
    {:element, root_tag, _ra, _rc, _} = ensure_element(node)
    domain_for? = for_source_name(node) != nil

    %{
      alert: class_any?(classes, ~w(alert warning error)),
      selector: "fieldset" in tags or has_input_type?(node, ~w(checkbox radio)),
      form: has_phx_form?(node) or "form" in tags or ".form" in tags,
      actions: not domain_for? and link_or_button_group?(node, classes),
      nav:
        root_tag in ~w(nav) or class_any?(classes, ~w(dock breadcrumb breadcrumbs menu navbar)),
      header: not domain_for? and header_role?(tags),
      grid: class_any?(classes, ~w(grid)) and domain_for?,
      table: "table" in tags,
      images: domain_for? and image_collection?(node),
      list: domain_for? and root_tag in ~w(ul ol),
      headed: heading_text(node) != nil
    }
  end

  defp ensure_element({:element, _, _, _, _} = el), do: el
  defp ensure_element(_), do: {:element, "div", [], [], nil}

  # ---- role signal helpers --------------------------------------------------

  defp all_classes(node) do
    Tree.walk(node, [], fn
      {:element, _t, attrs, _ch, _}, acc -> class_tokens(attrs) ++ acc
      _o, acc -> acc
    end)
  end

  defp class_tokens(attrs) do
    attrs
    |> Enum.find_value("", fn
      {"class", {:string, s}} -> s
      {"class", {:expr, s}} -> s
      _ -> nil
    end)
    |> String.downcase()
    |> then(&Regex.scan(~r/[a-z]+/, &1))
    |> List.flatten()
  end

  defp class_any?(classes, nouns), do: Enum.any?(nouns, &(&1 in classes))

  defp all_tags(node) do
    Tree.walk(node, [], fn
      {:element, t, _attrs, _ch, _}, acc -> [t | acc]
      _o, acc -> acc
    end)
  end

  defp has_input_type?(node, types) do
    Tree.walk(node, false, fn
      {:element, "input", attrs, _ch, _}, acc -> acc or input_type_in?(attrs, types)
      _o, acc -> acc
    end)
  end

  defp input_type_in?(attrs, types) do
    Enum.any?(attrs, fn
      {"type", {:string, t}} -> t in types
      _ -> false
    end)
  end

  defp has_phx_form?(node) do
    Tree.walk(node, false, fn
      {:element, _t, attrs, _ch, _}, acc -> acc or phx_form_attr?(attrs)
      _o, acc -> acc
    end)
  end

  defp phx_form_attr?(attrs) do
    Enum.any?(attrs, fn {name, _v} -> name in ~w(phx-submit phx-change) end)
  end

  # a group of ≥2 links/buttons (often `btn`-classed) — action triggers, not a
  # data list (the `:for` gate is applied by the caller).
  defp link_or_button_group?(node, classes) do
    links =
      Tree.walk(node, 0, fn
        {:element, "." <> rest, _a, _c, _}, acc when rest in ["link"] -> acc + 1
        {:element, "button", _a, _c, _}, acc -> acc + 1
        _o, acc -> acc
      end)

    links >= 2 or ("btn" in classes and links >= 1)
  end

  # a header: a heading element plus action controls (buttons/dropdown/links)
  # and NO data list — a top-of-block bar, not content.
  defp header_role?(tags) do
    has_heading = Enum.any?(tags, &(&1 in ~w(h1 h2 h3 h4 h5 h6 .header)))
    has_controls = Enum.any?(tags, &(&1 in ~w(button .link .dropdown)))
    has_heading and has_controls
  end

  defp image_collection?(node) do
    Tree.walk(node, false, fn
      {:element, t, _a, _c, _}, _acc when t in ~w(img figure .asset_preview .image) -> true
      _o, acc -> acc
    end)
  end

  defp deep_text(children) do
    children
    |> Enum.map(fn
      {:text, s, _} -> String.trim(s)
      {:element, _t, _a, ch, _} -> deep_text(ch)
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      s -> s
    end
  end

  # ---- sources (fallback chain) ---------------------------------------------

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
      suffix_redundant?(collection, type_word) -> String.to_atom(collection)
      true -> String.to_atom("#{collection}_#{type_word}")
    end
  end

  # The collection already carries the type word as its last segment — appending
  # it again stutters (`@brand_price_lists` + `list` → `brand_price_lists_list`).
  # Match the type word OR its plural (`list`/`lists`, `table`/`tables`) so a
  # plural collection name (`brand_price_lists`) suppresses a singular suffix.
  defp suffix_redundant?(collection, type_word) do
    last = collection |> String.split("_") |> List.last()
    last == type_word or last == type_word <> "s"
  end

  # The motif's own type word (`data_table` → `table`, `nav_list` → `list`),
  # except: a `link_group` of static links reads as `links` (`asset_links`, not
  # `asset_group`); and a wrapped list/table reads as a `container` — its root is
  # a generic wrapper rather than the list element itself, with siblings around
  # the list.
  defp type_word(:link_group, _node), do: "links"

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
