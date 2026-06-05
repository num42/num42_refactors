defmodule Number42.Refactors.Ex.IfElseToCond do
  @moduledoc """
  Rewrites nested `if`/`else` expressions where the last statement of a
  branch is another `if`/`else` into a flat `cond` block. When pre-statements
  appear before the inner `if`, they are wrapped in a local anonymous
  function and the cond branch calls it.

      if cond1 do
        body1
      else
        if cond2 do
          body2
        else
          body3
        end
      end
      ↓
      cond do
        cond1 -> body1
        cond2 -> body2
        true -> body3
      end

  ## When this fires

  - Outer `if/else` whose last expression in `do` or `else` branch is
    another `if/else` (the inner one must have an `else`)
  - With pre-statements in the branch: a local anonymous function is
    extracted before the cond
  - When outer branches are structurally identical, the outer `if` is
    dropped and only the inner logic survives as `cond`

  ## When this skips

  - Inner `if` has no `else` (would change semantics)
  - Extracted helper fn would need to be called in more than one cond
    branch (would duplicate side-effects or computation)
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Rewrite nested `if/else` chains as a flat `cond` block"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Nested `if/else` forces the reader to mentally pair each `else` with
    its `if` several lines above. A `cond` block keeps each condition
    next to its branch body, reads top-to-bottom as a guard chain, and
    extends naturally when a third case appears later.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 80

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> ast |> build_patches() |> apply_patches(source)
      {:error, _} -> source
    end
  end

  defp apply_patches([], source), do: source
  defp apply_patches(patches, source), do: Sourceror.patch_string(source, patches)

  defp build_patches(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&maybe_patch/1)
    |> Enum.take(1)
  end

  defp maybe_patch({:if, _meta, [_cond, _kw]} = node) do
    with {:ok, outer} <- if_shape(node),
         true <- has_nested_if?(outer),
         {:ok, branches} <- collect_branches(outer),
         {:ok, replacement} <- render_replacement(branches) do
      [Patch.replace(node, replacement)]
    else
      _ -> []
    end
  end

  defp maybe_patch(_), do: []

  # Fires only when do or else branch contains a nested if/else (directly or
  # as the tail of a __block__). Plain 2-branch if/else is left alone.
  defp has_nested_if?(%{do: do_body, else: else_body}) do
    branch_contains_nested_if?(do_body) or branch_contains_nested_if?(else_body)
  end

  defp branch_contains_nested_if?(body) do
    case if_shape(body) do
      {:ok, _} ->
        true

      :error ->
        case extract_block_tail_if(body) do
          {:ok, _, _} -> true
          :no -> false
        end
    end
  end

  # --- AST decomposition -----------------------------------------------------

  defp if_shape({:if, meta, [cond_ast, kw]}) when is_list(kw) do
    {do_body, else_body} = extract_do_else(kw)

    if do_body && else_body do
      {:ok, %{cond: cond_ast, do: do_body, else: else_body, meta: meta}}
    else
      :error
    end
  end

  defp if_shape(_), do: :error

  defp extract_do_else(kw) do
    Enum.reduce(kw, {nil, nil}, fn
      {{:__block__, _, [:do]}, v}, {_, e} -> {v, e}
      {:do, v}, {_, e} -> {v, e}
      {{:__block__, _, [:else]}, v}, {d, _} -> {d, v}
      {:else, v}, {d, _} -> {d, v}
      _, acc -> acc
    end)
  end

  # Returns a flat list of cond branches: %{cond: expr_or_nil, body: ast, pre: [stmt]}.
  # nil-cond marks the terminal `true ->` branch.
  # Decomposes nested if/else recursively.
  defp collect_branches(%{cond: cond_ast, do: do_body, else: else_body}) do
    if ast_eq?(do_body, else_body) do
      # Outer if is dead — both branches identical. Drop outer condition,
      # try to make a cond from the inner shape directly.
      collect_from_branch(do_body, [])
    else
      with {:ok, do_branches} <- collect_from_branch(do_body, []),
           {:ok, else_branches} <- collect_from_branch(else_body, []) do
        merge_branches(cond_ast, do_branches, else_branches)
      end
    end
  end

  # Combine outer cond + do/else sub-branches into one flat branch list.
  # Skip if BOTH sides nested (too complex for safe flattening).
  defp merge_branches(cond_ast, do_branches, else_branches) do
    do_nests? = length(do_branches) > 1
    else_nests? = length(else_branches) > 1

    cond do
      do_nests? and else_nests? ->
        :error

      # Case A: do terminal, else nests (or also terminal).
      not do_nests? ->
        [terminal_do] = do_branches
        guarded_do = %{terminal_do | cond: cond_ast}
        {:ok, [guarded_do | else_branches]}

      # Case B: do nests, else terminal.
      true ->
        guarded = Enum.map(do_branches, &guard_branch(cond_ast, &1))
        {:ok, guarded ++ else_branches}
    end
  end

  defp guard_branch(cond_ast, b) do
    new_cond =
      case b.cond do
        nil -> cond_ast
        inner -> combine_and(cond_ast, inner)
      end

    %{b | cond: new_cond}
  end

  # Decompose a single branch body. If body is `if/else`, recurse. Otherwise it's a terminal branch.
  defp collect_from_branch(body, pre_stmts) do
    case if_shape(body) do
      {:ok, inner} -> collect_from_nested_if(inner, pre_stmts)
      :error -> collect_from_non_if(body, pre_stmts)
    end
  end

  # Nested if/else — collect its branches, prepend pre_stmts to first one.
  defp collect_from_nested_if(inner, pre_stmts) do
    case collect_branches(inner) do
      {:ok, [first | rest]} ->
        {:ok, [%{first | pre: pre_stmts ++ first.pre} | rest]}

      err ->
        err
    end
  end

  # Maybe it's a block with statements + a final if/else?
  defp collect_from_non_if(body, pre_stmts) do
    case extract_block_tail_if(body) do
      {:ok, leading, inner_if} ->
        collect_from_branch(inner_if, pre_stmts ++ leading)

      :no ->
        # Terminal — this branch is the final body.
        {:ok, [%{cond: nil, body: body, pre: pre_stmts}]}
    end
  end

  # If `body` is a __block__ whose last statement is an if/else, return
  # {:ok, leading_stmts, inner_if_node}. Otherwise :no.
  defp extract_block_tail_if({:__block__, _, stmts}) when is_list(stmts) and length(stmts) >= 2 do
    {leading, [tail]} = Enum.split(stmts, -1)

    case if_shape(tail) do
      {:ok, _} -> {:ok, leading, tail}
      :error -> :no
    end
  end

  defp extract_block_tail_if(_), do: :no

  # --- Rendering -------------------------------------------------------------

  defp render_replacement(branches) do
    case Enum.any?(branches, fn b -> b.pre != [] end) do
      true -> render_with_pre_fns(branches)
      false -> {:ok, render_plain_cond(branches)}
    end
  end

  defp render_plain_cond(branches) do
    Sourceror.to_string(cond_ast(branches))
  end

  defp cond_ast(branches) do
    clauses =
      Enum.map(branches, fn b ->
        cond_expr = b.cond || true_lit()
        {:->, [line: 1], [[cond_expr], b.body]}
      end)

    cond_meta = [do: [line: 1], end: [line: 1]]
    {:cond, cond_meta, [[{{:__block__, [], [:do]}, clauses}]]}
  end

  # For each branch with pre-statements, attempt to extract a fn.
  # Returns :error if any branch can't be safely handled (forcing whole-tree skip).
  defp render_with_pre_fns(branches) do
    with {:ok, prepared} <- prepare_branches_with_fns(branches),
         :ok <- check_no_double_use(prepared) do
      {:ok, render_block_with_fns(prepared)}
    else
      _ -> :error
    end
  end

  # For each branch:
  #   - if pre == []: keep as-is
  #   - if pre != []: attempt extraction. Returns either an :inline (no fn needed)
  #     or a :fn entry with the fn definition.
  defp prepare_branches_with_fns(branches) do
    result =
      Enum.reduce_while(branches, {:ok, []}, fn b, {:ok, acc} ->
        case prepare_branch(b) do
          {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
          :error -> {:halt, :error}
        end
      end)

    case result do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      :error -> :error
    end
  end

  defp prepare_branch(%{pre: []} = b), do: {:ok, %{kind: :plain, branch: b}}

  defp prepare_branch(%{pre: pre, cond: cond_ast, body: body} = b) do
    # The fn-extraction replaces the WHOLE branch condition with
    # `compute_var.()`. That is only sound when the condition *is* exactly the
    # bound variable — then `compute_var.()` is semantically equal to testing
    # `var` for truthiness. If the condition is a compound expression that
    # merely *references* the binding (e.g. `var > 0 and other_guard`),
    # replacing it with `compute_var.()` would silently drop the real guards
    # (issue #8). In that case we skip the whole rewrite (the safest default).
    with {:ok, last_binding_var, _rhs} <- last_stmt_is_binding(pre),
         true <- cond_is_exactly_var?(cond_ast, last_binding_var),
         false <- body_references_var?(body, last_binding_var) do
      fn_name = synth_fn_name(last_binding_var)
      fn_body = rewrap_pre_as_fn_body(pre)
      call_node = {{:., [], [{fn_name, [], nil}]}, [], []}
      new_branch = %{b | cond: call_node, pre: []}
      fn_def = build_fn_def(fn_name, fn_body)
      {:ok, %{kind: :fn, branch: new_branch, fn_def: fn_def, fn_name: fn_name}}
    else
      _ -> :error
    end
  end

  # Check: the synthesised fn-name must appear in at most one branch.
  # Since we just created it freshly per branch this is always the case
  # for the fn-call placement, but we should also ensure the binding-var
  # itself isn't referenced in any OTHER branch (would mean the original
  # code shared the binding across branches).
  defp check_no_double_use(prepared) do
    fn_vars =
      prepared
      |> Enum.filter(&(&1.kind == :fn))
      |> Enum.map(fn p ->
        # Var name comes from the original branch's binding; reverse from fn_name.
        # We stored it in the fn_def — extract.
        extract_fn_var_name(p.fn_def)
      end)

    case fn_vars do
      [] ->
        :ok

      _ ->
        # Check each fn-var: it must not appear in any other branch's body
        # (the local-fn case ensures it doesn't appear in its own branch body —
        # prepare_branch already guards that).
        Enum.reduce_while(prepared, :ok, fn p, :ok ->
          if p.kind == :fn do
            var = extract_fn_var_name(p.fn_def)

            other_uses =
              prepared
              |> Enum.reject(&(&1 == p))
              |> Enum.any?(fn other -> branch_uses_var?(other.branch, var) end)

            if other_uses, do: {:halt, :error}, else: {:cont, :ok}
          else
            {:cont, :ok}
          end
        end)
    end
  end

  defp render_block_with_fns(prepared) do
    fn_defs =
      prepared
      |> Enum.filter(&(&1.kind == :fn))
      |> Enum.map(& &1.fn_def)

    branches = Enum.map(prepared, & &1.branch)
    cond_node = cond_ast(branches)

    block = {:__block__, [], fn_defs ++ [cond_node]}

    # Use the special inner-content form so Sourceror renders without
    # outer parens for the block.
    Sourceror.to_string(block)
  end

  # --- Pre-statement analysis helpers ----------------------------------------

  # The last statement of pre must be `var = rhs` where var is a bare atom.
  defp last_stmt_is_binding(pre) when is_list(pre) and pre != [] do
    case List.last(pre) do
      {:=, _, [{var, _, ctx}, rhs]} when is_atom(var) and is_atom(ctx) ->
        {:ok, var, rhs}

      _ ->
        :error
    end
  end

  defp last_stmt_is_binding(_), do: :error

  # True only when the condition AST is the bound variable itself (a bare
  # `{var, _meta, ctx}` reference). A compound expression that *contains* the
  # var does not qualify — replacing it wholesale with `compute_var.()` would
  # drop the surrounding guards (issue #8).
  defp cond_is_exactly_var?({var, _meta, ctx}, var) when is_atom(ctx), do: true
  defp cond_is_exactly_var?(_cond_ast, _var), do: false

  defp body_references_var?(body, var), do: ast_contains_var?(body, var)

  defp branch_uses_var?(%{cond: c, body: b}, var) do
    (c && ast_contains_var?(c, var)) || ast_contains_var?(b, var)
  end

  defp ast_contains_var?(ast, var) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {^var, _meta, ctx} = node, _acc when is_atom(ctx) -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  # `compute_<var>` — drop trailing `?`/`!` if present.
  defp synth_fn_name(var) do
    var
    |> Atom.to_string()
    |> String.replace(~r/[?!]$/, "")
    |> then(&("compute_" <> &1))
    |> String.to_atom()
  end

  # Take the pre-statements and turn them into the fn body. The last
  # statement was `var = rhs`; we replace it with just `rhs` (the final
  # expression becomes the fn's return value).
  defp rewrap_pre_as_fn_body(pre) do
    {leading, [{:=, _, [_lhs, rhs]}]} = Enum.split(pre, -1)

    case leading do
      [] -> rhs
      _ -> {:__block__, [], leading ++ [rhs]}
    end
  end

  # Build `<name> = fn -> <body> end`.
  defp build_fn_def(name, body) do
    fn_meta = [closing: [line: 1], line: 1]
    fn_node = {:fn, fn_meta, [{:->, [line: 1], [[], body]}]}
    {:=, [line: 1], [{name, [line: 1], nil}, fn_node]}
  end

  # Extract the original var name back from the fn_def we built.
  defp extract_fn_var_name({:=, _, [{name, _, _} | _]}) do
    name
    |> Atom.to_string()
    |> String.replace_prefix("compute_", "")
    |> String.to_atom()
  end

  defp true_lit, do: {:__block__, [], [true]}

  defp combine_and(a, b), do: {:and, [], [a, b]}

  # --- AST equality (meta-stripped) -----------------------------------------

  defp ast_eq?(a, b), do: strip_meta(a) == strip_meta(b)

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end
end
