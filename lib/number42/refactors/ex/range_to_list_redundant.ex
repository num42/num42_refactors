defmodule Number42.Refactors.Ex.RangeToListRedundant do
  @moduledoc """
  Drops a redundant `Enum.to_list/1` on a range that feeds directly into
  another `Enum.*` or `Stream.*` call.

      Enum.to_list(1..n) |> Enum.map(fun)     →  1..n |> Enum.map(fun)
      1..n |> Enum.to_list() |> Enum.each(f)  →  1..n |> Enum.each(f)
      Enum.map(Enum.to_list(a..b), fun)       →  Enum.map(a..b, fun)
      Enum.to_list(a..b//s) |> Stream.map(f)  →  a..b//s |> Stream.map(f)

  A range is already an `Enumerable`; every `Enum`/`Stream` function
  consumes it directly. Materialising it to a list first allocates a
  full list only to re-enumerate it. Removing the `to_list` is a pure
  performance + clarity win with no semantic change.

  ## Matched shape — provably a range, provably a downstream consumer

  Both ends are constrained deliberately:

  - The `to_list` **argument** must be a literal range — a `..` node
    (`a..b`), a `..//` node (`a..b//step`), or `Range.new(...)`. A bare
    variable or an arbitrary expression (`Enum.to_list(some_list)`) is
    skipped: the value could be a list the consumer mutates in place, a
    map, anything. Only a syntactic range proves enumerability here.
  - The **consumer** — the thing the `to_list` result flows into — must
    be a direct `Enum.*` / `Stream.*` call (pipe or nested call). When
    the result is bound to a variable, returned, pattern-matched on a
    list shape, or passed to an unknown function, the consumer is not
    provably a list-agnostic enumerator, so we skip.

  v1 scopes to ranges only. `Enum.to_list(map) |> Enum.map(...)` is
  equally redundant but ranges are the unambiguous, common case.

  ## Patch granularity

  Only the `to_list(range)` subnode (or the inner `range |> to_list()`
  pipe) is replaced — with the original source bytes of the range via
  `slice_node/2`. The enclosing consumer call is left untouched, so its
  formatting and the downstream pipe shape survive intact.

  ## Idempotence

  `Enum.map(1..n, fun)` carries no `Enum.to_list` node; a second pass
  matches nothing.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Enum.to_list(a..b) |> Enum.map(fun) -> a..b |> Enum.map(fun)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A range is already enumerable. Wrapping it in `Enum.to_list/1`
    before another `Enum`/`Stream` call allocates a full list purely to
    re-enumerate it — a wasted pass with no semantic effect. Dropping
    the `to_list` hands the range straight to the consumer, which is
    what the code meant.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 130
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast, source),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch(&1, source))

  # range |> Enum.to_list() |> Enum.map(fun)
  #              ^ inner pipe collapses to just `range`
  defp maybe_patch(
         {:|>, _,
          [
            {:|>, _, [range, {{:., _, [{:__aliases__, _, [:Enum]}, :to_list]}, _, []}]} = inner,
            consumer
          ]},
         source
       ) do
    drop_to_list(inner, range, consumer, source)
  end

  # Enum.to_list(range) |> Enum.map(fun)
  #   ^ left operand collapses to `range`
  defp maybe_patch(
         {:|>, _,
          [{{:., _, [{:__aliases__, _, [:Enum]}, :to_list]}, _, [range]} = to_list, consumer]},
         source
       ) do
    drop_to_list(to_list, range, consumer, source)
  end

  # Enum.map(Enum.to_list(range), fun) / Stream.map(Enum.to_list(range), f)
  #   ^ first arg collapses to `range`
  defp maybe_patch(
         {{:., _, [{:__aliases__, _, [mod]}, _fun]}, _,
          [{{:., _, [{:__aliases__, _, [:Enum]}, :to_list]}, _, [range]} = to_list | _rest]} =
           consumer,
         source
       )
       when mod in [:Enum, :Stream] do
    drop_nested_to_list(to_list, range, consumer, source)
  end

  defp maybe_patch(_, _), do: []

  # Pipe forms: the consumer is the right side of the outer `|>`; it is a
  # genuine Enum/Stream call iff it's a 0-arg or partial Enum.*/Stream.* call.
  defp drop_to_list(target_node, range, consumer, source) do
    if range?(range) and enum_or_stream_call?(consumer),
      do: replace_with_range(target_node, range, source),
      else: []
  end

  # Nested-call form: the consumer head is already verified by the clause
  # head (Enum/Stream module). Only the range itself needs checking.
  defp drop_nested_to_list(to_list_node, range, _consumer, source) do
    if range?(range),
      do: replace_with_range(to_list_node, range, source),
      else: []
  end

  defp replace_with_range(node, range, source) do
    case slice_node(source, range) do
      {:ok, range_text} -> [Patch.replace(node, range_text)]
      :error -> []
    end
  end

  # Literal range: a..b, a..b//step, or Range.new(...).
  defp range?({:.., _, [_, _]}), do: true
  defp range?({:..//, _, [_, _, _]}), do: true
  defp range?({{:., _, [{:__aliases__, _, [:Range]}, :new]}, _, _args}), do: true
  defp range?(_), do: false

  # A direct Enum.*/Stream.* call appearing as the right side of a pipe
  # (so it's called with the piped value as its implicit first arg).
  defp enum_or_stream_call?({{:., _, [{:__aliases__, _, [mod]}, _fun]}, _, _args})
       when mod in [:Enum, :Stream],
       do: true

  defp enum_or_stream_call?(_), do: false

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
