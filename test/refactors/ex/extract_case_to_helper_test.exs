defmodule Number42.Refactors.Ex.ExtractCaseToHelperTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractCaseToHelper

  @subject ExtractCaseToHelper

  describe "rewrites" do
    test "extracts tail-position case with one closure-captured var" do
      before_source = """
      defmodule M do
        def mount(:not_mounted_at_router, %{"position_id" => position_id}, socket) do
          case load_for_mount(socket, position_id) do
            {:ok, assigns} ->
              {:ok, assign(socket, assigns)}

            {:error, :not_found} ->
              {:ok,
               socket
               |> assign(position: nil, invalid?: true)
               |> put_flash(:error, "Position nicht gefunden")}
          end
        end
      end
      """

      expected = """
      defmodule M do
        def mount(:not_mounted_at_router, %{"position_id" => position_id}, socket) do
          load_for_mount(socket, position_id) |> handle_load_for_mount(socket)
        end

        # FIXME: extracted automatically by ExtractCaseToHelper — review
        # the parameter list and consider a better name.
        defp handle_load_for_mount({:ok, assigns}, socket) do
          {:ok, assign(socket, assigns)}
        end

        defp handle_load_for_mount({:error, :not_found}, socket) do
          {:ok,
           socket
           |> assign(position: nil, invalid?: true)
           |> put_flash(:error, "Position nicht gefunden")}
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "no free vars — helper has arity 1" do
      # `combine(v, :ok, %{step: 1})` is a complex clause (3 args,
      # one of which is a map) — that's what trips the non-complex
      # gate and keeps this case extraction-eligible. The other
      # clause is the trivial fallback.
      before_source = """
      defmodule M do
        def foo(x) do
          case lookup(x) do
            {:ok, v} -> combine(v, :ok, %{step: 1})
            :error -> 0
          end
        end
      end
      """

      expected = """
      defmodule M do
        def foo(x) do
          lookup(x) |> handle_foo_lookup()
        end

        # FIXME: extracted automatically by ExtractCaseToHelper — review
        # the parameter list and consider a better name.
        defp handle_foo_lookup({:ok, v}) do
          combine(v, :ok, %{step: 1})
        end

        defp handle_foo_lookup(:error) do
          0
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "free vars unioned across branches give same arity" do
      # First clause is a 3-arg call → complex enough for the gate to
      # let extraction proceed. Second clause stays a 1-arg call.
      before_source = """
      defmodule M do
        def run(a, b) do
          case fetch(a) do
            {:ok, x} -> use_a(x, a, %{tag: :ok})
            :error -> use_b(b)
          end
        end
      end
      """

      expected = """
      defmodule M do
        def run(a, b) do
          fetch(a) |> handle_run_fetch(a, b)
        end

        # FIXME: extracted automatically by ExtractCaseToHelper — review
        # the parameter list and consider a better name.
        defp handle_run_fetch({:ok, x}, a, _b) do
          use_a(x, a, %{tag: :ok})
        end

        defp handle_run_fetch(:error, _a, b) do
          use_b(b)
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "remote call as scrutinee uses just the function name in helper name" do
      # The match-on-found clause uses a multi-stage pipe — complex
      # enough to clear the non-complex gate.
      before_source = """
      defmodule M do
        def get(id) do
          case Repo.get(User, id) do
            nil -> {:error, :not_found}
            user -> user |> sanitize() |> wrap_ok()
          end
        end
      end
      """

      expected = """
      defmodule M do
        def get(id) do
          Repo.get(User, id) |> handle_get()
        end

        # FIXME: extracted automatically by ExtractCaseToHelper — review
        # the parameter list and consider a better name.
        defp handle_get(nil) do
          {:error, :not_found}
        end

        defp handle_get(user) do
          user |> sanitize() |> wrap_ok()
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "preceding statements stay; only the tail case is extracted" do
      # `wrap(r, y, %{step: 2})` is the complex clause that gates
      # the extraction; `y` alone stays trivial.
      before_source = """
      defmodule M do
        def go(x) do
          y = x + 1

          case work(y) do
            {:ok, r} -> wrap(r, y, %{step: 2})
            :error -> y
          end
        end
      end
      """

      expected = """
      defmodule M do
        def go(x) do
          y = x + 1

          work(y) |> handle_go_work(y)
        end

        # FIXME: extracted automatically by ExtractCaseToHelper — review
        # the parameter list and consider a better name.
        defp handle_go_work({:ok, r}, y) do
          wrap(r, y, %{step: 2})
        end

        defp handle_go_work(:error, y) do
          y
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "leaves alone" do
    test "case is not the tail expression" do
      assert_unchanged(@subject, """
      defmodule M do
        def foo(x) do
          case lookup(x) do
            {:ok, v} -> v
            :error -> 0
          end

          :ok
        end
      end
      """)
    end

    test "scrutinee is a bare variable, not a function call" do
      assert_unchanged(@subject, """
      defmodule M do
        def foo(x) do
          case x do
            1 -> :one
            _ -> :other
          end
        end
      end
      """)
    end

    test "scrutinee is a pipe expression" do
      assert_unchanged(@subject, """
      defmodule M do
        def foo(x) do
          case x |> normalize() do
            :a -> 1
            :b -> 2
          end
        end
      end
      """)
    end

    test "any clause body or guard references `super`" do
      # `super` is bound to the surrounding def — moving it into a
      # synthesized helper changes which definition it overrides
      # (or fails the arity check). Skip extraction whole-cloth.
      assert_unchanged(@subject, """
      defmodule M do
        def cast(value) when is_binary(value) do
          case Map.get(@aliases, value) do
            nil -> super(value)
            atom -> {:ok, atom}
          end
        end
      end
      """)
    end

    test "any clause pattern pins an outer variable" do
      # `^expected` pins the surrounding function's `expected` parameter.
      # Moving the case into a synthesized helper would lose that binding
      # (the pin would refer to nothing in the helper's scope) and the
      # extracted code fails to compile. Skip extraction whole-cloth.
      assert_unchanged(@subject, """
      defmodule M do
        defp infer_type_matches?(atomized, ctx, expected) do
          case Checker.infer_type(atomized, ctx) do
            {:ok, ^expected} -> true
            {:ok, _} when is_nil(expected) -> true
            _ -> false
          end
        end
      end
      """)
    end

    test "a clause guard pins an outer variable" do
      # Pin in the guard rather than the pattern — same problem: the
      # outer `expected` isn't in the helper's scope.
      assert_unchanged(@subject, """
      defmodule M do
        defp check(input, expected) do
          case run(input) do
            {:ok, value} when value == ^expected -> :match
            _ -> :nope
          end
        end
      end
      """)
    end
  end

  describe "leaves alone — non-complex case (all clauses are trivial)" do
    # "non-complex" clause body = literal, bare var, tuple of non-complex
    # parts, 1-2-arg local/qualified call of non-complex args, binary op
    # of non-complex operands, unary op of non-complex operand, or
    # 1-stage pipe of non-complex parts. A case is non-complex when ALL
    # its clauses are non-complex. Such cases don't benefit from being
    # lifted into a helper — the dispatch is already trivial, and the
    # extra hop costs more than it saves.

    test "all bare-var clauses skipped" do
      assert_unchanged(@subject, """
      defmodule M do
        def foo(x) do
          case lookup(x) do
            {:ok, v} -> v
            :error -> x
          end
        end
      end
      """)
    end

    test "all literal clauses skipped" do
      assert_unchanged(@subject, """
      defmodule M do
        def kind(x) do
          case classify(x) do
            :a -> 1
            :b -> 2
            :c -> 3
          end
        end
      end
      """)
    end

    test "all tuple clauses skipped" do
      assert_unchanged(@subject, """
      defmodule M do
        def get(id) do
          case Repo.get(User, id) do
            nil -> {:error, :not_found}
            user -> {:ok, user}
          end
        end
      end
      """)
    end

    test "all 1-arg-call clauses skipped" do
      assert_unchanged(@subject, """
      defmodule M do
        def log(x) do
          case fetch(x) do
            {:ok, v} -> handle(v)
            :error -> notify(x)
          end
        end
      end
      """)
    end

    test "all 2-arg-call clauses skipped" do
      assert_unchanged(@subject, """
      defmodule M do
        def run(a, b) do
          case fetch(a) do
            {:ok, x} -> use_a(x, a)
            :error -> use_b(b, a)
          end
        end
      end
      """)
    end

    test "binary-op-only clauses (a + 1, x == y) skipped" do
      assert_unchanged(@subject, """
      defmodule M do
        def foo(x) do
          case lookup(x) do
            {:ok, v} -> v + 1
            :error -> 0
          end
        end
      end
      """)
    end

    test "1-stage pipe clauses skipped" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(x) do
          case lookup(x) do
            {:ok, v} -> v |> double()
            :error -> x |> default()
          end
        end
      end
      """)
    end

    test "mix of literal + tuple + 1-arg-call still all non-complex → skipped" do
      assert_unchanged(@subject, """
      defmodule M do
        def dispatch(s) do
          case fetch(s) do
            {:ok, v} -> {:ok, v}
            :missing -> :missing
            :error -> notify(s)
          end
        end
      end
      """)
    end
  end

  describe "still extracts when at least one clause is complex" do
    # The complement of the non-complex gate: as soon as ONE clause
    # carries real work (3+-arg call, multi-stage pipe, nested
    # case/if/with, map literal, &-capture, lambda, …), the whole
    # case becomes worth lifting.

    test "one clause has a multi-stage pipe → extracts" do
      before_source = """
      defmodule M do
        def go(socket, id) do
          case load(socket, id) do
            {:ok, assigns} ->
              {:ok, assign(socket, assigns)}

            {:error, :not_found} ->
              {:ok,
               socket
               |> assign(position: nil, invalid?: true)
               |> put_flash(:error, "nicht gefunden")}
          end
        end
      end
      """

      expected = """
      defmodule M do
        def go(socket, id) do
          load(socket, id) |> handle_go_load(socket)
        end

        # FIXME: extracted automatically by ExtractCaseToHelper — review
        # the parameter list and consider a better name.
        defp handle_go_load({:ok, assigns}, socket) do
          {:ok, assign(socket, assigns)}
        end

        defp handle_go_load({:error, :not_found}, socket) do
          {:ok,
           socket
           |> assign(position: nil, invalid?: true)
           |> put_flash(:error, "nicht gefunden")}
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "one clause has a 3-arg call → extracts" do
      before_source = """
      defmodule M do
        def run(a, b, ctx) do
          case fetch(a) do
            {:ok, x} -> combine(x, a, ctx)
            :error -> b
          end
        end
      end
      """

      expected = """
      defmodule M do
        def run(a, b, ctx) do
          fetch(a) |> handle_run_fetch(a, b, ctx)
        end

        # FIXME: extracted automatically by ExtractCaseToHelper — review
        # the parameter list and consider a better name.
        defp handle_run_fetch({:ok, x}, a, _b, ctx) do
          combine(x, a, ctx)
        end

        defp handle_run_fetch(:error, _a, b, _ctx) do
          b
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "one clause has a nested case → extracts" do
      before_source = """
      defmodule M do
        def go(x) do
          case lookup(x) do
            {:ok, v} ->
              case decode(v) do
                {:ok, d} -> d
                :error -> :decode_failed
              end

            :error -> :lookup_failed
          end
        end
      end
      """

      # We only assert the outer extraction here (a nested case in the
      # extracted clause is the user's to clean up next pass).
      expected = """
      defmodule M do
        def go(x) do
          lookup(x) |> handle_go_lookup()
        end

        # FIXME: extracted automatically by ExtractCaseToHelper — review
        # the parameter list and consider a better name.
        defp handle_go_lookup({:ok, v}) do
          case decode(v) do
            {:ok, d} -> d
            :error -> :decode_failed
          end
        end

        defp handle_go_lookup(:error) do
          :lookup_failed
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "collision handling" do
    test "skips when an existing helper has structurally identical clauses" do
      # If the module already defines a helper with the synth name AND
      # that helper's clauses match the case clauses one-for-one (same
      # patterns, guards, bodies), the case has effectively already
      # been extracted. Re-running would duplicate the helper. Leave
      # the source unchanged (the host's case stays as-is — fixing the
      # half-done extraction is a manual job).
      assert_unchanged(@subject, """
      defmodule M do
        def foo(x) do
          case lookup(x) do
            {:ok, v} -> wrap(v, :ok, %{seen: true})
            :error -> 0
          end
        end

        defp handle_foo_lookup({:ok, v}) do
          wrap(v, :ok, %{seen: true})
        end

        defp handle_foo_lookup(:error) do
          0
        end
      end
      """)
    end

    test "renames helper with `_2` suffix when existing helper has different body" do
      before_source = """
      defmodule M do
        def foo(x) do
          case lookup(x) do
            {:ok, v} -> wrap(v, :ok, %{seen: true})
            :error -> 0
          end
        end

        defp handle_foo_lookup(_), do: :pre_existing
      end
      """

      actual = apply_refactor(@subject, before_source)
      assert String.contains?(actual, "lookup(x) |> handle_foo_lookup_2()")
      assert String.contains?(actual, "defp handle_foo_lookup_2({:ok, v})")
      assert String.contains?(actual, "defp handle_foo_lookup_2(:error)")
      # Pre-existing helper stays put.
      assert String.contains?(actual, "defp handle_foo_lookup(_)")
    end

    test "increments suffix until free: existing _2 forces _3" do
      before_source = """
      defmodule M do
        def foo(x) do
          case lookup(x) do
            {:ok, v} -> wrap(v, :ok, %{seen: true})
            :error -> 0
          end
        end

        defp handle_foo_lookup(_), do: :one
        defp handle_foo_lookup_2(_), do: :two
      end
      """

      actual = apply_refactor(@subject, before_source)
      assert String.contains?(actual, "lookup(x) |> handle_foo_lookup_3()")
      assert String.contains?(actual, "defp handle_foo_lookup_3({:ok, v})")
    end
  end

  describe "scope-aware shadowing" do
    test "var rebound by `from(x in …)` is not pulled in as helper param" do
      before_source = """
      defmodule M do
        def fetch(token) do
          case decode(token) do
            {:ok, decoded} ->
              q = from(token in src(decoded),
                where: token.x == 1,
                select: token
              )
              {:ok, q}

            :error -> :error
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      # `token` rebound inside `from` — outer `token` is unused in body.
      # Pipe call has arity 1; helper signature has arity 1.
      assert String.contains?(actual, "decode(token) |> handle_fetch_decode()")
      assert String.contains?(actual, "defp handle_fetch_decode({:ok, decoded})")
      assert String.contains?(actual, "defp handle_fetch_decode(:error)")
      refute String.contains?(actual, "handle_fetch_decode(token)")
    end

    test "var rebound by `fn x ->` doesn't count as outer use" do
      before_source = """
      defmodule M do
        def run(items, x) do
          case classify(items) do
            :keep ->
              Enum.map(items, fn x -> x * 2 end)

            :drop -> x
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      # `x` is referenced in :drop body (outer) but not in :keep body
      # (the `x` inside `fn x -> x * 2 end` is the lambda binding, not
      # the outer var). `items` is used in :keep, not :drop.
      assert String.contains?(actual, "classify(items) |> handle_run_classify(items, x)")
      assert String.contains?(actual, "defp handle_run_classify(:keep, items, _x)")
      assert String.contains?(actual, "defp handle_run_classify(:drop, _items, x)")
    end

    test "var rebound by `for x <- …` doesn't count as outer use" do
      before_source = """
      defmodule M do
        def run(xs, x) do
          case lookup(xs) do
            :many ->
              for x <- xs, do: x

            :one -> x
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert String.contains?(actual, "lookup(xs) |> handle_run_lookup(x, xs)")
      assert String.contains?(actual, "defp handle_run_lookup(:many, _x, xs)")
      assert String.contains?(actual, "defp handle_run_lookup(:one, x, _xs)")
    end
  end

  describe "when-guards" do
    test "guard moves out of pattern slot into helper signature" do
      # Default branch builds the provider via a 3-arg call to clear
      # the non-complex gate; the guarded branch is the simple
      # passthrough.
      before_source = """
      defmodule M do
        defp resolve_provider(opts) do
          case Keyword.pop(opts, :provider) do
            {nil, rest} -> {build_provider(:ai, :default, %{flag: true}), rest}
            {mod, rest} when is_atom(mod) -> {mod, rest}
          end
        end
      end
      """

      expected = """
      defmodule M do
        defp resolve_provider(opts) do
          Keyword.pop(opts, :provider) |> handle_resolve_provider_pop()
        end

        # FIXME: extracted automatically by ExtractCaseToHelper — review
        # the parameter list and consider a better name.
        defp handle_resolve_provider_pop({nil, rest}) do
          {build_provider(:ai, :default, %{flag: true}), rest}
        end

        defp handle_resolve_provider_pop({mod, rest}) when is_atom(mod) do
          {mod, rest}
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "guard reading an outer var pulls that var into free_vars" do
      # First branch uses a 3-arg call to clear the non-complex gate;
      # the guard logic is the actual subject under test.
      before_source = """
      defmodule M do
        def run(threshold, items) do
          case classify(items) do
            {:big, n} when n > threshold -> escalate(n, threshold, :over)
            _ -> :under
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert String.contains?(actual, "classify(items) |> handle_run_classify(threshold)")

      assert String.contains?(
               actual,
               "defp handle_run_classify({:big, n}, threshold) when n > threshold"
             )

      assert String.contains?(actual, "defp handle_run_classify(_, _threshold)")
    end
  end

  describe "unused-param prefixing" do
    test "prefixes _ on extra params unused by a clause body" do
      # First branch is a 3-arg call → complex → gate passes.
      before_source = """
      defmodule M do
        def mount(_, %{"id" => id}, socket) do
          case load(id) do
            {:ok, assigns} -> {:ok, assign_async(socket, assigns, %{ok: true})}
            :error -> {:error, :not_found}
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert String.contains?(actual, "load(id) |> handle_mount_load(socket)")
      assert String.contains?(actual, "defp handle_mount_load({:ok, assigns}, socket)")
      assert String.contains?(actual, "defp handle_mount_load(:error, _socket)")
    end

    test "pipe call uses real var names; only signatures get _ prefix" do
      # First branch is a 3-arg call → complex → gate passes.
      before_source = """
      defmodule M do
        def run(a, b) do
          case fetch(a) do
            {:ok, x} -> use_a(x, a, %{seen: true})
            :error -> use_b(b)
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      # Pipe site keeps real names — vars exist at the call site.
      assert String.contains?(actual, "fetch(a) |> handle_run_fetch(a, b)")
      # Each clause prefixes its locally-unused params.
      assert String.contains?(actual, "defp handle_run_fetch({:ok, x}, a, _b)")
      assert String.contains?(actual, "defp handle_run_fetch(:error, _a, b)")
    end
  end

  describe "name sanitization" do
    test "strips trailing ?/! from host and scrutinee names" do
      # `:module` branch uses a 3-arg call so the gate lets the
      # extraction proceed; the boolean fall-through stays trivial.
      before_source = """
      defmodule M do
        defp refactor?(module) when is_atom(module) do
          case Code.ensure_loaded(module) do
            {:module, _} -> validate(module, :loaded, %{ok: true})
            _ -> false
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      # scrutinee `ensure_loaded` has 2 subtokens → host (`refactor?`)
      # is dropped per AstHelpers.synth_compound_name/4. The `?` is still
      # stripped so the synthesised name is a valid identifier.
      assert String.contains?(actual, "handle_ensure_loaded")
      refute String.contains?(actual, "handle_refactor?")

      assert {:ok, _} = Code.string_to_quoted(actual)
    end

    test "strips bang from host name" do
      # `raise` always counts as complex (control-flow break) →
      # gate lets the extraction through.
      before_source = """
      defmodule M do
        def commit!(state) do
          case persist(state) do
            {:ok, _} -> :ok
            :error -> raise "boom"
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert String.contains?(actual, "handle_commit_persist")
      refute String.contains?(actual, "handle_commit!_persist")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      source = """
      defmodule M do
        def mount(_, %{"id" => id}, socket) do
          case load(socket, id) do
            {:ok, assigns} -> {:ok, assign(socket, assigns)}
            :error -> {:ok, put_flash(socket, :error, "nope")}
          end
        end
      end
      """

      assert_idempotent(@subject, source)
    end
  end
end
