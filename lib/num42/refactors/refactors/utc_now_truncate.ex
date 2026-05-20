defmodule Num42.Refactors.Refactors.UtcNowTruncate do
  @moduledoc """
  Collapses the two-step `utc_now() + truncate(precision)` idiom into
  the single-call form that takes a precision argument directly:

      DateTime.utc_now() |> DateTime.truncate(:second)
      ↓
      DateTime.utc_now(:second)

      DateTime.truncate(DateTime.utc_now(), :second)
      ↓
      DateTime.utc_now(:second)

  Same for `NaiveDateTime`.

  ## Why this is real, not just style

  `DateTime.utc_now/1` (and `NaiveDateTime.utc_now/1`) constructs the
  timestamp at the requested precision in one shot. The
  `utc_now() |> truncate(precision)` pipeline allocates a microsecond-
  precision struct and then a second struct with the truncated
  microsecond field. The single-call form skips the intermediate.

  Mirrors Quokka's `Style.Pipes` rewrite of the same pattern.

  ## What we match

  - `DateTime.utc_now() |> DateTime.truncate(precision)`
  - `DateTime.truncate(DateTime.utc_now(), precision)`
  - The same shapes for `NaiveDateTime`.
  - Module of `utc_now` MUST equal module of `truncate` — mixing
    `DateTime.utc_now() |> NaiveDateTime.truncate(...)` is a different
    operation (drops the timezone) and we leave it alone.
  - `utc_now` must be the zero-arity form. The 1-arity form
    (`utc_now(timezone)`) doesn't have an inverse single-call shape
    that takes a precision, so we skip it.

  ## Idempotence

  After the rewrite the AST is `Mod.utc_now(precision)` — no inner
  `truncate` call to match. Second pass is a no-op.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Num42.Refactors.Refactor
  def description, do: "DateTime.utc_now() |> DateTime.truncate(p) -> DateTime.utc_now(p)"

  @impl Num42.Refactors.Refactor
  def priority, do: 130

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    `DateTime.utc_now/1` and `NaiveDateTime.utc_now/1` build a timestamp
    at the requested precision in one shot. The `utc_now() |> truncate(p)`
    pipeline first allocates a microsecond-precision struct, then a
    second struct with the truncated field — the single-call form skips
    the intermediate. The replacement also reads more directly: "give
    me 'now' at second precision".
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  @date_modules [:DateTime, :NaiveDateTime]

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  # Pipe form: DateTime.utc_now() |> DateTime.truncate(precision)
  defp maybe_patch(
         {:|>, _,
          [
            {{:., _, [{:__aliases__, _, [mod1]}, :utc_now]}, _, []},
            {{:., dm, [{:__aliases__, am, [mod2]}, :truncate]}, cm, [precision]}
          ]} = node
       )
       when mod1 in @date_modules and mod1 == mod2 do
    replacement = build_utc_now(am, mod1, dm, cm, precision)
    [Patch.replace(node, render_clean(replacement))]
  end

  # Nested form: DateTime.truncate(DateTime.utc_now(), precision)
  defp maybe_patch(
         {{:., dm, [{:__aliases__, am, [mod2]}, :truncate]}, cm,
          [
            {{:., _, [{:__aliases__, _, [mod1]}, :utc_now]}, _, []},
            precision
          ]} = node
       )
       when mod1 in @date_modules and mod1 == mod2 do
    replacement = build_utc_now(am, mod1, dm, cm, precision)
    [Patch.replace(node, render_clean(replacement))]
  end

  defp maybe_patch(_), do: []

  defp build_utc_now(am, mod, dm, cm, precision),
    do: {{:., dm, [{:__aliases__, am, [mod]}, :utc_now]}, cm, [precision]}

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
