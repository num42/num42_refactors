defmodule Number42.Refactors.Ex.IfElseToCondTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.IfElseToCond

  @subject IfElseToCond

  describe "rewrites — plain nested (no pre-statements)" do
    test "if-in-else with three terminal branches becomes a 3-branch cond" do
      before_source = """
      def f(x) do
        if cond1 do
          a
        else
          if cond2 do
            b
          else
            c
          end
        end
      end
      """

      after_source = """
      def f(x) do
        cond do
          cond1 -> a
          cond2 -> b
          true -> c
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "if-in-do becomes cond, condition negation handled correctly" do
      before_source = """
      def f(x) do
        if cond1 do
          if cond2 do
            a
          else
            b
          end
        else
          c
        end
      end
      """

      after_source = """
      def f(x) do
        cond do
          cond1 and cond2 -> a
          cond1 -> b
          true -> c
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "clamp pattern (nested if-in-else, expression-level)" do
      before_source = """
      defp clamp(is, min, max) do
        if is > max, do: max, else: if(is < min, do: min, else: is)
      end
      """

      after_source = """
      defp clamp(is, min, max) do
        cond do
          is > max -> max
          is < min -> min
          true -> is
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "compound inner condition (no outer-body binding) still flattens with conjunction" do
      # Regression guard for the issue #8 fix: the skip rule must only trip on
      # outer-body bindings. A compound inner guard that references nothing from
      # the outer body must still flatten correctly into a conjunction.
      before_source = """
      def f(x) do
        if a > 0 do
          if b > 0 and c < 10 do
            hit
          else
            miss
          end
        else
          fallback
        end
      end
      """

      after_source = """
      def f(x) do
        cond do
          a > 0 and (b > 0 and c < 10) -> hit
          a > 0 -> miss
          true -> fallback
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "three-level linear else-chain flattens to a single cond" do
      before_source = """
      def f(x) do
        if a do
          x1
        else
          if b do
            y1
          else
            if c do
              z1
            else
              default
            end
          end
        end
      end
      """

      after_source = """
      def f(x) do
        cond do
          a -> x1
          b -> y1
          c -> z1
          true -> default
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "branches contain multi-statement bodies (no pre-statements before nested if)" do
      before_source = """
      def f(x) do
        if cond1 do
          y = compute(x)
          use(y)
        else
          if cond2 do
            z = other(x)
            use(z)
          else
            fallback(x)
          end
        end
      end
      """

      after_source = """
      def f(x) do
        cond do
          cond1 ->
            y = compute(x)
            use(y)

          cond2 ->
            z = other(x)
            use(z)

          true ->
            fallback(x)
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "rewrites — identical outer branches collapse" do
    test "if/else with structurally identical branches collapses to inner logic" do
      before_source = """
      def f(x) do
        if outer_cond do
          if inner_cond do
            a
          else
            b
          end
        else
          if inner_cond do
            a
          else
            b
          end
        end
      end
      """

      after_source = """
      def f(x) do
        cond do
          inner_cond -> a
          true -> b
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "rewrites — pre-statements extracted as local fn" do
    test "single pre-statement binding extracted as local fn, called once in cond" do
      before_source = """
      def f(value, allowed, changeset, field) do
        if value in [nil, ""] do
          changeset
        else
          all_valid? =
            value
            |> String.split(",", trim: true)
            |> Enum.all?(&(&1 in allowed))

          if all_valid? do
            changeset
          else
            add_error(changeset, field, "is invalid")
          end
        end
      end
      """

      after_source = """
      def f(value, allowed, changeset, field) do
        compute_all_valid = fn ->
          value
          |> String.split(",", trim: true)
          |> Enum.all?(&(&1 in allowed))
        end

        cond do
          value in [nil, ""] -> changeset
          compute_all_valid.() -> changeset
          true -> add_error(changeset, field, "is invalid")
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "rewrites — pure outer-body bindings hoisted before cond" do
    test "compound inner condition referencing a pure binding — binding hoisted, guards conjoined" do
      before_source = """
      def f(state, next) do
        if next == nil do
          total = state.a + state.b

          if total > 0 do
            vote
          else
            novote
          end
        else
          novote
        end
      end
      """

      after_source = """
      def f(state, next) do
        total = state.a + state.b

        cond do
          next == nil and total > 0 -> vote
          next == nil -> novote
          true -> novote
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "issue #8 repro: every guard survives as a conjunction, binding hoisted" do
      # Historic failure mode: the whole compound guard was replaced by a
      # no-op `compute_total.()` lambda call, silently dropping every guard.
      before_source = """
      def update_state(state, {_prev, _curr, next}, _emit_buf, _src, _grp) do
        if next == nil do
          total = state.literal_count + state.id_count

          if total > 0 and not state.has_control_flow and
               state.literal_count / total > 0.6 do
            {MapSet.new([{:data_vote, 2}]), :halt}
          else
            {MapSet.new(), state}
          end
        else
          {MapSet.new(), state}
        end
      end
      """

      after_source = """
      def update_state(state, {_prev, _curr, next}, _emit_buf, _src, _grp) do
        total = state.literal_count + state.id_count

        cond do
          next == nil and
              (total > 0 and not state.has_control_flow and
                 state.literal_count / total > 0.6) ->
            {MapSet.new([{:data_vote, 2}]), :halt}

          next == nil ->
            {MapSet.new(), state}

          true ->
            {MapSet.new(), state}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "cascading bindings across levels hoist in order" do
      before_source = """
      def f(state) do
        if state.mode == :off do
          :off
        else
          t1 = state.a + state.b

          if t1 > 0 do
            :pos
          else
            t2 = t1 * -1

            if t2 > 5 do
              :very_neg
            else
              :mild
            end
          end
        end
      end
      """

      after_source = """
      def f(state) do
        t1 = state.a + state.b
        t2 = t1 * -1

        cond do
          state.mode == :off -> :off
          t1 > 0 -> :pos
          t2 > 5 -> :very_neg
          true -> :mild
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "skips — hoisting safety gates" do
    test "compound condition over an impure binding (function call RHS) — skip" do
      assert_unchanged(@subject, """
      def f(state, next) do
        if next == nil do
          total = compute_total(state)

          if total > 0 and total < 100 do
            vote
          else
            novote
          end
        else
          novote
        end
      end
      """)
    end

    test "binding name already bound before the if and used after it — skip" do
      # Hoisting would rebind `total` for the code after the cond.
      assert_unchanged(@subject, """
      def f(state, next) do
        total = state.x

        r =
          if next == nil do
            total = state.a + state.b

            if total > 0 do
              :hot
            else
              :cold
            end
          else
            :cold
          end

        {r, total}
      end
      """)
    end

    test "binding name shadows a function parameter — skip" do
      assert_unchanged(@subject, """
      def f(total, next) do
        if next == nil do
          total = total + 1

          if total > 0 do
            :hot
          else
            :cold
          end
        else
          :cold
        end
      end
      """)
    end

    test "hoist RHS referencing a fn-extracted binding — whole-tree flatten blocked" do
      # Flattening the OUTER if would fn-extract `x` (its binding becomes a
      # lambda and disappears), so hoisting `y = (x || 0) + 1` would capture
      # the parameter `x` instead of the shadow binding. The gate blocks
      # that; only the inner if — where `x` stays bound — may flatten.
      before_source = """
      def f(a, src, x) do
        if a do
          :r1
        else
          x = src[:k]

          if x do
            :r2
          else
            y = (x || 0) + 1

            if y > 100 do
              {:r3, y}
            else
              {:r4, y}
            end
          end
        end
      end
      """

      after_source = """
      def f(a, src, x) do
        if a do
          :r1
        else
          x = src[:k]

          y = (x || 0) + 1

          cond do
            x -> :r2
            y > 100 -> {:r3, y}
            true -> {:r4, y}
          end
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "binding RHS calls a zero-arity remote function — skip" do
      assert_unchanged(@subject, """
      def f(next) do
        if next == nil do
          total = :rand.uniform()

          if total > 0.5 and total < 0.9 do
            :high
          else
            :low
          end
        else
          :none
        end
      end
      """)

      assert_unchanged(@subject, """
      def f(next) do
        if next == nil do
          total = :erlang.system_time

          if total > 0 and total < 99 do
            :high
          else
            :low
          end
        else
          :none
        end
      end
      """)
    end

    test "binding RHS calls a function on a variable receiver with parens — skip" do
      assert_unchanged(@subject, """
      def f(repo, next) do
        if next == nil do
          rows = repo.fetch_all()

          if rows != [] and length(rows) < 10 do
            :some
          else
            :none
          end
        else
          :none
        end
      end
      """)
    end

    test "hoist RHS receiver is type-guarded by an outer condition — skip" do
      # `state.a` is only reachable when `is_map(state)` held; hoisting
      # would evaluate it eagerly and raise on the else path.
      assert_unchanged(@subject, """
      def f(state) do
        if is_map(state) do
          total = state.a + state.b

          if total > 0 and total < 99 do
            :vote
          else
            :novote
          end
        else
          :novote
        end
      end
      """)

      assert_unchanged(@subject, """
      def f(state) do
        if state == nil do
          :novote
        else
          total = state.a + state.b

          if total > 0 and total < 99 do
            :vote
          else
            :novote
          end
        end
      end
      """)
    end

    test "same binding name introduced on two levels — skip" do
      # Hoisting both would let the second rebinding leak into every arm.
      assert_unchanged(@subject, """
      def f(state) do
        if state.off do
          :off
        else
          t = state.p + 1

          if t > 0 do
            :p_pos
          else
            t = state.q + 1

            if t > 0 do
              :q_pos
            else
              :rest
            end
          end
        end
      end
      """)
    end
  end

  describe "skips — semantics-changing or ambiguous shapes" do
    test "inner if without else is left alone" do
      assert_unchanged(@subject, """
      def f(x) do
        if cond1 do
          a
        else
          if cond2 do
            b
          end
        end
      end
      """)
    end

    test "plain if/else without nesting is left alone" do
      assert_unchanged(@subject, """
      def f(x) do
        if cond1 do
          a
        else
          b
        end
      end
      """)
    end

    test "pre-statement binding used in BOTH the inner condition AND the inner else body — skip" do
      assert_unchanged(@subject, """
      def f(x) do
        if outer_cond do
          a
        else
          result = expensive_compute(x)

          if result.ok? do
            handle_ok(result)
          else
            handle_err(result)
          end
        end
      end
      """)
    end

    test "pre-statement is a side-effect call without binding — skip" do
      assert_unchanged(@subject, """
      def f(x) do
        if outer_cond do
          a
        else
          Logger.info("trying alternate path")

          if inner_cond do
            b
          else
            c
          end
        end
      end
      """)
    end

    test "impure outer condition would be duplicated across arms (do-side nest) — skip" do
      # Flattening copies the outer condition into every do-side arm;
      # `send/2` would fire once per arm instead of once.
      assert_unchanged(@subject, """
      def f(pid) do
        if send(pid, :probe) == :probe do
          if check(pid) do
            a
          else
            b
          end
        else
          c
        end
      end
      """)
    end

    test "impure outer condition would be dropped by identical-branch collapse — skip" do
      assert_unchanged(@subject, """
      def f(x) do
        if log_and_check(x) do
          if inner_cond do
            a
          else
            b
          end
        else
          if inner_cond do
            a
          else
            b
          end
        end
      end
      """)
    end

    test "non-linear nest (both do and else nest a distinct if) — skip" do
      assert_unchanged(@subject, """
      def f(x) do
        if a do
          if b do
            x1
          else
            x2
          end
        else
          if c do
            y1
          else
            y2
          end
        end
      end
      """)
    end
  end

  describe "idempotent" do
    test "plain nested rewrite is idempotent" do
      assert_idempotent(@subject, """
      def f(x) do
        if cond1 do
          a
        else
          if cond2 do
            b
          else
            c
          end
        end
      end
      """)
    end

    test "pre-statement extraction is idempotent" do
      assert_idempotent(@subject, """
      def f(value, allowed, changeset, field) do
        if value in [nil, ""] do
          changeset
        else
          all_valid? = Enum.all?(value, &(&1 in allowed))

          if all_valid? do
            changeset
          else
            add_error(changeset, field, "is invalid")
          end
        end
      end
      """)
    end

    test "three-level flattening is idempotent" do
      assert_idempotent(@subject, """
      def f(x) do
        if a do
          x1
        else
          if b do
            y1
          else
            if c do
              z1
            else
              default
            end
          end
        end
      end
      """)
    end

    test "binding hoist is idempotent" do
      assert_idempotent(@subject, """
      def f(state, next) do
        if next == nil do
          total = state.a + state.b

          if total > 0 do
            vote
          else
            novote
          end
        else
          novote
        end
      end
      """)
    end

    test "identical-outer-branches collapse is idempotent" do
      assert_idempotent(@subject, """
      def f(x) do
        if outer_cond do
          if inner_cond do
            a
          else
            b
          end
        else
          if inner_cond do
            a
          else
            b
          end
        end
      end
      """)
    end
  end
end
