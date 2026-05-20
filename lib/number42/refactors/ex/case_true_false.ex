defmodule Number42.Refactors.Ex.CaseTrueFalse do
  @moduledoc """
  Rewrites two-clause `case` expressions whose patterns are exclusively
  `true` and `false` (in either order, or one of them as `_`) into an
  `if`/`else`. Mirrors `ExSlop.Check.Refactor.CaseTrueFalse`.

      case some_condition() do
        true -> :yes
        false -> :no
      end
      ↓
      if some_condition() do
        :yes
      else
        :no
      end

  ## When this fires

  The `case` must have **exactly two** clauses, with patterns in one of
  these shapes:

  - `true` + `false`
  - `false` + `true` (clause order is irrelevant; the `if`/`else`
    bodies are swapped accordingly)
  - `true` + `_` (catch-all stands in for the false branch)
  - `_` + `true`
  - `false` + `_`
  - `_` + `false`

  Guards on either clause kill the rewrite — `case x do true when y -> ...`
  isn't equivalent to `if`. Multi-statement bodies survive: they end up
  as the body of the `if`/`else` block.

  ## Known limitation

  Sourceror parses `def f(x), do: case x do … end` (a `case` directly
  inside a keyword `do:` of `def`) into an AST shape where the `case`
  appears separately from its clauses. Our pattern matches the
  ordinary case node and won't fire on this form. Wrap the `def` in
  `do … end` or pull the `case` into the function body manually.

  ## Procedural mode

  ExAST patterns can match a fixed clause shape, but covering all six
  permutations above as separate declarative refactors would mean six
  modules with identical bookkeeping. One procedural pass walks the
  AST and emits one `Sourceror.Patch.replace` per qualifying `case`.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Rewrite `case ... do true -> ...; false -> ... end` as `if`/`else`"

  @impl Number42.Refactors.Refactor
  def priority, do: 120

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `case` on a boolean is the wrong shape for the language: `if`/`else`
    is the construct that exists exactly for that decision, with shorter
    syntax and no risk of an accidentally-non-exhaustive match. Using
    `case` here forces the reader to scan the patterns to confirm
    they're booleans before they understand the intent — `if` makes it
    obvious at a glance.
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

  defp classify_clause({:->, _, [[pattern], body]}),
    do: pattern_kind(pattern) |> kind_or_skip(body)

  defp classify_clause(_), do: :skip

  defp classify_clauses([clause_a, clause_b]) do
    with {:ok, kind_a, body_a} <- classify_clause(clause_a),
         {:ok, kind_b, body_b} <- classify_clause(clause_b),
         {:ok, true_body, false_body} <- pair_bodies(kind_a, body_a, kind_b, body_b) do
      {:ok, true_body, false_body}
    else
      _ -> :skip
    end
  end

  defp maybe_patch({:case, _meta, [cond_ast, [{_do_block, clauses}]]} = node)
       when is_list(clauses) and length(clauses) == 2 do
    classify_clauses(clauses) |> if_patch_or_skip(cond_ast, node)
  end

  defp maybe_patch(_), do: []
  defp pair_bodies(:true_lit, t, :false_lit, f), do: {:ok, t, f}
  defp pair_bodies(:false_lit, f, :true_lit, t), do: {:ok, t, f}
  defp pair_bodies(:true_lit, t, :wildcard, f), do: {:ok, t, f}
  defp pair_bodies(:false_lit, f, :wildcard, t), do: {:ok, t, f}
  defp pair_bodies(_, _, _, _), do: :skip
  defp pattern_kind({:__block__, _, [true]}), do: :true_lit
  defp pattern_kind({:__block__, _, [false]}), do: :false_lit
  defp pattern_kind(true), do: :true_lit
  defp pattern_kind(false), do: :false_lit
  defp pattern_kind({:_, _, ctx}) when is_atom(ctx), do: :wildcard
  defp pattern_kind(_), do: nil

  defp render_if(cond_ast, true_body, false_body) do
    if_meta = [do: [line: 1], end: [line: 1]]

    Sourceror.to_string(
      {:if, if_meta,
       [
         cond_ast,
         [
           {{:__block__, [], [:do]}, true_body},
           {{:__block__, [], [:else]}, false_body}
         ]
       ]}
    )
  end

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp kind_or_skip(nil, _body), do: :skip

  defp kind_or_skip(kind, body), do: {:ok, kind, body}

  defp if_patch_or_skip({:ok, true_body, false_body}, cond_ast, node),
    do: [Patch.replace(node, render_if(cond_ast, true_body, false_body))]

  defp if_patch_or_skip(:skip, _cond_ast, _node), do: []

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
