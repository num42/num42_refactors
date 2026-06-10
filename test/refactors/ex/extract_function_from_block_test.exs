defmodule Number42.Refactors.Ex.ExtractFunctionFromBlockTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractFunctionFromBlock

  @subject ExtractFunctionFromBlock

  # ExtractFunctionFromBlock is default-OFF: transform/2 is a no-op unless
  # its own opts carry `enabled: true`. Every behaviour test below passes
  # `@on` as the trailing opts so it exercises the enabled refactor; the
  # default-OFF gate has its own dedicated test.
  @on [enabled: true]

  describe "default-OFF (opt-in only)" do
    test "without enabled: true, transform is a no-op" do
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

      assert apply_refactor(@subject, source) == source
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

    # A trailing `!`/`?` is only legal as the final character of an
    # identifier. When the live-out names are too terse to name the
    # helper (`a`, `b`), the fallback derives from the host name —
    # `verify!` + `_block` must become `verify_block!`, not the
    # unparseable `verify!_block`.
    test "keeps a trailing bang at the end of the fallback helper name" do
      before_source = """
      defmodule M do
        defp verify!(scope, ids) do
          a = load(scope)
          b = build(ids)
          compare(a, b)
        end
      end
      """

      after_source = """
      defmodule M do
        defp verify!(scope, ids) do
          {a, b} = verify_block!(scope, ids)
          compare(a, b)
        end

        defp verify_block!(scope, ids) do
          a = load(scope)
          b = build(ids)
          {a, b}
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

    # `a_and_b` would otherwise be the name; if a parameter is literally
    # named `a_and_b` the helper call would shadow it, so the fallback
    # `<fn>_block` is used instead.
    test "a result name colliding with a parameter falls back to <fn>_block" do
      before_source = """
      defmodule M do
        def run(source_and_formula) do
          source = first(source_and_formula)
          formula = second(source_and_formula)
          check(source, formula)
        end
      end
      """

      after_source = """
      defmodule M do
        def run(source_and_formula) do
          {source, formula} = run_block(source_and_formula)
          check(source, formula)
        end

        defp run_block(source_and_formula) do
          source = first(source_and_formula)
          formula = second(source_and_formula)
          {source, formula}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
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

    # When *every* live-out is dropped (both boolean) and no verb-object
    # name is possible, fall back to the host-derived `<fn>_block`.
    test "all-boolean live-outs with no object fall back to <fn>_block" do
      before_source = """
      defmodule M do
        defp gate(state) do
          ready? = check_ready(state)
          stale? = check_stale(state)
          decide(ready?, stale?)
        end
      end
      """

      after_source = """
      defmodule M do
        defp gate(state) do
          {ready?, stale?} = gate_block(state)
          decide(ready?, stale?)
        end

        defp gate_block(state) do
          ready? = check_ready(state)
          stale? = check_stale(state)
          {ready?, stale?}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    # Three or more live-outs would spell an `a_and_b_and_c` monster;
    # fall back to the host-derived name.
    test "three live-outs fall back to <fn>_block" do
      before_source = """
      defmodule M do
        defp build(order) do
          first = one(order)
          second = two(order)
          third = three(order)
          assemble(first, second, third)
        end
      end
      """

      after_source = """
      defmodule M do
        defp build(order) do
          {first, second, third} = build_block(order)
          assemble(first, second, third)
        end

        defp build_block(order) do
          first = one(order)
          second = two(order)
          third = three(order)
          {first, second, third}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
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
          x = g(a)
          y = h(a)
          combine(x, y, b)
        end
      end
      """

      after_source = """
      defmodule M do
        def f(a, b) do
          {x, y} = f_block(a)
          combine(x, y, b)
        end

        defp f_block(a) do
          x = g(a)
          y = h(a)
          {x, y}
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
        def scale(s, t) do
          s = s / 100
          c = s * factor(t)
          render(c, s)
        end
      end
      """

      after_source = """
      defmodule M do
        def scale(s, t) do
          {s, c} = scale_block(s, t)
          render(c, s)
        end

        defp scale_block(s, t) do
          s = s / 100
          c = s * factor(t)
          {s, c}
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
          a = compute(x)
          active? = check(a)
          cond do
            active? -> on(a)
            true -> off(a)
          end
        end
      end
      """

      after_source = """
      defmodule M do
        def f(x) do
          {a, active?} = f_block(x)

          cond do
            active? -> on(a)
            true -> off(a)
          end
        end

        defp f_block(x) do
          a = compute(x)
          active? = check(a)
          {a, active?}
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

      # A single live-out's only name *is* the bound variable; naming the
      # helper after it would shadow that variable at the call site
      # (`total = total(order)`), so a single live-out falls back to the
      # host-derived `run_block`.
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
