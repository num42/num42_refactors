defmodule Number42.Refactors.Ex.ExtractSocketToPipeTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractSocketToPipe

  @subject ExtractSocketToPipe

  describe "rewrites — local calls" do
    test "assign(socket, :k, v) becomes socket |> assign(:k, v)" do
      assert_rewrites(
        @subject,
        "assign(socket, :k, v)",
        "socket |> assign(:k, v)"
      )
    end

    test "single-arg foo(socket) becomes socket |> foo()" do
      assert_rewrites(
        @subject,
        "foo(socket)",
        "socket |> foo()"
      )
    end

    test "two-arg local call" do
      assert_rewrites(
        @subject,
        "put_flash(socket, :info)",
        "socket |> put_flash(:info)"
      )
    end
  end

  describe "rewrites — remote calls" do
    test "Phoenix.LiveView.assign(socket, ...) becomes socket |> Phoenix.LiveView.assign(...)" do
      assert_rewrites(
        @subject,
        "Phoenix.LiveView.assign(socket, :k, v)",
        "socket |> Phoenix.LiveView.assign(:k, v)"
      )
    end

    test "single-segment remote call" do
      assert_rewrites(
        @subject,
        "Foo.bar(socket, opt)",
        "socket |> Foo.bar(opt)"
      )
    end
  end

  describe "rewrites — inside larger expressions" do
    test "call as function argument is rewritten" do
      assert_rewrites(
        @subject,
        "wrap(assign(socket, :k, v))",
        "wrap(socket |> assign(:k, v))"
      )
    end

    test "call as RHS of `=` is rewritten" do
      assert_rewrites(
        @subject,
        "result = assign(socket, :k, v)",
        "result = socket |> assign(:k, v)"
      )
    end

    test "call inside a do-block is rewritten" do
      assert_rewrites(
        @subject,
        """
        if condition do
          assign(socket, :k, v)
        end
        """,
        """
        if condition do
          socket |> assign(:k, v)
        end
        """
      )
    end
  end

  describe "leaves alone — first arg is not the bare `socket` variable" do
    test "first arg is a different variable" do
      assert_unchanged(@subject, "assign(conn, :k, v)")
    end

    test "first arg is a field access on socket (socket.assigns)" do
      assert_unchanged(@subject, "assign(socket.assigns, :k, v)")
    end

    test "first arg is a literal" do
      assert_unchanged(@subject, "assign(%{}, :k, v)")
    end

    test "zero-arg call has no first arg" do
      assert_unchanged(@subject, "current_socket()")
    end
  end

  describe "leaves alone — already piped" do
    test "socket |> assign(:k, v) stays put" do
      assert_unchanged(@subject, "socket |> assign(:k, v)")
    end

    test "multi-stage pipe with socket call stays put" do
      assert_unchanged(@subject, "socket |> assign(:k, v) |> put_flash(:info)")
    end
  end

  describe "leaves alone — pipe-unsafe positions" do
    test "call as ++ operand stays put" do
      assert_unchanged(@subject, "x ++ collect(socket, opts)")
    end

    test "call as comparison operand stays put" do
      assert_unchanged(@subject, "count_assigns(socket) > 0")
    end

    test "call as boolean operand stays put" do
      assert_unchanged(@subject, "ready?(socket) and other")
    end

    test "call as <> operand stays put" do
      assert_unchanged(@subject, "prefix <> render(socket, opts)")
    end
  end

  describe "leaves alone — &-capture and ^-pin" do
    test "call inside &-capture stays put" do
      # Rewriting `&assign(socket, :k, v)` to `& socket |> assign(:k, v)`
      # breaks under the `&`-capture lexer rules — same hazard as
      # ExtractToPipeline.
      assert_unchanged(@subject, "&assign(socket, :k, v)")
    end

    test "call inside ^-pin stays put" do
      assert_unchanged(@subject, "where(q, [t], t.id in ^assign(socket, :k, v))")
    end
  end

  describe "edge cases" do
    test "function name `socket` is left alone (would shadow the variable)" do
      # `socket(socket, opts)` rewriting to `socket |> socket(opts)` is
      # technically valid Elixir but exotic and confusing. Leave it.
      assert_unchanged(@subject, "socket(socket, opts)")
    end

    test "function definition heads are not calls" do
      # `defp foo(socket, x), do: body` parses with the head
      # `{:foo, _, [socket_var, x_var]}` — same shape as a 2-arg local
      # call. Rewriting it produces `defp socket |> foo(x), do: ...`
      # which is invalid syntax. The body's calls (if any) MAY be
      # rewritten — only the head is off-limits.
      assert_unchanged(@subject, """
      defmodule M do
        defp mount_current_scope(socket, session) do
          do_mount(session)
        end
      end
      """)
    end

    test "function definition head with body that contains a socket call" do
      # The head `{:do_thing, _, [socket_var, opts_var]}` is a
      # definition, not a call. Rewriting the head is illegal; the
      # body's call to `assign(socket, ...)` is fair game.
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def do_thing(socket, opts) do
            assign(socket, :k, opts[:v])
          end
        end
        """,
        """
        defmodule M do
          def do_thing(socket, opts) do
            socket |> assign(:k, opts[:v])
          end
        end
        """
      )
    end

    test "def with single socket arg is not rewritten" do
      assert_unchanged(@subject, """
      defmodule M do
        def render(socket), do: socket
      end
      """)
    end

    test "def with rescue clause: head untouched, rescue body walked" do
      # `def foo(socket, x) do ... rescue ... end` parses as
      # `{:def, _, [head, [do: ..., rescue: ...]]}` — the body is a
      # keyword list with multiple clauses, not a single do-block.
      # The head must not be rewritten; calls inside any clause are
      # fair game.
      assert_unchanged(@subject, ~S'''
      defmodule M do
        defp safe_cancel_async(socket, name) do
          something(name)
        rescue
          _ -> socket
        end
      end
      ''')
    end

    test "match operator `socket = expr` is not a function call" do
      # The `=` in `socket = assign(socket, ...)` parses as
      # `{:=, _, [socket_var, rhs]}` — same shape as a 2-arg local call
      # at the AST level, but `=` is an operator, not a function.
      # The OUTER `=` must not be rewritten (`socket |> =(...)` is
      # invalid syntax). The INNER `assign(socket, ...)` is on the RHS
      # of `=`, which is pipe-safe, so it IS rewritten.
      assert_rewrites(
        @subject,
        "socket = assign(socket, :k, v)",
        "socket = socket |> assign(:k, v)"
      )
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "assign(socket, :k, v)")
    end
  end
end
