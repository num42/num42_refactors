defmodule Num42.Refactors.Refactors.SortFunctions do
  @moduledoc """
  Sorts top-level `def`/`defp` definitions inside a module
  alphabetically, with public (`def`) before private (`defp`).

      defmodule Foo do
        defp helper, do: :ok
        def b, do: helper()
        def a, do: helper()
      end

      ↓

      defmodule Foo do
        def a, do: helper()
        def b, do: helper()
        defp helper, do: :ok
      end

  Sorting is **conservative**: we only sort regions of the module
  where every node is provably safe to reorder.

  ## What gets sorted

  A *function block* is one or more consecutive `def`/`defp` clauses
  for the **same `name/arity`**, optionally preceded by a run of
  attached attributes (`@doc`, `@spec`, `@impl`, `@deprecated`,
  `@dialyzer`, `@typedoc`). The whole block — attributes plus all
  clauses — moves together.

  A *sortable region* is a maximal run of function blocks with
  nothing else between them. Each region is sorted independently.

  ## What we never reorder

  Anything that isn't a function block ends a region:

  - Module-level macro calls (`def_form_field`, `field`, `embed_one`,
    `has_many`, `plug`, ...). These can register state, inject
    `def`s, or otherwise depend on order.
  - `defstruct`, `defexception`, `defprotocol`, `defimpl`.
  - `use`/`import`/`alias`/`require`.
  - Module attributes that aren't on the attached-to-function
    allowlist (e.g. `@x 1` defining a compile-time constant).
  - `defmacro`/`defmacrop`/`defguard`/`defguardp` — these change the
    compile context for everything below; reordering relative to
    `def`s could break callers.

  Encountering any of these closes the current region. The region
  before is sorted (if it has 2+ blocks); everything from the
  unsortable node onwards starts a fresh region after the next
  function block.

  ## Clauses keep relative order

  Multi-clause functions rely on top-to-bottom match order:

      def to_int(true), do: 1
      def to_int(false), do: 0
      def to_int(_), do: -1

  Each clause is its own block. The sort key is
  `{visibility, name, arity, original_line}` — when two blocks share
  `{visibility, name, arity}` (i.e. they're clauses of the same
  function), the source-line tie-breaker keeps them in their original
  top-to-bottom order. A catch-all clause that sat above guard
  clauses stays above them, even when the function's clauses are
  split into non-adjacent groups elsewhere in the file.

  ## HEEx-first ordering

  Function blocks containing a `~H` sigil sort to the top of the
  module, ahead of every non-HEEx function. Within each group the
  existing rules apply (public before private, alphabetical by name,
  arity, original line).

  Multi-clause functions land in the HEEx group as long as **any**
  clause renders HEEx — splitting them between groups would tear a
  function apart.

  Blank lines between function blocks do not split regions —
  otherwise the lift wouldn't be able to cross the typical
  `mount`/`render`/`handle_*` paragraph breaks in a LiveView.

  ## Why procedural

  Reordering can't be expressed as a single ExAST pattern. We walk
  the module body, group expressions into blocks and regions, and
  emit one `Sourceror.Patch.new/3` per region that replaces the
  original lines with a sorted version — reusing the original source
  slices so attached attributes, comments, and formatting are
  preserved verbatim.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  # Attribute names that are considered "attached" to the next
  # function definition and must travel with it. Mirrors common
  # Elixir conventions; expand if a project needs more.
  @attached_attrs ~w(doc spec impl deprecated dialyzer typedoc since)a

  # Macro calls that decorate the next function in the same way that
  # `@spec`/`@doc` do. Phoenix components stack `attr :name, ...` and
  # `slot :inner_block, ...` immediately above the function-component
  # definition; treating them as `:other` would split the region and
  # leave the decorator orphaned when the function moves.
  @attached_macros ~w(attr slot)a

  @impl Num42.Refactors.Refactor
  def description, do: "Sort def/defp groups alphabetically"

  @impl Num42.Refactors.Refactor
  def priority, do: 30

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    "Where is `do_stuff/1` defined?" is a question with one answer if
    functions are alphabetised and a "scroll until you find it"
    exercise otherwise. Sorting also stabilises diffs: a new function
    appears at its sort position rather than at the bottom or
    "wherever the author was working", so reviews reflect intent
    instead of editing history. The catch — multi-clause functions stay
    contiguous, attributes stay glued to their `def` — is preserved.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp add_def(node, name, arity, blocks, attr_buf) do
    nodes = attr_buf |> Enum.reverse([node])
    {[{:fn_block, name, arity, nodes} | blocks], []}
  end

  defp all_module_bodies(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [_name, [{_do, body}]]} ->
        [body_to_exprs(body)]

      _ ->
        []
    end)
  end

  defp block_source({:fn_block, _, _, nodes}, source) do
    first_range = nodes |> List.first() |> Sourceror.get_range()
    last_range = nodes |> List.last() |> Sourceror.get_range()

    slice_range(source, first_range.start, last_range.end)
  end

  defp build_patches(ast, source) do
    ast
    |> all_module_bodies()
    |> Enum.flat_map(fn exprs ->
      intoed_block = group_into_blocks(exprs)
      heex_set = heex_function_set(intoed_block)

      intoed_block
      |> split_into_regions()
      |> Enum.flat_map(&region_patch(&1, source, heex_set))
    end)
  end

  defp build_replace_patch(original, sorted, source) do
    first_node = original |> List.first() |> first_node_of_block()
    last_node = original |> List.last() |> last_node_of_block()

    first_range = Sourceror.get_range(first_node)
    last_range = Sourceror.get_range(last_node)

    # Each block is rendered by stitching its original source slices
    # together — the slices already include their own attached
    # attributes since those were collected into the block. Blocks
    # are joined with a single newline + indent (dense format);
    # `mix format` will normalize spacing as needed.
    indent = leading_indent(source, first_range.start[:line])

    rendered =
      sorted
      |> Enum.map(&block_source(&1, source))
      |> Enum.intersperse("\n" <> indent)
      |> IO.iodata_to_binary()

    range = %{
      end: [line: last_range.end[:line], column: last_range.end[:column]],
      start: [line: first_range.start[:line], column: first_range.start[:column]]
    }

    Patch.new(range, rendered, false)
  end

  defp classify_node({def_or_defp, _, [head | _]})
       when def_or_defp in [:def, :defp] do
    extract_name_arity(head) |> def_classification_or_other()
  end

  defp classify_node({:@, _, [{attr, _, _}]}) when is_atom(attr) do
    if attr in @attached_attrs, do: :attached_attr, else: :other
  end

  defp classify_node({name, _, args})
       when is_atom(name) and is_list(args) and args != [] do
    if name in @attached_macros, do: :attached_attr, else: :other
  end

  defp classify_node(_), do: :other

  defp contains_h_sigil?(node) do
    node
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:sigil_H, _, _} -> true
      _ -> false
    end)
  end

  defp extract_name_arity({:when, _, [head | _]}), do: extract_name_arity(head)

  defp extract_name_arity({name, _, ctx}) when is_atom(name) and is_atom(ctx),
    do: {:ok, name, 0}

  defp extract_name_arity({name, _, args}) when is_atom(name) and is_list(args),
    do: {:ok, name, length(args)}

  defp extract_name_arity(_), do: :error

  defp finalize_blocks({blocks, attr_buf}),
    do:
      attr_buf
      |> flush_attrs_as_other(blocks)
      |> Enum.reverse()

  defp first_node_of_block({:fn_block, _, _, [first | _]}), do: first

  defp flush_attrs_as_other(attr_buf, blocks) do
    attr_buf
    |> Enum.reverse()
    |> Enum.reduce(blocks, fn n, acc -> [{:other, n} | acc] end)
  end

  defp group_into_blocks(exprs) do
    exprs
    |> Enum.reduce({[], []}, fn node, {blocks, attr_buf} ->
      case classify_node(node) do
        {:def, name, arity} ->
          add_def(node, name, arity, blocks, attr_buf)

        :attached_attr ->
          {blocks, [node | attr_buf]}

        :other ->
          flushed = flush_attrs_as_other(attr_buf, blocks)
          {[{:other, node} | flushed], []}
      end
    end)
    |> finalize_blocks()
  end

  defp heex_function_set(blocks) do
    blocks
    |> Enum.flat_map(fn
      {:fn_block, name, arity, nodes} ->
        if nodes |> Enum.any?(&contains_h_sigil?/1), do: [{name, arity}], else: []

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp is_def_node({def_or_defp, _, _}) when def_or_defp in [:def, :defp], do: true
  defp is_def_node(_), do: false
  defp last_node_of_block({:fn_block, _, _, nodes}), do: List.last(nodes)

  defp leading_indent(source, line) do
    source
    |> String.split("\n")
    |> Enum.at(line - 1, "")
    |> then(fn l ->
      case Regex.run(~r/^[\s]*/, l) do
        [match] -> match
        _ -> ""
      end
    end)
  end

  defp original_line({:fn_block, _, _, [first | _]}),
    do: Sourceror.get_range(first) |> start_line_or_zero()

  defp region_patch(blocks, source, heex_set) do
    sorted = blocks |> Enum.sort_by(&sort_key(&1, heex_set))

    if sorted == blocks do
      []
    else
      [build_replace_patch(blocks, sorted, source)]
    end
  end

  defp slice_range(source, start_pos, end_pos) do
    l1 = Keyword.fetch!(start_pos, :line)
    c1 = Keyword.fetch!(start_pos, :column)
    l2 = Keyword.fetch!(end_pos, :line)
    c2 = Keyword.fetch!(end_pos, :column)

    lines = String.split(source, "\n")

    cond do
      l1 == l2 ->
        line = lines |> Enum.at(l1 - 1)
        String.slice(line, (c1 - 1)..(c2 - 2)//1)

      true ->
        first_line =
          lines
          |> Enum.at(l1 - 1)
          |> String.slice((c1 - 1)..-1//1)

        middle_lines = lines |> Enum.slice(l1..(l2 - 2)//1)

        last_line =
          lines
          |> Enum.at(l2 - 1)
          |> String.slice(0..(c2 - 2)//1)

        ([first_line | middle_lines] ++ [last_line]) |> Enum.join("\n")
    end
  end

  defp sort_key({:fn_block, name, arity, nodes} = block, heex_set) do
    visibility =
      case nodes |> Enum.find(&is_def_node/1) do
        {:def, _, _} -> 0
        {:defp, _, _} -> 1
        _ -> 0
      end

    heex_group = if MapSet.member?(heex_set, {name, arity}), do: 0, else: 1

    {heex_group, visibility, Atom.to_string(name) |> String.downcase(), arity,
     original_line(block)}
  end

  defp split_into_regions(blocks) do
    blocks
    |> Enum.chunk_while(
      [],
      fn
        {:fn_block, _, _, _} = b, [] ->
          {:cont, [b]}

        {:fn_block, _, _, _} = b, acc ->
          {:cont, [b | acc]}

        {:other, _}, [] ->
          {:cont, []}

        {:other, _}, acc ->
          {:cont, acc |> Enum.reverse(), []}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, acc |> Enum.reverse(), []}
      end
    )
    |> Enum.filter(&(length(&1) >= 2))
  end

  defp apply_patches({:ok, ast}, source),
    do:
      build_patches(ast, source)
      |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp def_classification_or_other({:ok, name, arity}), do: {:def, name, arity}

  defp def_classification_or_other(:error), do: :other

  defp start_line_or_zero(%{start: start}), do: start |> Keyword.fetch!(:line)

  defp start_line_or_zero(_), do: 0

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
