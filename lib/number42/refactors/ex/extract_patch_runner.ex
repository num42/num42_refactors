defmodule Number42.Refactors.Ex.ExtractPatchRunner do
  @moduledoc """
  Rewrite a refactor module that carries the canonical parse/build/patch
  skeleton to `use Number42.Refactors.PatchRefactor`, deleting the
  boilerplate that the macro re-generates.

      # before
      use Number42.Refactors.Refactor

      @impl Number42.Refactors.Refactor
      def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)
      defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
      defp apply_patches({:error, _}, source), do: source

      defp build_patches(ast), do: ast |> Macro.prewalker() |> Enum.flat_map(&maybe_patch/1)
      # ... module-specific helpers ...
      defp patch_or_passthrough([], source), do: source
      defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

      # after
      use Number42.Refactors.PatchRefactor

      defp build_patches(ast), do: ast |> Macro.prewalker() |> Enum.flat_map(&maybe_patch/1)
      # ... module-specific helpers ...

  The module keeps `build_patches/1` (its only refactor-specific moving
  part) plus `description/0`, `explanation/0`, `priority/0`,
  `reformat_after?/0`; the `use Number42.Refactors.PatchRefactor` macro
  supplies `transform/2`, `apply_patches/2`, and `patch_or_passthrough/2`.

  ## What we match

  A module is rewritten only when **all** of the following hold — a
  deliberately exact-shape matcher, so the rewrite never changes
  behaviour:

  - the module declares `use Number42.Refactors.Refactor`
  - `transform/2` is exactly
    `def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)`
    (one clause, `opts` unused)
  - both `apply_patches/2` clauses match the canonical `{:ok, ast}` /
    `{:error, _}` shape
  - both `patch_or_passthrough/2` clauses match the canonical empty /
    non-empty shape (either `Sourceror.patch_string(source, patches)`
    call form or its `source |> Sourceror.patch_string(patches)` pipe)
  - `build_patches/1` is defined (the extension point the macro calls)
  - the names `apply_patches` and `patch_or_passthrough` appear **only**
    inside the canonical clauses — never called from `build_patches/1`
    or any other helper

  ## What we skip

  - A `transform/2` that reads `opts`, has extra clauses, or threads
    additional state through `apply_patches` — its control flow is not
    the macro's control flow.
  - A custom parse-error or empty-patch branch (anything other than
    "return the source unchanged").
  - A module that already uses `Number42.Refactors.PatchRefactor`.
  - A module where a skeleton helper name is reused for other work —
    deleting the clause would break a real call.

  ## Idempotence

  After the rewrite the skeleton clauses and the `Refactor` `use` are
  gone, so a second pass finds nothing to match.
  """

  use Number42.Refactors.PatchRefactor

  @refactor_use [:Number42, :Refactors, :Refactor]

  # Canonical skeleton clauses, matched after normalization (metadata
  # stripped, Sourceror's `{:__block__, _, [literal]}` wrappers unwrapped)
  # so source spacing and Sourceror's representation don't affect the match.
  @transform_template "def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)"
  @apply_ok_template "defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)"
  @apply_err_template "defp apply_patches({:error, _}, source), do: source"
  @pop_empty_template "defp patch_or_passthrough([], source), do: source"
  @pop_full_call_template "defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)"
  @pop_full_pipe_template "defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)"

  @impl Number42.Refactors.Refactor
  def description,
    do: "Rewrite the parse/build/patch skeleton to `use Number42.Refactors.PatchRefactor`"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    The same parse → build patches → apply mechanics are copied across
    dozens of refactor modules: `transform/2` delegates to
    `Sourceror.parse_string`, an `apply_patches/2` pair handles the
    `{:ok, ast}` / `{:error, _}` split, and a `patch_or_passthrough/2`
    pair returns the source for an empty patch list or calls
    `Sourceror.patch_string/2`. Factoring it into
    `use Number42.Refactors.PatchRefactor` leaves each refactor with just
    its `build_patches/1` — the only part that actually differs — so a
    new refactor reads as the rule it encodes, not the plumbing around
    it. Matched exactly, so the rewrite is behaviour-preserving.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 100

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  defp build_patches(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value([], &patches_for_module/1)
  end

  defp patches_for_module({:defmodule, _, [_name, [{_do, body}]]}) do
    exprs = body_to_exprs(body)

    with use_node when not is_nil(use_node) <- refactor_use_node(exprs),
         skeleton when not is_nil(skeleton) <- find_skeleton(exprs),
         true <- has_build_patches?(exprs),
         true <- helpers_only_in_skeleton?(exprs, skeleton) do
      build_rewrite_patches(use_node, skeleton, exprs)
    else
      _ -> nil
    end
  end

  defp patches_for_module(_), do: nil

  defp refactor_use_node(exprs) do
    Enum.find(exprs, fn
      {:use, _, [{:__aliases__, _, @refactor_use}]} -> true
      _ -> false
    end)
  end

  # Collect the five canonical clauses by exact AST shape (metadata
  # stripped). Returns a map of the matched nodes, or nil if any is
  # missing or duplicated.
  defp find_skeleton(exprs) do
    transform = single_match(exprs, &transform_clause?/1)
    apply_ok = single_match(exprs, &apply_ok_clause?/1)
    apply_err = single_match(exprs, &apply_err_clause?/1)
    pop_empty = single_match(exprs, &pop_empty_clause?/1)
    pop_full = single_match(exprs, &pop_full_clause?/1)

    skeleton = %{
      transform: transform,
      apply_ok: apply_ok,
      apply_err: apply_err,
      pop_empty: pop_empty,
      pop_full: pop_full
    }

    if Enum.any?(Map.values(skeleton), &is_nil/1), do: nil, else: skeleton
  end

  # Exactly one expr satisfies the predicate, else nil — guards against a
  # second clause we'd silently drop.
  defp single_match(exprs, pred) do
    case Enum.filter(exprs, pred) do
      [only] -> only
      _ -> nil
    end
  end

  defp transform_clause?(node), do: matches_template?(node, @transform_template)
  defp apply_ok_clause?(node), do: matches_template?(node, @apply_ok_template)
  defp apply_err_clause?(node), do: matches_template?(node, @apply_err_template)
  defp pop_empty_clause?(node), do: matches_template?(node, @pop_empty_template)

  # Non-empty branch comes in a call form and an equivalent pipe form.
  defp pop_full_clause?(node) do
    matches_template?(node, @pop_full_call_template) or
      matches_template?(node, @pop_full_pipe_template)
  end

  defp matches_template?(node, template) do
    case Sourceror.parse_string(template) do
      {:ok, template_ast} -> normalize(node) == normalize(template_ast)
      {:error, _} -> false
    end
  end

  defp has_build_patches?(exprs) do
    Enum.any?(exprs, fn
      {kind, _, [head | _]} when kind in [:def, :defp] ->
        match?({:build_patches, _, [_]}, strip_when(head))

      _ ->
        false
    end)
  end

  # The names `apply_patches` and `patch_or_passthrough` may appear only
  # inside the five canonical clauses. Any other reference means the
  # helper is load-bearing elsewhere; deleting it would break a call.
  defp helpers_only_in_skeleton?(exprs, skeleton) do
    skeleton_nodes = Map.values(skeleton)
    others = exprs -- skeleton_nodes

    not Enum.any?(others, &references_skeleton_helper?/1)
  end

  defp references_skeleton_helper?(node) do
    node
    |> Macro.prewalker()
    |> Enum.any?(fn
      {name, _, args} when name in [:apply_patches, :patch_or_passthrough] and is_list(args) ->
        true

      _ ->
        false
    end)
  end

  defp build_rewrite_patches(use_node, skeleton, exprs) do
    [use_patch(use_node) | delete_patches(skeleton, exprs)]
  end

  defp use_patch(use_node) do
    %{change: "use Number42.Refactors.PatchRefactor", range: Sourceror.get_range(use_node)}
  end

  defp delete_patches(skeleton, exprs) do
    skeleton
    |> Map.values()
    |> Enum.map(&delete_node_with_leading_impl(&1, exprs))
    |> Enum.reject(&is_nil/1)
  end

  # Delete the clause, plus an `@impl` attribute directly above it if
  # present (the macro re-emits its own `@impl`).
  defp delete_node_with_leading_impl(node, exprs) do
    idx = Enum.find_index(exprs, &(&1 == node))
    start_node = leading_impl(exprs, idx) || node

    with %{start: start_pos} <- Sourceror.get_range(start_node),
         %{end: end_pos} <- Sourceror.get_range(node) do
      %{change: "", range: %{start: start_pos, end: end_pos}}
    else
      _ -> nil
    end
  end

  defp leading_impl(_exprs, nil), do: nil
  defp leading_impl(_exprs, 0), do: nil

  defp leading_impl(exprs, idx) do
    case Enum.at(exprs, idx - 1) do
      {:@, _, [{:impl, _, _}]} = attr -> attr
      _ -> nil
    end
  end

  # Strip metadata and unwrap Sourceror's `{:__block__, _, [literal]}`
  # wrappers so two ASTs of the same code compare equal regardless of
  # source spacing or whether a literal carried position info.
  defp normalize(ast) do
    Macro.prewalk(ast, fn
      {:__block__, _meta, [literal]} -> literal
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other
end
