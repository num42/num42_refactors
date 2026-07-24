defmodule Number42.Refactors.Detection.ExtractRenamedCloneDetectTest do
  @moduledoc """
  ExtractRenamedClone's detection, swept out of `build_plan/2`.

  This detector exposes the most gates of the family. `build_function_entry/7`
  discarded five per-function exclusions with a bare `[]`, and the
  group-level decision silently passed over three more cases. Telling
  those apart is the point: "no clone exists" and "a clone exists but the
  group was skipped" produce identical (empty) plans.
  """
  use ExUnit.Case, async: true

  alias Number42.Refactors.Detection.Finding
  alias Number42.Refactors.Ex.ExtractRenamedClone

  defp body do
    """
        total = x + y
        scaled = total * 3
        label = "s" <> Integer.to_string(scaled)
        %{total: total, scaled: scaled, label: label}
    """
  end

  defp module_source(module, fun) do
    "defmodule #{module} do\n  def #{fun}(x, y) do\n#{body()}  end\nend\n"
  end

  # `compute` and `compute_alt` both resolve to the "Computation" activity
  # segment, which is what lets the group derive a shared module name.
  defp renamed_corpus do
    [
      {"lib/my_app/items/a.ex", module_source("MyApp.Items.A", "compute")},
      {"lib/my_app/items/b.ex", module_source("MyApp.Items.B", "compute_alt")}
    ]
  end

  defp detect(corpus, opts \\ []) do
    ExtractRenamedClone.detect_corpus(
      corpus,
      Keyword.put_new(opts, :write_root, System.tmp_dir!())
    )
  end

  describe "accepted findings" do
    test "flags both sides of a renamed clone pair" do
      accepted = renamed_corpus() |> detect() |> Finding.accepted()

      assert length(accepted) == 2
      assert Enum.all?(accepted, &(&1.kind == :renamed_clone))
    end

    test "names the shared module the group would be lifted into" do
      [finding | _] = renamed_corpus() |> detect() |> Finding.accepted()

      assert finding.evidence.target == MyApp.Items.Computation
      assert finding.evidence.shared_name == :compute
    end

    test "carries each loser's own file, not the group's path list" do
      paths = renamed_corpus() |> detect() |> Finding.accepted() |> Enum.map(& &1.path)

      assert Enum.sort(paths) == ["lib/my_app/items/a.ex", "lib/my_app/items/b.ex"]
    end

    test "scopes each finding to its module and function" do
      scopes =
        renamed_corpus()
        |> detect()
        |> Finding.accepted()
        |> Enum.map(&{&1.scope.module, &1.scope.function})
        |> Enum.sort()

      assert scopes == [
               {MyApp.Items.A, {:compute, 2}},
               {MyApp.Items.B, {:compute_alt, 2}}
             ]
    end
  end

  describe "group-level declines are distinguished from each other" do
    test "a unique body reports that nothing matches it" do
      declined =
        [{"lib/z/a.ex", module_source("Z.A", "compute")}]
        |> detect()
        |> Finding.declined()

      assert [finding] = declined
      assert String.contains?(finding.decline, "body is unique")
    end

    test "a same-name clone points at ExtractSharedModule instead" do
      declined =
        [
          {"lib/y/a.ex", module_source("Y.A", "compute")},
          {"lib/y/b.ex", module_source("Y.B", "compute")}
        ]
        |> detect()
        |> Finding.declined()

      assert Enum.all?(declined, &String.contains?(&1.decline, "same name"))
      refute Enum.any?(declined, &String.contains?(&1.decline, "body is unique"))
    end

    test "a renamed clone with no derivable segment says so" do
      declined =
        [
          {"lib/x/a.ex", module_source("X.Alpha", "fireplace_value")},
          {"lib/x/b.ex", module_source("X.Beta", "to_label")}
        ]
        |> detect()
        |> Finding.declined()

      assert Enum.all?(declined, &String.contains?(&1.decline, "no shared-module name"))
    end
  end

  describe "per-function exclusions now report" do
    test "a private function is declined as public-only" do
      source = "defmodule P do\n  defp compute(x, y) do\n#{body()}  end\nend\n"

      declined = [{"lib/p.ex", source}] |> detect() |> Finding.declined()

      assert Enum.any?(declined, &String.contains?(&1.decline, "private function"))
    end

    test "a multi-clause function is declined with that reason" do
      source = """
      defmodule M do
        def compute(0, _y), do: :zero
        def compute(x, y) do
      #{body()}  end
      end
      """

      declined = [{"lib/m.ex", source}] |> detect() |> Finding.declined()

      assert Enum.any?(declined, &String.contains?(&1.decline, "multi-clause"))
    end

    test "a non-plain-var head is declined with that reason" do
      source = "defmodule H do\n  def compute(%{k: x}, y) do\n#{body()}  end\nend\n"

      declined = [{"lib/h.ex", source}] |> detect() |> Finding.declined()

      assert Enum.any?(declined, &String.contains?(&1.decline, "plain-var"))
    end

    test "a below-mass body is declined with the measured mass" do
      source = "defmodule T do\n  def compute(x, y), do: x + y\nend\n"

      declined = [{"lib/t.ex", source}] |> detect() |> Finding.declined()

      assert [finding] = declined
      assert String.contains?(finding.decline, "min_mass")
      assert finding.evidence.mass < finding.evidence.min_mass
    end

    test "a module-attribute user is declined with that reason" do
      source = """
      defmodule A do
        @scale 3

        def compute(x, y) do
          total = x + y
          scaled = total * @scale
          label = "s" <> Integer.to_string(scaled)
          %{total: total, scaled: scaled, label: label}
        end
      end
      """

      declined = [{"lib/a.ex", source}] |> detect() |> Finding.declined()

      assert Enum.any?(declined, &String.contains?(&1.decline, "module attribute"))
    end
  end

  describe "detect_corpus/2 writes nothing" do
    setup do
      dir = System.tmp_dir!() |> Path.join("renamed_detect_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      %{dir: dir}
    end

    test "creates no shared module even for an accepted group", %{dir: dir} do
      detect(renamed_corpus(), write_root: dir)

      assert File.ls!(dir) == []
    end

    test "ignores an explicit dry_run: false from the caller", %{dir: dir} do
      detect(renamed_corpus(), write_root: dir, dry_run: false)

      assert File.ls!(dir) == []
    end
  end

  describe "contract plumbing" do
    test "every finding carries a path" do
      findings = detect(renamed_corpus())

      assert Enum.all?(findings, &is_binary(&1.path))
    end

    test "skips unparseable sources rather than raising" do
      assert detect([{"lib/broken.ex", "defmodule Broken do"}]) == []
    end

    test "returns no findings for an empty corpus" do
      assert detect([]) == []
    end

    test "is deterministic across runs" do
      assert detect(renamed_corpus()) == detect(renamed_corpus())
    end

    test "exposes only the corpus entry point" do
      refute function_exported?(ExtractRenamedClone, :detect, 2)
      assert function_exported?(ExtractRenamedClone, :detect_corpus, 2)
    end

    test "declares itself as its own detector" do
      assert ExtractRenamedClone.detector() == ExtractRenamedClone
    end
  end
end
