defmodule Number42.Refactors.Ex.ExtractPatchRunnerTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractPatchRunner

  describe "rewrites the canonical patch skeleton" do
    test "swaps the `use` line and drops the boilerplate, keeping build_patches" do
      before_source = """
      defmodule MyApp.Refactors.Demo do
        use Number42.Refactors.Refactor

        alias Sourceror.Patch

        @impl Number42.Refactors.Refactor
        def description, do: "demo"

        @impl Number42.Refactors.Refactor
        def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)
        defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
        defp apply_patches({:error, _}, source), do: source

        defp build_patches(ast) do
          ast
          |> Macro.prewalker()
          |> Enum.flat_map(&maybe_patch/1)
        end

        defp maybe_patch({:foo, _, _} = node), do: [Patch.replace(node, "bar")]
        defp maybe_patch(_), do: []
        defp patch_or_passthrough([], source), do: source
        defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
      end
      """

      expected = """
      defmodule MyApp.Refactors.Demo do
        use Number42.Refactors.PatchRefactor

        alias Sourceror.Patch

        @impl Number42.Refactors.Refactor
        def description, do: "demo"

        defp build_patches(ast) do
          ast
          |> Macro.prewalker()
          |> Enum.flat_map(&maybe_patch/1)
        end

        defp maybe_patch({:foo, _, _} = node), do: [Patch.replace(node, "bar")]
        defp maybe_patch(_), do: []
      end
      """

      assert_rewrites(ExtractPatchRunner, before_source, expected)
    end

    test "rewrites the piped patch_or_passthrough form too" do
      before_source = """
      defmodule MyApp.Refactors.Piped do
        use Number42.Refactors.Refactor

        def description, do: "piped"

        def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)
        defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
        defp apply_patches({:error, _}, source), do: source

        defp build_patches(_ast), do: []
        defp patch_or_passthrough([], source), do: source
        defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
      end
      """

      expected = """
      defmodule MyApp.Refactors.Piped do
        use Number42.Refactors.PatchRefactor

        def description, do: "piped"

        defp build_patches(_ast), do: []
      end
      """

      assert_rewrites(ExtractPatchRunner, before_source, expected)
    end

    test "rewritten output compiles and is idempotent" do
      before_source = """
      defmodule MyApp.Refactors.Compiles do
        use Number42.Refactors.Refactor

        @impl Number42.Refactors.Refactor
        def description, do: "compiles"

        @impl Number42.Refactors.Refactor
        def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)
        defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
        defp apply_patches({:error, _}, source), do: source

        defp build_patches(_ast), do: []
        defp patch_or_passthrough([], source), do: source
        defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
      end
      """

      assert_idempotent(ExtractPatchRunner, before_source)
    end
  end

  describe "skips non-canonical control flow" do
    test "leaves a transform that reads opts untouched" do
      source = """
      defmodule MyApp.Refactors.UsesOpts do
        use Number42.Refactors.Refactor

        def description, do: "opts"

        def transform(source, opts) do
          min = Keyword.get(opts, :min, 0)
          Sourceror.parse_string(source) |> apply_patches(source, min)
        end

        defp apply_patches({:ok, ast}, source, min), do: build_patches(ast, min) |> patch_or_passthrough(source)
        defp apply_patches({:error, _}, source, _min), do: source

        defp build_patches(_ast, _min), do: []
        defp patch_or_passthrough([], source), do: source
        defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
      end
      """

      assert_unchanged(ExtractPatchRunner, source)
    end

    test "leaves a module already using PatchRefactor untouched" do
      source = """
      defmodule MyApp.Refactors.Already do
        use Number42.Refactors.PatchRefactor

        def description, do: "already"

        def build_patches(_ast), do: []
      end
      """

      assert_unchanged(ExtractPatchRunner, source)
    end

    test "leaves a module whose apply_patches branch differs" do
      source = """
      defmodule MyApp.Refactors.CustomBranch do
        use Number42.Refactors.Refactor

        def description, do: "custom"

        def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)
        defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
        defp apply_patches({:error, reason}, _source), do: raise(reason)

        defp build_patches(_ast), do: []
        defp patch_or_passthrough([], source), do: source
        defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
      end
      """

      assert_unchanged(ExtractPatchRunner, source)
    end

    test "leaves a module that lacks the boilerplate entirely" do
      source = """
      defmodule MyApp.Refactors.Bespoke do
        use Number42.Refactors.Refactor

        def description, do: "bespoke"

        def transform(source, _opts) do
          case Sourceror.parse_string(source) do
            {:ok, ast} -> do_thing(ast, source)
            {:error, _} -> source
          end
        end

        defp do_thing(_ast, source), do: source
      end
      """

      assert_unchanged(ExtractPatchRunner, source)
    end

    test "leaves a module where a skeleton helper name is referenced elsewhere" do
      source = """
      defmodule MyApp.Refactors.HelperReused do
        use Number42.Refactors.Refactor

        def description, do: "reused"

        def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)
        defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
        defp apply_patches({:error, _}, source), do: source

        defp build_patches(ast), do: ast |> nested() |> wrap()
        defp nested(ast), do: apply_patches({:ok, ast}, "")
        defp wrap(_), do: []
        defp patch_or_passthrough([], source), do: source
        defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
      end
      """

      assert_unchanged(ExtractPatchRunner, source)
    end

    test "leaves a non-refactor module alone" do
      source = """
      defmodule MyApp.PlainModule do
        def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)
        defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
        defp apply_patches({:error, _}, source), do: source
        defp build_patches(_ast), do: []
        defp patch_or_passthrough([], source), do: source
        defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
      end
      """

      assert_unchanged(ExtractPatchRunner, source)
    end
  end
end
