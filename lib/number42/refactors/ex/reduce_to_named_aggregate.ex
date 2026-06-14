defmodule Number42.Refactors.Ex.ReduceToNamedAggregate do
  @moduledoc """
  Classifies a multi-line `Enum.reduce/3` whose accumulator follows a
  known aggregation shape and rewrites it to the named `Enum` idiom that
  expresses the same intent.

  Unlike `ReduceMapPut` / `ReduceAsMap` (single-line `Map.put` / list
  builds) and `EnumReduceToSum` (the `+`/`0` sum case), this reads the
  whole lambda body and dispatches on the accumulation pattern.

      # group_by: Map.update with list-cons
      Enum.reduce(orders, %{}, fn order, acc ->
        Map.update(acc, order.customer_id, [order], fn existing -> [order | existing] end)
      end)
      ↓
      Enum.group_by(orders, fn order -> order.customer_id end)

      # frequencies_by: Map.update with +1
      Enum.reduce(events, %{}, fn event, acc ->
        Map.update(acc, event.type, 1, &(&1 + 1))
      end)
      ↓
      Enum.frequencies_by(events, fn event -> event.type end)

      # product_by: numeric accumulator with *
      Enum.reduce(factors, 1, fn factor, acc -> acc * factor.weight end)
      ↓
      Enum.product_by(factors, fn factor -> factor.weight end)

  ## Recognised shapes

  | Acc seed | Body shape                                   | Rewrite                                   |
  |----------|----------------------------------------------|-------------------------------------------|
  | `%{}`    | `Map.update(acc, key, [v], &[v \\| &1])`      | `Enum.group_by(coll, key_fun[, value_fun])` |
  | `%{}`    | `Map.update(acc, key, 1, &(&1 + 1))`         | `Enum.frequencies_by(coll, key_fun)`      |
  | `1`      | `acc * value` / `value * acc`                | `Enum.product_by(coll, value_fun)`        |

  The `+`/`0` **sum** case is deliberately *not* handled here — it is
  owned by `EnumReduceToSum`, which fires first and rewrites it to
  `Enum.sum/1` / `Enum.sum_by/2`. The single-line `Map.put` map-build is
  owned by `ReduceMapPut`. We only add the idioms those two don't cover.

  ## group_by ordering divergence (documented, not skipped)

  Per project policy a manual review follows every refactor, so the
  `group_by` case rewrites the 80% shape even though the bucket order
  differs:

  - `Map.update(acc, key, [v], &[v | &1])` **prepends** each element, so
    each bucket ends up in **reverse** input order.
  - `Enum.group_by/3` **appends**, so buckets keep **input** order.

  The set of keys and the multiset of members per bucket are identical;
  only the within-bucket order flips. This is almost always the intended
  semantics (the hand-rolled prepend is the idiomatic "fast" build and
  the order is incidental), so we rewrite and flag the divergence here
  rather than silently skipping. If within-bucket order is load-bearing,
  the human reviewer reverts.

  ## What we match

  - Direct call: `Enum.reduce(coll, seed, fn arg, acc -> body end)`.
  - Pipe stage: `coll |> Enum.reduce(seed, fn arg, acc -> body end)`.
  - Lambda: exactly one clause, two patterns `arg, acc`. The acc must be
    a bare variable; arg can be anything (destructure, pin, ...).
  - The body must be **exactly** the recognised expression (a lone
    `Map.update/4` or a single `*`). Extra statements or a second
    accumulator update fall through to `:skip` — that's the "more than
    the recognised shape" boundary, and we choose skip over guessing.
  - The `key_expr` / `value_expr` must reference at least one name the
    arg pattern introduces — otherwise the projection is constant and
    the rewrite would be misleading (a human should look).
  - The seed must match the idiom exactly: `%{}` for group_by /
    frequencies_by, `1` for product_by. A wrong seed (`Enum.reduce(coll,
    existing_map, ...)`, `Enum.reduce(coll, 2, ...)`) changes semantics
    and is left alone.

  ## Idempotence

  After a rewrite the call site is `Enum.group_by` / `Enum.frequencies_by`
  / `Enum.product_by`, none of which match our `Enum.reduce/3` head, so a
  second pass is a no-op.

  ## Why procedural

  ExAST's pattern language can't express "the lambda's `Map.update`
  second-arg/default/fun all line up into a group_by, AND `acc` matches
  the lambda's second pattern" without a custom guard. We walk the AST
  with `Macro.prewalker/1` and emit `Sourceror.Patch.replace/2` per
  match.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description,
    do: "Enum.reduce/3 aggregation lambdas -> Enum.group_by/frequencies_by/product_by"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `Enum.reduce(coll, %{}, fn x, acc -> Map.update(acc, k(x), ...) end)`
    is a named aggregation spelled out by hand — `group_by`,
    `frequencies_by` and `product_by` each name the operation directly,
    so the seed, the accumulator parameter and the `Map.update`
    bookkeeping all disappear behind the function name.

    One documented divergence: the `group_by` source prepends
    (`[v | &1]`), so its buckets are in reverse input order, whereas
    `Enum.group_by/3` appends and keeps input order. The keys and the
    per-bucket membership are identical; only within-bucket order flips.
    The hand-rolled prepend is the idiomatic fast build and the order is
    almost always incidental, so we rewrite and rely on the mandatory
    manual review to catch the rare case where bucket order matters.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 150
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

  # --- call-site matching -------------------------------------------------

  defp maybe_patch({{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [coll, seed, fun]} = node) do
    case classify(seed, fun) do
      {:ok, kind} -> [Patch.replace(node, render(kind, Sourceror.to_string(coll), :direct))]
      :skip -> []
    end
  end

  defp maybe_patch({{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [seed, fun]} = node) do
    case classify(seed, fun) do
      {:ok, kind} -> [Patch.replace(node, render(kind, nil, :pipe))]
      :skip -> []
    end
  end

  defp maybe_patch(_), do: []

  # --- classifier ---------------------------------------------------------

  defp classify(seed, {:fn, _, [{:->, _, [[arg_pat, acc_pat], body]}]}) do
    case bare_var(acc_pat) do
      {:ok, acc} -> classify_body(seed, arg_pat, acc, unwrap(body))
      :skip -> :skip
    end
  end

  defp classify(_, _), do: :skip

  defp classify_body(seed, arg_pat, acc, body) do
    cond do
      empty_map?(seed) -> classify_map_update(arg_pat, acc, body)
      one?(seed) -> classify_product(arg_pat, acc, body)
      true -> :skip
    end
  end

  # group_by / frequencies_by both ride Map.update/4.
  defp classify_map_update(
         arg_pat,
         acc,
         {{:., _, [{:__aliases__, _, [:Map]}, :update]}, _, [acc_ref, key, default, update_fun]}
       ) do
    with true <- refers_only_to?(acc_ref, acc),
         {:ok, kind, key_fun_extra} <- update_shape(default, update_fun, acc),
         true <- references_pattern?(arg_pat, key),
         false <- references_var?(key, acc) do
      {:ok, build_kind(kind, arg_pat, key, key_fun_extra)}
    else
      _ -> :skip
    end
  end

  defp classify_map_update(_, _, _), do: :skip

  # group_by: default `[v]`, update `&[v | &1]` / `fn e -> [v | e] end`.
  defp update_shape(default, update_fun, _acc) do
    with {:ok, seed_elem} <- singleton_list_elem(default),
         {:ok, cons_elem} <- cons_prepend_elem(update_fun),
         true <- ast_equal?(seed_elem, cons_elem) do
      {:ok, :group_by, seed_elem}
    else
      _ -> frequencies_shape(default, update_fun)
    end
  end

  # frequencies_by: default `1`, update `&(&1 + 1)` / `fn c -> c + 1 end`.
  defp frequencies_shape(default, update_fun) do
    if one?(default) and increment_fun?(update_fun),
      do: {:ok, :frequencies_by, nil},
      else: :skip
  end

  # product_by: seed `1`, body `acc * value` / `value * acc`.
  defp classify_product(arg_pat, acc, {:*, _, [lhs, rhs]}) do
    with {:ok, value} <- pick_other_operand(lhs, rhs, acc),
         true <- references_pattern?(arg_pat, value),
         false <- references_var?(value, acc) do
      {:ok, {:product_by, arg_pat, value}}
    else
      _ -> :skip
    end
  end

  defp classify_product(_, _, _), do: :skip

  # --- kind construction --------------------------------------------------

  # group_by emits an identity value-fun implicitly when the grouped
  # element is the bare arg; an explicit value-fun otherwise.
  defp build_kind(:group_by, arg_pat, key, value_elem) do
    if bare_arg_match?(arg_pat, value_elem),
      do: {:group_by, arg_pat, key, nil},
      else: {:group_by, arg_pat, key, value_elem}
  end

  defp build_kind(:frequencies_by, arg_pat, key, _extra),
    do: {:frequencies_by, arg_pat, key}

  # --- rendering ----------------------------------------------------------

  defp render({:group_by, arg_pat, key, nil}, coll_text, mode),
    do: emit("Enum.group_by", coll_text, mode, [key_fun(arg_pat, key)])

  defp render({:group_by, arg_pat, key, value_elem}, coll_text, mode),
    do:
      emit("Enum.group_by", coll_text, mode, [key_fun(arg_pat, key), key_fun(arg_pat, value_elem)])

  defp render({:frequencies_by, arg_pat, key}, coll_text, mode),
    do: emit("Enum.frequencies_by", coll_text, mode, [key_fun(arg_pat, key)])

  defp render({:product_by, arg_pat, value}, coll_text, mode),
    do: emit("Enum.product_by", coll_text, mode, [key_fun(arg_pat, value)])

  defp emit(fun_name, coll_text, :direct, fun_texts),
    do: "#{fun_name}(#{Enum.join([coll_text | fun_texts], ", ")})"

  defp emit(fun_name, _coll_text, :pipe, fun_texts),
    do: "#{fun_name}(#{Enum.join(fun_texts, ", ")})"

  defp key_fun(arg_pat, expr) do
    arg_text = Sourceror.to_string(arg_pat)
    expr_text = Sourceror.to_string(expr)
    "fn #{arg_text} -> #{expr_text} end"
  end

  # --- shape helpers ------------------------------------------------------

  defp unwrap({:__block__, _, [single]}), do: single
  defp unwrap(other), do: other

  defp empty_map?({:%{}, _, []}), do: true
  defp empty_map?(_), do: false

  defp one?(1), do: true
  defp one?({:__block__, _, [1]}), do: true
  defp one?(_), do: false

  defp singleton_list_elem({:__block__, _, [[elem]]}), do: {:ok, elem}
  defp singleton_list_elem([elem]), do: {:ok, elem}
  defp singleton_list_elem(_), do: :skip

  # `&[v | &1]` (capture) or `fn e -> [v | e] end`.
  defp cons_prepend_elem({:&, _, [body]}), do: capture_cons_elem(body)

  defp cons_prepend_elem({:fn, _, [{:->, _, [[acc_pat], body]}]}) do
    with {:ok, fold_acc} <- bare_var(acc_pat),
         {:ok, elem} <- prepend_list_elem(unwrap(body)),
         {:ok, tail} <- prepend_list_tail(unwrap(body)),
         true <- refers_only_to?(tail, fold_acc) do
      {:ok, elem}
    else
      _ -> :skip
    end
  end

  defp cons_prepend_elem(_), do: :skip

  defp capture_cons_elem(body) do
    with {:ok, elem} <- prepend_list_elem(unwrap(body)),
         {:ok, tail} <- prepend_list_tail(unwrap(body)),
         true <- capture_arg1?(tail) do
      {:ok, elem}
    else
      _ -> :skip
    end
  end

  defp prepend_list_elem([{:|, _, [elem, _tail]}]), do: {:ok, elem}
  defp prepend_list_elem({:__block__, _, [[{:|, _, [elem, _tail]}]]}), do: {:ok, elem}
  defp prepend_list_elem(_), do: :skip

  defp prepend_list_tail([{:|, _, [_elem, tail]}]), do: {:ok, tail}
  defp prepend_list_tail({:__block__, _, [[{:|, _, [_elem, tail]}]]}), do: {:ok, tail}
  defp prepend_list_tail(_), do: :skip

  defp capture_arg1?({:&, _, [1]}), do: true
  defp capture_arg1?(_), do: false

  # `&(&1 + 1)` (capture) or `fn c -> c + 1 end`.
  defp increment_fun?({:&, _, [body]}), do: capture_increment?(unwrap(body))

  defp increment_fun?({:fn, _, [{:->, _, [[acc_pat], body]}]}) do
    with {:ok, fold_acc} <- bare_var(acc_pat),
         {:+, _, [lhs, rhs]} <- unwrap(body) do
      plus_one_over?(lhs, rhs, fn node -> refers_only_to?(node, fold_acc) end)
    else
      _ -> false
    end
  end

  defp increment_fun?(_), do: false

  defp capture_increment?({:+, _, [lhs, rhs]}),
    do: plus_one_over?(lhs, rhs, &capture_arg1?/1)

  defp capture_increment?(_), do: false

  defp plus_one_over?(lhs, rhs, acc_pred?) do
    (acc_pred?.(lhs) and one?(rhs)) or (one?(lhs) and acc_pred?.(rhs))
  end

  defp pick_other_operand(lhs, rhs, acc) do
    case {refers_only_to?(lhs, acc), refers_only_to?(rhs, acc)} do
      {true, false} -> {:ok, rhs}
      {false, true} -> {:ok, lhs}
      _ -> :skip
    end
  end

  # --- var helpers --------------------------------------------------------

  defp refers_only_to?({name, _, ctx}, target)
       when is_atom(name) and is_atom(ctx),
       do: name == target

  defp refers_only_to?(_, _), do: false

  defp bare_arg_match?({name, _, ctx}, {name2, _, ctx2})
       when is_atom(name) and is_atom(ctx) and is_atom(name2) and is_atom(ctx2),
       do: name == name2 and not underscore?(name)

  defp bare_arg_match?(_, _), do: false

  defp references_pattern?(pat, expr),
    do:
      pat
      |> pattern_var_names()
      |> Enum.any?(&references_var?(expr, &1))

  defp references_var?(ast, target) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> name == target
      _ -> false
    end)
  end

  defp ast_equal?(a, b), do: strip_meta(a) == strip_meta(b)

  defp strip_meta(ast),
    do:
      Macro.prewalk(ast, fn
        {f, _meta, a} -> {f, [], a}
        other -> other
      end)

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
