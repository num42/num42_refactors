defmodule Number42.Refactors.Ex.SortForTopK do
  @moduledoc """
  Rewrites pipelines that fully sort a collection just to read one
  end. Mirrors `ExSlop.Check.Refactor.SortForTopK`.

      Enum.sort(coll) |> Enum.take(1)        # → [Enum.min(coll)]
      Enum.sort(coll) |> hd()                # → Enum.min(coll)
      Enum.sort(coll, :desc) |> Enum.take(1) # → [Enum.max(coll)]
      Enum.sort(coll, :desc) |> hd()         # → Enum.max(coll)

  `O(n log n)` work degenerates to `O(n)` and the pipeline collapses to
  a single call.

  ## Why these four cases only

  - `Enum.sort(coll, :asc)` is the same as default `sort/1`; we accept
    both, plus omitted-arg form.
  - `Enum.sort(coll, fun)` with a custom comparator is left alone:
    rewriting it to `Enum.min_by/2` would only be correct when the
    comparator is `&Function.identity/1`-equivalent; we can't tell.
    `sort_by/2` is its own family and a separate refactor.
  - `Enum.take(coll, 1)` returns a list — preserve that by wrapping
    `Enum.min/max` in a list. `mix format` collapses any redundant
    brackets afterwards.
  - `hd/1` returns a scalar — emit the bare `Enum.min/max` call.

  ## Pipeline vs. nested form

  Sourceror keeps `|>` as a real `{:|>, _, [left, right]}` AST node
  (it does *not* normalize pipelines to nested calls). So we handle
  both shapes explicitly:

  - Nested: outer `Enum.take(Enum.sort(coll), 1)` or `hd(Enum.sort(coll))`
  - Piped:  `<sort> |> Enum.take(1)` or `<sort> |> hd()`, with the
    `<sort>` itself possibly the tail of a longer pipeline whose
    head produces the collection.

  In the piped case we walk a flattened step list (see `unpipe/1`)
  and look for adjacent `sort` + `take(1)`/`hd()` pairs.

  ## Procedural mode

  Four input shapes × two output shapes × two pipeline encodings mean
  many near-identical declarative refactors; one walk over the AST
  keeps the dispatch in one place.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Enum.sort + take(1)/hd -> Enum.min/max"

  @impl Number42.Refactors.Refactor
  def priority, do: 130

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Sorting a list to read one end is `O(n log n)` work for an answer
    obtainable in `O(n)`. `Enum.min`/`Enum.max` are the dedicated calls
    for "the smallest/largest element" — they need a single linear
    pass and no allocation of a sorted intermediate. The replacement
    also reads better: "the minimum of `list`" beats "sort `list` and
    take the first one".
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_patches(ast) do
    inner_pipes = collect_inner_pipes(ast)

    ast
    |> Macro.prewalker()
    |> Enum.flat_map(
      &case &1 do
        # Skip non-outermost `:|>` nodes; the outermost pipe drives
        # the rewrite and includes the inner pipes in its patch range.
        # Without this filter, `prewalker` would emit overlapping
        # patches for the same source region and `Sourceror.patch_string`
        # would crash.
        {:|>, _, _} ->
          if MapSet.member?(inner_pipes, &1), do: [], else: maybe_patch(&1)

        _ ->
          maybe_patch(&1)
      end
    )
  end

  defp collapse_step(:asc, :scalar), do: enum_partial(:min)
  defp collapse_step(:desc, :scalar), do: enum_partial(:max)
  defp collapse_step(:asc, :list), do: enum_partial(:min)
  defp collapse_step(:desc, :list), do: enum_partial(:max)

  defp collect_inner_pipes(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.reduce(MapSet.new(), fn
      {:|>, _, [{:|>, _, _} = inner, _right]}, acc -> MapSet.put(acc, inner)
      _, acc -> acc
    end)
  end

  defp direction_atom({:__block__, _, [atom]}) when atom in [:asc, :desc], do: atom
  defp direction_atom(atom) when atom in [:asc, :desc], do: atom
  defp direction_atom(_), do: nil

  defp do_rewrite_steps([sort, follower | rest], acc, fired?) do
    with {:ok, _coll, direction} <- partial_sort_call(sort),
         {:ok, mode} <- top_k_step(follower) do
      collapsed = collapse_step(direction, mode)
      do_rewrite_steps(rest, [collapsed | acc], true)
    else
      _ -> do_rewrite_steps([follower | rest], [sort | acc], fired?)
    end
  end

  defp do_rewrite_steps([last], acc, true), do: {:ok, [last | acc] |> Enum.reverse()}
  defp do_rewrite_steps([], acc, true), do: {:ok, acc |> Enum.reverse()}
  defp do_rewrite_steps(_, _, false), do: :unchanged

  defp enum_partial(fun),
    do: {{:., [], [{:__aliases__, [], [:Enum]}, fun]}, [], []}

  defp maybe_patch({:|>, _, _} = node) do
    steps = unpipe(node)

    rewrite_steps(steps) |> pipeline_patch_or_skip(node)
  end

  defp maybe_patch({{:., _, [{:__aliases__, _, [:Enum]}, :take]}, _, [inner, take_arg]} = node) do
    with {:ok, take_one?} <- take_one_arg(take_arg),
         true <- take_one?,
         {:ok, coll, direction} <- sort_call(inner) do
      [Patch.replace(node, render(:list, coll, direction))]
    else
      _ -> []
    end
  end

  defp maybe_patch({:hd, _, [inner]} = node), do: sort_call(inner) |> sort_patch_or_skip(node)

  defp maybe_patch(_), do: []

  defp partial_sort_call({{:., _, [{:__aliases__, _, [:Enum]}, :sort]}, _, []}),
    do: {:ok, :__piped__, :asc}

  defp partial_sort_call({{:., _, [{:__aliases__, _, [:Enum]}, :sort]}, _, [dir]}),
    do: direction_atom(dir) |> direction_or_skip()

  defp partial_sort_call(_), do: :skip

  defp render(:scalar, coll, direction) do
    fun = if direction == :asc, do: :min, else: :max
    Sourceror.to_string({{:., [], [{:__aliases__, [], [:Enum]}, fun]}, [], [coll]})
  end

  defp render(:list, coll, direction) do
    fun = if direction == :asc, do: :min, else: :max
    inner = {{:., [], [{:__aliases__, [], [:Enum]}, fun]}, [], [coll]}
    Sourceror.to_string([inner])
  end

  defp render_pipeline([single]), do: single |> Sourceror.to_string()

  defp render_pipeline([first | rest]) do
    pipeline =
      rest
      |> Enum.reduce(first, fn step, acc ->
        {:|>, [], [acc, step]}
      end)

    Sourceror.to_string(pipeline)
  end

  defp rewrite_steps(rewrited_steps), do: rewrited_steps |> do_rewrite_steps([], false)

  defp sort_call({{:., _, [{:__aliases__, _, [:Enum]}, :sort]}, _, [coll]}),
    do: {:ok, coll, :asc}

  defp sort_call({{:., _, [{:__aliases__, _, [:Enum]}, :sort]}, _, [coll, dir]}),
    do: direction_atom(dir) |> coll_direction_or_skip(coll)

  defp sort_call(_), do: :skip
  defp take_one_arg({:__block__, _, [1]}), do: {:ok, true}
  defp take_one_arg(1), do: {:ok, true}
  defp take_one_arg(_), do: {:ok, false}

  defp top_k_step({{:., _, [{:__aliases__, _, [:Enum]}, :take]}, _, [arg]}),
    do: take_one_arg(arg) |> take_kind_or_skip()

  defp top_k_step({:hd, _, []}), do: {:ok, :scalar}
  defp top_k_step({:hd, _, nil}), do: {:ok, :scalar}
  defp top_k_step(_), do: :skip
  defp unpipe({:|>, _, [left, right]}), do: unpipe(left) ++ [right]
  defp unpipe(other), do: [other]

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp pipeline_patch_or_skip({:ok, new_steps}, node),
    do: [Patch.replace(node, render_pipeline(new_steps))]

  defp pipeline_patch_or_skip(:unchanged, _node), do: []

  defp sort_patch_or_skip({:ok, coll, direction}, node),
    do: [Patch.replace(node, render(:scalar, coll, direction))]

  defp sort_patch_or_skip(_, _node), do: []

  defp direction_or_skip(:asc), do: {:ok, :__piped__, :asc}

  defp direction_or_skip(:desc), do: {:ok, :__piped__, :desc}

  defp direction_or_skip(_), do: :skip

  defp coll_direction_or_skip(:asc, coll), do: {:ok, coll, :asc}

  defp coll_direction_or_skip(:desc, coll), do: {:ok, coll, :desc}

  defp coll_direction_or_skip(_, _coll), do: :skip

  defp take_kind_or_skip({:ok, true}), do: {:ok, :list}

  defp take_kind_or_skip(_), do: :skip

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
