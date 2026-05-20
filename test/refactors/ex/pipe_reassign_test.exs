defmodule Number42.Refactors.Ex.PipeReassignTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.PipeReassign

  @subject PipeReassign

  describe "rewrites" do
    test "x = f(x, ...) becomes x = x |> f(...)" do
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          def bump(assigns, visible) do
            assigns = assign(assigns, :delete_visible, visible)
            assigns
          end
        end
        """,
        """
        defmodule Foo do
          def bump(assigns, visible) do
            assigns = assigns |> assign(:delete_visible, visible)
            assigns
          end
        end
        """
      )
    end

    test "module-qualified call: socket = Phoenix.LiveView.assign(socket, :k, v)" do
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          def f(socket) do
            socket = Phoenix.LiveView.assign(socket, :k, :v)
            socket
          end
        end
        """,
        """
        defmodule Foo do
          def f(socket) do
            socket = socket |> Phoenix.LiveView.assign(:k, :v)
            socket
          end
        end
        """
      )
    end

    test "value `nil` does not produce an extra `)` (Sourceror range quirk)" do
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          def f(socket) do
            socket = assign(socket, :literal_editing_path, nil)
            socket
          end
        end
        """,
        """
        defmodule Foo do
          def f(socket) do
            socket = socket |> assign(:literal_editing_path, nil)
            socket
          end
        end
        """
      )
    end

    test "value `true`/`false` does not produce an extra `)`" do
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          def f(s) do
            s = assign(s, :open?, true)
            s = assign(s, :closed?, false)
            s
          end
        end
        """,
        """
        defmodule Foo do
          def f(s) do
            s = s |> assign(:open?, true)
            s = s |> assign(:closed?, false)
            s
          end
        end
        """
      )
    end

    test "preserves operator-shape arg with `||` / `&&`" do
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          def f(socket, default) do
            socket = assign(socket, :flag, socket.assigns[:flag] || default)
            socket
          end
        end
        """,
        """
        defmodule Foo do
          def f(socket, default) do
            socket = socket |> assign(:flag, socket.assigns[:flag] || default)
            socket
          end
        end
        """
      )
    end

    test "preserves operator-shape arg with `not in` (Sourceror range quirk)" do
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          def f(assigns) do
            assigns = assign(assigns, :has_value, assigns.value_type not in [nil, "", "nil"])
            assigns
          end
        end
        """,
        """
        defmodule Foo do
          def f(assigns) do
            assigns = assigns |> assign(:has_value, assigns.value_type not in [nil, "", "nil"])
            assigns
          end
        end
        """
      )
    end

    test "rewrites every match in a function body" do
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          def f(state) do
            state = Map.put(state, :a, 1)
            state = Map.put(state, :b, 2)
            state
          end
        end
        """,
        """
        defmodule Foo do
          def f(state) do
            state = state |> Map.put(:a, 1)
            state = state |> Map.put(:b, 2)
            state
          end
        end
        """
      )
    end
  end

  describe "leaves alone" do
    test "single-arg calls (style preference, ambiguous gain)" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(x) do
          x = identity(x)
          x
        end
      end
      """)
    end

    test "first arg is not the LHS variable" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(a, b) do
          a = update(b, :k, :v)
          a
        end
      end
      """)
    end

    test "first arg is a literal/expression, not a bare var" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f do
          m = Map.put(%{}, :k, :v)
          m
        end
      end
      """)
    end

    test "LHS is a pattern (not a bare var)" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(x) do
          {:ok, x} = wrap(x, :k)
          x
        end
      end
      """)
    end

    test "RHS is already a pipe" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(x) do
          x = x |> assign(:k, :v)
          x
        end
      end
      """)
    end

    test "RHS is a kernel operator (=, +, etc.)" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(x) do
          x = x + 1
          x
        end
      end
      """)
    end

    test "RHS is a `case` special form (do/end, not parens)" do
      # `case organization_id do ... end` parses as
      # `{:case, _, [organization_id, [do: ...]]}` — same shape as a
      # 2-arg call with `organization_id` first, but rewriting it to
      # `organization_id |> case(do nil -> ...)` produces invalid
      # syntax (the closing `end` gets sliced at the wrong byte
      # offset, leaking `en)` into the output). Special forms with
      # `do/end` must be left alone.
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(organization_id) do
          organization_id = case organization_id do
            nil -> insert(:organization).id
            _ -> organization_id
          end

          organization_id
        end
      end
      """)
    end

    test "RHS is an `if` special form" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(x) do
          x = if x, do: x, else: :default
          x
        end
      end
      """)
    end

    test "RHS is a `with` special form" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(x) do
          x = with {:ok, y} <- fetch(x), do: y
          x
        end
      end
      """)
    end

    test "RHS is a `cond` special form" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(x) do
          x = cond do
            x > 0 -> x
            true -> 0
          end

          x
        end
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      defmodule Foo do
        def f(assigns, v) do
          assigns = assign(assigns, :k, v)
          assigns
        end
      end
      """)
    end
  end
end
