defmodule Num42.Refactors.Refactors.ExtractIntraModuleClone do
  @moduledoc """
  Within-module clone detector and rewriter.

  Two `def`/`defp` clauses in the same module with identical bodies
  (same arity, same body AST modulo metadata and variable renaming)
  collapse into one: the **first** clause in source order keeps its
  body; every later duplicate is rewritten to a one-liner that calls
  the first.

      # before
      defmodule MyApp.Items do
        def alpha(x, y) do
          x |> Kernel.+(y) |> Kernel.*(2)
        end

        def beta(x, y) do
          x |> Kernel.+(y) |> Kernel.*(2)
        end
      end

      # after
      defmodule MyApp.Items do
        def alpha(x, y) do
          x |> Kernel.+(y) |> Kernel.*(2)
        end

        def beta(x, y), do: alpha(x, y)
      end

  ## Why "first wins"

  Picking the first clause in source order is deterministic, doesn't
  invent a new name (so no collision search), and keeps a familiar
  call site for whichever function existed first historically. The
  collapsed clauses become trivial wrappers that reviewers can
  notice at a glance.

  ## What is skipped

  - Single occurrence of a body — no clone, nothing to do.
  - Different arities — `f(x)` ≠ `g(x, y)`, no compatible call.
  - Body references a module attribute — not analysed here; the
    cross-module variant `ExtractSharedModule` is also conservative
    about this.
  - Loser head is not plain-var (e.g. `def f(%Foo{} = x)`) — we'd
    have to invent vars and lose the pattern match. Leave alone.
  - Loser head has a guard — would need to replicate guards in the
    wrapper or evaluate them; leave alone.
  - Loser is multi-clause — collapsing per-clause works only when
    the call site can target the same `{name, arity}` of the source
    function, which gets fiddly. Out of scope for v1.
  - Body mass below `:min_mass` (default 20) — micro-clones add
    noise without benefit.
  """

  use Num42.Refactors.Refactor

  @default_min_mass 20

  @impl Num42.Refactors.Refactor
  def description, do: "Within-module clone collapse: extra clauses delegate to the first"

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    When two functions in the same module share an identical body,
    keep the first as the source of truth and rewrite the others to
    `def loser(args), do: source(args)`. Skips pattern-matched and
    guarded heads, multi-clause functions, module-attribute users,
    and bodies below the configured `:min_mass` (default 20).
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Num42.Refactors.Refactor
  def transform(source, opts) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)

    Sourceror.parse_string(source) |> apply_to_parse_result(min_mass, source)
  end

  defp apply_to_ast(ast, source, min_mass) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [_name_ast, [{_do, body}]]} ->
        body
        |> body_to_exprs()
        |> patches_for_module(min_mass)

      _ ->
        []
    end)
    |> patch_or_passthrough(source)
  end

  defp patches_for_module(body_exprs, min_mass) do
    clauses = body_exprs |> Enum.filter(&def_clause?/1)

    multi_clause_keys = multi_clause_keys(clauses)

    eligible =
      clauses
      |> Enum.reject(&MapSet.member?(multi_clause_keys, name_arity(&1)))
      |> Enum.reject(&body_uses_module_attribute?/1)
      |> Enum.filter(&(clause_mass(&1) >= min_mass))

    eligible
    |> Enum.group_by(fn c -> {arity_of(c), body_hash(c)} end)
    |> Enum.flat_map(fn {_key, group} ->
      case group do
        [_only] ->
          []

        [source | losers] ->
          source_name = name_of(source)
          losers |> Enum.flat_map(&patch_for_loser(&1, source_name))
      end
    end)
  end

  defp def_clause?({kind, _, [_head, body_kw]}) when kind in [:def, :defp] and is_list(body_kw),
    do: true

  defp def_clause?(_), do: false

  defp multi_clause_keys(clauses) do
    clauses
    |> Enum.group_by(&name_arity/1)
    |> Enum.filter(fn {_k, list} -> length(list) > 1 end)
    |> Enum.map(fn {k, _} -> k end)
    |> MapSet.new()
  end

  defp name_arity(clause), do: {name_of(clause), arity_of(clause)}

  defp name_of({kind, _, [head | _]}) when kind in [:def, :defp] do
    strip_when(head) |> name_atom_or_nil()
  end

  defp arity_of({kind, _, [head | _]}) when kind in [:def, :defp] do
    strip_when(head) |> arity_of_head()
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp head_has_guard?({_kind, _, [{:when, _, _} | _]}), do: true
  defp head_has_guard?(_), do: false

  defp head_is_plain_vars?({_kind, _, [head | _]}) do
    case strip_when(head) do
      ^head -> args_are_plain_vars?(head)
      _ -> false
    end
  end

  defp args_are_plain_vars?({_name, _, args}) when is_list(args),
    do: args |> Enum.all?(&plain_var?/1)

  defp args_are_plain_vars?({_name, _, nil}), do: true
  defp args_are_plain_vars?(_), do: false

  defp plain_var?({:\\, _, _}), do: false

  defp plain_var?({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    not underscore?(name)
  end

  defp plain_var?(_), do: false

  defp body_uses_module_attribute?({_kind, _, [_head, body_kw]}),
    do:
      body_kw
      |> Keyword.values()
      |> Enum.any?(&references_attribute?/1)

  defp references_attribute?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:@, _, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) -> true
      _ -> false
    end)
  end

  defp clause_mass({_kind, _, [_head, body_kw]}),
    do: body_kw |> Keyword.values() |> Enum.map(&node_count/1) |> Enum.sum()

  defp node_count(ast) do
    {_, count} = Macro.prewalk(ast, 0, fn node, acc -> {node, acc + 1} end)
    count
  end

  defp body_hash({_kind, _, [_head, body_kw]}),
    do:
      body_kw
      |> Keyword.values()
      |> Enum.map(&strip_meta/1)
      |> rename_vars()
      |> :erlang.phash2()

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp rename_vars(ast) do
    {result, _} = Macro.prewalk(ast, %{}, &rename_var_node/2)
    result
  end

  defp rename_var_node({name, [], ctx} = node, acc)
       when is_atom(name) and is_atom(ctx) do
    cond do
      underscore?(name) ->
        {node, acc}

      Map.has_key?(acc, name) ->
        {{:"$var", [], [Map.fetch!(acc, name)]}, acc}

      true ->
        idx = map_size(acc)
        {{:"$var", [], [idx]}, Map.put(acc, name, idx)}
    end
  end

  defp rename_var_node(node, acc), do: {node, acc}

  defp patch_for_loser(loser_clause, source_name) do
    cond do
      head_has_guard?(loser_clause) ->
        []

      not head_is_plain_vars?(loser_clause) ->
        []

      true ->
        replacement = render_replacement(loser_clause, source_name)
        clause_replacement_patch(loser_clause, replacement)
    end
  end

  defp render_replacement({kind, _, [head | _]}, source_name) do
    {_name, _, args} = strip_when(head)
    arg_names = (args || []) |> Enum.map(fn {n, _, _} -> n end)
    arg_list = arg_names |> Enum.join(", ")

    "#{kind} #{name_for_kind(kind, head)}(#{arg_list}), do: #{source_name}(#{arg_list})"
  end

  defp name_for_kind(_kind, head) do
    {name, _, _} = strip_when(head)
    name
  end

  defp clause_replacement_patch(clause, replacement),
    do: Sourceror.get_range(clause) |> patch_for_range(replacement)

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp apply_to_parse_result({:ok, ast}, min_mass, source),
    do: ast |> apply_to_ast(source, min_mass)

  defp apply_to_parse_result({:error, _}, _min_mass, source), do: source

  defp name_atom_or_nil({name, _, _}) when is_atom(name), do: name
  defp name_atom_or_nil(_), do: nil

  defp arity_of_head({_, _, args}) when is_list(args), do: length(args)
  defp arity_of_head({_, _, nil}), do: 0
  defp arity_of_head(_), do: -1

  defp patch_for_range(%{end: end_pos, start: start_pos}, replacement),
    do: [%{change: replacement, range: %{end: end_pos, start: start_pos}}]

  defp patch_for_range(_, _replacement), do: []
end
