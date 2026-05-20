defmodule Num42.Refactors.Refactors.ExtractSharedModuleTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.ExtractSharedModule

  @subject ExtractSharedModule

  # ExtractSharedModule has stronger side-effects than Phase 1: when the
  # plan calls for a new shared module, prepare/1 writes a new .ex file
  # to disk. To keep tests hermetic we run them in a per-test tmp_dir
  # and pass `:write_root` so the planner writes there instead of the
  # project root.

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "extract_shared_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp prepared(sources, opts),
    do: sources |> ExtractSharedModule.build_plan(Keyword.merge([min_mass: 5], opts))

  describe "rewrites — new shared module" do
    test "two modules: shared module is created, both delegate to it", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items do
        def assign(scope, attrs) do
          scope
          |> Map.put(:attrs, attrs)
          |> Map.put(:assigned, true)
        end
      end
      """

      b = """
      defmodule MyApp.Items.Positions do
        def assign(scope, attrs) do
          scope
          |> Map.put(:attrs, attrs)
          |> Map.put(:assigned, true)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      expected_a = """
      defmodule MyApp.Items do
        defdelegate assign(scope, attrs), to: MyApp.Items.Shared
      end
      """

      expected_b = """
      defmodule MyApp.Items.Positions do
        defdelegate assign(scope, attrs), to: MyApp.Items.Shared
      end
      """

      assert_rewrites(@subject, a, expected_a, prepared: plan)
      assert_rewrites(@subject, b, expected_b, prepared: plan)

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path)

      shared_source = File.read!(shared_path)
      assert shared_source =~ "defmodule MyApp.Items.Shared"
      assert shared_source =~ "def assign(scope, attrs)"
      assert shared_source =~ "Map.put(:assigned, true)"
    end
  end

  describe "skips" do
    test "single occurrence is left alone", %{tmp: tmp} do
      only = """
      defmodule MyApp.Solo do
        def lonely(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      plan = prepared([{"solo.ex", only}], write_root: tmp)
      assert_unchanged(@subject, only, prepared: plan)
      refute File.exists?(Path.join(tmp, "lib/my_app/shared.ex"))
    end

    test "longest common prefix of 1 segment is rejected (no top-level Shared dump)", %{tmp: tmp} do
      a = """
      defmodule MyApp.Foo do
        def shared(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      b = """
      defmodule OtherApp.Bar do
        def shared(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      # LCP of [MyApp, Foo] and [OtherApp, Bar] is empty — so no
      # `LCP.Shared` makes sense. Skip.
      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
    end

    test "LCP of exactly 1 segment is allowed (sammeleimer)", %{tmp: tmp} do
      a = """
      defmodule MyApp.Foo do
        def shared(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      b = """
      defmodule MyApp.Bar do
        def shared(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      expected_a = """
      defmodule MyApp.Foo do
        defdelegate shared(x, y), to: MyApp.Shared
      end
      """

      assert_rewrites(@subject, a, expected_a, prepared: plan)
      assert File.exists?(Path.join(tmp, "lib/my_app/shared.ex"))
    end

    test "modules with conflicting imports are skipped", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        import Ecto.Query
        def assign(scope, attrs) do
          scope
          |> Map.put(:attrs, attrs)
          |> Map.put(:assigned, true)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        import Ecto.Changeset
        def assign(scope, attrs) do
          scope
          |> Map.put(:attrs, attrs)
          |> Map.put(:assigned, true)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
    end

    test "idempotence: second pass after delegates exist is a no-op", %{tmp: tmp} do
      already_delegated = """
      defmodule MyApp.Items do
        defdelegate assign(scope, attrs), to: MyApp.Items.Shared
      end
      """

      plan = prepared([{"a.ex", already_delegated}], write_root: tmp)
      assert_unchanged(@subject, already_delegated, prepared: plan)
    end
  end

  describe "private functions" do
    test "defp clones are extracted as def in shared, originals get import", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def caller(x), do: helper(x, 0)

        defp helper(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def caller(x), do: helper(x, 0)

        defp helper(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan)

      # The defp is gone from the original; an import takes its place.
      refute result_a =~ "defp helper"
      assert result_a =~ "import MyApp.Items.Shared, only: [helper: 2]"
      # The caller still references `helper(x, 0)` — resolved via import now.
      assert result_a =~ "def caller(x), do: helper(x, 0)"

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path)

      shared_source = File.read!(shared_path)
      # Migrated as public def so the import can pick it up.
      assert shared_source =~ "def helper(x, y)"
    end
  end

  describe "pattern-match heads" do
    test "wraps original with plain-var def, shared keeps the patterns", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def assign(%{scope: s}, attrs) do
          s
          |> Map.put(:attrs, attrs)
          |> Map.put(:assigned, true)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def assign(%{scope: s}, attrs) do
          s
          |> Map.put(:attrs, attrs)
          |> Map.put(:assigned, true)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan)

      # Original gets a plain-var wrapper (no pattern match anymore).
      refute result_a =~ "%{scope: s}"

      assert result_a =~
               ~r/def assign\(arg_0, arg_1\), do: MyApp\.Items\.Shared\.assign\(arg_0, arg_1\)/

      shared_source = File.read!(Path.join(tmp, "lib/my_app/items/shared.ex"))

      # Shared module preserves the pattern match.
      assert shared_source =~ "def assign(%{scope: s}, attrs)"
    end

    test "guarded heads also wrap into plain-var", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def compute(x, y) when is_integer(x) and is_integer(y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def compute(x, y) when is_integer(x) and is_integer(y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan)

      assert result_a =~
               ~r/def compute\(arg_0, arg_1\), do: MyApp\.Items\.Shared\.compute\(arg_0, arg_1\)/

      refute result_a =~ "is_integer"

      shared_source = File.read!(Path.join(tmp, "lib/my_app/items/shared.ex"))
      assert shared_source =~ "when is_integer(x) and is_integer(y)"
    end
  end

  describe "multi-clause" do
    test "multi-clause functions: all clauses go to shared, one wrapper in original", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def classify(0), do: :zero
        def classify(n) when is_integer(n) and n > 0, do: :positive
        def classify(n) when is_integer(n), do: :negative
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def classify(0), do: :zero
        def classify(n) when is_integer(n) and n > 0, do: :positive
        def classify(n) when is_integer(n), do: :negative
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan)

      # Exactly one wrapper, all clauses gone from original.
      refute result_a =~ ":zero"
      refute result_a =~ ":positive"
      assert result_a =~ ~r/def classify\(arg_0\), do: MyApp\.Items\.Shared\.classify\(arg_0\)/

      shared_source = File.read!(Path.join(tmp, "lib/my_app/items/shared.ex"))
      assert shared_source =~ "def classify(0)"
      assert shared_source =~ ":zero"
      assert shared_source =~ ":positive"
      assert shared_source =~ ":negative"
    end
  end

  describe "shared module body rendering" do
    test "calls in body are fully qualified using original aliases", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.Foo do
        alias MyApp.Repo

        def fetch_all(query) do
          query
          |> Repo.all()
          |> Enum.map(& &1.id)
        end
      end
      """

      b = """
      defmodule MyApp.Items.Bar do
        alias MyApp.Repo

        def fetch_all(query) do
          query
          |> Repo.all()
          |> Enum.map(& &1.id)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      _result_a = apply_refactor(@subject, a, prepared: plan)

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path)

      shared_source = File.read!(shared_path)
      # The Repo alias in the original is rewritten to its full form
      # in the shared module, so the shared module needs no alias.
      assert shared_source =~ "MyApp.Repo.all"
      refute shared_source =~ "alias MyApp.Repo"
    end

    test "skips when body calls a local function that other defs also use (cannot migrate cleanly)",
         %{tmp: tmp} do
      # `helper/1` is used both by the cloned `process/1` AND by another
      # public function `also_uses_helper/1`. We can't migrate the
      # helper into Shared (the other def still needs it locally) — so
      # the whole extraction has to skip.
      a = """
      defmodule MyApp.Items.A do
        def process(items) do
          items
          |> Enum.map(&helper/1)
          |> Enum.reduce(0, fn x, acc -> acc + x end)
        end

        def also_uses_helper(item), do: helper(item)

        defp helper(x), do: x * 2
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def process(items) do
          items
          |> Enum.map(&helper/1)
          |> Enum.reduce(0, fn x, acc -> acc + x end)
        end

        def also_uses_helper(item), do: helper(item)

        defp helper(x), do: x * 2
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
    end

    test "matching imports are copied verbatim into the shared module", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        import Ecto.Query

        def big(q) do
          q
          |> where([x], x.id > 0)
          |> select([x], x.id)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        import Ecto.Query

        def big(q) do
          q
          |> where([x], x.id > 0)
          |> select([x], x.id)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      _ = apply_refactor(@subject, a, prepared: plan)

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path)

      shared_source = File.read!(shared_path)
      assert shared_source =~ "import Ecto.Query"
    end
  end

  describe "no prepared plan" do
    test "without a plan, transform/2 is a no-op" do
      source = """
      defmodule MyApp.Foo do
        def assign(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "regression — bodyless def stubs" do
    # Default-argument heads parse as a separate `{:def, _, [head]}`
    # node (no body keyword). The walker used to crash trying to
    # destructure it as `{_, _, [_h, body_kw]}`. Two same-named def
    # stubs across modules must NOT crash the planner.
    test "default-argument stubs do not crash plan building", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def f(x, opts \\\\ []) do
          List.wrap(x) ++ opts
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def f(x, opts \\\\ []) do
          List.wrap(x) ++ opts
        end
      end
      """

      # The plan builder must complete without raising. The function
      # itself may or may not be extracted (we don't assert that here);
      # the regression is purely about not blowing up on the stub.
      assert plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)
      assert is_map(plan)
    end
  end

  describe "regression — pipe-call arity accounting" do
    # `x |> helper(y)` references `helper/2`, NOT `helper/1`. Earlier
    # versions counted the rhs as 1-arg, so a defp helper used only via
    # a pipe was wrongly considered "unreachable" and either deleted
    # from the loser or rejected as unmigratable. Verify the call is
    # accounted for at the right arity by checking that a pipe-only
    # caller still triggers an extraction with the helper migrating
    # along.
    test "pipe-call rhs is counted at arity+1", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def run(items) do
          items
          |> normalize(0)
          |> Enum.sum()
        end

        defp normalize(items, base) do
          Enum.map(items, fn x -> x + base end)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def run(items) do
          items
          |> normalize(0)
          |> Enum.sum()
        end

        defp normalize(items, base) do
          Enum.map(items, fn x -> x + base end)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      # Both `run/1` and `normalize/2` should land in the shared module
      # — `normalize` migrates as a helper. If pipe-arity accounting
      # were broken, `normalize` would be considered a dangling local
      # call and the extraction would skip.
      result_a = apply_refactor(@subject, a, prepared: plan)
      assert result_a =~ "defdelegate run(items)"

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path)
      shared_source = File.read!(shared_path)
      assert shared_source =~ "def run(items)"
      # `normalize/2` here happens to be a clone too (identical in both
      # modules), so it lands as a `def` in Shared (promoted from defp).
      # The key invariant we're checking: the body of `run/1` is not
      # rejected as unmigratable — pipe-arity accounting recognized
      # `|> normalize(0)` as a valid call to `normalize/2`.
      assert shared_source =~ "normalize(items, base)"
    end
  end

  describe "regression — dry-run safety" do
    # `mix refactor --dry-run` forwards `dry_run: true` into the
    # planner. The plan itself MUST still be populated — the dry-run
    # diff preview reads the plan to render output — but no helper
    # file may land on disk regardless of `write_root`. An earlier
    # iteration short-circuited the planner whenever `write_root` was
    # nil, which silently produced an empty diff regardless of how
    # many clones the codebase had.
    test "build_plan with dry_run populates the plan but writes nothing" do
      sandbox = Path.join(System.tmp_dir!(), "no_writes_#{System.unique_integer([:positive])}")
      File.mkdir_p!(sandbox)
      on_exit(fn -> File.rm_rf!(sandbox) end)

      a = """
      defmodule MyApp.Items.A do
        def big(q) do
          q
          |> List.wrap()
          |> Enum.map(& &1.id)
          |> Enum.uniq()
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def big(q) do
          q
          |> List.wrap()
          |> Enum.map(& &1.id)
          |> Enum.uniq()
        end
      end
      """

      plan =
        ExtractSharedModule.build_plan(
          [{"a.ex", a}, {"b.ex", b}],
          min_mass: 5,
          write_root: sandbox,
          dry_run: true
        )

      # Plan IS populated — both modules end up as losers pointing at
      # MyApp.Items.Shared. (No file gets written; see assertion below.)
      assert Map.has_key?(plan, MyApp.Items.A)
      assert Map.has_key?(plan, MyApp.Items.B)

      [entry_a] = Map.fetch!(plan, MyApp.Items.A)
      assert entry_a.target == MyApp.Items.Shared
      assert entry_a.name == :big

      refute File.exists?(Path.join(sandbox, "lib/my_app/items/shared.ex"))
    end
  end

  describe "regression — multiple clones into the same shared module" do
    # Two distinct clone groups whose LCP-based target collapses to the
    # same `*.Shared` module must both end up in that module. An earlier
    # implementation wrote the file once per clone group, with later
    # writes overwriting earlier ones — so only the last group's
    # function survived.
    test "two clone groups merge into one shared module", %{tmp: tmp} do
      # Clone group 1: `compute/1` between A and B.
      # Clone group 2: `format/1` between A and B (same modules, distinct
      # function). Both target MyApp.Items.Shared.
      a = """
      defmodule MyApp.Items.A do
        def compute(x) do
          x
          |> Kernel.+(1)
          |> Kernel.*(2)
        end

        def format(x) do
          x
          |> Integer.to_string()
          |> String.pad_leading(4, "0")
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def compute(x) do
          x
          |> Kernel.+(1)
          |> Kernel.*(2)
        end

        def format(x) do
          x
          |> Integer.to_string()
          |> String.pad_leading(4, "0")
        end
      end
      """

      _plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path)

      shared_source = File.read!(shared_path)
      # Both functions must be present in the same file.
      assert shared_source =~ "def compute(x)"
      assert shared_source =~ "def format(x)"
    end
  end

  describe "regression — helper colliding with cloned function name" do
    # `maybe_update_oz/2` was both a transitively-migrated defp helper
    # for the cloned `recalculate/0` AND a clone in its own right. The
    # shared module must contain it ONCE as a `def`, not twice (once as
    # `defp` from the helper migration, once as `def` from the clone).
    test "function takes precedence; helper version is dropped", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def big(items) do
          Enum.map(items, fn item -> small(item, :ok) end)
        end

        defp small(item, _flag) when is_map(item), do: item

        defp small(item, flag) do
          %{item: item, flag: flag}
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def big(items) do
          Enum.map(items, fn item -> small(item, :ok) end)
        end

        defp small(item, _flag) when is_map(item), do: item

        defp small(item, flag) do
          %{item: item, flag: flag}
        end
      end
      """

      _plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path)

      shared_source = File.read!(shared_path)

      # `small/2` is a clone in its own right, so it lands as `def`
      # (promoted from defp). The helper-migration path through `big/1`
      # tried to insert `small/2` as a `defp` — that copy must be
      # suppressed. Count how many `(def|defp) small(` occurrences
      # appear: should be exactly two clauses, all as `def`.
      defs_count = shared_source |> String.split("def small(") |> length() |> Kernel.-(1)
      defps_count = shared_source |> String.split("defp small(") |> length() |> Kernel.-(1)

      assert defs_count == 2,
             "expected two `def small(` clauses, got #{defs_count}\n#{shared_source}"

      assert defps_count == 0,
             "expected zero `defp small(` clauses, got #{defps_count}\n#{shared_source}"
    end
  end

  describe "regression — defp helper migrates while non-clone caller stays" do
    # Real-world repro of `next_item_unit/1` (clone) called by
    # `cycle_item_unit/2` (NOT a clone — module-qualified vs.
    # unqualified call leaves the bodies inequivalent).
    #
    # The shared private helper is migrated to `…Shared` as a `def`,
    # the original `defp` is deleted — but the caller is left intact,
    # still calling the helper unqualified. Without an `import`
    # injected by the same pass, the caller compiles to an undefined
    # function reference.
    test "caller that is NOT a clone gets the import for the migrated helper", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def cycle(scope, id) do
          item = get_item!(scope, id)
          next_unit = do_next(item.unit)
          update_item(scope, item, %{unit: next_unit})
        end

        defp get_item!(_scope, _id), do: %{unit: :piece}
        defp update_item(_scope, _item, _attrs), do: :ok

        defp do_next(:piece), do: :flat
        defp do_next(:flat), do: :linear
        defp do_next(_), do: :piece
      end
      """

      b = """
      defmodule MyApp.Items.B do
        alias MyApp.Items.A, as: Items

        def cycle(scope, id) do
          item = Items.get_item!(scope, id)
          next_unit = do_next(item.unit)
          Items.update_item(scope, item, %{unit: next_unit})
        end

        defp do_next(:piece), do: :flat
        defp do_next(:flat), do: :linear
        defp do_next(_), do: :piece
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      result_b = apply_refactor(@subject, b, prepared: plan)

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path), "shared module must exist"
      shared_source = File.read!(shared_path)

      # The `defp do_next` was migrated as a public `def` — the only
      # safe migration shape, otherwise the import wouldn't pick it up.
      assert shared_source =~ ~r/def do_next\(/, """
      `do_next` should be migrated to Shared as a public `def`.
      shared:
      #{shared_source}
      """

      # The original `defp do_next` clauses must be gone from B —
      # otherwise we'd have both a local AND a (would-be) imported
      # definition, which is a compile error too.
      refute result_b =~ ~r/defp do_next\(/, """
      `defp do_next` should be removed from the original now that it
      lives in Shared. Result:
      #{result_b}
      """

      # The caller `cycle/2` is NOT a clone (Module-qualified calls
      # diverge between A and B) and must stay put. After migration it
      # still references `do_next(item.unit)` unqualified — so an
      # `import MyApp.Items.Shared, only: [do_next: 1]` MUST have been
      # injected, or the file won't compile.
      assert result_b =~ ~r/import MyApp\.Items\.Shared,\s*only:\s*\[[^\]]*do_next:\s*1[^\]]*\]/,
             """
             missing `import MyApp.Items.Shared, only: [do_next: 1]` —
             caller `cycle/2` calls `do_next(item.unit)` unqualified and
             would fail to compile. Result:
             #{result_b}
             """
    end
  end

  describe "regression — cloned def calling cloned defp helper" do
    # Reproduction of the `cycle_item_unit/2` + `next_item_unit/1` bug:
    # both a `def` and its only-caller `defp` helper are clones across
    # two modules. The helper is reachable only from the caller (so it
    # qualifies for migration), and the caller is itself a clone. The
    # two migrations must NOT cancel each other out — either both fire
    # cleanly (caller becomes a `defdelegate`, helper moves to Shared,
    # original `defp` deleted) or the caller stays put with an `import`
    # for the helper. Anything in between leaves a caller pointing at a
    # vanished local `defp`.
    test "either both migrate cleanly or original keeps caller intact", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def cycle(unit) do
          do_next(unit)
        end

        defp do_next(:piece), do: :flat
        defp do_next(:flat), do: :linear
        defp do_next(_), do: :piece
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def cycle(unit) do
          do_next(unit)
        end

        defp do_next(:piece), do: :flat
        defp do_next(:flat), do: :linear
        defp do_next(_), do: :piece
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan)

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path), "shared module must exist on disk"
      shared_source = File.read!(shared_path)

      # The original `defp do_next` must NOT survive in the original if
      # the helper has been migrated to Shared — otherwise we'd end up
      # with a duplicate definition or a caller pointing at a dead
      # local. If it did survive, no migration of the helper happened —
      # in which case `cycle/1` must keep its body unchanged AND the
      # local `defp do_next` must still be there.
      helper_in_shared? = shared_source =~ ~r/def do_next\(/
      helper_in_original? = result_a =~ ~r/defp do_next\(/

      caller_calls_local? =
        result_a =~ ~r/def cycle\(unit\) do\s+do_next\(unit\)/ or
          result_a =~ ~r/def cycle\(unit\),\s*do:\s*do_next\(unit\)/

      caller_is_delegate? =
        result_a =~ ~r/defdelegate cycle\(unit\), to: MyApp\.Items\.Shared/

      caller_uses_import? =
        result_a =~ ~r/import MyApp\.Items\.Shared.*do_next/s

      cond do
        # Path 1: caller stayed local. Helper must also stay local
        # OR be importable from Shared.
        caller_calls_local? ->
          assert helper_in_original? or caller_uses_import?, """
          caller `cycle/1` still calls `do_next(unit)` locally, but the
          helper is gone from the original AND there's no
          `import MyApp.Items.Shared, only: [do_next: 1]` to resolve it.
          original:
          #{result_a}
          shared:
          #{shared_source}
          """

        # Path 2: caller became a defdelegate. Helper should be in
        # Shared (the whole pair travelled together). Local helper
        # must be gone (otherwise we have a dangling defp).
        caller_is_delegate? ->
          assert helper_in_shared?, """
          caller `cycle/1` was rewritten to `defdelegate` but
          `do_next/1` was not migrated to Shared.
          shared:
          #{shared_source}
          """

          refute helper_in_original?, """
          caller `cycle/1` became a `defdelegate` but the original
          still has `defp do_next` — that's dead code.
          original:
          #{result_a}
          """

        true ->
          flunk("""
          caller `cycle/1` is in an unexpected shape — neither the
          original local body, nor a `defdelegate`. Result:
          #{result_a}
          """)
      end
    end
  end

  describe "regression — existing shared module is not overwritten" do
    # The first run writes a Shared module to disk. A second run that
    # wouldn't otherwise add anything new must not clobber the existing
    # file, even if the inputs only contain the original loser modules
    # (which still parse as clones of each other). An earlier
    # implementation called `File.write!` unconditionally — the file
    # was rewritten on every invocation, losing any user-added
    # functions or comments.
    test "second run preserves a function added by the first run", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def shared_op(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def shared_op(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      _plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path)

      first_source = File.read!(shared_path)
      assert first_source =~ "def shared_op(x, y)"

      # Second run with the *same* inputs. Now the Shared module
      # already exists on disk; the planner must leave it alone (no
      # new functions to add → unchanged) instead of rewriting it from
      # scratch.
      _plan2 = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      second_source = File.read!(shared_path)
      assert second_source == first_source
    end

    test "second run does not duplicate functions added by the first run", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def shared_op(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def shared_op(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      _plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      _plan2 = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      shared_source = File.read!(Path.join(tmp, "lib/my_app/items/shared.ex"))

      defs_count =
        shared_source |> String.split("def shared_op(x, y)") |> length() |> Kernel.-(1)

      assert defs_count == 1,
             "expected one `def shared_op(x, y)` clause, got #{defs_count}\n#{shared_source}"
    end

    test "hand-written content in existing Shared file is preserved", %{tmp: tmp} do
      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      File.mkdir_p!(Path.dirname(shared_path))

      hand_written = """
      defmodule MyApp.Items.Shared do
        # human-authored helper — must survive the refactor
        def hand_written(x), do: x * 3
      end
      """

      File.write!(shared_path, hand_written)

      a = """
      defmodule MyApp.Items.A do
        def shared_op(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def shared_op(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      _plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      shared_source = File.read!(shared_path)

      assert shared_source =~ "def hand_written(x)",
             "hand-written function was clobbered:\n#{shared_source}"

      assert shared_source =~ "def shared_op(x, y)",
             "extracted clone was not appended:\n#{shared_source}"

      assert shared_source =~ "human-authored helper",
             "hand-written comment was lost:\n#{shared_source}"
    end

    test "name collision with different body: existing definition wins", %{tmp: tmp} do
      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      File.mkdir_p!(Path.dirname(shared_path))

      # Existing Shared module already defines `shared_op/2`, but with
      # a totally different body. The refactor must NOT overwrite or
      # duplicate it — the existing definition wins, and the new
      # extraction is dropped for that name/arity.
      existing = """
      defmodule MyApp.Items.Shared do
        def shared_op(x, y) do
          # different body — sentinel string for the assertion
          {:hand_written, x, y}
        end
      end
      """

      File.write!(shared_path, existing)

      a = """
      defmodule MyApp.Items.A do
        def shared_op(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def shared_op(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      _plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      shared_source = File.read!(shared_path)

      assert shared_source =~ "{:hand_written, x, y}",
             "existing body was overwritten:\n#{shared_source}"

      defs_count =
        shared_source |> String.split("def shared_op(x, y)") |> length() |> Kernel.-(1)

      assert defs_count == 1,
             "expected exactly one `def shared_op(x, y)` clause (existing wins), got #{defs_count}\n#{shared_source}"
    end
  end

  describe "origin comments" do
    # Reviewers want to see at a glance which modules a shared
    # function/helper came from. Every rendered definition gets a
    # leading `# extracted from: A, B, ...` comment listing the
    # origin modules in alphabetical order.
    test "function gets `extracted from` comment listing all source modules", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def shared_op(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def shared_op(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      _plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      shared_source = File.read!(Path.join(tmp, "lib/my_app/items/shared.ex"))

      assert shared_source =~ "# extracted from: MyApp.Items.A, MyApp.Items.B",
             "expected origin comment for shared_op:\n#{shared_source}"
    end

    test "transitively-migrated private helper gets origin comment", %{tmp: tmp} do
      # `caller/1` is a clone between A and B and pulls in the
      # helper `unique_compute/1`, which only exists in A. The
      # helper isn't its own clone group (different name in B) so
      # it lands in Shared via the transitive-helper path, with a
      # source comment naming exactly its origin module.
      a = """
      defmodule MyApp.Items.A do
        def caller(x) do
          unique_compute(x)
          |> Kernel.+(1)
          |> Kernel.*(2)
        end

        defp unique_compute(x) do
          x
          |> Kernel.*(3)
          |> Kernel.+(7)
        end
      end
      """

      # B has an identical caller/1 (same AST → same hash → clone)
      # but no `unique_compute/1` definition. The detector only
      # looks at AST shape, not at whether the call resolves; the
      # helper is migratable from A's body alone, so it lands in
      # Shared as a transitive helper sourced solely from A.
      b = """
      defmodule MyApp.Items.B do
        def caller(x) do
          unique_compute(x)
          |> Kernel.+(1)
          |> Kernel.*(2)
        end
      end
      """

      _plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      shared_source = File.read!(Path.join(tmp, "lib/my_app/items/shared.ex"))

      # caller/1 is a clone — both modules.
      assert shared_source =~ "# extracted from: MyApp.Items.A, MyApp.Items.B\n  def caller(x)",
             "expected origin comment over caller:\n#{shared_source}"

      # unique_compute is a transitive helper from A only. It stays
      # `defp` in Shared because it's only called from caller/1,
      # which now also lives in Shared.
      assert shared_source =~
               ~r/# extracted from: MyApp\.Items\.A\n\s*defp? unique_compute\(x\)/,
             "expected origin comment over unique_compute helper:\n#{shared_source}"
    end
  end

  describe "module-attribute co-migration" do
    # Bodies that reference module attributes used to be skipped
    # outright. New behaviour: if every clone module defines the
    # attribute identically AND the value is a structural literal
    # (no function calls), co-migrate the attribute into Shared.
    test "value-literal attribute is migrated to Shared", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        @sentinel_oz "0"

        def caller(x) do
          @sentinel_oz
          |> Kernel.<>(x)
          |> String.upcase()
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        @sentinel_oz "0"

        def caller(x) do
          @sentinel_oz
          |> Kernel.<>(x)
          |> String.upcase()
        end
      end
      """

      _plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      shared_source = File.read!(Path.join(tmp, "lib/my_app/items/shared.ex"))

      assert shared_source =~ ~s|@sentinel_oz "0"|,
             "expected @sentinel_oz attribute to be co-migrated:\n#{shared_source}"

      assert shared_source =~ "def caller(x)",
             "expected caller/1 in shared:\n#{shared_source}"
    end

    test "attribute defined identically in all modules — verify originals still keep it",
         %{tmp: tmp} do
      # We do NOT delete attributes from the originals — other code
      # in the same module might still reference them. The Shared
      # module gets its own copy.
      a = """
      defmodule MyApp.Items.A do
        @retries 3

        def caller(x) do
          x
          |> Kernel.+(@retries)
          |> Kernel.*(2)
        end

        def unrelated, do: @retries
      end
      """

      b = """
      defmodule MyApp.Items.B do
        @retries 3

        def caller(x) do
          x
          |> Kernel.+(@retries)
          |> Kernel.*(2)
        end
      end
      """

      _plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      shared_source = File.read!(Path.join(tmp, "lib/my_app/items/shared.ex"))

      assert shared_source =~ "@retries 3",
             "expected @retries to be co-migrated:\n#{shared_source}"
    end

    test "attribute with diverging values blocks the extraction", %{tmp: tmp} do
      # Same attribute name, different values — co-migration would
      # silently pick one. Skip the whole clone group instead.
      a = """
      defmodule MyApp.Items.A do
        @retries 3

        def caller(x) do
          x
          |> Kernel.+(@retries)
          |> Kernel.*(2)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        @retries 5

        def caller(x) do
          x
          |> Kernel.+(@retries)
          |> Kernel.*(2)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      assert plan == %{}

      refute File.exists?(Path.join(tmp, "lib/my_app/items/shared.ex")),
             "expected no shared module on diverging attribute values"
    end

    test "compile-time-evaluated attribute (function call in value) blocks extraction",
         %{tmp: tmp} do
      # `@now DateTime.utc_now()` evaluates at *each module's*
      # compile time — both modules can have textually identical
      # AST but different runtime values. Refuse to migrate.
      a = """
      defmodule MyApp.Items.A do
        @now DateTime.utc_now()

        def caller(x) do
          @now
          |> Map.from_struct()
          |> Map.put(:input, x)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        @now DateTime.utc_now()

        def caller(x) do
          @now
          |> Map.from_struct()
          |> Map.put(:input, x)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      assert plan == %{}
    end

    test "missing attribute in one module blocks the extraction", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        @retries 3

        def caller(x) do
          x
          |> Kernel.+(@retries)
          |> Kernel.*(2)
        end
      end
      """

      # B references @retries but never defines it — the body
      # wouldn't compile in Shared without the attribute, and B is
      # itself broken. Skip rather than guess.
      b = """
      defmodule MyApp.Items.B do
        def caller(x) do
          x
          |> Kernel.+(@retries)
          |> Kernel.*(2)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      assert plan == %{}
    end

    test "transitive helper that references an attribute migrates with the attribute",
         %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        @factor 7

        def caller(x) do
          step(x)
          |> Kernel.*(2)
        end

        defp step(x), do: x * @factor
      end
      """

      b = """
      defmodule MyApp.Items.B do
        @factor 7

        def caller(x) do
          step(x)
          |> Kernel.*(2)
        end

        defp step(x), do: x * @factor
      end
      """

      _plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      shared_source = File.read!(Path.join(tmp, "lib/my_app/items/shared.ex"))

      assert shared_source =~ "@factor 7",
             "expected @factor to follow its referencing helper:\n#{shared_source}"
    end
  end

  describe "regression — pre-existing import block must be extended" do
    # Real-world bug from the Phase-4 smoke run:
    # ParametricClone runs first and writes
    #
    #     import MyApp.Items.Shared, only: [foo_shared: 1]
    #
    # to a module. ExtractSharedModule runs afterwards and migrates a
    # `defp helper/1` from that same module to MyApp.Items.Shared.
    # `build_import_patches/2` skips its own insertion because
    # `module_already_imports?/2` matches the pre-existing import block.
    # Result: helper is gone from the original, the existing import
    # `only:` list does NOT include `helper: 1`, and the caller compiles
    # to an undefined function reference.
    #
    # Either the existing `only:` list must be extended to include the
    # new helper, or a separate `import` line must be appended for the
    # new helper. Either way, after the refactor every unqualified call
    # to a migrated helper MUST resolve.
    test "extends the only:-list of a pre-existing import for the same target",
         %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        import MyApp.Items.Shared, only: [foo_shared: 1]

        def caller(x) do
          helper(x)
        end

        defp helper(:a), do: :one
        defp helper(:b), do: :two
        defp helper(_), do: :other
      end
      """

      b = """
      defmodule MyApp.Items.B do
        import MyApp.Items.Shared, only: [foo_shared: 1]

        def caller(x) do
          helper(x)
        end

        defp helper(:a), do: :one
        defp helper(:b), do: :two
        defp helper(_), do: :other
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan)

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path), "shared module must exist on disk"
      shared_source = File.read!(shared_path)

      assert shared_source =~ ~r/def helper\(/, """
      `helper/1` should be migrated to Shared as a public def.
      shared:
      #{shared_source}
      """

      refute result_a =~ ~r/defp helper\(/, """
      `defp helper` should be removed from the original now that it
      lives in Shared. result:
      #{result_a}
      """

      # The caller `caller/1` is NOT a clone (it stays put) and must
      # resolve `helper(x)` after the refactor. That means SOME `import
      # MyApp.Items.Shared` directive in the file must include
      # `helper: 1` in its `only:` list.
      assert result_a =~ ~r/import MyApp\.Items\.Shared,\s*only:\s*\[[^\]]*helper:\s*1[^\]]*\]/s,
             """
             expected an `import MyApp.Items.Shared, only: [..., helper: 1, ...]`
             in the file — the original had only `[foo_shared: 1]`, and
             the new helper migration must extend that list (or add a
             second import). Result:
             #{result_a}
             """

      # Sanity: the pre-existing `foo_shared: 1` reference must not be
      # lost. If we replace the existing import wholesale it'd break
      # callers of `foo_shared` too.
      assert result_a =~ ~r/foo_shared:\s*1/, """
      pre-existing `foo_shared: 1` import was lost. Result:
      #{result_a}
      """
    end
  end

  describe "regression — pre-existing private helper in Shared must not be imported" do
    # Real-world bug: ExtractParametricClone runs first and writes
    # `MyApp.Items.Shared` containing `defp helper/2` (a private helper
    # that backs the ParametricClone-generated `_shared` functions).
    # ExtractSharedModule then plans to migrate the same `defp helper/2`
    # from the source modules and — because the function name/arity is
    # not yet present as a *def* — extends the source modules' `import
    # MyApp.Items.Shared, only: [...]` list with `helper: 2`.
    #
    # The result is a hard `cannot import … because it is undefined or
    # private` compile error: the helper IS in Shared, but as `defp`,
    # so it can't be imported.
    #
    # Either the loser-side rewrite must be skipped entirely (the
    # `defp` stays local in the source modules — safe duplication) OR
    # the existing `defp` in Shared must be promoted to `def`. Either
    # way, the post-refactor codebase must compile.
    test "skips the loser rewrite when target already has the helper as defp",
         %{tmp: tmp} do
      shared_dir = Path.join(tmp, "lib/my_app/items")
      File.mkdir_p!(shared_dir)

      # Pre-existing Shared module (as ParametricClone would write it):
      # contains a `_shared` public function plus a private `helper/2`
      # used internally by it.
      pre_existing_shared = """
      defmodule MyApp.Items.Shared do
        def big_op_shared(x, y, z) do
          a = helper(x, y)
          b = helper(y, z)
          c = helper(z, x)
          a + b + c
        end

        defp helper(x, y) do
          base = x + y
          base * 2 + 1
        end
      end
      """

      File.write!(Path.join(shared_dir, "shared.ex"), pre_existing_shared)

      # Source modules: each has a clone of `caller/1` (above min_mass)
      # AND a clone of `defp helper/2`. ExtractSharedModule will see
      # that `helper/2` is reachable from `caller/1` and plan to migrate
      # it — but `helper/2` already exists in Shared as a *private*
      # function (above), so the synthetic
      # `import MyApp.Items.Shared, only: [helper: 2]` it would add is
      # a hard compile error.
      a = """
      defmodule MyApp.Items.A do
        import MyApp.Items.Shared, only: [big_op_shared: 3]

        def caller(x, y, z) do
          a = helper(x, y)
          b = helper(y, z)
          c = helper(z, x)
          a + b + c
        end

        defp helper(x, y) do
          base = x + y
          base * 2 + 1
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        import MyApp.Items.Shared, only: [big_op_shared: 3]

        def caller(x, y, z) do
          a = helper(x, y)
          b = helper(y, z)
          c = helper(z, x)
          a + b + c
        end

        defp helper(x, y) do
          base = x + y
          base * 2 + 1
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan)

      # The hard requirement: the post-refactor file must NEVER carry
      # `import …Shared, only: [helper: 2]` while `helper/2` exists in
      # Shared as `defp`. That's a guaranteed `cannot import … because
      # it is private` compile error.
      refute result_a =~ ~r/import MyApp\.Items\.Shared,\s*only:\s*\[[^\]]*helper:\s*2[^\]]*\]/s,
             """
             refactor injected `import MyApp.Items.Shared, only: [..., helper: 2, ...]`
             but `helper/2` exists in Shared only as `defp` — this would
             fail to compile with `cannot import … because it is private`.
             Result:
             #{result_a}
             """

      # Pre-existing `big_op_shared: 1` reference must survive — we
      # don't want to clobber unrelated imports.
      assert result_a =~ ~r/big_op_shared:\s*3/, """
      pre-existing `big_op_shared: 3` import was lost. Result:
      #{result_a}
      """
    end
  end

  describe "regression — excluded path prefixes are filtered from sources" do
    # When the CLI runs `mix refactor ./test/**/*.ex`, Test-Quellen
    # landen in build_plan/2. Ein Test-Modul wie `MyApp.Shared`
    # in `test/support/shared.ex` würde sonst ein `lib/my_app/shared.ex`
    # aus Test-Code ableiten — Test-Module gehören nicht in den
    # Lib-Tree. `build_plan/2` muss `test/`- und
    # `dev/refactors/refactors/`-Pfade aus den Quellen droppen, bevor
    # es nach Klonen sucht.
    test "test/ paths are dropped from sources", %{tmp: tmp} do
      a = """
      defmodule MyApp.Foo do
        def big(q) do
          q
          |> List.wrap()
          |> Enum.map(& &1.id)
          |> Enum.uniq()
        end
      end
      """

      b = """
      defmodule MyApp.Bar do
        def big(q) do
          q
          |> List.wrap()
          |> Enum.map(& &1.id)
          |> Enum.uniq()
        end
      end
      """

      plan =
        ExtractSharedModule.build_plan(
          [{"test/foo_test.exs", a}, {"test/bar_test.exs", b}],
          min_mass: 5,
          write_root: tmp
        )

      assert plan == %{}
      refute File.exists?(Path.join(tmp, "lib/my_app/shared.ex"))
    end

    test "dev/ paths are dropped from sources (whole subtree, not just dev/refactors/refactors/)",
         %{tmp: tmp} do
      a = """
      defmodule Num42.Refactors.Foo do
        def big(q) do
          q
          |> List.wrap()
          |> Enum.map(& &1.id)
          |> Enum.uniq()
        end
      end
      """

      b = """
      defmodule Num42.Refactors.Bar do
        def big(q) do
          q
          |> List.wrap()
          |> Enum.map(& &1.id)
          |> Enum.uniq()
        end
      end
      """

      plan =
        ExtractSharedModule.build_plan(
          [
            {"dev/refactors/foo.ex", a},
            {"dev/refactors/bar.ex", b}
          ],
          min_mass: 5,
          write_root: tmp
        )

      # Dev-code (refactor engine, AST helpers, mix tasks) is not
      # part of the production tree; extracting Shared modules from
      # it would leak dev/ code into lib/ via the module-name → path
      # convention.
      assert plan == %{}
    end

    test "leading ./ prefix on excluded paths is still filtered", %{tmp: tmp} do
      # Shell glob expansion (`mix refactor ./dev/**/*.ex`) leaves
      # `./` on every path. The filter must normalize that prefix
      # away, otherwise excluded paths leak through and dev/lib
      # extractions happen anyway.
      a = """
      defmodule Num42.Refactors.Foo do
        def big(q) do
          q
          |> List.wrap()
          |> Enum.map(& &1.id)
          |> Enum.uniq()
        end
      end
      """

      b = """
      defmodule Num42.Refactors.Bar do
        def big(q) do
          q
          |> List.wrap()
          |> Enum.map(& &1.id)
          |> Enum.uniq()
        end
      end
      """

      plan =
        ExtractSharedModule.build_plan(
          [
            {"./dev/refactors/foo.ex", a},
            {"./dev/refactors/bar.ex", b}
          ],
          min_mass: 5,
          write_root: tmp
        )

      assert plan == %{}
    end

    test "mixed lib/ and test/ sources: only lib/ entries form the plan", %{tmp: tmp} do
      lib_a = """
      defmodule MyApp.A do
        def shared_op(scope, attrs) do
          scope
          |> Map.put(:attrs, attrs)
          |> Map.put(:assigned, true)
        end
      end
      """

      lib_b = """
      defmodule MyApp.B do
        def shared_op(scope, attrs) do
          scope
          |> Map.put(:attrs, attrs)
          |> Map.put(:assigned, true)
        end
      end
      """

      # Test-Quelle definiert eine dritte Kopie; die darf NICHT in den
      # Plan und nicht in die Origin-Liste einfließen.
      test_c = """
      defmodule MyApp.Test.C do
        def shared_op(scope, attrs) do
          scope
          |> Map.put(:attrs, attrs)
          |> Map.put(:assigned, true)
        end
      end
      """

      plan =
        ExtractSharedModule.build_plan(
          [
            {"lib/my_app/a.ex", lib_a},
            {"lib/my_app/b.ex", lib_b},
            {"test/support/c.ex", test_c}
          ],
          min_mass: 5,
          write_root: tmp
        )

      assert Map.has_key?(plan, MyApp.A)
      assert Map.has_key?(plan, MyApp.B)
      refute Map.has_key?(plan, MyApp.Test.C)
    end
  end
end
