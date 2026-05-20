defmodule Num42.Refactors.Refactors.ExtractRenamedCloneTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.ExtractRenamedClone

  @subject ExtractRenamedClone

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "extract_renamed_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp prepared(sources, opts),
    do: sources |> ExtractRenamedClone.build_plan(Keyword.merge([min_mass: 5], opts))

  describe "rewrites" do
    test "two modules, two names: shared module hosts the alphabetically-first name", %{tmp: tmp} do
      # MyApp.Items < MyApp.Items.Sub in module-name order, so
      # MyApp.Items wins — `compute/2` is the shared name.
      a = """
      defmodule MyApp.Items do
        def compute(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      b = """
      defmodule MyApp.Items.Sub do
        def derive(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      # Source module: still hosts a wrapper under its original name.
      expected_a = """
      defmodule MyApp.Items do
        def compute(x, y), do: MyApp.Items.Shared.compute(x, y)
      end
      """

      # Loser module: wrapper under its original name pointing at the
      # shared (winning) name.
      expected_b = """
      defmodule MyApp.Items.Sub do
        def derive(x, y), do: MyApp.Items.Shared.compute(x, y)
      end
      """

      assert_rewrites(@subject, a, expected_a, prepared: plan)
      assert_rewrites(@subject, b, expected_b, prepared: plan)

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path)

      shared_source = File.read!(shared_path)
      assert shared_source =~ "defmodule MyApp.Items.Shared"
      assert shared_source =~ "def compute(x, y)"
      refute shared_source =~ "def derive(x, y)"
    end
  end

  describe "skips" do
    test "same name in both modules is left to ExtractSharedModule", %{tmp: tmp} do
      # When names match, the regular ExtractSharedModule already
      # handles it. This refactor only kicks in when names differ.
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

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
      refute File.exists?(Path.join(tmp, "lib/my_app/items/shared.ex"))
    end

    test "different bodies are left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.A do
        def compute(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def derive(x, y) do
          x
          |> Kernel.-(y)
          |> Kernel.*(2)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
    end

    test "single occurrence is left alone", %{tmp: tmp} do
      only = """
      defmodule MyApp.Solo do
        def compute(x, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      plan = prepared([{"solo.ex", only}], write_root: tmp)
      assert_unchanged(@subject, only, prepared: plan)
    end

    test "non-plain-var head is left alone", %{tmp: tmp} do
      # Pattern-match heads can't take a uniform wrapper without
      # losing the pattern.
      a = """
      defmodule MyApp.Items.A do
        def compute(%{key: x}, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      b = """
      defmodule MyApp.Items.B do
        def derive(%{key: x}, y) do
          x
          |> Kernel.+(y)
          |> Kernel.*(2)
        end
      end
      """

      plan = prepared([{"a.ex", a}, {"b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan)
      assert_unchanged(@subject, b, prepared: plan)
    end
  end
end
