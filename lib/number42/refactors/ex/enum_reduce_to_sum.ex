defmodule Number42.Refactors.Ex.EnumReduceToSum do
  @moduledoc """
  Rewrites `Enum.reduce/3` calls that just sum a collection into the
  appropriate `Enum.sum/1` / `Enum.sum_by/2` form.

      # plain sum
      Enum.reduce(nums, 0, fn n, acc -> n + acc end)
      ↓
      Enum.sum(nums)

      # projection sum (Elixir 1.18+)
      Enum.reduce(items, 0, fn item, acc -> acc + item.qty end)
      ↓
      Enum.sum_by(items, fn item -> item.qty end)

      # piped variants are handled too
      items |> Enum.reduce(0, fn item, acc -> acc + length(item.children) end)
      ↓
      items |> Enum.sum_by(fn item -> length(item.children) end)

  Mirrors `ExSlop.Check.Refactor.ExplicitSumReduce` and extends it: the
  underlying idea is "use `Enum.sum`/`Enum.sum_by` when you're summing".
  Both `+` argument orders qualify because `+` is commutative.

  ## What we match

  - Host call: `Enum.reduce/3` with literal integer `0` as the initial
    accumulator (including the `{:__block__, _, [0]}` Sourceror shape).
  - Lambda: exactly one clause, two bare-variable patterns `arg, acc`,
    single-statement body of shape `_ + _`.
  - One of the `+` operands references **only the acc** (so it
    contributes the running total). The other operand references the
    `arg` and must NOT reference the `acc` (otherwise the projection
    would self-recur — that's not a sum).

  Special case: when the non-acc operand is the bare `arg` itself, the
  result is `Enum.sum/1` rather than `Enum.sum_by/2` with an identity
  lambda.

  ## Idempotence

  After a rewrite, the call site is `Enum.sum(...)` or
  `Enum.sum_by(...)`. Neither matches our `Enum.reduce/3` head, so a
  second pass is a no-op.

  ## Why procedural

  ExAST's pattern language can't express "lambda's body references the
  acc on one side and only the arg on the other" without a custom
  guard. We walk the AST with `Macro.prewalker/1` and emit
  `Sourceror.Patch.replace/2` per match instead.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Enum.reduce/3 summing lambdas -> Enum.sum/1 or Enum.sum_by/2"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `Enum.reduce/3` with `0` and a `+` lambda is "addition spelled out
    by hand" — the reader has to mentally evaluate the lambda to
    recognise that this is just a sum. `Enum.sum/1` and `Enum.sum_by/2`
    name the operation directly, so the intent is visible in the
    function name and the implementation detail (which accumulator,
    which order, which seed) becomes irrelevant.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 150
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)
  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
  defp apply_patches({:error, _}, source), do: source

  defp bare_var_match?({name, _, ctx} = _arg_pat, {name2, _, ctx2} = _projection)
       when is_atom(name) and is_atom(ctx) and is_atom(name2) and is_atom(ctx2),
       do: name == name2 and not underscore?(name)

  defp bare_var_match?(_, _), do: false

  defp bare_var_named?({name, _, ctx}, target)
       when is_atom(name) and is_atom(ctx),
       do: name == target

  defp bare_var_named?(_, _), do: false

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp classify({:fn, _, [{:->, _, [[arg_pat, acc_pat], body]}]}) do
    with {:ok, acc} <- bare_var(acc_pat),
         {:ok, lhs, rhs} <- plus_operands(body),
         {:ok, projection} <- pick_projection(lhs, rhs, acc),
         true <- pattern_introduces_referenced_name?(arg_pat, projection),
         false <- references_var?(projection, acc) do
      cond do
        bare_var_match?(arg_pat, projection) -> {:ok, :sum}
        true -> {:ok, {:sum_by, arg_pat, projection}}
      end
    else
      _ -> :skip
    end
  end

  defp classify(_), do: :skip

  defp lambda_text(arg_pat, projection) do
    arg_text = Sourceror.to_string(arg_pat)
    proj_text = Sourceror.to_string(projection)
    "fn #{arg_text} -> #{proj_text} end"
  end

  defp maybe_patch({{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [coll, zero, fun]} = node) do
    with true <- zero?(zero),
         {:ok, kind} <- classify(fun) do
      coll_text = Sourceror.to_string(coll)
      [Patch.replace(node, render(kind, coll_text, :direct))]
    else
      _ -> []
    end
  end

  defp maybe_patch({{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [zero, fun]} = node) do
    with true <- zero?(zero),
         {:ok, kind} <- classify(fun) do
      [Patch.replace(node, render(kind, nil, :pipe))]
    else
      _ -> []
    end
  end

  defp maybe_patch(_), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  defp pattern_introduces_referenced_name?(pat, projection),
    do:
      pattern_var_names(pat)
      |> Enum.any?(&references_var?(projection, &1))

  defp pick_projection(lhs, rhs, acc) do
    case {bare_var_named?(lhs, acc), bare_var_named?(rhs, acc)} do
      {true, false} -> {:ok, rhs}
      {false, true} -> {:ok, lhs}
      _ -> :skip
    end
  end

  defp plus_operands({:+, _, [lhs, rhs]}), do: {:ok, lhs, rhs}
  defp plus_operands(_), do: :skip

  defp references_var?(ast, target) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> name == target
      _ -> false
    end)
  end

  defp render(:sum, coll_text, :direct), do: "Enum.sum(#{coll_text})"
  defp render(:sum, _coll_text, :pipe), do: "Enum.sum()"

  defp render({:sum_by, arg_pat, projection}, coll_text, :direct),
    do: "Enum.sum_by(#{coll_text}, #{lambda_text(arg_pat, projection)})"

  defp render({:sum_by, arg_pat, projection}, _coll_text, :pipe),
    do: "Enum.sum_by(#{lambda_text(arg_pat, projection)})"

  defp zero?(0), do: true
  defp zero?({:__block__, _, [0]}), do: true
  defp zero?(_), do: false
end
