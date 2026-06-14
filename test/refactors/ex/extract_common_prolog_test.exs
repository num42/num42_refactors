defmodule Number42.Refactors.Ex.ExtractCommonPrologTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractCommonProlog

  @subject ExtractCommonProlog

  describe "rewrites — shared prolog lifted into a tuple-returning helper" do
    test "two functions, two live bindings -> tuple return" do
      before_source = """
      defmodule M do
        def handle_event("save", params, socket) do
          socket = assign(socket, :loading, true)
          socket = assign(socket, :error, nil)
          current_user = socket.assigns.current_user
          finish(socket, save(params, current_user))
        end

        def handle_event("delete", params, socket) do
          socket = assign(socket, :loading, true)
          socket = assign(socket, :error, nil)
          current_user = socket.assigns.current_user
          finish(socket, delete(params, current_user))
        end
      end
      """

      # Both call sites destructure the same sorted tuple; the prolog runs
      # once inside the helper, in order, and returns the live bindings.
      after_source = """
      defmodule M do
        def handle_event("save", params, socket) do
          {current_user, socket} = prepare_handle_event(socket)
          finish(socket, save(params, current_user))
        end

        def handle_event("delete", params, socket) do
          {current_user, socket} = prepare_handle_event(socket)
          finish(socket, delete(params, current_user))
        end

        defp prepare_handle_event(socket) do
          socket = assign(socket, :loading, true)
          socket = assign(socket, :error, nil)
          current_user = socket.assigns.current_user
          {current_user, socket}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "single live binding -> bare (no tuple) return and bind" do
      before_source = """
      defmodule M do
        def a(conn) do
          conn = step(conn, 1)
          conn = authorize(conn)
          render_a(conn)
        end

        def b(conn) do
          conn = step(conn, 1)
          conn = authorize(conn)
          render_b(conn)
        end
      end
      """

      after_source = """
      defmodule M do
        def a(conn) do
          conn = prepare_common_prolog(conn)
          render_a(conn)
        end

        def b(conn) do
          conn = prepare_common_prolog(conn)
          render_b(conn)
        end

        defp prepare_common_prolog(conn) do
          conn = step(conn, 1)
          conn = authorize(conn)
          conn
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "binding live in only one caller is still returned; both destructure uniformly" do
      before_source = """
      defmodule M do
        def first(socket) do
          socket = touch(socket)
          user = owner(socket)
          render(socket, user)
        end

        def second(socket) do
          socket = touch(socket)
          user = owner(socket)
          render(socket)
        end
      end
      """

      # `user` is read only by `first`, but both sites destructure the
      # same `{socket, user}` tuple — the helper stays monomorphic.
      after_source = """
      defmodule M do
        def first(socket) do
          {socket, user} = prepare_common_prolog(socket)
          render(socket, user)
        end

        def second(socket) do
          {socket, user} = prepare_common_prolog(socket)
          render(socket)
        end

        defp prepare_common_prolog(socket) do
          socket = touch(socket)
          user = owner(socket)
          {socket, user}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "assert_compiles — rewritten output is real, compilable Elixir" do
    # Self-contained module: prolog uses Map, tails use Kernel ops, so the
    # rewritten source compiles with no undefined references.
    test "two functions with a two-statement prolog, tuple return" do
      before_source = """
      defmodule M do
        def a(state) do
          state = Map.put(state, :loading, true)
          count = map_size(state)
          {:a, state, count}
        end

        def b(state) do
          state = Map.put(state, :loading, true)
          count = map_size(state)
          {:b, state, count}
        end
      end
      """

      rewritten = apply_refactor(@subject, before_source)

      assert rewritten =~ "defp prepare_common_prolog(state)"
      assert rewritten =~ "{count, state} = prepare_common_prolog(state)"
      assert_compiles(rewritten)
    end

    test "three functions share the prolog -> one helper, three call sites" do
      before_source = """
      defmodule M do
        def a(state) do
          state = Map.put(state, :loading, true)
          count = map_size(state)
          {:a, state, count}
        end

        def b(state) do
          state = Map.put(state, :loading, true)
          count = map_size(state)
          {:b, state, count}
        end

        def c(state) do
          state = Map.put(state, :loading, true)
          count = map_size(state)
          {:c, state, count}
        end
      end
      """

      rewritten = apply_refactor(@subject, before_source)

      assert rewritten =~ "defp prepare_common_prolog(state)"
      assert rewritten |> String.split("prepare_common_prolog(state)") |> length() == 5
      assert_compiles(rewritten)
    end

    test "single live binding -> bare bind compiles" do
      before_source = """
      defmodule M do
        def a(state) do
          state = Map.put(state, :loading, true)
          state = Map.put(state, :error, nil)
          {:a, state}
        end

        def b(state) do
          state = Map.put(state, :loading, true)
          state = Map.put(state, :error, nil)
          {:b, state}
        end
      end
      """

      rewritten = apply_refactor(@subject, before_source)

      assert rewritten =~ "state = prepare_common_prolog(state)"
      assert_compiles(rewritten)
    end
  end

  describe "leaves alone" do
    test "a prolog appearing in only one function" do
      source = """
      defmodule M do
        def only(socket) do
          socket = assign(socket, :loading, true)
          user = owner(socket)
          render(socket, user)
        end

        def other(socket) do
          render(socket)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "prologs that diverge in a literal (parametric clone)" do
      source = """
      defmodule M do
        def a(socket) do
          socket = assign(socket, :loading, true)
          user = owner(socket)
          do_a(socket, user)
        end

        def b(socket) do
          socket = assign(socket, :loading, :spinner)
          user = owner(socket)
          do_b(socket, user)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "prolog shorter than the minimum statement floor" do
      source = """
      defmodule M do
        def a(socket) do
          socket = assign(socket, :loading, true)
          do_a(socket)
        end

        def b(socket) do
          socket = assign(socket, :loading, true)
          do_b(socket)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "prolog with no live binding (pure side-effect run)" do
      source = """
      defmodule M do
        def a(socket) do
          log(socket)
          track(socket)
          do_a(socket)
        end

        def b(socket) do
          log(socket)
          track(socket)
          do_b(socket)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "no divergent tail — whole body is the prolog (full-body clone)" do
      source = """
      defmodule M do
        def a(socket) do
          socket = assign(socket, :loading, true)
          socket = authorize(socket)
        end

        def b(socket) do
          socket = assign(socket, :loading, true)
          socket = authorize(socket)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "control flow in the prolog" do
      source = """
      defmodule M do
        def a(socket) do
          socket = assign(socket, :loading, true)
          socket = if connected?(socket), do: track(socket), else: socket
          do_a(socket)
        end

        def b(socket) do
          socket = assign(socket, :loading, true)
          socket = if connected?(socket), do: track(socket), else: socket
          do_b(socket)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "prolog needs an input not a bare parameter everywhere" do
      source = """
      defmodule M do
        def a(socket) do
          socket = assign(socket, :user, user)
          socket = touch(socket)
          do_a(socket)
        end

        def b(socket) do
          socket = assign(socket, :user, user)
          socket = touch(socket)
          do_b(socket)
        end
      end
      """

      # `user` is free in the prolog but is not a parameter of either
      # function, so it can't be threaded in as a helper argument.
      assert_unchanged(@subject, source)
    end

    test "shared prolog split by an unrelated definition (non-contiguous)" do
      source = """
      defmodule M do
        def a(socket) do
          socket = assign(socket, :loading, true)
          user = owner(socket)
          do_a(socket, user)
        end

        def interlude(x) do
          x + 1
        end

        def b(socket) do
          socket = assign(socket, :loading, true)
          user = owner(socket)
          do_b(socket, user)
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "clause-group safety — helper placed after the whole clause family" do
    # A multi-clause function whose prolog-sharing clauses sit in the
    # MIDDLE of the family. The helper must land after the LAST clause of
    # the family, not between the consuming clauses and the later ones —
    # otherwise the clause group is split and the compiler warns
    # "clauses with the same name and arity should be grouped together".
    test "helper goes after the last same-name/arity clause, not mid-family" do
      before_source = """
      defmodule M do
        defp parse(:a, map) do
          left = Map.get(map, :left)
          right = Map.get(map, :right)
          {:a, left, right}
        end

        defp parse(:b, map) do
          left = Map.get(map, :left)
          right = Map.get(map, :right)
          {:b, left, right}
        end

        defp parse(:c, map) do
          left = Map.get(map, :left)
          right = Map.get(map, :right)
          {:c, left, right}
        end

        defp parse(:later, map) do
          {:later, map}
        end

        defp parse(:last, map) do
          {:last, map}
        end
      end
      """

      rewritten = apply_refactor(@subject, before_source)

      assert rewritten =~ "defp prepare_parse(map)"

      {helper_pos, _} = :binary.match(rewritten, "defp prepare_parse(map)")
      {last_clause_pos, _} = :binary.match(rewritten, "defp parse(:last, map)")

      assert helper_pos > last_clause_pos, """
      Helper was spliced before the end of the clause family — the
      `parse/2` clause group is split.

      --- rewritten ---
      #{rewritten}
      """

      # No `parse/2` clause header may follow the helper header.
      after_helper = String.split(rewritten, "defp prepare_parse(map)") |> List.last()

      refute after_helper =~ "defp parse(",
             """
             A `parse/2` clause follows the helper — clause family is split.

             --- rewritten ---
             #{rewritten}
             """

      assert_compiles(rewritten)
    end

    # Sanity: when the prolog-sharing clauses ARE the tail of the family
    # (no later same-name/arity clauses), the helper sits directly after
    # them — the original, idempotent behaviour is preserved.
    test "helper stays directly after the group when it is the family tail" do
      before_source = """
      defmodule M do
        defp parse(:early, map) do
          {:early, map}
        end

        defp parse(:a, map) do
          left = Map.get(map, :left)
          right = Map.get(map, :right)
          {:a, left, right}
        end

        defp parse(:b, map) do
          left = Map.get(map, :left)
          right = Map.get(map, :right)
          {:b, left, right}
        end
      end
      """

      rewritten = apply_refactor(@subject, before_source)

      assert rewritten =~ "defp prepare_parse(map)"

      after_helper = String.split(rewritten, "defp prepare_parse(map)") |> List.last()
      refute after_helper =~ "defp parse("

      assert_compiles(rewritten)
    end
  end

  describe "idempotence" do
    test "second pass over rewritten output is a no-op" do
      source = """
      defmodule M do
        def handle_event("save", params, socket) do
          socket = assign(socket, :loading, true)
          socket = assign(socket, :error, nil)
          current_user = socket.assigns.current_user
          finish(socket, save(params, current_user))
        end

        def handle_event("delete", params, socket) do
          socket = assign(socket, :loading, true)
          socket = assign(socket, :error, nil)
          current_user = socket.assigns.current_user
          finish(socket, delete(params, current_user))
        end
      end
      """

      assert_idempotent(@subject, source)
    end
  end
end
