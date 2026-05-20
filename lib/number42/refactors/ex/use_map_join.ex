defmodule Number42.Refactors.Ex.UseMapJoin do
  @moduledoc """
  Rewrites `Enum.map(coll, fun) |> Enum.join(sep)` to
  `Enum.map_join(coll, sep, fun)`.

  Mirrors `ExSlop.Check.Refactor.UseMapJoin`. The chained form
  allocates an intermediate list; `Enum.map_join/3` walks the source
  once.

  Both surface forms (`coll |> Enum.map(fun) |> Enum.join(sep)` and
  `Enum.join(Enum.map(coll, fun), sep)`) parse to the same AST shape,
  so one walker handles both.

  ## Scope

  Only the `Enum.join/2` form is rewritten. The zero-arg
  `Enum.join/1` (default separator `""`) doesn't match `Enum.map_join`'s
  arity-3 signature without manually inserting `""`, and writing
  `Enum.map_join(coll, "", fun)` for what was originally
  `Enum.map(coll, fun) |> Enum.join()` reads worse than the
  before-form. We leave it alone.

  ## Why procedural

  An earlier version was declarative (`from`/`replacement`) but the
  ExAST patcher's capture-and-re-emit path corrupts two things:

  - **Map-access**: `series_type.item_types` (a captured pipe-first
    arg) re-emits as `series_type.item_types()` — a runtime
    `UndefinedFunctionError`.
  - **String escapes**: a captured `"\\n"` separator round-trips as
    `"\\\\n"` (literally backslash-n).

  Going procedural lets us splice the *original source bytes* for
  `coll`, `sep`, and `fun` via `Sourceror.get_range/1` — no
  re-emission, no corruption.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Enum.map(coll, fun) |> Enum.join(sep) -> Enum.map_join(coll, sep, fun)"

  @impl Number42.Refactors.Refactor
  def priority, do: 130

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Mapping then joining is two passes over the data and an
    intermediate list of strings that exists only to be consumed by the
    next step. `Enum.map_join/3` fuses them into a single pass with no
    temporary list — and the call site reads as "produce a separator-
    joined string from this projection", which is what the original
    pipeline meant.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_patches(ast, source),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch(&1, source))
      |> drop_enclosing_patches()

  # Nested `Enum.map(...) |> Enum.join(...)` pipes generate one patch
  # for the outer chain and one for the inner one — both written to
  # the same source. Submitting both to `Sourceror.patch_string/2`
  # produces overlapping ranges; the outer patch silently swallows
  # bytes the inner one already consumed, corrupting whatever follows
  # the outer pipe (typically a comment on the next line). Keep the
  # innermost patch and drop any patch whose range strictly encloses
  # another — the engine's fixpoint loop will pick up the outer in a
  # later pass once the inner is rewritten.
  defp drop_enclosing_patches(patches) do
    patches
    |> Enum.reject(fn p ->
      patches |> Enum.any?(fn other -> other != p and encloses?(p.range, other.range) end)
    end)
  end

  defp encloses?(outer, inner),
    do:
      pos_le(outer.start, inner.start) and pos_le(inner.end, outer.end) and
        not (pos_eq(outer.start, inner.start) and pos_eq(outer.end, inner.end))

  defp pos_le(a, b), do: {a[:line], a[:column]} <= {b[:line], b[:column]}

  defp pos_eq(a, b), do: a[:line] == b[:line] and a[:column] == b[:column]

  # Nested form: `Enum.join(Enum.map(coll, fun), sep)`.
  defp maybe_patch(
         {{:., _, [{:__aliases__, _, [:Enum]}, :join]}, _,
          [
            {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [coll, fun]},
            sep
          ]} = node,
         source
       ),
       do: node |> rewrite(coll, fun, sep, source)

  # Pipe form: `coll |> Enum.map(fun) |> Enum.join(sep)`.
  # Sourceror keeps `|>` as a node — no automatic expansion to the
  # nested form, so we have to match the chain shape directly.
  defp maybe_patch(
         {:|>, _,
          [
            {:|>, _,
             [
               coll,
               {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [fun]}
             ]},
            {{:., _, [{:__aliases__, _, [:Enum]}, :join]}, _, [sep]}
          ]} = node,
         source
       ),
       do: node |> rewrite(coll, fun, sep, source)

  defp maybe_patch(_, _), do: []

  defp rewrite(node, coll, fun, sep, source) do
    coll_text = slice_node(source, coll)
    fun_text = slice_node(source, fun)
    sep_text = slice_node(source, sep)

    case [coll_text, fun_text, sep_text] do
      [{:ok, c}, {:ok, f}, {:ok, s}] ->
        [Patch.replace(node, "Enum.map_join(#{c}, #{s}, #{f})")]

      _ ->
        []
    end
  end

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
