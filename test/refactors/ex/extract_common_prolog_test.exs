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

    test "binding live in only one caller is still returned; the unread site underscores it" do
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

      # `user` is read only by `first`, so the helper still returns the
      # same `{socket, user}` tuple (monomorphic), but `second` — which
      # never reads `user` in its tail — binds it as `_user` so it is not
      # an unused variable under `--warnings-as-errors`.
      after_source = """
      defmodule M do
        def first(socket) do
          {socket, user} = prepare_common_prolog(socket)
          render(socket, user)
        end

        def second(socket) do
          {socket, _user} = prepare_common_prolog(socket)
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

  describe "underscores per-call-site unread bindings" do
    # The live set is the UNION over all tails, so a site that reads only
    # one of two live bindings would otherwise bind the other unused. Each
    # site underscores the tuple positions its own tail never reads, so the
    # helper stays monomorphic (same tuple shape returned) while the call
    # site compiles clean under --warnings-as-errors.
    test "site reading only one of two live bindings underscores the other" do
      before_source = """
      defmodule M do
        def handle_event("validate", params, socket) do
          combined = combine_params(params)
          changeset = build_changeset(socket, combined)
          render(changeset)
        end

        def handle_event("save", params, socket) do
          combined = combine_params(params)
          changeset = build_changeset(socket, combined)
          persist(changeset, combined)
        end
      end
      """

      after_source = """
      defmodule M do
        def handle_event("validate", params, socket) do
          {changeset, _combined} = prepare_handle_event(params, socket)
          render(changeset)
        end

        def handle_event("save", params, socket) do
          {changeset, combined} = prepare_handle_event(params, socket)
          persist(changeset, combined)
        end

        defp prepare_handle_event(params, socket) do
          combined = combine_params(params)
          changeset = build_changeset(socket, combined)
          {changeset, combined}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "per-site underscored output compiles clean (no unused-variable)" do
      before_source = """
      defmodule M do
        def a(state) do
          combined = Map.put(state, :a, 1)
          count = map_size(combined)
          {:a, count}
        end

        def b(state) do
          combined = Map.put(state, :a, 1)
          count = map_size(combined)
          {:b, count, combined}
        end
      end
      """

      rewritten = apply_refactor(@subject, before_source)

      # `a`'s tail reads only `count`; `combined` is underscored there.
      assert rewritten =~ "{_combined, count} = prepare_common_prolog(state)"
      # `b`'s tail reads both, so neither position is underscored.
      assert rewritten =~ "{combined, count} = prepare_common_prolog(state)"
      assert_compiles(rewritten)
    end

    test "single bare live binding underscored at a site that does not read it" do
      # `b` reads `state` again in its tail; `a` does not, so `a` binds
      # `_state` to avoid an unused variable on the bare (non-tuple) return.
      before_source = """
      defmodule M do
        def a(state) do
          state = Map.put(state, :loading, true)
          state = Map.put(state, :error, nil)
          {:a, :done}
        end

        def b(state) do
          state = Map.put(state, :loading, true)
          state = Map.put(state, :error, nil)
          {:b, state}
        end
      end
      """

      rewritten = apply_refactor(@subject, before_source)

      assert rewritten =~ "_state = prepare_common_prolog(state)"
      assert rewritten =~ "\n      state = prepare_common_prolog(state)"
      assert_compiles(rewritten)
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

  describe "near-match — one clause carries an extra boundary getter" do
    # Slice 1: the extra is a PURE field-access chain over a helper param
    # (`socket.assigns.current_user`). `pure?/1` rejects the dotted chain
    # (its root is a dot-call, not an `__aliases__`), so a dedicated
    # `field_access_over_param?` predicate accepts it. Pure reads stay
    # EAGER in the return tuple — no thunk. The non-needing clause
    # underscores the eager slot.
    test "extra pure field-access read -> eager extra slot, non-bearer underscores it" do
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
          finish(socket, delete(socket))
        end
      end
      """

      after_source = """
      defmodule M do
        def handle_event("save", params, socket) do
          {current_user, socket} = prepare_handle_event(socket)
          finish(socket, save(params, current_user))
        end

        def handle_event("delete", params, socket) do
          {_current_user, socket} = prepare_handle_event(socket)
          finish(socket, delete(socket))
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

    # Slice 2: the extra is a side-effect-possible getter (`Repo.get/2`).
    # It must NOT run for the non-needing clause, so it is wrapped in a
    # thunk (`fn -> ... end`) and forced (`u = u_fun.()`) only at the
    # bearer. The non-bearer underscores the thunk slot and never forces.
    test "extra DB getter -> lazy thunk slot, bearer forces, non-bearer underscores" do
      before_source = """
      defmodule M do
        def handle_event("save", params, socket) do
          socket = assign(socket, :loading, true)
          socket = assign(socket, :error, nil)
          user = Repo.get(User, socket.assigns.id)
          finish(socket, save(params, user))
        end

        def handle_event("delete", params, socket) do
          socket = assign(socket, :loading, true)
          socket = assign(socket, :error, nil)
          finish(socket, delete(socket))
        end
      end
      """

      after_source = """
      defmodule M do
        def handle_event("save", params, socket) do
          {socket, user_fun} = prepare_handle_event(socket)
          user = user_fun.()
          finish(socket, save(params, user))
        end

        def handle_event("delete", params, socket) do
          {socket, _user_fun} = prepare_handle_event(socket)
          finish(socket, delete(socket))
        end

        defp prepare_handle_event(socket) do
          socket = assign(socket, :loading, true)
          socket = assign(socket, :error, nil)
          {socket, fn -> Repo.get(User, socket.assigns.id) end}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    # Slice 2 again, with a LOCAL getter (`get_user/1`) instead of a
    # remote one — also side-effect-possible, also lazy.
    test "extra local getter -> lazy thunk slot" do
      before_source = """
      defmodule M do
        def a(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          user = get_user(ctx)
          render_a(ctx, user)
        end

        def b(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          render_b(ctx)
        end
      end
      """

      after_source = """
      defmodule M do
        def a(ctx) do
          {ctx, user_fun} = prepare_common_prolog(ctx)
          user = user_fun.()
          render_a(ctx, user)
        end

        def b(ctx) do
          {ctx, _user_fun} = prepare_common_prolog(ctx)
          render_b(ctx)
        end

        defp prepare_common_prolog(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          {ctx, fn -> get_user(ctx) end}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    # Slice 3: ≥ 3 functions where only one carries the extra; the other
    # two share the plain prolog. The lazy thunk slot coexists with the
    # eager live binding (`ctx`).
    test "three functions, only one carries the lazy extra getter" do
      before_source = """
      defmodule M do
        def a(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          user = get_user(ctx)
          render_a(ctx, user)
        end

        def b(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          render_b(ctx)
        end

        def c(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          render_c(ctx)
        end
      end
      """

      after_source = """
      defmodule M do
        def a(ctx) do
          {ctx, user_fun} = prepare_common_prolog(ctx)
          user = user_fun.()
          render_a(ctx, user)
        end

        def b(ctx) do
          {ctx, _user_fun} = prepare_common_prolog(ctx)
          render_b(ctx)
        end

        def c(ctx) do
          {ctx, _user_fun} = prepare_common_prolog(ctx)
          render_c(ctx)
        end

        defp prepare_common_prolog(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          {ctx, fn -> get_user(ctx) end}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "near-match — compiles, lazy slot is real, idempotent" do
    test "lazy thunk output compiles clean under warnings-as-errors" do
      before_source = """
      defmodule M do
        def a(state) do
          state = Map.put(state, :loading, true)
          state = Map.put(state, :error, nil)
          extra = fetch_extra(state)
          {:a, state, extra}
        end

        def b(state) do
          state = Map.put(state, :loading, true)
          state = Map.put(state, :error, nil)
          {:b, state}
        end

        defp fetch_extra(state), do: map_size(state)
      end
      """

      rewritten = apply_refactor(@subject, before_source)

      assert rewritten =~ "fn -> fetch_extra(state) end"
      assert rewritten =~ "extra = extra_fun.()"
      # Slots are sorted (`extra_fun` < `state`); the non-bearer underscores
      # the thunk slot and never forces it.
      assert rewritten =~ "{_extra_fun, state} = prepare_common_prolog(state)"
      assert_compiles(rewritten)
    end

    test "eager pure field-access output compiles clean" do
      before_source = """
      defmodule M do
        def a(state) do
          state = Map.put(state, :loading, true)
          state = Map.put(state, :error, nil)
          extra = Map.get(state, :extra)
          {:a, state, extra}
        end

        def b(state) do
          state = Map.put(state, :loading, true)
          state = Map.put(state, :error, nil)
          {:b, state}
        end
      end
      """

      rewritten = apply_refactor(@subject, before_source)

      # `Map.get/2` is pure → eager, no thunk.
      refute rewritten =~ "fn ->"
      assert rewritten =~ "extra = Map.get(state, :extra)"
      assert_compiles(rewritten)
    end

    test "near-match rewrite is idempotent (second pass is a no-op)" do
      source = """
      defmodule M do
        def a(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          user = get_user(ctx)
          render_a(ctx, user)
        end

        def b(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          render_b(ctx)
        end
      end
      """

      assert_idempotent(@subject, source)
    end
  end

  describe "near-match — falls back to exact-match (no extraction)" do
    # A mid-prolog extra CAN split the shared run (#241), but only when it
    # reads stable names. Here the getter `get_user(ctx)` reads `ctx`, which
    # the later shared statement `ctx = put(ctx, :error, nil)` rebinds.
    # Deferring the getter to the end of the helper would feed it the
    # post-prolog `ctx`, not the value it read mid-prolog — unsound. Declines.
    test "extra getter mid-prolog reading a rebound name is not deferrable" do
      source = """
      defmodule M do
        def a(ctx) do
          ctx = put(ctx, :loading, true)
          user = get_user(ctx)
          ctx = put(ctx, :error, nil)
          render_a(ctx, user)
        end

        def b(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          render_b(ctx)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    # The extra getter's value is consumed by a statement the other clauses
    # ALSO share after the boundary — so the value is needed everywhere and
    # can't be deferred to one clause. Falls back.
    test "extra getter consumed by a shared follow-up line is not deferrable" do
      source = """
      defmodule M do
        def a(ctx) do
          ctx = put(ctx, :loading, true)
          user = get_user(ctx)
          ctx = with_user(ctx, user)
          render_a(ctx)
        end

        def b(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = with_user(ctx, user)
          render_b(ctx)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    # Two clauses each carry a (different) extra statement. The near-match
    # path allows exactly one bearer; two disqualifies. Falls back to the
    # exact-match path: the shared `put;put` prolog is still extracted, and
    # each clause's extra stays inline in its own tail.
    test "two clauses carrying extras falls back to exact-match (extras stay inline)" do
      before_source = """
      defmodule M do
        def a(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          user = get_user(ctx)
          render_a(ctx, user)
        end

        def b(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          token = get_token(ctx)
          render_b(ctx, token)
        end
      end
      """

      after_source = """
      defmodule M do
        def a(ctx) do
          ctx = prepare_common_prolog(ctx)
          user = get_user(ctx)
          render_a(ctx, user)
        end

        def b(ctx) do
          ctx = prepare_common_prolog(ctx)
          token = get_token(ctx)
          render_b(ctx, token)
        end

        defp prepare_common_prolog(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          ctx
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    # The extra is a bare side-effecting call with no binding (`log(ctx)`).
    # There is no value to thread back, so the near-match path declines and
    # the exact-match path runs, leaving `log(ctx)` inline in `a`.
    test "bare side-effecting extra call (no binding) falls back to exact-match" do
      before_source = """
      defmodule M do
        def a(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          log(ctx)
          render_a(ctx)
        end

        def b(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          render_b(ctx)
        end
      end
      """

      after_source = """
      defmodule M do
        def a(ctx) do
          ctx = prepare_common_prolog(ctx)
          log(ctx)
          render_a(ctx)
        end

        def b(ctx) do
          ctx = prepare_common_prolog(ctx)
          render_b(ctx)
        end

        defp prepare_common_prolog(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          ctx
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    # The extra getter reads a var that is neither a helper param nor bound
    # by the shared prolog (`token` is a param of `a` only, the helper takes
    # only `ctx`). It can't be evaluated inside the helper, so the near-match
    # path declines and the exact-match path leaves it inline in `a`.
    test "extra getter reading a non-param, non-prolog var falls back to exact-match" do
      before_source = """
      defmodule M do
        def a(ctx, token) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          user = get_user(token)
          render_a(ctx, user)
        end

        def b(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          render_b(ctx)
        end
      end
      """

      after_source = """
      defmodule M do
        def a(ctx, token) do
          ctx = prepare_common_prolog(ctx)
          user = get_user(token)
          render_a(ctx, user)
        end

        def b(ctx) do
          ctx = prepare_common_prolog(ctx)
          render_b(ctx)
        end

        defp prepare_common_prolog(ctx) do
          ctx = put(ctx, :loading, true)
          ctx = put(ctx, :error, nil)
          ctx
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "near-match — extra splits the shared prolog (#241)" do
    # The single extra need not sit at the prolog boundary: a clause may
    # insert it in the MIDDLE of the shared run and the statements after
    # it still count toward the shared prolog. Here `b = 2` is fn1's
    # extra; the shared prolog is `a = step(x)` THEN `c = more(a)`.
    # `b` is a pure literal binding read only in fn1's tail, so it becomes
    # an EAGER slot returned by the helper; fn2 underscores it.
    test "pure literal extra splitting the prolog -> eager slot, non-bearer underscores it" do
      before_source = """
      defmodule M do
        def fn1(x) do
          a = step(x)
          b = 2
          c = more(a)
          use(a, b, c)
        end

        def fn2(x) do
          a = step(x)
          c = more(a)
          use(a, c)
        end
      end
      """

      # Shared prolog `a = step(x); c = more(a)` lifts into the helper; the
      # eager extra `b = 2` runs there too and is returned by value.
      # Slots sorted `{a, b, c}`: fn1 reads all three, fn2 underscores `b`.
      after_source = """
      defmodule M do
        def fn1(x) do
          {a, b, c} = prepare_common_prolog(x)
          use(a, b, c)
        end

        def fn2(x) do
          {a, _b, c} = prepare_common_prolog(x)
          use(a, c)
        end

        defp prepare_common_prolog(x) do
          a = step(x)
          c = more(a)
          b = 2
          {a, b, c}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "pure-literal split output compiles and is idempotent" do
      before_source = """
      defmodule M do
        def fn1(x) do
          a = Map.put(x, :a, 1)
          b = 2
          c = map_size(a)
          {:fn1, a, b, c}
        end

        def fn2(x) do
          a = Map.put(x, :a, 1)
          c = map_size(a)
          {:fn2, a, c}
        end
      end
      """

      rewritten = apply_refactor(@subject, before_source)

      assert rewritten =~ "defp prepare_common_prolog(x)"
      # The eager extra `b = 2` lands in the helper after the shared run.
      assert rewritten =~ "b = 2"
      assert rewritten =~ "{a, b, c} = prepare_common_prolog(x)"
      assert rewritten =~ "{a, _b, c} = prepare_common_prolog(x)"
      assert_compiles(rewritten)
      assert_idempotent(@subject, before_source)
    end

    # The extra is a pure ARITHMETIC binding over a shared-prolog binding
    # (`b = a + 10`, where `a` is bound by the shared prolog). `pure?/1`
    # accepts the arithmetic, so it stays eager. The shared prolog after
    # the extra (`c = more(a)`) still counts.
    test "pure arithmetic extra over a shared-prolog binding splits the prolog (eager)" do
      before_source = """
      defmodule M do
        def fn1(x) do
          a = step(x)
          b = a + 10
          c = more(a)
          use(a, b, c)
        end

        def fn2(x) do
          a = step(x)
          c = more(a)
          use(a, c)
        end
      end
      """

      after_source = """
      defmodule M do
        def fn1(x) do
          {a, b, c} = prepare_common_prolog(x)
          use(a, b, c)
        end

        def fn2(x) do
          {a, _b, c} = prepare_common_prolog(x)
          use(a, c)
        end

        defp prepare_common_prolog(x) do
          a = step(x)
          c = more(a)
          b = a + 10
          {a, b, c}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    # A side-effect-possible getter (`get_user/1`) inserted in the MIDDLE of
    # the shared prolog is LAZY (deferred behind a thunk forced only by the
    # bearer). Deferring it past a shared statement that ITSELF has a side
    # effect (`ctx = touch(ctx)`) would reorder its side effect after that
    # statement's — observable, and a violation of the "## Side-effect
    # ordering" contract. So a lazy mid-prolog extra requires every shared
    # statement after it to be `pure?`-true; here `touch(ctx)` is not, so the
    # near match declines and (the exact `base; ctx` run having a side-effect
    # tail that is also the only shared run once the bearer's extra is
    # accounted for) nothing is extracted.
    test "lazy extra split by an IMPURE shared-after statement -> declines (no extraction)" do
      source = """
      defmodule M do
        def a(ctx) do
          base = root(ctx)
          user = get_user(base)
          ctx = touch(ctx)
          render_a(ctx, user)
        end

        def b(ctx) do
          base = root(ctx)
          ctx = touch(ctx)
          render_b(ctx)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    # The mirror of the decline above: the shared statement AFTER the lazy
    # extra is PURE (`n = base + 1`), so forcing the thunk after it cannot
    # reorder one side effect past another. The lazy split is therefore
    # taken — the getter `user = get_user(base)` becomes a `*_fun` thunk slot
    # the bearer forces, while the non-bearer underscores it.
    test "lazy extra split by a PURE shared-after statement -> lazy thunk slot" do
      before_source = """
      defmodule M do
        def a(ctx) do
          base = root(ctx)
          user = get_user(base)
          n = base + 1
          render_a(n, user)
        end

        def b(ctx) do
          base = root(ctx)
          n = base + 1
          render_b(n)
        end
      end
      """

      # Shared prolog is `base = root(ctx); n = base + 1`. Live: `n` (both
      # tails). The lazy thunk captures `base` (a shared binding in scope in
      # the helper). Slots sorted `{n, user_fun}`.
      after_source = """
      defmodule M do
        def a(ctx) do
          {n, user_fun} = prepare_common_prolog(ctx)
          user = user_fun.()
          render_a(n, user)
        end

        def b(ctx) do
          {n, _user_fun} = prepare_common_prolog(ctx)
          render_b(n)
        end

        defp prepare_common_prolog(ctx) do
          base = root(ctx)
          n = base + 1
          {n, fn -> get_user(base) end}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "lazy split over a pure shared-after statement compiles and is idempotent" do
      before_source = """
      defmodule M do
        def a(ctx) do
          base = Map.get(ctx, :base)
          user = process_user(base)
          n = base + 1
          {:a, n, user}
        end

        def b(ctx) do
          base = Map.get(ctx, :base)
          n = base + 1
          {:b, n}
        end

        defp process_user(b), do: {:user, b}
      end
      """

      rewritten = apply_refactor(@subject, before_source)

      assert rewritten =~ "defp prepare_common_prolog(ctx)"
      assert rewritten =~ "{n, fn -> process_user(base) end}"
      assert rewritten =~ "{n, user_fun} = prepare_common_prolog(ctx)"
      assert rewritten =~ "{n, _user_fun} = prepare_common_prolog(ctx)"
      assert_compiles(rewritten)
      assert_idempotent(@subject, before_source)
    end

    # Two clauses each insert a (different) extra mid-prolog. The near-match
    # layer allows exactly one bearer; two disqualifies the split. There is
    # then no single leading run of `min_prolog` length they all share
    # contiguously (fn1: `a; X; c`, fn2: `a; Y; c` diverge at index 1), so
    # nothing is extracted.
    test "two bearers each splitting the prolog -> declines (no extraction)" do
      source = """
      defmodule M do
        def fn1(x) do
          a = step(x)
          b = get_user(a)
          c = more(a)
          use(a, b, c)
        end

        def fn2(x) do
          a = step(x)
          d = get_token(a)
          c = more(a)
          use(a, c, d)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    # OUT OF SCOPE (#241 tracks separately): a single statement whose
    # DESTRUCTURING PATTERN diverges between clauses. `{a, b, c} = src()`
    # vs `{a, c} = src()` is one statement with a different LHS, not an
    # inserted extra statement. The refactor must leave it untouched.
    test "destructuring-pattern divergence stays untouched" do
      source = """
      defmodule M do
        def fn1(x) do
          base = init(x)
          {a, b, c} = src(base)
          use(a, b, c)
        end

        def fn2(x) do
          base = init(x)
          {a, c} = src(base)
          use(a, c)
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end
end
