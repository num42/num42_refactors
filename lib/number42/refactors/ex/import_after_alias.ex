defmodule Number42.Refactors.Ex.ImportAfterAlias do
  @moduledoc """
  Reorders module-top directives so that `import` statements sit
  **after** the `alias` block:

      defmodule M do
        import Foo
        alias My.Mod

        def go, do: Mod.run()
      end

  becomes

      defmodule M do
        alias My.Mod
        import Foo

        def go, do: Mod.run()
      end

  ## Why

  In a codebase that uniformly aliases first and imports second, an
  `import` that floats above the `alias` block is visual noise — the
  reader's eye stops, checks "wait, is this special?", and moves on.
  A blanket convention removes the question.

  ## Scope

  - **Module-top only.** Function-local `import`s aren't moved
    (`LiftDirectives` is the refactor for hoisting them out of
    function bodies; this one only reorders what's already at the
    module top).
  - **Requires at least one `alias`.** With no aliases there's
    nothing to reorder around — leave the module alone.
  - **Reorders, never edits.** `import` options
    (`import X, only: [...]`) are spliced from the original source
    via `slice_node/2` so per-directive formatting is preserved.

  ## Procedural mode

  We patch by erasing whole import-lines from the prefix block and
  re-inserting the spliced source after the last `alias`. Not
  expressible as a single ExAST 1:1 rewrite — multiple nodes get
  deleted and one new block is inserted elsewhere.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Move module-top `import` statements after the `alias` block"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Mixing `import` lines into or in front of the `alias` block makes
    the dependency surface scan worse: the reader has to track two
    interleaved kinds of "what's in scope" rather than read aliases as
    one block, then imports as another. A consistent
    `use → alias → import → require` order keeps each section
    homogeneous, so adding a new alias or import has one obvious
    insertion point.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_patches(ast, source) do
    with {:ok, body_exprs} <- module_body(ast),
         imports when imports != [] <- top_level_imports(body_exprs),
         last_alias_node when not is_nil(last_alias_node) <- last_top_level_alias(body_exprs),
         [_ | _] = imports_before <- imports_before_node(imports, last_alias_node) do
      delete_patches = imports_before |> Enum.map(&delete_line_patch(&1))
      insert_patch = build_insert_patch(imports_before, last_alias_node, source)
      [insert_patch | delete_patches]
    else
      _ -> []
    end
  end

  defp module_body({:defmodule, _, [_name, [{_do, body}]]}), do: {:ok, body_to_exprs(body)}

  defp module_body(_), do: :error

  defp top_level_imports(exprs),
    do: exprs |> Enum.filter(&match?({:import, _, args} when is_list(args), &1))

  defp last_top_level_alias(exprs),
    do:
      exprs
      |> Enum.filter(&match?({:alias, _, args} when is_list(args), &1))
      |> List.last()

  defp imports_before_node(imports, ref_node) do
    ref_line = node_line(ref_node)

    imports
    |> Enum.filter(fn imp ->
      end_of_expression_line(imp) < ref_line or node_line(imp) < ref_line
    end)
  end

  defp node_line({_, meta, _}) when is_list(meta), do: Keyword.get(meta, :line, 1)
  defp node_line(_), do: 1

  defp delete_line_patch({_, meta, _} = node) when is_list(meta) do
    start_line = Keyword.get(meta, :line, 1)
    end_line = end_of_expression_line(node)

    range = %{
      end: [line: end_line + 1, column: 1],
      start: [line: start_line, column: 1]
    }

    Patch.new(range, "", false)
  end

  defp build_insert_patch(imports, last_alias_node, source) do
    insert_line = end_of_expression_line(last_alias_node) + 1

    text = Enum.map_join(imports, "\n", &render_import(&1, source)) <> "\n"

    range = %{
      end: [line: insert_line, column: 1],
      start: [line: insert_line, column: 1]
    }

    Patch.new(range, text, false)
  end

  defp render_import(node, source), do: slice_node(source, node) |> import_text_or_render(node)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp import_text_or_render({:ok, text}, _node), do: text |> String.trim_trailing()

  defp import_text_or_render(:error, node), do: node |> Sourceror.to_string()

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
