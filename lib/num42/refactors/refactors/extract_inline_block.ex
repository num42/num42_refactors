defmodule Num42.Refactors.Refactors.ExtractInlineBlock do
  @moduledoc """
  Extract a duplicated function body into a private helper inside the
  same module, then rewrite every clone to call that helper.

  Different from `ExtractIntraModuleClone`: that pass picks the *first*
  clone as the source of truth and rewrites the others to delegate
  to it (`def f, do: g(...)`). This pass synthesises a brand-new
  `defp extracted_block/n` for the shared body, so neither clone is
  privileged — every original `def` becomes a one-liner that calls
  the helper. Useful when none of the clones is a natural "primary"
  call site (e.g. `embedding_gemini` ↔ `embedding_openai` — neither is
  the "real" function).

      # before
      defmodule MyApp.Sender do
        def send_email(user, payload) do
          envelope = build_envelope(user)
          formatted = format_payload(payload)
          dispatch(envelope, formatted)
        end

        def send_sms(user, payload) do
          envelope = build_envelope(user)
          formatted = format_payload(payload)
          dispatch(envelope, formatted)
        end
      end

      # after
      defmodule MyApp.Sender do
        def send_email(user, payload), do: extracted_block(user, payload)
        def send_sms(user, payload), do: extracted_block(user, payload)

        defp extracted_block(user, payload) do
          envelope = build_envelope(user)
          formatted = format_payload(payload)
          dispatch(envelope, formatted)
        end
      end

  ## What is skipped

  - Single occurrence of a body — no clone, nothing to extract.
  - Body references a module attribute — the helper would need to live
    in the same module *and* the attribute must be in scope, which is
    fine here, but a body that uses an attribute is often parameterised
    on environment in subtle ways. Conservative: skip for v1.
  - Loser head not plain-var or has guard — can't synthesise a clean
    helper call site without losing pattern semantics.
  - Body uses variables not derivable from the function's arguments —
    closure over outer-scope bindings the helper can't see. Skip.
  - Body mass below `:min_mass` (default 20) — micro-clones are noise.
  - The helper name `extracted_block` already exists in the module
    with a different shape — would have to dedupe; skip for v1.
  """

  use Num42.Refactors.Refactor

  @default_min_mass 20
  @helper_name :extracted_block

  @impl Num42.Refactors.Refactor
  def description, do: "Extract duplicated function bodies into a shared private helper"

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    Two or more functions in the same module with identical bodies are
    rewritten to call a synthesised `defp extracted_block(...)` helper.
    Unlike `ExtractIntraModuleClone`, no clone is privileged as the
    "source" — both wrappers delegate to a fresh helper.
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
    plans =
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(fn
        {:defmodule, _, [_name_ast, [{_do, body}]]} = mod_ast ->
          body
          |> body_to_exprs()
          |> plans_for_module(mod_ast, min_mass)

        _ ->
          []
      end)

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

  defp plans_for_module(body_exprs, _mod_ast, min_mass) do
    clauses = body_exprs |> Enum.filter(&def_clause?/1)
    multi_clause_keys = multi_clause_keys(clauses)
    helper_taken? = helper_name_taken?(clauses)

    eligible =
      clauses
      |> Enum.reject(&MapSet.member?(multi_clause_keys, name_arity(&1)))
      |> Enum.reject(&body_uses_module_attribute?/1)
      |> Enum.reject(&head_has_guard?/1)
      |> Enum.reject(&(not head_is_plain_vars?(&1)))
      |> Enum.filter(&(clause_mass(&1) >= min_mass))

    cond do
      helper_taken? ->
        []

      true ->
        eligible
        |> Enum.group_by(&body_hash/1)
        |> Enum.flat_map(fn {_hash, group} ->
          case group do
            [_only] -> []
            [first | _] = group -> plan_for_group(group, first)
          end
        end)
    end
  end

  defp plan_for_group(group, first) do
    arg_names = arg_names_of(first)
    available = MapSet.new(arg_names)

    cond do
      not body_self_contained?(group, available) ->
        []

      true ->
        helper_args = arg_names
        helper_body = body_of(first)

        callsite_patches =
          group
          |> Enum.map(
            &clause_callsite_patch(
              &1,
              helper_args
            )
          )
          |> Enum.reject(&is_nil/1)

        helper_text = render_helper_text(helper_args, helper_body)
        [%{callsite_patches: callsite_patches, helper_text: helper_text}]
    end
  end

  defp body_self_contained?(group, available) do
    group
    |> Enum.all?(fn clause ->
      clause_args = MapSet.new(arg_names_of(clause))
      free = free_vars_of_body(clause, clause_args)
      free == [] or MapSet.subset?(MapSet.new(free), available)
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

  defp helper_name_taken?(clauses) do
    clauses |> Enum.any?(fn c -> name_of(c) == @helper_name end)
  end

  defp name_arity(clause), do: {name_of(clause), arity_of(clause)}

  defp name_of({kind, _, [head | _]}) when kind in [:def, :defp] do
    strip_when(head) |> name_atom_or_nil()
  end

  defp arity_of({kind, _, [head | _]}) when kind in [:def, :defp] do
    strip_when(head) |> arity_of_head()
  end

  defp arg_names_of({kind, _, [head | _]}) when kind in [:def, :defp] do
    strip_when(head) |> arg_atoms_of_head()
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

  defp body_of({_kind, _, [_head, body_kw]}) do
    body_kw
    |> Enum.find_value(fn
      {{:__block__, _, [:do]}, value} -> value
      {:do, value} -> value
      _ -> nil
    end)
  end

  defp free_vars_of_body(clause, available) do
    body = body_of(clause)
    free_vars(body, available)
  end

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

  defp clause_callsite_patch(clause, helper_args) do
    {kind, _, [head | _]} = clause
    {fn_name, _, _} = strip_when(head)
    fn_arg_names = arg_names_of(clause)
    fn_arg_list = fn_arg_names |> Enum.join(", ")

    helper_call_args =
      helper_args
      |> Enum.map_join(", ", fn name ->
        if name in fn_arg_names, do: Atom.to_string(name), else: Atom.to_string(name)
      end)

    replacement =
      "#{kind} #{fn_name}(#{fn_arg_list}) do\n  #{Atom.to_string(@helper_name)}(#{helper_call_args})\nend"

    Sourceror.get_range(clause) |> patch_for_range(replacement)
  end

  defp render_helper_text(helper_args, helper_body) do
    body_text = Sourceror.to_string(helper_body)
    args_text = helper_args |> Enum.map_join(", ", &Atom.to_string/1)

    "  defp #{Atom.to_string(@helper_name)}(#{args_text}) do\n" <>
      indent_body(body_text) <>
      "\n  end"
  end

  defp indent_body(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> "    " <> line end)
  end

  defp patch_or_passthrough(source, []), do: source
  defp patch_or_passthrough(source, patches), do: Sourceror.patch_string(source, patches)

  defp apply_to_parse_result({:ok, ast}, min_mass, source),
    do: ast |> apply_to_ast(source, min_mass)

  defp apply_to_parse_result({:error, _}, _min_mass, source), do: source

  defp name_atom_or_nil({name, _, _}) when is_atom(name), do: name
  defp name_atom_or_nil(_), do: nil

  defp arity_of_head({_, _, args}) when is_list(args), do: length(args)
  defp arity_of_head({_, _, nil}), do: 0
  defp arity_of_head(_), do: -1

  defp arg_atoms_of_head({_, _, args}) when is_list(args) do
    args
    |> Enum.flat_map(fn
      {n, _, ctx} when is_atom(n) and is_atom(ctx) -> [n]
      _ -> []
    end)
  end

  defp arg_atoms_of_head(_), do: []

  defp patch_for_range(%{end: end_pos, start: start_pos}, replacement),
    do: %{change: replacement, range: %{end: end_pos, start: start_pos}}

  defp patch_for_range(_, _replacement), do: nil
end
