defmodule Number42.Refactors.Ex.RangeLiteralToRangeNew do
  @moduledoc """
  Rewrites range literals to explicit `Range.new/2,3` calls:

      a..b        ->  Range.new(a, b)
      a..b//step  ->  Range.new(a, b, step)

  ## Opinionated / opt-in — DEFAULT-OFF

  This refactor runs **against** the library's usual
  `verbose -> idiomatic-short` direction and against the common Elixir
  style guide, which prefers the `a..b` literal. Most Elixir code reads
  better with the literal, so the refactor is **disabled by default** and
  only fires when called with `enabled: true`. There is no
  `skipped_modules` entry — the in-module `enabled` gate *is* the
  default-off convention (same as `SortReverseToDesc` and
  `ExtractExpressionClone`).

  It exists for the cases where the explicit call is genuinely clearer:

  - **Visible step semantics** — `a..b//step` is easy to misread; the
    call form `Range.new(a, b, step)` names the third argument.
  - **Dynamic bounds** — when `a`/`b`/`step` are non-trivial expressions,
    `Range.new(x + 1, y - 1, z)` can read better than
    `(x + 1)..(y - 1)//z`.

  ## What we never touch

  - **Full-slice `..`** (no operands, as in `String.slice(s, ..)`) — there
    is no `Range.new` equivalent that reads better. Matched as
    `{:.., _, []}` and skipped.
  - **Ranges in guards and patterns** — `Range.new/2,3` is a function
    call and is illegal where a range literal is required *syntax*:
    a `when` guard (`x in 1..10`), a clause pattern
    (`case n do 1..10 -> … end`), or a match LHS (`1..10 = r`). We build
    the set of nodes reachable from those positions (cf.
    `LengthZeroToEmpty`'s guard set) and skip any range inside them.

  ## Idempotence

  After rewriting, the AST holds a `Range.new(...)` call — which has no
  `..` node — so a second pass is a no-op.

  Operands are sliced from source via `slice_node/2`, preserving the
  author's original spelling. Emission goes through `Sourceror.patch_string/2`;
  `mix format` re-normalises afterwards.
  """

  use Number42.Refactors.Refactor

  import Number42.Refactors.AstHelpers, only: [slice_node: 2]

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "a..b -> Range.new(a, b) (opinionated, default-off)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    OPINIONATED / OPT-IN. This inverts the usual short-form preference:
    most Elixir reads better with the `a..b` literal, so this refactor is
    DEFAULT-OFF and only runs with `enabled: true`. Turn it on when you
    want explicit `Range.new/2,3` for its named step argument
    (`Range.new(a, b, step)` vs the easy-to-misread `a..b//step`) or for
    dynamic bounds where the call form is clearer than
    `(x + 1)..(y - 1)//z`. Full-slice `..` and ranges in guards/patterns
    (where the literal is required syntax) are left untouched.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 150

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      Sourceror.parse_string(source) |> apply_patches(source)
    else
      source
    end
  end

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast, source) do
    pattern_nodes = collect_pattern_nodes(ast)

    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&maybe_patch(&1, pattern_nodes, source))
  end

  # Nodes reachable from positions where a range literal is required
  # syntax and `Range.new/_` would be illegal: `when` guards, clause
  # patterns (`->` LHS), and match LHS (`=` left side).
  defp collect_pattern_nodes(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&pattern_subtrees/1)
    |> Enum.flat_map(&Enum.to_list(Macro.prewalker(&1)))
    |> MapSet.new()
  end

  defp pattern_subtrees({:when, _, [_head, guard]}), do: [guard]
  defp pattern_subtrees({:->, _, [patterns, _body]}), do: patterns
  defp pattern_subtrees({:=, _, [lhs, _rhs]}), do: [lhs]
  defp pattern_subtrees(_), do: []

  defp maybe_patch({:.., _, [a, b]} = node, pattern_nodes, source) do
    if MapSet.member?(pattern_nodes, node), do: [], else: rewrite(node, [a, b], source)
  end

  defp maybe_patch({:..//, _, [a, b, step]} = node, pattern_nodes, source) do
    if MapSet.member?(pattern_nodes, node), do: [], else: rewrite(node, [a, b, step], source)
  end

  # Full-slice `..` (no operands) and everything else: leave alone.
  defp maybe_patch(_, _, _), do: []

  defp rewrite(node, operands, source) do
    operands
    |> Enum.map(&slice_node(source, &1))
    |> build_replacement(node)
  end

  defp build_replacement(texts, node) do
    if Enum.all?(texts, &match?({:ok, _}, &1)) do
      args = Enum.map_join(texts, ", ", fn {:ok, t} -> t end)
      [Patch.replace(node, "Range.new(#{args})")]
    else
      []
    end
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
