defmodule Number42.Refactors.Analysis.Heex.TreeTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Analysis.Heex.Tree

  describe "parse_body/1" do
    test "parses a simple element with literal children" do
      assert {:ok,
              [
                {:element, "div", [{"class", {:string, "x"}}], [{:text, "hello", _}], _}
              ]} = Tree.parse_body(~s(<div class="x">hello</div>))
    end

    test "splits text-with-curlies into text + eex_expr nodes" do
      assert {:ok,
              [
                {:element, "span", [], [{:eex_expr, "@name", _}], _}
              ]} = Tree.parse_body(~s(<span>{@name}</span>))
    end

    test "preserves attribute interpolation as :expr value" do
      assert {:ok, [{:element, "div", [{"class", {:expr, "@cls"}}], [], _}]} =
               Tree.parse_body(~s(<div class={@cls}></div>))
    end

    test "wraps an EEx for-block with its children as nested nodes" do
      body = """
      <ul>
        <%= for h <- @houses do %>
          <li>{h.name}</li>
        <% end %>
      </ul>
      """

      assert {:ok,
              [
                {:element, "ul", [],
                 [
                   {:eex_block, " for h <- @houses do ",
                    [
                      {:element, "li", [], [{:eex_expr, "h.name", _}], _}
                    ], _}
                 ], _}
              ]} = Tree.parse_body(body)
    end

    test "handles self-closing components" do
      assert {:ok, [{:element, ".my_comp", [{"foo", {:expr, "@bar"}}], [], _}]} =
               Tree.parse_body(~s(<.my_comp foo={@bar} />))
    end

    test "drops whitespace-only text between siblings" do
      body = "<div>\n  <span>a</span>\n  <span>b</span>\n</div>"

      {:ok, [{:element, "div", [], children, _}]} = Tree.parse_body(body)

      assert [
               {:element, "span", [], [{:text, "a", _}], _},
               {:element, "span", [], [{:text, "b", _}], _}
             ] = children
    end
  end

  describe "from_source/1" do
    test "collects every ~H sigil in a module and tags it with its enclosing fn" do
      source = ~S'''
      defmodule Demo do
        def render_a(assigns) do
          ~H"""
          <div>a</div>
          """
        end

        defp render_b(assigns) do
          ~H"""
          <span>b</span>
          """
        end
      end
      '''

      assert {:ok, sigils} = Tree.from_source(source)
      assert length(sigils) == 2

      names = sigils |> Enum.map(& &1.enclosing_fn) |> Enum.sort()
      assert names == [:render_a, :render_b]

      assert sigils |> Enum.all?(fn s -> is_list(s.tree) and s.tree != [] end)
    end

    test "skips sigils whose body cannot be parsed cleanly without crashing" do
      # Stray `<` inside text is tolerated and treated as text.
      source = ~S'''
      defmodule Demo do
        def render(assigns) do
          ~H"""
          <div>a < b</div>
          """
        end
      end
      '''

      assert {:ok, [%{tree: tree}]} = Tree.from_source(source)
      assert tree != []
    end
  end

  describe "line tracking" do
    test "nested elements get their actual line, not the body's first line" do
      body = """
      <div>
        <span>line two body</span>

        <article>
          <h2>line five body</h2>
        </article>
      </div>
      """

      {:ok, [{:element, "div", [], children, %{line: 1}}]} = Tree.parse_body(body)

      [
        {:element, "span", _, _, %{line: span_line}},
        {:element, "article", _, art_kids, %{line: art_line}}
      ] =
        children

      assert span_line == 2
      assert art_line == 4

      [{:element, "h2", _, _, %{line: h2_line}}] = art_kids
      assert h2_line == 5
    end

    test "curly interpolations track their line within a multi-line text" do
      body = """
      <p>
        first
        {@x}
      </p>
      """

      {:ok, [{:element, "p", _, kids, _}]} = Tree.parse_body(body)
      eex = kids |> Enum.find(&match?({:eex_expr, _, _}, &1))
      assert {:eex_expr, "@x", %{line: 3}} = eex
    end

    test "self-closing components track their line" do
      body = """
      <div>
        <span />
        <.icon name="x" />
      </div>
      """

      {:ok, [{:element, "div", _, kids, _}]} = Tree.parse_body(body)
      [span, icon] = kids
      assert {:element, "span", _, _, %{line: 2}} = span
      assert {:element, ".icon", _, _, %{line: 3}} = icon
    end
  end

  describe "walk/3" do
    test "visits every node pre-order" do
      {:ok, tree} = Tree.parse_body(~s(<div><span>x</span><span>y</span></div>))

      kinds =
        Tree.walk(tree, [], fn node, acc -> [elem(node, 0) | acc] end)
        |> Enum.reverse()

      assert kinds == [:element, :element, :text, :element, :text]
    end
  end

  describe "cursor never overruns the body (issue #260)" do
    test "tag whose `{...}` attribute reaches the body end does not crash the offset scan" do
      # Reduced from a real position-db flash component: an element whose
      # attributes are `{...}` interpolations containing `||`, `%{}`, `#{}`
      # and a pipe — the tag-end scanner walked past byte_size(body), and the
      # next event's offset lookup got a negative `:binary.match` scope length.
      body = ~S"""
      <div
        :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
        id={@id}
        phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
        role="alert"
        class="toast toast-top toast-end z-[9999] top-16"
        {@rest}
      >
        <div class={[
          "alert w-80 sm:w-96",
          @kind == :info && "alert-info",
          @kind == :error && "alert-error"
        ]}>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
      </div>
      """

      assert {:ok, [{:element, "div", _attrs, _kids, _meta}]} = Tree.parse_body(body)
    end

    test "self-closing tag at the very end of the body does not overrun" do
      body = ~s(<.icon name="x" />)
      assert {:ok, [{:element, ".icon", _, _, _}]} = Tree.parse_body(body)
    end
  end
end
