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
