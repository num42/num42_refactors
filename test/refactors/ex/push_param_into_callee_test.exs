defmodule Number42.Refactors.Ex.PushParamIntoCalleeTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.PushParamIntoCallee

  @subject PushParamIntoCallee

  # Cross-file context: prepare/1 scans every input source, finds every
  # call site of each private callee, and proves every caller passes the
  # identical pure, context-free, callee-resolvable expression at the
  # same position. The plan is keyed per module; transform/2 looks it up.
  # Tests feed that context via opts[:prepared] — same shape the engine
  # produces from prepare/1.
  defp prepared(sources), do: PushParamIntoCallee.build_plan(sources)

  describe "rewrites" do
    test "every caller passes the same literal: param dropped, value pushed into callee" do
      src = """
      defmodule MyApp.Worker do
        def run(a), do: process(a, 42)
        def run_other(b), do: process(b, 42)

        defp process(data, factor), do: data * factor
      end
      """

      expected = """
      defmodule MyApp.Worker do
        def run(a), do: process(a)
        def run_other(b), do: process(b)

        defp process(data), do: data * 42
      end
      """

      plan = prepared([{"worker.ex", src}])
      assert_rewrites(@subject, src, expected, prepared: plan)
    end

    test "param used multiple times in body: every occurrence substituted" do
      src = """
      defmodule MyApp.Calc do
        def a(x), do: scale(x, 2)
        def b(y), do: scale(y, 2)

        defp scale(v, n), do: v * n + n
      end
      """

      expected = """
      defmodule MyApp.Calc do
        def a(x), do: scale(x)
        def b(y), do: scale(y)

        defp scale(v), do: v * 2 + 2
      end
      """

      plan = prepared([{"calc.ex", src}])
      assert_rewrites(@subject, src, expected, prepared: plan)
    end

    test "stdlib pure call with literal args is eligible" do
      src = """
      defmodule MyApp.Greeter do
        def hi, do: build("a", String.upcase("x"))
        def ho, do: build("b", String.upcase("x"))

        defp build(name, suffix), do: name <> suffix
      end
      """

      expected = """
      defmodule MyApp.Greeter do
        def hi, do: build("a")
        def ho, do: build("b")

        defp build(name), do: name <> String.upcase("x")
      end
      """

      plan = prepared([{"greeter.ex", src}])
      assert_rewrites(@subject, src, expected, prepared: plan)
    end

    test "dropped param at position 0 still works" do
      src = """
      defmodule MyApp.Front do
        def a(x), do: wrap(:tag, x)
        def b(y), do: wrap(:tag, y)

        defp wrap(label, val), do: {label, val}
      end
      """

      expected = """
      defmodule MyApp.Front do
        def a(x), do: wrap(x)
        def b(y), do: wrap(y)

        defp wrap(val), do: {:tag, val}
      end
      """

      plan = prepared([{"front.ex", src}])
      assert_rewrites(@subject, src, expected, prepared: plan)
    end

    test "multi-clause callee: param dropped from every clause, var substituted per clause" do
      src = """
      defmodule MyApp.Multi do
        def a, do: pick(:x, 7)
        def b, do: pick(:y, 7)

        defp pick(:x, n), do: n + 1
        defp pick(other, m), do: {other, m}
      end
      """

      expected = """
      defmodule MyApp.Multi do
        def a, do: pick(:x)
        def b, do: pick(:y)

        defp pick(:x), do: 7 + 1
        defp pick(other), do: {other, 7}
      end
      """

      plan = prepared([{"multi.ex", src}])
      assert_rewrites(@subject, src, expected, prepared: plan)
    end

    test "callee reopened across two files: callers in both files are rewritten" do
      file_a = """
      defmodule MyApp.Split do
        def a(x), do: tag(x, :z)

        defp tag(v, label), do: {v, label}
      end
      """

      file_b = """
      defmodule MyApp.Split do
        def b(y), do: tag(y, :z)
      end
      """

      plan = prepared([{"a.ex", file_a}, {"b.ex", file_b}])

      expected_a = """
      defmodule MyApp.Split do
        def a(x), do: tag(x)

        defp tag(v), do: {v, :z}
      end
      """

      expected_b = """
      defmodule MyApp.Split do
        def b(y), do: tag(y)
      end
      """

      assert_rewrites(@subject, file_a, expected_a, prepared: plan)
      assert_rewrites(@subject, file_b, expected_b, prepared: plan)
    end
  end

  describe "idempotency" do
    test "second pass is a no-op (dropped param leaves no uniform arg)" do
      src = """
      defmodule MyApp.Worker do
        def run(a), do: process(a, 42)
        def run_other(b), do: process(b, 42)

        defp process(data, factor), do: data * factor
      end
      """

      plan = prepared([{"worker.ex", src}])
      assert_idempotent(@subject, src, prepared: plan)
    end
  end

  describe "skips" do
    test "callers disagree on the value" do
      src = """
      defmodule MyApp.Mixed do
        def a(x), do: process(x, 1)
        def b(y), do: process(y, 2)

        defp process(data, n), do: data + n
      end
      """

      plan = prepared([{"mixed.ex", src}])
      assert_unchanged(@subject, src, prepared: plan)
    end

    test "call-site-local variable in the argument" do
      src = """
      defmodule MyApp.LocalVar do
        def a(x, cfg), do: process(x, cfg)
        def b(y, cfg), do: process(y, cfg)

        defp process(data, c), do: data + c
      end
      """

      plan = prepared([{"localvar.ex", src}])
      assert_unchanged(@subject, src, prepared: plan)
    end

    test "impure argument expression" do
      src = """
      defmodule MyApp.Impure do
        def a(x), do: process(x, DateTime.utc_now())
        def b(y), do: process(y, DateTime.utc_now())

        defp process(data, t), do: {data, t}
      end
      """

      plan = prepared([{"impure.ex", src}])
      assert_unchanged(@subject, src, prepared: plan)
    end

    test "module attribute in the argument (per-module, not callee-resolvable)" do
      src = """
      defmodule MyApp.Attr do
        @factor 3
        def a(x), do: process(x, @factor)
        def b(y), do: process(y, @factor)

        defp process(data, f), do: data * f
      end
      """

      plan = prepared([{"attr.ex", src}])
      assert_unchanged(@subject, src, prepared: plan)
    end

    test "__MODULE__ in the argument (resolves differently per module)" do
      src = """
      defmodule MyApp.Mod do
        def a(x), do: process(x, __MODULE__)
        def b(y), do: process(y, __MODULE__)

        defp process(data, m), do: {data, m}
      end
      """

      plan = prepared([{"mod.ex", src}])
      assert_unchanged(@subject, src, prepared: plan)
    end

    test "default argument in the callee head" do
      src = """
      defmodule MyApp.Defaults do
        def a(x), do: process(x, 9)
        def b(y), do: process(y, 9)

        defp process(data, n \\\\ 0), do: data + n
      end
      """

      plan = prepared([{"defaults.ex", src}])
      assert_unchanged(@subject, src, prepared: plan)
    end

    test "capture of the callee (&fun/arity) anywhere in the corpus" do
      src = """
      defmodule MyApp.Capture do
        def a(x), do: process(x, 5)
        def b(list), do: Enum.map(list, &process(&1, 5))

        defp process(data, n), do: data + n
      end
      """

      plan = prepared([{"capture.ex", src}])
      assert_unchanged(@subject, src, prepared: plan)
    end

    test "apply/3 dispatch to the callee" do
      src = """
      defmodule MyApp.Apply do
        def a(x), do: process(x, 5)
        def b(y), do: apply(__MODULE__, :process, [y, 5])

        defp process(data, n), do: data + n
      end
      """

      plan = prepared([{"apply.ex", src}])
      assert_unchanged(@subject, src, prepared: plan)
    end

    test "public function (def) is never touched — external callers unknown" do
      src = """
      defmodule MyApp.Pub do
        def a(x), do: process(x, 7)
        def b(y), do: process(y, 7)

        def process(data, n), do: data + n
      end
      """

      plan = prepared([{"pub.ex", src}])
      assert_unchanged(@subject, src, prepared: plan)
    end

    test "callee param is pattern-matched, not a plain var" do
      src = """
      defmodule MyApp.Pattern do
        def a(x), do: process(x, %{k: 1})
        def b(y), do: process(y, %{k: 1})

        defp process(data, %{k: v}), do: data + v
      end
      """

      plan = prepared([{"pattern.ex", src}])
      assert_unchanged(@subject, src, prepared: plan)
    end

    test "a call site passing a non-uniform extra arity is left alone" do
      src = """
      defmodule MyApp.Arity do
        def a(x), do: process(x, 5)
        def b(y), do: process(y)

        defp process(data, n), do: data + n
        defp process(data), do: data
      end
      """

      plan = prepared([{"arity.ex", src}])
      assert_unchanged(@subject, src, prepared: plan)
    end

    test "no call sites at all (dead-ish helper) is left alone" do
      src = """
      defmodule MyApp.Unused do
        defp process(data, n), do: data + n
      end
      """

      plan = prepared([{"unused.ex", src}])
      assert_unchanged(@subject, src, prepared: plan)
    end

    test "pipe into callee is skipped (position math hazard)" do
      src = """
      defmodule MyApp.Piped do
        def a(x), do: x |> process(5)
        def b(y), do: y |> process(5)

        defp process(data, n), do: data + n
      end
      """

      plan = prepared([{"piped.ex", src}])
      assert_unchanged(@subject, src, prepared: plan)
    end

    test "callee param is referenced in a guard" do
      src = """
      defmodule MyApp.Guarded do
        def a(x), do: process(x, 5)
        def b(y), do: process(y, 5)

        defp process(data, n) when n > 0, do: data + n
      end
      """

      plan = prepared([{"guarded.ex", src}])
      assert_unchanged(@subject, src, prepared: plan)
    end
  end
end
