defmodule Number42.Refactors.Ex.PushParamIntoCalleeTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.PushParamIntoCallee

  @subject PushParamIntoCallee

  # PushParamIntoCallee is enabled by default and takes no enable gate.
  # `@on` is the empty opts list; the rewrite is driven by opts[:prepared]
  # (the cross-file plan), not by an `enabled` flag.
  @on []

  # Cross-file context: prepare/1 scans every input source, finds every
  # call site of each private callee, and proves every caller passes the
  # identical pure, context-free, callee-resolvable expression at the
  # same position. The plan is keyed per module; transform/2 looks it up.
  # Tests feed that context via opts[:prepared] — same shape the engine
  # produces from prepare/1.
  defp prepared(sources), do: PushParamIntoCallee.build_plan(sources)
  defp prepared_public(sources), do: PushParamIntoCallee.build_plan(sources, public: true)

  describe "enabled by default" do
    test "rewrites with a plan and no enable opt" do
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

    test "with no plan it is a no-op (nothing prepared)" do
      src = """
      defmodule MyApp.Worker do
        def run(a), do: process(a, 42)
        defp process(data, factor), do: data * factor
      end
      """

      assert_unchanged(@subject, src, [])
    end
  end

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
      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
    end

    # Regression (position-db dogfood): a leading comment on the callee
    # was duplicated — `render/1` re-emitted the comment that the patch
    # range (get_range/1) already leaves in place. The comment must
    # survive exactly once.
    test "a leading comment on the callee is not duplicated" do
      src = """
      defmodule MyApp.Commented do
        def a(p), do: build(p, :original)
        def b(p), do: build(p, :original)

        # Builds the storage path for an asset.
        defp build(path, version), do: "\#{path}/\#{version}"
      end
      """

      expected = """
      defmodule MyApp.Commented do
        def a(p), do: build(p)
        def b(p), do: build(p)

        # Builds the storage path for an asset.
        defp build(path), do: "\#{path}/\#{:original}"
      end
      """

      plan = prepared([{"commented.ex", src}])
      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
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
      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
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
      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
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
      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
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
      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
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

      assert_rewrites(@subject, file_a, expected_a, @on ++ [prepared: plan])
      assert_rewrites(@subject, file_b, expected_b, @on ++ [prepared: plan])
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
      assert_idempotent(@subject, src, @on ++ [prepared: plan])
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
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
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
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
    end

    # Regression (position-db dogfood): the callee rebinds the param
    # (`s = s / 100`). Substituting the pushed literal for every `s`
    # produced `55 = 55 / 100` (a MatchError) and `c = ... * 55` instead
    # of the divided value. A rebound param is a write target, not a pure
    # read — decline the whole candidate.
    test "param rebound inside the callee body is left untouched" do
      src = """
      defmodule MyApp.Rebind do
        def a(h), do: hsl(h, 55)
        def b(h), do: hsl(h, 55)

        defp hsl(h, s) do
          s = s / 100
          h * s
        end
      end
      """

      plan = prepared([{"rebind.ex", src}])
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
    end

    # Regression (position-db dogfood): the param is used as a pin target
    # (`^left`). Substituting a literal yields `^:i` — pinning a literal,
    # which is invalid. Decline.
    test "param used as a pin target inside the callee is left untouched" do
      src = """
      defmodule MyApp.Pin do
        def a, do: build(:i, [1])
        def b, do: build(:i, [2])

        defp build(left, xs) do
          Enum.map(xs, fn x -> match?(^left, x) end)
        end
      end
      """

      plan = prepared([{"pin.ex", src}])
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
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
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
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
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
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
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
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
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
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
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
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
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
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
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
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
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
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
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
    end

    test "no call sites at all (dead-ish helper) is left alone" do
      src = """
      defmodule MyApp.Unused do
        defp process(data, n), do: data + n
      end
      """

      plan = prepared([{"unused.ex", src}])
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
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
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
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
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
    end
  end

  # In `public: true` mode a public `def` callee is rewritten to the new
  # arity *and* a backward-compat wrapper at the old arity is injected, so
  # external callers outside the corpus keep compiling. `defp` behaviour is
  # unchanged; without `public: true` a `def` is still never touched.
  describe "public def with backward-compat wrapper" do
    test "public def: param dropped, value pushed, wrapper preserves old arity" do
      src = """
      defmodule MyApp.Pub do
        def run(a), do: process(a, 42)
        def run_other(b), do: process(b, 42)

        def process(data, factor), do: data * factor
      end
      """

      expected = """
      defmodule MyApp.Pub do
        def run(a), do: process(a)
        def run_other(b), do: process(b)

        def process(data), do: data * 42
        def process(a0, _), do: process(a0)
      end
      """

      plan = prepared_public([{"pub.ex", src}])
      actual = apply_refactor(@subject, src, @on ++ [prepared: plan])

      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
      assert_compiles(actual)
      assert ungrouped_clauses(actual) == []
    end

    test "public def: dropped param at position 0, wrapper underscores it" do
      src = """
      defmodule MyApp.PubFront do
        def a(x), do: wrap(:tag, x)
        def b(y), do: wrap(:tag, y)

        def wrap(label, val), do: {label, val}
      end
      """

      expected = """
      defmodule MyApp.PubFront do
        def a(x), do: wrap(x)
        def b(y), do: wrap(y)

        def wrap(val), do: {:tag, val}
        def wrap(_, a1), do: wrap(a1)
      end
      """

      plan = prepared_public([{"pubfront.ex", src}])
      actual = apply_refactor(@subject, src, @on ++ [prepared: plan])

      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
      assert_compiles(actual)
    end

    test "public multi-clause def: wrapper appended after the last clause, clauses grouped" do
      src = """
      defmodule MyApp.PubMulti do
        def a, do: pick(:x, 7)
        def b, do: pick(:y, 7)

        def pick(:x, n), do: n + 1
        def pick(other, m), do: {other, m}
      end
      """

      expected = """
      defmodule MyApp.PubMulti do
        def a, do: pick(:x)
        def b, do: pick(:y)

        def pick(:x), do: 7 + 1
        def pick(other), do: {other, 7}
        def pick(a0, _), do: pick(a0)
      end
      """

      plan = prepared_public([{"pubmulti.ex", src}])
      actual = apply_refactor(@subject, src, @on ++ [prepared: plan])

      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
      assert_compiles(actual)
      assert ungrouped_clauses(actual) == []
    end

    test "public def: dropping the sole param forwards to arity 0" do
      src = """
      defmodule MyApp.PubSole do
        def a, do: greet("hi")
        def b, do: greet("hi")

        def greet(msg), do: String.upcase(msg)
      end
      """

      # Sourceror renders the zero-arg head as `greet()`; `mix format`
      # (reformat_after?) drops the parens. We compare raw refactor output.
      expected = """
      defmodule MyApp.PubSole do
        def a, do: greet()
        def b, do: greet()

        def greet(), do: String.upcase("hi")
        def greet(_), do: greet()
      end
      """

      plan = prepared_public([{"pubsole.ex", src}])
      actual = apply_refactor(@subject, src, @on ++ [prepared: plan])

      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
      assert_compiles(actual)
      assert ungrouped_clauses(actual) == []
    end

    test "public def is idempotent: second pass leaves the wrapper alone" do
      src = """
      defmodule MyApp.Pub do
        def run(a), do: process(a, 42)
        def run_other(b), do: process(b, 42)

        def process(data, factor), do: data * factor
      end
      """

      plan = prepared_public([{"pub.ex", src}])
      assert_idempotent(@subject, src, @on ++ [prepared: plan])
    end

    test "public def left alone when public: false (default)" do
      src = """
      defmodule MyApp.Pub do
        def run(a), do: process(a, 42)
        def run_other(b), do: process(b, 42)

        def process(data, factor), do: data * factor
      end
      """

      plan = prepared([{"pub.ex", src}])
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
    end

    test "public def with an existing lower arity collision is left alone" do
      src = """
      defmodule MyApp.PubArity do
        def a(x), do: process(x, 5)
        def b(y), do: process(y, 5)

        def process(data, n), do: data + n
        def process(data), do: data
      end
      """

      plan = prepared_public([{"pubarity.ex", src}])
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
    end

    test "private defp gets no wrapper even in public: true mode" do
      src = """
      defmodule MyApp.Mixed do
        def run(a), do: process(a, 42)
        def run_other(b), do: process(b, 42)

        defp process(data, factor), do: data * factor
      end
      """

      expected = """
      defmodule MyApp.Mixed do
        def run(a), do: process(a)
        def run_other(b), do: process(b)

        defp process(data), do: data * 42
      end
      """

      plan = prepared_public([{"mixed.ex", src}])
      actual = apply_refactor(@subject, src, @on ++ [prepared: plan])

      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
      assert_compiles(actual)
    end
  end
end
