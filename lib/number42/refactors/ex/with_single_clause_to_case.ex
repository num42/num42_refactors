defmodule Number42.Refactors.Ex.WithSingleClauseToCase do
  @moduledoc """
  Rewrites a `with` that has exactly one `<-` clause into a plain `case`.

  ## Antipattern (lib/my_app/identity/user_notifier.ex:19)

      with {:ok, _metadata} <- Mailer.deliver(email) do
        {:ok, email}
      end

  ## Replacement

      case Mailer.deliver(email) do
        {:ok, _metadata} -> {:ok, email}
        other -> other
      end

  The `other -> other` arm preserves `with`'s passthrough semantics: a
  bare `with X <- expr do body end` returns the un-matched value when
  the match fails, so a naked `case` (only the success arm) would
  change behavior to `CaseClauseError`.

  ## Why

  A single-clause `with` is a `case` written with extra ceremony. `with`
  earns its keep when chaining ≥ 2 fallible operations: the `<-` arrows
  give the reader an explicit happy-path-only/fail-fast story for
  multiple steps. With exactly one step, `case` says the same thing in
  fewer words and matches the codebase's pattern-matching idiom for
  single-step branching.

  ## Edge cases to handle in implementation

  - **`else` branches**: translate each `else` clause into an additional
    `case` arm. Without an `else`, append a synthetic `other -> other`
    passthrough arm to preserve `with`-semantics.
  - **Side-effect body**: preserve the body verbatim (multiple
    statements stay multiple statements inside the success arm).
  - **Guards on the `<-`**: rare but legal (`with {:ok, x} when x > 0 <- ...`)
    — port the guard onto the `case` arm.
  - **`when` in the matched value**: not the same as a guard on the
    clause; leave alone if shape doesn't fit cleanly.
  - **Bare `=` clauses inside `with`**: those are not fallible matches;
    a `with` with one `<-` plus N `=` clauses is fine to rewrite —
    the `=` clauses move into the `case` arm body, before the original
    body.

  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Rewrite single-clause `with` into `case`"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A `with` with exactly one `<-` arrow is just a `case` with extra
    syntax: same control flow, more keywords. Switching to `case` makes
    the intent — "match this single value, branch on the shape" —
    immediately legible. `with` should signal "I'm chaining at least
    two fallible operations"; using it for one cheapens that signal.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 120
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)
  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
  defp apply_patches({:error, _}, source), do: source
  defp arrow?({:<-, _, _}), do: true
  defp arrow?(_), do: false

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp classify(clauses) do
    {kw, head_clauses} = split_keyword(clauses)

    arrows = head_clauses |> Enum.filter(&arrow?/1)

    with true <- length(arrows) == 1,
         true <- length(head_clauses) == 1,
         {:ok, body} <- fetch_keyword(kw, :do),
         {:ok, else_clauses} <- fetch_else(kw),
         {:<-, _, [pattern, rhs]} <- hd(arrows) do
      {:ok, pattern, rhs, body, else_clauses}
    else
      _ -> :skip
    end
  end

  defp collision?(rhs, body, else_clauses),
    do: refs_other?(rhs) or refs_other?(body) or Enum.any?(else_clauses, &refs_other?/1)

  defp else_clauses_or_default({:ok, clauses}) when is_list(clauses) do
    {:ok, clauses}
  end

  defp else_clauses_or_default(:error), do: {:ok, []}
  defp else_clauses_or_default(_), do: :error
  defp fetch_else(keyword), do: fetch_keyword(keyword, :else) |> else_clauses_or_default()

  defp fetch_keyword(keyword, key) do
    keyword
    |> Enum.find_value(:error, fn
      {{:__block__, _, [^key]}, value} -> {:ok, value}
      {^key, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp maybe_patch({:with, _meta, clauses} = node) when is_list(clauses) do
    classify(clauses) |> patch_or_skip(node)
  end

  defp maybe_patch(_), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  defp patch_or_skip({:ok, pattern, rhs, body, else_clauses}, node) do
    if collision?(rhs, body, else_clauses) do
      []
    else
      [Patch.replace(node, render_case(rhs, pattern, body, else_clauses))]
    end
  end

  defp patch_or_skip(:skip, _node), do: []

  defp refs_other?(ast) do
    {_, hit} =
      Macro.prewalk(ast, false, fn
        {:other, _, ctx} = node, _ when is_atom(ctx) -> {node, true}
        node, acc -> {node, acc}
      end)

    hit
  end

  defp render_case(scrutinee, pattern, body, else_clauses) do
    success_arm = {:->, [], [[pattern], body]}

    arms =
      if else_clauses == [] do
        other = {:other, [], nil}
        passthrough_arm = {:->, [], [[other], other]}
        [success_arm, passthrough_arm]
      else
        [success_arm | else_clauses]
      end

    case_meta = [do: [line: 1], end: [line: 1]]
    case_ast = {:case, case_meta, [scrutinee, [{{:__block__, [], [:do]}, arms}]]}

    Sourceror.to_string(case_ast)
  end

  defp split_keyword(clauses), do: List.last(clauses) |> split_off_keyword(clauses)

  defp split_off_keyword(kw, clauses) when is_list(kw) do
    {kw, clauses |> Enum.drop(-1)}
  end

  defp split_off_keyword(_, clauses), do: {[], clauses}
end
