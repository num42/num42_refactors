defmodule Number42.Refactors.Ex.DropTrailingReturnBinding do
  @moduledoc """
  Drops a trailing binding that exists only to be returned: when the
  **last statement** of a block is a bare variable `v` and the statement
  immediately before it is `v = rhs` (bare-variable LHS), removes the
  binding and lets `rhs` be the block's final expression.

      def something(some) do
        # ...
        binding = some_call_or_statement
        binding
      end
      ↓
      def something(some) do
        # ...
        some_call_or_statement
      end

  ## Why this needs no purity check (unlike #37 InlineSingleUseBinding)

  `InlineSingleUseBinding` inlines a binding **into a following use
  site**, so it must prove the RHS is pure: it moves the evaluation and
  could reorder or duplicate it. This refactor has **no use site** — the
  binding *is* the block's return value. Dropping `v =` leaves `rhs` in
  the exact same position it already occupied: nothing moves, nothing
  duplicates, evaluation order is unchanged. A side-effecting or
  possibly-raising `rhs` (`Repo.insert(...)`, `do_thing!()`) is still
  safe to de-bind — it stays the last evaluated expression and its
  result was already what the block returned.

  ## When we rewrite

  All of:

  - The block's **last expression** is a bare variable `v`
    (`AstHelpers.bare_var/1`), not a pattern or call.
  - The **immediately preceding** statement is `v = rhs` where the LHS
    is a **bare variable** — not a pattern match (`{:ok, v} = …`,
    `%X{} = …`). A pattern carries match semantics (a possible
    `MatchError`, a destructured shape); dropping it would change
    behaviour, so pattern LHS is skipped.
  - `v` is **not read anywhere else** in the block — not in `rhs`
    (recursion / shadowing of an outer `v`) and not in any statement
    before the binding. If it were, removing the binding would break
    that other read.

  Applies to any block tail: `def`/`defp` bodies, `fn` bodies,
  `case`/`with`/`if` arm bodies, `quote` blocks — every one parses as a
  `{:__block__, _, [..., v = rhs, v]}`.

  ## What we skip

  - Pattern-match LHS (`{:ok, v} = …; v`) — the match is doing work.
  - The binding variable is also read earlier in the block — then it is
    not just a return shim.
  - The binding variable appears in its own `rhs` — dropping the binding
    would change what the trailing reference resolved to.
  - A single-statement block — there is no preceding binding to drop.

  ## Idempotence & determinism

  At most **one** shim is dropped per pass — the first eligible block in
  source order. After the rewrite the trailing `v = rhs; v` shape is
  gone, so a re-run finds nothing there; the engine's fixpoint loop
  picks up any remaining shims on later passes.
  """

  use Number42.Refactors.Refactor

  @impl Number42.Refactors.Refactor
  def description, do: "Drop a trailing `v = rhs; v` shim, returning `rhs` directly"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A binding whose only purpose is to be returned on the next line is a
    name with no payoff — it forces the reader to hold `result` in their
    head across a line break only to learn it's immediately handed back.
    Because the binding sits at the block's tail with no use site,
    dropping `result =` leaves the RHS exactly where it was: same
    position, same evaluation order, no purity requirement. The result
    is one fewer name and a block that says what it returns directly.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp apply_patches({:ok, ast}, source),
    do: ast |> first_shim_patches() |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  # First eligible block in source order, so output stays deterministic.
  defp first_shim_patches(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value([], fn
      {:__block__, _, exprs} when is_list(exprs) and length(exprs) >= 2 ->
        shim_patches(exprs)

      _ ->
        nil
    end)
  end

  # The block tail must be `… ; v = rhs ; v` with a bare-variable LHS
  # matching the trailing bare-variable return, and `v` read nowhere
  # else in the block.
  defp shim_patches(exprs) do
    [return | rev_rest] = Enum.reverse(exprs)
    [binding | rev_prefix] = rev_rest

    with {:ok, ret_var} <- bare_var(return),
         {:=, _, [lhs, rhs]} <- binding,
         {:ok, ^ret_var} <- bare_var(lhs),
         false <- read?(ret_var, rhs),
         false <- Enum.any?(rev_prefix, &read?(ret_var, &1)) do
      [replace_binding_with_rhs(binding, rhs), delete_return(return)]
    else
      _ -> nil
    end
  end

  defp read?(var, ast), do: MapSet.member?(used_var_names(ast), var)

  defp replace_binding_with_rhs(binding, rhs),
    do: %{change: Sourceror.to_string(rhs), range: Sourceror.get_range(binding)}

  defp delete_return(return), do: %{change: "", range: Sourceror.get_range(return)}

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
