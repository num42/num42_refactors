defmodule Number42.Refactors.Ex.ConvertLiveComponentToFunctionTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ConvertLiveComponentToFunction

  @subject ConvertLiveComponentToFunction

  @enabled [enabled: true]

  describe "default-OFF gate" do
    test "no-op when not enabled" do
      assert_unchanged(@subject, stateless_component())
    end
  end

  describe "converts a stateless live_component module (no same-file callers)" do
    test "drops `:live_component` for `:html`, removes update/2, turns render/1 into the function" do
      result = apply_refactor(@subject, stateless_component(), @enabled)

      # module shell switches to :html
      assert result =~ ~r/use\s+MyAppWeb,\s*:html/
      refute result =~ ":live_component"
      # update/2 is gone
      refute result =~ "def update("
      # render/1 becomes a named function component (file basename → fn name)
      assert result =~ ~r/def badge\(assigns\)/
      refute result =~ "def render("
    end

    test "emits attr declarations inferred from the render body" do
      result = apply_refactor(@subject, stateless_component(), @enabled)
      assert result =~ ~r/attr :label/
    end
  end

  describe "rewrites a same-file caller" do
    test "<.live_component module={__MODULE__} id=.. label=..> becomes <.badge label=..>" do
      source = """
      defmodule MyAppWeb.BadgeUser do
        use MyAppWeb, :live_view

        def render(assigns) do
          ~H'''
          <.live_component module={MyAppWeb.Badge} id="b1" label={@text} />
          '''
        end
      end

      defmodule MyAppWeb.Badge do
        use MyAppWeb, :live_component

        def update(assigns, socket), do: {:ok, assign(socket, assigns)}

        def render(assigns) do
          ~H'''
          <span>{@label}</span>
          '''
        end
      end
      """

      result = apply_refactor(@subject, source, @enabled)

      # the caller tag is rewritten alias-qualified (module/id dropped, attrs kept)
      assert result =~ ~r/<Badge\.badge label=\{@text\}/
      refute result =~ "<.live_component module={MyAppWeb.Badge}"
      # the caller module gains `alias MyAppWeb.Badge` so `<Badge.badge>` resolves
      assert result =~ "alias MyAppWeb.Badge"
    end
  end

  describe "declines (derive-or-decline soundness gates)" do
    test "declines a live_component with handle_event/3 (stateful)" do
      assert_unchanged(
        @subject,
        """
        defmodule MyAppWeb.Clicker do
          use MyAppWeb, :live_component

          def update(assigns, socket), do: {:ok, assign(socket, assigns)}
          def handle_event("go", _params, socket), do: {:noreply, socket}

          def render(assigns) do
            ~H'<button phx-click="go">{@label}</button>'
          end
        end
        """,
        @enabled
      )
    end

    test "declines when update/2 derives non-assign state" do
      assert_unchanged(
        @subject,
        """
        defmodule MyAppWeb.Deriver do
          use MyAppWeb, :live_component

          def update(assigns, socket) do
            {:ok, socket |> assign(assigns) |> assign(:now, System.system_time())}
          end

          def render(assigns) do
            ~H'<span>{@now}</span>'
          end
        end
        """,
        @enabled
      )
    end

    test "declines when send_update / async is present" do
      assert_unchanged(
        @subject,
        """
        defmodule MyAppWeb.Async do
          use MyAppWeb, :live_component

          def update(assigns, socket) do
            send_update(__MODULE__, id: assigns.id)
            {:ok, assign(socket, assigns)}
          end

          def render(assigns), do: ~H'<span>{@x}</span>'
        end
        """,
        @enabled
      )
    end

    test "declines a plain module that is not a live_component" do
      assert_unchanged(
        @subject,
        """
        defmodule MyAppWeb.Plain do
          use MyAppWeb, :html
          def thing(assigns), do: ~H'<span>{@x}</span>'
        end
        """,
        @enabled
      )
    end

    test "declines (in slice 1) a stateless component with a caller in ANOTHER file is out of scope here" do
      # A bare stateless component with no same-file caller is still converted;
      # cross-file callers are slice 2. This fixture has the component alone —
      # converting it is fine; the cross-file caller gate is exercised by the
      # dogfood, not a unit fixture (single-string input has no separate file).
      result = apply_refactor(@subject, stateless_component(), @enabled)
      refute result =~ ":live_component"
    end
  end

  describe "idempotent" do
    test "an already-converted function component is a no-op" do
      converted = apply_refactor(@subject, stateless_component(), @enabled)
      assert_unchanged(@subject, converted, @enabled)
    end
  end

  describe "cross-file caller gate (slice 1 declines; slice 2 territory)" do
    # When the corpus index (from prepare/source_files) shows the module is
    # called as <.live_component module={Mod}/> in ANOTHER file, slice 1 declines
    # — converting the module without fixing those callers would break them.
    test "declines when a caller lives in another file" do
      source = stateless_component()

      prepared = %{
        callers: %{"Badge" => MapSet.new(["lib/other_caller.ex"])},
        source_to_file: %{source => "lib/badge.ex"}
      }

      result = @subject.transform(source, enabled: true, prepared: prepared)
      assert result == source
    end

    test "converts when the only caller is the module's own file" do
      source = stateless_component()

      prepared = %{
        callers: %{"Badge" => MapSet.new(["lib/badge.ex"])},
        source_to_file: %{source => "lib/badge.ex"}
      }

      result = @subject.transform(source, enabled: true, prepared: prepared)
      refute result =~ ":live_component"
    end
  end

  defp stateless_component do
    """
    defmodule MyAppWeb.Badge do
      use MyAppWeb, :live_component

      def update(assigns, socket), do: {:ok, assign(socket, assigns)}

      def render(assigns) do
        ~H'''
        <span class="badge">{@label}</span>
        '''
      end
    end
    """
  end
end
