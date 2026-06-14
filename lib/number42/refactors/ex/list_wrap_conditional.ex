defmodule Number42.Refactors.Ex.ListWrapConditional do
  @moduledoc """
  Rewrites the hand-rolled "normalise single-or-many" conditional into
  `List.wrap/1`:

      if is_list(x), do: x, else: [x]
      ↓
      List.wrap(x)

  Both the inline keyword form (`if c, do: …, else: …`) and the block
  form (`if c do … else … end`) are accepted — Sourceror parses them to
  the same `{:if, _, [cond, branches]}` shape after branch unwrapping.

  ## The `nil` divergence — why this is **default-off**

  `List.wrap/1` is **not** behaviour-equivalent to the conditional for
  `x == nil`:

      List.wrap(nil)                       # => []
      if is_list(nil), do: nil, else: [nil] # => [nil]

  `List.wrap/1` treats `nil` as "no value" and returns the empty list,
  whereas the hand-rolled conditional wraps `nil` into `[nil]`. The two
  programs differ exactly when `x` is `nil`. (For every other value the
  rewrite is exact: `List.wrap/1` returns a list unchanged and wraps any
  non-list non-nil term in a singleton — it does **not** flatten, so
  `List.wrap([a])` is `[a]`, matching the `do: x` branch.)

  We cannot prove `x` is non-nil from the conditional alone, so the
  rewrite cannot be guaranteed behaviour-preserving in general. This
  refactor is therefore registered in the library's own `.refactor.exs`
  `skipped_modules` (default-off for strict behaviour-preservation) and
  documented loudly here. Enable it per project by removing it from
  `skipped_modules` once you've confirmed the `nil` case is irrelevant
  to your call sites (or that `[nil]` vs `[]` is an acceptable shift).

  ## What we match — exact shape only

  Conservative on purpose. The rewrite fires only when:

  - the condition is exactly `is_list(x)` for a bare variable `x`,
  - the `do` branch is exactly that same variable `x`,
  - the `else` branch is exactly the singleton list `[x]` of that same
    variable.

  Anything else is skipped: a different guard (`is_map/1`, …), a `do`
  branch that is not the guarded variable, an `else` branch that is not
  `[x]` (e.g. `[x, y]`, `[other]`, an already-`List.wrap(x)`), or a
  guard variable that differs from the branch variable. The single
  matched expression carries no side effects (a bare variable read), so
  collapsing the two identical reads into one `List.wrap(x)` is safe.

  ## Idempotence

  `List.wrap(x)` has no `if is_list` shape, so a second pass is a no-op.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "if is_list(x), do: x, else: [x] -> List.wrap(x)"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `List.wrap/1` is the dedicated "give me a list whether or not I
    already have one" constructor; the hand-rolled
    `if is_list(x), do: x, else: [x]` is the same intent spelled out and
    obscures it. NOTE the one divergence: `List.wrap(nil)` is `[]`, while
    the conditional yields `[nil]` for `x == nil` — so the rewrite is
    only behaviour-preserving when `x` can never be `nil`. This refactor
    is default-off for that reason; enable it once nil is ruled out at
    the call sites.
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

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp maybe_patch({:if, _, [cond_ast, branches]} = node) when is_list(branches) do
    with {:ok, var} <- guarded_var(cond_ast),
         do_branch = fetch_branch(branches, :do),
         else_branch = fetch_branch(branches, :else),
         true <- var_ref?(do_branch, var),
         true <- singleton_of_var?(else_branch, var) do
      [Patch.replace(node, "List.wrap(#{var})")]
    else
      _ -> []
    end
  end

  defp maybe_patch(_), do: []

  defp guarded_var({:is_list, _, [arg]}), do: bare_var(arg)
  defp guarded_var(_), do: :skip

  defp fetch_branch(branches, key) do
    branches
    |> Enum.find_value(fn
      {{:__block__, _, [^key]}, value} -> {:found, unwrap_block(value)}
      {^key, value} -> {:found, unwrap_block(value)}
      _ -> nil
    end)
    |> case do
      {:found, value} -> value
      nil -> nil
    end
  end

  defp singleton_of_var?([elem], var), do: var_ref?(elem, var)
  defp singleton_of_var?(_, _), do: false

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
