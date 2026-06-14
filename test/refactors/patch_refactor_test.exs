defmodule Number42.Refactors.PatchRefactorTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.PatchRefactor
  alias Sourceror.Patch

  defmodule UpcaseFoo do
    use Number42.Refactors.PatchRefactor

    @impl Number42.Refactors.Refactor
    def description, do: "rename :foo atoms to :bar"

    defp build_patches(ast) do
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(fn
        {:foo, _, ctx} = node when is_atom(ctx) -> [Patch.replace(node, "bar")]
        _ -> []
      end)
    end
  end

  describe "use Number42.Refactors.PatchRefactor" do
    test "registers the module as a refactor" do
      assert {:is_refactor, [true]} in UpcaseFoo.__info__(:attributes)
    end

    test "transform/2 applies build_patches/1" do
      assert UpcaseFoo.transform("x = foo + 1", []) == "x = bar + 1"
    end

    test "passes the source through unchanged when there are no patches" do
      assert UpcaseFoo.transform("x = baz + 1", []) == "x = baz + 1"
    end

    test "passes the source through unchanged on a parse error" do
      garbage = "defmodule do <<< unbalanced"
      assert UpcaseFoo.transform(garbage, []) == garbage
    end
  end

  describe "patch_or_passthrough/2" do
    test "returns the source unchanged for an empty patch list" do
      assert PatchRefactor.patch_or_passthrough([], "src") == "src"
    end
  end
end
