defmodule Number42.Refactors.Ex.DelegateExactDuplicatesTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.DelegateExactDuplicates

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

  describe "transitive call closure must match too" do
    test "identical public body but divergent local helper → not delegated (#305)" do
      # #305 regression: `fetch_page` is AST-identical in both modules, but
      # each calls its OWN `defp list/2` with completely different logic.
      # Delegating `fetch_page` to one module makes the other run the wrong
      # `list/2` → wrong data (or a crash on a missing key). The transitive
      # call closure diverges, so neither may delegate.
      filtered = """
      defmodule MyApp.FilteredSource do
        def fetch_page(direction, cursor, limit, args) do
          slice = resolve(direction, cursor, limit)
          {entries, total} = list(args, slice)
          {:ok, index(entries), next(total)}
        end

        defp list(args, slice) do
          scope = Map.fetch!(args, :scope)
          search = Map.get(args, :search)
          fetch_filtered(scope, search, slice)
        end
      end
      """

      collection = """
      defmodule MyApp.CollectionSource do
        def fetch_page(direction, cursor, limit, args) do
          slice = resolve(direction, cursor, limit)
          {entries, total} = list(args, slice)
          {:ok, index(entries), next(total)}
        end

        defp list(args, slice) do
          scope = Map.fetch!(args, :scope)
          collection_id = Map.fetch!(args, :collection_id)
          fetch_collection(scope, collection_id, slice)
        end
      end
      """

      plan = prepared([{"filtered.ex", filtered}, {"collection.ex", collection}])

      assert_unchanged(@subject, filtered, prepared: plan)
      assert_unchanged(@subject, collection, prepared: plan)
    end

    test "identical public body AND identical local helper → still delegated" do
      # The whole transitive closure is structurally equal, so delegation is
      # safe: the winner's `list/2` does exactly what the loser's did.
      a = """
      defmodule MyApp.A do
        def fetch_page(direction, cursor, limit, args) do
          slice = resolve(direction, cursor, limit)
          {entries, total} = list(args, slice)
          {:ok, index(entries), next(total)}
        end

        defp list(args, slice) do
          scope = Map.fetch!(args, :scope)
          fetch_shared(scope, slice)
        end
      end
      """

      b = """
      defmodule MyApp.A.Longer do
        def fetch_page(direction, cursor, limit, args) do
          slice = resolve(direction, cursor, limit)
          {entries, total} = list(args, slice)
          {:ok, index(entries), next(total)}
        end

        defp list(args, slice) do
          scope = Map.fetch!(args, :scope)
          fetch_shared(scope, slice)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}])

      # After delegation `list/2` is only reachable from the delegated
      # `fetch_page`, so it's dead in module A and the dead-helper cleanup
      # removes it. The point of this test is that delegation *happens* (the
      # closure matched), not the leftover helper.
      expected_a = """
      defmodule MyApp.A do
        defdelegate fetch_page(direction, cursor, limit, args), to: MyApp.A.Longer


      end
      """

      assert_rewrites(@subject, a, expected_a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
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

    test "module that already delegates the def gets no second delegate (#226)" do
      # The destination/accumulation gap from #226: a module carries BOTH a
      # leftover `def` (e.g. re-generated by ExtractSharedModule each pass) AND
      # an existing AST-identical `defdelegate` for the same name/arity/target.
      # build_plan flags the `def` as a duplicate of the winner, but the module
      # must NOT get a second identical defdelegate appended.
      loser = """
      defmodule MyApp.Support do
        defdelegate collect_parent_ids(tree), to: MyApp.Deep.RowBuilder

        def collect_parent_ids(tree) do
          tree
          |> Enum.map(& &1.parent_id)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
        end
      end
      """

      winner = """
      defmodule MyApp.Deep.RowBuilder do
        def collect_parent_ids(tree) do
          tree
          |> Enum.map(& &1.parent_id)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
        end
      end
      """

      plan = prepared([{"support.ex", loser}, {"rowbuilder.ex", winner}])

      assert_unchanged(@subject, loser, prepared: plan)
    end

    test "full prepare→transform→prepare→transform cycle converges (#226)" do
      # First pass turns the leftover `def` into a delegate. A second pass,
      # re-planned from the rewritten world plus the re-introduced leftover
      # `def` (as ExtractSharedModule would emit it), must append nothing.
      def_only = """
      defmodule MyApp.Support do
        def collect_parent_ids(tree) do
          tree
          |> Enum.map(& &1.parent_id)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
        end
      end
      """

      winner = """
      defmodule MyApp.Deep.RowBuilder do
        def collect_parent_ids(tree) do
          tree
          |> Enum.map(& &1.parent_id)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
        end
      end
      """

      plan = prepared([{"support.ex", def_only}, {"rowbuilder.ex", winner}])
      once = apply_refactor(@subject, def_only, prepared: plan)

      # Re-introduce the leftover `def` next to the freshly-emitted delegate.
      with_leftover = """
      defmodule MyApp.Support do
        defdelegate collect_parent_ids(tree), to: MyApp.Deep.RowBuilder

        def collect_parent_ids(tree) do
          tree
          |> Enum.map(& &1.parent_id)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
        end
      end
      """

      assert once =~ "defdelegate collect_parent_ids(tree)"

      plan2 = prepared([{"support.ex", with_leftover}, {"rowbuilder.ex", winner}])
      assert_unchanged(@subject, with_leftover, prepared: plan2)
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

  describe "regression — bodiless multi-clause head must not crash" do
    # Real-world crash from whk_portal/seeds.ex: the closure-hash path
    # (`defp_body_hashes/1` -> `hash_clauses/1` -> `normalize_clause/1`)
    # fingerprints every local `defp` reachable from a clone candidate.
    # A multi-clause helper whose first clause is a bodiless head
    # (`defp ensure_org(user, org)` with no `do`) has AST
    # `{:defp, _, [head]}` — no `body_kw` — and `normalize_clause/1`
    # raised a FunctionClauseError, killing the whole `mix refactor` run.
    test "a reachable defp with a bodiless head does not raise" do
      shorter = """
      defmodule MyApp.Items do
        def recalc(user, org) do
          ensure_org(user, org)
        end

        defp ensure_org(user, org)
        defp ensure_org(user, nil), do: user
        defp ensure_org(user, org), do: %{user | org: org}
      end
      """

      longer = """
      defmodule MyApp.Items.Positions do
        def recalc(user, org) do
          ensure_org(user, org)
        end

        defp ensure_org(user, org)
        defp ensure_org(user, nil), do: user
        defp ensure_org(user, org), do: %{user | org: org}
      end
      """

      plan = prepared([{"shorter.ex", shorter}, {"longer.ex", longer}])

      assert is_binary(apply_refactor(@subject, shorter, prepared: plan))
    end
  end
end
