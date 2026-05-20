defmodule Number42.Refactors.Ex.MapGetUnsafePass do
  @moduledoc """
  Drops the redundant `nil` default argument from `Map.get/3` and
  `Keyword.get/3` calls:

      Map.get(x, :k, nil)         →   Map.get(x, :k)
      Keyword.get(x, :k, nil)     →   Keyword.get(x, :k)
      x |> Map.get(:k, nil)       →   x |> Map.get(:k)

  `Map.get/2` and `Keyword.get/2` already default to `nil` for missing
  keys; passing `nil` explicitly is verbose without any change in
  behaviour. Mirrors Quokka's `Style.SingleNode` rewrite of the same
  pattern.

  ## Why "unsafe pass"?

  The Quokka name reflects that this is a `Map.get` call which silently
  conflates "key absent" with "key present, value nil" — both produce
  `nil`. The refactor doesn't change that behaviour; it only removes the
  redundant explicit `nil`. If the original code's intent was actually
  to distinguish, the right move is `Map.fetch/2` or `Map.has_key?/2`,
  not adding a default — that's a separate, human-driven refactor.

  ## What we match

  - `Map.get(x, k, nil)` (arity 3, third arg is the literal `nil`)
  - `Keyword.get(x, k, nil)` (same shape)
  - Pipe form: `x |> Map.get(k, nil)` and `x |> Keyword.get(k, nil)`

  ## What we skip

  - Arity-2 calls (no default to drop)
  - Defaults other than `nil` (`Map.get(x, k, [])` is meaningful)
  - Other modules' `get/3` (custom modules can have any semantics)
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Map.get(x, k, nil) -> Map.get(x, k) (also Keyword.get)"

  @impl Number42.Refactors.Refactor
  def priority, do: 130

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `Map.get/2` and `Keyword.get/2` already return `nil` for missing
    keys — explicitly passing `nil` as the third argument adds noise
    without changing behaviour. The two-arg form is the idiomatic way
    to say "look this up, accept nil if absent".
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  # Direct call: Map.get(x, k, nil)
  defp maybe_patch({{:., dm, [{:__aliases__, am, [mod]}, :get]}, cm, [coll, key, default]} = node)
       when mod in [:Map, :Keyword] do
    if nil_literal?(default) do
      shortened = {{:., dm, [{:__aliases__, am, [mod]}, :get]}, cm, [coll, key]}
      [Patch.replace(node, render_clean(shortened))]
    else
      []
    end
  end

  # Pipe stage: x |> Map.get(k, nil)
  defp maybe_patch(
         {:|>, _,
          [
            _coll,
            {{:., dm, [{:__aliases__, am, [mod]}, :get]}, cm, [key, default]}
          ]} = node
       )
       when mod in [:Map, :Keyword] do
    if nil_literal?(default) do
      # Replace the pipe stage call only, by patching the inner
      # `Mod.get(k, nil)` to `Mod.get(k)`. The outer pipe is left intact.
      stage = {{:., dm, [{:__aliases__, am, [mod]}, :get]}, cm, [key]}
      inner_node = elem(node, 2) |> Enum.at(1)
      [Patch.replace(inner_node, render_clean(stage))]
    else
      []
    end
  end

  defp maybe_patch(_), do: []

  defp nil_literal?({:__block__, _, [nil]}), do: true
  defp nil_literal?(nil), do: true
  defp nil_literal?(_), do: false

  # `Sourceror.to_string/1` re-emits comments stored in node meta
  # (`:leading_comments` / `:trailing_comments`). When we patch a
  # subrange that already includes those comments in the source, the
  # comments would get duplicated. Strip them before rendering.
  defp render_clean(ast), do: ast |> strip_comments() |> Sourceror.to_string()

  defp strip_comments(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        {form, meta |> Keyword.put(:leading_comments, []) |> Keyword.put(:trailing_comments, []),
         args}

      other ->
        other
    end)
  end

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
