defmodule Number42.Refactors.Ex.PromoteRepeatedPrivateHelpersTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.PromoteRepeatedPrivateHelpers

  @subject PromoteRepeatedPrivateHelpers

  # Like ExtractSharedModule, this refactor writes a fresh support module
  # to disk when it plans an extraction. Tests run in a per-test tmp_dir
  # and pass `:write_root` so the planner writes there, not the project
  # root. It is also default-OFF, so every plan/transform passes
  # `enabled: true`.

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "promote_helpers_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp prepared(sources, opts),
    do:
      sources
      |> PromoteRepeatedPrivateHelpers.build_plan(
        Keyword.merge([min_mass: 5, enabled: true], opts)
      )

  describe "default-OFF gate" do
    test "transform is a no-op unless enabled: true", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def caller(x), do: patch(x, 1)

        defp patch(x, n) do
          x
          |> Map.put(:patched, true)
          |> Map.put(:n, n)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def caller(x), do: patch(x, 1)

        defp patch(x, n) do
          x
          |> Map.put(:patched, true)
          |> Map.put(:n, n)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      # Plan exists, but transform without enabled: true must not touch source.
      assert_unchanged(@subject, a, prepared: plan)

      # And with enabled: true it does rewrite.
      result_a = apply_refactor(@subject, a, prepared: plan, enabled: true)
      refute result_a =~ "defp patch"
    end
  end

  describe "rewrites — identical helper in two modules" do
    test "support module is created, both modules call into it", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def caller(x), do: patch(x, 1)

        defp patch(target, n) do
          target
          |> Map.put(:patched, true)
          |> Map.put(:n, n)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def other(y), do: patch(y, 2)

        defp patch(target, n) do
          target
          |> Map.put(:patched, true)
          |> Map.put(:n, n)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan, enabled: true)
      result_b = apply_refactor(@subject, b, prepared: plan, enabled: true)

      # Local defp is gone in both modules.
      refute result_a =~ "defp patch"
      refute result_b =~ "defp patch"

      # The call sites are rewritten to remote calls into the support module.
      assert result_a =~ "MyApp.Items.Support.patch(x, 1)"
      assert result_b =~ "MyApp.Items.Support.patch(y, 2)"

      support_path = Path.join(tmp, "lib/my_app/items/support.ex")
      assert File.exists?(support_path)

      support_source = File.read!(support_path)
      assert support_source =~ "defmodule MyApp.Items.Support"
      # Promoted to public def so the remote call resolves.
      assert support_source =~ "def patch(target, n)"
      assert support_source =~ "Map.put(:patched, true)"
    end

    test "capture-form call sites are rewritten to the remote capture", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def caller(list), do: Enum.map(list, &patch/1)

        defp patch(target) do
          target
          |> Map.put(:patched, true)
          |> Map.put(:done, true)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def caller(list), do: Enum.map(list, &patch/1)

        defp patch(target) do
          target
          |> Map.put(:patched, true)
          |> Map.put(:done, true)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan, enabled: true)

      # The deleted defp must leave no dangling unqualified capture behind.
      refute result_a =~ "defp patch"
      refute result_a =~ "&patch/1"
      assert result_a =~ "&MyApp.Items.Support.patch/1"

      support_source = File.read!(Path.join(tmp, "lib/my_app/items/support.ex"))
      assert_compiles(support_source <> "\n" <> result_a)
    end

    test "near-identical (var renamed) helpers are still detected as clones", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def caller(x), do: strip_meta(x)

        defp strip_meta(node) do
          node
          |> Map.delete(:line)
          |> Map.delete(:column)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def caller(x), do: strip_meta(x)

        defp strip_meta(ast) do
          ast
          |> Map.delete(:line)
          |> Map.delete(:column)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan, enabled: true)
      assert result_a =~ "MyApp.Items.Support.strip_meta(x)"

      support_source = File.read!(Path.join(tmp, "lib/my_app/items/support.ex"))
      assert support_source =~ "def strip_meta("
    end
  end

  describe "skips" do
    test "single occurrence is left alone (no clone to promote)", %{tmp: tmp} do
      only = """
      defmodule MyApp.Solo do
        def caller(x), do: patch(x, 1)

        defp patch(target, n) do
          target
          |> Map.put(:patched, true)
          |> Map.put(:n, n)
        end
      end
      """

      plan = prepared([{"solo.ex", only}], write_root: tmp)
      assert plan == %{}
      assert_unchanged(@subject, only, prepared: plan, enabled: true)
      refute File.exists?(Path.join(tmp, "lib/my_app/support.ex"))
    end

    test "non-identical helper bodies are not promoted", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def caller(x), do: patch(x, 1)

        defp patch(target, n) do
          target
          |> Map.put(:patched, true)
          |> Map.put(:n, n)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def caller(x), do: patch(x, 1)

        defp patch(target, n) do
          target
          |> Map.put(:patched, false)
          |> Map.put(:count, n)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)
      assert plan == %{}
      assert_unchanged(@subject, a, prepared: plan, enabled: true)
      assert_unchanged(@subject, b, prepared: plan, enabled: true)
    end

    test "helper that reads a module attribute is skipped (closure over @attr)", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        @factor 7

        def caller(x), do: scale(x)

        defp scale(value) do
          value
          |> Kernel.*(@factor)
          |> Kernel.+(1)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        @factor 7

        def caller(x), do: scale(x)

        defp scale(value) do
          value
          |> Kernel.*(@factor)
          |> Kernel.+(1)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)
      assert plan == %{}
      assert_unchanged(@subject, a, prepared: plan, enabled: true)
      refute File.exists?(Path.join(tmp, "lib/my_app/items/support.ex"))
    end

    test "helper that calls another local private function is skipped", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def caller(x), do: outer(x)

        defp outer(value) do
          value
          |> inner()
          |> Kernel.+(1)
        end

        defp inner(value), do: value * 2
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def caller(x), do: outer(x)

        defp outer(value) do
          value
          |> inner()
          |> Kernel.+(1)
        end

        defp inner(value), do: value * 2
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)
      assert plan == %{}
      assert_unchanged(@subject, a, prepared: plan, enabled: true)
    end

    test "trivial helper below min_mass is not promoted", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def caller(x), do: id(x)
        defp id(x), do: x
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def caller(x), do: id(x)
        defp id(x), do: x
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp, min_mass: 10)
      assert plan == %{}
    end

    test "longest common prefix of 1 segment is rejected (no top-level Support dump)", %{tmp: tmp} do
      a = """
      defmodule MyApp.Foo do
        def caller(x), do: patch(x, 1)

        defp patch(target, n) do
          target
          |> Map.put(:patched, true)
          |> Map.put(:n, n)
        end
      end
      """

      b = """
      defmodule OtherApp.Bar do
        def caller(x), do: patch(x, 1)

        defp patch(target, n) do
          target
          |> Map.put(:patched, true)
          |> Map.put(:n, n)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)
      assert plan == %{}
    end
  end

  describe "no prepared plan" do
    test "without a plan, transform/2 is a no-op even when enabled" do
      source = """
      defmodule MyApp.Foo do
        def caller(x), do: patch(x, 1)

        defp patch(target, n) do
          target
          |> Map.put(:patched, true)
          |> Map.put(:n, n)
        end
      end
      """

      assert_unchanged(@subject, source, enabled: true)
    end
  end

  describe "dry-run safety" do
    test "build_plan with dry_run populates the plan but writes nothing" do
      sandbox = Path.join(System.tmp_dir!(), "no_writes_#{System.unique_integer([:positive])}")
      File.mkdir_p!(sandbox)
      on_exit(fn -> File.rm_rf!(sandbox) end)

      a = """
      defmodule MyApp.Items.A do
        def caller(x), do: patch(x, 1)

        defp patch(target, n) do
          target
          |> Map.put(:patched, true)
          |> Map.put(:n, n)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def caller(x), do: patch(x, 1)

        defp patch(target, n) do
          target
          |> Map.put(:patched, true)
          |> Map.put(:n, n)
        end
      end
      """

      plan =
        PromoteRepeatedPrivateHelpers.build_plan(
          [{"a.ex", a}, {"b.ex", b}],
          min_mass: 5,
          enabled: true,
          write_root: sandbox,
          dry_run: true
        )

      assert Map.has_key?(plan, MyApp.Items.A)
      assert Map.has_key?(plan, MyApp.Items.B)

      [entry_a] = Map.fetch!(plan, MyApp.Items.A)
      assert entry_a.target == MyApp.Items.Support
      assert entry_a.name == :patch

      refute File.exists?(Path.join(sandbox, "lib/my_app/items/support.ex"))
    end
  end

  describe "excluded paths" do
    test "test/ and dev/ sources are dropped from clone detection", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def caller(x), do: patch(x, 1)

        defp patch(target, n) do
          target
          |> Map.put(:patched, true)
          |> Map.put(:n, n)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def caller(x), do: patch(x, 1)

        defp patch(target, n) do
          target
          |> Map.put(:patched, true)
          |> Map.put(:n, n)
        end
      end
      """

      plan =
        PromoteRepeatedPrivateHelpers.build_plan(
          [{"test/a_test.exs", a}, {"dev/refactors/b.ex", b}],
          min_mass: 5,
          enabled: true,
          write_root: tmp
        )

      assert plan == %{}
    end
  end

  describe "idempotence" do
    test "second pass after promotion is a no-op", %{tmp: tmp} do
      already_promoted = """
      defmodule MyApp.Items.A do
        def caller(x), do: MyApp.Items.Support.patch(x, 1)
      end
      """

      plan = prepared([{"a.ex", already_promoted}], write_root: tmp)
      assert_unchanged(@subject, already_promoted, prepared: plan, enabled: true)
    end
  end

  describe "produced code compiles" do
    test "rewritten modules + support module compile together", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def caller(x), do: patch(x, 1)

        defp patch(target, n) do
          target
          |> Map.put(:patched, true)
          |> Map.put(:n, n)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def other(y), do: patch(y, 2)

        defp patch(target, n) do
          target
          |> Map.put(:patched, true)
          |> Map.put(:n, n)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan, enabled: true)
      result_b = apply_refactor(@subject, b, prepared: plan, enabled: true)
      support_source = File.read!(Path.join(tmp, "lib/my_app/items/support.ex"))

      assert_compiles(support_source <> "\n" <> result_a <> "\n" <> result_b)
    end
  end
end
