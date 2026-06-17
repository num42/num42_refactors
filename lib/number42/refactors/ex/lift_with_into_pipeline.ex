defmodule Number42.Refactors.Ex.LiftWithIntoPipeline do
  @moduledoc """
  Rewrites a single-clause `with` whose body is a single happy-path
  transformation into a pipe.

  ## Antipattern (lib/my_app/reference_buildings/csv_import.ex:204-206)

      with {:ok, consolidated} <- consolidate_rows(rows) do
        {:ok, preview_consolidated_rows(consolidated, building_id)}
      end

  ## Replacement

      rows
      |> consolidate_rows()
      |> case do
        {:ok, consolidated} ->
          {:ok, preview_consolidated_rows(consolidated, building_id)}
      end

  Or, when the failure-tag passthrough is acceptable to the surrounding
  context (e.g. the caller already handles `{:error, _}` shapes):

      rows
      |> consolidate_rows()
      |> Result.map(fn consolidated ->
        preview_consolidated_rows(consolidated, building_id)
      end)

  (The exact shape of the lifted form depends on what helper functions
  the project provides — `Result.map/2`, custom map-on-`{:ok, _}`, etc.
  The implementation will need to pick one based on what's in scope.)

  ## Why

  A `with` with one `<-` clause is bookkeeping for the happy path:
  destructure the success tuple, run a body that re-tags. When the
  body is *itself* a single transformation, the `with` ceremony
  contributes nothing — the same logic reads as a pipe with explicit
  data flow.

  ## When this fires vs. WithSingleClauseToCase

  `WithSingleClauseToCase` always rewrites single-clause `with` to
  `case`. This refactor is more specific: it requires the success
  body to be a single, transformation-like expression (a function
  call, a tuple construction wrapping a function call) so the result
  reads naturally as a pipe step. When the body is multi-statement,
  has side effects, or doesn't naturally chain, fall through to
  `WithSingleClauseToCase` (case is more honest about the branching).

  Engine ordering: this refactor runs *before* `WithSingleClauseToCase`
  alphabetically (`Lift…` < `With…`), so on a matching site it claims
  the rewrite first. Non-matching sites fall through to the case form.

  ## Edge cases to handle in implementation

  - **Multi-statement body**: skip — pipes can't host bare statements.
  - **Body doesn't reference the bound variable**: skip — there's no
    pipeable data flow to lift; the `with` is a guard, not a transform.
  - **Body's outermost call is the bound variable's consumer**: this
    is the canonical case. `{:ok, x} <- foo() ; bar(x)` →
    `foo() |> case match -> bar(x)`.
  - **Body wraps in `{:ok, _}` again**: re-emitting a success tag is
    common; lifting needs to know whether to use `Result.map` (assumes
    `{:ok, _}` semantics) or a `case` pipe step (no assumption).
  - **No `Result.map`-equivalent in scope**: fall back to `|> case do
    ... end` which is always available. The implementation should
    detect available helpers and choose; for now, no-op.

  ## Status

  Stub — `transform/2` is a no-op until the implementation lands.
  Of all five with-clause refactors, this one is most opinion-laden:
  it depends on what "pipe-shaped" means in this codebase. Implement
  last, after the easier four have surfaced the conventions.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Lift single-clause `with` with a transformation body into a pipe"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A `with` block that destructures one success tuple and runs a single
    transformation on the bound value is a pipe written in long form.
    Lifting it makes the data flow visible — what comes in, what each
    step does, what comes out — and removes the `with` ceremony for a
    case where it earns nothing. The result reads top-to-bottom in the
    direction the data actually moves.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 150
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)
  @impl Number42.Refactors.Refactor
  def patches(ast, _source, _opts), do: build_patches(ast)

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
  defp apply_patches({:error, _}, source), do: source

  defp body_uses_pattern_var?(pattern, body) do
    pattern_vars = pattern_var_names(pattern) |> MapSet.new()
    used = used_var_names(body)
    not MapSet.disjoint?(pattern_vars, used)
  end

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp fetch_keyword(keyword, key) do
    keyword
    |> Enum.find_value(:error, fn
      {{:__block__, _, [^key]}, value} -> {:ok, value}
      {^key, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp maybe_patch({:with, _meta, clauses} = node) when is_list(clauses) do
    {kw, head_clauses} = split_keyword(clauses)

    with [{:<-, _, [pattern, rhs]}] <- head_clauses,
         :error <- fetch_keyword(kw, :else),
         {:ok, body} <- fetch_keyword(kw, :do),
         true <- single_expr?(body),
         true <- body_uses_pattern_var?(pattern, body),
         {:ok, head, rest} <- split_call(rhs) do
      [Patch.replace(node, render_pipe_via_case(head, rest, pattern, body))]
    else
      _ -> []
    end
  end

  defp maybe_patch(_), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  defp render_pipe_via_case(head, call_with_rest_args, pattern, body) do
    success_arm = {:->, [], [[pattern], body]}
    other = {:other, [], nil}
    passthrough_arm = {:->, [], [[other], other]}
    case_arms = [success_arm, passthrough_arm]
    case_meta = [do: [line: 1], end: [line: 1]]
    case_node = {:case, case_meta, [[{{:__block__, [], [:do]}, case_arms}]]}

    pipe_ast =
      {:|>, [],
       [
         {:|>, [], [head, call_with_rest_args]},
         case_node
       ]}

    Sourceror.to_string(pipe_ast)
  end

  defp single_expr?({:__block__, _, exprs}) when length(exprs) > 1, do: false
  defp single_expr?(_), do: true
  defp split_call({name, _, _}) when is_atom(name) and pipe_unsafe_op?(name), do: :error

  defp split_call({name, _, args}) when is_atom(name) and is_list(args) and args != [] do
    [head | rest] = args
    {:ok, head, {name, [], rest}}
  end

  defp split_call({{:., _, _} = remote, _, args}) when is_list(args) and args != [] do
    [head | rest] = args
    {:ok, head, {remote, [], rest}}
  end

  defp split_call(_), do: :error
  defp split_keyword(clauses), do: List.last(clauses) |> split_keyword_last(clauses)

  defp split_keyword_last(kw, clauses) when is_list(kw) do
    {kw, clauses |> Enum.drop(-1)}
  end

  defp split_keyword_last(_, clauses), do: {[], clauses}
end
