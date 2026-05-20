defmodule Num42.Refactors.Refactors.RedundantBooleanIf do
  @moduledoc """
  Rewrites `if cond, do: true, else: false` (and the negated form) to
  the condition itself. Mirrors `ExSlop.Check.Refactor.RedundantBooleanIf`.

      if status == :active, do: true, else: false
      ↓
      status == :active

      if !is_nil(x), do: false, else: true
      ↓
      !!is_nil(x)            # negated form: prepend `!` to the condition

  ## What we match

  Both keyword (`do:`/`else:`) and block (`do … else … end`) forms
  collapse to the same AST shape — `{:if, _, [cond, [do: T, else: F]]}`
  where Sourceror wraps literal booleans either bare or in `__block__`.
  We accept all four combinations.

  Single-branch `if cond, do: true` (no `else`) is intentionally **not**
  rewritten: when the condition is falsy the value is `nil`, not
  `false`, so dropping the `if` would change semantics.

  ## Negated form

  `if cond, do: false, else: true` is equivalent to `!cond` — but
  emitting `!cond` for a compound condition would change precedence
  (`!a == b` parses as `(!a) == b`, not `!(a == b)`). We render via
  `Sourceror.to_string` on a synthesized `{:!, _, [cond]}` node, which
  Sourceror parenthesizes correctly.

  ## Procedural mode

  Two AST shapes (positive + negated) × two literal encodings each
  would mean four declarative pairs with near-identical bookkeeping.
  One procedural pass keeps the logic in one place.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Num42.Refactors.Refactor
  def description, do: "Rewrite `if cond, do: true, else: false` to the condition itself"

  @impl Num42.Refactors.Refactor
  def priority, do: 120

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    `if x, do: true, else: false` is exactly `x` (and the inverse form
    is `!x`). The `if` adds a branch the reader has to evaluate to
    arrive at a value the condition already produced — the boolean was
    right there. Stripping the wrapper makes the expression smaller
    and removes a class of "wait, does this normalise to a boolean?"
    questions on review.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp block_atom({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp block_atom(atom) when is_atom(atom), do: atom
  defp block_atom(_), do: nil
  defp bool_literal?({:__block__, _, [v]}, v) when is_boolean(v), do: true
  defp bool_literal?(v, v) when is_boolean(v), do: true
  defp bool_literal?(_, _), do: false

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp classify(cond_ast, do_body, else_body) do
    cond do
      bool_literal?(do_body, true) and bool_literal?(else_body, false) ->
        {:ok, Sourceror.to_string(cond_ast)}

      bool_literal?(do_body, false) and bool_literal?(else_body, true) ->
        {:ok, Sourceror.to_string({:!, [], [cond_ast]})}

      true ->
        :skip
    end
  end

  defp maybe_patch({:if, _meta, [cond_ast, [{do_key, do_body}, {else_key, else_body}]]} = node) do
    with :do <- block_atom(do_key),
         :else <- block_atom(else_key),
         {:ok, replacement} <- classify(cond_ast, do_body, else_body) do
      [Patch.replace(node, replacement)]
    else
      _ -> []
    end
  end

  defp maybe_patch(_), do: []

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
