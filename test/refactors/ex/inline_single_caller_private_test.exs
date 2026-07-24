defmodule Number42.Refactors.Ex.InlineSingleCallerPrivateTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.InlineSingleCallerPrivate

  @subject InlineSingleCallerPrivate

  # InlineSingleCallerPrivate is enabled by default and takes no opts;
  # `@on` is the empty opts list, kept on the behavioural tests so the
  # call shape stays uniform.
  @on []

  describe "rewrites — canonical inline" do
    test "single-call-site defp is inlined and deleted" do
      before_source = """
      defmodule M do
        defp helper(x), do: x * 2 + offset()
        def f(n), do: helper(n) + 1
      end
      """

      after_source = """
      defmodule M do
        def f(n), do: (n * 2 + offset()) + 1
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "paren-wrap preserves precedence inside a larger expression" do
      before_source = """
      defmodule M do
        defp double(x), do: x + x
        def f(n), do: 1 + helper_wrap() * double(n)
      end
      """

      # `double(n)` → `(n + n)` so `* (n + n)` binds correctly.
      after_source = """
      defmodule M do
        def f(n), do: 1 + helper_wrap() * (n + n)
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "deletes the helper's preceding @doc and @spec" do
      before_source = """
      defmodule M do
        @doc false
        @spec helper(integer()) :: integer()
        defp helper(x), do: x * 2

        def f(n), do: helper(n) + 1
      end
      """

      after_source = """
      defmodule M do
        def f(n), do: (n * 2) + 1
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "multi-arg helper substitutes each param" do
      before_source = """
      defmodule M do
        defp combine(a, b), do: a + b * 2
        def f(x, y), do: combine(x, y) - 1
      end
      """

      after_source = """
      defmodule M do
        def f(x, y), do: (x + y * 2) - 1
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end
  end

  describe "multiple-evaluation trap" do
    test "param used twice with trivially-safe (literal) arg is inlined" do
      before_source = """
      defmodule M do
        defp twice(x), do: x + x
        def f, do: twice(5)
      end
      """

      after_source = """
      defmodule M do
        def f, do: (5 + 5)
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "param used twice with bare-var arg is inlined" do
      before_source = """
      defmodule M do
        defp twice(x), do: x + x
        def f(n), do: twice(n)
      end
      """

      after_source = """
      defmodule M do
        def f(n), do: (n + n)
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "param used twice with impure call arg is left unchanged" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp twice(x), do: x + x
          def f, do: twice(side_effect())
        end
        """,
        @on
      )
    end
  end

  describe "leaves alone — out of scope kinds" do
    test "public def is never inlined" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def helper(x), do: x * 2
          def f(n), do: helper(n) + 1
        end
        """,
        @on
      )
    end

    test "defmacrop is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defmacrop helper(x), do: quote(do: unquote(x) * 2)
          def f(n), do: helper(n) + 1
        end
        """,
        @on
      )
    end
  end

  describe "leaves alone — non-substitutable defp shapes" do
    test "multi-clause defp is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(0), do: :zero
          defp helper(x), do: x * 2
          def f(n), do: helper(n)
        end
        """,
        @on
      )
    end

    test "when-guarded defp is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x) when x > 0, do: x * 2
          def f(n), do: helper(n) + 1
        end
        """,
        @on
      )
    end

    test "recursive defp is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x), do: helper(x - 1) + x
          def f(n), do: helper(n)
        end
        """,
        @on
      )
    end

    test "pattern param is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(%X{a: a}), do: a * 2
          def f(s), do: helper(s) + 1
        end
        """,
        @on
      )
    end

    test "body with a binding (=) is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x) do
            y = x * 2
            y + 1
          end

          def f(n), do: helper(n)
        end
        """,
        @on
      )
    end

    test "rescue-bearing body is skipped (would drop the rescue clause)" do
      # `fetch_do_body/1` only reads the `:do` value; without this guard the
      # `rescue _ -> nil` clause is silently dropped and the inlined call
      # raises instead of returning nil. Skip the whole helper.
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp safe(mod) do
            risky!(mod)
          rescue
            _ -> nil
          end

          def f(mod), do: safe(mod)
        end
        """,
        @on
      )
    end

    test "after-bearing body is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp with_cleanup(h) do
            read(h)
          after
            close(h)
          end

          def f(h), do: with_cleanup(h)
        end
        """,
        @on
      )
    end

    test "else-bearing (do/else try) body is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp parse(x) do
            String.to_integer(x)
          rescue
            _ -> :error
          else
            n -> {:ok, n}
          end

          def f(x), do: parse(x)
        end
        """,
        @on
      )
    end

    # A `quote`-returning helper carves a macro body into named sections
    # stitched with `unquote(define_section())`. Inlining yields
    # `unquote(quote do … end)` — worse than the named helper. Skip.
    test "quote-returning body is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defmacro __using__(_opts) do
            quote do
              unquote(callbacks())
            end
          end

          defp callbacks do
            quote do
              def type, do: :string
            end
          end
        end
        """,
        @on
      )
    end

    # A body spanning many source lines (here a heredoc) is structure a
    # name should hold; cramming it into the single call site reads worse.
    test "many-line body is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp banner do
            \"\"\"
            line one
            line two
            line three
            line four
            line five
            line six
            \"\"\"
          end

          def f, do: banner()
        end
        """,
        @on
      )
    end
  end

  describe "leaves alone — call-site count" do
    test "two call sites are skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2
          def f(n), do: helper(n) + helper(n + 1)
        end
        """,
        @on
      )
    end

    test "zero call sites are skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2
          def f(n), do: n + 1
        end
        """,
        @on
      )
    end

    test "capture-only use is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2
          def f(xs), do: Enum.map(xs, &helper/1)
        end
        """,
        @on
      )
    end

    test "apply mentioning the name is skipped" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2
          def f(n), do: apply(__MODULE__, :helper, [n])
        end
        """,
        @on
      )
    end
  end

  # #400: the soundness case. One *direct* call plus a second caller
  # reaching the helper through a non-direct dispatch form. Undercounting
  # any of these reads as "exactly one caller" and deletes a function that
  # is still called — a silently broken build. The count now comes from
  # `AstHelpers.collect_calls/1`, so each form is counted by the shared
  # call-graph layer rather than by a private walk.
  describe "leaves alone — a second caller via a non-direct form (#400)" do
    test "direct call + capture elsewhere is not inlined" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2
          def f(n), do: helper(n)
          def g(xs), do: Enum.map(xs, &helper/1)
        end
        """,
        @on
      )
    end

    test "direct call + pipe-form call elsewhere is not inlined" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2
          def f(n), do: helper(n)
          def g(n), do: n |> helper()
        end
        """,
        @on
      )
    end

    test "direct call + static apply elsewhere is not inlined" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2
          def f(n), do: helper(n)
          def g(n), do: apply(__MODULE__, :helper, [n])
        end
        """,
        @on
      )
    end

    test "direct call + Kernel.apply elsewhere is not inlined" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2
          def f(n), do: helper(n)
          def g(n), do: Kernel.apply(__MODULE__, :helper, [n])
        end
        """,
        @on
      )
    end

    test "unresolvable dynamic dispatch blocks inlining even with one direct call" do
      # `apply(__MODULE__, fun, [n])` with a non-literal name could reach
      # any local function, so "exactly one caller" is unknowable.
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2
          def f(n), do: helper(n)
          def g(fun, n), do: apply(__MODULE__, fun, [n])
        end
        """,
        @on
      )
    end

    test "arity-correct pipe caller of a /2 helper is counted" do
      # `x |> helper(y)` is AST-shaped as helper/1 but is really helper/2.
      # Missing the arity correction would leave helper/2 with one counted
      # caller and delete it while the pipe still references it.
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp helper(x, y), do: x * y
          def f(a, b), do: helper(a, b)
          def g(a, b), do: a |> helper(b)
        end
        """,
        @on
      )
    end
  end

  describe "leaves alone — pipe-form callers (issue #80)" do
    test "one direct caller + one pipe caller is not inlined/deleted" do
      # `x |> render()` is AST-shaped as render/0 (the piped arg is
      # implicit) but is really a render/1 call. Counting it as a use
      # means render/1 has two callers → skip. Before the fix the pipe
      # caller was missed, render was deleted, and `b` dangled.
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp render(x), do: do_render(x)
          def a(x), do: render(x)
          def b(x), do: x |> render()
        end
        """,
        @on
      )
    end

    test "sole caller is a pipe call (no direct call) is not inlined/deleted" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp render(x), do: do_render(x)
          def b(x), do: x |> render()
        end
        """,
        @on
      )
    end

    test "pipe call with an explicit arg counts at arity+1" do
      # `x |> combine(y)` is really combine/2. With a direct combine/2
      # call too, that's two callers → skip.
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp combine(a, b), do: a + b
          def f(x, y), do: combine(x, y)
          def g(x, y), do: x |> combine(y)
        end
        """,
        @on
      )
    end

    test "pipe call into a later pipe stage is counted" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp step(x), do: x + 1
          def f(x), do: step(x)
          def g(x), do: x |> step() |> Integer.to_string()
        end
        """,
        @on
      )
    end
  end

  describe "idempotent" do
    test "canonical inline is stable across passes" do
      assert_idempotent(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2 + offset()
          def f(n), do: helper(n) + 1
        end
        """,
        @on
      )
    end

    test "non-matching code is left alone across passes" do
      assert_idempotent(
        @subject,
        """
        defmodule M do
          defp helper(x), do: x * 2
          def f(n), do: helper(n) + helper(n)
        end
        """,
        @on
      )
    end

    # Regression: several independent single-caller helpers must all
    # inline within ONE transform, not one-per-pass. With the old throttle
    # a file holding more single-caller helpers than the engine's pass cap
    # (@max_passes) never finished and was reported as non-converging;
    # transform/2 now loops to its own fixpoint.
    test "inlines several independent helpers in one transform" do
      source = """
      defmodule M do
        def a(n), do: h1(n) + 1
        def b(n), do: h2(n) + 1
        def c(n), do: h3(n) + 1
        defp h1(x), do: x * 2
        defp h2(x), do: x * 3
        defp h3(x), do: x * 4
      end
      """

      once = apply_refactor(@subject, source, @on)

      refute once =~ "defp h1"
      refute once =~ "defp h2"
      refute once =~ "defp h3"

      assert_idempotent(@subject, source, @on)
      assert_compiles(once)
    end

    # Regression: a chain where inlining one helper exposes the next as a
    # single-caller. Re-parsing each step keeps this correct AND lets it
    # fully resolve inside a single transform.
    test "resolves a single-caller chain in one transform" do
      source = """
      defmodule M do
        def f(n), do: h1(n)
        defp h1(x), do: h2(x) + 1
        defp h2(x), do: x * 2
      end
      """

      once = apply_refactor(@subject, source, @on)

      refute once =~ "defp h1"
      refute once =~ "defp h2"

      assert_idempotent(@subject, source, @on)
      assert_compiles(once)
    end
  end

  describe "regression — arg shadows a param name must not loop (whk floor_plan.ex)" do
    # The single call site passes an argument expression that itself
    # contains a variable with the same name as the helper's parameter
    # (`width` here). The old prewalk-based substitution replaced the
    # param `width` with the arg `width + pad`, then re-descended into the
    # inserted arg, found `width` again, and substituted forever
    # (412M+ reductions, never terminating). Substitution must splice the
    # arg verbatim without re-traversing it.
    test "param name appearing in the call-site arg terminates" do
      before_source = """
      defmodule M do
        defp scale(width), do: width * 2 + base()
        def render(width, pad), do: scale(width + pad)
      end
      """

      # The assertion is simply that this returns at all (was an infinite
      # loop). Correctness of the splice is covered by the output below.
      result = apply_refactor(@subject, before_source, @on)
      assert is_binary(result)
      assert result =~ "width + pad"
      refute result =~ "defp scale"
    end

    test "inlined output with shadowing arg compiles" do
      before_source = """
      defmodule InlineShadowSample do
        defp scale(width), do: width * 2
        def render(width, pad), do: scale(width + pad)
      end
      """

      assert_compiles(apply_refactor(@subject, before_source, @on))
    end
  end

  describe "output compiles" do
    test "inlined output is valid Elixir" do
      before_source = """
      defmodule InlineCompileSample do
        def f(n), do: helper(n) + 1
        defp helper(x), do: x * 2 + 3
      end
      """

      assert_compiles(apply_refactor(@subject, before_source, @on))
    end
  end
end
