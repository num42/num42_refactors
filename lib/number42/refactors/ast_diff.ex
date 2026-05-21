defmodule Number42.Refactors.AstDiff do
  @moduledoc """
  N-ary parallel walk over AST clauses with identical skeleton-hash,
  producing a single skeleton AST plus a list of **holes** — the points
  where the inputs differ.

  Used by Type-II clone refactors (`ExtractParametricClone`) that have
  already bucketed clauses by structural shape and now need to know
  *what* differs at each leaf so the differences can be turned into
  helper parameters.

  ## Why a parallel walk and not Tai/Zhang-Shasha tree edit distance?

  Type-II clones are **structurally isomorphic** by construction —
  they share an AST skeleton, only literal values differ. A
  point-by-point synchronous walk over N ASTs is O(n × N) and produces
  a clean per-position diff. Real tree-edit-distance algorithms are
  O(n^4) and would only matter for Type-III (near-miss) clones, which
  are out of scope here.

  ## Hole classification

  | Hole content                       | `kind`     |
  | ---------------------------------- | ---------- |
  | All N reine Literale               | `:literal` |
  | All N Listen/Tupel/Maps von Lits   | `:data`    |
  | Sonst (Calls, Vars, Attrs, Misch)  | `:expr`    |

  Every hole is parametrised — the divergent subtree is passed as a
  helper argument at the call-site. The compiler is the source of
  truth for whether the resulting code is well-formed (e.g. Ecto.Query
  macros require compile-time keyword keys; if a key gets parametrised,
  the compile fails — that is a real signal, not something this layer
  pre-filters away).

  ## Result shape

      %{
        skeleton: ast,                       # first AST with holes
        holes: [%{                           # one entry per divergence
          path: [non_neg_integer],           # walk index in pre-order
          values: [ast],                     # one AST per input clause
          kind: :literal | :data | :expr
        }]
      }
  """

  @type kind :: :literal | :data | :expr
  @type hole :: %{kind: kind(), path: [non_neg_integer()], values: [term()]}

  @type result :: %{
          holes: [hole()],
          skeleton: term()
        }

  @doc """
  Diff a list of N (≥ 2) AST clauses.

  Same semantics as the 2-arg form, generalised to bucket groups with
  more than two clones.
  """
  @spec tree_diff([term()]) :: result()
  def tree_diff([_first | _] = ast_diffs) when length(ast_diffs) >= 2 do
    {skeleton, holes} = walk(ast_diffs, [], [])
    %{holes: holes |> Enum.reverse(), skeleton: skeleton}
  end

  @doc """
  Diff two AST trees, returning their shared skeleton and the holes
  where they diverge.

  Pre-condition: both inputs have the same
  `replace_literals_with_holes` hash. Without that, this function will
  likely report a complex hole at the first structural divergence —
  correct, just wasteful.
  """
  @spec tree_diff(term(), term()) :: result()
  def tree_diff(a, b), do: tree_diff([a, b])
  defp all_literal_nodes?(nodes), do: nodes |> Enum.all?(&literal_node?/1)

  defp all_strip_eq?(nodes) do
    [first | rest] = nodes
    stripped_first = strip(first)
    rest |> Enum.all?(&(strip(&1) == stripped_first))
  end

  defp build_hole(values, path), do: %{kind: classify(values), path: path, values: values}

  defp classify(values) do
    cond do
      values |> Enum.all?(&literal_node?/1) -> :literal
      values |> Enum.all?(&data_node?/1) -> :data
      true -> :expr
    end
  end

  defp data_node?(node) do
    case node do
      list when is_list(list) ->
        list |> Enum.all?(&(literal_node?(&1) or data_node?(&1)))

      {:__block__, _, [list]} when is_list(list) ->
        list |> Enum.all?(&(literal_node?(&1) or data_node?(&1)))

      {:{}, _, args} when is_list(args) ->
        args |> Enum.all?(&(literal_node?(&1) or data_node?(&1)))

      {:%{}, _, pairs} when is_list(pairs) ->
        pairs
        |> Enum.all?(fn {k, v} ->
          (literal_node?(k) or data_node?(k)) and (literal_node?(v) or data_node?(v))
        end)

      _ ->
        false
    end
  end

  defp descend([{form, meta, args} | _] = nodes, path, holes_acc) when is_list(args) do
    children_per_node = nodes |> Enum.map(fn {_, _, a} -> a end)

    # Walk argument lists in parallel position-by-position.
    {new_args, holes_acc} =
      walk_lists(children_per_node, path ++ [:args], 0, holes_acc)

    {{form, meta, new_args}, holes_acc}
  end

  defp descend([list | _] = nodes, path, holes_acc) when is_list(list) do
    walk_lists(nodes, path, 0, holes_acc)
  end

  defp descend([{_a, _b} | _] = nodes, path, holes_acc) do
    # 2-tuple — walk each side in parallel.
    lefts = nodes |> Enum.map(fn {l, _} -> l end)
    rights = nodes |> Enum.map(fn {_, r} -> r end)

    {new_left, holes_acc} = walk(lefts, path ++ [0], holes_acc)
    {new_right, holes_acc} = walk(rights, path ++ [1], holes_acc)

    {{new_left, new_right}, holes_acc}
  end

  defp descend([tuple | _] = nodes, path, holes_acc) when is_tuple(tuple) do
    # General N-tuple — walk each component.
    sizes = nodes |> Enum.map(&tuple_size/1)
    [size | _] = sizes

    if sizes |> Enum.all?(&(&1 == size)) do
      {new_components, holes_acc} =
        0..(size - 1)
        |> Enum.reduce({[], holes_acc}, fn i, {acc, h} ->
          components = nodes |> Enum.map(&elem(&1, i))
          {new, h} = walk(components, path ++ [i], h)
          {[new | acc], h}
        end)

      {List.to_tuple(new_components |> Enum.reverse()), holes_acc}
    else
      hole = build_hole(nodes, path)
      {placeholder(path), [hole | holes_acc]}
    end
  end

  defp descend([first | _] = nodes, path, holes_acc) do
    # Leaf-shape divergence we couldn't classify as a structural
    # descent. Treat as a hole.
    if nodes |> Enum.all?(&(&1 == first)) do
      {first, holes_acc}
    else
      hole = build_hole(nodes, path)
      {placeholder(path), [hole | holes_acc]}
    end
  end

  defp literal_node?({:__block__, _, [v]})
       when is_atom(v) or is_integer(v) or is_float(v) or is_binary(v),
       do: true

  defp literal_node?(_), do: false
  defp placeholder(path), do: {:"$hole", [], [path]}

  defp same_3tuple_shape?({form_a, _, args_a}, {form_b, _, args_b}),
    do: same_form?(form_a, form_b) and same_args_shape?(args_a, args_b)

  defp same_args_shape?(args_a, args_b)
       when is_list(args_a) and is_list(args_b),
       do: length(args_a) == length(args_b)

  defp same_args_shape?(args_a, args_b),
    do: args_a == args_b or is_atom(args_a) == is_atom(args_b)

  defp same_form?(form_a, form_b), do: strip(form_a) == strip(form_b)

  defp same_outer_shape?([first | rest]) do
    cond do
      is_tuple(first) and tuple_size(first) == 3 ->
        rest |> Enum.all?(fn n -> tuple3?(n) and same_3tuple_shape?(first, n) end)

      is_tuple(first) and tuple_size(first) == 2 ->
        rest |> Enum.all?(fn n -> is_tuple(n) and tuple_size(n) == 2 end)

      is_tuple(first) ->
        size = tuple_size(first)
        rest |> Enum.all?(fn n -> is_tuple(n) and tuple_size(n) == size end)

      is_list(first) ->
        len = length(first)
        rest |> Enum.all?(fn n -> is_list(n) and length(n) == len end)

      true ->
        false
    end
  end

  defp strip(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) -> {form, [], args}
      other -> other
    end)
  end

  defp tuple3?(t), do: is_tuple(t) and tuple_size(t) == 3

  defp walk(nodes, path, holes_acc) do
    [first | _] = nodes

    cond do
      all_strip_eq?(nodes) ->
        # Every input has structurally identical AST at this position.
        # Take the first verbatim — no descent needed, no hole.
        {first, holes_acc}

      all_literal_nodes?(nodes) ->
        # All N are Sourceror-wrapped literals (atom/int/float/string/
        # bool/nil) but their *values* differ. This is exactly a
        # parametric-clone hole — classify as :literal regardless of
        # the inner-list-mismatch the walker would otherwise descend
        # into (`{:__block__, _, [true]}` vs `{:__block__, _, [false]}`
        # share outer shape but the structural walk would split the
        # bool atoms incorrectly).
        hole = build_hole(nodes, path)
        {placeholder(path), [hole | holes_acc]}

      same_outer_shape?(nodes) ->
        # Same form/arity at the outer level — descend into children
        # and recurse position-by-position.
        descend(nodes, path, holes_acc)

      true ->
        # Divergent shape. This is a hole. Classify by content.
        hole = build_hole(nodes, path)
        {placeholder(path), [hole | holes_acc]}
    end
  end

  defp walk_lists(walked_lists, base_path, index, holes_acc) do
    [first | _] = walked_lists

    cond do
      first == [] and Enum.all?(walked_lists, &(&1 == [])) ->
        {[], holes_acc}

      first == [] or Enum.any?(walked_lists, &(&1 == [])) ->
        # Length mismatch — would have been caught at outer level by
        # same_outer_shape? Defensive: emit hole.
        hole = build_hole(walked_lists, base_path ++ [index])
        {placeholder(base_path ++ [index]), [hole | holes_acc]}

      true ->
        heads = walked_lists |> Enum.map(&hd/1)
        tails = walked_lists |> Enum.map(&tl/1)

        {new_head, holes_acc} = walk(heads, base_path ++ [index], holes_acc)
        {new_tail, holes_acc} = walk_lists(tails, base_path, index + 1, holes_acc)

        {[new_head | new_tail], holes_acc}
    end
  end
end
