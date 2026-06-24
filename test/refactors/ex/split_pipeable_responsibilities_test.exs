defmodule Number42.Refactors.Ex.SplitPipeableResponsibilitiesTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.SplitPipeableResponsibilities

  @subject SplitPipeableResponsibilities

  # SplitPipeableResponsibilities is default-OFF: transform/2 is a no-op
  # unless its own opts carry `enabled: true`. Every behaviour test passes
  # `@on` so it exercises the enabled refactor; the default-OFF gate has
  # its own dedicated test.
  @on [enabled: true]

  describe "default-OFF (opt-in only)" do
    test "without enabled: true, transform is a no-op" do
      source = """
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

      assert apply_refactor(@subject, source) == source
    end
  end

  describe "naming gate — derive or decline (#375)" do
    # There is no `<fn>_phase_n` placeholder fallback. A split is emitted
    # only if EVERY phase — including the final tail phase — earns a
    # meaningful name from what it does and produces. A tail phase has no
    # live-out (its value is the return) and so rarely yields a verb+object
    # name; in practice that makes the refactor decline most bodies rather
    # than ship a `report_phase_3`-style placeholder chain. That is the
    # intended behaviour: a partition no one can fully name reads better as
    # the original straight-line body.
    test "an abstract-call body is declined (no _phase_n placeholder)" do
      before_source = """
      defmodule M do
        def report(order) do
          a = f(order)
          b = g(a)
          c = h(b)
          d = i(c)
          e = j(d)
          last(e)
        end
      end
      """

      out = apply_refactor(@subject, before_source, @on ++ [min_phases: 2])
      assert out == before_source
      refute out =~ ~r/_phase_\d+/
    end

    test "a body with a non-nameable tail phase is declined (no placeholder tail)" do
      # Phase 1 computes `totals` (nameable: `compute_totals`), but the tail
      # phase has no live-out and no inferable verb+object — it would need a
      # `report_phase_2` placeholder, so the whole split is declined.
      before_source = """
      defmodule M do
        def report(order) do
          lines = Enum.map(order, & &1.amount)
          totals = Enum.sum(lines)
          formatted = to_string(totals)
          labelled = "total: " <> formatted
          String.upcase(labelled)
        end
      end
      """

      out = apply_refactor(@subject, before_source, @on ++ [min_phases: 2])
      assert out == before_source
      refute out =~ ~r/_phase_\d+/
    end
  end

  describe "min_phases floor" do
    @floor_body """
    defmodule M do
      def report(order) do
        lines = Enum.map(order, & &1.amount)
        totals = Enum.sum(lines)
        formatted = to_string(totals)
        labelled = "total: " <> formatted
        String.upcase(labelled)
      end
    end
    """

    test "a body below the default floor of 3 phases is left untouched" do
      assert_unchanged(@subject, @floor_body, @on)
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

      assert_unchanged(@subject, source, @on)
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

      assert_unchanged(@subject, source, @on)
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

      assert_unchanged(@subject, source, @on)
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

      assert_unchanged(@subject, source, @on)
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

      assert_unchanged(@subject, source, @on)
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

      assert_unchanged(@subject, source, @on)
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

      assert_unchanged(@subject, source, @on)
    end
  end

  describe "naming gate — no placeholder, no nested re-split" do
    test "an abstract-call six-statement body is declined (no _phase_n placeholder)" do
      # Each phase would infer no verb and bind no nameable object, so the
      # only available name was the old `run_phase_n` placeholder. With no
      # fallback (#375) the whole split is declined — and because the
      # `_phase_n` name can never be emitted, the `run_phase_2_phase_1`
      # nested re-split it used to risk is now structurally impossible.
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

      out = apply_refactor(@subject, source, @on)
      assert out == source
      refute out =~ ~r/_phase_\d+/
    end

    test "applying transform twice equals applying it once (fixpoint)" do
      # A nameable body: every phase earns a verb_object name; a re-run finds
      # the host is now a pipe chain and the helpers are already minimal.
      source = """
      defmodule M do
        def run(order) do
          lines = Enum.map(order, & &1.amount)
          totals = Enum.sum(lines)
          formatted = to_string(totals)
          labelled = "x: " <> formatted
          String.upcase(labelled)
        end
      end
      """

      once = SplitPipeableResponsibilities.transform(source, @on ++ [min_phases: 2])

      assert_idempotent(@subject, source, @on ++ [min_phases: 2])
      refute once =~ ~r/_phase_\d+/
    end
  end

  describe "idempotence — fan-in bodies" do
    # A fan-in body (independent bindings all feeding one tail) with
    # abstract `pick`/`load` calls infers no verb for any phase → declined.
    # Because the `_phase_n` placeholder can never be emitted, the
    # `_phase_2_phase_2` cascade this once guarded is structurally
    # impossible, and the body is a trivial fixpoint (unchanged).
    test "an abstract fan-in body is declined and is a trivial fixpoint" do
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

      opts = @on ++ [min_phases: 2]
      out = SplitPipeableResponsibilities.transform(source, opts)
      assert out == source
      refute out =~ ~r/_phase_\d+/
      assert_idempotent(@subject, source, opts)
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

      assert_unchanged(@subject, already_split, @on)
    end
  end

  describe "naming gate — non-nameable tail declines (#375)" do
    # This body once split (its interpolated-string tail exercised a
    # token-exact body-range regression). Its tail phase — the interpolated
    # string — has no live-out and no inferable verb+object, so under the
    # derive-or-decline policy the whole split is declined rather than
    # shipping a `format_relationship_phase_2` placeholder tail.
    test "an interpolated-string-tail body is declined (no placeholder tail)" do
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

      out = SplitPipeableResponsibilities.transform(source, @on ++ [min_phases: 2])
      assert out == source
      refute out =~ ~r/_phase_\d+/
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

      assert_unchanged(@subject, source, @on)
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

      assert_unchanged(@subject, source, @on)
    end
  end

  describe "naming gate — self-rebound parameter body declines (#375)" do
    # `assigns = assign(assigns, ...)` reads `assigns` before rebinding it
    # (a data-flow subtlety). With abstract `Map.get`/`assign`/`render`
    # calls no phase is nameable, so the body is declined rather than split
    # into placeholder phases.
    test "a self-rebound-parameter body with abstract calls is declined" do
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

      out = SplitPipeableResponsibilities.transform(source, @on ++ [min_phases: 2])
      assert out == source
      refute out =~ ~r/_phase_\d+/
    end
  end
end
