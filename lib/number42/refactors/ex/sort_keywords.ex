defmodule Number42.Refactors.Ex.SortKeywords do
  @moduledoc """
  Sorts keyword-shaped contents alphabetically by key in the places
  where reordering is provably semantics-preserving:

  - **Map literals** — `%{b: 1, a: 2}` → `%{a: 2, b: 1}`.
  - **Struct literals** — `%MyStruct{b: 1, a: 2}` → `%MyStruct{a: 2, b: 1}`.
  - **`defstruct` with a keyword list** — `defstruct b: 1, a: 0` →
    `defstruct a: 0, b: 1`.
  - **`defstruct` with a bare atom list** — `defstruct [:b, :a]` →
    `defstruct [:a, :b]`.

  Other syntactic keyword lists are **not** touched. Many are
  semantically order-sensitive — `Ecto.Query.from(.., where: ..,
  order_by: .., select: ..)`, `import X, only: [a: 1, b: 2]`, plug
  pipelines, `case do ... end` clauses, `attr` / `slot` macro calls in
  Phoenix components — and a blanket sort would silently break
  behaviour. The safe core only.

  ## Mixed-key shapes stay alone

  Only **pure** keyword shapes (every entry is `key: value` with an
  atom key) are sorted. `%{1 => :a, b: 2}` is left alone because
  partial sorting visually suggests the whole map was canonicalised.
  Same for `defstruct [:a, b: 1]` — atom-only and keyword-list forms
  must not mix.

  ## Map updates

  `%{base | a: 1, b: 2}` is **not** sorted: the cons-cell tail makes
  the AST shape (`{:%{}, _, [{:|, _, [_var, [pairs]]}]}`) different
  from a plain map, and rewriting it would require additional
  range-fiddling. Skipped pragmatically; can be added later.

  ## Procedural mode

  Reordering inside a syntactic literal can't be expressed as a single
  ExAST pattern rewrite. We walk the AST, find sortable nodes, and
  emit one `Sourceror.Patch.new/3` per node that replaces the original
  pair-list range with a sorted, reslice-and-rejoin rendering —
  reusing each pair's source slice so per-pair formatting is preserved
  verbatim.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.AstHelpers
  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Sort keyword-list contents alphabetically"

  @impl Number42.Refactors.Refactor
  def priority, do: 30

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Map and struct literals are conceptually unordered: `%{a: 1, b: 2}`
    and `%{b: 2, a: 1}` produce the same map. Sorting them
    alphabetically pays off in code review (a new field appears at its
    sort position rather than "wherever the author was working") and
    in diffs (no incidental reordering noise). The refactor only
    touches places where the runtime is provably indifferent to
    order — `defstruct`, map and struct literals — so behaviour cannot
    regress.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: source |> do_transform(0)

  # Sourceror's `patch_string/2` does not compose overlapping patches
  # (an outer patch wins; inner ones are dropped). Nested literals
  # (`%{b: %{y: 1, x: 2}, a: 1}`) need both patches to land. We run a
  # bounded fixpoint over the source: each pass produces only the
  # *outermost* patches that actually fire, which leaves the next
  # pass to find the now-uncontested inner ones. Capped at @max_passes
  # to keep pathological inputs from looping.
  @max_passes 5

  defp do_transform(source, passes) when passes >= @max_passes, do: source

  defp do_transform(source, passes),
    do: Sourceror.parse_string(source) |> apply_patches(passes, source)

  # Keep only patches whose ranges don't overlap any other patch's
  # range — when two would overlap, prefer the outer one (the one
  # whose range strictly contains the other). The contained patch
  # gets a free shot in the next fixpoint iteration after the outer
  # one has already been applied.
  defp drop_overlaps(patches) do
    patches
    |> Enum.reject(fn p ->
      patches
      |> Enum.any?(fn other ->
        other != p and contains?(other.range, p.range)
      end)
    end)
  end

  defp contains?(outer, inner),
    do:
      pos_lte(outer.start, inner.start) and pos_lte(inner.end, outer.end) and
        not (pos_eq(outer.start, inner.start) and pos_eq(outer.end, inner.end))

  defp pos_lte(a, b), do: {a[:line], a[:column]} <= {b[:line], b[:column]}

  defp pos_eq(a, b), do: a[:line] == b[:line] and a[:column] == b[:column]

  # `Macro.prewalker/1` walks every node, so a `%MyStruct{...}` is
  # visited as both the outer `:%` shape AND its inner `:%{}` twin —
  # they cover the same pair list and produce identical patches.
  # `uniq_by` over the patch range collapses the duplicate.
  defp build_patches(ast, source),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&node_patches(&1, source))
      |> Enum.uniq_by(& &1.range)

  # Map literal: %{a: 1, b: 2}
  defp node_patches({:%{}, _meta, [{:|, _, _}]}, _source), do: []

  defp node_patches({:%{}, _meta, pairs}, source) when is_list(pairs) do
    sort_pair_list(pairs, source)
  end

  # Struct literal: %MyStruct{a: 1, b: 2}
  defp node_patches({:%, _, [_struct, {:%{}, _, pairs}]}, source) when is_list(pairs) do
    sort_pair_list(pairs, source)
  end

  # defstruct with a keyword list (no brackets): defstruct b: 1, a: 0
  defp node_patches({:defstruct, _, [pairs]}, source) when is_list(pairs) do
    sort_pair_list(pairs, source)
  end

  # defstruct with a bracketed atom list: defstruct [:b, :a]
  defp node_patches(
         {:defstruct, _, [{:__block__, _meta, [items]}]},
         source
       )
       when is_list(items) do
    sort_atom_list(items, source)
  end

  defp node_patches(_, _), do: []

  # ---------------------------------------------------------------
  # Pair-list sorting (maps, structs, defstruct kw)
  # ---------------------------------------------------------------

  defp sort_pair_list(pairs, source) do
    cond do
      length(pairs) < 2 -> []
      not Enum.all?(pairs, &keyword_pair?/1) -> []
      true -> maybe_patch_pairs(pairs, source)
    end
  end

  defp maybe_patch_pairs(pairs, source) do
    sorted = pairs |> Enum.sort_by(&pair_sort_key/1)

    if sorted == pairs do
      []
    else
      [build_pair_patch(pairs, sorted, source)]
    end
  end

  # Sourceror parses each `key: value` pair as `{key_node, value_node}`
  # where `key_node` is `{:__block__, meta, [:atom_key]}` with
  # `format: :keyword`. We further require the absence of a
  # `:delimiter` meta — string keys (`"brand-id": v`) parse to the
  # same shape but with `delimiter: "\""`, and rendering them as bare
  # atoms (`brand-id:`) produces invalid syntax.
  defp keyword_pair?({{:__block__, meta, [key]}, _value}) when is_atom(key) do
    Keyword.get(meta, :format) == :keyword and not Keyword.has_key?(meta, :delimiter)
  end

  defp keyword_pair?(_), do: false

  defp pair_sort_key({{:__block__, _, [key]}, _value}), do: Atom.to_string(key)

  defp build_pair_patch(original, sorted, source) do
    first_range = Sourceror.get_range(List.first(original))
    last_pair = List.last(original)
    last_range = Sourceror.get_range(last_pair)

    # Sourceror over-shoots a range whose right-most leaf is a boolish
    # literal by one column — without clipping, the patch eats the
    # trailing `}` / `,`. The helper handles it (skips clipping when
    # the node has its own closing-bracket meta).
    {_key, last_value} = last_pair
    end_pos = AstHelpers.clip_end_for_boolish_tail(last_value, last_range.end)

    multiline? = first_range.start[:line] != end_pos[:line]
    joiner = pair_joiner(multiline?)

    rendered =
      sorted
      |> Enum.map(&pair_slice(&1, source))
      |> Enum.intersperse(joiner)
      |> IO.iodata_to_binary()

    range = %{end: end_pos, start: first_range.start}
    Patch.new(range, rendered, false)
  end

  # `reformat_after?/0` is `true`, so `Code.format_string!/2` will
  # re-indent the output. We don't need to compute the visual indent
  # ourselves — a bare `,\n` between pairs is enough to keep the
  # rendering syntactically valid for the formatter to take over.
  defp pair_joiner(false), do: ", "
  defp pair_joiner(true), do: ",\n"

  # Render `key: value` from source. We can't trust
  # `Sourceror.get_range/1` on the pair as a whole — Sourceror
  # over-shoots the value range by one column for right-most boolish
  # literals (`nil`/`true`/`false`), which leaks the trailing comma
  # or closing brace into the slice. Instead: render the keyword key
  # directly from the AST (it's always `<atom>:`) and slice the value
  # via `AstHelpers.slice_node/2` (which clips the boolish overshoot).
  defp pair_slice({{:__block__, _, [key]}, value_node}, source) do
    {:ok, value_text} = AstHelpers.slice_node(source, value_node)
    Atom.to_string(key) <> ": " <> value_text
  end

  # ---------------------------------------------------------------
  # Atom-list sorting (defstruct [:a, :b])
  # ---------------------------------------------------------------

  defp sort_atom_list(items, source) do
    cond do
      length(items) < 2 -> []
      not Enum.all?(items, &atom_block?/1) -> []
      true -> maybe_patch_atom_list(items, source)
    end
  end

  defp atom_block?({:__block__, _, [v]}) when is_atom(v), do: true
  defp atom_block?(_), do: false

  defp maybe_patch_atom_list(items, source) do
    sorted = items |> Enum.sort_by(&atom_block_key/1)

    if sorted == items do
      []
    else
      [build_atom_patch(items, sorted, source)]
    end
  end

  defp atom_block_key({:__block__, _, [v]}), do: Atom.to_string(v)

  defp build_atom_patch(original, sorted, source) do
    first_range = Sourceror.get_range(List.first(original))
    last_range = Sourceror.get_range(List.last(original))

    multiline? = first_range.start[:line] != last_range.end[:line]
    joiner = pair_joiner(multiline?)

    rendered =
      sorted
      |> Enum.map(&atom_slice(&1, source))
      |> Enum.intersperse(joiner)
      |> IO.iodata_to_binary()

    range = %{end: last_range.end, start: first_range.start}
    Patch.new(range, rendered, false)
  end

  defp atom_slice(node, source) do
    {:ok, text} = AstHelpers.slice_node(source, node)
    text
  end

  defp apply_patches({:ok, ast}, passes, source),
    do:
      build_patches(ast, source)
      |> patch_or_recurse(passes, source)

  defp apply_patches({:error, _}, _passes, source), do: source

  defp patch_or_recurse([], _passes, source), do: source

  defp patch_or_recurse(patches, passes, source),
    do:
      patches
      |> drop_overlaps()
      |> then(&Sourceror.patch_string(source, &1))
      |> do_transform(passes + 1)
end
