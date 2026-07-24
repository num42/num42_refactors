defmodule Number42.Refactors.EngineDetectTest do
  @moduledoc """
  The detection-only run mode: `Engine.detect/2` reports findings and
  changes nothing.

  This is the standalone-layer proof from #341 — Detection reachable
  without instantiating Transform.
  """
  use ExUnit.Case, async: true

  alias Number42.Refactors.Engine
  alias Number42.Refactors.Ex.ExtractHeexComponentBySeam
  alias Number42.Refactors.Ex.ExtractToPublicComponent

  @template """
  defmodule MyAppWeb.PageLive do
    use Phoenix.LiveView

    def render(assigns) do
      ~H\"\"\"
      <div>
        <h1>{@title}</h1>
        <section class="card">
          <header class="card-header">
            <h2>{@card_title}</h2>
            <p class="subtitle">{@card_subtitle}</p>
          </header>
          <div class="card-body">
            <p>{@card_body}</p>
            <span class="badge">{@card_badge}</span>
            <p class="meta">{@card_meta}</p>
          </div>
        </section>
      </div>
      \"\"\"
    end
  end
  """

  setup do
    dir = System.tmp_dir!() |> Path.join("detect_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "page_live.ex")
    File.write!(path, @template)

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir, path: path}
  end

  describe "detected_modules/1" do
    test "includes the refactors that declare a runnable detector" do
      modules = Engine.detected_modules()

      assert ExtractHeexComponentBySeam in modules
      assert ExtractToPublicComponent in modules
    end

    test "is a subset of the pipeline modules" do
      pipeline = Engine.pipeline_modules()

      assert Engine.detected_modules() -- pipeline == []
    end

    test "honours :only_modules filtering" do
      modules = Engine.detected_modules(only_modules: [ExtractToPublicComponent])

      assert modules == [ExtractToPublicComponent]
    end

    test "honours :skipped_modules filtering" do
      modules = Engine.detected_modules(skipped_modules: [ExtractToPublicComponent])

      refute ExtractToPublicComponent in modules
    end
  end

  describe "detect/2" do
    test "returns findings for a template with candidate subtrees", %{path: path} do
      findings = Engine.detect([path])

      assert findings != []
      assert Enum.all?(findings, &(&1.path == path))
    end

    test "attributes each finding to the refactor that produced it", %{path: path} do
      refactors = Engine.detect([path]) |> Enum.map(& &1.refactor) |> Enum.uniq()

      assert refactors != []

      assert Enum.all?(refactors, &(&1 in Engine.detected_modules()))
    end

    test "writes nothing — the source is byte-identical afterwards", %{path: path} do
      before = File.read!(path)

      Engine.detect([path])

      assert File.read!(path) == before
    end

    test "creates no new files in the corpus directory", %{dir: dir, path: path} do
      Engine.detect([path])

      assert File.ls!(dir) == ["page_live.ex"]
    end

    test "is deterministic across runs", %{path: path} do
      assert Engine.detect([path]) == Engine.detect([path])
    end

    test "orders findings by path, then line", %{dir: dir, path: path} do
      other = Path.join(dir, "aaa_live.ex")
      File.write!(other, @template)

      findings = Engine.detect([path, other])
      paths = findings |> Enum.map(& &1.path) |> Enum.dedup()

      assert paths == Enum.sort(paths)
    end

    test "restricting to one detector yields only its findings", %{path: path} do
      findings = Engine.detect([path], only_modules: [ExtractToPublicComponent])

      assert Enum.all?(findings, &(&1.refactor == ExtractToPublicComponent))
    end

    test "returns an empty list for a source with no templates", %{dir: dir} do
      plain = Path.join(dir, "plain.ex")
      File.write!(plain, "defmodule Plain do\n  def hello, do: :world\nend\n")

      assert Engine.detect([plain]) == []
    end

    test "returns an empty list for an empty corpus" do
      assert Engine.detect([]) == []
      assert Engine.detect(nil) == []
    end

    test "skips unreadable paths rather than raising", %{dir: dir} do
      assert Engine.detect([Path.join(dir, "does_not_exist.ex")]) == []
    end
  end
end
