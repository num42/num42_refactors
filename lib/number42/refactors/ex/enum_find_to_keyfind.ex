defmodule Number42.Refactors.Ex.EnumFindToKeyfind do
  @moduledoc """
  Rewrites `Enum.find(list, fn {k, _} -> k == key end)` over a list of
  tuples to `List.keyfind(list, key, 0)`.

      Enum.find(list, fn {k, _v} -> k == key end)          →  List.keyfind(list, key, 0)
      Enum.find(list, fn t -> elem(t, 1) == x end)         →  List.keyfind(list, x, 1)
      children |> Enum.find(fn {t, _, _} -> t == :price end) →  children |> List.keyfind(:price, 0)

  `List.keyfind/3` is the purpose-built function for "find the tuple
  whose Nth element equals this key" — the same job the hand-rolled
  lambda does, but without the closure and with the position stated
  explicitly. Both return `nil` on no match, so arity 3 is equivalent.

  ## Matched shape — exact by design

  The lambda must be single-clause, single-param, unguarded, and its
  body exactly one `==` comparison between the keyed element and a key
  expression. The keyed element is either:

  - a tuple-pattern destructure where exactly **one** element is bound
    and all others are wildcards (`fn {k, _} -> k == key end`,
    position = index of the binding), or
  - `elem(param, n)` with a literal integer `n`.

  The key side must not reference the lambda param (it is the looked-up
  value, constant w.r.t. iteration). `===` is skipped — `List.keyfind`
  compares with `==` semantics. Field access on the bound element
  (`fn {p, _} -> p.id == pid end`) compares a *projection*, not the
  element itself — not expressible as `keyfind`, skipped.

  ## Behavioral note

  `Enum.find` raises `FunctionClauseError` when an element doesn't
  match the tuple pattern; `List.keyfind` happily inspects tuples of
  any size and raises only on non-tuple elements. On homogeneous tuple
  lists — the shape this code is written for — the two agree.

  ## Idempotence

  `List.keyfind(...)` has no `Enum.find` node; a second pass matches
  nothing.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description,
    do: "Enum.find(list, fn {k, _} -> k == key end) -> List.keyfind(list, key, 0)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A hand-rolled `Enum.find` lambda that compares one tuple position
    against a key re-implements `List.keyfind/3`. The named function
    states the position explicitly, drops the closure, and reads as
    "find the entry keyed by this value" — which is what the lambda
    meant. Both return `nil` when nothing matches.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 130
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  @impl Number42.Refactors.Refactor
  def patches(ast, source, _opts), do: build_patches(ast, source)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast, source),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch(&1, source))

  # Enum.find(list, lambda)
  defp maybe_patch(
         {{:., _, [{:__aliases__, _, [:Enum]}, :find]}, _, [list, lambda]} = node,
         source
       ),
       do: node |> rewrite(list, lambda, source, :call)

  # list |> Enum.find(lambda)
  defp maybe_patch(
         {:|>, _, [list, {{:., _, [{:__aliases__, _, [:Enum]}, :find]}, _, [lambda]}]} = node,
         source
       ),
       do: node |> rewrite(list, lambda, source, :pipe)

  defp maybe_patch(_, _), do: []

  defp rewrite(node, list, lambda, source, form) do
    with {:ok, key, pos} <- keyed_comparison(lambda),
         {:ok, list_text} <- slice_node(source, list),
         {:ok, key_text} <- slice_node(source, key) do
      [Patch.replace(node, replacement(form, list_text, key_text, pos))]
    else
      _ -> []
    end
  end

  defp replacement(:pipe, list, key, pos), do: "#{list} |> List.keyfind(#{key}, #{pos})"
  defp replacement(:call, list, key, pos), do: "List.keyfind(#{list}, #{key}, #{pos})"

  # Single-clause, single-param, unguarded lambda whose body is one
  # `==` between the keyed element and a param-free key expression.
  defp keyed_comparison({:fn, _, [{:->, _, [[param], body]}]}) do
    with {:ok, bound, pattern_names} <- keyed_param(param) do
      comparison_key(body, bound, pattern_names)
    end
  end

  defp keyed_comparison(_), do: :skip

  # Tuple destructure: exactly one bound element, all others wildcards.
  defp keyed_param({:__block__, _, [inner]}), do: keyed_param(inner)
  defp keyed_param({a, b}), do: tuple_keyed_param([a, b])
  defp keyed_param({:{}, _, elems}), do: tuple_keyed_param(elems)

  # Bare param for the elem(param, n) form.
  defp keyed_param({name, _, ctx}) when is_atom(name) and is_atom(ctx),
    do: {:ok, {:elem_of, name}, MapSet.new([name])}

  defp keyed_param(_), do: :skip

  defp tuple_keyed_param(elems) do
    classified = elems |> Enum.map(&classify_element/1)
    bound = for {{:bound, name}, i} <- Enum.with_index(classified), do: {name, i}

    with false <- Enum.any?(classified, &(&1 == :other)),
         [{name, pos}] <- bound do
      {:ok, {:var, name, pos}, classified |> Enum.flat_map(&names_of/1) |> MapSet.new()}
    else
      _ -> :skip
    end
  end

  defp classify_element({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    if String.starts_with?(Atom.to_string(name), "_"),
      do: {:wildcard, name},
      else: {:bound, name}
  end

  defp classify_element(_), do: :other

  defp names_of({:bound, name}), do: [name]
  defp names_of({:wildcard, :_}), do: []
  defp names_of({:wildcard, name}), do: [name]

  defp comparison_key({:==, _, [lhs, rhs]}, bound, pattern_names) do
    case {element_position(lhs, bound), element_position(rhs, bound)} do
      {pos, :skip} when is_integer(pos) -> key_with_position(rhs, pos, pattern_names)
      {:skip, pos} when is_integer(pos) -> key_with_position(lhs, pos, pattern_names)
      _ -> :skip
    end
  end

  defp comparison_key(_, _, _), do: :skip

  defp element_position({name, _, ctx}, {:var, name, pos}) when is_atom(ctx), do: pos

  defp element_position({:elem, _, [{name, _, ctx}, n]}, {:elem_of, name}) when is_atom(ctx),
    do: literal_position(n)

  defp element_position(_, _), do: :skip

  defp literal_position({:__block__, _, [n]}) when is_integer(n) and n >= 0, do: n
  defp literal_position(n) when is_integer(n) and n >= 0, do: n
  defp literal_position(_), do: :skip

  defp key_with_position(key, pos, pattern_names) do
    if key |> used_var_names() |> MapSet.disjoint?(pattern_names),
      do: {:ok, key, pos},
      else: :skip
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
