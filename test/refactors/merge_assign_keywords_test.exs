defmodule Num42.Refactors.Refactors.MergeAssignKeywordsTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.MergeAssignKeywords

  @subject MergeAssignKeywords

  describe "rewrites" do
    test "merges two consecutive assign/3 calls" do
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          def f(assigns, a, b) do
            assigns = assigns |> assign(:a, a)
            assigns = assigns |> assign(:b, b)
            assigns
          end
        end
        """,
        """
        defmodule Foo do
          def f(assigns, a, b) do
            assigns = assigns |> assign(a: a, b: b)
            assigns
          end
        end
        """
      )
    end

    test "merges three consecutive assign/3 calls" do
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          def f(s, a, b, c) do
            s = s |> assign(:a, a)
            s = s |> assign(:b, b)
            s = s |> assign(:c, c)
            s
          end
        end
        """,
        """
        defmodule Foo do
          def f(s, a, b, c) do
            s = s |> assign(a: a, b: b, c: c)
            s
          end
        end
        """
      )
    end

    test "merges consecutive assign steps inside a single pipe chain" do
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          def f(assigns, fb) do
            assigns
            |> assign(:masses, fb.masses)
            |> assign(:params, fb.params)
            |> assign(:options, fb.options)
          end
        end
        """,
        """
        defmodule Foo do
          def f(assigns, fb) do
            assigns
            |> assign(masses: fb.masses, params: fb.params, options: fb.options)
          end
        end
        """
      )
    end

    test "merges only the consecutive assign run inside a longer pipe" do
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          def f(assigns, fb) do
            assigns
            |> assign(:masses, fb.masses)
            |> assign(:params, fb.params)
            |> Map.put(:meta, :extra)
            |> assign(:options, fb.options)
          end
        end
        """,
        """
        defmodule Foo do
          def f(assigns, fb) do
            assigns
            |> assign(masses: fb.masses, params: fb.params)
            |> Map.put(:meta, :extra)
            |> assign(:options, fb.options)
          end
        end
        """
      )
    end

    test "pipe chain inside a tuple (no leading `lhs =`)" do
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          def f(socket, fb) do
            {:ok,
             socket
             |> assign(:total_count, 0)
             |> assign(:all_rows, [])}
          end
        end
        """,
        """
        defmodule Foo do
          def f(socket, fb) do
            {:ok,
             socket
             |> assign(total_count: 0, all_rows: [])}
          end
        end
        """
      )
    end

    test "pipe chain inside an anonymous fn body" do
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          def f do
            fn s ->
              s
              |> assign(:a, 1)
              |> assign(:b, 2)
            end
          end
        end
        """,
        """
        defmodule Foo do
          def f do
            fn s ->
              s
              |> assign(a: 1, b: 2)
            end
          end
        end
        """
      )
    end

    test "pipe ending in `then(fn ... end)` does not chew the next defp" do
      # Sourceror's range on the outermost `|>` over-shoots when the
      # last step is `then(fn ... end)` — the range extends past the
      # closing `)` and into the following `\n  defp ...` line. This
      # repros that exact shape: a chain ending in `then`, immediately
      # followed by another `defp`.
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          defp first(socket) do
            socket
            |> assign(:a, 1)
            |> assign(:b, 2)
            |> then(fn s ->
              s
            end)
          end

          defp second(_), do: :ok
        end
        """,
        """
        defmodule Foo do
          defp first(socket) do
            socket
            |> assign(a: 1, b: 2)
            |> then(fn s ->
              s
            end)
          end

          defp second(_), do: :ok
        end
        """
      )
    end

    test "last step's value is an operator expression — closing `)` preserved" do
      # Sourceror's `get_range(step)` on a pipe step `|> assign(:k, x || y)`
      # ends at the right operand, NOT at the call's `)`. Without the
      # `:closing` meta fallback, the patch end falls one column short
      # and the original `)` survives → `false))}`. This exact shape was
      # observed in `item_picker_component.ex` after `mix refactor -yt`.
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          def f(socket, assigns) do
            {:ok,
             socket
             |> assign(:a, 1)
             |> assign(:open, assigns[:open] || false)}
          end
        end
        """,
        """
        defmodule Foo do
          def f(socket, assigns) do
            {:ok,
             socket
             |> assign(a: 1, open: assigns[:open] || false)}
          end
        end
        """
      )
    end

    test "remote-qualified assign (Phoenix.Component.assign)" do
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          def f(socket, x, y) do
            socket = socket |> Phoenix.Component.assign(:x, x)
            socket = socket |> Phoenix.Component.assign(:y, y)
            socket
          end
        end
        """,
        """
        defmodule Foo do
          def f(socket, x, y) do
            socket = socket |> Phoenix.Component.assign(x: x, y: y)
            socket
          end
        end
        """
      )
    end

    # If the module imports `Phoenix.Component, only: [assign: 3]`,
    # merging two `|> assign(:k, v)` steps into a single
    # `|> assign(k: v, ...)` (which is `assign/2`) leaves `assign/2`
    # un-imported — the file no longer compiles. The refactor must
    # widen the `:only` list to include `assign: 2` whenever it emits
    # a merge in such a module. Real-world repro:
    # `lib/my_app_web/live/price_list_live/price_list_data.ex`.
    test "widens `only: [assign: 3]` import when merging assign/3 to assign/2" do
      assert_rewrites(
        @subject,
        """
        defmodule Foo do
          import Phoenix.Component, only: [assign: 3]

          def f(socket, a, b) do
            socket
            |> assign(:a, a)
            |> assign(:b, b)
          end
        end
        """,
        """
        defmodule Foo do
          import Phoenix.Component, only: [assign: 2, assign: 3]

          def f(socket, a, b) do
            socket
            |> assign(a: a, b: b)
          end
        end
        """
      )
    end
  end

  describe "leaves alone" do
    test "single assign — nothing to merge" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(assigns, a) do
          assigns = assigns |> assign(:a, a)
          assigns
        end
      end
      """)
    end

    test "different LHS variables break the sequence" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(a, b) do
          a = a |> assign(:k, 1)
          b = b |> assign(:k, 2)
          {a, b}
        end
      end
      """)
    end

    test "non-adjacent statements (anything between)" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(assigns, a, b) do
          assigns = assigns |> assign(:a, a)
          IO.inspect(:between)
          assigns = assigns |> assign(:b, b)
          assigns
        end
      end
      """)
    end

    test "non-atom-literal key" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(assigns, key, a, b) do
          assigns = assigns |> assign(key, a)
          assigns = assigns |> assign(:b, b)
          assigns
        end
      end
      """)
    end

    test "already-merged keyword form" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(assigns, a, b) do
          assigns = assigns |> assign(a: a, b: b)
          assigns
        end
      end
      """)
    end

    test "non-pipe rhs (bare call)" do
      # Out of scope — PipeReassign covers turning `x = f(x, ...)` into a
      # pipe; merging only fires once the pipe form is in place.
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(assigns, a, b) do
          assigns = assign(assigns, :a, a)
          assigns = assign(assigns, :b, b)
          assigns
        end
      end
      """)
    end

    test "single assign inside a pipe — nothing to merge" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(assigns, fb) do
          assigns
          |> assign(:masses, fb.masses)
          |> Map.put(:meta, :extra)
        end
      end
      """)
    end

    test "different function name (assign_new) breaks the sequence" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def f(assigns, a, b) do
          assigns = assigns |> assign(:a, a)
          assigns = assigns |> assign_new(:b, fn -> b end)
          assigns
        end
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      defmodule Foo do
        def f(assigns, a, b) do
          assigns = assigns |> assign(:a, a)
          assigns = assigns |> assign(:b, b)
          assigns
        end
      end
      """)
    end

    test "running twice on the pipe-chain form equals running once" do
      assert_idempotent(@subject, """
      defmodule Foo do
        def f(assigns, fb) do
          assigns
          |> assign(:masses, fb.masses)
          |> assign(:params, fb.params)
        end
      end
      """)
    end
  end
end
