defmodule Number42.Refactors.Ex.ReduceAsMap do
  @moduledoc """
  Rewrites `Enum.reduce/3` calls that just build a transformed list
  into `Enum.map/2`.

      # bad — O(n²) append
      Enum.reduce(items, [], fn item, acc -> acc ++ [transform(item)] end)
      ↓
      Enum.map(items, fn item -> transform(item) end)

      # bad — manually prepending, then reversing at the end
      items
      |> Enum.reduce([], fn item, acc -> [transform(item) | acc] end)
      |> Enum.reverse()
      ↓
      Enum.map(items, fn item -> transform(item) end)

  Mirrors `ExSlop.Check.Refactor.ReduceAsMap`. We only fire on the
  two shapes where the rewrite has a clear before/after argument:

  - **Append form (`acc ++ [expr]`)** — always equivalent to `Enum.map`.
    `++` produces a new list with the projection appended in order, so
    the resulting list has the same order as the input.

  - **Prepend form with trailing reverse (`[expr | acc]` followed by
    `Enum.reverse/1`)** — also equivalent. The reverse cancels the
    inverted accumulation order.

  Bare prepend without `Enum.reverse` is **left alone**. It produces a
  reversed list, which may be intentional (the caller wants the
  reversed projection) — silent rewriting would change semantics. A
  human should look at it.

  ## What we match

  - Direct call: `Enum.reduce(coll, [], fn arg, acc -> body end)`.
  - Pipe stage: `coll |> Enum.reduce([], fn arg, acc -> body end)`.
  - For the prepend-with-reverse case: the pipe stage above must be
    immediately followed by `|> Enum.reverse()`.
  - Lambda: exactly one clause, two patterns `arg, acc`. The acc must
    be a bare variable; arg can be anything (destructure, pin, ...).
  - Lambda body must be either `[expr | acc]` (prepend) or
    `acc ++ [expr]` (append) where `acc` is the lambda's acc var. The
    projection (`expr`) must reference at least one name from the arg
    pattern — otherwise it's not really a per-element projection and
    the rewrite would be misleading.

  ## Idempotence

  After a rewrite, the call site is `Enum.map(...)`. It doesn't match
  our `Enum.reduce/3` head, so a second pass is a no-op.

  ## Why procedural

  ExAST's pattern language can't express "lambda body is `[expr | acc]`
  AND `acc` matches the lambda's second pattern" without a custom
  guard, and the prepend-with-reverse rewrite spans two AST nodes
  (the reduce + the trailing reverse).
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Enum.reduce/3 building a list -> Enum.map/2"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Folding `acc ++ [x]` to grow a list is the textbook way to spell
    `Enum.map/2` by hand — and the textbook way to introduce O(n²)
    quadratic appends. `Enum.map/2` is the named operation for "build a
    new list element by element", runs in O(n), and the call site reads
    as the transformation it actually performs instead of an
    accumulator pattern.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 150
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp append_projection({:++, _, [{name, _, ctx}, rhs]}, acc_name)
       when is_atom(name) and is_atom(ctx) and name == acc_name do
    singleton_list(rhs)
  end

  defp append_projection({:__block__, _, [single]}, acc_name),
    do: append_projection(single, acc_name)

  defp append_projection(_, _), do: :skip
  @impl Number42.Refactors.Refactor
  def patches(ast, _source, _opts), do: build_patches(ast)

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp classify_append({:fn, _, [{:->, _, [[arg_pat, acc_pat], body]}]}) do
    with {:ok, acc_name} <- bare_var(acc_pat),
         {:ok, projection} <- append_projection(body, acc_name),
         true <- pattern_introduces_referenced_name?(arg_pat, projection),
         false <- references_var?(projection, acc_name) do
      {:ok, arg_pat, projection}
    else
      _ -> :skip
    end
  end

  defp classify_append(_), do: :skip

  defp classify_prepend({:fn, _, [{:->, _, [[arg_pat, acc_pat], body]}]}) do
    with {:ok, acc_name} <- bare_var(acc_pat),
         {:ok, projection} <- prepend_projection(body, acc_name),
         true <- pattern_introduces_referenced_name?(arg_pat, projection),
         false <- references_var?(projection, acc_name) do
      {:ok, arg_pat, projection}
    else
      _ -> :skip
    end
  end

  defp classify_prepend(_), do: :skip

  defp lambda_text(arg_pat, projection) do
    arg_text = Sourceror.to_string(arg_pat)
    proj_text = Sourceror.to_string(projection)
    "fn #{arg_text} -> #{proj_text} end"
  end

  defp maybe_patch(
         {:|>, _,
          [
            {:|>, _, [coll, {{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [empty, fun]}]},
            {{:., _, [{:__aliases__, _, [:Enum]}, :reverse]}, _, []}
          ]} = node
       ) do
    with true <- empty_list?(empty),
         {:ok, arg_pat, projection} <- classify_prepend(fun) do
      coll_text = Sourceror.to_string(coll)
      [Patch.replace(node, render_direct(coll_text, arg_pat, projection))]
    else
      _ -> []
    end
  end

  defp maybe_patch({{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [coll, empty, fun]} = node) do
    with true <- empty_list?(empty),
         {:ok, arg_pat, projection} <- classify_append(fun) do
      coll_text = Sourceror.to_string(coll)
      [Patch.replace(node, render_direct(coll_text, arg_pat, projection))]
    else
      _ -> []
    end
  end

  defp maybe_patch({{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [empty, fun]} = node) do
    with true <- empty_list?(empty),
         {:ok, arg_pat, projection} <- classify_append(fun) do
      [Patch.replace(node, render_pipe(arg_pat, projection))]
    else
      _ -> []
    end
  end

  defp maybe_patch(_), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  defp pattern_introduces_referenced_name?(pat, projection),
    do:
      pat
      |> pattern_var_names()
      |> Enum.any?(&references_var?(projection, &1))

  defp prepend_projection({:__block__, _, [[{:|, _, [expr, {name, _, ctx}]}]]}, acc_name)
       when is_atom(name) and is_atom(ctx) and name == acc_name,
       do: {:ok, expr}

  defp prepend_projection([{:|, _, [expr, {name, _, ctx}]}], acc_name)
       when is_atom(name) and is_atom(ctx) and name == acc_name,
       do: {:ok, expr}

  defp prepend_projection({:__block__, _, [single]}, acc_name),
    do: prepend_projection(single, acc_name)

  defp prepend_projection(_, _), do: :skip

  defp references_var?(ast, target) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> name == target
      _ -> false
    end)
  end

  defp render_direct(coll_text, arg_pat, projection),
    do: "Enum.map(#{coll_text}, #{lambda_text(arg_pat, projection)})"

  defp render_pipe(arg_pat, projection), do: "Enum.map(#{lambda_text(arg_pat, projection)})"
  defp singleton_list({:__block__, _, [[expr]]}), do: {:ok, expr}
  defp singleton_list([expr]), do: {:ok, expr}
  defp singleton_list(_), do: :skip
end
