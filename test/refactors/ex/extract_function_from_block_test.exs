defmodule Number42.Refactors.Ex.ExtractFunctionFromBlockTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractFunctionFromBlock

  @subject ExtractFunctionFromBlock

  # ExtractFunctionFromBlock is opt-in / default-off. Every test that
  # exercises the rewrite passes `enabled: true`; a dedicated test asserts
  # the default-off behaviour.
  @on [enabled: true]

  describe "default-off" do
    test "without opt-in config the source is left untouched" do
      source = """
      defmodule M do
        def report(order) do
          subtotal = sum_lines(order)
          tax = subtotal * region_rate(order)
          total = subtotal + tax
          format(total, tax)
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "rewrites — tuple return" do
    test "extracts a multi-binding prefix with two live-out bindings into a tuple-return helper" do
      before_source = """
      defmodule M do
        def report(order) do
          subtotal = sum_lines(order)
          tax = subtotal * region_rate(order)
          total = subtotal + tax
          format(total, tax)
        end
      end
      """

      # live-out vars are returned in binding (source) order: tax is
      # bound before total, so the tuple is {tax, total}.
      after_source = """
      defmodule M do
        def report(order) do
          {tax, total} = report_block(order)
          format(total, tax)
        end

        defp report_block(order) do
          subtotal = sum_lines(order)
          tax = subtotal * region_rate(order)
          total = subtotal + tax
          {tax, total}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    # A trailing `!`/`?` is only legal as the final character of an
    # identifier. `verify!` + `_block` must become `verify_block!`, not
    # the unparseable `verify!_block`.
    test "keeps a trailing bang at the end of the generated helper name" do
      before_source = """
      defmodule M do
        defp verify!(scope, ids) do
          loaded = load(scope)
          expected = build(ids)
          compare(loaded, expected)
        end
      end
      """

      after_source = """
      defmodule M do
        defp verify!(scope, ids) do
          {loaded, expected} = verify_block!(scope, ids)
          compare(loaded, expected)
        end

        defp verify_block!(scope, ids) do
          loaded = load(scope)
          expected = build(ids)
          {loaded, expected}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "keeps a trailing question mark at the end of the generated helper name" do
      before_source = """
      defmodule M do
        defp valid?(a, b) do
          x = foo(a)
          y = bar(b)
          check(x, y)
        end
      end
      """

      after_source = """
      defmodule M do
        defp valid?(a, b) do
          {x, y} = valid_block?(a, b)
          check(x, y)
        end

        defp valid_block?(a, b) do
          x = foo(a)
          y = bar(b)
          {x, y}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end
  end

  describe "rewrites — single live-out value" do
    test "extracts a multi-binding prefix with one live-out binding into a value-return helper" do
      before_source = """
      defmodule M do
        def run(order) do
          base = fetch(order)
          total = base + surcharge(order)
          render(total)
        end
      end
      """

      after_source = """
      defmodule M do
        def run(order) do
          total = run_block(order)
          render(total)
        end

        defp run_block(order) do
          base = fetch(order)
          total = base + surcharge(order)
          total
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end
  end

  describe "skips unsafe or pointless extractions" do
    test "skips a prefix shorter than two bindings" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            a = compute(x)
            use_it(a)
          end
        end
        """,
        @on
      )
    end

    test "skips when the prefix contains a non-binding (side-effecting) statement" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            a = compute(x)
            log_it(x)
            b = derive(a)
            combine(a, b)
          end
        end
        """,
        @on
      )
    end

    test "skips when the prefix performs non-local control flow (raise)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            a = compute(x)
            b = if a == nil, do: raise("boom"), else: a
            combine(a, b)
          end
        end
        """,
        @on
      )
    end

    test "skips when no prefix binding is read after the block (no live-out)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            a = compute(x)
            b = derive(x)
            unrelated(x)
          end
        end
        """,
        @on
      )
    end

    test "skips when the prefix references a module attribute" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          @rate 0.2
          def f(x) do
            a = compute(x)
            b = a * @rate
            render(a, b)
          end
        end
        """,
        @on
      )
    end

    test "skips a single-statement body" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x), do: compute(x)
        end
        """,
        @on
      )
    end

    test "skips when the prefix is the whole body (no tail to keep)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            a = compute(x)
            b = derive(a)
          end
        end
        """,
        @on
      )
    end
  end

  describe "idempotence & compilation" do
    test "stable after one extraction" do
      assert_idempotent(
        @subject,
        """
        defmodule M do
          def report(order) do
            subtotal = sum_lines(order)
            tax = subtotal * region_rate(order)
            total = subtotal + tax
            format(total, tax)
          end
        end
        """,
        @on
      )
    end

    test "output compiles" do
      source = """
      defmodule ExtractFunctionFromBlockCompileCheck do
        def report(order) do
          subtotal = sum_lines(order)
          tax = subtotal * region_rate(order)
          total = subtotal + tax
          format(total, tax)
        end

        defp sum_lines(_), do: 1
        defp region_rate(_), do: 1
        defp format(_, _), do: :ok
      end
      """

      assert_compiles(apply_refactor(@subject, source, @on))
    end
  end
end
