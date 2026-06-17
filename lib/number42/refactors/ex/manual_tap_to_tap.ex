defmodule Number42.Refactors.Ex.ManualTapToTap do
  @moduledoc """
  Rewrites a hand-rolled "run a side effect, then return the original
  value" lambda in a pipe into `Kernel.tap/2`:

      value |> then(fn x -> log(x); x end)        →  value |> tap(fn x -> log(x) end)
      value |> (fn x -> log(x); x end).()         →  value |> tap(fn x -> log(x) end)

  `tap/2` exists precisely for "do something with the value, then keep
  piping the original value forward". The hand-rolled form — a lambda
  whose body is `stmt; x`, applied to the piped value either via `then/2`
  or by immediate self-application `(fn … end).()` — buries that intent
  and is easy to get subtly wrong (accidentally returning the side
  effect's result). `tap` makes the discard explicit.

  ## Matched shapes — exact by design

  Two trigger shapes, both in pipe position:

  1. `expr |> (fn x -> body; x end).()` — immediately-applied lambda.
  2. `expr |> then(fn x -> body; x end)` — `then/2` returning its input.

  The lambda must be **single-clause, single-param**, the param a bare
  variable (no destructuring, no `_`, unguarded). The body must be a
  block whose **last expression is exactly the bound parameter**,
  unchanged, with **at least one preceding statement**. The emitted
  `tap` body drops the trailing `; x` (tap ignores the return).

  ## Why these guards matter — skip rather than guess

  - **Last expression must be the bare param.** `fn x -> f(x) end`
    returns a derived value, not the original — that is a `then`, not a
    `tap`. Rewriting it would change what flows down the pipe.
  - **At least one side effect.** `fn x -> x end` is identity, not a
    tap; removing it is a different concern (out of scope).
  - **No parameter shadowing.** If the param is rebound inside the body
    before the final `x` (`fn x -> x = f(); x end`), the returned `x` is
    no longer the original piped value — `tap` would forward the
    original and silently change the program. We detect any binding of
    the param name in a preceding statement and skip.
  - **Single bare param.** Multi-clause / multi-arg `fn`, or a
    destructuring/`_` param, do not have a single "the original value"
    to forward — skip.

  ## Idempotence

  A `tap(…)` node is neither a `then/2` call nor an immediately-applied
  lambda, so a second pass matches nothing.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description,
    do:
      "value |> then(fn x -> eff; x end) / |> (fn x -> eff; x end).() -> value |> tap(fn x -> eff end)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A pipe whose lambda runs a side effect and then returns its own
    untouched input re-implements `Kernel.tap/2` by hand — either via
    `then(fn x -> eff; x end)` or by self-applying the lambda with
    `(fn x -> eff; x end).()`. `tap` names that "peek without changing
    the value" intent directly and makes the discard of the side
    effect's result explicit, removing a place to accidentally forward
    the wrong value down the pipe.
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

  defp build_patches(ast, source),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch(&1, source))

  # value |> then(fn x -> body; x end)
  defp maybe_patch({:|>, _, [value, {:then, _, [lambda]}]} = node, source),
    do: rewrite(node, value, lambda, source)

  # value |> (fn x -> body; x end).()
  defp maybe_patch({:|>, _, [value, {{:., _, [lambda]}, _, []}]} = node, source),
    do: rewrite(node, value, lambda, source)

  defp maybe_patch(_, _), do: []

  defp rewrite(node, value, lambda, source) do
    with {:ok, param, side_effects} <- tap_lambda(lambda),
         {:ok, value_text} <- slice_node(source, value),
         {:ok, body_text} <- side_effect_text(side_effects, source) do
      [Patch.replace(node, "#{value_text} |> tap(fn #{param} -> #{body_text} end)")]
    else
      _ -> []
    end
  end

  # Single-clause, single-bare-param, unguarded lambda whose body is a
  # block ending in the bare param, with >= 1 preceding side effect that
  # never rebinds the param.
  defp tap_lambda({:fn, _, [{:->, _, [[param], body]}]}) do
    with {:ok, name} <- bare_param(param),
         {:ok, side_effects} <- returns_original(body, name) do
      {:ok, name, side_effects}
    end
  end

  defp tap_lambda(_), do: :skip

  defp bare_param({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    if String.starts_with?(Atom.to_string(name), "_"), do: :skip, else: {:ok, name}
  end

  defp bare_param(_), do: :skip

  # Body must be a block: [side_effect, ..., final]. final must be the
  # bare param, and no preceding statement may rebind the param.
  defp returns_original({:__block__, _, stmts}, name) when length(stmts) >= 2 do
    {side_effects, [final]} = Enum.split(stmts, -1)

    with true <- var_ref?(final, name),
         false <- Enum.any?(side_effects, &binds_var?(&1, name)) do
      {:ok, side_effects}
    else
      _ -> :skip
    end
  end

  defp returns_original(_, _), do: :skip

  # Any `=` whose left pattern binds `name` rebinds the param — the
  # returned `x` is then no longer the original piped value.
  defp binds_var?(stmt, name) do
    stmt
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:=, _, [pattern, _rhs]} -> MapSet.member?(used_var_names(pattern), name)
      _ -> false
    end)
  end

  defp side_effect_text(side_effects, source) do
    side_effects
    |> Enum.reduce_while({:ok, []}, fn stmt, {:ok, acc} ->
      case slice_node(source, stmt) do
        {:ok, text} -> {:cont, {:ok, [text | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, texts} -> {:ok, texts |> Enum.reverse() |> Enum.join("\n")}
      :error -> :error
    end
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
