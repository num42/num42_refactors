defmodule Number42.Refactors.Ex.ExtractLambdaBlock do
  @moduledoc """
  Extract a duplicated anonymous-function body into a private helper
  inside the same module, then replace every clone with a `&helper/n`
  capture.

      # before
      defmodule MyApp.Pricing do
        def first(items) do
          Enum.map(items, fn item ->
            x = compute(item)
            y = transform(x)
            %{item: item, score: y}
          end)
        end

        def second(items) do
          Enum.map(items, fn item ->
            x = compute(item)
            y = transform(x)
            %{item: item, score: y}
          end)
        end
      end

      # after
      defmodule MyApp.Pricing do
        def first(items) do
          Enum.map(items, &extracted_lambda/1)
        end

        def second(items) do
          Enum.map(items, &extracted_lambda/1)
        end

        defp extracted_lambda(item) do
          x = compute(item)
          y = transform(x)
          %{item: item, score: y}
        end
      end

  ## What is skipped

  - A lambda that occurs only once — no clone, nothing to extract.
  - Lambda body references a variable that is not one of its own
    parameters (closure over an outer-scope binding). Promoting it to
    a `defp` would lose that binding; conservative skip.
  - Lambda body mass below `:min_mass` (default 20) — micro-clones
    add noise without benefit.
  - Multi-clause lambdas (`fn :a -> ... ; :b -> ... end`). Out of
    scope for v1 — would need clause-by-clause matching.
  - Lambda body references a module attribute. Out of scope for v1.
  - The helper name `extracted_lambda` already exists in the module
    with a different shape. Skip rather than disambiguate.
  """

  use Number42.Refactors.Refactor

  @default_min_mass 20
  @helper_name :extracted_lambda

  @impl Number42.Refactors.Refactor
  def description, do: "Extract duplicated anonymous-function bodies into a shared private helper"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    When a lambda's body appears twice or more in the same module
    (most often in `Enum.map`/`Enum.reduce` over similar collections),
    synthesise `defp extracted_lambda(args), do: body` and replace
    every clone with `&extracted_lambda/n`. Skips multi-clause
    lambdas, closure-bearing bodies, and bodies below `:min_mass`.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)

    Sourceror.parse_string(source) |> apply_to_parse_result(min_mass, source)
  end

  defp apply_to_ast(ast, source, min_mass) do
    plans =
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&plans_for_node(&1, min_mass))

    case plans do
      [] ->
        source

      _ ->
        callsite_patches = plans |> Enum.flat_map(& &1.callsite_patches)
        helpers = plans |> Enum.map(& &1.helper_text)

        source
        |> patch_or_passthrough(callsite_patches)
        |> splice_helpers_before_module_end(helpers)
    end
  end

  defp plans_for_node({:defmodule, _, [_name_ast, [{_do, body}]]}, min_mass),
    do: body |> body_to_exprs() |> plans_for_module(min_mass)

  defp plans_for_node(_node, _min_mass), do: []

  defp apply_to_parse_result({:ok, ast}, min_mass, source),
    do: ast |> apply_to_ast(source, min_mass)

  defp apply_to_parse_result({:error, _}, _min_mass, source), do: source

  defp capture_replacement_patch(%{arity: arity, ast: lambda}, arity),
    do: Sourceror.get_range(lambda) |> replacement_patch(arity)

  defp capture_replacement_patch(_lambda, _arity), do: nil

  defp collect_lambdas(body_exprs),
    do:
      body_exprs
      |> Enum.filter(&def_clause?/1)
      |> Enum.flat_map(&lambdas_in_clause/1)

  defp def_clause?({kind, _, [_head, body_kw]}) when kind in [:def, :defp] and is_list(body_kw),
    do: true

  defp def_clause?(_), do: false

  defp has_outer_free_vars?(body, lambda_args) do
    bound = bound_in(body)

    body
    |> Macro.prewalker()
    |> Enum.any?(&free_var_node?(&1, bound, lambda_args))
  end

  defp free_var_node?({name, _, ctx}, bound, lambda_args)
       when is_atom(name) and is_atom(ctx) do
    not underscore?(name) and
      name not in [:__MODULE__, :__CALLER__, :__ENV__] and
      not MapSet.member?(bound, name) and
      not MapSet.member?(lambda_args, name)
  end

  defp free_var_node?(_node, _bound, _lambda_args), do: false

  defp helper_name_taken?(body_exprs) do
    body_exprs
    |> Enum.any?(fn
      {kind, _, [head | _]} when kind in [:def, :defp] ->
        case strip_when(head) do
          {name, _, _} when is_atom(name) -> name == @helper_name
          _ -> false
        end

      _ ->
        false
    end)
  end

  defp indent_body(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> "    " <> line end)
  end

  defp lambda_arg_names(arg_names) do
    arg_names
    |> Enum.reduce_while([], fn
      {n, _, ctx}, acc when is_atom(n) and is_atom(ctx) ->
        if underscore?(n), do: {:halt, :error}, else: {:cont, [n | acc]}

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      :error -> :error
      list -> list |> Enum.reverse()
    end
  end

  defp lambda_hash(args, body),
    do:
      {strip_meta({args, body}) |> rename_vars()}
      |> :erlang.phash2()

  defp lambdas_in_clause({_kind, _, [_head, body_kw]}) do
    body_kw
    |> Keyword.values()
    |> Enum.flat_map(fn body ->
      body
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_extract_lambda/1)
    end)
  end

  defp maybe_extract_lambda({:fn, _meta, [{:->, _arrow_meta, [args, body]}]} = lambda)
       when is_list(args) do
    arg_names = lambda_arg_names(args)

    cond do
      # Multi-clause lambdas (more than one `->`) won't reach this
      # clause because the wrapping `[{:->, ...}]` list has length 1.
      arg_names == :error ->
        []

      references_attribute?(body) ->
        []

      true ->
        available = MapSet.new(arg_names)
        free = free_vars(body, available)

        if free == [] or MapSet.subset?(MapSet.new(free), available) do
          [
            %{
              args: arg_names,
              arity: length(arg_names),
              ast: lambda,
              body: body,
              has_closure?: has_outer_free_vars?(body, available),
              hash: lambda_hash(args, body),
              mass: node_count(body)
            }
          ]
        else
          []
        end
    end
  end

  defp maybe_extract_lambda(_), do: []

  defp node_count(ast) do
    {_, count} = Macro.prewalk(ast, 0, fn node, acc -> {node, acc + 1} end)
    count
  end

  defp patch_or_passthrough(source, []), do: source
  defp patch_or_passthrough(source, patches), do: Sourceror.patch_string(source, patches)

  defp plan_for_group([first | _] = group) do
    callsite_patches =
      group
      |> Enum.map(&capture_replacement_patch(&1, first.arity))
      |> Enum.reject(&is_nil/1)

    helper_text = render_helper_text(first.args, first.body)

    [%{callsite_patches: callsite_patches, helper_text: helper_text}]
  end

  defp plan_for_hash_group([_only]), do: []
  defp plan_for_hash_group(group), do: plan_for_group(group)

  defp plans_for_module(body_exprs, min_mass) do
    helper_taken? = helper_name_taken?(body_exprs)

    if helper_taken? do
      []
    else
      lambda = collect_lambdas(body_exprs)

      lambda
      |> Enum.filter(&(&1.mass >= min_mass))
      |> Enum.reject(& &1.has_closure?)
      |> Enum.group_by(& &1.hash)
      |> Enum.flat_map(fn {_hash, group} -> plan_for_hash_group(group) end)
    end
  end

  defp references_attribute?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:@, _, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) -> true
      _ -> false
    end)
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

  defp rename_vars(ast) do
    {result, _} = Macro.prewalk(ast, %{}, &rename_var_node/2)
    result
  end

  defp render_helper_text(helper_args, helper_body) do
    body_text = Sourceror.to_string(helper_body)
    args_text = helper_args |> Enum.map_join(", ", &Atom.to_string/1)

    "  defp #{Atom.to_string(@helper_name)}(#{args_text}) do\n" <>
      indent_body(body_text) <>
      "\n  end"
  end

  defp replacement_patch(%{end: end_pos, start: start_pos}, arity) do
    replacement = "&#{Atom.to_string(@helper_name)}/#{arity}"
    %{change: replacement, range: %{end: end_pos, start: start_pos}}
  end

  defp replacement_patch(_, _arity), do: nil
  defp splice_helpers_before_module_end(source, []), do: source

  defp splice_helpers_before_module_end(source, helpers) do
    addition = helpers |> Enum.join("\n")
    lines = String.split(source, "\n")
    {prefix, suffix} = split_at_last_end(lines)
    (prefix ++ [addition] ++ suffix) |> Enum.join("\n")
  end

  defp split_at_last_end(lines) do
    idx =
      lines
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {line, i} ->
        if String.trim(line) == "end", do: i, else: nil
      end)

    case idx do
      nil -> {lines, []}
      i -> {lines |> Enum.take(i), lines |> Enum.drop(i)}
    end
  end

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other
end
