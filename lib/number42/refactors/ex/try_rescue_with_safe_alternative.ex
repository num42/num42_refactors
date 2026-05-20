defmodule Number42.Refactors.Ex.TryRescueWithSafeAlternative do
  @moduledoc """
  Rewrites `try/rescue` blocks that wrap a raising lookup in order
  to provide a default value, when the same effect is expressible as
  the non-raising counterpart with a default argument.

      try do
        Map.fetch!(m, k)
      rescue
        _ -> :default
      end
      ↓
      Map.get(m, k, :default)

      try do
        Keyword.fetch!(kw, k)
      rescue
        _ -> :default
      end
      ↓
      Keyword.get(kw, k, :default)

  Mirrors the spirit of `ExSlop.Check.Refactor.TryRescueWithSafeAlternative`,
  but narrows the rewrite to the two cases where the safe alternative
  has a `*_with_default/3` arity that absorbs the rescue clause's body
  exactly. The other pairs in the ex_slop check (`String.to_integer`
  → `Integer.parse`, `File.read!` → `File.read`, ...) change the
  return shape (`int` → `{int, ""} | :error`, value → `{:ok, v} | {:error, e}`)
  and would need a `case`-wrap that's noisier than the original code.
  Those are left for human refactoring.

  ## What we accept

  - Body is exactly one expression (or a `__block__` with a single
    expression). Multi-statement bodies are kept as-is — the side
    effects of earlier expressions would have to be preserved on
    both branches, which doesn't survive the rewrite cleanly.
  - The rescue has exactly one clause whose pattern is `_` or a
    `_`-prefixed variable (the binding is unused, so it's safe to
    drop). Specific exception patterns (`MatchError ->`,
    `KeyError ->`) are skipped because they catch a strict subset
    of what `Map.fetch!`/`Keyword.fetch!` raise — the intent might
    be more precise than the safe alternative offers.
  - The rescue clause has no `when` guard.
  - The rescue body is **any** expression, captured verbatim and
    spliced in as the default argument.

  ## Idempotence

  After the rewrite the `try` is gone — a second pass finds nothing
  to match.

  ## Procedural mode

  The match needs to inspect the `try` keyword payload, the body
  shape, and the rescue clause structure simultaneously. ExAST's
  declarative pattern can't express the "wildcard rescue clause"
  side condition, so we walk the AST procedurally.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "try/rescue around Map.fetch!/Keyword.fetch! -> .get(..., default)"

  @impl Number42.Refactors.Refactor
  def priority, do: 120

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Using `try/rescue` around `Map.fetch!`/`Keyword.fetch!` to provide a
    fallback uses exceptions for routine control flow — expensive at
    runtime (the BEAM materialises a stack trace for the raise) and
    misleading for the reader, who sees an exception block and assumes
    something genuinely exceptional is being handled. `Map.get(..., default)`
    expresses "look up; if missing, use this default" as ordinary
    data flow without any of that.
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

  defp ensure_no_other_branches(keyword) do
    keys =
      keyword
      |> Enum.map(fn
        {{:__block__, _, [k]}, _} -> k
        {k, _} when is_atom(k) -> k
        _ -> :unknown
      end)

    if keys |> Enum.all?(&(&1 in [:do, :rescue])), do: :ok, else: :skip
  end

  defp fetch_keyword(keyword, key) do
    keyword
    |> Enum.find_value(:error, fn
      {{:__block__, _, [^key]}, value} -> {:ok, value}
      {^key, value} -> {:ok, value}
      _ -> nil
    end)
    |> case do
      :error -> :error
      ok -> ok
    end
  end

  defp maybe_patch({:try, _meta, [kw]} = node) when is_list(kw) do
    with {:ok, body} <- fetch_keyword(kw, :do),
         {:ok, rescue_clauses} <- fetch_keyword(kw, :rescue),
         :ok <- ensure_no_other_branches(kw),
         {:ok, call_ast} <- single_expression(body),
         {:ok, mod, fun, [coll, key]} <- raising_lookup(call_ast),
         {:ok, default_ast} <- single_wildcard_rescue(rescue_clauses) do
      replacement = render_get(mod, fun, coll, key, default_ast)
      [Patch.replace(node, replacement)]
    else
      _ -> []
    end
  end

  defp maybe_patch(_), do: []

  defp raising_lookup({{:., _, [{:__aliases__, _, [mod]}, fun]}, _, args})
       when is_list(args) and length(args) == 2 do
    case {mod, fun} do
      {:Map, :fetch!} -> {:ok, :Map, :fetch!, args}
      {:Keyword, :fetch!} -> {:ok, :Keyword, :fetch!, args}
      _ -> :skip
    end
  end

  defp raising_lookup(_), do: :skip

  defp render_call(mod_atom, fun, args),
    do: {{:., [], [{:__aliases__, [], [mod_atom]}, fun]}, [], args} |> Sourceror.to_string()

  defp render_get(:Map, :fetch!, coll, key, default),
    do: :Map |> render_call(:get, [coll, key, default])

  defp render_get(:Keyword, :fetch!, coll, key, default),
    do: :Keyword |> render_call(:get, [coll, key, default])

  defp single_expression({:__block__, _, [single]}), do: {:ok, single}
  defp single_expression({:__block__, _, _}), do: :skip
  defp single_expression(other), do: {:ok, other}

  defp single_wildcard_rescue([{:->, _, [[pattern], body]}]) do
    if wildcard_pattern?(pattern), do: {:ok, body}, else: :skip
  end

  defp single_wildcard_rescue(_), do: :skip

  defp wildcard_pattern?({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    name
    |> Atom.to_string()
    |> String.starts_with?("_")
  end

  defp wildcard_pattern?(_), do: false

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
