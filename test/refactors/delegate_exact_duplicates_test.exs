defmodule Num42.Refactors.Refactors.DelegateExactDuplicatesTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.DelegateExactDuplicates

  @subject DelegateExactDuplicates

  # The refactor needs cross-file context: it inspects every input
  # source, hashes function bodies, picks a "winner" module per clone
  # group, and rewrites the losers. We feed that context to transform/2
  # via a `prepared` map under opts[:prepared] — same shape the engine
  # produces from `prepare/1` in production.

  defp prepared(sources), do: sources |> DelegateExactDuplicates.build_plan(min_mass: 5)

  describe "rewrites — winner is the longer module name" do
    test "two modules with identical def: shorter delegates to longer" do
      shorter = """
      defmodule MyApp.Items do
        def assign(scope, attrs) do
          scope
          |> Map.put(:attrs, attrs)
          |> Map.put(:assigned, true)
        end
      end
      """

      longer = """
      defmodule MyApp.Items.Positions do
        def assign(scope, attrs) do
          scope
          |> Map.put(:attrs, attrs)
          |> Map.put(:assigned, true)
        end
      end
      """

      plan = prepared([{"shorter.ex", shorter}, {"longer.ex", longer}])

      expected_shorter = """
      defmodule MyApp.Items do
        defdelegate assign(scope, attrs), to: MyApp.Items.Positions
      end
      """

      assert_rewrites(@subject, shorter, expected_shorter, prepared: plan)
      assert_unchanged(@subject, longer, prepared: plan)
    end

    test "ties on segment count fall back to alphabetical order (later wins)" do
      a = """
      defmodule MyApp.Apple do
        def hello(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      b = """
      defmodule MyApp.Banana do
        def hello(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}])

      expected_a = """
      defmodule MyApp.Apple do
        defdelegate hello(x, y), to: MyApp.Banana
      end
      """

      assert_rewrites(@subject, a, expected_a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
    end
  end

  describe "skips" do
    test "single-occurrence functions stay untouched" do
      only = """
      defmodule MyApp.Solo do
        def lonely(x, y), do: x + y
      end
      """

      plan = prepared([{"solo.ex", only}])
      assert_unchanged(@subject, only, prepared: plan)
    end

    test "private functions (defp) are not delegated" do
      a = """
      defmodule MyApp.Foo do
        defp helper(x, y), do: x + y
      end
      """

      b = """
      defmodule MyApp.Foo.Bar do
        defp helper(x, y), do: x + y
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}])

      assert_unchanged(@subject, a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
    end

    test "macros are not delegated" do
      a = """
      defmodule MyApp.Macros do
        defmacro debug(expr) do
          quote do: IO.inspect(unquote(expr))
        end
      end
      """

      b = """
      defmodule MyApp.Macros.Extra do
        defmacro debug(expr) do
          quote do: IO.inspect(unquote(expr))
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}])

      assert_unchanged(@subject, a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
    end

    test "pattern-matched arguments in head are skipped" do
      a = """
      defmodule MyApp.Patterns do
        def run(%{key: k}, opts) do
          k + length(opts)
        end
      end
      """

      b = """
      defmodule MyApp.Patterns.Inner do
        def run(%{key: k}, opts) do
          k + length(opts)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}])

      assert_unchanged(@subject, a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
    end

    test "default arguments in head are skipped" do
      a = """
      defmodule MyApp.Defaults do
        def run(x, opts \\\\ []), do: {x, opts}
      end
      """

      b = """
      defmodule MyApp.Defaults.Inner do
        def run(x, opts \\\\ []), do: {x, opts}
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}])

      assert_unchanged(@subject, a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
    end

    test "guards in head are skipped" do
      a = """
      defmodule MyApp.Guards do
        def run(x, y) when is_integer(x) and is_integer(y) do
          x + y
        end
      end
      """

      b = """
      defmodule MyApp.Guards.Inner do
        def run(x, y) when is_integer(x) and is_integer(y) do
          x + y
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}])

      assert_unchanged(@subject, a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
    end

    test "function bodies referencing module attributes are skipped" do
      a = """
      defmodule MyApp.Attrs do
        @magic 42
        def with_magic(x), do: x + @magic
      end
      """

      b = """
      defmodule MyApp.Attrs.Inner do
        @magic 42
        def with_magic(x), do: x + @magic
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}])

      assert_unchanged(@subject, a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
    end

    test "trivial bodies (under min mass) are skipped" do
      # A 2-node body like `do: x` is too small to be worth delegating.
      a = """
      defmodule MyApp.Tiny do
        def passthrough(x), do: x
      end
      """

      b = """
      defmodule MyApp.Tiny.Inner do
        def passthrough(x), do: x
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}])

      assert_unchanged(@subject, a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
    end

    test "multi-clause functions are only delegated if every clause matches" do
      a = """
      defmodule MyApp.Multi do
        def run(0), do: :zero
        def run(n) when is_integer(n), do: n * 2
      end
      """

      b = """
      defmodule MyApp.Multi.Inner do
        def run(0), do: :zero
        def run(n) when is_integer(n), do: n * 100
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}])

      assert_unchanged(@subject, a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
    end
  end

  describe "n-way clones" do
    test "three modules: shortest two delegate to the longest" do
      a = """
      defmodule MyApp.A do
        def shared(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      b = """
      defmodule MyApp.A.B do
        def shared(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      c = """
      defmodule MyApp.A.B.C do
        def shared(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}, {"c.ex", c}])

      expected_a = """
      defmodule MyApp.A do
        defdelegate shared(x, y), to: MyApp.A.B.C
      end
      """

      expected_b = """
      defmodule MyApp.A.B do
        defdelegate shared(x, y), to: MyApp.A.B.C
      end
      """

      assert_rewrites(@subject, a, expected_a, prepared: plan)
      assert_rewrites(@subject, b, expected_b, prepared: plan)
      assert_unchanged(@subject, c, prepared: plan)
    end
  end

  describe "idempotence" do
    test "second pass on a rewritten loser is a no-op" do
      shorter = """
      defmodule MyApp.Items do
        def assign(scope, attrs) do
          scope
          |> Map.put(:attrs, attrs)
          |> Map.put(:assigned, true)
        end
      end
      """

      longer = """
      defmodule MyApp.Items.Positions do
        def assign(scope, attrs) do
          scope
          |> Map.put(:attrs, attrs)
          |> Map.put(:assigned, true)
        end
      end
      """

      plan = prepared([{"shorter.ex", shorter}, {"longer.ex", longer}])
      once = apply_refactor(@subject, shorter, prepared: plan)

      # Re-build the plan from the *rewritten* world. The shorter module
      # now contains only a defdelegate, so it's no longer a duplicate.
      plan2 = prepared([{"shorter.ex", once}, {"longer.ex", longer}])

      assert_unchanged(@subject, once, prepared: plan2)
    end
  end

  describe "no prepared plan" do
    test "without a plan, transform/2 is a no-op (engine just hasn't called prepare yet)" do
      source = """
      defmodule MyApp.Foo do
        def assign(x, y), do: x + y
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "dead helper cleanup" do
    test "private helpers used only by the delegated function are removed" do
      shorter = """
      defmodule MyApp.Items do
        def recalc(items) do
          items
          |> Enum.map(&normalize/1)
          |> Enum.reduce(0, fn x, acc -> acc + x end)
        end

        defp normalize(item), do: item * 2
      end
      """

      longer = """
      defmodule MyApp.Items.Positions do
        def recalc(items) do
          items
          |> Enum.map(&normalize/1)
          |> Enum.reduce(0, fn x, acc -> acc + x end)
        end

        defp normalize(item), do: item * 2
      end
      """

      plan = prepared([{"shorter.ex", shorter}, {"longer.ex", longer}])

      expected_shorter = """
      defmodule MyApp.Items do
        defdelegate recalc(items), to: MyApp.Items.Positions
      end
      """

      assert_rewrites(@subject, shorter, expected_shorter, prepared: plan)
    end

    test "transitively unreachable helpers are also removed" do
      shorter = """
      defmodule MyApp.Items do
        def recalc(items) do
          items
          |> Enum.map(&normalize/1)
          |> Enum.reduce(0, &add/2)
        end

        defp normalize(item), do: scale(item)
        defp scale(x), do: x * 2
        defp add(x, acc), do: acc + x
      end
      """

      longer = """
      defmodule MyApp.Items.Positions do
        def recalc(items) do
          items
          |> Enum.map(&normalize/1)
          |> Enum.reduce(0, &add/2)
        end

        defp normalize(item), do: scale(item)
        defp scale(x), do: x * 2
        defp add(x, acc), do: acc + x
      end
      """

      plan = prepared([{"shorter.ex", shorter}, {"longer.ex", longer}])

      expected_shorter = """
      defmodule MyApp.Items do
        defdelegate recalc(items), to: MyApp.Items.Positions
      end
      """

      assert_rewrites(@subject, shorter, expected_shorter, prepared: plan)
    end

    test "helpers still used by other public functions are kept" do
      shorter = """
      defmodule MyApp.Items do
        def recalc(items) do
          items
          |> Enum.map(&normalize/1)
          |> Enum.reduce(0, fn x, acc -> acc + x end)
        end

        def other_caller(item), do: normalize(item)

        defp normalize(item), do: item * 2
      end
      """

      longer = """
      defmodule MyApp.Items.Positions do
        def recalc(items) do
          items
          |> Enum.map(&normalize/1)
          |> Enum.reduce(0, fn x, acc -> acc + x end)
        end

        defp normalize(item), do: item * 2
      end
      """

      plan = prepared([{"shorter.ex", shorter}, {"longer.ex", longer}])

      # `normalize/1` stays because `other_caller/1` still uses it.
      result = apply_refactor(@subject, shorter, prepared: plan)
      assert result =~ "defdelegate recalc(items)"
      assert result =~ "defp normalize(item)"
      assert result =~ "def other_caller(item)"
    end
  end
end
