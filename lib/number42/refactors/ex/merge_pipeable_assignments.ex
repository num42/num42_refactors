defmodule Number42.Refactors.Ex.MergePipeableAssignments do
  @moduledoc """
  Collapses a linear single-assignment chain into a pipeline.

      def f(order) do
        a = step_one(order)
        b = step_two(a)
        step_three(b)
      end
      ↓
      def f(order) do
        order
        |> step_one()
        |> step_two()
        |> step_three()
      end

  ## When this fires

  A `def`/`defp` body that is a sequence of `var = call(...)` bindings
  ending in a single tail call, where:

    * every binding LHS is a bare variable,
    * each bound variable is referenced **exactly once** in the whole
      body, and that reference is the **leading first argument** of the
      immediately-following step's outermost call,
    * the body has no control flow (`case`/`cond`/`if`/`with`/`fn`/…).

  The seed of the pipe is the first argument of the first step's call —
  often a parameter, but any expression works (`fetch(order)`).

  ## Relationship to SplitPipeableResponsibilities (#58)

  Both read per-statement data-flow, but trigger on opposite shapes.
  Split cuts a body at *wide* data-flow boundaries (several distinct
  carriers) into named `defp` phases. Merge fires on the *narrowest*
  possible shape — a strictly linear chain where each step carries
  exactly one value into the next — and folds it into a pipe. A body
  that splits is not linear; a body that merges has no split boundary.

  ## What we skip

    * A var used more than once across the chain's calls (`combine(a, a)`,
      or a later `{a, b}` read) — a pipe threads one value, not two. The
      single-use count is taken over the right-hand-side calls only, so it
      also rules out any read *after* the consuming step.
    * A consuming step whose leading argument is not the var
      (`wrap(other(), a)`) — the pipe would inject `a` in the wrong slot.
    * A tail that is not a call (`a + 1`, bare `a`) — nothing to pipe into.
    * Non-bare binding LHS (`{a, b} = ...`) — destructuring isn't a
      single carrier.
    * Any control-flow form in the body.

  ## Idempotence

  After folding, the body is a single `|>` chain — no longer a
  multi-binding run — so a second pass finds no assignment chain to
  collapse. An already-piped body is skipped outright.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @control_flow_forms ~w(case cond if unless with for fn try receive)a

  @impl Number42.Refactors.Refactor
  def description, do: "Collapse a linear single-assignment chain into a pipeline"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A run of `a = f(x); b = g(a); h(b)` bindings, where each value is
    threaded straight into the next step and used nowhere else, is a
    pipeline spelled out by hand. Folding it into `x |> f() |> g() |>
    h()` removes the intermediate names, makes the data flow the literal
    shape of the code, and lowers nesting. The fold only fires when every
    carrier is single-use and lands in the leading argument slot, so the
    rewrite preserves evaluation order and argument positions exactly.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts),
    do: Sourceror.parse_string(source) |> apply_patches(source)

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&maybe_patch/1)
  end

  defp maybe_patch({kind, _, [_head, body_kw]}) when kind in [:def, :defp] and is_list(body_kw) do
    with {:ok, body} <- do_body(body_kw),
         exprs = body_to_exprs(body),
         {:ok, seed, stages} <- linear_chain(exprs) do
      [Patch.replace(body, render_pipe(seed, stages))]
    else
      _ -> []
    end
  end

  defp maybe_patch(_), do: []

  # Validate the body as a linear chain and project it into a pipe seed
  # plus the headless stage texts.
  defp linear_chain(exprs) when length(exprs) < 2, do: :skip

  defp linear_chain(exprs) do
    {bindings, [tail]} = Enum.split(exprs, -1)

    with :ok <- no_control_flow(exprs),
         {:ok, calls} <- step_calls(bindings),
         {:ok, tail_call} <- as_call(tail),
         {:ok, vars} <- step_vars(bindings),
         all_calls = calls ++ [tail_call],
         :ok <- carriers_thread?(vars, calls, tail_call, all_calls) do
      seed = leading_arg(hd(all_calls))
      {:ok, Sourceror.to_string(seed), Enum.map(all_calls, &headless_text/1)}
    else
      _ -> :skip
    end
  end

  # Every non-tail statement is `var = call(...)`; collect the call ASTs.
  defp step_calls(bindings) do
    bindings
    |> reduce_ok(fn
      {:=, _, [_lhs, rhs]} -> as_call(rhs)
      _ -> :skip
    end)
  end

  defp step_vars(bindings) do
    bindings
    |> reduce_ok(fn
      {:=, _, [lhs, _rhs]} -> bare_var(lhs)
      _ -> :skip
    end)
  end

  # For each carrier var, its consumer (the next step's call, or the
  # tail) must read it exactly once as the leading argument. Use-count is
  # taken over the call expressions only, so the LHS binder never counts.
  defp carriers_thread?(vars, calls, tail_call, all_calls) do
    consumers = tl(calls) ++ [tail_call]

    vars
    |> Enum.zip(consumers)
    |> Enum.all?(fn {var, consumer} ->
      single_use?(var, all_calls) and var_ref?(leading_arg(consumer), var)
    end)
    |> ok_or_skip()
  end

  defp as_call({{:., _, _}, _, args} = call) when is_list(args) and args != [], do: {:ok, call}

  defp as_call({fun, _, args} = call) when is_atom(fun) and is_list(args) and args != [] do
    if Macro.operator?(fun, length(args)) or fun == :|>, do: :skip, else: {:ok, call}
  end

  defp as_call(_), do: :skip

  defp leading_arg({_callee, _meta, [first | _rest]}), do: first

  defp headless_text({callee, meta, [_first | rest]}),
    do: Sourceror.to_string({callee, meta, rest})

  defp single_use?(var, exprs) do
    exprs
    |> Enum.map(fn expr -> expr |> Macro.prewalker() |> Enum.count(&var_ref?(&1, var)) end)
    |> Enum.sum()
    |> Kernel.==(1)
  end

  defp render_pipe(seed, stages), do: Enum.join([seed | Enum.map(stages, &("|> " <> &1))], "\n")

  defp no_control_flow(exprs) do
    exprs
    |> Enum.any?(fn expr ->
      expr
      |> Macro.prewalker()
      |> Enum.any?(fn
        {form, _, _} when form in @control_flow_forms -> true
        _ -> false
      end)
    end)
    |> negate_to_skip()
  end

  defp negate_to_skip(true), do: :skip
  defp negate_to_skip(false), do: :ok

  defp ok_or_skip(true), do: :ok
  defp ok_or_skip(false), do: :skip

  defp reduce_ok(list, fun) do
    list
    |> Enum.reduce_while([], fn item, acc ->
      case fun.(item) do
        {:ok, value} -> {:cont, [value | acc]}
        :skip -> {:halt, :skip}
      end
    end)
    |> case do
      :skip -> :skip
      values -> {:ok, Enum.reverse(values)}
    end
  end

  defp do_body(body_kw) do
    body_kw
    |> Enum.find_value(:skip, fn
      {{:__block__, _, [:do]}, value} -> {:ok, value}
      {:do, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
