defmodule Number42.Refactors.Ex.CanonicalStatementOrderTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.CanonicalStatementOrder
  alias Number42.Refactors.Ex.DelegateExactDuplicates

  @subject CanonicalStatementOrder

  # Enabled by default and takes no enable gate; `@on` is the empty opts
  # list. `min_block_statements:` is still a live opt, threaded where a
  # test needs it.
  @on []

  describe "Slice 0 — enabled by default" do
    test "reorders with no enable opt" do
      before_source = """
      defmodule M do
        def f(input) do
          x = Map.put(%{}, :x, input)
          y = Map.put(%{}, :y, input)
          z = Map.put(%{}, :z, input)

          {x, y, z}
        end
      end
      """

      after_source = """
      defmodule M do
        def f(input) do
          z = Map.put(%{}, :z, input)
          x = Map.put(%{}, :x, input)
          y = Map.put(%{}, :y, input)

          {x, y, z}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, [])
    end
  end

  describe "Slice 1 — independent pure bindings sorted canonically" do
    test "reorders three independent pure bindings into canonical order" do
      # Three independent `Map.put` bindings (pure RHS, no inter-dep).
      # The canonical hash-driven order for this set is z, x, y — a
      # deterministic, variable-name-independent fact about the hash.
      before_source = """
      defmodule M do
        def f(input) do
          x = Map.put(%{}, :x, input)
          y = Map.put(%{}, :y, input)
          z = Map.put(%{}, :z, input)

          {x, y, z}
        end
      end
      """

      after_source = """
      defmodule M do
        def f(input) do
          z = Map.put(%{}, :z, input)
          x = Map.put(%{}, :x, input)
          y = Map.put(%{}, :y, input)

          {x, y, z}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
      assert_idempotent(@subject, before_source, @on)
      assert_compiles(apply_refactor(@subject, before_source, @on))
    end

    test "canonical order is independent of source order (every permutation converges)" do
      permutations =
        for keys <- [~w(x y z), ~w(z y x), ~w(y z x), ~w(z x y), ~w(x z y)] do
          [k1, k2, k3] = keys

          """
          defmodule M do
            def f(input) do
              #{k1} = Map.put(%{}, :#{k1}, input)
              #{k2} = Map.put(%{}, :#{k2}, input)
              #{k3} = Map.put(%{}, :#{k3}, input)

              {x, y, z}
            end
          end
          """
        end

      outputs = Enum.map(permutations, &(apply_refactor(@subject, &1, @on) |> squeeze_body()))

      # Every permutation of the same independent-binding set must reach
      # the SAME canonical statement order — that is the whole point.
      assert Enum.uniq(outputs) |> length() == 1
    end

    test "already-canonical block is left untouched" do
      # The z, x, y order is the canonical fixpoint for this set, so a
      # block already in that order emits no patch.
      source = """
      defmodule M do
        def f(input) do
          z = Map.put(%{}, :z, input)
          x = Map.put(%{}, :x, input)
          y = Map.put(%{}, :y, input)

          {x, y, z}
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "the last statement (return value) is never sorted forward" do
      source = """
      defmodule M do
        def f() do
          z_first = 1
          a_second = 2

          a_second + z_first
        end
      end
      """

      out = apply_refactor(@subject, source, @on)
      # Whatever happens to the two bindings, the trailing return
      # expression stays the trailing expression.
      assert out |> String.trim() |> String.split("\n") |> List.last() |> String.trim() ==
               "end"

      lines = out |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      # `a_second + z_first` must be the last non-blank line before the two `end`s.
      assert Enum.at(lines, -3) == "a_second + z_first"
    end
  end

  describe "Slice 2 — dependency chains via topological sort" do
    test "a binding that reads an earlier binding never moves before it" do
      source = """
      defmodule M do
        def f(input) do
          a = Map.put(%{}, :k, input)
          b = Map.get(a, :k)

          {a, b}
        end
      end
      """

      # `b` depends on `a` (RAW), so order is fixed regardless of hash.
      out = apply_refactor(@subject, source, @on)
      a_pos = position_of(out, "a = Map.put")
      b_pos = position_of(out, "b = Map.get")
      assert a_pos < b_pos
      assert_idempotent(@subject, source, @on)
      assert_compiles(out)
    end

    test "a rebinding chain (socket = f(socket)) keeps its order" do
      source = """
      defmodule M do
        def f(socket) do
          socket = assign(socket, :a, 1)
          socket = assign(socket, :b, 2)

          socket
        end
      end
      """

      # WAW + RAW via rebinding: the two `socket = ...` statements form a
      # hard chain and must never swap.
      assert_unchanged(@subject, source, @on)
    end

    test "destructuring binding feeds a later read — order preserved" do
      source = """
      defmodule M do
        def f(input) do
          {a, b} = split_pair(input)
          c = combine(a, b)

          c
        end
      end
      """

      out = apply_refactor(@subject, source, @on)
      assert position_of(out, "{a, b} = split_pair") < position_of(out, "c = combine")
    end
  end

  describe "Slice 3 — side-effect barriers" do
    test "two impure statements keep their relative source order" do
      source = """
      defmodule M do
        def f(x) do
          Logger.info("first")
          Logger.info("second")

          x
        end
      end
      """

      # Both calls are impure (potential side effect) → relative order
      # is pinned, even though they are data-independent.
      assert_unchanged(@subject, source, @on)
    end

    test "pure independent binding may reorder around a single impure anchor" do
      source = """
      defmodule M do
        def f(x) do
          beta = 2
          Logger.info("side")
          alpha = 1

          {alpha, beta, x}
        end
      end
      """

      # The impure Logger call is a barrier; pure bindings on each side of
      # it stay on their side. So this is unchanged (only one binding per
      # segment, nothing to reorder), proving the barrier segments.
      assert_unchanged(@subject, source, @on)
    end
  end

  describe "Slice 4 — control-flow segment boundaries + min size" do
    test "blocks below min_block_statements are untouched" do
      # Three-statement body that *would* reorder at the default
      # threshold of 3, but a configured threshold of 4 suppresses it.
      source = """
      defmodule M do
        def f(input) do
          x = Map.put(%{}, :x, input)
          y = Map.put(%{}, :y, input)

          {x, y}
        end
      end
      """

      # Body has 3 statements; threshold 4 → below min → no-op.
      assert_unchanged(@subject, source, Keyword.put(@on, :min_block_statements, 4))
    end

    test "min_block_statements gate: same body reorders at the default but not above it" do
      # 3-statement body (2 reorderable leading + pinned return). The
      # canonical order of the pair is x, y.
      source = """
      defmodule M do
        def f(input) do
          y = Map.put(%{}, :y, input)
          x = Map.put(%{}, :x, input)

          {x, y}
        end
      end
      """

      # Above the body size (4) → gate closes → no-op.
      assert_unchanged(@subject, source, Keyword.put(@on, :min_block_statements, 4))

      # At the default threshold (3) → gate opens → reorders to x, y.
      out = apply_refactor(@subject, source, @on)
      assert position_of(out, "x = Map.put") < position_of(out, "y = Map.put")
      assert_idempotent(@subject, source, @on)
      assert_compiles(out)
    end

    test "a case form is a segment boundary; bindings do not cross it" do
      source = """
      defmodule M do
        def f(input) do
          beta = 2

          case input do
            :ok -> 1
            _ -> 0
          end

          alpha = 1
          alpha + beta
        end
      end
      """

      out = apply_refactor(@subject, source, @on)
      # The case stays put and the lone-binding segments on each side
      # cannot merge across it.
      assert position_of(out, "beta = 2") < position_of(out, "case input")
      assert position_of(out, "case input") < position_of(out, "alpha = 1")
      assert_idempotent(@subject, source, @on)
    end
  end

  describe "Slice 5 — INTEGRATION: exposes clones to DelegateExactDuplicates" do
    test "two functions differing only in statement order become detectable clones" do
      # Same independent bindings, different source order. Before the
      # reorder the clone detector's order-sensitive fingerprint misses
      # them; after, both canonicalise to the same order and match.
      mod_a = """
      defmodule MyApp.Items do
        def build(input) do
          a = Map.put(%{}, :x, input)
          b = Map.put(%{}, :y, input)
          c = Map.put(%{}, :z, input)

          {a, b, c}
        end
      end
      """

      mod_b = """
      defmodule MyApp.Items.Positions do
        def build(input) do
          c = Map.put(%{}, :z, input)
          a = Map.put(%{}, :x, input)
          b = Map.put(%{}, :y, input)

          {a, b, c}
        end
      end
      """

      before_plan =
        DelegateExactDuplicates.build_plan(
          [{"a.ex", mod_a}, {"b.ex", mod_b}],
          min_mass: 5
        )

      # Order-sensitive fingerprint: NOT recognised as a clone yet.
      assert before_plan == %{}

      reordered_a = apply_refactor(@subject, mod_a, @on)
      reordered_b = apply_refactor(@subject, mod_b, @on)

      after_plan =
        DelegateExactDuplicates.build_plan(
          [{"a.ex", reordered_a}, {"b.ex", reordered_b}],
          min_mass: 5
        )

      # After canonicalisation the two bodies hash identically → the
      # detector plans a defdelegate. That is the entire purpose.
      refute after_plan == %{}
    end
  end

  describe "Slice 6 — regression: sort key over the normalised AST (#256)" do
    # The canonical sort key normalised each statement (meta stripped +
    # positional variable renaming into synthetic `{:"$var", [], [idx]}`
    # nodes) and then rendered it via `Sourceror.to_string/1` — the
    # Elixir source formatter. The formatter cannot render those
    # synthetic, meta-less internal nodes: its `force_args?/2` does a
    # `case` over node shapes and falls through on the bare integer arg,
    # raising `CaseClauseError`. Reduced from the library's own
    # `lib/mix/tasks/refactor.ex` (a `run_opts = %{...}` map literal). The
    # key must serialise the normalised term, not re-render it as source.

    test "a map literal with variable values does not crash the sort key" do
      source = """
      defmodule M do
        def f(a, b) do
          opts = %{auto?: a, check?: b, dry?: a}
          head = Map.put(%{}, :h, a)
          body = Map.put(%{}, :b, b)

          {opts, head, body}
        end
      end
      """

      result = apply_refactor(@subject, source, @on)

      assert_idempotent(@subject, source, @on)
      assert_compiles(result)
    end

    test "a keyword list with variable values does not crash the sort key" do
      source = """
      defmodule M do
        def f(a, b) do
          opts = [auto?: a, check?: b, dry?: a]
          head = Map.put(%{}, :h, a)
          body = Map.put(%{}, :b, b)

          {opts, head, body}
        end
      end
      """

      result = apply_refactor(@subject, source, @on)

      assert_idempotent(@subject, source, @on)
      assert_compiles(result)
    end

    test "a stepped range with a unary-minus end (the original trace shape)" do
      # The reported stack trace went through `unary_op_to_algebra/5`
      # because the offending file also held `String.slice(path, 3..-1//1)`
      # — a `{:-, _, [1]}` unary op on a bare integer. Same defect, same
      # crash path through the formatter on a normalised node.
      source = """
      defmodule M do
        def f(path, a, b) do
          tail = %{slice: String.slice(path, 3..-1//1), a: a}
          head = Map.put(%{}, :h, a)
          body = Map.put(%{}, :b, b)

          {tail, head, body}
        end
      end
      """

      result = apply_refactor(@subject, source, @on)

      assert_idempotent(@subject, source, @on)
      assert_compiles(result)
    end
  end

  describe "Slice 7 — regression: every body reorders in one pass (#422)" do
    # Before the fix `transform/2` reordered only the FIRST reorderable
    # def body per call, leaning on the engine's pass loop for the rest.
    # On a file with more reorderable bodies than the engine's pass cap
    # (`@max_passes`) the run never reached the later bodies and reported
    # a false non-convergence. A single `transform/2` must now reach the
    # fixpoint for the whole source: applying it twice equals applying it
    # once even when several independent bodies all need reordering.
    test "two independent bodies both sort in a single transform" do
      source = """
      defmodule M do
        def f(input) do
          x = Map.put(%{}, :x, input)
          y = Map.put(%{}, :y, input)
          z = Map.put(%{}, :z, input)

          {x, y, z}
        end

        def g(input) do
          a = Map.put(%{}, :a, input)
          b = Map.put(%{}, :b, input)
          c = Map.put(%{}, :c, input)

          {a, b, c}
        end
      end
      """

      once = apply_refactor(@subject, source, @on)

      # Both bodies must already be canonicalised after ONE pass — i.e.
      # neither still sits in source order.
      refute squeeze_body(once) =~ "x = Map.put(%{}, :x, input) y = Map.put(%{}, :y, input) z ="
      refute squeeze_body(once) =~ "a = Map.put(%{}, :a, input) b = Map.put(%{}, :b, input) c ="

      assert_idempotent(@subject, source, @on)
      assert_compiles(once)
    end

    # Many bodies (> the engine's @max_passes of 5) — the original throttle
    # needed one pass per body, so 6 bodies could never converge under the
    # cap. One transform must settle all of them.
    test "six independent bodies all sort in a single transform" do
      bodies =
        Enum.map_join(?a..?f, "\n\n", fn ch ->
          n = <<ch>>

          """
            def #{n}(input) do
              p = Map.put(%{}, :p, input)
              q = Map.put(%{}, :q, input)
              r = Map.put(%{}, :r, input)

              {p, q, r}
            end
          """
        end)

      source = "defmodule M do\n#{bodies}\nend\n"

      assert_idempotent(@subject, source, @on)
      assert_compiles(apply_refactor(@subject, source, @on))
    end
  end

  # Compare just the def body, whitespace-squeezed.
  defp squeeze_body(source) do
    source
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp position_of(source, needle) do
    case :binary.match(source, needle) do
      {pos, _} -> pos
      :nomatch -> -1
    end
  end
end
