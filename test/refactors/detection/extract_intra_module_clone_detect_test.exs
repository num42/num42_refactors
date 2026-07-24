defmodule Number42.Refactors.Detection.ExtractIntraModuleCloneDetectTest do
  @moduledoc """
  ExtractIntraModuleClone's detection, swept out of `transform/2`.

  The gate this exposes is the mass floor: a byte-identical clone pair
  below `:min_mass` used to be filtered out before anything recorded it,
  so a micro-clone looked exactly like no clone. It is now a declined
  finding carrying the measured mass.
  """
  use ExUnit.Case, async: true

  alias Number42.Refactors.Detection.Finding
  alias Number42.Refactors.Ex.ExtractIntraModuleClone

  defp detect(source, opts \\ []), do: ExtractIntraModuleClone.detect(source, opts)

  defp transform(source, opts \\ []), do: ExtractIntraModuleClone.transform(source, opts)

  defp clone_body do
    """
        total = a + b
        scaled = total * 3
        label = "sum: " <> Integer.to_string(scaled)
        %{total: total, scaled: scaled, label: label}
    """
  end

  defp two_clones do
    """
    defmodule Dup do
      def alpha(a, b) do
    #{clone_body()}  end

      def beta(a, b) do
    #{clone_body()}  end
    end
    """
  end

  describe "accepted findings" do
    test "flags a group of identical-body clauses" do
      accepted = two_clones() |> detect() |> Finding.accepted()

      assert [%Finding{kind: :intra_module_clone} = finding] = accepted
      assert finding.evidence.names == [:alpha, :beta]
      assert finding.evidence.clones == 1
    end

    test "the accepted group is one transform/2 actually collapses" do
      source = two_clones()

      assert source |> detect() |> Finding.accepted() != []
      assert transform(source) != source
    end

    test "reports the module and the surviving function as scope" do
      [finding] = two_clones() |> detect() |> Finding.accepted()

      assert finding.scope.module == Dup
      assert finding.scope.function == :alpha
    end

    test "reports the line of the surviving clause" do
      [finding] = two_clones() |> detect() |> Finding.accepted()

      assert finding.line == 2
    end

    test "counts three identical clauses as one group with two clones" do
      source = """
      defmodule Trip do
        def a(a, b) do
      #{clone_body()}  end

        def b(a, b) do
      #{clone_body()}  end

        def c(a, b) do
      #{clone_body()}  end
      end
      """

      [finding] = source |> detect() |> Finding.accepted()

      assert finding.evidence.clones == 2
      assert finding.evidence.names == [:a, :b, :c]
    end
  end

  describe "declined findings — the mass floor now reports" do
    test "a below-mass clone pair is declined rather than dropped" do
      source = """
      defmodule Tiny do
        def a(x), do: x
        def b(x), do: x
      end
      """

      findings = detect(source)

      assert Finding.accepted(findings) == []
      assert [%Finding{} = declined] = Finding.declined(findings)
      assert declined.evidence.names == [:a, :b]
      assert String.contains?(declined.decline, "min_mass")
    end

    test "a below-mass clone pair is left alone by transform/2" do
      source = """
      defmodule Tiny do
        def a(x), do: x
        def b(x), do: x
      end
      """

      assert transform(source) == source
    end

    test "raising min_mass moves a group from accepted to declined" do
      source = two_clones()

      assert source |> detect() |> Finding.accepted() != []

      declined = source |> detect(min_mass: 500) |> Finding.declined()

      assert Enum.any?(declined, &String.contains?(&1.decline, "min_mass 500"))
      assert transform(source, min_mass: 500) == source
    end

    test "carries the measured mass as evidence so the gate is inspectable" do
      source = """
      defmodule Tiny do
        def a(x), do: x
        def b(x), do: x
      end
      """

      [declined] = source |> detect() |> Finding.declined()

      assert is_integer(declined.evidence.mass)
      assert declined.evidence.mass < declined.evidence.min_mass
    end
  end

  describe "exclusions stay invisible" do
    test "a unique function body produces no finding" do
      source = """
      defmodule Solo do
        def only(a, b) do
      #{clone_body()}  end
      end
      """

      assert detect(source) == []
    end

    test "multi-clause functions are excluded from detection" do
      source = """
      defmodule Multi do
        def a(0), do: :zero
        def a(n), do: n
        def b(0), do: :zero
        def b(n), do: n
      end
      """

      assert Finding.accepted(detect(source)) == []
    end

    test "clauses reading a module attribute are excluded" do
      source = """
      defmodule Attr do
        @scale 3

        def a(a, b) do
          total = a + b
          scaled = total * @scale
          %{total: total, scaled: scaled, label: "x"}
        end

        def b(a, b) do
          total = a + b
          scaled = total * @scale
          %{total: total, scaled: scaled, label: "x"}
        end
      end
      """

      assert Finding.accepted(detect(source)) == []
      assert transform(source) == source
    end
  end

  describe "contract plumbing" do
    test "threads the path from opts into findings" do
      [finding] = two_clones() |> detect(path: "lib/dup.ex") |> Finding.accepted()

      assert finding.path == "lib/dup.ex"
    end

    test "scopes findings to the nested module they were found in" do
      source = """
      defmodule Outer do
        defmodule Inner do
          def a(a, b) do
      #{clone_body()}    end

          def b(a, b) do
      #{clone_body()}    end
        end
      end
      """

      modules = source |> detect() |> Finding.accepted() |> Enum.map(& &1.scope.module)

      assert modules == [Outer.Inner]
    end

    test "returns an empty list for unparseable source" do
      assert detect("defmodule Broken do") == []
    end

    test "is deterministic across runs" do
      assert detect(two_clones()) == detect(two_clones())
    end

    test "declares itself as its own detector" do
      assert ExtractIntraModuleClone.detector() == ExtractIntraModuleClone
    end
  end
end
