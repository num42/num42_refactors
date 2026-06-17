defmodule Number42.Refactors.Ex.MemberToInOperator do
  @moduledoc """
  Rewrites `Enum.member?(coll, x)` to the `in` operator: `x in coll`.

  `Kernel.in/2` lowers to exactly `Enum.member?/2` for non-literal
  right-hand sides — a 1:1 equivalence, purely a readability win. Note
  the argument order flips: the element moves to the left of `in`.

  Negated calls fold into the `not in` form:

      not Enum.member?(ids, id)   →   id not in ids
      !Enum.member?(ids, id)      →   id not in ids

  ## Guard context

  Inside a `when` clause, `in/2` is only legal when the right-hand side
  is a compile-time list or range literal. `Enum.member?/2` isn't
  guard-callable either, so such code is already broken — but we only
  rewrite when the result is legal: collection must be a list literal
  of plain literals or a literal integer range. Anything else inside a
  guard is skipped.

  ## Pipe form

  The single-stage pipe `coll |> Enum.member?(x)` rewrites to
  `x in coll` (the pipe injects `coll` as first arg). A multi-stage
  pipe tail (`a |> b() |> Enum.member?(x)`) is left alone — inlining
  the chain as `x in (a |> b())` reads worse than the original
  (mirrors `MergePipelineIntoComprehension` declining pipe heads).

  ## Operand parenthesization

  `in` binds tighter than `||`/`and`/comparisons and looser than
  arithmetic. Operands whose root is a loose-binding operator are
  wrapped in parens (`Enum.member?(coll, a || b)` → `(a || b) in coll`)
  so the rewrite never re-associates.

  ## Idempotence

  The result contains no `Enum.member?` node; a second pass matches
  nothing.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  # Binary operators that bind looser than (or equal to) `in` — an
  # operand rooted in one of these must be parenthesized, otherwise the
  # emitted `x in coll` re-associates.
  @loose_binary_ops [
    :=,
    :when,
    :"::",
    :or,
    :||,
    :and,
    :&&,
    :==,
    :!=,
    :===,
    :!==,
    :<,
    :>,
    :<=,
    :>=,
    :=~,
    :in,
    :|>
  ]
  @loose_unary_ops [:not, :!]

  @impl Number42.Refactors.Refactor
  def description, do: "Enum.member?(coll, x) -> x in coll"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `x in coll` is the idiomatic Elixir membership test and reads as
    natural language; `Kernel.in/2` is defined as exactly
    `Enum.member?/2`, so there is no runtime difference. Negated calls
    become the `not in` form, which is clearer still than a `not`
    wrapped around a function call.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 130
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  @impl Number42.Refactors.Refactor
  def patches(ast, source, _opts), do: build_patches(ast, source)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast, source) do
    guard_nodes = collect_guard_nodes(ast)
    negation_handled = collect_negation_handled(ast)

    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&maybe_patch(&1, source, guard_nodes, negation_handled))
  end

  defp collect_guard_nodes(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:when, _, [_inner, guard]} -> guard |> Macro.prewalker() |> Enum.to_list()
      _ -> []
    end)
    |> MapSet.new()
  end

  # Member? calls directly under a `not`/`!` are rewritten on the parent
  # node (to `not in`); the bare-call walker must skip them.
  defp collect_negation_handled(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {neg, _, [call]} when neg in [:not, :!] ->
        case member_call(call) do
          {:ok, _, _} -> [call]
          :skip -> []
        end

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp maybe_patch({neg, _, [call]} = node, source, guard_nodes, _handled)
       when neg in [:not, :!] do
    case member_call(call) do
      {:ok, coll, x} -> rewrite(node, coll, x, "not in", source, guard_nodes)
      :skip -> []
    end
  end

  defp maybe_patch(node, source, guard_nodes, handled) do
    case {MapSet.member?(handled, node), member_call(node)} do
      {false, {:ok, coll, x}} -> rewrite(node, coll, x, "in", source, guard_nodes)
      _ -> []
    end
  end

  defp member_call({{:., _, [{:__aliases__, _, [:Enum]}, :member?]}, _, [coll, x]}),
    do: {:ok, coll, x}

  defp member_call({:|>, _, [coll, {{:., _, [{:__aliases__, _, [:Enum]}, :member?]}, _, [x]}]}) do
    if pipe?(coll), do: :skip, else: {:ok, coll, x}
  end

  defp member_call(_), do: :skip
  defp pipe?({:|>, _, _}), do: true
  defp pipe?(_), do: false

  defp rewrite(node, coll, x, op, source, guard_nodes) do
    if MapSet.member?(guard_nodes, node) and not guard_safe_collection?(coll) do
      []
    else
      case {slice_node(source, x), slice_node(source, coll)} do
        {{:ok, x_text}, {:ok, coll_text}} ->
          [
            Patch.replace(
              node,
              "#{parenthesize(x, x_text)} #{op} #{parenthesize(coll, coll_text)}"
            )
          ]

        _ ->
          []
      end
    end
  end

  defp parenthesize(ast, text), do: if(loose_root?(ast), do: "(#{text})", else: text)

  defp loose_root?({op, _, [_, _]}) when op in @loose_binary_ops, do: true
  defp loose_root?({op, _, [_]}) when op in @loose_unary_ops, do: true
  defp loose_root?(_), do: false

  # `in` inside a guard needs a compile-time list of plain literals or a
  # literal integer range on the right.
  defp guard_safe_collection?({:__block__, _, [inner]}), do: guard_safe_collection?(inner)
  defp guard_safe_collection?(list) when is_list(list), do: Enum.all?(list, &plain_literal?/1)

  defp guard_safe_collection?({:.., _, [lo, hi]}),
    do: plain_literal?(lo) and plain_literal?(hi)

  defp guard_safe_collection?(_), do: false

  defp plain_literal?({:__block__, _, [inner]}), do: plain_literal?(inner)
  defp plain_literal?({:-, _, [inner]}), do: plain_literal?(inner)

  defp plain_literal?(value),
    do: is_atom(value) or is_number(value) or is_binary(value)

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
