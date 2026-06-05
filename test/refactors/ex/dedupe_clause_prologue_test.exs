defmodule Number42.Refactors.Ex.DedupeClausePrologueTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.DedupeClausePrologue

  @subject DedupeClausePrologue

  describe "rewrites — shared prologue lifted, clauses dispatched" do
    test "two clauses with an identical two-statement prologue" do
      before_source = """
      defmodule M do
        def handle(:a, x) do
          log(x)
          check(x)
          do_a(x)
        end

        def handle(:b, x) do
          log(x)
          check(x)
          do_b(x)
        end
      end
      """

      # The shared prologue runs once in a generic clause; the divergent
      # tails move to a dispatch defp that re-matches the original heads.
      after_source = """
      defmodule M do
        def handle(arg1, x) do
          log(x)
          check(x)
          handle_dispatch(arg1, x)
        end

        defp handle_dispatch(:a, x) do
          do_a(x)
        end

        defp handle_dispatch(:b, x) do
          do_b(x)
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "prologue may read a parameter bound identically in every clause" do
      before_source = """
      defmodule M do
        def run(:x, conn) do
          assign(conn, :step, 1)
          authorize(conn)
          step_x(conn)
        end

        def run(:y, conn) do
          assign(conn, :step, 1)
          authorize(conn)
          step_y(conn)
        end
      end
      """

      after_source = """
      defmodule M do
        def run(arg1, conn) do
          assign(conn, :step, 1)
          authorize(conn)
          run_dispatch(arg1, conn)
        end

        defp run_dispatch(:x, conn) do
          step_x(conn)
        end

        defp run_dispatch(:y, conn) do
          step_y(conn)
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "skips — guards preserved" do
    test "carries clause guards onto the dispatch helper" do
      before_source = """
      defmodule M do
        def pick(n, acc) when n > 0 do
          log(acc)
          note(acc)
          big(n, acc)
        end

        def pick(n, acc) when n <= 0 do
          log(acc)
          note(acc)
          small(n, acc)
        end
      end
      """

      after_source = """
      defmodule M do
        def pick(n, acc) do
          log(acc)
          note(acc)
          pick_dispatch(n, acc)
        end

        defp pick_dispatch(n, acc) when n > 0 do
          big(n, acc)
        end

        defp pick_dispatch(n, acc) when n <= 0 do
          small(n, acc)
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "skips" do
    test "leaves clauses with a one-statement prologue untouched (below default min)" do
      source = """
      defmodule M do
        def handle(:a, x) do
          log(x)
          do_a(x)
        end

        def handle(:b, x) do
          log(x)
          do_b(x)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves clauses whose prologues differ untouched" do
      source = """
      defmodule M do
        def handle(:a, x) do
          log(x)
          check(x)
          do_a(x)
        end

        def handle(:b, x) do
          log(x)
          verify(x)
          do_b(x)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves a single-clause function untouched" do
      source = """
      defmodule M do
        def handle(:a, x) do
          log(x)
          check(x)
          do_a(x)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves clauses with no divergent tail untouched (whole body identical)" do
      source = """
      defmodule M do
        def handle(:a, x) do
          log(x)
          check(x)
        end

        def handle(:b, x) do
          log(x)
          check(x)
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "idempotence" do
    test "a second pass over already-deduped output is a no-op" do
      already_deduped = """
      defmodule M do
        def handle(arg1, x) do
          log(x)
          check(x)
          handle_dispatch(arg1, x)
        end

        defp handle_dispatch(:a, x) do
          do_a(x)
        end

        defp handle_dispatch(:b, x) do
          do_b(x)
        end
      end
      """

      assert_unchanged(@subject, already_deduped)
    end
  end
end
