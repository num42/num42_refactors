defmodule Number42.Refactors.Ex.CollapseRichCaseToWithElse do
  @moduledoc """
  Collapses a nested `case` pyramid whose error arms do **real work**
  (transform, log, re-tag — not just propagate `{:error, e}`) into a
  `with` chain plus an `else` block.

  This is the rich-arm counterpart to `CollapseNestedCaseToWith`, which
  only fires when every error arm is a trivial pass-through and the
  `with` needs no `else`. Here at least one error arm differs, so the
  arms are collected from every level and emitted as `else` clauses.

  ## Antipattern

      case fetch_user(id) do
        {:ok, user} ->
          case authorize(user, action) do
            :ok ->
              case perform(action, user) do
                {:ok, result} -> {:ok, result}
                {:error, :timeout} -> {:error, "took too long"}
              end

            {:error, :forbidden} -> {:error, "not allowed"}
          end

        {:error, :not_found} -> {:error, "no such user"}
      end

  ## Replacement

      with {:ok, user} <- fetch_user(id),
           :ok <- authorize(user, action),
           {:ok, result} <- perform(action, user) do
        {:ok, result}
      else
        {:error, :not_found} -> {:error, "no such user"}
        {:error, :forbidden} -> {:error, "not allowed"}
        {:error, :timeout} -> {:error, "took too long"}
      end

  ## Why

  Each level's success arm nests the next `case`; the error arms are the
  failure handling. `with` expresses exactly this — happy path as a
  linear chain of `<-` clauses, every failure routed through one `else`.
  The pyramid forces the reader to track which `case` an error arm
  belongs to; the flat `else` makes the whole failure surface visible at
  once.

  ## What this refactor refuses to do — the dangerous part

  - **Scope loss.** An error arm that references a variable bound by an
    *earlier* success arm (e.g. a `:forbidden` arm logging `user.id`)
    will not compile in the flat `else` — `user` isn't bound there. This
    produces *uncompilable* code, not merely a behaviour edge, so it is
    skipped unconditionally.
  - **Overlapping error patterns.** If two levels can both yield the same
    error shape (`{:error, :x}`) with different intended handling, the
    flat `else` collapses them to the first match — a behaviour change.
    Duplicate patterns across the collected arms force a skip.
  - **At least one non-trivial arm.** If every error arm is a trivial
    pass-through, the rewrite is `CollapseNestedCaseToWith`'s job (no
    `else` needed). This refactor stays out of the way then.
  - **Exactly one success arm per level.** Two `{:ok, _}`-shaped arms in
    one `case` make the spine ambiguous; skip.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Collapse a nested case with non-trivial error arms into `with`/`else`"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A `case` pyramid whose error arms transform, log, or re-tag the
    failure can't collapse to a bare `with` — the work would be lost.
    Routing every level's error arm through one `else` block preserves
    that work while flattening the happy path into a linear `with`
    chain. The refactor refuses when an error arm reads an outer
    success binding (uncompilable in `else`) or when two levels share an
    error pattern (the flat `else` would mis-route one of them).
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

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp maybe_patch({:case, _, _} = node), do: unwrap_pyramid(node, [], []) |> patch_or_skip(node)
  defp maybe_patch(_), do: []

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  # Walk the success spine. `clauses` accumulates `{success_pattern,
  # scrutinee}` in reverse; `arms` accumulates the non-success arms in
  # outer-to-inner order for the eventual `else` block.
  defp unwrap_pyramid({:case, _, [scrutinee, [{_do, arms_ast}]]}, clauses, arms)
       when is_list(arms_ast) do
    case split_arms(arms_ast) do
      {:ok, {success_pattern, success_body}, error_arms} ->
        clauses = [{success_pattern, scrutinee} | clauses]
        arms = arms ++ error_arms
        continue_spine(success_body, clauses, arms)

      :skip ->
        :skip
    end
  end

  defp unwrap_pyramid(_, _, _), do: :skip

  defp continue_spine({:case, _, _} = inner, clauses, arms),
    do: unwrap_pyramid(inner, clauses, arms)

  defp continue_spine(body, clauses, arms), do: {:ok, clauses, body, arms}

  # Partition a level's arms into the single success arm and the rest.
  # Requires exactly one happy-path arm; otherwise the spine is ambiguous.
  defp split_arms(arms_ast) do
    {success, errors} = Enum.split_with(arms_ast, &success_arm?/1)

    case success do
      [{:->, _, [[pattern], body]}] -> {:ok, {pattern, body}, errors}
      _ -> :skip
    end
  end

  defp success_arm?({:->, _, [[pattern], _body]}), do: happy_path?(pattern)
  defp success_arm?(_), do: false

  defp happy_path?({:__block__, _, [{{:__block__, _, [:ok]}, _val}]}), do: true
  defp happy_path?({:__block__, _, [:ok]}), do: true
  defp happy_path?(:ok), do: true
  defp happy_path?(_), do: false

  defp patch_or_skip({:ok, [_, _ | _] = clauses, body, arms}, node) do
    clauses = Enum.reverse(clauses)

    if rewritable?(clauses, arms),
      do: [Patch.replace(node, render_with_else(clauses, body, arms))],
      else: []
  end

  defp patch_or_skip(_, _node), do: []

  # Gate the rewrite on the three correctness conditions plus the
  # boundary against the trivial-arm refactor.
  defp rewritable?(clauses, arms) do
    has_nontrivial_arm?(arms) and not duplicate_patterns?(arms) and
      not scope_loss?(clauses, arms)
  end

  defp has_nontrivial_arm?(arms), do: Enum.any?(arms, &(not passthrough_arm?(&1)))

  defp passthrough_arm?({:->, _, [[pattern], body]}),
    do: strip_meta(pattern) == strip_meta(body)

  defp passthrough_arm?(_), do: false

  # Two collected arms whose patterns are structurally identical would
  # both match the same failure value; the flat `else` routes only to
  # the first → behaviour change.
  defp duplicate_patterns?(arms) do
    patterns = Enum.map(arms, fn {:->, _, [[pattern], _]} -> strip_meta(pattern) end)
    length(Enum.uniq(patterns)) != length(patterns)
  end

  # An error arm that reads a variable bound by any earlier `with` step's
  # success pattern would not compile in the flat `else`.
  defp scope_loss?(clauses, arms) do
    bound =
      clauses |> Enum.flat_map(fn {pattern, _} -> pattern_var_names(pattern) end) |> MapSet.new()

    Enum.any?(arms, fn {:->, _, [[_pattern], body]} ->
      body |> used_var_names() |> MapSet.intersection(bound) |> MapSet.size() > 0
    end)
  end

  defp render_with_else(clauses, body, arms) do
    arrow_clauses =
      Enum.map(clauses, fn {pattern, scrutinee} -> {:<-, [], [pattern, scrutinee]} end)

    else_clauses = Enum.map(arms, &strip_arm_meta/1)

    kw = [
      {{:__block__, [], [:do]}, body},
      {{:__block__, [], [:else]}, else_clauses}
    ]

    with_meta = [do: [line: 1], end: [line: 1]]
    with_ast = {:with, with_meta, arrow_clauses ++ [kw]}
    Sourceror.to_string(with_ast)
  end

  # Re-key each arrow clause so it renders cleanly inside the fresh
  # `with`; the captured arms carry pyramid-relative metadata.
  defp strip_arm_meta({:->, _, [[pattern], body]}), do: {:->, [], [[pattern], body]}

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end
end
