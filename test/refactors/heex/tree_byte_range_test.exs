defmodule Number42.Refactors.Heex.TreeByteRangeTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Heex.Tree

  describe "node_byte_range/2 for elements" do
    test "returns the byte range of an element node within its body" do
      body = ~s(<div>\n  <span class="x">hi</span>\n</div>\n)
      {:ok, [{:element, "div", _, [span], _}]} = Tree.parse_body(body)

      {start_byte, end_byte} = Tree.node_byte_range(span, body)

      assert binary_part(body, start_byte, end_byte - start_byte) ==
               ~s(<span class="x">hi</span>)
    end

    test "self-closing tag range covers from `<` through `/>`" do
      body = ~s(<.icon name="x" class="y" />)
      {:ok, [icon]} = Tree.parse_body(body)
      {s, e} = Tree.node_byte_range(icon, body)
      assert binary_part(body, s, e - s) == String.trim(body)
    end

    test "every node range stays inside the body for a tag ending in `{...}` (issue #260)" do
      body = ~s(<input type="hidden" id={@id} name={@name} value={@value} {@rest} />\n)
      {:ok, tree} = Tree.parse_body(body)

      bad =
        Tree.walk(tree, [], fn node, acc ->
          {s, e} = Tree.node_byte_range(node, body)
          if s < 0 or e > byte_size(body) or e < s, do: [{elem(node, 0), s, e} | acc], else: acc
        end)

      assert bad == [], "nodes with out-of-bounds ranges: #{inspect(bad)}"
    end

    test "outer element range covers nested children too" do
      body = ~s(<div>\n  <span>{@x}</span>\n  <p>{@y}</p>\n</div>\n)
      {:ok, [div]} = Tree.parse_body(body)
      {s, e} = Tree.node_byte_range(div, body)
      slice = binary_part(body, s, e - s)
      assert String.starts_with?(slice, "<div>")
      assert String.ends_with?(slice, "</div>")
    end

    test "nested element sharing a line with its ancestor (issue #212)" do
      body = ~s|<h1><span class="title">Dashboard</span></h1>\n|
      {:ok, [{:element, "h1", _attrs, [span], _} = h1]} = Tree.parse_body(body)

      {hs, he} = Tree.node_byte_range(h1, body)
      assert binary_part(body, hs, he - hs) == ~s|<h1><span class="title">Dashboard</span></h1>|

      {ss, se} = Tree.node_byte_range(span, body)

      assert binary_part(body, ss, se - ss) == ~s|<span class="title">Dashboard</span>|
    end

    test "two sibling elements of the same kind on one line" do
      body = ~s|<p><span>a</span><span>b</span></p>\n|
      {:ok, [{:element, "p", _, [first, second], _}]} = Tree.parse_body(body)

      {fs, fe} = Tree.node_byte_range(first, body)
      assert binary_part(body, fs, fe - fs) == "<span>a</span>"

      {ss, se} = Tree.node_byte_range(second, body)
      assert binary_part(body, ss, se - ss) == "<span>b</span>"
    end

    test "nested eex_expr sharing a line with its element" do
      body = ~s|<button>{@label}</button>\n|
      {:ok, [{:element, "button", _, [expr], _}]} = Tree.parse_body(body)

      {s, e} = Tree.node_byte_range(expr, body)
      assert binary_part(body, s, e - s) == "{@label}"
    end
  end

  describe "node_byte_range/2 — slice-starts-with-tag invariant (issue #348/#350)" do
    # The real safety property every range consumer relies on: for an
    # `{:element, tag, …}` node the slice must begin with `<tag`. A drift
    # in the offset scan violates it — the slice lands on a sibling's close
    # tag or collapses to an empty `end..end` range.
    defp assert_every_element_slice_starts_with_tag(body) do
      {:ok, tree} = Tree.parse_body(body)

      bad =
        Tree.walk(tree, [], fn
          {:element, tag, _attrs, _children, _meta} = node, acc ->
            {s, e} = Tree.node_byte_range(node, body)
            slice = binary_part(body, s, max(e - s, 0))

            if e - s > 0 and String.starts_with?(slice, "<" <> tag),
              do: acc,
              else: [{tag, s, e, String.slice(slice, 0, 30)} | acc]

          _node, acc ->
            acc
        end)

      assert bad == [], "elements whose slice does not start with their tag: #{inspect(bad)}"
    end

    test "standalone `{@rest}` spread attribute does not drift siblings" do
      body = ~s|<div :if={@x} {@rest}>\n  <span>a</span>\n  <button>b</button>\n</div>\n|
      assert_every_element_slice_starts_with_tag(body)
    end

    test "standalone `{[...]}` dynamic-attribute list does not drift children" do
      body =
        ~s|<button class="c" {[{:"phx-x", ""}]} type="button">\n  <.icon name="x" />\n</button>\n|

      assert_every_element_slice_starts_with_tag(body)
    end

    test "bare `<` inside an `<%= if … do %>` expression is not matched as a tag" do
      body =
        ~s|<div>\n  <button {@rest}>x</button>\n  <%= if String.length(v) < 60 do %>\n    <span>y</span>\n  <% end %>\n</div>\n|

      assert_every_element_slice_starts_with_tag(body)
    end

    test "reduced :flash shape — multi-line spread tag with nested components" do
      body = """
      <div
        :if={msg = render_slot(@inner_block) || get(@flash, @kind)}
        phx-click={JS.push("clear") |> hide("#flash")}
        {@rest}
      >
        <p :if={@title}>
          <Heroicons.info :if={@kind == :info} mini class="h-4 w-4" />
          {@title}
        </p>
        <button :if={@close} type="button">
          <Heroicons.x_mark solid class="h-5 w-5" />
        </button>
      </div>
      """

      assert_every_element_slice_starts_with_tag(body)
    end

    test "multibyte text before a marker keeps byte offsets aligned" do
      # EEx columns count codepoints; a byte-naive offset would drift after the
      # 2-byte `ü`/`ä`/`ö`/`é`. Both the `<%= %>` expr and the trailing `<div>`
      # (preceded by multibyte content) must still slice correctly.
      body = ~s|<p>Über ältere Größen</p>\n<%= @x %>\n<div>café</div>\n|
      assert_every_element_slice_starts_with_tag(body)

      {:ok, tree} = Tree.parse_body(body)

      expr =
        Tree.walk(tree, nil, fn
          {:eex_expr, _, _} = n, _ -> n
          _, acc -> acc
        end)

      {s, e} = Tree.node_byte_range(expr, body)
      assert binary_part(body, s, e - s) == "<%= @x %>"
    end

    test "reduced menu_ui shape — spread attr + EEx if with `<` comparisons" do
      body = """
      <div>
        <%= if not is_nil(value) do %>
          <div class="bobble">
            <button
              class="x"
              {[{:"phx-value-\#{name}", ""}]}
              type="button"
            >
              <Heroicons.x_mark class="h-3 w-3" />
            </button>
          </div>
        <% end %>

        <%= if length(values) <= 3 && String.length(j) < 60 do %>
          <div class="row">
            <input type="radio" value={v} />
          </div>
        <% else %>
          <select name={name}>
            <option value="">pick</option>
          </select>
        <% end %>
      </div>
      """

      assert_every_element_slice_starts_with_tag(body)
    end
  end

  describe "node_byte_range/2 for eex nodes" do
    test "covers an eex_expr `{...}` interpolation" do
      body = ~s(<span>{@title}</span>)
      {:ok, [{:element, "span", _, [expr], _}]} = Tree.parse_body(body)
      {s, e} = Tree.node_byte_range(expr, body)
      assert binary_part(body, s, e - s) == "{@title}"
    end

    test "covers an eex_expr `<%= ... %>` expression without over-scanning (issue #216)" do
      body = ~s|<p><%= @greeting %></p>\n|
      {:ok, [{:element, "p", _, [expr], _}]} = Tree.parse_body(body)

      {s, e} = Tree.node_byte_range(expr, body)
      assert binary_part(body, s, e - s) == "<%= @greeting %>"
    end

    test "eex_expr `<%= ... %>` with a `}` in the code stops at `%>`" do
      body = ~s|<p><%= Map.get(m, :k) %> after</p>\n|
      {:ok, [{:element, "p", _, [expr | _], _}]} = Tree.parse_body(body)

      {s, e} = Tree.node_byte_range(expr, body)
      assert binary_part(body, s, e - s) == "<%= Map.get(m, :k) %>"
    end

    test "a `<%= case %>` block ends at its `<% end %>`, not swallowing siblings" do
      # case clauses `<% x -> %>` are NOT block openers; only `do` opens an
      # end-terminated block. A naive `->`-as-opener balancer over-scans past
      # the single `<% end %>` and eats the trailing `</div>`.
      body = """
      <div>
        <%= case @k do %>
          <% :a -> %>
            <span>{@a}</span>
          <% :b -> %>
            <span>{@b}</span>
        <% end %>
      </div>
      """

      {:ok, [{:element, "div", _, children, _}]} = Tree.parse_body(body)
      block = Enum.find(children, &match?({:eex_block, _, _, _}, &1))

      {s, e} = Tree.node_byte_range(block, body)
      frag = binary_part(body, s, e - s)

      assert String.ends_with?(String.trim_trailing(frag), "<% end %>")
      refute frag =~ "</div>"
    end
  end
end
