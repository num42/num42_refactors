defmodule Number42.Refactors.Ex.SplitRootConditionalComponentTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.SplitRootConditionalComponent

  @subject SplitRootConditionalComponent

  @enabled [enabled: true]

  describe "default-OFF gate" do
    test "no-op when not enabled" do
      assert_unchanged(@subject, """
      defmodule M do
        def thing(assigns) do
          if assigns.kind == :link do
            ~H"<a>A</a>"
          else
            ~H"<button>B</button>"
          end
        end
      end
      """)
    end
  end

  describe "splits a root-level if-over-two-sigils into two clauses" do
    test "literal-equality condition becomes a head pattern + catch-all" do
      result =
        apply_refactor(
          @subject,
          """
          defmodule M do
            def thing(assigns) do
              if assigns.kind == :link do
                ~H"<a>A</a>"
              else
                ~H"<button>B</button>"
              end
            end
          end
          """,
          @enabled
        )

      # do-clause guards on the condition, keeps `assigns` bound
      assert result =~ ~r/def thing\(assigns\) when assigns\.kind == :link/
      # catch-all keeps the param named `assigns` (the ~H reads it)
      assert result =~ ~r/def thing\(assigns\) do/
      assert result =~ ~s|~H"<a>A</a>"|
      assert result =~ ~s|~H"<button>B</button>"|
      refute result =~ "_assigns"
      refute result =~ ~r/if .* do/
      assert_compiles_component(result)
    end

    test "key-membership condition (rest[:href]) becomes is_map_key guards" do
      result =
        apply_refactor(
          @subject,
          """
          defmodule M do
            def button(assigns) do
              if assigns.rest[:href] || assigns.rest[:navigate] do
                ~H"<.link {@rest}>x</.link>"
              else
                ~H"<button {@rest}>x</button>"
              end
            end
          end
          """,
          @enabled
        )

      assert result =~ "when"
      assert result =~ "is_map_key(assigns.rest, :href)"
      assert result =~ "is_map_key(assigns.rest, :navigate)"
      assert result =~ "def button(assigns) do"
      assert_compiles_component(result)
    end

    test "hoists `assigns = setup` into both clauses" do
      result =
        apply_refactor(
          @subject,
          """
          defmodule M do
            def thing(assigns) do
              assigns = assign_new(assigns, :class, fn -> "x" end)

              if assigns.kind == :link do
                ~H"<a class={@class}>A</a>"
              else
                ~H"<button class={@class}>B</button>"
              end
            end
          end
          """,
          @enabled
        )

      # the setup line appears in both clauses
      assert length(Regex.scan(~r/assign_new\(assigns, :class/, result)) == 2
      assert result =~ ~r/def thing\(assigns\) when assigns\.kind == :link/
      assert_compiles_component(result)
    end
  end

  describe "declines (derive-or-decline soundness gates)" do
    test "declines a branch that is not a sigil" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def thing(assigns) do
            if assigns.kind == :link do
              ~H"<a>A</a>"
            else
              raise "nope"
            end
          end
        end
        """,
        @enabled
      )
    end

    test "declines a guard-unsafe condition (arbitrary function call)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def thing(assigns) do
            if String.length(assigns.title) > 3 do
              ~H"<a>A</a>"
            else
              ~H"<button>B</button>"
            end
          end
        end
        """,
        @enabled
      )
    end

    test "declines a nested if inside a branch" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def thing(assigns) do
            if assigns.kind == :link do
              if assigns.big, do: ~H"<a>big</a>", else: ~H"<a>small</a>"
            else
              ~H"<button>B</button>"
            end
          end
        end
        """,
        @enabled
      )
    end

    test "declines a condition over a setup-derived assign (not an input)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def thing(assigns) do
            assigns = assign(assigns, :derived, compute(assigns))

            if assigns.derived == :x do
              ~H"<a>A</a>"
            else
              ~H"<button>B</button>"
            end
          end
        end
        """,
        @enabled
      )
    end

    test "declines an else-less if (single branch — not this refactor)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def thing(assigns) do
            if assigns.show do
              ~H"<a>A</a>"
            end
          end
        end
        """,
        @enabled
      )
    end

    test "declines a non-component def (param is not assigns)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def thing(x) do
            if x == :a do
              ~H"<a>A</a>"
            else
              ~H"<button>B</button>"
            end
          end
        end
        """,
        @enabled
      )
    end
  end

  describe "idempotent" do
    test "already-split component is a no-op" do
      assert_idempotent(
        @subject,
        """
        defmodule M do
          def thing(assigns) do
            if assigns.kind == :link do
              ~H"<a>A</a>"
            else
              ~H"<button>B</button>"
            end
          end
        end
        """,
        @enabled
      )
    end
  end

  # `~H` requires Phoenix.Component; compile a wrapper that `use`s it. Skips
  # gracefully if Phoenix.Component isn't available in this env.
  defp assert_compiles_component(source) do
    if Code.ensure_loaded?(Phoenix.Component) do
      wrapped =
        String.replace(source, "defmodule M do", "defmodule M do\n  use Phoenix.Component",
          global: false
        )

      assert_compiles(wrapped)
    else
      :ok
    end
  end
end
