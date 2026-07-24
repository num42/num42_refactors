defmodule Number42.Refactors.Detection.ConvertedSeamsTest do
  @moduledoc """
  The two pre-existing candidate-finding seams, read through the
  `Number42.Refactors.Detection` contract.

  These are the cheap validation of the contract: both modules already
  had a `find_candidates/2` seam, so `detect/2` must agree with it
  exactly rather than re-deciding anything.
  """
  use ExUnit.Case, async: true

  alias Number42.Refactors.Detection
  alias Number42.Refactors.Detection.Finding
  alias Number42.Refactors.Ex.ExtractHeexComponentBySeam
  alias Number42.Refactors.Ex.ExtractToPublicComponent

  # A render function with one large, cohesive subtree reading its own
  # assigns — the shape both detectors are built to find.
  defp seamed_source do
    """
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
  end

  describe "ExtractHeexComponentBySeam.detect/2" do
    test "returns findings, one per candidate find_candidates/2 reports" do
      source = seamed_source()

      candidates = ExtractHeexComponentBySeam.find_candidates(source)
      findings = ExtractHeexComponentBySeam.detect(source)

      assert length(findings) == length(candidates)
      assert Enum.all?(findings, &match?(%Finding{}, &1))
    end

    test "the accept/decline verdict matches the candidate's" do
      source = seamed_source()

      candidates = ExtractHeexComponentBySeam.find_candidates(source)
      findings = ExtractHeexComponentBySeam.detect(source)

      assert Enum.map(findings, & &1.accepted?) == Enum.map(candidates, & &1.accepted)
      assert Enum.map(findings, & &1.decline) == Enum.map(candidates, & &1.decline)
    end

    test "carries the gate metrics as evidence" do
      finding =
        seamed_source()
        |> ExtractHeexComponentBySeam.detect()
        |> List.first()

      assert %{nodes: nodes, lines: lines, leak: leak} = finding.evidence
      assert is_integer(nodes) and is_integer(lines) and is_float(leak)
    end

    test "threads the path from opts into every finding" do
      findings = ExtractHeexComponentBySeam.detect(seamed_source(), path: "lib/page.ex")

      assert Enum.all?(findings, &(&1.path == "lib/page.ex"))
    end

    test "attributes every finding to the refactor that produced it" do
      findings = ExtractHeexComponentBySeam.detect(seamed_source())

      assert Enum.all?(findings, &(&1.refactor == ExtractHeexComponentBySeam))
    end

    test "detects nothing in a template with no large subtree" do
      source = """
      defmodule MyAppWeb.TinyLive do
        use Phoenix.LiveView

        def render(assigns) do
          ~H"<span>{@x}</span>"
        end
      end
      """

      assert ExtractHeexComponentBySeam.detect(source) == []
    end
  end

  describe "ExtractToPublicComponent.detect/2" do
    test "agrees with find_candidates/2 on count and verdict" do
      source = seamed_source()

      candidates = ExtractToPublicComponent.find_candidates(source)
      findings = ExtractToPublicComponent.detect(source)

      assert length(findings) == length(candidates)
      assert Enum.map(findings, & &1.accepted?) == Enum.map(candidates, & &1.accepted)
    end

    test "carries the motif and component kind as evidence" do
      finding =
        seamed_source()
        |> ExtractToPublicComponent.detect()
        |> List.first()

      assert Map.has_key?(finding.evidence, :motif)
      assert finding.evidence.component_kind in [:function, :live_component]
    end
  end

  describe "both refactors declare their detector" do
    test "detector/0 points at a module the Detection layer can run" do
      for refactor <- [ExtractHeexComponentBySeam, ExtractToPublicComponent] do
        assert Detection.detector?(refactor.detector())
      end
    end
  end

  describe "Detection.run/3 over the converted seams" do
    test "drives per-source detection across a corpus, tagging each path" do
      findings =
        Detection.run(ExtractHeexComponentBySeam, [
          {"lib/b.ex", seamed_source()},
          {"lib/a.ex", seamed_source()}
        ])

      paths = findings |> Enum.map(& &1.path) |> Enum.uniq()

      assert paths == ["lib/a.ex", "lib/b.ex"]
    end

    test "findings can be grouped per file" do
      grouped =
        Detection.run(ExtractHeexComponentBySeam, [{"lib/a.ex", seamed_source()}])
        |> Finding.by_path()

      assert Map.keys(grouped) == ["lib/a.ex"]
    end

    test "is deterministic across repeated runs" do
      corpus = [{"lib/a.ex", seamed_source()}, {"lib/b.ex", seamed_source()}]

      first = Detection.run(ExtractHeexComponentBySeam, corpus)
      second = Detection.run(ExtractHeexComponentBySeam, corpus)

      assert first == second
    end
  end
end
