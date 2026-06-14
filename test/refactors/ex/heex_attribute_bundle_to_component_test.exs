defmodule Number42.Refactors.Ex.HeexAttributeBundleToComponentTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.HeexAttributeBundleToComponent

  @subject HeexAttributeBundleToComponent
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
          <div class="danger_panel">
            <p>{@first}</p>
          </div>
          <div class="danger_panel">
            <p>{@second}</p>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, [])
    end
  end

  describe "extracts a repeated static-attribute shell into a slot component" do
    test "two danger_panel divs become one component + two calls" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div class="danger_panel">
            <p>{@first}</p>
          </div>
          <div class="danger_panel">
            <strong>{@second}</strong>
          </div>
          \"\"\"
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)

      # A private slot component was synthesised.
      assert result =~ "defp danger_panel(assigns)"
      assert result =~ "slot :inner_block"
      assert result =~ "render_slot(@inner_block)"

      # Each occurrence is replaced with a call wrapping its original body.
      assert result =~ "<.danger_panel>"
      assert result =~ "</.danger_panel>"
      assert result =~ "<p>{@first}</p>"
      assert result =~ "<strong>{@second}</strong>"

      # The raw repeated shell is gone from the render body (only the
      # generated component definition keeps the `class="danger_panel"`).
      refute result =~ ~s(<div class="danger_panel">\n    <p>)
    end

    test "the generated component carries the shared static attribute" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <section class="card highlight">
            <p>{@a}</p>
          </section>
          <section class="card highlight">
            <p>{@b}</p>
          </section>
          \"\"\"
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)
      assert result =~ ~s(<section class="card highlight">)
      assert result =~ "render_slot(@inner_block)"
    end
  end

  describe "dynamic attributes" do
    test "extracts when the dynamic attribute bundle is identical across occurrences" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div class="primary_button" id={@id}>
            <span>{@one}</span>
          </div>
          <div class="primary_button" id={@id}>
            <span>{@two}</span>
          </div>
          \"\"\"
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)
      assert result =~ "defp primary_button(assigns)"
      assert result =~ "attr :id, :any"
      # The dynamic attribute is forwarded at the call site.
      assert result =~ "<.primary_button id={@id}>"
    end

    test "does not extract when dynamic attribute values differ across occurrences" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div class="primary_button" id={@first_id}>
            <span>{@one}</span>
          </div>
          <div class="primary_button" id={@second_id}>
            <span>{@two}</span>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end
  end

  describe "skip conditions" do
    test "skips a shell that occurs only once" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div class="empty_state">
            <p>{@only}</p>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "skips form/input/semantic elements to preserve accessibility semantics" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <form class="login_form">
            <input name="first" />
          </form>
          <form class="login_form">
            <input name="second" />
          </form>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "skips when the body binds a local variable that cannot become slot content" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div class="loop_panel">
            <%= for item <- @items do %>
              <span>{item}</span>
            <% end %>
          </div>
          <div class="loop_panel">
            <%= for item <- @others do %>
              <span>{item}</span>
            <% end %>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "skips when the generated component name collides with an existing function" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def danger_panel(assigns) do
          ~H\"\"\"
          <aside>{@x}</aside>
          \"\"\"
        end

        def render(assigns) do
          ~H\"\"\"
          <div class="danger_panel">
            <p>{@first}</p>
          </div>
          <div class="danger_panel">
            <p>{@second}</p>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "skips shells with no class token to name from" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div data-role="x">
            <p>{@first}</p>
          </div>
          <div data-role="x">
            <p>{@second}</p>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end
  end

  describe "idempotence" do
    test "running twice equals running once" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div class="danger_panel">
            <p>{@first}</p>
          </div>
          <div class="danger_panel">
            <strong>{@second}</strong>
          </div>
          \"\"\"
        end
      end
      """

      assert_idempotent(@subject, source, @enabled)
    end

    test "leaves already-extracted code (component calls) alone" do
      source = """
      defmodule MyApp.Page do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <.danger_panel>
            <p>{@first}</p>
          </.danger_panel>
          <.danger_panel>
            <strong>{@second}</strong>
          </.danger_panel>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end
  end

  describe "produces compilable output" do
    test "rewritten module compiles" do
      source = """
      defmodule MyApp.CompilePage do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div class="danger_panel">
            <p>{@first}</p>
          </div>
          <div class="danger_panel">
            <strong>{@second}</strong>
          </div>
          \"\"\"
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)
      assert result =~ "defp danger_panel(assigns)"
    end
  end
end
