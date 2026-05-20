defmodule Number42.Refactors.Ex.LiftDirectives do
  @moduledoc """
  Lifts `alias`, `import` and `require` directives out of `def`/`defp`
  bodies onto the enclosing module level.

  Function-local directives are valid Elixir, but they hide
  dependencies from anyone scanning the module top, and they break
  refactors that lift code into new helper functions (the helper
  no longer sees the alias). This refactor moves them up.

  ## Strategy

  - Walk the module body, collect every `def`/`defp` (skipping
    `defmacro`/`defmacrop` and anything inside a `quote do … end`
    block — those produce code for *other* modules, where lifting
    the directive would change semantics).
  - Inside each function body, find every directive node and emit
    a `Patch.replace` that erases the original line.
  - Deduplicate the harvested directives by their AST shape and
    drop any that are already declared at the module top.
  - Insert the survivors after the existing prefix block (`use`,
    `@`, `alias`, etc.) — same insertion strategy as
    `Credo.Check.Design.AliasUsage`.

  ## Known limitations

  - `alias :as` and `import only:`/`except:` options are preserved
    verbatim. If two functions disagree on the `:as` name (e.g.
    one says `alias Foo, as: A`, another `alias Foo, as: B`),
    both are lifted and the second shadows the first at the module
    top — caller-visible behaviour changes. Don't enable this on
    code that does that on purpose.
  - We do **not** rewrite call sites. If lifting an `import` brings
    a name into the module scope that wasn't there before, calls in
    other functions resolve differently. In practice this is the
    point of the refactor (uniform module-level imports), but be
    aware before mass-applying.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @directive_keywords [:alias, :import, :require]

  @impl Number42.Refactors.Refactor
  def description, do: "Lift function-local alias/import/require directives to the module level"

  @impl Number42.Refactors.Refactor
  def priority, do: 220

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `alias`/`import`/`require` inside a function are perfectly legal but
    fragmenting: the reader has to descend into each function to
    understand what's in scope, and the same alias re-declared in three
    functions is just three places to update. Lifting them to the
    module top makes the dependency surface visible on one screen and
    eliminates the "wait, is `Helper` aliased here?" cognitive tax.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_insert_patch(directives, insert_at_line) do
    text =
      directives |> Enum.map_join("\n", &directive_to_string/1)

    range = %{
      end: [line: insert_at_line, column: 1],
      start: [line: insert_at_line, column: 1]
    }

    Patch.new(range, text <> "\n", false)
  end

  defp build_patches(ast), do: find_module_body(ast) |> directive_patches_or_skip()

  defp collect_local_directives({def_kind, _meta, [_head, [{_do, body}]]})
       when def_kind?(def_kind) do
    walk_body(body)
  end

  defp collect_local_directives(_), do: []

  defp collect_module_level_directives(exprs) do
    exprs
    |> Enum.flat_map(fn
      {kw, _, args} = node when kw in @directive_keywords and is_list(args) -> [normalize(node)]
      _ -> []
    end)
  end

  defp delete_patch(%{node: node}) do
    range = directive_line_range(node)
    Patch.new(range, "", false)
  end

  defp directive_line_range({_, meta, _}) when is_list(meta) do
    line = Keyword.get(meta, :line, 1)
    end_line = end_of_expression_line({nil, meta, nil})

    %{
      end: [line: end_line + 1, column: 1],
      start: [line: line, column: 1]
    }
  end

  defp directive_to_string(node),
    do:
      node
      |> Sourceror.to_string()
      |> String.trim_trailing()

  defp find_module_body(ast) do
    case ast do
      {:defmodule, _, [_name, [{_do, body}]]} ->
        toed_expr = body_to_exprs(body)
        {prefix, _rest} = toed_expr |> Enum.split_while(&prefix_node?/1)
        line = insert_line_after(prefix, body)
        {toed_expr, line}

      _ ->
        nil
    end
  end

  defp insert_line_after([], body) do
    case body do
      {:__block__, _, [first | _]} -> line_of(first)
      single -> line_of(single)
    end
  end

  defp insert_line_after(prefix, _body) do
    last = List.last(prefix)
    end_of_expression_line(last) + 1
  end

  defp normalize(node) do
    Macro.prewalk(node, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp prefix_node?({:@, _, _}), do: true
  defp prefix_node?({:use, _, _}), do: true
  defp prefix_node?({:require, _, _}), do: true
  defp prefix_node?({:import, _, _}), do: true
  defp prefix_node?({:alias, _, _}), do: true
  defp prefix_node?({:behaviour, _, _}), do: true
  defp prefix_node?(_), do: false
  defp walk_body({:quote, _, _}), do: []

  defp walk_body({kw, _, args} = node) when kw in @directive_keywords and is_list(args) do
    [%{node: node, normalized: normalize(node)}]
  end

  defp walk_body({_, _, args}) when is_list(args), do: args |> Enum.flat_map(&walk_body/1)
  defp walk_body({left, right}), do: walk_body(left) ++ walk_body(right)
  defp walk_body(list) when is_list(list), do: list |> Enum.flat_map(&walk_body/1)
  defp walk_body(_leaf), do: []

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp directive_patches_or_skip(nil), do: []

  defp directive_patches_or_skip({body_exprs, insert_at_line}) do
    existing = collect_module_level_directives(body_exprs)

    local_directives =
      body_exprs
      |> Enum.flat_map(&collect_local_directives/1)

    case local_directives do
      [] ->
        []

      _ ->
        delete_patches = local_directives |> Enum.map(&delete_patch/1)

        new_directives =
          local_directives
          |> Enum.map(& &1.normalized)
          |> Enum.uniq()
          |> Enum.reject(&(&1 in existing))

        case new_directives do
          [] ->
            delete_patches

          _ ->
            insert_patch = build_insert_patch(new_directives, insert_at_line)
            [insert_patch | delete_patches]
        end
    end
  end

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
