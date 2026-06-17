defmodule Number42.Refactors.Ex.AliasUsage do
  @moduledoc """
  Replaces fully-qualified module references like `Foo.Bar.Baz.fun(...)`
  with `Baz.fun(...)`, inserting `alias Foo.Bar.Baz` at the top of the
  module on demand.

  Mirrors `Credo.Check.Design.AliasUsage`. Stdlib namespaces (`Enum`,
  `String`, `IO`, `File`, ...) are excluded — those are universally
  recognized and don't benefit from aliasing.

  This is a **procedural** refactor: it can't be expressed as a single
  pattern-to-pattern rewrite because it touches the module top *and*
  every call site in the body simultaneously. ExAST's pattern language
  doesn't support function-name wildcards, so we walk the AST with
  Sourceror directly and emit `Sourceror.Patch` operations so only
  the edited regions of the source change.

  ## Conflict handling

  If the last segment of the target module clashes with an existing
  alias (e.g. another `alias Foo.Formatting` is already in scope), we
  leave the FQN call sites alone. We don't try to rename or use
  `alias :as` — that's a judgment call, and silent fallback is safer.

  ## Known limitations

  Module attributes (`@foo Mod.A.B.fn(...)`) are still picked up as
  candidates, but the inserted alias lands after them at the module
  top — which is too late, since attributes are evaluated at compile
  time and would fail to find the alias. As a result, files whose
  only FQN candidates are inside attributes can produce broken code.
  Fix this before enabling this refactor on production code: skip
  attributes during candidate collection, or insert aliases ahead
  of all attributes.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  # Modules from `Credo.Check.Design.AliasUsage`'s defaults.
  @excluded_namespaces ~w(File IO Inspect Kernel Macro Supervisor Task Version)
  @excluded_lastnames ~w(
    Access Agent Application Atom Base Behaviour Bitwise Code Date DateTime
    Dict Enum Exception File Float GenEvent GenServer HashDict HashSet
    Integer IO Kernel Keyword List Macro Map MapSet Module NaiveDateTime
    Node OptionParser Path Port Process Protocol Range Record Regex
    Registry Set Stream String StringIO Supervisor System Task Time Tuple
    URI Version
  )

  @impl Number42.Refactors.Refactor
  def description, do: "Alias multi-segment module references at the top of the module"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Repeating `My.Deep.Path.Mod.fn(...)` at every call site adds visual
    noise that has nothing to do with what the code does. Lifting the
    full path into a single `alias` at the module top makes the call
    sites read as `Mod.fn(...)` and concentrates the dependency
    information in one place — easier to skim, easier to refactor when
    `My.Deep.Path.Mod` moves.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 220
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)
  defp alias_patches_or_skip(nil), do: []

  defp alias_patches_or_skip({body_exprs, insert_at_line}) do
    aliases_in_scope = collect_aliases(body_exprs)
    fqn_call_nodes = collect_fqn_call_nodes(body_exprs)

    candidates =
      fqn_call_nodes
      |> Enum.map(fn {segments, _node} -> segments end)
      |> Enum.uniq()
      |> Enum.filter(&aliasable?(&1, aliases_in_scope))
      |> drop_last_segment_collisions()

    case candidates do
      [] ->
        []

      _ ->
        call_patches =
          fqn_call_nodes
          |> Enum.filter(fn {segments, _} -> segments in candidates end)
          |> Enum.map(fn {segments, aliases_node} ->
            alias_replace_patch(segments, aliases_node)
          end)

        alias_patch = build_alias_insert_patch(candidates, insert_at_line)
        [alias_patch | call_patches]
    end
  end

  defp alias_replace_patch(segments, aliases_node) do
    last = segments |> List.last() |> Atom.to_string()
    Patch.replace(aliases_node, last)
  end

  defp aliasable?(segments, aliases_in_scope) do
    last = List.last(segments)
    first = List.first(segments)
    last_str = Atom.to_string(last)
    first_str = Atom.to_string(first)

    cond do
      first_str in @excluded_namespaces -> false
      last_str in @excluded_lastnames -> false
      MapSet.member?(aliases_in_scope, last) -> false
      # `Identity.User` where `Identity` is already an alias for `MyApp.Identity`
      # is a *relative* reference, not a FQN. Aliasing it would produce
      # `alias Identity.User` — which points at a non-existent top-level
      # module. Skip it; the existing alias already covers this access.
      MapSet.member?(aliases_in_scope, first) -> false
      true -> true
    end
  end

  @impl Number42.Refactors.Refactor
  def patches(ast, _source, _opts), do: build_patches(ast)

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
  defp apply_patches({:error, _}, source), do: source

  defp build_alias_insert_patch(candidates, insert_at_line) do
    text =
      candidates
      |> Enum.sort_by(&Enum.map(&1, fn s -> Atom.to_string(s) end))
      |> Enum.map_join("\n", fn segments ->
        "alias " <> Enum.map_join(segments, ".", &Atom.to_string/1)
      end)

    range = %{
      end: [line: insert_at_line, column: 1],
      start: [line: insert_at_line, column: 1]
    }

    Sourceror.Patch.new(range, text <> "\n", false)
  end

  defp build_patches(ast), do: find_module_body(ast) |> alias_patches_or_skip()

  defp collect_aliases(exprs) do
    exprs
    |> Enum.flat_map(fn
      {:alias, _, [{:__aliases__, _, segments}]} ->
        [List.last(segments)]

      {:alias, _, [{:__aliases__, _, segments}, opts]} when is_list(opts) ->
        as_atom =
          opts
          |> Enum.find_value(fn
            {{:__block__, _, [:as]}, {:__aliases__, _, [as_name]}} -> as_name
            {:as, {:__aliases__, _, [as_name]}} -> as_name
            _ -> nil
          end)

        [as_atom || List.last(segments)]

      # Multi-alias: `alias Foo.Bar.{Baz, Qux}` introduces `Baz` and `Qux`.
      {:alias, _, [{{:., _, [{:__aliases__, _, _}, :{}]}, _, group}]} ->
        group
        |> Enum.flat_map(fn
          {:__aliases__, _, segs} -> [List.last(segs)]
          _ -> []
        end)

      # Inner module: `defmodule Foo do ... end` makes `Foo` reachable
      # bare from the surrounding module. Treat its last segment as an
      # in-scope name so we don't shadow it with an alias.
      {:defmodule, _, [{:__aliases__, _, segments} | _]} ->
        [List.last(segments)]

      _ ->
        []
    end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp collect_fqn_call_nodes(exprs), do: exprs |> Enum.flat_map(&collect_in_expr/1)
  defp collect_in_expr({:@, _, _}), do: []

  defp collect_in_expr({directive, _, _})
       when directive in [:alias, :import, :require, :use],
       do: []

  defp collect_in_expr(expr) do
    expr
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      # `_fun` is the called function name. Multi-alias `Foo.{A, B}` desugars
      # to `{:., _, [Foo, :{}]}` — exclude that explicitly so we don't treat
      # the alias-grouping syntax as a call site.
      {{:., _, [{:__aliases__, _, segments} = aliases, fun]}, _, _args}
      when length(segments) > 1 and fun != :{} ->
        [{segments, aliases}]

      _ ->
        []
    end)
  end

  defp drop_last_segment_collisions(candidates) do
    grouped = candidates |> Enum.group_by(&List.last/1)

    grouped
    |> Enum.flat_map(fn
      {_last, [single]} -> [single]
      {_last, _multi} -> []
    end)
  end

  defp find_module_body(ast) do
    case ast do
      {:defmodule, _, [_name, [{_do, body}]]} ->
        toed_expr = body_to_exprs(body)
        line = directive_insert_line(toed_expr)
        {toed_expr, line}

      _ ->
        nil
    end
  end

  # The insertion point is *after* a leading `@moduledoc` (if any) and
  # after the `use`/`alias`/`import`/`require`/`behaviour` prefix block.
  # `@moduledoc` must stay the first thing in the module, so we anchor on
  # the leading-moduledoc/prefix region — never inserting a directive
  # above it. Other `@`-attributes are deliberately *not* prefix nodes:
  # the alias belongs after them too, but they don't anchor the insertion.
  defp directive_insert_line(exprs) do
    {moduledoc, rest} = split_leading_moduledoc(exprs)
    {prefix, _} = Enum.split_while(rest, &prefix_node?/1)

    insert_anchored(prefix, moduledoc, rest)
  end

  defp split_leading_moduledoc([{:@, _, [{:moduledoc, _, _}]} = moduledoc | rest]),
    do: {moduledoc, rest}

  defp split_leading_moduledoc(exprs), do: {nil, exprs}

  # Insert *after* the last prefix node if there is one, else *after* a
  # leading `@moduledoc`, else *at* the first body expression's line
  # (pushing it down). Empty body falls back to line 1.
  defp insert_anchored([_ | _] = prefix, _moduledoc, _rest),
    do: end_of_expression_line(List.last(prefix)) + 1

  defp insert_anchored([], moduledoc, _rest) when not is_nil(moduledoc),
    do: end_of_expression_line(moduledoc) + 1

  defp insert_anchored([], nil, [first | _]), do: line_of(first)
  defp insert_anchored([], nil, []), do: 1

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
  defp prefix_node?({:use, _, _}), do: true
  defp prefix_node?({:require, _, _}), do: true
  defp prefix_node?({:import, _, _}), do: true
  defp prefix_node?({:alias, _, _}), do: true
  defp prefix_node?({:behaviour, _, _}), do: true
  defp prefix_node?(_), do: false
end
