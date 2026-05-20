defmodule Number42.Refactors.Ex.ExtractHeexForTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractHeexFor

  @subject ExtractHeexFor

  describe "rewrites" do
    test "extracts a multi-line for body into a private component" do
      before_source = ~S'''
      defmodule MyView do
        def render(assigns) do
          ~H"""
          <ul>
            <%= for house <- @houses do %>
              <li>
                <span>{house.name}</span>
                <span>{house.size}</span>
                <span>{house.color}</span>
              </li>
            <% end %>
          </ul>
          """
        end
      end
      '''

      after_source = ~S'''
      defmodule MyView do
        def render(assigns) do
          ~H"""
          <ul>
            <%= for house <- @houses do %><.render_house_component house={house} /><% end %>
          </ul>
          """
        end

        defp render_house_component(assigns) do
          ~H"""
          <li>
            <span>{@house.name}</span>
            <span>{@house.size}</span>
            <span>{@house.color}</span>
          </li>
          """
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "leaves alone" do
    test "single-line for body (below the line threshold)" do
      assert_unchanged(@subject, ~S'''
      defmodule MyView do
        def render(assigns) do
          ~H"""
          <ul>
            <%= for x <- @xs do %><li>{x}</li><% end %>
          </ul>
          """
        end
      end
      ''')
    end

    test "for body containing nested EEx control flow (rejected)" do
      assert_unchanged(@subject, ~S'''
      defmodule MyView do
        def render(assigns) do
          ~H"""
          <ul>
            <%= for x <- @xs do %>
              <%= if x.flag do %>
                <li>{x.name}</li>
                <li>{x.size}</li>
                <li>{x.color}</li>
              <% end %>
            <% end %>
          </ul>
          """
        end
      end
      ''')
    end

    test "no ~H sigil at all" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def go(list) do
          for x <- list, do: x
        end
      end
      """)
    end

    test "two for blocks in the same fn would collide on component name" do
      # Both loops use the same enclosing fn (`render`) and the same loop
      # variable (`item`), so the synthesized component name would be
      # `render_item_component` for both — emitting a duplicate `defp`.
      # Skip rather than emit code that fails to compile; the human can
      # rename one loop variable and re-run.
      assert_unchanged(@subject, ~S'''
      defmodule MyView do
        def render(assigns) do
          ~H"""
          <ul>
            <%= for item <- @first do %>
              <li>
                <span>{item.name}</span>
                <span>{item.size}</span>
                <span>{item.color}</span>
              </li>
            <% end %>
            <%= for item <- @second do %>
              <li>
                <span>{item.label}</span>
                <span>{item.value}</span>
                <span>{item.tag}</span>
              </li>
            <% end %>
          </ul>
          """
        end
      end
      ''')
    end

    test "synthesized name collides with an existing function in the module" do
      # The module already defines `render_house_component/1`, so the
      # extracted block's synthesized name would clash. Skip the
      # extraction to avoid emitting a duplicate `defp`.
      assert_unchanged(@subject, ~S'''
      defmodule MyView do
        def render(assigns) do
          ~H"""
          <ul>
            <%= for house <- @houses do %>
              <li>
                <span>{house.name}</span>
                <span>{house.size}</span>
                <span>{house.color}</span>
              </li>
            <% end %>
          </ul>
          """
        end

        defp render_house_component(assigns) do
          ~H"""
          <li>pre-existing</li>
          """
        end
      end
      ''')
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, ~S'''
      defmodule MyView do
        def render(assigns) do
          ~H"""
          <ul>
            <%= for house <- @houses do %>
              <li>
                <span>{house.name}</span>
                <span>{house.size}</span>
                <span>{house.color}</span>
              </li>
            <% end %>
          </ul>
          """
        end
      end
      ''')
    end
  end
end
