defmodule Number42.Refactors.Ex.MergePipelineIntoComprehension do
  @moduledoc """
  Rewrites a `coll |> Enum.filter(pred) |> Enum.map(f)` pipeline into a
  single `for` comprehension:

      coll
      |> Enum.filter(& &1.active)
      |> Enum.map(& &1.id)
      ↓
      for x <- coll, x.active, do: x.id

  In the result, `x.active` is a **normal `for` filter expression**, not
  a guard — `for` filters accept arbitrary expressions, so the rewrite
  is not restricted to guard-safe predicates.

  ## Why this is only sound for pure `pred` and `f`

  `Enum.filter |> Enum.map` evaluates **all** predicates first, then maps
  the survivors — two full passes. A `for` comprehension **interleaves**:
  it tests `pred(x)` and, on success, computes `f(x)` for each element in
  turn. With side effects the difference is observable (interleaved vs.
  batched effects, and `f` is never reached for a raising/short-circuiting
  `pred`). So we fuse **only** when both the predicate body and the map
  body are `AstHelpers.pure?/1` — total, exception-free, eager. Anything
  impure is left for a human (mirrors `FlatMapToFilter` deferring the
  `filter + map` shape).

  ## The reject variant

  `coll |> Enum.reject(p) |> Enum.map(m)` fuses the same way with the
  filter negated: `for x <- coll, !p(x), do: m(x)`. The negation uses
  `Kernel.!/1`, **not** `Kernel.not/1` — `Enum.reject` drops elements
  whose predicate returns any *truthy* value, and `!` preserves exactly
  that truthiness semantics where strict-boolean `not` would raise on a
  `nil` predicate result. Predicates rooted in a binary/unary operator
  are parenthesized (`!(x > 0)`) so the `!` never re-associates.

  ## What we match

  - Host: `coll |> Enum.filter(p) |> Enum.map(m)` (or `Enum.reject`) —
    the canonical two-stage pipe, `Enum` exactly (aliased `MyEnum` is
    left alone).
  - `coll` must **not itself be a pipe** — fusing `a |> b() |> filter |>
    map` would emit a pipe inside the generator head, which reads worse
    than the original. Leave it for the user to pre-extract a binding.
  - Each of `p`/`m` is either an anonymous capture whose body uses only
    `&1` (`& &1.active`), or a single-clause, single-bare-var-arg,
    no-guard, single-expression lambda (`fn x -> x.active end`).
  - Function-reference captures (`&active?/1`) have no body to inline and
    are declined.

  ## Capture-collision-safe inlining

  Both bodies are rebound to **one** shared generator variable. The name
  is chosen so it cannot capture an outer variable referenced by either
  body — if a candidate name appears free in the other body, a fresh
  `x`, `x1`, `x2`, … is used instead.

  ## Idempotence

  After the rewrite the call site is a `for` comprehension with no
  `Enum.filter |> Enum.map` chain. A second pass matches nothing.

  ## Out of scope

  - `quote do … end` blocks — template AST, not code to transform.
  - Module-alias resolution — an `alias SomeLib.Enum` would be rewritten;
    the AST-only match cannot tell it from the stdlib `Enum`.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  # Synthetic binding atom assigned to an inlined `&1` capture before the
  # final generator name is chosen.
  @capture_slot :"$captured"

  @impl Number42.Refactors.Refactor
  def description,
    do: "coll |> Enum.filter/reject(pred) |> Enum.map(f) -> for x <- coll, [!]pred(x), do: f(x)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A `coll |> Enum.filter(pred) |> Enum.map(f)` pipeline is two passes
    over the data that a single `for x <- coll, pred(x), do: f(x)`
    expresses in one — the comprehension head reads as "for each kept
    element, produce f of it", which is the intent.

    The rewrite is gated on purity. `filter |> map` evaluates every
    predicate, then maps the survivors; a comprehension interleaves the
    two per element. With pure `pred` and `f` the two are observably
    identical, so the fusion is safe. With side effects (IO, message
    sends, raising calls, lazy streams) the interleaving is observable,
    so we decline and leave the pipeline for a human — the same stance
    `FlatMapToFilter` takes on the `filter + map` shape it won't touch.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: source |> Sourceror.parse_string() |> apply_patches(source)

  defp apply_patches({:ok, ast}, source),
    do: ast |> walk_for_patches() |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp build_for(coll, {pred_var, pred_body}, {map_var, map_body}, op) do
    binding = choose_binding(pred_var, pred_body, map_var, map_body)
    coll_str = coll |> render()

    pred_str =
      pred_body |> rebind(pred_var, binding) |> render() |> apply_polarity(op, pred_body)

    map_str = map_body |> rebind(map_var, binding) |> render()

    {:ok, "for #{binding} <- #{coll_str}, #{pred_str}, do: #{map_str}"}
  end

  defp apply_polarity(pred_str, :filter, _pred_ast), do: pred_str

  defp apply_polarity(pred_str, :reject, pred_ast),
    do: if(operator_root?(pred_ast), do: "!(#{pred_str})", else: "!#{pred_str}")

  defp operator_root?({op, _, args}) when is_atom(op) and is_list(args),
    do: Macro.operator?(op, length(args))

  defp operator_root?(_), do: false

  defp candidate_name(0), do: :x
  defp candidate_name(n), do: String.to_atom("x#{n}")
  defp children_of({_form, _meta, args}) when is_list(args), do: args
  defp children_of(_), do: []
  # Reuse a lambda's own parameter as the generator binding when it is a
  # real name (not a `&1` capture slot) and is not read free by the other
  # body — where it would be a different, outer variable. Otherwise pick a
  # fresh name guaranteed unused by either body.
  defp choose_binding(pred_var, pred_body, map_var, map_body) do
    reads = MapSet.union(reads_of(pred_var, pred_body), reads_of(map_var, map_body))

    cond do
      real_binding?(pred_var) and not MapSet.member?(reads, pred_var) ->
        pred_var

      real_binding?(map_var) and not MapSet.member?(reads, map_var) ->
        map_var

      true ->
        0
        |> Stream.iterate(&(&1 + 1))
        |> Stream.map(&candidate_name/1)
        |> Enum.find(&(not MapSet.member?(reads, &1)))
    end
  end

  defp fuse(coll, pred_fun, map_fun, op) do
    with false <- pipe?(coll),
         {:ok, pred} <- inlinable(pred_fun),
         {:ok, map} <- inlinable(map_fun),
         true <- pure?(elem(pred, 1)),
         true <- pure?(elem(map, 1)) do
      build_for(coll, pred, map, op)
    else
      _ -> :skip
    end
  end

  defp handle_maybe_patch_fuse({:ok, replacement}, node), do: [Patch.replace(node, replacement)]
  defp handle_maybe_patch_fuse(:skip, _node), do: []
  # Capture whose body uses only `&1`: inline to the synthetic slot.
  defp inlinable({:&, _, [{:/, _, [_, _]}]}), do: :skip

  defp inlinable({:&, _, [body]}) do
    case rebind_capture(body) do
      {:ok, rewritten} -> {:ok, {@capture_slot, rewritten}}
      :skip -> :skip
    end
  end

  # Single-clause, single bare-var arg, no guard, single-expression body.
  defp inlinable({:fn, _, [{:->, _, [[arg], body]}]}) do
    with {:ok, name} <- bare_var(arg),
         [single] <- body_to_exprs(body) do
      {:ok, {name, single}}
    else
      _ -> :skip
    end
  end

  defp inlinable(_), do: :skip

  defp maybe_patch(
         {:|>, _,
          [
            {:|>, _, [coll, {{:., _, [{:__aliases__, _, [:Enum]}, op]}, _, [pred_fun]}]},
            {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [map_fun]}
          ]} = node
       )
       when op in [:filter, :reject],
       do: fuse(coll, pred_fun, map_fun, op) |> handle_maybe_patch_fuse(node)

  defp maybe_patch(_), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
  defp pipe?({:|>, _, _}), do: true
  defp pipe?(_), do: false
  # Names read free by a body, with the body's own param removed (it is
  # the thing being renamed to the generator binding).
  defp reads_of(param, body), do: body |> used_var_names() |> MapSet.delete(param)
  defp real_binding?(@capture_slot), do: false
  defp real_binding?(name) when is_atom(name), do: true

  defp rebind(ast, from, to) when is_atom(from) and is_atom(to) do
    Macro.prewalk(ast, fn
      {^from, meta, ctx} when is_atom(ctx) -> {to, meta, ctx}
      other -> other
    end)
  end

  # `&1` -> the synthetic slot var; `&2`+ means multi-arg, not fusable.
  defp rebind_capture(body) do
    {rewritten, ok?} =
      Macro.prewalk(body, true, fn
        {:&, _, [n]}, _acc when is_integer(n) and n > 1 -> {nil, false}
        {:&, m, [1]}, acc -> {{@capture_slot, m, nil}, acc}
        other, acc -> {other, acc}
      end)

    if ok?, do: {:ok, rewritten}, else: :skip
  end

  defp render(ast), do: ast |> strip_comments() |> Sourceror.to_string()

  defp strip_comments(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        {form, Keyword.drop(meta, [:leading_comments, :trailing_comments]), args}

      other ->
        other
    end)
  end

  # Manual walk so we can prune `quote` subtrees (template AST, not code).
  defp walk_for_patches({:quote, _, _}), do: []

  defp walk_for_patches({_, _, _} = node),
    do: maybe_patch(node) ++ (node |> children_of() |> Enum.flat_map(&walk_for_patches/1))

  defp walk_for_patches(list) when is_list(list), do: list |> Enum.flat_map(&walk_for_patches/1)

  defp walk_for_patches({left, right}),
    do: walk_for_patches(left) ++ walk_for_patches(right)

  defp walk_for_patches(_), do: []
end
