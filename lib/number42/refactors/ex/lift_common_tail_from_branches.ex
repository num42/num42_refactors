defmodule Number42.Refactors.Ex.LiftCommonTailFromBranches do
  @moduledoc """
  Lifts the identical trailing statements shared by **every** branch of
  a `case`/`if`/`cond` out of the block, to a single run after it.

      case x do
        :a ->
          do_a()
          log(:done)

        _ ->
          do_b()
          log(:done)
      end
      ↓
      case x do
        :a -> do_a()
        _ -> do_b()
      end

      log(:done)

  ## Preconditions

  - **All branches share the tail.** The lifted run is the longest
    common *trailing* sequence of AST-identical statements across every
    branch. Each branch must keep at least one statement before it — a
    branch that is *exactly* the tail can't be emptied.
  - **Every branch is explicit.** A non-exhaustive `case` (no catch-all
    clause), an `if` without `else`, and a `cond` without a literal
    `true ->` final arm all carry an *implicit* branch that does not run
    the tail. Lifting would make the tail run for inputs that previously
    skipped it. Such blocks are skipped.
  - **The tail is branch-independent.** A tail statement may not read any
    variable bound inside a branch — neither by the branch pattern nor by
    a pre-tail statement. Otherwise the lifted tail would reference an
    out-of-scope binding.
  - **The block value is not consumed.** The tail becomes the new block
    value, so the `case`/`if` must sit in statement position — not as the
    RHS of `=`, an operand of `|>`, or an argument to a call. There it is
    either a discarded mid-block statement or the function's return; both
    preserve the original value.

  ## Idempotence

  After lifting, no branch carries the common tail, so a second pass
  finds nothing to lift and returns the source unchanged.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Lift identical trailing statements out of all case/if/cond branches"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    When every branch of a `case`/`if`/`cond` ends in the same statements,
    that tail is duplicated work the reader has to diff-match by eye. When
    all branches are explicit, the tail is branch-independent, and the
    block value isn't consumed, the tail can run once after the block
    instead — shorter branches, the shared epilogue stated exactly once.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough([patch | _], source), do: Sourceror.patch_string(source, [patch])

  defp build_patches(ast, source) do
    consumed = consumed_nodes(ast)

    ast
    |> Macro.prewalker()
    |> Enum.find_value([], fn node -> maybe_patch(node, consumed, source) end)
  end

  defp maybe_patch({form, _, _} = node, consumed, source) when form in [:case, :if, :cond] do
    with false <- MapSet.member?(consumed, strip_meta(node)),
         {:ok, branches} <- branches(node),
         {:ok, tail_len} <- common_tail_length(branches),
         :ok <- tail_independent?(node, branches, tail_len),
         {:ok, patch} <- build_patch(node, branches, tail_len, source) do
      [patch]
    else
      _ -> nil
    end
  end

  defp maybe_patch(_, _, _), do: nil

  # --- branch extraction ---

  # Returns the explicit branch bodies as lists of statements, or :skip
  # when the block carries an implicit branch (non-exhaustive case /
  # else-less if) that wouldn't run the tail.
  defp branches({:case, _, [_scrutinee, kw]}) do
    with {:ok, clauses} <- fetch_block(kw, :do),
         true <- is_list(clauses),
         true <- Enum.all?(clauses, &match?({:->, _, [[_pattern], _body]}, &1)),
         true <- exhaustive?(clauses) do
      {:ok, Enum.map(clauses, &clause_stmts/1)}
    else
      _ -> :skip
    end
  end

  defp branches({:if, _, [_cond, kw]}) do
    with {:ok, do_body} <- fetch_block(kw, :do),
         {:ok, else_body} <- fetch_block(kw, :else) do
      {:ok, [body_to_exprs(do_body), body_to_exprs(else_body)]}
    else
      _ -> :skip
    end
  end

  defp branches({:cond, _, [[{_do_key, clauses}]]}) do
    with true <- is_list(clauses),
         true <- Enum.all?(clauses, &match?({:->, _, [[_condition], _body]}, &1)),
         true <- cond_exhaustive?(clauses) do
      {:ok, Enum.map(clauses, &clause_stmts/1)}
    else
      _ -> :skip
    end
  end

  # Any other shape (e.g. a bare `do:`-keyword `case` parsed as
  # `{:case, _, [scrutinee]}`) has no `do/end` block to lift a tail
  # behind — skip.
  defp branches(_), do: :skip

  defp clause_stmts({:->, _, [_patterns, body]}), do: body_to_exprs(body)

  # A case is treated as exhaustive iff its last clause is an unguarded
  # catch-all binding a single bare/underscore variable.
  defp exhaustive?(clauses) do
    case List.last(clauses) do
      {:->, _, [[pattern], _body]} -> catch_all_pattern?(pattern)
      _ -> false
    end
  end

  defp catch_all_pattern?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp catch_all_pattern?(_), do: false

  # A cond is exhaustive iff its last arm tests a literal `true`. Without
  # it, no arm may match and the cond raises — an implicit branch that
  # wouldn't run the tail.
  defp cond_exhaustive?(clauses) do
    case List.last(clauses) do
      {:->, _, [[condition], _body]} -> literal_true?(condition)
      _ -> false
    end
  end

  defp literal_true?(true), do: true
  defp literal_true?({:__block__, _, [true]}), do: true
  defp literal_true?(_), do: false

  defp fetch_block(kw, key) when is_list(kw) do
    kw
    |> Enum.find_value(:skip, fn
      {{:__block__, _, [^key]}, value} -> {:ok, value}
      {^key, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp fetch_block(_, _), do: :skip

  # --- common-tail analysis ---

  # Longest common trailing run of AST-identical statements across all
  # branches, strictly shorter than every branch and at least 1.
  defp common_tail_length(branches) do
    max_tail = (branches |> Enum.map(&length/1) |> Enum.min()) - 1

    max_tail
    |> longest_common_tail(branches)
    |> tail_length_or_skip()
  end

  defp longest_common_tail(max_tail, _branches) when max_tail < 1, do: 0

  defp longest_common_tail(max_tail, branches) do
    Enum.reduce_while(1..max_tail//1, 0, fn n, acc ->
      if all_agree_at_tail?(branches, n), do: {:cont, n}, else: {:halt, acc}
    end)
  end

  defp tail_length_or_skip(len) when len >= 1, do: {:ok, len}
  defp tail_length_or_skip(_), do: :skip

  defp all_agree_at_tail?([first | rest], n) do
    ref = first |> Enum.at(-n) |> strip_meta()
    Enum.all?(rest, fn stmts -> strip_meta(Enum.at(stmts, -n)) == ref end)
  end

  # The tail must not read any variable bound inside a branch — pattern
  # bindings or pre-tail statement bindings.
  defp tail_independent?(node, branches, tail_len) do
    [first | _] = branches
    tail = Enum.take(first, -tail_len)
    reads = Enum.reduce(tail, MapSet.new(), fn s, acc -> MapSet.union(acc, used_var_names(s)) end)

    branch_binds =
      branches
      |> Enum.reduce(pattern_binds(node), fn stmts, acc ->
        prefix = Enum.drop(stmts, -tail_len)
        MapSet.union(acc, Enum.reduce(prefix, MapSet.new(), &MapSet.union(&2, bound_in(&1))))
      end)

    if MapSet.disjoint?(reads, branch_binds), do: :ok, else: :skip
  end

  defp pattern_binds({:case, _, [_scrutinee, kw]}) do
    case fetch_block(kw, :do) do
      {:ok, clauses} when is_list(clauses) ->
        clauses
        |> Enum.flat_map(fn {:->, _, [patterns, _body]} ->
          Enum.flat_map(patterns, &pattern_var_names/1)
        end)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp pattern_binds({:if, _, _}), do: MapSet.new()
  defp pattern_binds({:cond, _, _}), do: MapSet.new()

  # --- patch construction ---

  defp build_patch(node, branches, tail_len, source) do
    [first | _] = branches
    tail = Enum.take(first, -tail_len)

    with %{} = range <- Sourceror.get_range(node),
         {:ok, block_text} <- render_block_without_tail(node, tail_len) do
      tail_text = Enum.map_join(tail, "\n\n", &Sourceror.to_string/1)
      indent = String.duplicate(" ", range.start[:column] - 1)
      replacement = block_text <> "\n\n" <> reindent(tail_text, indent)
      _ = source
      {:ok, Patch.new(range, replacement)}
    else
      _ -> :skip
    end
  end

  defp render_block_without_tail({:case, meta, [scrutinee, kw]}, tail_len) do
    clauses = strip_tail_from_clauses(fetch_block!(kw, :do), tail_len)
    {:ok, Sourceror.to_string({:case, meta, [scrutinee, put_block(kw, :do, clauses)]})}
  end

  defp render_block_without_tail({:cond, meta, [[{do_key, clauses}]]}, tail_len) do
    new_clauses = strip_tail_from_clauses(clauses, tail_len)
    {:ok, Sourceror.to_string({:cond, meta, [[{do_key, new_clauses}]]})}
  end

  defp render_block_without_tail({:if, meta, [cond_ast, kw]}, tail_len) do
    {:ok, do_body} = fetch_block(kw, :do)
    {:ok, else_body} = fetch_block(kw, :else)
    new_do = drop_tail_body(do_body, tail_len)
    new_else = drop_tail_body(else_body, tail_len)

    kw =
      kw
      |> put_block(:do, new_do)
      |> put_block(:else, new_else)

    {:ok, Sourceror.to_string({:if, meta, [cond_ast, kw]})}
  end

  defp strip_tail_from_clauses(clauses, tail_len) do
    Enum.map(clauses, fn {:->, meta, [patterns, body]} ->
      {:->, meta, [patterns, drop_tail_body(body, tail_len)]}
    end)
  end

  defp drop_tail_body(body, tail_len) do
    body
    |> body_to_exprs()
    |> Enum.drop(-tail_len)
    |> exprs_to_body()
  end

  defp exprs_to_body([single]), do: single
  defp exprs_to_body(exprs), do: {:__block__, [], exprs}

  defp fetch_block!(kw, key) do
    {:ok, value} = fetch_block(kw, key)
    value
  end

  defp put_block(kw, key, value) do
    Enum.map(kw, fn
      {{:__block__, _, [^key]} = k, _} -> {k, value}
      {^key, _} -> {key, value}
      other -> other
    end)
  end

  defp reindent(text, indent) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> indent <> line
    end)
  end

  # --- shared ---

  # Set of stripped case/if nodes whose value is consumed: RHS of `=`,
  # operand of `|>`, or any call/operator argument.
  defp consumed_nodes(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:=, _, [_lhs, rhs]} -> control_flow_in(rhs)
      {:|>, _, args} -> Enum.flat_map(args, &control_flow_in/1)
      {:__block__, _, _} -> []
      {_form, _, args} when is_list(args) -> Enum.flat_map(args, &control_flow_in/1)
      _ -> []
    end)
    |> MapSet.new()
  end

  defp control_flow_in({form, _, _} = node) when form in [:case, :if, :cond],
    do: [strip_meta(node)]

  defp control_flow_in(_), do: []

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end
end
