defmodule Number42.Refactors.Ex.SplitFlagArgumentTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.SplitFlagArgument

  @subject SplitFlagArgument

  # SplitFlagArgument is a structural refactor that rewrites call sites
  # across files — never auto-on. Every rewrite test passes `enabled:
  # true`; a dedicated test asserts the default-off no-op.
  @on [enabled: true]

  # Cross-file context: prepare/1 scans every input source, proves the
  # flag-is-only-a-discriminant + exhaustive/exclusive branch invariant,
  # and analyses every call site for completeness. The plan is keyed per
  # module; transform/2 looks it up. Tests feed it via opts[:prepared].
  defp prepared(sources), do: SplitFlagArgument.build_plan(sources)

  describe "default-off" do
    test "without enabled: true the source is left untouched (no-op)" do
      src = """
      defmodule MyApp.View do
        def render(data, compact) do
          if compact, do: shrink(data), else: expand(data)
        end

        def shrink(d), do: {:c, d}
        def expand(d), do: {:f, d}

        def a(x), do: render(x, true)
        def b(x), do: render(x, false)
      end
      """

      plan = prepared([{"view.ex", src}])
      # plan-present but enabled flag absent → still a no-op.
      assert_unchanged(@subject, src, prepared: plan)
    end
  end

  describe "bool flag, all call sites literal — splits without dispatcher" do
    test "if/else on a bare-var flag splits into two named functions" do
      src = """
      defmodule MyApp.View do
        def render(data, compact) do
          if compact, do: shrink(data), else: expand(data)
        end

        def shrink(d), do: {:c, d}
        def expand(d), do: {:f, d}

        def a(x), do: render(x, true)
        def b(x), do: render(x, false)
      end
      """

      expected = """
      defmodule MyApp.View do
        def render_shrink(data) do
          shrink(data)
        end

        def render_expand(data) do
          expand(data)
        end

        def shrink(d), do: {:c, d}
        def expand(d), do: {:f, d}

        def a(x), do: render_shrink(x)
        def b(x), do: render_expand(x)
      end
      """

      plan = prepared([{"view.ex", src}])
      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
      assert_compiles(apply_refactor(@subject, src, @on ++ [prepared: plan]))
    end

    test "case true/false on a bare-var flag splits and drops the dispatcher" do
      src = """
      defmodule MyApp.Fmt do
        def show(v, terse) do
          case terse do
            true -> brief(v)
            false -> verbose(v)
          end
        end

        def brief(v), do: {:b, v}
        def verbose(v), do: {:v, v}

        def a, do: show(1, true)
        def b, do: show(2, false)
      end
      """

      expected = """
      defmodule MyApp.Fmt do
        def show_brief(v) do
          brief(v)
        end

        def show_verbose(v) do
          verbose(v)
        end

        def brief(v), do: {:b, v}
        def verbose(v), do: {:v, v}

        def a, do: show_brief(1)
        def b, do: show_verbose(2)
      end
      """

      plan = prepared([{"fmt.ex", src}])
      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
      assert_compiles(apply_refactor(@subject, src, @on ++ [prepared: plan]))
    end
  end

  describe "bool flag, mixed sites — splits PLUS retained dispatcher" do
    test "a dynamic call site keeps the original as a dispatcher" do
      src = """
      defmodule MyApp.View do
        def render(data, compact) do
          if compact, do: shrink(data), else: expand(data)
        end

        def shrink(d), do: {:c, d}
        def expand(d), do: {:f, d}

        def a(x), do: render(x, true)
        def b(x, pref), do: render(x, pref)
      end
      """

      expected = """
      defmodule MyApp.View do
        def render(data, compact) do
          case compact do
            true -> render_shrink(data)
            false -> render_expand(data)
          end
        end

        def render_shrink(data) do
          shrink(data)
        end

        def render_expand(data) do
          expand(data)
        end

        def shrink(d), do: {:c, d}
        def expand(d), do: {:f, d}

        def a(x), do: render_shrink(x)
        def b(x, pref), do: render(x, pref)
      end
      """

      plan = prepared([{"view.ex", src}])
      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
      assert_compiles(apply_refactor(@subject, src, @on ++ [prepared: plan]))
    end

    test "a capture &render/2 keeps the dispatcher and is left intact" do
      src = """
      defmodule MyApp.View do
        def render(data, compact) do
          if compact, do: shrink(data), else: expand(data)
        end

        def shrink(d), do: {:c, d}
        def expand(d), do: {:f, d}

        def a(x), do: render(x, true)
        def b(list), do: Enum.map(list, &render(&1, true))
        def c, do: pass(&render/2)
        def pass(f), do: f
      end
      """

      out = apply_refactor(@subject, src, @on ++ [prepared: prepared([{"view.ex", src}])])

      # Dispatcher retained (capture pins arity/2), splits present, the
      # literal direct site rewritten, the capture left untouched.
      assert out =~ "def render(data, compact)"
      assert out =~ "def render_shrink(data)"
      assert out =~ "def render_expand(data)"
      assert out =~ "render_shrink(x)"
      assert out =~ "&render/2"
      assert_compiles(out)
    end

    test "apply/3 naming the flag function keeps the dispatcher" do
      src = """
      defmodule MyApp.View do
        def render(data, compact) do
          if compact, do: shrink(data), else: expand(data)
        end

        def shrink(d), do: {:c, d}
        def expand(d), do: {:f, d}

        def a(x), do: render(x, true)
        def b(x), do: apply(__MODULE__, :render, [x, false])
      end
      """

      out = apply_refactor(@subject, src, @on ++ [prepared: prepared([{"view.ex", src}])])

      assert out =~ "def render(data, compact)"
      assert out =~ "render_shrink(x)"
      assert out =~ "apply(__MODULE__, :render, [x, false])"
      assert_compiles(out)
    end
  end

  describe "default arguments" do
    test "default-implied call site render(x) routes to the false-branch split" do
      src = """
      defmodule MyApp.View do
        def render(data, compact \\\\ false) do
          if compact, do: shrink(data), else: expand(data)
        end

        def shrink(d), do: {:c, d}
        def expand(d), do: {:f, d}

        def a(x), do: render(x, true)
        def b(x), do: render(x)
      end
      """

      expected = """
      defmodule MyApp.View do
        def render_shrink(data) do
          shrink(data)
        end

        def render_expand(data) do
          expand(data)
        end

        def shrink(d), do: {:c, d}
        def expand(d), do: {:f, d}

        def a(x), do: render_shrink(x)
        def b(x), do: render_expand(x)
      end
      """

      plan = prepared([{"view.ex", src}])
      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
      assert_compiles(apply_refactor(@subject, src, @on ++ [prepared: plan]))
    end
  end

  describe "small-enum flag (3 atoms)" do
    test "case over three atoms splits into three named functions" do
      src = """
      defmodule MyApp.Doc do
        def emit(v, fmt) do
          case fmt do
            :json -> to_json(v)
            :xml -> to_xml(v)
            :csv -> to_csv(v)
          end
        end

        def to_json(v), do: {:j, v}
        def to_xml(v), do: {:x, v}
        def to_csv(v), do: {:c, v}

        def a(v), do: emit(v, :json)
        def b(v), do: emit(v, :xml)
        def c(v), do: emit(v, :csv)
      end
      """

      expected = """
      defmodule MyApp.Doc do
        def emit_json(v) do
          to_json(v)
        end

        def emit_xml(v) do
          to_xml(v)
        end

        def emit_csv(v) do
          to_csv(v)
        end

        def to_json(v), do: {:j, v}
        def to_xml(v), do: {:x, v}
        def to_csv(v), do: {:c, v}

        def a(v), do: emit_json(v)
        def b(v), do: emit_xml(v)
        def c(v), do: emit_csv(v)
      end
      """

      plan = prepared([{"doc.ex", src}])
      assert_rewrites(@subject, src, expected, @on ++ [prepared: plan])
      assert_compiles(apply_refactor(@subject, src, @on ++ [prepared: plan]))
    end
  end

  describe "cross-file call sites" do
    test "the flag function reopened across files: callers in both files rewritten" do
      file_a = """
      defmodule MyApp.View do
        def render(data, compact) do
          if compact, do: shrink(data), else: expand(data)
        end

        def shrink(d), do: {:c, d}
        def expand(d), do: {:f, d}
      end
      """

      file_b = """
      defmodule MyApp.View do
        def a(x), do: render(x, true)
        def b(x), do: render(x, false)
      end
      """

      plan = prepared([{"a.ex", file_a}, {"b.ex", file_b}])

      expected_a = """
      defmodule MyApp.View do
        def render_shrink(data) do
          shrink(data)
        end

        def render_expand(data) do
          expand(data)
        end

        def shrink(d), do: {:c, d}
        def expand(d), do: {:f, d}
      end
      """

      expected_b = """
      defmodule MyApp.View do
        def a(x), do: render_shrink(x)
        def b(x), do: render_expand(x)
      end
      """

      assert_rewrites(@subject, file_a, expected_a, @on ++ [prepared: plan])
      assert_rewrites(@subject, file_b, expected_b, @on ++ [prepared: plan])
    end
  end

  describe "idempotency" do
    test "second pass is a no-op (no dispatcher case)" do
      src = """
      defmodule MyApp.View do
        def render(data, compact) do
          if compact, do: shrink(data), else: expand(data)
        end

        def shrink(d), do: {:c, d}
        def expand(d), do: {:f, d}

        def a(x), do: render(x, true)
        def b(x), do: render(x, false)
      end
      """

      plan = prepared([{"view.ex", src}])
      assert_idempotent(@subject, src, @on ++ [prepared: plan])
    end

    test "second pass is a no-op (with retained dispatcher)" do
      src = """
      defmodule MyApp.View do
        def render(data, compact) do
          if compact, do: shrink(data), else: expand(data)
        end

        def shrink(d), do: {:c, d}
        def expand(d), do: {:f, d}

        def a(x), do: render(x, true)
        def b(x, pref), do: render(x, pref)
      end
      """

      plan = prepared([{"view.ex", src}])
      assert_idempotent(@subject, src, @on ++ [prepared: plan])
    end
  end

  describe "leaves alone" do
    test "flag also used inside a branch body (woven into the computation)" do
      src = """
      defmodule MyApp.M do
        def f(data, flag) do
          if flag, do: {flag, a(data)}, else: b(data)
        end

        def c(x), do: f(x, true)
      end
      """

      plan = prepared([{"m.ex", src}])
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
    end

    test "flag passed onward to another call (not solely a discriminant)" do
      src = """
      defmodule MyApp.M do
        def f(data, flag) do
          if flag, do: a(data, flag), else: b(data)
        end

        def c(x), do: f(x, true)
      end
      """

      plan = prepared([{"m.ex", src}])
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
    end

    test "non-exhaustive case: a catch-all _ arm is not a clean split" do
      src = """
      defmodule MyApp.M do
        def f(v, mode) do
          case mode do
            :a -> a(v)
            _ -> b(v)
          end
        end

        def c(x), do: f(x, :a)
      end
      """

      plan = prepared([{"m.ex", src}])
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
    end

    test "body has statements before/after the branch (not a single branch)" do
      src = """
      defmodule MyApp.M do
        def f(data, flag) do
          x = prep(data)
          if flag, do: a(x), else: b(x)
        end

        def c(d), do: f(d, true)
      end
      """

      plan = prepared([{"m.ex", src}])
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
    end

    test "discriminant is not the flag param itself (a derived expression)" do
      src = """
      defmodule MyApp.M do
        def f(data, flag) do
          if is_atom(flag), do: a(data), else: b(data)
        end

        def c(d), do: f(d, :x)
      end
      """

      plan = prepared([{"m.ex", src}])
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
    end

    test "multi-clause function is not a single-clause flag shape" do
      src = """
      defmodule MyApp.M do
        def f(0, flag), do: if(flag, do: a(), else: b())
        def f(n, flag), do: if(flag, do: c(n), else: d(n))
      end
      """

      plan = prepared([{"m.ex", src}])
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
    end

    test "flag is not the last parameter (drop would shift positions)" do
      src = """
      defmodule MyApp.M do
        def f(flag, data) do
          if flag, do: a(data), else: b(data)
        end

        def c(d), do: f(true, d)
      end
      """

      plan = prepared([{"m.ex", src}])
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
    end

    test "a derived split name collides with an existing definition" do
      src = """
      defmodule MyApp.M do
        def f(data, flag) do
          if flag, do: a(data), else: b(data)
        end

        def f_a(_x), do: :taken

        def c(d), do: f(d, true)
      end
      """

      plan = prepared([{"m.ex", src}])
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
    end
  end

  describe "no half-rewrite invariant" do
    test "dynamic-only call sites: dispatcher kept, NO call site half-renamed" do
      src = """
      defmodule MyApp.View do
        def render(data, compact) do
          if compact, do: shrink(data), else: expand(data)
        end

        def shrink(d), do: {:c, d}
        def expand(d), do: {:f, d}

        def a(x, p), do: render(x, p)
        def b(x, q), do: render(x, q)
      end
      """

      out = apply_refactor(@subject, src, @on ++ [prepared: prepared([{"view.ex", src}])])

      # The original survives as a dispatcher delegating to the splits;
      # the two dynamic sites still call render/2 (unchanged), so nothing
      # is half-renamed. Result must compile.
      assert out =~ "def render(data, compact)"
      assert out =~ "def render_shrink(data)"
      assert out =~ "def render_expand(data)"
      assert out =~ "render(x, p)"
      assert out =~ "render(x, q)"
      refute out =~ "render_shrink(x"
      assert_compiles(out)
    end

    test "self-delegating flag function (branches call render_*) is left alone" do
      # Branch bodies bare-delegate to `render_compact`/`render_full` —
      # siblings sharing the function's own name prefix. That is exactly
      # the dispatcher shape this refactor emits; splitting would risk a
      # self-recursive `render_render_*` name and break idempotence, so
      # the function is declined (skip rather than guess). Rename the
      # helpers to something not prefixed with `render_` to make it
      # split-ready.
      src = """
      defmodule MyApp.View do
        def render(data, compact) do
          if compact, do: render_compact(data), else: render_full(data)
        end

        def render_compact(d), do: {:c, d}
        def render_full(d), do: {:f, d}

        def a(x), do: render(x, true)
        def b(x), do: render(x, false)
      end
      """

      plan = prepared([{"view.ex", src}])
      assert_unchanged(@subject, src, @on ++ [prepared: plan])
    end
  end
end
