defmodule Number42.Refactors.Ex.GenerateHeexAssignContractsTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.GenerateHeexAssignContracts

  @subject GenerateHeexAssignContracts

  @enabled [enabled: true]

  describe "default-off" do
    test "does nothing unless enabled: true" do
      assert_unchanged(@subject, ~S'''
      defmodule MyView do
        def greeting(assigns) do
          ~H"""
          <p>{@name}</p>
          """
        end
      end
      ''')
    end
  end

  describe "rewrites" do
    test "generates attr declarations for undeclared assigns" do
      before_source = ~S'''
      defmodule MyView do
        def greeting(assigns) do
          ~H"""
          <p>Hello {@name}, you are {@role}.</p>
          """
        end
      end
      '''

      after_source = ~S'''
      defmodule MyView do
        attr :name, :any, required: true
        attr :role, :any, required: true

        def greeting(assigns) do
          ~H"""
          <p>Hello {@name}, you are {@role}.</p>
          """
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source, @enabled)
    end

    test "infers :string for class/id/name/title/href attrs" do
      before_source = ~S'''
      defmodule MyView do
        def box(assigns) do
          ~H"""
          <a class={@class} href={@href} title={@title}>link</a>
          """
        end
      end
      '''

      after_source = ~S'''
      defmodule MyView do
        attr :class, :string, required: true
        attr :href, :string, required: true
        attr :title, :string, required: true

        def box(assigns) do
          ~H"""
          <a class={@class} href={@href} title={@title}>link</a>
          """
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source, @enabled)
    end

    test "infers :boolean for boolean HTML attrs" do
      before_source = ~S'''
      defmodule MyView do
        def button(assigns) do
          ~H"""
          <button disabled={@disabled}>go</button>
          """
        end
      end
      '''

      after_source = ~S'''
      defmodule MyView do
        attr :disabled, :boolean, required: true

        def button(assigns) do
          ~H"""
          <button disabled={@disabled}>go</button>
          """
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source, @enabled)
    end

    test "infers :map for field access with no stronger signal" do
      before_source = ~S'''
      defmodule MyView do
        def card(assigns) do
          ~H"""
          <div>{@user.name}</div>
          """
        end
      end
      '''

      after_source = ~S'''
      defmodule MyView do
        attr :user, :map, required: true

        def card(assigns) do
          ~H"""
          <div>{@user.name}</div>
          """
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source, @enabled)
    end

    test "infers :slot for @inner_block usage" do
      before_source = ~S'''
      defmodule MyView do
        def wrapper(assigns) do
          ~H"""
          <section>{render_slot(@inner_block)}</section>
          """
        end
      end
      '''

      after_source = ~S'''
      defmodule MyView do
        slot :inner_block, required: true

        def wrapper(assigns) do
          ~H"""
          <section>{render_slot(@inner_block)}</section>
          """
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source, @enabled)
    end

    test "only generates attrs for assigns not already declared" do
      before_source = ~S'''
      defmodule MyView do
        attr :name, :string, default: nil

        def greeting(assigns) do
          ~H"""
          <p>{@name} is {@role}</p>
          """
        end
      end
      '''

      # Generated declarations are inserted directly above the component,
      # leaving any hand-authored declarations (here `attr :name`) in place.
      after_source = ~S'''
      defmodule MyView do
        attr :name, :string, default: nil

        attr :role, :any, required: true

        def greeting(assigns) do
          ~H"""
          <p>{@name} is {@role}</p>
          """
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source, @enabled)
    end

    test "multi-clause component: attrs anchored before the FIRST clause, unioned across clauses" do
      # Phoenix requires every `attr`/`slot` to precede the first clause of a
      # multi-clause component; an `attr` before a later clause is a compile
      # error. The block must be hoisted to the first clause and the missing
      # assigns unioned across every clause (`@type` is only read by the
      # second clause, `@label` only by the first).
      before_source = ~S'''
      defmodule MyView do
        def input(%{kind: :select} = assigns) do
          ~H"""
          <label>{@label}</label>
          """
        end

        def input(assigns) do
          ~H"""
          <input type={@type} />
          """
        end
      end
      '''

      after_source = ~S'''
      defmodule MyView do
        attr :label, :any, required: true
        attr :type, :any, required: true

        def input(%{kind: :select} = assigns) do
          ~H"""
          <label>{@label}</label>
          """
        end

        def input(assigns) do
          ~H"""
          <input type={@type} />
          """
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source, @enabled)
    end
  end

  describe "derived assigns (set in the body) are not declared" do
    test "an assign computed via assign/3 in the body gets no attr" do
      # `@pdf_url` is derived inside the component from `@asset`; the caller
      # must NOT pass it, so an `attr :pdf_url, required: true` would be wrong.
      # Only the genuine input `@asset` is declared.
      before_source = ~S'''
      defmodule MyView do
        def pdf_preview(assigns) do
          assigns = assign(assigns, :pdf_url, download_url(assigns.asset))

          ~H"""
          <object data={@pdf_url}>{@asset.name}</object>
          """
        end
      end
      '''

      after_source = ~S'''
      defmodule MyView do
        attr :asset, :map, required: true

        def pdf_preview(assigns) do
          assigns = assign(assigns, :pdf_url, download_url(assigns.asset))

          ~H"""
          <object data={@pdf_url}>{@asset.name}</object>
          """
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source, @enabled)
    end

    test "the pipe form `assigns |> assign(:x, ...)` is also recognised as derived" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule MyView do
          def card(assigns) do
            assigns = assigns |> assign(:label, build_label(assigns))

            ~H"""
            <span>{@label}</span>
            """
          end
        end
        ''',
        @enabled
      )
    end

    test "assign_new and keyword-form assign targets are recognised as derived" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule MyView do
          def panel(assigns) do
            assigns =
              assigns
              |> assign_new(:open, fn -> false end)
              |> assign(title: "x", count: 0)

            ~H"""
            <details open={@open}><summary>{@title}</summary>{@count}</details>
            """
          end
        end
        ''',
        @enabled
      )
    end
  end

  describe "leaves alone" do
    test "all assigns already declared" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule MyView do
          attr :name, :string, required: true
          attr :role, :any, required: true

          def greeting(assigns) do
            ~H"""
            <p>{@name} {@role}</p>
            """
          end
        end
        ''',
        @enabled
      )
    end

    test "function takes assigns but has no ~H sigil" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule MyView do
          def build(assigns) do
            Map.put(assigns, :ready, true)
          end
        end
        ''',
        @enabled
      )
    end

    test "function returns a sigil but does not take assigns" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule MyView do
          def page(conn) do
            ~H"""
            <p>{@name}</p>
            """
          end
        end
        ''',
        @enabled
      )
    end

    test "no @assign references in the sigil" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule MyView do
          def static(assigns) do
            ~H"""
            <p>hello world</p>
            """
          end
        end
        ''',
        @enabled
      )
    end

    test "ignores the reserved @inner_block-free special assigns" do
      # `@socket`, `@flash`, `@myself`, `@__changed__` are LiveView-provided
      # special assigns, never declared with `attr`.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule MyView do
          def panel(assigns) do
            ~H"""
            <div id={@myself}>{@flash}</div>
            """
          end
        end
        ''',
        @enabled
      )
    end
  end

  # The contract is only exhaustive once it accounts for what the callers pass:
  # declaring one attr makes Phoenix validate every attribute at every site.
  describe "call-site aware contract" do
    defp index(sites) do
      caller = """
      defmodule Caller do
        def page(assigns) do
          ~H\"\"\"
      #{sites}
          \"\"\"
        end
      end
      """

      dir = Path.join(System.tmp_dir!(), "n42_contract_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "caller.ex")
      File.write!(path, caller)
      on_exit(fn -> File.rm_rf!(dir) end)

      GenerateHeexAssignContracts.build_call_index([path])
    end

    defp slot_component(body) do
      """
      defmodule MyView do
        def slot_row(assigns) do
          ~H\"\"\"
          #{body}
          \"\"\"
        end
      end
      """
    end

    test "declares an attr the callers pass but the body never reads" do
      built = index(~S|      <.slot_row design={@design} milestone={@m} />|)

      after_src =
        apply_refactor(@subject, slot_component("<span>{@milestone}</span>"),
          enabled: true,
          prepared: built
        )

      assert after_src =~ "attr :design, :any, required: true"
      assert after_src =~ "attr :milestone, :any, required: true"
    end

    test "an attr only some call sites pass is declared without required: true" do
      built =
        index("""
              <.slot_row milestone={@m} design={@d} />
              <.slot_row milestone={@m} />
        """)

      after_src =
        apply_refactor(@subject, slot_component("<span>{@milestone}</span>"),
          enabled: true,
          prepared: built
        )

      assert after_src =~ "attr :design, :any\n"
      refute after_src =~ "attr :design, :any, required: true"
      assert after_src =~ "attr :milestone, :any, required: true"
    end

    test "an assign the body reads but no caller passes is not marked required" do
      built = index(~S|      <.slot_row milestone={@m} />|)

      after_src =
        apply_refactor(@subject, slot_component("<span>{@milestone} {@design}</span>"),
          enabled: true,
          prepared: built
        )

      assert after_src =~ "attr :design, :any\n"
      refute after_src =~ "attr :design, :any, required: true"
    end

    test "a spreading call site hides the names, so the component is left alone" do
      built = index(~S|      <.slot_row {@rest} milestone={@m} />|)

      assert_unchanged(@subject, slot_component("<span>{@milestone}</span>"),
        enabled: true,
        prepared: built
      )
    end

    test "global attributes at a call site become one :global attr" do
      built = index(~S|      <.slot_row milestone={@m} phx-click="go" data-id="1" />|)

      after_src =
        apply_refactor(@subject, slot_component("<span>{@milestone}</span>"),
          enabled: true,
          prepared: built
        )

      assert after_src =~ "attr :rest, :global"
      refute after_src =~ "phx-click"
      refute after_src =~ "data-id"
    end

    test "a declaration binds to its own component, not the whole module" do
      built = index(~S|      <.slot_row design={@d} milestone={@m} />|)

      before_source = ~S'''
      defmodule MyView do
        attr :design, :any, required: true

        def other(assigns) do
          ~H"""
          <span>{@design}</span>
          """
        end

        def slot_row(assigns) do
          ~H"""
          <span>{@milestone}</span>
          """
        end
      end
      '''

      after_src = apply_refactor(@subject, before_source, enabled: true, prepared: built)

      # `attr :design` above `other/1` says nothing about `slot_row/1`, whose
      # callers pass `design` too.
      assert after_src =~ "attr :design, :any, required: true\n  attr :milestone"
    end

    test "a named slot is declared as a slot, not an attribute" do
      built = index(~S|      <.slot_row milestone={@m}><:back>go</:back></.slot_row>|)

      after_src =
        apply_refactor(@subject, slot_component("<span>{@milestone}{render_slot(@back)}</span>"),
          enabled: true,
          prepared: built
        )

      assert after_src =~ "slot :back, required: true"
      refute after_src =~ "attr :back"
    end

    test "a slot only some call sites fill is not required" do
      built =
        index("""
              <.slot_row milestone={@m}><:back>go</:back></.slot_row>
              <.slot_row milestone={@m} />
        """)

      after_src =
        apply_refactor(@subject, slot_component("<span>{@milestone}{render_slot(@back)}</span>"),
          enabled: true,
          prepared: built
        )

      assert after_src =~ "slot :back\n"
      refute after_src =~ "slot :back, required: true"
    end

    test "a slot a caller fills but the body never renders is still declared" do
      built = index(~S|      <.slot_row milestone={@m}><:footer>x</:footer></.slot_row>|)

      after_src =
        apply_refactor(@subject, slot_component("<span>{@milestone}</span>"),
          enabled: true,
          prepared: built
        )

      assert after_src =~ "slot :footer, required: true"
    end

    test "a slot entry does not count as inner_block content" do
      built = index(~S|      <.slot_row milestone={@m}><:back>go</:back></.slot_row>|)

      after_src =
        apply_refactor(
          @subject,
          slot_component("<span>{@milestone}{render_slot(@inner_block)}</span>"),
          enabled: true,
          prepared: built
        )

      assert after_src =~ "slot :inner_block\n"
      refute after_src =~ "slot :inner_block, required: true"
    end

    test "HEEx directives are never declared" do
      built = index(~S|      <.slot_row :if={@show} :let={row} milestone={@m} />|)

      after_src =
        apply_refactor(@subject, slot_component("<span>{@milestone}</span>"),
          enabled: true,
          prepared: built
        )

      refute after_src =~ "::if"
      refute after_src =~ "::let"
      assert after_src =~ "attr :milestone, :any, required: true"
    end

    test "an unreferenced component keeps the body-only contract" do
      built = index(~S|      <.something_else x={@x} />|)

      after_src =
        apply_refactor(@subject, slot_component("<span>{@milestone}</span>"),
          enabled: true,
          prepared: built
        )

      assert after_src =~ "attr :milestone, :any, required: true"
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(
        @subject,
        ~S'''
        defmodule MyView do
          def greeting(assigns) do
            ~H"""
            <p>Hello {@name}, you are {@role}.</p>
            """
          end
        end
        ''',
        @enabled
      )
    end
  end
end
