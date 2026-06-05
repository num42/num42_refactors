defmodule Number42.Refactors.Ex.SortFunctions do
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
  where the surrounding node shapes give us no obvious reason a
  reorder would change behaviour. That is a discipline applied at
  pattern-match time, not a formal proof — review the diff after
  running, especially in files that use module-level state (`@on_load`,
  `@before_compile`, runtime attribute reads at compile time).

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

  ## Clauses keep relative order — and stay contiguous

  Multi-clause functions rely on top-to-bottom match order:

      def to_int(true), do: 1
      def to_int(false), do: 0
      def to_int(_), do: -1

  Each clause is its own block. The sort key is
  `{heex_group, visibility, impl_group, name, arity, original_line}` —
  when two blocks share `{name, arity}` (i.e. they're clauses of the
  same function) every other tie-breaker is keyed by `{name, arity}`
  too, so the only field that differs is `original_line`. That keeps
  the clauses adjacent and in their original top-to-bottom order: a
  catch-all clause that sat above guard clauses stays above them.

  If a function's clauses are split across two sortable regions (an
  unsortable node — a constant, a macro call — sits between them in the
  source), reordering either region independently could wedge an
  unrelated function between the clauses and trigger the compiler's
  *"clauses with the same name and arity should be grouped together"*
  warning. To uphold contiguity in that case we **refuse to reorder any
  region that touches a split clause group** and leave the source order
  intact. Doing nothing never makes contiguity worse.

  ## Section comments are preserved

  Divider comments such as `# --- GenServer callbacks ---` and any
  other comment that sits directly above a function block are attached
  by the parser as `:leading_comments` of the block's first node. The
  block's source slice is extended upward to include them, so the
  comment travels with the block it heads instead of being silently
  deleted when the block moves.

  ## Public API before behaviour callbacks

  Within the public group, plain `def`s sort ahead of `@impl`-annotated
  behaviour callbacks (`init`, `handle_call`, ...), mirroring the
  common convention of listing a module's external surface first and
  its callbacks below. The `@impl` grouping is keyed by `{name, arity}`
  so a callback whose `@impl` only decorates its first clause keeps all
  its clauses together. Private `defp`s always come last.

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

  use Number42.Refactors.Refactor

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

  @impl Number42.Refactors.Refactor
  def description, do: "Sort def/defp groups alphabetically"
  @impl Number42.Refactors.Refactor
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

  @impl Number42.Refactors.Refactor
  def priority, do: 30
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
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

  defp apply_patches({:ok, ast}, source),
    do:
      build_patches(ast, source)
      |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp block_source({:fn_block, _, _, nodes}, source) do
    first = nodes |> List.first()
    last_range = nodes |> List.last() |> Sourceror.get_range()

    slice_range(source, block_start_pos(first), last_range.end)
  end

  # Effective start position of a block, extended upward to cover any
  # *non-divider* comments Sourceror attached to the block's first node
  # as `:leading_comments`. Per-function comments live in the gap above a
  # node, outside its AST range — slicing from the bare range start drops
  # them. We pull the start up so they travel with the block they
  # annotate. Section dividers (`# --- callbacks ---`) are deliberately
  # excluded: they anchor a section boundary (see `section_break?`) and
  # must stay in source position rather than be dragged with a block.
  defp block_start_pos(node) do
    range = Sourceror.get_range(node)
    node_line = range.start[:line]

    case earliest_non_divider_comment_line(node) do
      nil -> range.start
      line when line < node_line -> [line: line, column: 1]
      _ -> range.start
    end
  end

  defp earliest_non_divider_comment_line(node) do
    node
    |> leading_comments()
    |> Enum.reject(&section_divider?/1)
    |> Enum.map(& &1.line)
    |> Enum.min(fn -> nil end)
  end

  defp leading_comments(node) do
    node
    |> Sourceror.get_meta()
    |> Keyword.get(:leading_comments, [])
  end

  # A divider comment marks a logical section (`# --- callbacks ---`,
  # `# === public API ===`). We match a leading `#`, optional space, then
  # 3+ of the usual ASCII rule characters. Such comments anchor a section
  # boundary instead of decorating a single function.
  @section_divider_re ~r/^#\s*[-=*~_]{3,}/
  defp section_divider?(%{text: text}), do: Regex.match?(@section_divider_re, text)
  defp section_divider?(_), do: false

  # True when a node carries a section-divider comment in its leading
  # comments — i.e. a new logical section starts at this node.
  defp section_break?(node) do
    node |> leading_comments() |> Enum.any?(&section_divider?/1)
  end

  defp build_patches(ast, source) do
    ast
    |> all_module_bodies()
    |> Enum.flat_map(fn exprs ->
      intoed_block = group_into_blocks(exprs)
      heex_set = heex_function_set(intoed_block)
      impl_set = impl_function_set(intoed_block)
      regions = split_into_regions(intoed_block)
      split_set = cross_region_split_set(regions)

      regions
      |> Enum.flat_map(&region_patch(&1, source, heex_set, impl_set, split_set))
    end)
  end

  # Names/arities whose clauses live in more than one sortable region.
  # A region terminator (a constant, a macro call, ...) sat between two
  # clauses of the same function in the source. Reordering either region
  # independently can wedge an unrelated function between those clauses,
  # producing the compiler's "clauses with the same name and arity should
  # be grouped together" warning. We refuse to reorder any region that
  # touches such a group — leaving the source order intact never makes
  # contiguity worse and stays idempotent.
  defp cross_region_split_set(regions) do
    regions
    |> Enum.flat_map(fn region ->
      region
      |> Enum.map(fn {:fn_block, name, arity, _} -> {name, arity} end)
      |> Enum.uniq()
    end)
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {key, count} when count > 1 -> [key]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp build_replace_patch(original, sorted, source) do
    first_node = original |> List.first() |> first_node_of_block()
    last_node = original |> List.last() |> last_node_of_block()

    # Start the patch at the first block's effective start (above any
    # leading divider comment), so the original comment lines are
    # replaced by the re-stitched, comment-carrying slices rather than
    # left behind and duplicated.
    start_pos = block_start_pos(first_node)
    last_range = Sourceror.get_range(last_node)

    # Each block is rendered by stitching its original source slices
    # together — the slices already include their own attached
    # attributes and leading comments. Blocks are joined with a single
    # newline + indent (dense format); `mix format` normalizes spacing.
    indent = leading_indent(source, start_pos[:line])

    rendered =
      sorted
      |> Enum.map(&block_source(&1, source))
      |> Enum.intersperse("\n" <> indent)
      |> IO.iodata_to_binary()

    range = %{
      end: [line: last_range.end[:line], column: last_range.end[:column]],
      start: [line: start_pos[:line], column: start_pos[:column]]
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

  defp def_classification_or_other({:ok, name, arity}), do: {:def, name, arity}
  defp def_classification_or_other(:error), do: :other
  defp def_node?({def_or_defp, _, _}) when def_or_defp in [:def, :defp], do: true
  defp def_node?(_), do: false
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
      {blocks, attr_buf}
      |> maybe_open_section(node)
      |> add_node(node)
    end)
    |> finalize_blocks()
  end

  # A node carrying a section-divider comment opens a new logical
  # section. We flush any buffered attributes and inject a
  # `:section_break` marker so `split_into_regions` treats the divider
  # like any other region boundary — sorting happens within each section
  # and the divider stays put in the source (it is never sliced into a
  # block). Attributes can buffer above the divider node, so flush them
  # first to keep the marker between the previous block and this one.
  defp maybe_open_section({blocks, attr_buf}, node) do
    if section_break?(node) do
      flushed = flush_attrs_as_other(attr_buf, blocks)
      {[:section_break | flushed], []}
    else
      {blocks, attr_buf}
    end
  end

  defp add_node({blocks, attr_buf}, node) do
    case classify_node(node) do
      {:def, name, arity} ->
        add_def(node, name, arity, blocks, attr_buf)

      :attached_attr ->
        {blocks, [node | attr_buf]}

      :other ->
        flushed = flush_attrs_as_other(attr_buf, blocks)
        {[{:other, node} | flushed], []}
    end
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

  # `{name, arity}` of every function with an `@impl` attribute on any of
  # its clauses. Keyed by name/arity (not per-block) so that a function
  # whose `@impl` annotation only decorates its first clause still keeps
  # all its clauses in the same group — splitting them would tear the
  # function apart and break clause contiguity.
  defp impl_function_set(blocks) do
    blocks
    |> Enum.flat_map(fn
      {:fn_block, name, arity, nodes} ->
        if nodes |> Enum.any?(&impl_attr?/1), do: [{name, arity}], else: []

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp impl_attr?({:@, _, [{:impl, _, _}]}), do: true
  defp impl_attr?(_), do: false

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

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  defp region_patch(blocks, source, heex_set, impl_set, split_set) do
    if region_touches_split?(blocks, split_set) do
      []
    else
      sorted = blocks |> Enum.sort_by(&sort_key(&1, heex_set, impl_set))

      if sorted == blocks do
        []
      else
        [build_replace_patch(blocks, sorted, source)]
      end
    end
  end

  defp region_touches_split?(blocks, split_set) do
    blocks
    |> Enum.any?(fn {:fn_block, name, arity, _} ->
      MapSet.member?(split_set, {name, arity})
    end)
  end

  defp slice_range(source, start_pos, end_pos) do
    l1 = Keyword.fetch!(start_pos, :line)
    c1 = Keyword.fetch!(start_pos, :column)
    l2 = Keyword.fetch!(end_pos, :line)
    c2 = Keyword.fetch!(end_pos, :column)

    lines = String.split(source, "\n")

    if l1 == l2 do
      line = lines |> Enum.at(l1 - 1)
      String.slice(line, (c1 - 1)..(c2 - 2)//1)
    else
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

  defp sort_key({:fn_block, name, arity, nodes} = block, heex_set, impl_set) do
    visibility =
      case nodes |> Enum.find(&def_node?/1) do
        {:def, _, _} -> 0
        {:defp, _, _} -> 1
        _ -> 0
      end

    heex_group = if MapSet.member?(heex_set, {name, arity}), do: 0, else: 1

    # Plain public API (0) sorts ahead of `@impl` behaviour callbacks (1)
    # within the public group, mirroring the repo convention of listing a
    # module's external surface first and its callbacks below. Keyed by
    # name/arity so multi-clause functions never straddle the boundary.
    impl_group = if MapSet.member?(impl_set, {name, arity}), do: 1, else: 0

    {heex_group, visibility, impl_group, Atom.to_string(name) |> String.downcase(), arity,
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

        # Any non-fn_block marker (`{:other, _}` or `:section_break`)
        # closes the current region. Reordering never crosses it.
        _boundary, [] ->
          {:cont, []}

        _boundary, acc ->
          {:cont, acc |> Enum.reverse(), []}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, acc |> Enum.reverse(), []}
      end
    )
    |> Enum.reject(&(&1 == []))
  end

  defp start_line_or_zero(%{start: start}), do: start |> Keyword.fetch!(:line)
  defp start_line_or_zero(_), do: 0
end
