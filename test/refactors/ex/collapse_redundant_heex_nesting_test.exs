defmodule Number42.Refactors.Ex.CollapseRedundantHeexNestingTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.CollapseRedundantHeexNesting

  @subject CollapseRedundantHeexNesting
  @enabled [enabled: true]

  describe "metadata" do
    test "implements Refactor behaviour" do
      Code.ensure_loaded!(@subject)
      assert function_exported?(@subject, :description, 0)
      assert function_exported?(@subject, :transform, 2)
      assert is_binary(@subject.description())
      assert is_binary(@subject.explanation())
      assert is_integer(@subject.priority())
    end

    test "reformats after rewriting (HEEx sigils need formatter)" do
      assert @subject.reformat_after?() == true
    end
  end

  describe "default-off" do
    test "is a no-op without enabled: true" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <div class="card">{@body}</div>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, [])
    end
  end

  describe "Case B — pull styling up from the only child" do
    test "div > div[class] collapses; outer adopts the class, inner dissolves" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <div class="card">{@body}</div>
          </div>
          \"\"\"
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)

      # Outer keeps its tag and adopts the child's class.
      assert result =~ ~s(<div class="card">)
      # The inner element's content is preserved.
      assert result =~ "{@body}"
      # Exactly one `<div ` survives (the merged one) and no nested empty div.
      refute result =~ ~s(<div>\n)
      assert collapsed_div_count(result) == 1
    end

    test "section > section[class] collapses" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <section>
            <section class="panel">Hi</section>
          </section>
          \"\"\"
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)
      assert result =~ ~s(<section class="panel">)
      assert result =~ "Hi"
    end

    test "outer and inner may be different transparent containers" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <span class="badge">{@n}</span>
          </div>
          \"\"\"
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)
      # Outer tag stays div, takes the class; inner span dissolves.
      assert result =~ ~s(<div class="badge">)
      refute result =~ "<span"
    end

    test "preserves the inner element's full inner content" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <article class="entry">
              <h2>{@title}</h2>
              <p>{@text}</p>
            </article>
          </div>
          \"\"\"
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)
      assert result =~ ~s(<div class="entry">)
      assert result =~ "<h2>{@title}</h2>"
      assert result =~ "<p>{@text}</p>"
      refute result =~ "<article"
    end
  end

  describe "skip conditions" do
    test "skips when the child carries an attribute other than class" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <div class="card" id="main">{@body}</div>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "skips when the child carries a phx-* listener" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <div class="card" phx-click="go">{@body}</div>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "skips when the child carries a :for directive" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <div class="row" :for={r <- @rows}>{r}</div>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "skips when the outer has more than one child element" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <div class="a">{@one}</div>
            <div class="b">{@two}</div>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "skips when the outer has a non-whitespace text sibling" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            leading text
            <div class="card">{@body}</div>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "skips when the outer has a {...} expression sibling" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            {@prefix}
            <div class="card">{@body}</div>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "Case A: a wrapper around a single component collapses, component kept verbatim" do
      # the dominant real-world fuel: an attribute-less div wrapping one component
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <.card class="x">{@body}</.card>
          </div>
          \"\"\"
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)
      assert result =~ ~s(<.card class="x">{@body}</.card>)
      refute result =~ "<div>"
    end

    test "skips when the single child is a slot entry (<:x>)" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <.modal>
            <:header class="h">{@title}</:header>
          </.modal>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "skips when the single child is an eex block, not an element" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <%= if @cond do %>
              <span class="x">hi</span>
            <% end %>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "skips a content-model tag boundary: ul > li[class] is untouched" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <ul>
            <li class="item">{@x}</li>
          </ul>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "skips table > tr[class] content-model boundary" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <table>
            <tr class="r">{@x}</tr>
          </table>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "skips when the outer is not a transparent container" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <button>
            <div class="label">{@text}</div>
          </button>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "skips when the inner is not a transparent container" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <button class="btn">{@text}</button>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "skips when the outer carries any attribute" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div class="outer">
            <div class="card">{@body}</div>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "Case A: an attribute-less element child collapses (outer wins, content promoted)" do
      # inner div has no attributes -> nothing to lose; the outer tag stays and
      # the inner's content is promoted into it
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <div>{@body}</div>
          </div>
          \"\"\"
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)
      assert result =~ "{@body}"
      assert collapsed_div_count(result) == 1
    end
  end

  describe "idempotence" do
    test "running twice equals running once" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <div class="card">{@body}</div>
          </div>
          \"\"\"
        end
      end
      """

      assert_idempotent(@subject, source, @enabled)
    end

    test "already-collapsed code (div[class] with no redundant wrapper) is left alone" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div class="card">{@body}</div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end
  end

  describe "production-size template" do
    test "collapses the one redundant wrapper inside a large template, leaving everything else intact" do
      source = """
      defmodule MyApp.DashboardLive do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <main class="dashboard">
            <header class="topbar">
              <h1>{@title}</h1>
              <nav class="links">
                <a href="/home">Home</a>
                <a href="/settings">Settings</a>
              </nav>
            </header>

            <section class="content">
              <div>
                <article class="metric-card">
                  <span class="metric-label">{@label}</span>
                  <strong class="metric-value">{@value}</strong>
                </article>
              </div>

              <ul class="feed">
                <%= for item <- @items do %>
                  <li class="feed-item" phx-click="open" phx-value-id={item.id}>
                    <span>{item.name}</span>
                  </li>
                <% end %>
              </ul>
            </section>

            <footer class="legal">
              <small>© {@year}</small>
            </footer>
          </main>
          \"\"\"
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)

      # The one redundant `<div>` wrapping `<article class="metric-card">`
      # collapses: outer div adopts the class, the article dissolves.
      assert result =~ ~s(<div class="metric-card">)
      refute result =~ "<article"

      # The article's inner content is preserved verbatim.
      assert result =~ ~s(<span class="metric-label">{@label}</span>)
      assert result =~ ~s(<strong class="metric-value">{@value}</strong>)

      # Everything that must NOT collapse stays put:
      # - ul > li (content model boundary, plus li has listeners)
      assert result =~ ~s(<li class="feed-item")
      assert result =~ "phx-click=\"open\""
      # - the for-loop survives
      assert result =~ "<%= for item <- @items do %>"
      # - landmark elements with attributes are untouched
      assert result =~ ~s(<main class="dashboard">)
      assert result =~ ~s(<header class="topbar">)
      assert result =~ ~s(<nav class="links">)
      assert result =~ ~s(<footer class="legal">)
    end
  end

  describe "Case A — dissolve an empty wrapper around a single child" do
    test "div wrapping a single component collapses; outer dissolves, component stays" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <.defining value={@value} label={@label} />
          </div>
          \"\"\"
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)

      # the redundant wrapper div is gone; the component survives verbatim
      assert result =~ ~s(<.defining value={@value} label={@label} />)
      refute result =~ "<div>"
    end

    test "attribute-less article wrapping a single section collapses (outer wins)" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <article>
            <section>
              <h2>{@title}</h2>
              <p>{@body}</p>
            </section>
          </article>
          \"\"\"
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)

      # outer tag wins; the inner section dissolves, its children promoted
      assert result =~ "<article>"
      refute result =~ "<section>"
      assert result =~ "<h2>{@title}</h2>"
      assert result =~ "<p>{@body}</p>"
    end

    test "inner transparent container with only a class is Case B (hoist), not A" do
      # outer div empty, inner span is a transparent container with only a class
      # -> Case B wins (preferred): the outer adopts the class, the span dissolves
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <span class="badge">{@n}</span>
          </div>
          \"\"\"
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)
      assert result =~ ~s(<div class="badge">{@n}</div>)
      refute result =~ "<span"
    end

    test "SKIP: outer carries an attribute" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div class="wrap">
            <.defining value={@v} />
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "SKIP: outer has a text sibling next to the child" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            Heading
            <.defining value={@v} />
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "SKIP: child is a slot entry (boundary of the parent component)" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <.table rows={@rows}>
            <:col :let={r}>{r.name}</:col>
          </.table>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "SKIP: child is an <%= for %> block (not a wrapper)" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <%= for x <- @xs do %>
              <p>{x}</p>
            <% end %>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "SKIP: child is a content-model element (div > tr)" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <tr><td>{@a}</td></tr>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "SKIP: outer has multiple element children" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <.defining value={@a} />
            <.defining value={@b} />
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "re-indents a promoted multi-line component to the outer's column" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div class="grid">
            <div>
              <.defining
                term="Hochgeladen"
                definition={@y}
              />
            </div>
          </div>
          \"\"\"
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)
      # the inner div is gone; the component's continuation lines are shifted left
      # by the wrapper's indent so they stay aligned with the component's open tag
      assert result =~
               "      <.defining\n        term=\"Hochgeladen\"\n        definition={@y}\n      />"

      refute result =~ "    <div>\n"
    end

    test "idempotent: a collapsed component wrapper does not re-match" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div>
            <.defining value={@v} />
          </div>
          \"\"\"
        end
      end
      """

      once = apply_refactor(@subject, source, @enabled)
      twice = apply_refactor(@subject, once, @enabled)
      assert once == twice
    end
  end

  # Count `<div ` open tags (with attributes) plus bare `<div>` opens,
  # excluding closing tags. Used to assert the wrapper is gone.
  defp collapsed_div_count(source) do
    Regex.scan(~r/<div(\s|>)/, source) |> length()
  end
end
