defmodule Number42.Refactors.Ex.ReduceMapPut do
  @moduledoc """
  Rewrites `Enum.reduce/3` calls that just build a map via `Map.put/3`
  into `Map.new/2`.

      # bad — verbose reduce to build a map
      Enum.reduce(batch, %{}, fn event, acc ->
        Map.put(acc, event.id, event)
      end)
      ↓
      Map.new(batch, fn event -> {event.id, event} end)

      # piped form too
      batch |> Enum.reduce(%{}, fn event, acc -> Map.put(acc, event.id, event) end)
      ↓
      batch |> Map.new(fn event -> {event.id, event} end)

  Mirrors `ExSlop.Check.Refactor.ReduceMapPut`.

  ## Why always safe

  `Map.put/3` and `Map.new/2` resolve duplicate keys identically:
  the last `{k, v}` pair wins. So an input collection containing the
  same key twice produces the same result either way. No
  `Enum.reverse`-style caveat applies.

  ## What we match

  - Direct call: `Enum.reduce(coll, %{}, fn arg, acc -> body end)`.
  - Pipe stage: `coll |> Enum.reduce(%{}, fn arg, acc -> body end)`.
  - Lambda: exactly one clause, two patterns `arg, acc`. The acc must
    be a bare variable; arg can be anything (destructure, pin, ...).
  - Lambda body must be exactly `Map.put(acc, key_expr, value_expr)`,
    where `acc` is the lambda's acc var. The key/value expressions
    must reference at least one name from the arg pattern — otherwise
    the rewrite would produce a single-key map that doesn't depend on
    the input element, which is almost certainly a logic bug worth
    leaving for a human.

  ## Initial accumulator must be `%{}`

  `Enum.reduce(coll, existing_map, fn ... Map.put(acc, k, v) end)` is
  *not* equivalent to `Map.new` — it would lose the entries already in
  `existing_map`. We require the literal empty-map AST.

  ## Defers to `EnumIntoToMapNew`

  If the lambda body is `Map.put(acc, k, v)` with `{k, v}` already
  computed elsewhere as a tuple, the user might already have used
  `Enum.into(coll, %{})`. That case is handled by `EnumIntoToMapNew`
  and doesn't reach us.

  ## Idempotence

  After a rewrite, the call site is `Map.new(...)`. It doesn't match
  our `Enum.reduce/3` head, so a second pass is a no-op.

  ## Why procedural

  ExAST's pattern language can't express "lambda body is
  `Map.put(acc, k, v)` AND `acc` matches the lambda's second pattern"
  without a custom guard.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Enum.reduce/3 building a map via Map.put -> Map.new/2"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `Enum.reduce(coll, %{}, fn x, acc -> Map.put(acc, k(x), v(x)) end)`
    is `Map.new/2` written in pieces — the seed, the accumulator
    parameter, and the explicit `Map.put` are all bookkeeping the
    constructor handles internally. Switching to `Map.new(coll, fn x ->
    {k(x), v(x)} end)` shrinks the line to the actual transformation
    (the `{key, value}` projection) and removes a category of bugs
    where a wrong seed silently merges into pre-existing data.
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

  defp classify({:fn, _, [{:->, _, [[arg_pat, acc_pat], body]}]}) do
    with {:ok, acc_name} <- bare_var(acc_pat),
         {:ok, key, value} <- map_put_call(body, acc_name),
         true <- pattern_introduces_referenced_name?(arg_pat, key, value),
         false <- references_var?(key, acc_name),
         false <- references_var?(value, acc_name) do
      {:ok, arg_pat, key, value}
    else
      _ -> :skip
    end
  end

  defp classify(_), do: :skip
  defp empty_map?({:%{}, _, []}), do: true
  defp empty_map?(_), do: false

  defp lambda_text(arg_pat, key, value) do
    arg_text = Sourceror.to_string(arg_pat)
    key_text = Sourceror.to_string(key)
    value_text = Sourceror.to_string(value)
    "fn #{arg_text} -> {#{key_text}, #{value_text}} end"
  end

  defp map_put_call(
         {{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [{name, _, ctx}, key, value]},
         acc_name
       )
       when is_atom(name) and is_atom(ctx) and name == acc_name,
       do: {:ok, key, value}

  defp map_put_call({:__block__, _, [single]}, acc_name),
    do: map_put_call(single, acc_name)

  defp map_put_call(_, _), do: :skip

  defp maybe_patch({{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [coll, empty, fun]} = node) do
    with true <- empty_map?(empty),
         {:ok, arg_pat, key, value} <- classify(fun) do
      coll_text = Sourceror.to_string(coll)
      [Patch.replace(node, render_direct(coll_text, arg_pat, key, value))]
    else
      _ -> []
    end
  end

  defp maybe_patch({{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [empty, fun]} = node) do
    with true <- empty_map?(empty),
         {:ok, arg_pat, key, value} <- classify(fun) do
      [Patch.replace(node, render_pipe(arg_pat, key, value))]
    else
      _ -> []
    end
  end

  defp maybe_patch(_), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  defp pattern_introduces_referenced_name?(pat, key, value) do
    names = pattern_var_names(pat)
    names |> Enum.any?(&(references_var?(key, &1) or references_var?(value, &1)))
  end

  defp references_var?(ast, target) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> name == target
      _ -> false
    end)
  end

  defp render_direct(coll_text, arg_pat, key, value),
    do: "Map.new(#{coll_text}, #{lambda_text(arg_pat, key, value)})"

  defp render_pipe(arg_pat, key, value), do: "Map.new(#{lambda_text(arg_pat, key, value)})"
end
