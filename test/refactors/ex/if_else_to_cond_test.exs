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
