defmodule Number42.Refactors.Ex.LiftDirectivesTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.LiftDirectives

  @subject LiftDirectives

  describe "rewrites" do
    test "lifts a function-local alias to the module level" do
      before_source = """
      defmodule Foo do
        def go(x) do
          alias My.Helper
          Helper.run(x)
        end
      end
      """

      after_source = """
      defmodule Foo do
        alias My.Helper

        def go(x) do
          Helper.run(x)
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "lifts a function-local import" do
      before_source = """
      defmodule Foo do
        def go(x) do
          import My.Funcs
          run(x)
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ "import My.Funcs"
      refute result =~ "    import My.Funcs"
    end
  end

  describe "preserves attribute/def adjacency" do
    test "lifts alias above @spec, not between @spec and def" do
      before_source = """
      defmodule Foo do
        @moduledoc "Renders things."

        @spec render(map()) :: String.t()
        def render(report) do
          blocks_section(report)
        end

        defp blocks_section(report) do
          alias My.Helper

          Helper.run(report)
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert_adjacent(result, ~r/^\s*@spec render/, ~r/^\s*def render/)
      assert result =~ "alias My.Helper"
      refute result =~ ~r/^\s+alias My\.Helper.*\n\s*def render/m
    end

    test "lifts alias above the @doc/@spec/@impl cluster of a def" do
      before_source = """
      defmodule Foo do
        @moduledoc "thing"

        @impl true
        @doc "renders"
        @spec render(map()) :: String.t()
        def render(report) do
          helper(report)
        end

        defp helper(report) do
          alias My.Helper

          Helper.run(report)
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert_adjacent(result, ~r/^\s*@impl true/, ~r/^\s*@doc/)
      assert_adjacent(result, ~r/^\s*@doc/, ~r/^\s*@spec render/)
      assert_adjacent(result, ~r/^\s*@spec render/, ~r/^\s*def render/)
      assert result =~ "alias My.Helper"
    end

    test "still lifts when there is no attached spec, after the alias block" do
      before_source = """
      defmodule Foo do
        @moduledoc "thing"

        def render(report) do
          helper(report)
        end

        defp helper(report) do
          alias My.Helper

          Helper.run(report)
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ "alias My.Helper"
      refute result =~ "    alias My.Helper"
    end

    test "idempotent with an attached @spec" do
      assert_idempotent(@subject, """
      defmodule Foo do
        @moduledoc "thing"

        @spec render(map()) :: String.t()
        def render(report) do
          helper(report)
        end

        defp helper(report) do
          alias My.Helper

          Helper.run(report)
        end
      end
      """)
    end
  end

  describe "leaves alone" do
    test "directives already at module level" do
      assert_unchanged(@subject, """
      defmodule Foo do
        alias My.Helper

        def go(x), do: Helper.run(x)
      end
      """)
    end

    test "no defmodule wrapper" do
      assert_unchanged(@subject, "x = 1\n")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      defmodule Foo do
        def go(x) do
          alias My.Helper
          Helper.run(x)
        end
      end
      """)
    end
  end

  # Asserts that the first source line matching `upper` is immediately
  # followed (ignoring blank lines) by a line matching `lower`. Used to
  # verify spec/def adjacency survives a lift — squeeze-based helpers
  # collapse the whitespace that carries this signal.
  defp assert_adjacent(source, upper, lower) do
    lines =
      source
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == ""))

    upper_idx = Enum.find_index(lines, &(&1 =~ upper))

    assert upper_idx != nil, """
    Expected a line matching #{inspect(upper)} in:
    #{source}
    """

    next = Enum.at(lines, upper_idx + 1)

    assert next =~ lower, """
    Expected line matching #{inspect(lower)} to immediately follow #{inspect(upper)}.
    Got #{inspect(next)} instead, in:
    #{source}
    """
  end
end
