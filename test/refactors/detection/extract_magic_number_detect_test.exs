defmodule Number42.Refactors.Detection.ExtractMagicNumberDetectTest do
  @moduledoc """
  ExtractMagicNumber's detection, swept out of `transform/2`.

  The load-bearing property is **agreement**: a group the detector accepts
  is a group the rewrite actually hoists, and a declined group is one the
  rewrite leaves alone. Detection and transform share the gate functions
  precisely so they cannot drift, and these tests pin that.
  """
  use ExUnit.Case, async: true

  alias Number42.Refactors.Detection.Finding
  alias Number42.Refactors.Ex.ExtractMagicNumber

  defp detect(source, opts \\ []), do: ExtractMagicNumber.detect(source, opts)

  defp transform(source, opts \\ []), do: ExtractMagicNumber.transform(source, opts)

  describe "accepted findings" do
    test "flags a numeric literal repeated above the threshold" do
      source = """
      defmodule Client do
        def connect, do: open(timeout: 5000)
        def reconnect, do: open(timeout: 5000)
      end
      """

      accepted = source |> detect() |> Finding.accepted()

      assert [%Finding{kind: :magic_number} = finding] = accepted
      assert finding.evidence.value == 5000
      assert finding.evidence.occurrences == 2
    end

    test "the accepted value is the one transform/2 actually hoists" do
      source = """
      defmodule Client do
        def connect, do: open(timeout: 5000)
        def reconnect, do: open(timeout: 5000)
      end
      """

      [finding] = source |> detect() |> Finding.accepted()
      rewritten = transform(source)

      assert rewritten != source
      assert String.contains?(rewritten, to_string(finding.evidence.value))
      assert String.contains?(rewritten, "@")
    end

    test "carries the module it was found in as scope" do
      source = """
      defmodule Deep.Nested.Client do
        def a, do: open(timeout: 5000)
        def b, do: open(timeout: 5000)
      end
      """

      [finding] = source |> detect() |> Finding.accepted()

      assert finding.scope.module == Deep.Nested.Client
    end

    test "reports the line of the first occurrence" do
      source = """
      defmodule Client do
        def a, do: open(timeout: 5000)
        def b, do: open(timeout: 5000)
      end
      """

      [finding] = source |> detect() |> Finding.accepted()

      assert finding.line == 2
    end
  end

  describe "declined findings — the gates now report instead of discarding" do
    test "a literal below the threshold is declined, not dropped" do
      source = """
      defmodule Client do
        def connect, do: open(timeout: 5000)
      end
      """

      declined = source |> detect() |> Finding.declined()

      assert Enum.any?(declined, &(&1.evidence.value == 5000))
      assert Enum.any?(declined, &String.contains?(&1.decline, "min_occurrences"))
    end

    test "a below-threshold literal is left alone by transform/2" do
      source = """
      defmodule Client do
        def connect, do: open(timeout: 5000)
      end
      """

      assert source |> detect() |> Finding.accepted() == []
      assert transform(source) == source
    end

    test "raising min_occurrences moves a group from accepted to declined" do
      source = """
      defmodule Client do
        def a, do: open(timeout: 5000)
        def b, do: open(timeout: 5000)
      end
      """

      assert source |> detect() |> Finding.accepted() != []

      declined = source |> detect(min_occurrences: 3) |> Finding.declined()

      assert Enum.any?(declined, &String.contains?(&1.decline, "min_occurrences 3"))
      assert transform(source, min_occurrences: 3) == source
    end

    test "occurrences that disagree on meaning are declined with that reason" do
      source = """
      defmodule Config do
        def a, do: [batch_size: 5000]
        def b, do: [max_concurrency: 5000]
      end
      """

      declined = source |> detect() |> Finding.declined()

      assert Enum.any?(declined, &String.contains?(&1.decline, "disagree on meaning"))
      assert transform(source) == source
    end

    test "a group with no informative derivable name is declined" do
      source = """
      defmodule Bare do
        def a, do: 240 + 240
      end
      """

      findings = detect(source)
      declined = Finding.declined(findings)

      assert Finding.accepted(findings) == []
      assert Enum.any?(declined, &String.contains?(&1.decline, "no informative name"))
      assert transform(source) == source
    end
  end

  describe "exclusions stay invisible to detection" do
    test "idiomatic small numbers are not reported at all" do
      source = """
      defmodule Idiomatic do
        def a, do: 0 + 1 + 2
        def b, do: 0 + 1 + 2
      end
      """

      assert detect(source) == []
    end

    test "literals inside a nested module belong to that module, not the outer one" do
      source = """
      defmodule Outer do
        defmodule Inner do
          def a, do: open(timeout: 5000)
          def b, do: open(timeout: 5000)
        end
      end
      """

      scopes = source |> detect() |> Finding.accepted() |> Enum.map(& &1.scope.module)

      assert scopes == [Outer.Inner]
    end
  end

  describe "contract plumbing" do
    test "threads the path from opts into findings" do
      source = """
      defmodule Client do
        def a, do: open(timeout: 5000)
        def b, do: open(timeout: 5000)
      end
      """

      [finding] = source |> detect(path: "lib/client.ex") |> Finding.accepted()

      assert finding.path == "lib/client.ex"
    end

    test "returns an empty list for unparseable source" do
      assert detect("defmodule Broken do") == []
    end

    test "is deterministic across runs" do
      source = """
      defmodule Client do
        def a, do: open(timeout: 5000, retry: 9001)
        def b, do: open(timeout: 5000, retry: 9001)
      end
      """

      assert detect(source) == detect(source)
    end

    test "declares itself as its own detector" do
      assert ExtractMagicNumber.detector() == ExtractMagicNumber
    end
  end
end
