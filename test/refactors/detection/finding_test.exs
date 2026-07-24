defmodule Number42.Refactors.Detection.FindingTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Detection.Finding

  describe "accept/2" do
    test "marks the finding accepted and leaves no decline reason" do
      finding = Finding.accept(:eex_block, path: "lib/a.ex", line: 12)

      assert finding.accepted?
      assert finding.decline == nil
      assert finding.kind == :eex_block
      assert finding.path == "lib/a.ex"
      assert finding.line == 12
    end

    test "carries evidence and confidence through" do
      finding =
        Finding.accept(:seam, evidence: %{nodes: 9, leak: 0.1}, confidence: 0.8)

      assert finding.evidence == %{nodes: 9, leak: 0.1}
      assert finding.confidence == 0.8
    end

    test "defaults evidence to an empty map and confidence to nil" do
      finding = Finding.accept(:seam)

      assert finding.evidence == %{}
      assert finding.confidence == nil
    end

    test "accepts a map of attrs as well as a keyword list" do
      assert Finding.accept(:seam, %{line: 3}).line == 3
    end
  end

  describe "decline/3" do
    test "records the reason and flips the verdict" do
      finding = Finding.decline(:seam, "seam leaks 3 vars", path: "lib/a.ex")

      refute finding.accepted?
      assert finding.decline == "seam leaks 3 vars"
      assert finding.path == "lib/a.ex"
    end

    test "still carries evidence, so a rejected gate stays inspectable" do
      finding = Finding.decline(:seam, "below min mass", evidence: %{nodes: 2})

      assert finding.evidence == %{nodes: 2}
    end
  end

  describe "accepted/1 and declined/1" do
    setup do
      %{
        findings: [
          Finding.accept(:a),
          Finding.decline(:b, "nope"),
          Finding.accept(:c)
        ]
      }
    end

    test "accepted/1 keeps only the accepted findings", %{findings: findings} do
      assert findings |> Finding.accepted() |> Enum.map(& &1.kind) == [:a, :c]
    end

    test "declined/1 keeps only the declined findings", %{findings: findings} do
      assert findings |> Finding.declined() |> Enum.map(& &1.kind) == [:b]
    end
  end

  describe "by_path/1" do
    test "groups findings by file" do
      grouped =
        [
          Finding.accept(:a, path: "lib/a.ex"),
          Finding.accept(:b, path: "lib/b.ex"),
          Finding.accept(:c, path: "lib/a.ex")
        ]
        |> Finding.by_path()

      assert grouped |> Map.keys() |> Enum.sort() == ["lib/a.ex", "lib/b.ex"]
      assert grouped["lib/a.ex"] |> Enum.map(& &1.kind) == [:a, :c]
    end

    test "drops findings that carry no path context" do
      assert [Finding.accept(:a)] |> Finding.by_path() == %{}
    end
  end

  describe "to_line/1" do
    test "renders path, line, kind and the decline reason" do
      line =
        Finding.decline(:eex_block, "seam leaks 3 vars", path: "lib/a.ex", line: 42)
        |> Finding.to_line()

      assert line == "lib/a.ex:42 [eex_block] declined: seam leaks 3 vars"
    end

    test "renders the description for an accepted finding" do
      line =
        Finding.accept(:seam, path: "lib/a.ex", line: 7, description: "card subtree")
        |> Finding.to_line()

      assert line == "lib/a.ex:7 [seam] card subtree"
    end

    test "falls back to 'accepted' when there is no description" do
      assert Finding.accept(:seam, path: "lib/a.ex", line: 7) |> Finding.to_line() ==
               "lib/a.ex:7 [seam] accepted"
    end

    test "omits the location when the finding has no path" do
      assert Finding.accept(:seam) |> Finding.to_line() == "[seam] accepted"
    end

    test "renders the path alone when the line is unknown" do
      assert Finding.accept(:seam, path: "lib/a.ex") |> Finding.to_line() ==
               "lib/a.ex [seam] accepted"
    end
  end
end
