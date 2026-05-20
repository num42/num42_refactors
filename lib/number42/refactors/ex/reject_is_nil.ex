defmodule Number42.Refactors.Ex.RejectIsNil do
  @moduledoc """
  Rewrites manual nil-filtering lambdas to `Enum.reject(&is_nil/1)`.

      # filter-out-nil shapes (mirrors ExSlop's FilterNil)
      Enum.filter(list, fn x -> x != nil end)
      Enum.filter(list, fn x -> !is_nil(x) end)
      list |> Enum.filter(fn x -> not is_nil(x) end)
      ↓
      Enum.reject(list, &is_nil/1)
      list |> Enum.reject(&is_nil/1)

      # keep-only-nil shapes (mirrors ExSlop's RejectNil)
      Enum.reject(list, fn x -> x == nil end)
      list |> Enum.reject(fn x -> is_nil(x) end)
      ↓
      Enum.reject(list, &is_nil/1)
      list |> Enum.reject(&is_nil/1)

  The two ExSlop checks (`FilterNil` and `RejectNil`) collapse into a
  single rewrite here: both endpoints are `Enum.reject(&is_nil/1)`.

  ## What we match

  - Host call: `Enum.filter/2` or `Enum.reject/2`, direct or piped.
  - Lambda: exactly one clause, single bare-variable arg `x`,
    single-statement body that is one of:
    - `x != nil`, `nil != x`, `x !== nil`, `nil !== x` *(filter only)*
    - `!is_nil(x)`, `not is_nil(x)` *(filter only)*
    - `x == nil`, `nil == x`, `x === nil`, `nil === x` *(reject only)*
    - `is_nil(x)` *(reject only)*

  Pairing the operator polarity with the host function is intentional:
  `Enum.filter(list, fn x -> x == nil end)` keeps **only** nils, which
  is almost certainly a bug — we don't auto-rewrite it; a human should
  look.

  ## Procedural mode

  We only patch the `fn ... end` subterm with a `&is_nil/1` capture
  (and rewrite the host name to `:reject` if it was `:filter`). This
  avoids restructuring the surrounding call and stays well-behaved in
  pipe positions.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Manual nil-filtering lambdas -> Enum.reject(&is_nil/1)"

  @impl Number42.Refactors.Refactor
  def priority, do: 150

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    "Drop the nils" is one of the most common pipeline steps and shows
    up in a dozen subtly different shapes (`fn x -> x != nil end`,
    `fn x -> not is_nil(x) end`, `&(&1 != nil)`, …) — all the same
    operation, none of them obvious at a glance. Collapsing them to
    `Enum.reject(&is_nil/1)` makes the intent searchable and uniform
    so a reader recognises the step instantly across files.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp body_matches_polarity?(:filter, body, predicate) do
    case body do
      {op, _, [lhs, rhs]} when op in [:!=, :!==] -> nil_op_pair?(lhs, rhs, predicate)
      {:!, _, [{:is_nil, _, [arg]}]} -> predicate.(arg)
      {:not, _, [{:is_nil, _, [arg]}]} -> predicate.(arg)
      _ -> false
    end
  end

  defp body_matches_polarity?(:reject, body, predicate) do
    case body do
      {op, _, [lhs, rhs]} when op in [:==, :===] -> nil_op_pair?(lhs, rhs, predicate)
      {:is_nil, _, [arg]} -> predicate.(arg)
      _ -> false
    end
  end

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp capture_arg_ref?(ast, n) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:&, _, [^n]} -> true
      _ -> false
    end)
  end

  defp capture_text(:identity), do: "&is_nil/1"

  defp capture_text({:projection, projection}) do
    proj_text = Sourceror.to_string(projection)
    "&is_nil(#{proj_text})"
  end

  defp classify(host, {:fn, _, [{:->, _, [[arg], body]}]}) do
    with {:ok, var} <- bare_var(arg),
         true <- body_matches_polarity?(host, body, &var_ref?(&1, var)) do
      {:ok, :identity}
    else
      _ -> :skip
    end
  end

  defp classify(host, {:&, _, [body]}) do
    body = unwrap_block(body)

    extract_projection(body, host) |> capture_kind_or_skip()
  end

  defp classify(_, _), do: :skip

  defp extract_projection(body, :filter) do
    case body do
      {op, _, [lhs, rhs]} when op in [:!=, :!==] -> non_nil_operand(lhs, rhs)
      {:!, _, [{:is_nil, _, [arg]}]} -> {:ok, arg}
      {:not, _, [{:is_nil, _, [arg]}]} -> {:ok, arg}
      _ -> :skip
    end
  end

  defp extract_projection(body, :reject) do
    case body do
      {op, _, [lhs, rhs]} when op in [:==, :===] -> non_nil_operand(lhs, rhs)
      {:is_nil, _, [arg]} -> {:ok, arg}
      _ -> :skip
    end
  end

  defp maybe_patch({{:., _, [{:__aliases__, _, [:Enum]}, host]}, _, [coll, fun]} = node)
       when host in [:filter, :reject] do
    classify(host, fun) |> reject_patch_or_skip(coll, node)
  end

  defp maybe_patch({{:., _, [{:__aliases__, _, [:Enum]}, host]}, _, [fun]} = node)
       when host in [:filter, :reject] do
    classify(host, fun) |> reject_patch_or_skip(node)
  end

  defp maybe_patch(_), do: []
  defp nil_literal?(nil), do: true
  defp nil_literal?({:__block__, _, [nil]}), do: true
  defp nil_literal?(_), do: false

  defp nil_op_pair?(lhs, rhs, predicate),
    do:
      (nil_literal?(lhs) and predicate.(rhs)) or
        (nil_literal?(rhs) and predicate.(lhs))

  defp non_nil_operand(lhs, rhs) do
    cond do
      nil_literal?(lhs) and not nil_literal?(rhs) -> {:ok, rhs}
      nil_literal?(rhs) and not nil_literal?(lhs) -> {:ok, lhs}
      true -> :skip
    end
  end

  defp uses_other_capture_args?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:&, _, [n]} when is_integer(n) and n != 1 -> true
      _ -> false
    end)
  end

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp capture_kind_or_skip({:ok, projection}) do
    cond do
      not capture_arg_ref?(projection, 1) -> :skip
      uses_other_capture_args?(projection) -> :skip
      # Identity case: `&(&1 != nil)` or `&(&1 == nil)`. Bare `&1`
      # reference equals an identity check — collapse to `&is_nil/1`.
      match?({:&, _, [1]}, projection) -> {:ok, :identity}
      true -> {:ok, {:projection, projection}}
    end
  end

  defp capture_kind_or_skip(:skip), do: :skip

  defp reject_patch_or_skip({:ok, kind}, coll, node) do
    coll_text = Sourceror.to_string(coll)
    [Patch.replace(node, "Enum.reject(#{coll_text}, #{capture_text(kind)})")]
  end

  defp reject_patch_or_skip(:skip, _coll, _node), do: []

  defp reject_patch_or_skip({:ok, kind}, node),
    do: [Patch.replace(node, "Enum.reject(#{capture_text(kind)})")]

  defp reject_patch_or_skip(:skip, _node), do: []

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
