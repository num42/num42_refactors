defmodule Number42.Refactors.Ex.FlatMapToFilter do
  @moduledoc """
  Rewrites `Enum.flat_map/2` calls that wrap pure filter logic in
  singleton-or-empty lists into plain `Enum.filter/2`:

      Enum.flat_map(items, fn item -> if item.active, do: [item], else: [] end)
      ↓
      Enum.filter(items, fn item -> item.active end)

      items |> Enum.flat_map(fn item -> if cond, do: [], else: [item] end)
      ↓
      items |> Enum.filter(fn item -> not cond end)

  Mirrors `ExSlop.Check.Refactor.FlatMapFilter`.

  ## Why we're stricter than ExSlop

  ExSlop's check accepts any singleton AST (`[_]`) as the kept element.
  We require the singleton to be **exactly the lambda argument** (a
  bare-variable pattern). Reason: `Enum.flat_map(items, fn item -> if
  c, do: [spec], else: [] end)` returns `spec`s (a derived value),
  while `Enum.filter(items, fn item -> c end)` returns the original
  `item`s — different programs. Auto-rewriting that shape would silently
  change the result.

  Code that fits the looser shape is `filter + map` and needs a
  two-step rewrite (`|> Enum.filter |> Enum.map`); we don't attempt
  it here — leave it to a human.

  ## What we match

  - Host: `Enum.flat_map/2`, direct or piped.
  - Lambda: one clause, one bare-var arg `x`, single-statement body
    of shape `if cond, do: [x], else: []` (kept-when-true) or
    `if cond, do: [], else: [x]` (kept-when-false → emits `not cond`).
  - The keep-list singleton must be exactly the bare arg `x` (not a
    derived expression, not a destructure).

  Inline keyword form (`if c, do: [...], else: [...]`) and block
  form (`if c do [...] else [...] end`) are both accepted; Sourceror
  preserves them differently in metadata, but the AST shapes coincide
  after normalization.

  ## Idempotence

  After a rewrite the call site is `Enum.filter`, which has no
  matching `flat_map` head — a second pass is a no-op.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Enum.flat_map(coll, fn x -> if c, do: [x], else: [] end) -> Enum.filter"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Wrapping each kept element in `[x]` and dropping rejects as `[]` is
    `Enum.filter/2` written through `flat_map`'s "many-or-none"
    interface — costs an allocation per element and obscures the
    intent. `Enum.filter` is the operation the reader is actually
    looking for: keep the elements where the predicate is true. Naming
    the operation directly removes a translation step on every read.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 150
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp analyze_body({:if, _, [cond_ast, branches]}, var) when is_list(branches) do
    do_branch = fetch_branch(branches, :do)
    else_branch = fetch_branch(branches, :else)

    cond do
      singleton_of_var?(do_branch, var) and empty_list?(else_branch) ->
        {:ok, cond_ast, :keep_on_true}

      empty_list?(do_branch) and singleton_of_var?(else_branch, var) ->
        {:ok, cond_ast, :keep_on_false}

      true ->
        :skip
    end
  end

  defp analyze_body(_, _), do: :skip
  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp classify({:fn, _, [{:->, _, [[arg], body]}]}) do
    with {:ok, var} <- bare_var(arg),
         {:ok, cond_ast, polarity} <- analyze_body(body, var) do
      cond_text = render_condition(cond_ast, polarity)
      {:ok, Atom.to_string(var), cond_text}
    else
      _ -> :skip
    end
  end

  defp classify(_), do: :skip

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

  defp filter_patch_or_skip({:ok, var, cond_text}, node),
    do: [Patch.replace(node, "Enum.filter(fn #{var} -> #{cond_text} end)")]

  defp filter_patch_or_skip(:skip, _node), do: []

  defp filter_patch_or_skip({:ok, var, cond_text}, coll, node) do
    coll_text = Sourceror.to_string(coll)
    [Patch.replace(node, "Enum.filter(#{coll_text}, fn #{var} -> #{cond_text} end)")]
  end

  defp filter_patch_or_skip(:skip, _coll, _node), do: []

  defp maybe_patch({{:., _, [{:__aliases__, _, [:Enum]}, :flat_map]}, _, [coll, fun]} = node),
    do: classify(fun) |> filter_patch_or_skip(coll, node)

  defp maybe_patch({{:., _, [{:__aliases__, _, [:Enum]}, :flat_map]}, _, [fun]} = node),
    do: classify(fun) |> filter_patch_or_skip(node)

  defp maybe_patch(_), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
  defp render_condition(cond_ast, :keep_on_true), do: Sourceror.to_string(cond_ast)

  defp render_condition(cond_ast, :keep_on_false),
    # `(not a) and b`, but if `cond_ast` is something like `a and b`
    # we'd want `not (a and b)`. `Code.format_string!` (triggered via
    # `reformat_after?`) strips redundant parens around plain calls
    # but keeps them where precedence demands.
    do: "not (" <> Sourceror.to_string(cond_ast) <> ")"

  defp singleton_of_var?([elem], var), do: var_ref?(elem, var)
  defp singleton_of_var?(_, _), do: false
end
