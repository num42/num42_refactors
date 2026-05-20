defmodule Num42.Refactors.Refactors.CollapseNestedCaseToWith do
  @moduledoc """
  Rewrites nested `case` expressions that pattern-match `{:ok, _}` /
  `{:error, _}` into a single `with` chain.

  ## Antipattern (paraphrased from lib/my_app/configurator.ex)

      case validate_massformula_on_changeset(changeset, organization_id) do
        {:ok, changeset} ->
          case check_mass_cycle_on_changeset(changeset, organization_id, nil) do
            :ok ->
              case Repo.insert(changeset) do
                {:ok, mass} ->
                  EmbeddingHook.generate_and_store_async(mass)
                  {:ok, mass}

                {:error, e} ->
                  {:error, e}
              end

            {:error, e} ->
              {:error, e}
          end

        {:error, e} ->
          {:error, e}
      end

  ## Replacement

      with {:ok, changeset} <- validate_massformula_on_changeset(changeset, organization_id),
           :ok <- check_mass_cycle_on_changeset(changeset, organization_id, nil),
           {:ok, mass} <- Repo.insert(changeset) do
        EmbeddingHook.generate_and_store_async(mass)
        {:ok, mass}
      end

  ## Why

  A pyramid of `case` matchers where each error arm just propagates the
  error is the "happy-path with fall-through error" pattern that `with`
  was built for. The `with` form makes the chain linear and the
  short-circuit rule explicit; the nested form forces the reader to
  count braces and match `case` arms by eye.

  ## Edge cases to handle in implementation

  - **All error arms must propagate**: if any error arm does work other
    than returning the error tag (logs, side effects, transforms),
    leave alone. The `with`-without-`else` form would silently swallow
    that work.
  - **Mixed tag shapes**: `{:ok, _}` / `:ok` / `{:halt, _}` are all
    happy paths, but mixing them in one chain may need an explicit
    `else` block to disambiguate. Conservative: only rewrite when every
    happy-path tag is structurally compatible.
  - **Bindings in success arms**: each `case`'s success-arm pattern
    becomes a `<-` clause head; subsequent arms reference the
    introduced binding (`changeset` from the first match flows into the
    second `case`'s scrutinee).
  - **Side effects between success arms**: if a success arm runs code
    *before* the next nested `case` (logging, telemetry), pull that
    code into a `=` clause inside the `with` chain.
  - **Innermost arm body multi-statement**: keep the entire block as
    the `with` body.

  ## Status

  Stub — `transform/2` is a no-op until the implementation lands.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Num42.Refactors.Refactor
  def description, do: "Collapse nested {:ok,_}/{:error,_} cases into a `with` chain"

  @impl Num42.Refactors.Refactor
  def priority, do: 120

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    Nested `case` expressions where each error arm just re-emits the
    error are the "fail fast through a chain" pattern that `with`
    expresses directly. Collapsing them flattens N levels of indentation
    into a flat clause sequence and makes the success path the obvious
    one — the failure handling becomes invisible structure rather than
    visible noise. The reader stops counting `end`s.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp maybe_patch({:case, _, _} = node), do: unwrap_pyramid(node, []) |> with_patch_or_skip(node)

  defp maybe_patch(_), do: []

  defp unwrap_pyramid({:case, _, [scrutinee, [{_do_key, [success_arm, error_arm]}]]}, acc) do
    with {:ok, success_pattern, success_body} <- classify_success(success_arm),
         true <- error_passthrough?(error_arm) do
      acc = [{success_pattern, scrutinee} | acc]

      case success_body do
        {:case, _, _} = inner_case ->
          unwrap_pyramid(inner_case, acc)

        body ->
          {:ok, acc, body}
      end
    else
      _ -> :skip
    end
  end

  defp unwrap_pyramid(_, _), do: :skip

  defp classify_success({:->, _, [[pattern], body]}) do
    if happy_path?(pattern) do
      {:ok, pattern, body}
    else
      :skip
    end
  end

  defp classify_success(_), do: :skip

  defp happy_path?({:__block__, _, [{{:__block__, _, [:ok]}, _val}]}), do: true
  defp happy_path?({:__block__, _, [:ok]}), do: true
  defp happy_path?(:ok), do: true
  defp happy_path?(_), do: false

  defp error_passthrough?({:->, _, [[pattern], body]}),
    do: strip_meta(pattern) == strip_meta(body)

  defp error_passthrough?(_), do: false

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp render_with(clauses, body) do
    arrow_clauses =
      clauses
      |> Enum.map(fn {pattern, scrutinee} ->
        {:<-, [], [pattern, scrutinee]}
      end)

    with_meta = [do: [line: 1], end: [line: 1]]
    with_ast = {:with, with_meta, arrow_clauses ++ [[{{:__block__, [], [:do]}, body}]]}
    Sourceror.to_string(with_ast)
  end

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp with_patch_or_skip({:ok, [_, _ | _] = clauses, body}, node),
    do: [Patch.replace(node, render_with(clauses |> Enum.reverse(), body))]

  defp with_patch_or_skip(_, _node), do: []

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
