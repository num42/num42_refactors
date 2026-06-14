defmodule Number42.Refactors.Ex.LiftLocalLambda do
  @moduledoc """
  Lift a local anonymous function bound to a variable inside one
  function into a private function (`defp`). Variables the lambda
  closes over from the enclosing scope are promoted to parameters of
  the new `defp`; every `f.(...)` call site in the body is rewritten to
  a direct call passing the closed-over values.

      # before
      defp validate_multi_select(changeset, field, allowed) do
        value = get_field(changeset, field)

        compute_all_valid = fn ->
          value
          |> String.split(",", trim: true)
          |> Enum.all?(&(&1 in allowed))
        end

        cond do
          value in [nil, ""]     -> changeset
          compute_all_valid.()   -> changeset
          true                   -> add_error(changeset, field, "bad")
        end
      end

      # after
      defp validate_multi_select(changeset, field, allowed) do
        value = get_field(changeset, field)

        cond do
          value in [nil, ""]      -> changeset
          all_valid?(value, allowed) -> changeset
          true                    -> add_error(changeset, field, "bad")
        end
      end

      defp all_valid?(value, allowed) do
        value
        |> String.split(",", trim: true)
        |> Enum.all?(&(&1 in allowed))
      end

  Complementary to `ExtractLambdaBlock`: that refactor extracts a
  duplicated lambda *body* into a `&capture/n` and **skips** closures.
  This one handles the case it bails on — a lambda bound to a variable
  that closes over outer-scope bindings.

  ## Parameter promotion

  Every free variable in the lambda body (referenced but not bound
  there, and not one of the lambda's own params) that is bound in the
  enclosing scope becomes a `defp` parameter, in first-reference order.
  The lambda's own params lead; the promoted closures follow. Each
  call site `f.(args)` becomes `helper(args, closure_a, closure_b)`.

  ## Naming

  Derived from the binding name. A boolean-returning body earns a `?`
  suffix and sheds a leading `compute_`/`is_`/`check_` verb
  (`compute_all_valid` → `all_valid?`). Otherwise the binding name is
  kept verbatim.

  ## What is skipped

  - **Lambda escapes** — the binding is referenced anywhere other than
    a `f.(...)` call (passed as a value, returned, stored). Lifting
    would change arity/value semantics.
  - **Zero call sites** — dead binding, nothing to rewrite.
  - **Recursive lambda** — body references its own binding name. The
    `defp` self-reference would need its own name; conservative skip.
  - **Multi-clause lambda** (`fn :a -> ... ; :b -> ... end`).
  - **Closed-over var rebound after the binding** — the value the
    lambda would capture differs from the value at the (later) call
    site once promoted to a param. Semantic trap; skip.
  - **Body mass below `:min_mass`** (default 20) — micro-lambdas add
    noise. Reuses the `ExtractLambdaBlock` threshold convention.
  - **Helper name already taken** in the module with a different
    arity/shape — skip rather than disambiguate.
  """

  use Number42.Refactors.Refactor

  @default_min_mass 20

  @impl Number42.Refactors.Refactor
  def description,
    do:
      "Lift a local `f = fn ... end` binding to a private function, promoting closures to params"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A local `fn -> ... end` assigned to a variable and called within the
    function body is harder to test, harder to name-as-intent, and
    clutters the host function. Lifting it to a `defp` — promoting the
    closed-over bindings to parameters and rewriting each call site —
    makes the helper addressable, unit-testable, and reusable, and
    flattens the host function.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 100
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)

    Sourceror.parse_string(source) |> apply_to_parse_result(min_mass, source)
  end

  defp apply_to_parse_result({:ok, ast}, min_mass, source),
    do: apply_to_ast(ast, source, min_mass)

  defp apply_to_parse_result({:error, _}, _min_mass, source), do: source

  defp apply_to_ast(ast, source, min_mass) do
    ast
    |> module_bodies()
    |> Enum.flat_map(&plans_for_module(&1, min_mass))
    # One lift per pass keeps the diff focused; the engine's fixpoint
    # loop re-runs to pick up further lifts. Splicing a fresh helper at
    # module end also shifts line numbers, so committing to a single
    # plan per pass avoids stale ranges in a second plan.
    |> Enum.take(1)
    |> emit_or_passthrough(source)
  end

  defp module_bodies(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [_name, [{_do, body}]]} = node -> [{node, body_to_exprs(body)}]
      _ -> []
    end)
  end

  defp plans_for_module({module_node, body_exprs}, min_mass) do
    defp_index = def_name_arities(body_exprs)

    body_exprs
    |> Enum.filter(&def_clause?/1)
    |> Enum.flat_map(&plans_for_clause(&1, module_node, defp_index, min_mass))
  end

  defp def_clause?({kind, _, [_head, body_kw]}) when kind in [:def, :defp] and is_list(body_kw),
    do: true

  defp def_clause?(_), do: false

  defp plans_for_clause({_kind, _, [head, body_kw]}, module_node, defp_index, min_mass) do
    head_params = head |> head_param_names() |> MapSet.new()

    case do_body(body_kw) do
      {:ok, body} ->
        stmts = body_to_exprs(body)
        lift_plans(stmts, head_params, module_node, defp_index, min_mass)

      :error ->
        []
    end
  end

  # The `:do` body, unwrapping Sourceror's `{:__block__, _, [:do]}` key
  # form as well as the plain `:do` atom key. `:rescue`/`:after` bodies
  # are deliberately ignored — a binding/call split across them
  # wouldn't share one statement list.
  defp do_body(body_kw) do
    Enum.find_value(body_kw, :error, fn
      {{:__block__, _, [:do]}, body} -> {:ok, body}
      {:do, body} -> {:ok, body}
      _ -> nil
    end)
  end

  defp lift_plans(stmts, head_params, module_node, defp_index, min_mass) do
    ctx = %{
      defp_index: defp_index,
      head_params: head_params,
      min_mass: min_mass,
      module_node: module_node,
      stmts: stmts
    }

    stmts
    |> Enum.with_index()
    |> Enum.flat_map(fn {stmt, idx} -> build_plan(stmt, idx, ctx) end)
  end

  # `name = fn args -> body end` — single-clause only.
  defp lambda_binding({:=, _, [{name, _, ctx}, {:fn, _, [{:->, _, [args, body]}]}]})
       when is_atom(name) and is_atom(ctx) and is_list(args) do
    if underscore?(name), do: :skip, else: {:ok, name, args, body}
  end

  defp lambda_binding(_), do: :skip

  defp scope_before(stmts, idx, head_params) do
    stmts
    |> Enum.take(idx)
    |> Enum.reduce(head_params, fn stmt, acc -> MapSet.union(acc, bound_in(stmt)) end)
  end

  defp build_plan(stmt, idx, ctx) do
    %{defp_index: defp_index, head_params: head_params, min_mass: min_mass, stmts: stmts} = ctx

    with {:ok, name, lambda_args, lambda_body} <- lambda_binding(stmt),
         available <- scope_before(stmts, idx, head_params),
         lambda_arg_names <- lambda_args |> Enum.flat_map(&pattern_var_names/1) |> MapSet.new(),
         :ok <- check_mass(lambda_body, min_mass),
         :ok <- check_not_recursive(lambda_body, name),
         {:ok, lambda_arg_list} <- valid_lambda_args(lambda_args),
         {:ok, call_sites} <- call_sites_only(stmts, name),
         closures <- promoted_closures(lambda_body, available, lambda_arg_names),
         :ok <- check_no_rebind(stmts, idx, closures),
         arity <- length(lambda_arg_list) + length(closures),
         helper <- helper_name(name, lambda_body),
         :ok <- check_name_free(defp_index, helper, arity) do
      [
        %{
          arity: arity,
          binding_stmt: stmt,
          call_sites: call_sites,
          closures: closures,
          helper: helper,
          lambda_args: lambda_arg_list,
          lambda_body: lambda_body,
          module_node: ctx.module_node
        }
      ]
    else
      _ -> []
    end
  end

  defp check_mass(body, min_mass) do
    if node_count(body) >= min_mass, do: :ok, else: :skip
  end

  defp check_not_recursive(body, name) do
    if references_name?(body, name), do: :skip, else: :ok
  end

  # Every lambda param must be a bare, non-underscore variable — a
  # destructuring pattern (`fn %{a: a} -> ...`) would change the call
  # site shape and is out of scope for v1.
  defp valid_lambda_args(args) do
    args
    |> Enum.reduce_while([], fn
      {n, _, ctx}, acc when is_atom(n) and is_atom(ctx) ->
        if underscore?(n), do: {:halt, :skip}, else: {:cont, [n | acc]}

      _, _acc ->
        {:halt, :skip}
    end)
    |> case do
      :skip -> :skip
      names -> {:ok, Enum.reverse(names)}
    end
  end

  # Collect every reference to the binding `name` in the surrounding
  # statements. A reference must be a call `name.(args)`; any other
  # reference (the bare var passed/returned/stored) means the lambda
  # escapes → skip. At least one call site is required.
  #
  # The walk *prunes* the callee var of a matched `name.(args)` and the
  # LHS var of the binding site so they aren't re-counted as escapes by
  # the catch-all bare-var clause — a `name.()` call legitimately holds
  # a `{name, _, ctx}` node as its callee.
  defp call_sites_only(stmts, name) do
    {_, refs} =
      Enum.reduce(stmts, {nil, []}, fn stmt, {_, acc} ->
        Macro.prewalk(stmt, acc, &collect_ref(&1, &2, name))
      end)

    cond do
      Enum.any?(refs, &(&1 == :escape)) -> :skip
      not Enum.any?(refs, &match?({:call, _}, &1)) -> :skip
      true -> {:ok, Enum.filter(refs, &match?({:call, _}, &1))}
    end
  end

  # `name.(args)` — record the call, replace its callee var with `nil`
  # so the descent doesn't re-see the bare var as an escape.
  defp collect_ref({{:., dm, [{n, _, ctx}]}, m, args} = node, acc, name)
       when n == name and is_atom(ctx) and is_list(args),
       do: {{{:., dm, [nil]}, m, args}, [{:call, node} | acc]}

  # The binding site `name = fn ... end` — prune the LHS var.
  defp collect_ref({:=, m, [{n, _, ctx}, {:fn, _, _} = fun]}, acc, name)
       when n == name and is_atom(ctx),
       do: {{:=, m, [nil, fun]}, acc}

  # Any surviving bare-var occurrence of `name` is an escape.
  defp collect_ref({n, _, ctx} = node, acc, name) when n == name and is_atom(ctx),
    do: {node, [:escape | acc]}

  defp collect_ref(node, acc, _name), do: {node, acc}

  defp promoted_closures(body, available, lambda_arg_names) do
    bound = bound_in(body)

    body
    |> Macro.prewalker()
    |> Enum.flat_map(&free_ref(&1, bound, lambda_arg_names, available))
    |> Enum.uniq()
  end

  defp free_ref({name, _, ctx}, bound, lambda_arg_names, available)
       when is_atom(name) and is_atom(ctx) do
    if not underscore?(name) and
         name not in [:__MODULE__, :__CALLER__, :__ENV__] and
         not MapSet.member?(bound, name) and
         not MapSet.member?(lambda_arg_names, name) and
         MapSet.member?(available, name),
       do: [name],
       else: []
  end

  defp free_ref(_node, _bound, _lambda_arg_names, _available), do: []

  # If any promoted closure is rebound in a statement *after* the
  # binding site, the value captured at definition differs from the
  # value at the (later) call site once we promote it to a param. Skip.
  defp check_no_rebind(stmts, idx, closures) do
    closure_set = MapSet.new(closures)

    rebound =
      stmts
      |> Enum.drop(idx + 1)
      |> Enum.reduce(MapSet.new(), fn stmt, acc -> MapSet.union(acc, bound_in(stmt)) end)

    if MapSet.disjoint?(rebound, closure_set), do: :ok, else: :skip
  end

  defp check_name_free(defp_index, helper, arity) do
    case Map.get(defp_index, helper) do
      nil -> :ok
      ^arity -> :skip
      _other -> :skip
    end
  end

  # Map of every defined function name → its arity (any clause). Used
  # only to detect a name collision; an existing name in any shape is a
  # conservative skip.
  defp def_name_arities(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {kind, _, [head | _]} when kind in [:def, :defp, :defmacro, :defmacrop] ->
        case extract_fn_signature(strip_when(head)) do
          {name, args} -> [{name, length(args)}]
          :error -> []
        end

      _ ->
        []
    end)
    |> Map.new()
  end

  defp head_param_names({:when, _, [inner | _]}), do: head_param_names(inner)

  defp head_param_names({name, _, args}) when is_atom(name) and is_list(args),
    do: args |> Enum.flat_map(&pattern_var_names/1)

  defp head_param_names(_), do: []

  # --- naming -------------------------------------------------------

  @verb_prefixes ~w(compute is check has get build make do calc)

  defp helper_name(binding_name, body) do
    if boolean_body?(body),
      do: boolean_helper_name(binding_name),
      else: binding_name
  end

  defp boolean_helper_name(binding_name) do
    str = Atom.to_string(binding_name)
    base = strip_verb_prefix(str)
    candidate = if String.ends_with?(base, "?"), do: base, else: base <> "?"
    String.to_atom(candidate)
  end

  defp strip_verb_prefix(str) do
    case String.split(str, "_", parts: 2) do
      [prefix, rest] when prefix in @verb_prefixes and rest != "" -> rest
      _ -> str
    end
  end

  # A body is boolean when its final expression is a boolean-valued
  # construct: a comparison/boolean operator, a `?`-suffixed call, or a
  # pipe ending in one. Conservative — only fires on clear signals.
  defp boolean_body?(body) do
    body |> body_to_exprs() |> List.last() |> boolean_expr?()
  end

  @boolean_ops [:==, :!=, :===, :!==, :>, :<, :>=, :<=, :and, :or, :not, :&&, :||, :!, :in]

  defp boolean_expr?({op, _, _}) when op in @boolean_ops, do: true
  defp boolean_expr?({:|>, _, [_lhs, rhs]}), do: boolean_expr?(rhs)
  defp boolean_expr?({{:., _, [_callee, fname]}, _, _}) when is_atom(fname), do: question?(fname)
  defp boolean_expr?({fname, _, args}) when is_atom(fname) and is_list(args), do: question?(fname)
  defp boolean_expr?(_), do: false

  defp question?(fname), do: fname |> Atom.to_string() |> String.ends_with?("?")

  # --- emission -----------------------------------------------------

  defp emit_or_passthrough([], source), do: source

  defp emit_or_passthrough([plan], source) do
    callsite_patches = Enum.map(plan.call_sites, &callsite_patch(&1, plan))
    binding_patch = removal_patch(plan.binding_stmt)
    helper_text = render_helper(plan)

    source
    |> patch_string([binding_patch | callsite_patches])
    |> splice_helper_before_module_end(plan.module_node, helper_text)
  end

  defp callsite_patch({:call, {_dot, _meta, args} = node}, plan) do
    extra = plan.closures |> Enum.map(&Atom.to_string/1)
    arg_texts = Enum.map(args, &Sourceror.to_string/1)
    replacement = "#{plan.helper}(#{Enum.join(arg_texts ++ extra, ", ")})"
    %{change: replacement, range: Sourceror.get_range(node)}
  end

  # Replace the `name = fn ... end` statement with nothing. The range
  # covers the assignment expression; the line it sat on collapses on
  # the reformat pass.
  defp removal_patch(stmt) do
    range = Sourceror.get_range(stmt)
    %{change: "", range: full_line_range(range)}
  end

  # Extend the binding range to swallow its own line: start at column 1
  # and end at column 1 of the next line, so the now-empty line goes
  # away rather than leaving a blank gap.
  defp full_line_range(%{start: start_pos, end: end_pos}) do
    %{
      start: [line: start_pos[:line], column: 1],
      end: [line: end_pos[:line] + 1, column: 1]
    }
  end

  defp render_helper(plan) do
    params = (plan.lambda_args ++ plan.closures) |> Enum.map_join(", ", &Atom.to_string/1)
    params_clause = if params == "", do: "", else: "(#{params})"
    body_text = Sourceror.to_string(plan.lambda_body)

    "  defp #{plan.helper}#{params_clause} do\n" <>
      indent_body(body_text) <>
      "\n  end"
  end

  defp indent_body(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "    " <> line
    end)
  end

  defp splice_helper_before_module_end(source, _module_node, helper_text) do
    lines = String.split(source, "\n")
    {prefix, suffix} = split_at_last_end(lines)
    (prefix ++ ["", helper_text] ++ suffix) |> Enum.join("\n")
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
      i -> {Enum.take(lines, i), Enum.drop(lines, i)}
    end
  end

  # --- shared small helpers -----------------------------------------

  defp references_name?(ast, name) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {n, _, ctx} when n == name and is_atom(ctx) -> true
      _ -> false
    end)
  end

  defp node_count(ast) do
    {_, count} = Macro.prewalk(ast, 0, fn node, acc -> {node, acc + 1} end)
    count
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp patch_string(source, patches), do: Sourceror.patch_string(source, patches)
end
