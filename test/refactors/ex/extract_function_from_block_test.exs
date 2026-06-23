defmodule Number42.Refactors.Ex.ExtractFunctionFromBlockTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractFunctionFromBlock

  @subject ExtractFunctionFromBlock

  # ExtractFunctionFromBlock is enabled by default and takes no enable
  # gate; `@on` is the empty opts list, kept on the behaviour tests for
  # call-shape uniformity.
  @on []

  describe "enabled by default" do
    test "extracts with no enable opt" do
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

      after_source = """
      defmodule M do
        def report(order) do
          {tax, total} = tax_and_total(order)
          format(total, tax)
        end

        defp tax_and_total(order) do
          subtotal = sum_lines(order)
          tax = subtotal * region_rate(order)
          total = subtotal + tax
          {tax, total}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, [])
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
      # bound before total, so the tuple is {tax, total}. Both names are
      # meaningful, so the helper is named after what it produces:
      # tax_and_total.
      after_source = """
      defmodule M do
        def report(order) do
          {tax, total} = tax_and_total(order)
          format(total, tax)
        end

        defp tax_and_total(order) do
          subtotal = sum_lines(order)
          tax = subtotal * region_rate(order)
          total = subtotal + tax
          {tax, total}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    # No placeholder `<host>_block` fallback: when the live-outs (`a`/`b`,
    # `x`/`y`) name nothing meaningful, the extraction is declined rather
    # than minting `verify_block!` / `valid_block?`. A block with no
    # nameable result reads better left inline.
    test "no meaningful name from short live-outs is left inline (bang host)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp verify!(scope, ids) do
            a = load(scope)
            b = build(ids)
            compare(a, b)
          end
        end
        """,
        @on
      )
    end

    test "no meaningful name from short live-outs is left inline (question host)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp valid?(a, b) do
            x = foo(a)
            y = bar(b)
            check(x, y)
          end
        end
        """,
        @on
      )
    end
  end

  describe "helper naming — result-based" do
    # `get_field` is a fetch verb; the two meaningful live-outs are the
    # object → `fetch_source_and_formula`.
    test "verb (fetch) + object names the helper after what it does and produces" do
      before_source = """
      defmodule M do
        defp validate(changeset) do
          source = get_field(changeset, :source)
          formula = get_field(changeset, :formula)
          check(source, formula)
        end
      end
      """

      after_source = """
      defmodule M do
        defp validate(changeset) do
          {source, formula} = fetch_source_and_formula(changeset)
          check(source, formula)
        end

        defp fetch_source_and_formula(changeset) do
          source = get_field(changeset, :source)
          formula = get_field(changeset, :formula)
          {source, formula}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    # The only meaningful name (`source_and_formula`) is literally the
    # parameter, so it would shadow — and there is no placeholder fallback.
    # The extraction is declined.
    test "a result name colliding with a parameter is left inline" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def run(source_and_formula) do
            source = first(source_and_formula)
            formula = second(source_and_formula)
            check(source, formula)
          end
        end
        """,
        @on
      )
    end

    # A boolean live-out (`enabled?`) is dropped from the object — a
    # `?`/`!` is only legal as an identifier's final character. Here only
    # `timeout` survives as the object, and `Keyword.get` is a fetch verb
    # → `fetch_timeout`.
    test "a boolean (?) live-out is dropped, the remaining name carries the object" do
      before_source = """
      defmodule M do
        defp configure(opts) do
          enabled? = Keyword.get(opts, :enabled, true)
          timeout = Keyword.get(opts, :timeout, 5000)
          apply_config(enabled?, timeout)
        end
      end
      """

      after_source = """
      defmodule M do
        defp configure(opts) do
          {enabled?, timeout} = fetch_timeout(opts)
          apply_config(enabled?, timeout)
        end

        defp fetch_timeout(opts) do
          enabled? = Keyword.get(opts, :enabled, true)
          timeout = Keyword.get(opts, :timeout, 5000)
          {enabled?, timeout}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    # Every live-out is boolean (dropped from the object) and no
    # verb-object name is possible → no meaningful name → declined.
    test "all-boolean live-outs with no object are left inline" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp gate(state) do
            ready? = check_ready(state)
            stale? = check_stale(state)
            decide(ready?, stale?)
          end
        end
        """,
        @on
      )
    end

    # Three or more live-outs would spell an `a_and_b_and_c` monster and
    # there is no placeholder fallback → declined.
    test "three live-outs with no concise name are left inline" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp build(order) do
            first = one(order)
            second = two(order)
            third = three(order)
            assemble(first, second, third)
          end
        end
        """,
        @on
      )
    end
  end

  describe "free variables — only the prefix's reads become params" do
    # The prefix reads only `a`, never `b`. The helper must take `a`
    # alone — passing `b` would emit an unused-variable warning and
    # break under --warnings-as-errors.
    test "passes only the variables the prefix actually reads" do
      before_source = """
      defmodule M do
        def f(a, b) do
          header = g(a)
          footer = h(a)
          combine(header, footer, b)
        end
      end
      """

      # Helper takes only `a` (read by the prefix), not `b`. Live-outs
      # `{header, footer}` join to the standalone name `header_and_footer`.
      after_source = """
      defmodule M do
        def f(a, b) do
          {header, footer} = header_and_footer(a)
          combine(header, footer, b)
        end

        defp header_and_footer(a) do
          header = g(a)
          footer = h(a)
          {header, footer}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end
  end

  # `s` is a parameter AND re-bound in the prefix, reading itself on the
  # RHS first (`s = s / 100`). That leading read is free, so `s` must be
  # a helper parameter — a whole-block `used - bound` would cancel it
  # and emit `s = s / 100` against an undefined `s`.
  describe "free variables — parameter re-bound while reading itself" do
    test "treats a self-shadowing read as a free parameter" do
      before_source = """
      defmodule M do
        def scale(saturation, t) do
          saturation = saturation / 100
          channel = saturation * factor(t)
          render(channel, saturation)
        end
      end
      """

      # `saturation` is both a parameter and re-bound reading itself, so it
      # stays a helper parameter. Live-outs `{saturation, channel}` name the
      # helper `saturation_and_channel`.
      after_source = """
      defmodule M do
        def scale(saturation, t) do
          {saturation, channel} = saturation_and_channel(saturation, t)
          render(channel, saturation)
        end

        defp saturation_and_channel(saturation, t) do
          saturation = saturation / 100
          channel = saturation * factor(t)
          {saturation, channel}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end
  end

  # A prefix-bound name read inside a `cond` clause *test* (the LHS of
  # `->`, which is a boolean expression, not a pattern) is live-out and
  # must be returned. A naive `used - collect_bound_vars` mistakes the
  # cond test var for a binding and drops it, leaving the tail with an
  # undefined variable.
  describe "live-out — name read in a cond clause test" do
    test "returns a binding read only inside a cond condition" do
      before_source = """
      defmodule M do
        def f(x) do
          account = compute(x)
          status = check(account)
          cond do
            status -> on(account)
            true -> off(account)
          end
        end
      end
      """

      # `status` is read only in the cond clause *test* (a boolean
      # expression, not a pattern), so it is live-out and returned.
      # Live-outs `{account, status}` name the helper `account_and_status`.
      after_source = """
      defmodule M do
        def f(x) do
          {account, status} = compute_account_and_status(x)

          cond do
            status -> on(account)
            true -> off(account)
          end
        end

        defp compute_account_and_status(x) do
          account = compute(x)
          status = check(account)
          {account, status}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end
  end

  # The helper is spliced in as a sibling immediately after the host
  # clause. For a multi-clause function that lands it *between* clauses,
  # which the compiler rejects ("clauses ... should be grouped
  # together"). Skip multi-clause hosts.
  describe "skips multi-clause hosts" do
    test "skips a function with more than one clause at the same arity" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(%{a: a}) do
            x = g(a)
            y = h(a)
            use(x, y)
          end

          def f(_), do: :default
        end
        """,
        @on
      )
    end
  end

  describe "skips interpolation / sigil bindings" do
    # A binding whose RHS contains string interpolation can't be moved
    # by range patches without corrupting the host body (the heredoc's
    # closing `\"\"\"` is left behind). Skip rather than break.
    test "skips when a prefix binding contains string interpolation" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def build(item, label) do
            ctx = context(item)
            text = """
            Label: #{label}
            Context: #{ctx}
            """
            send(text, ctx)
          end
        end
        ''',
        @on
      )
    end

    test "skips when a prefix binding contains a template sigil" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def render(assigns) do
            a = prep(assigns)
            markup = ~H"""
            <p>{@foo}</p>
            """
            emit(a, markup)
          end
        end
        ''',
        @on
      )
    end
  end

  describe "rewrites — single live-out value" do
    # A single live-out's only name *is* the bound variable, which would
    # shadow it at the call site (`total = total(order)`). With no
    # placeholder fallback and no verb composing onto the result, the
    # extraction is declined rather than minting `run_block`.
    test "a single live-out with no concise name is left inline" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def run(order) do
            base = fetch(order)
            total = base + surcharge(order)
            render(total)
          end
        end
        """,
        @on
      )
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
