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
end
