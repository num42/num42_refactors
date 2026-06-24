defmodule Number42.Refactors.Ex.IntroduceContextObjectForParameterTrainTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.IntroduceContextObjectForParameterTrain, as: Subject

  # transform/2 opts: enabled, with the per-module plan threaded through
  # `prepared` exactly as the engine does. `public?` toggles wrapper mode.
  defp opts(src, extra \\ []) do
    public? = Keyword.get(extra, :public, false)
    min = Keyword.get(extra, :min_train_size, 3)
    plan = Subject.build_plan([{"lib/m.ex", src}], public: public?, min_train_size: min)
    [enabled: true, prepared: plan]
  end

  describe "default-OFF gate" do
    test "without enabled: true the source is untouched even for a clear train" do
      src = """
      defmodule Pricing do
        def total(items, region, currency) do
          subtotal(items, region, currency) + tax(items, region, currency)
        end

        defp subtotal(items, region, currency), do: items
        defp tax(items, region, currency), do: region
      end
      """

      plan = Subject.build_plan([{"lib/m.ex", src}])
      assert_unchanged(Subject, src, prepared: plan)
    end
  end

  describe "private-only call chain (the core case)" do
    test "a 3-param train forwarded to a defp is bundled into a context struct" do
      src = """
      defmodule Pricing do
        def total(items, region, currency) do
          subtotal(items, region, currency)
        end

        defp subtotal(items, region, currency), do: items + region + currency
      end
      """

      out = Subject.transform(src, opts(src))

      assert out =~ "defstruct [:items, :region, :currency]"
      assert out =~ "defp subtotal(%Order{items: items, region: region, currency: currency})"
      assert out =~ "subtotal(%Order{items: items, region: region, currency: currency})"
    end

    test "the bundled output compiles" do
      src = """
      defmodule Pricing do
        def total(items, region, currency) do
          subtotal(items, region, currency)
        end

        defp subtotal(items, region, currency), do: items + region + currency
      end
      """

      assert_compiles(Subject.transform(src, opts(src)))
    end

    test "a train crossing two helper boundaries is bundled across both callees" do
      # Dictionary-named train (`items`+`region`+`currency` → `Order`); an
      # unnameable param set would be declined (no placeholder fallback).
      src = """
      defmodule Pricing do
        def total(items, region, currency) do
          one(items, region, currency) + two(items, region, currency)
        end

        defp one(items, region, currency), do: items + region + currency
        defp two(items, region, currency), do: items * region * currency
      end
      """

      out = Subject.transform(src, opts(src))

      assert out =~ "defp one(%"
      assert out =~ "defp two(%"
      assert out =~ "defmodule Order do"
      assert_compiles(out)
    end
  end

  describe "public wrapper mode" do
    test "a public def train keeps a backward-compat wrapper at the original arity" do
      # Dictionary-named train (`conn`+`params`+`session` → `Request`).
      src = """
      defmodule View do
        def show(conn, params, session) do
          render(conn, params, session)
        end

        def render(conn, params, session), do: conn + params + session
      end
      """

      out = Subject.transform(src, opts(src, public: true))

      # the public callee gets the struct arity AND a forwarding wrapper
      assert out =~ "def render(%"
      assert out =~ "def render(conn, params, session), do: render(%"
      assert_compiles(out)
    end

    test "without public: true a public-def train is not bundled" do
      src = """
      defmodule View do
        def render(socket, assigns, params), do: socket
        def caller(socket, assigns, params), do: render(socket, assigns, params)
      end
      """

      assert_unchanged(Subject, src, opts(src))
    end
  end

  describe "false-positive guards (skip)" do
    test "reordered args at a call site decline the train" do
      src = """
      defmodule M do
        def caller(a, b, c) do
          helper(a, b, c) + helper(c, b, a)
        end

        defp helper(a, b, c), do: a + b + c
      end
      """

      assert_unchanged(Subject, src, opts(src))
    end

    test "a transformed arg at a call site declines the train" do
      src = """
      defmodule M do
        def caller(a, b, c) do
          helper(a + 1, b, c)
        end

        defp helper(a, b, c), do: a + b + c
      end
      """

      assert_unchanged(Subject, src, opts(src))
    end

    test "a partially-omitted train (call at lower arity) declines" do
      src = """
      defmodule M do
        def caller(a, b, c) do
          helper(a, b, c) + helper(a, b)
        end

        defp helper(a, b, c), do: a + b + c
        defp helper(a, b), do: a + b
      end
      """

      assert_unchanged(Subject, src, opts(src))
    end

    test "fewer than K params is below threshold" do
      src = """
      defmodule M do
        def caller(a, b), do: helper(a, b)
        defp helper(a, b), do: a + b
      end
      """

      assert_unchanged(Subject, src, opts(src))
    end

    test "an unnameable param set is declined (no Context<N> placeholder)" do
      # `a`/`b`/`c` match no dictionary entry. With no placeholder fallback
      # (#375) the train is declined rather than bundled into `Context1`.
      src = """
      defmodule M do
        def caller(a, b, c) do
          one(a, b, c) + two(a, b, c)
        end

        defp one(a, b, c), do: a + b + c
        defp two(a, b, c), do: a * b * c
      end
      """

      out = Subject.transform(src, opts(src))
      assert_unchanged(Subject, src, opts(src))
      refute out =~ "Context"
      refute out =~ "TODO: rename"
    end

    test "a framework callback arity is never bundled" do
      src = """
      defmodule Server do
        def init(state), do: dispatch(state)
        def handle_call(msg, from, state), do: handle_call(msg, from, state)
        defp dispatch(state), do: state
      end
      """

      assert_unchanged(Subject, src, opts(src))
    end

    test "a pattern-matched train param declines (non-trivial head)" do
      src = """
      defmodule M do
        def caller(a, b, c) do
          helper(a, b, c)
        end

        defp helper(%{x: a}, b, c), do: b + c
      end
      """

      assert_unchanged(Subject, src, opts(src))
    end

    test "a default-arg train param declines" do
      src = """
      defmodule M do
        def caller(a, b) do
          helper(a, b, 0)
        end

        defp helper(a, b, c \\\\ 0), do: a + b + c
      end
      """

      assert_unchanged(Subject, src, opts(src))
    end

    test "a guarded train param declines" do
      src = """
      defmodule M do
        def caller(a, b, c) do
          helper(a, b, c)
        end

        defp helper(a, b, c) when is_integer(a), do: a + b + c
      end
      """

      assert_unchanged(Subject, src, opts(src))
    end

    test "a capture of the callee pins the arity and declines" do
      src = """
      defmodule M do
        def caller(a, b, c) do
          run(&helper/3, helper(a, b, c))
        end

        defp helper(a, b, c), do: a + b + c
        defp run(f, x), do: f.(x)
      end
      """

      assert_unchanged(Subject, src, opts(src))
    end

    test "a callee with no call sites is not a train" do
      src = """
      defmodule M do
        defp helper(a, b, c), do: a + b + c
      end
      """

      assert_unchanged(Subject, src, opts(src))
    end
  end

  describe "idempotence" do
    test "running twice equals running once (private)" do
      src = """
      defmodule Pricing do
        def total(items, region, currency) do
          subtotal(items, region, currency)
        end

        defp subtotal(items, region, currency), do: items + region + currency
      end
      """

      assert_idempotent(Subject, src, opts(src))
    end

    test "the public wrapper is not re-bundled on a second pass" do
      src = """
      defmodule View do
        def show(socket, assigns, params) do
          render(socket, assigns, params)
        end

        def render(socket, assigns, params), do: socket + assigns + params
      end
      """

      # the engine re-derives the plan from the rewritten source each
      # fixpoint iteration, so re-prepare before the second pass.
      once = Subject.transform(src, opts(src, public: true))
      twice = Subject.transform(once, opts(once, public: true))

      assert String.replace(once, ~r/\s+/, " ") == String.replace(twice, ~r/\s+/, " ")
    end
  end

  describe "build_plan/2" do
    test "produces a per-module spec for an eligible train" do
      src = """
      defmodule Pricing do
        def total(items, region, currency), do: subtotal(items, region, currency)
        defp subtotal(items, region, currency), do: items
      end
      """

      plan = Subject.build_plan([{"lib/m.ex", src}])
      spec = plan |> Map.values() |> List.flatten() |> List.first()

      assert spec.fields == [:items, :region, :currency]
      assert spec.struct_name == "Order"
      assert Enum.map(spec.callees, & &1.name) == [:subtotal]
    end

    test "skips test/ and dev/ paths" do
      src = """
      defmodule M do
        def caller(a, b, c), do: helper(a, b, c)
        defp helper(a, b, c), do: a + b + c
      end
      """

      assert Subject.build_plan([{"test/m_test.exs", src}]) == %{}
      assert Subject.build_plan([{"dev/m.ex", src}]) == %{}
    end
  end
end
