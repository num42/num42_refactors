defmodule Number42.Refactors.Ex.SplitPipeableResponsibilitiesTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.SplitPipeableResponsibilities

  @subject SplitPipeableResponsibilities

  describe "rewrites — single carrier becomes a pipe" do
    test "splits a clean two-phase body where one value flows across into a pipe" do
      before_source = """
      defmodule M do
        def report(order) do
          subtotal = sum_lines(order)
          discount = lookup_discount(order)
          net = subtotal - discount
          doubled = net * 2
          adjusted = doubled + 1
          format(adjusted)
        end
      end
      """

      # Narrowest cut is after `net = subtotal - discount` (stmt 2):
      # only `net` is read downstream → single carrier → pipe. Phase 2
      # reads only `net` (and call names), so its sole parameter is
      # `net`: a clean pipe.
      after_source = """
      defmodule M do
        def report(order) do
          order
          |> report_phase_1()
          |> report_phase_2()
        end

        defp report_phase_1(order) do
          subtotal = sum_lines(order)
          discount = lookup_discount(order)
          net = subtotal - discount
          net
        end

        defp report_phase_2(net) do
          doubled = net * 2
          adjusted = doubled + 1
          format(adjusted)
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "skips — side effects" do
    test "leaves a body containing a Repo. call untouched" do
      source = """
      defmodule M do
        def run(order) do
          a = compute(order)
          b = derive(a)
          Repo.insert(b)
          finalize(b)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves a body containing a Logger. call untouched" do
      source = """
      defmodule M do
        def run(order) do
          a = compute(order)
          b = derive(a)
          Logger.info("done")
          finalize(b)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves a body containing a send/2 call untouched" do
      source = """
      defmodule M do
        def run(order) do
          a = compute(order)
          b = derive(a)
          send(pid, b)
          finalize(b)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves a body containing a bang function untouched" do
      source = """
      defmodule M do
        def run(order) do
          a = compute(order)
          b = derive(a)
          File.write!(path, b)
          finalize(b)
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "skips — nothing to split" do
    test "leaves a body too short to form two phases untouched" do
      source = """
      defmodule M do
        def run(order) do
          a = compute(order)
          finalize(a)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves a body with no clean low-carrier cut untouched" do
      # The narrowest valid cut (after stmt 1, min 2/phase) already
      # carries four values: the two tuple bindings bind a,b,c,d and all
      # four are read by the tail — exceeding the default max_carriers of
      # 3. No eligible boundary → no split.
      source = """
      defmodule M do
        def run(x) do
          {a, b} = f(x)
          {c, d} = g(x)
          mid = h(x)
          tail = i(x)
          done(a, b, c, d, mid, tail)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves a body with control flow untouched" do
      source = """
      defmodule M do
        def run(order) do
          a = compute(order)
          b = derive(a)

          c =
            if a > b do
              x(a)
            else
              y(b)
            end

          finalize(c)
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "rewrites — flat maximal partition in one pass" do
    test "a six-statement body splits into three flat phases, not a nested re-split" do
      before_source = """
      defmodule M do
        def run(order) do
          a = f(order)
          b = g(a)
          c = h(b)
          d = i(c)
          e = j(d)
          last(e)
        end
      end
      """

      # Single value flows across each boundary (b, then d) → a flat
      # pipe of three phases in ONE pass. No `run_phase_2_phase_1` etc.
      after_source = """
      defmodule M do
        def run(order) do
          order
          |> run_phase_1()
          |> run_phase_2()
          |> run_phase_3()
        end

        defp run_phase_1(order) do
          a = f(order)
          b = g(a)
          b
        end

        defp run_phase_2(b) do
          c = h(b)
          d = i(c)
          d
        end

        defp run_phase_3(d) do
          e = j(d)
          last(e)
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "applying transform twice equals applying it once (fixpoint after one pass)" do
      source = """
      defmodule M do
        def run(order) do
          a = f(order)
          b = g(a)
          c = h(b)
          d = i(c)
          e = j(d)
          last(e)
        end
      end
      """

      once = SplitPipeableResponsibilities.transform(source, [])

      assert_idempotent(@subject, source)
      refute once =~ ~r/_phase_\d+_phase_\d+/
    end
  end

  describe "idempotence — fan-in bodies" do
    # A fan-in body (independent bindings all feeding one tail) can only
    # cut once under max_carriers, so the maximal partition is two phases
    # with a long tail helper. That helper would re-split on a second
    # pass were generated `_phase_n` helpers not skipped. This guards the
    # `_phase_2_phase_2` cascade seen against position-db's new/2.
    test "a fan-in body reaches a fixpoint after one pass (no nested re-split)" do
      source = """
      defmodule M do
        def build(opts, org) do
          a = pick(opts, :a)
          b = pick(opts, :b)
          c = pick(opts, :c)
          d = pick(opts, :d)
          e = load(org)
          g = load2(org)
          assemble(a, b, c, d, e, g, org)
        end
      end
      """

      once = SplitPipeableResponsibilities.transform(source, [])

      assert once =~ "build_phase_1"
      refute once =~ ~r/_phase_\d+_phase_\d+/
      assert_idempotent(@subject, source)
    end
  end

  describe "idempotence" do
    test "a second pass over already-split output is a no-op" do
      already_split = """
      defmodule M do
        def report(order) do
          order
          |> report_phase_1()
          |> report_phase_2()
        end

        defp report_phase_1(order) do
          subtotal = sum_lines(order)
          discount = lookup_discount(order)
          subtotal - discount
        end

        defp report_phase_2(net) do
          tax = net * rate(order)
          total = net + tax
          format(total)
        end
      end
      """

      assert_unchanged(@subject, already_split)
    end
  end

  describe "rewrites — interpolated multiline string tail" do
    # Regression: a tail expression that is an interpolated string with
    # escaped quotes makes `Sourceror.get_range/1` undercount its end
    # column, so per-statement delete-patches left the closing `"` behind
    # as a dangling stub in the host — output parsed but did not compile.
    # The token-exact body-interior replacement must keep the string whole
    # inside the final phase helper.
    test "keeps an interpolated string tail whole and compiles" do
      source = ~S"""
      defmodule M do
        defp format_relationship(foreign_key) do
          from_entity = format_entity_name(foreign_key.from_table)
          to_entity = format_entity_name(foreign_key.to_table)
          label = generate_relationship_label(foreign_key)
          "#{to_entity} ||--o{ #{from_entity} : \"#{label}\""
        end

        defp format_entity_name(x), do: x
        defp generate_relationship_label(_x), do: "rel"
      end
      """

      out = SplitPipeableResponsibilities.transform(source, [])

      # Phase 1 returns {from_entity, to_entity} — both meaningful, no
      # verb → object-only name. The final phase (the interpolated tail)
      # has no live-out and no inferable verb → the `_phase_n` fallback.
      assert out =~ "from_entity_and_to_entity"
      assert out =~ "format_relationship_phase_2"
      refute out =~ ~r/^\s*"\s*$/m
      assert_compiles(out)
    end
  end

  describe "skips — unsuffixable host names" do
    # `<fn_name>_phase_<n>` can't be appended to a `!`/`?` name:
    # `foo!_phase_1` parses as `foo!(_phase_1)`. Skip such hosts.
    test "leaves a bang-named function untouched" do
      source = """
      defmodule M do
        defp verify!(scope, parent, ids) do
          children = load(scope, parent)
          known = MapSet.new(children)
          requested = MapSet.new(ids)
          {known, requested}
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves a predicate-named function untouched" do
      source = """
      defmodule M do
        defp valid?(scope, parent, ids) do
          children = load(scope, parent)
          known = MapSet.new(children)
          requested = MapSet.new(ids)
          MapSet.subset?(requested, known)
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "rewrites — self-rebind of a parameter" do
    # `assigns = assigns |> assign(...)` reads `assigns` on the RHS before
    # rebinding it. The data-flow accounting once dropped that read (the
    # name was both written and used in one statement), so the phase that
    # owned the rebind lost `assigns` as a parameter and the output failed
    # to compile. The rebound name must flow in as a parameter.
    test "passes a self-rebound parameter into the phase that needs it" do
      source = """
      defmodule M do
        defp build(assigns) do
          ref = Map.get(assigns.a, assigns.b)
          total = Map.get(assigns.c, assigns.d)
          assigns = assign(assigns, ref: ref, total: total)
          render(assigns)
        end

        defp assign(a, _kw), do: a
        defp render(a), do: a
      end
      """

      out = SplitPipeableResponsibilities.transform(source, [])

      assert out =~ "build_phase_2(assigns,"
      assert_compiles(out)
    end
  end

  describe "phase fallback — host already carries a _block suffix" do
    # ExtractFunctionFromBlock may run first and leave a `<x>_block` host.
    # Appending `_phase_n` would double the suffix (`<x>_block_phase_n`);
    # the trailing `_block` is stripped so the fallback reads `<x>_phase_n`.
    test "a _block host phase falls back to <x>_phase_n, not <x>_block_phase_n" do
      source = """
      defmodule M do
        defp add_nodes_block(deps) do
          a = pick(deps, :a)
          b = pick(deps, :b)
          c = combine(a, b)
          d = combine(c, a)
          assemble(a, b, c, d)
        end
      end
      """

      out = SplitPipeableResponsibilities.transform(source, [])

      assert out =~ "add_nodes_phase_2"
      refute out =~ "add_nodes_block_phase"
    end
  end
end
