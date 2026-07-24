defmodule Number42.Refactors.DetectionTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Detection
  alias Number42.Refactors.Detection.Finding

  defmodule PerSourceDetector do
    use Number42.Refactors.Detection

    @impl Number42.Refactors.Detection
    def detect(source, opts) do
      if String.contains?(source, "smell") do
        [Finding.accept(:smell, path: Keyword.get(opts, :path), line: 1)]
      else
        [Finding.decline(:smell, "no marker", path: Keyword.get(opts, :path))]
      end
    end
  end

  defmodule CorpusDetector do
    use Number42.Refactors.Detection

    @impl Number42.Refactors.Detection
    def detect_corpus(sources, _opts) do
      [Finding.accept(:corpus_wide, evidence: %{files: length(sources)})]
    end
  end

  defmodule NotADetector do
    def description, do: "no detection entry point"
  end

  describe "derived detect_corpus/2" do
    test "maps detect/2 over each source and threads the path in" do
      findings =
        PerSourceDetector.detect_corpus([
          {"lib/a.ex", "has smell"},
          {"lib/b.ex", "clean"}
        ])

      assert findings |> Enum.map(&{&1.path, &1.accepted?}) == [
               {"lib/a.ex", true},
               {"lib/b.ex", false}
             ]
    end

    test "orders findings by path regardless of input order" do
      findings =
        PerSourceDetector.detect_corpus([
          {"lib/z.ex", "smell"},
          {"lib/a.ex", "smell"}
        ])

      assert findings |> Enum.map(& &1.path) == ["lib/a.ex", "lib/z.ex"]
    end

    test "is overridable by a genuinely cross-file detector" do
      findings = CorpusDetector.detect_corpus([{"lib/a.ex", "x"}, {"lib/b.ex", "y"}])

      assert findings |> Enum.map(& &1.evidence) == [%{files: 2}]
    end
  end

  describe "run/3" do
    test "prefers detect_corpus/2 when the module defines its own" do
      assert Detection.run(CorpusDetector, [{"lib/a.ex", "x"}]) |> Enum.map(& &1.kind) ==
               [:corpus_wide]
    end

    test "drives a per-source detector across the corpus" do
      findings = Detection.run(PerSourceDetector, [{"lib/a.ex", "smell"}])

      assert findings |> Enum.map(&{&1.kind, &1.path}) == [{:smell, "lib/a.ex"}]
    end

    test "raises when the module implements neither entry point" do
      assert_raise ArgumentError, ~r/implements neither detect\/2 nor detect_corpus\/2/, fn ->
        Detection.run(NotADetector, [{"lib/a.ex", "x"}])
      end
    end

    test "passes opts through to the detector" do
      findings = Detection.run(PerSourceDetector, [{"lib/a.ex", "clean"}], some_opt: true)

      assert findings |> Enum.map(& &1.accepted?) == [false]
    end
  end

  describe "detector?/1" do
    test "recognises both entry-point shapes" do
      assert Detection.detector?(PerSourceDetector)
      assert Detection.detector?(CorpusDetector)
    end

    test "rejects a module with no detection entry point" do
      refute Detection.detector?(NotADetector)
    end

    test "rejects a module that does not exist" do
      refute Detection.detector?(Elixir.NoSuchDetectorModule)
    end
  end
end
