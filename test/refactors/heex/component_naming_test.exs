defmodule Number42.Refactors.Heex.ComponentNamingTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Heex.{ComponentNaming, Tree}

  defp parse(body) do
    {:ok, [n]} = Tree.parse_body(body)
    n
  end

  describe "derive/2 — naming source chain" do
    test "1. semantic tag wins when present" do
      n = parse(~S|<section class="x"><p>{@a}</p></section>|)
      assert ComponentNaming.derive(n, []) == :section
    end

    test "2. class-hint noun when tag is generic" do
      n = parse(~S|<div class="user-card shadow"><p>{@a}</p></div>|)
      assert ComponentNaming.derive(n, []) == :card
    end

    test "3. heading text when no semantic tag / class hint" do
      n = parse(~S|<div><h2>Order Summary</h2><p>{@a}</p></div>|)
      assert ComponentNaming.derive(n, []) == :order_summary
    end

    test "4. gettext literal when no heading" do
      n = parse(~S|<div><b>{gettext("Weekly Module Breakdown")}</b><p>{@a}</p></div>|)
      assert ComponentNaming.derive(n, []) == :weekly_module_breakdown
    end

    test "5. dominant assign when nothing else" do
      n = parse(~S|<div><p>{@weekly_data}</p><span>{@weekly_data}</span><i>{@other}</i></div>|)
      assert ComponentNaming.derive(n, []) == :weekly_data
    end

    test "falls back to a generic name when no source yields anything" do
      n = parse(~S|<div><p>{1 + 1}</p></div>|)
      assert ComponentNaming.derive(n, []) == :component
    end

    test "disambiguates against taken names with a numeric suffix" do
      n = parse(~S|<section><p>{@a}</p></section>|)
      assert ComponentNaming.derive(n, [:section]) == :section_2
      assert ComponentNaming.derive(n, [:section, :section_2]) == :section_3
    end

    test "semantic tag beats class hint beats heading (priority order)" do
      n = parse(~S|<section class="user-card"><h2>Profile</h2><p>{@a}</p></section>|)
      assert ComponentNaming.derive(n, []) == :section
    end
  end

  describe "derive/2 — structural motif (source #0), qualified by dominant assign" do
    test "a data_table is named {dominant_assign}_table, not the reserved <table> tag" do
      # <table> alone would name :table (a CoreComponents builtin) → :table_2;
      # the motif gives the `_table` type word, the dominant `@entries` assign
      # makes it mean something in this codebase
      n =
        parse(~S"""
        <table>
          <thead><tr><th>Name</th><th>Qty</th></tr></thead>
          <tbody>
            <tr :for={entry <- @entries}><td>{entry.name}</td><td>{entry.qty}</td></tr>
            <tr><td>{@entries}</td><td>{@entries}</td></tr>
          </tbody>
        </table>
        """)

      assert ComponentNaming.derive(n, []) == :entries_table
    end

    test "a select_field is named {dominant_assign}_field" do
      n =
        parse(~S"""
        <select name="x">
          <option :for={c <- @categories}>{c.label}</option>
          <option>{@categories}</option>
          <option>{@categories}</option>
        </select>
        """)

      assert ComponentNaming.derive(n, []) == :categories_field
    end

    test "a button_group is named {dominant_assign}_group, beating a class hint / heading" do
      # without the motif, the <h2> heading would name it :pick_one
      n =
        parse(~S"""
        <div>
          <h2>Pick one</h2>
          <button>{@actions}</button>
          <button>{@actions}</button>
        </div>
        """)

      assert ComponentNaming.derive(n, []) == :actions_group
    end

    test "a card_grid is named {dominant_assign}_grid, beating the :card class hint" do
      # each child carries `card` → class-hint chain would name it :card;
      # the grid-of-cards motif + dominant @products is the more precise name
      n =
        parse(~S"""
        <div>
          <div class="card shadow"><h3>{@products}</h3></div>
          <div class="card shadow"><h3>{@products}</h3></div>
          <div class="card shadow"><h3>{@products}</h3></div>
        </div>
        """)

      assert ComponentNaming.derive(n, []) == :products_grid
    end

    test "a nav_list is named {dominant_assign}_list" do
      n =
        parse(~S"""
        <nav>
          <.link :for={item <- @brand_items} navigate={item.path}>{item.label}</.link>
          <.link navigate="/x">{@brand_items}</.link>
        </nav>
        """)

      assert ComponentNaming.derive(n, []) == :brand_items_list
    end

    test "names by the :for source, qualified by its parent, not the wrapper assign" do
      # the block is about @page.rows (the iterated collection), not the dominant
      # frequency assign; the parent qualifies the member → page_rows
      n =
        parse(~S"""
        <table>
          <thead><tr><th>A</th></tr></thead>
          <tbody><tr :for={row <- @page.rows}><td>{row.a}</td></tr></tbody>
        </table>
        """)

      assert ComponentNaming.derive(n, []) == :page_rows_table
    end

    test "a thin/adjective :for sub-field is qualified by its parent noun" do
      # `@preview.new` alone reads as `new_table`; the parent makes it preview_new
      n =
        parse(~S"""
        <table>
          <thead><tr><th>A</th></tr></thead>
          <tbody><tr :for={entry <- @preview.new}><td>{entry.a}</td></tr></tbody>
        </table>
        """)

      assert ComponentNaming.derive(n, []) == :preview_new_table
    end

    test "the parent is dropped when the member already carries it as a prefix" do
      # @brand_item.brand_item_assets must not stutter into brand_item_brand_item_assets
      n =
        parse(~S"""
        <ul>
          <li :for={bia <- @brand_item.brand_item_assets}>{bia.name}</li>
          <li :for={bia <- @brand_item.brand_item_assets}>{bia.name}</li>
        </ul>
        """)

      assert ComponentNaming.derive(n, []) == :brand_item_assets_list
    end

    test "a wrapped list (root is a container, not the <ul>) is named _container" do
      # <section> wraps a heading + the :for-driven <ul> over @brand_item.brand_item_assets;
      # the list is not the root, so it is a container, named by the :for source
      n =
        parse(~S"""
        <section :if={@brand_item.brand_item_assets != []} class="p-2">
          <p>Bilder</p>
          <ul>
            <li :for={bia <- @brand_item.brand_item_assets}>{bia.asset.name}</li>
          </ul>
        </section>
        """)

      assert ComponentNaming.derive(n, []) == :brand_item_assets_container
    end

    test "a bare <ul> root stays a _list (not wrapped)" do
      n =
        parse(~S"""
        <ul>
          <li :for={tag <- @tags}>{tag.label}</li>
          <li :for={tag <- @tags}>{tag.label}</li>
        </ul>
        """)

      assert ComponentNaming.derive(n, []) == :tags_list
    end

    test "with no usable assign the bare motif is kept" do
      # static options, no @assign at all → nothing to qualify with → :select_field
      n =
        parse(~S"""
        <select name="x">
          <option>One</option>
          <option>Two</option>
          <option>Three</option>
        </select>
        """)

      assert ComponentNaming.derive(n, []) == :select_field
    end

    test "an :unknown motif is transparent — the existing chain is unchanged" do
      # a single <p> is amorphous → :unknown → semantic-tag source wins
      n = parse(~S|<section class="x"><p>{@a}</p></section>|)
      assert ComponentNaming.derive(n, []) == :section
    end

    test "a qualified motif name is disambiguated against taken names" do
      n =
        parse(~S"""
        <select name="x"><option>{@categories}</option><option>{@categories}</option></select>
        """)

      assert ComponentNaming.derive(n, [:categories_field]) == :categories_field_2
    end
  end

  describe "derive/2 — reserved names" do
    test "a reserved semantic-tag name falls through to a meaningful source" do
      # <footer> would name :footer (clashes with CoreComponents.footer/1); a
      # heading is a better name than a numeric-suffixed :footer_2 anyway
      n = parse(~S|<footer class="x"><h3>Contact Info</h3><p>{@a}</p></footer>|)
      assert ComponentNaming.derive(n, []) == :contact_info
    end

    test "a reserved name with no alternative source is suffixed, not made generic" do
      # nothing else to go on: a suffixed tag name still beats :component
      n = parse(~S|<form class="x"><input name="a" /><button>Go</button></form>|)
      refute ComponentNaming.derive(n, []) == :form
      assert ComponentNaming.derive(n, []) == :form_2
    end

    test "a dominant-assign name clashing with a builtin falls through / is suffixed" do
      # dominant assign @link clashes with Phoenix.Component.link/1
      n = parse(~S|<div><a href={@link}>{@link}</a><span>{@link}</span></div>|)
      refute ComponentNaming.derive(n, []) == :link
    end

    test "module-taken names (caller-supplied) are avoided too" do
      # dominant assign @report names it :report; a local def report/1 is taken
      n = parse(~S|<div><p>{@report}</p><p>{@report}</p><span>{@report}</span></div>|)
      assert ComponentNaming.derive(n, [:report]) == :report_2
    end

    test "a reserved name falls through past taken to the next real source" do
      n = parse(~S|<footer><h3>Order Total</h3><p>{@a}</p></footer>|)
      assert ComponentNaming.derive(n, [:order_total]) == :order_total_2
    end

    test "the dominant assign falls through a reserved name to the next assign" do
      # @form dominates but clashes with Phoenix.Component.form/1; the next
      # assign @collection names the component meaningfully (not :form_2)
      n =
        parse(~S|<div><.form for={@form}>{@form}{@form}<span>{@collection}</span></.form></div>|)

      assert ComponentNaming.derive(n, []) == :collection
    end

    test "all assigns reserved -> still suffix the dominant one" do
      # @form and @link are both reserved; nothing meaningful left -> :form_2
      n = parse(~S|<div>{@form}{@form}<a href={@link}>x</a></div>|)
      assert ComponentNaming.derive(n, []) == :form_2
    end

    test "infrastructure assigns (@myself, @current_scope, ...) are never names" do
      # @current_scope dominates but is LiveView boilerplate; @summary names it
      n = parse(~S|<div>{@current_scope}{@current_scope}<p>{@summary}</p></div>|)
      refute ComponentNaming.derive(n, []) == :current_scope
      assert ComponentNaming.derive(n, []) == :summary
    end

    test "a reserved dominant assign falls through past infra to a real assign" do
      # @form reserved, @myself infra -> :payment names it
      n =
        parse(
          ~S|<div>{@form}{@form}{@myself}<span>{@payment}</span><span>{@payment}</span></div>|
        )

      assert ComponentNaming.derive(n, []) == :payment
    end
  end

  describe "derive_shared/3 — motif-keyed dedup for shared public components" do
    test "structurally identical subtrees share one name" do
      a = parse(~S|<section class="x"><h2>One</h2><p>{@a}</p></section>|)
      b = parse(~S|<section class="x"><h2>Two</h2><p>{@b}</p></section>|)

      cache = %{}
      {name_a, cache} = ComponentNaming.derive_shared(a, [], cache)
      {name_b, _cache} = ComponentNaming.derive_shared(b, [], cache)

      # same structural motif → same component, not section + section_2
      assert name_a == name_b
    end

    test "structurally different subtrees get distinct names" do
      a = parse(~S|<section class="x"><h2>One</h2><p>{@a}</p></section>|)
      b = parse(~S|<article class="y"><h2>Two</h2><p>{@b}</p><p>{@c}</p></article>|)

      cache = %{}
      {name_a, cache} = ComponentNaming.derive_shared(a, [], cache)
      {name_b, _cache} = ComponentNaming.derive_shared(b, [], cache)

      refute name_a == name_b
    end

    test "the returned cache reuses the name on a repeat key without re-disambiguating" do
      a = parse(~S|<section class="x"><h2>One</h2><p>{@a}</p></section>|)
      b = parse(~S|<section class="x"><h2>Two</h2><p>{@b}</p></section>|)

      {name_a, cache} = ComponentNaming.derive_shared(a, [], %{})
      # `section` is now taken, but b shares a's key → reuse, do not suffix
      {name_b, _cache} = ComponentNaming.derive_shared(b, [name_a], cache)

      assert name_b == name_a
    end
  end
end
