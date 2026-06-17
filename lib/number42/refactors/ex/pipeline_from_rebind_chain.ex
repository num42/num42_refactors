defmodule Number42.Refactors.Ex.PipelineFromRebindChain do
  @moduledoc """
  Collapses a chain of sequential rebinds of the *same* variable into a
  single pipe.

      x = transform_a(input)
      x = transform_b(x, opt)
      x = transform_c(x)
      ↓
      input |> transform_a() |> transform_b(opt) |> transform_c()

  ## When this fires

  A contiguous run of two or more statements inside a block, each of the
  shape `x = <step>` rebinding the **same bare variable** `x`, where:

    * the **head** step (the first) does **not** read `x` — its leading
      argument seeds the pipe (`input`, `fetch(input)`, …);
    * every **consuming** step (the rest) reads the previous `x`
      **exactly once** and **only at the leading first-argument slot** —
      `transform_b(x, g(x))` reads `x` twice and `transform_b(other, x)`
      reads it in the wrong slot, both SKIP;
    * `x` is **not read after** the run — the chain's final value is the
      run's only product, so the binding can dissolve into a bare pipe.

  Each step is either a plain call (`f(x, rest)`) or an already-piped
  form (`x |> f(rest)`), the latter being what `PipeReassign` leaves
  behind for multi-arg middle steps in the full pipeline.

  ## Relationship to MergePipeableAssignments (#63)

  Both fold a straight-line run of bindings into a pipe, but they trigger
  on disjoint shapes and never compete:

    * **MergePipeableAssignments** threads **distinct** variables
      (`a = f(x); b = g(a); h(b)`) and requires the run to be the whole
      `def`/`defp` body ending in a **non-assignment tail call**. A
      same-variable rebind chain has an assignment as its last statement,
      which that refactor's tail-call check rejects outright.
    * **PipelineFromRebindChain** threads **one** variable rebound in
      place. Every statement (including the last) is `x = …`, so the
      distinct-LHS requirement of the sibling never holds.

  The two trigger conditions are mutually exclusive on the LHS-distinctness
  axis, so the fixpoint loop cannot ping-pong between them.

  ## Why bare-call replacement (no binding)

  The run only fires when `x` is dead after it, so re-binding `x` would
  leave an unread variable. Emitting the bare pipe preserves evaluation
  order and the final value (which becomes the block's value when the run
  is the tail) while dropping the dead name.

  ## Idempotence

  After folding, the run is a single pipe expression — there is no rebind
  chain left, so a second pass matches nothing. An existing pipe is
  skipped outright.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Collapse sequential rebinds of one variable into a single pipe"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `x = a(input); x = b(x, opt); x = c(x)` is a pipeline spelled out as
    a sequence of in-place rebinds: each line threads the running value
    back through the next step. Folding it into `input |> a() |> b(opt)
    |> c()` removes the repeated name, makes the data flow the literal
    shape of the code, and drops a dead binding. The fold only fires when
    every step consumes the previous value exactly once in the leading
    slot and the variable is unused afterwards, so evaluation order and
    argument positions are preserved.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  @impl Number42.Refactors.Refactor
  def patches(ast, _source, _opts), do: build_patches(ast)

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&block_patches/1)
  end

  defp block_patches({:__block__, _, stmts}) when is_list(stmts), do: chain_patches(stmts, 0, [])
  defp block_patches(_), do: []

  # Walk statements left-to-right; on a collapsible run emit one patch and
  # skip past the whole run. Consuming the run keeps emitted ranges
  # disjoint, so `patch_string` never sees overlapping edits.
  defp chain_patches(stmts, index, acc) do
    case Enum.drop(stmts, index) do
      [] ->
        Enum.reverse(acc)

      [_first | _] = rest ->
        case run_at(rest, stmts, index) do
          {:ok, length, replacement} ->
            patch = run_patch(rest, length, replacement)
            chain_patches(stmts, index + length, [patch | acc])

          :skip ->
            chain_patches(stmts, index + 1, acc)
        end
    end
  end

  defp run_patch(rest, length, replacement) do
    run = Enum.take(rest, length)

    range = %{
      start: Sourceror.get_range(hd(run)).start,
      end: Sourceror.get_range(List.last(run)).end
    }

    Patch.new(range, replacement, false)
  end

  # A run is the maximal same-variable rebind sequence starting at the
  # head; validate it and project it into pipe text.
  defp run_at([head | _] = rest, stmts, index) do
    with {:ok, var} <- rebind_var(head),
         run when length(run) >= 2 <- collect_run(rest, var),
         false <- read_after?(var, stmts, index + length(run) - 1),
         {:ok, seed, stages} <- project(run, var) do
      {:ok, length(run), render_pipe(seed, stages)}
    else
      _ -> :skip
    end
  end

  # Greedily take the longest prefix of consecutive `var = …` rebinds.
  defp collect_run(rest, var) do
    rest
    |> Enum.take_while(&match?({:=, _, [_, _]}, &1))
    |> Enum.take_while(fn {:=, _, [lhs, _]} -> bare_var(lhs) == {:ok, var} end)
  end

  defp rebind_var({:=, _, [lhs, _rhs]}), do: bare_var(lhs)
  defp rebind_var(_), do: :skip

  # Head seeds the pipe and must not read `var`; the rest each consume the
  # previous `var` once, in the leading slot.
  defp project([{:=, _, [_, head_rhs]} | tail], var) do
    with false <- reads?(head_rhs, var),
         {:ok, seed, head_stages} <- head_stage(head_rhs),
         {:ok, tail_stages} <- consuming_stages(tail, var) do
      {:ok, seed, head_stages ++ tail_stages}
    else
      _ -> :skip
    end
  end

  defp head_stage({:|>, _, _} = pipe) do
    {seed, stages} = unpipe(pipe)
    {:ok, Sourceror.to_string(seed), Enum.map(stages, &Sourceror.to_string/1)}
  end

  # A nested head seed unwraps along its **leading-argument spine**:
  # `f(g(h(input)))` seeds from `h(input)` and stacks `g()` then `f()`.
  # Each level lifts only its first argument; sibling args stay inside
  # their own stage, so left-to-right evaluation order is preserved. The
  # recursion stops at the **innermost call** — the deepest call whose own
  # leading argument is not itself a call (`h(input)`, `fetch(input)`),
  # which is rendered whole as the seed. A single linear call seeds from
  # its leading argument exactly as before.
  defp head_stage(rhs) do
    with {:ok, {callee, _, [first | rest]}} <- as_call(rhs) do
      case as_call(first) do
        {:ok, _} ->
          {seed, inner_stages} = unwrap_seed(first)
          {:ok, seed, inner_stages ++ [headless_text(callee, rest)]}

        :skip ->
          {:ok, Sourceror.to_string(first), [headless_text(callee, rest)]}
      end
    end
  end

  # `call` is a call whose leading arg may itself be a call. Keep peeling
  # the leading-arg spine until the inner leading arg is a non-call; that
  # innermost call is the seed, rendered whole.
  defp unwrap_seed({callee, _, [first | rest]} = call) do
    case as_call(first) do
      {:ok, _} ->
        {seed, inner_stages} = unwrap_seed(first)
        {seed, inner_stages ++ [headless_text(callee, rest)]}

      :skip ->
        {Sourceror.to_string(call), []}
    end
  end

  defp consuming_stages(tail, var) do
    tail
    |> Enum.reduce_while([], fn {:=, _, [_, rhs]}, acc ->
      case consume_stage(rhs, var) do
        {:ok, stages} -> {:cont, acc ++ stages}
        :skip -> {:halt, :skip}
      end
    end)
    |> case do
      :skip -> :skip
      stages -> {:ok, stages}
    end
  end

  # `x |> f(rest)`: the pipe head must be exactly `x`, used nowhere else.
  defp consume_stage({:|>, _, _} = pipe, var) do
    {seed, stages} = unpipe(pipe)

    with true <- var_ref?(seed, var),
         true <- uses_once?(pipe, var) do
      {:ok, Enum.map(stages, &Sourceror.to_string/1)}
    else
      _ -> :skip
    end
  end

  # `f(x, rest)`: `x` must be the leading arg and appear nowhere else.
  defp consume_stage(rhs, var) do
    with {:ok, {callee, _, [first | rest]}} <- as_call(rhs),
         true <- var_ref?(first, var),
         true <- uses_once?(rhs, var) do
      {:ok, [headless_text(callee, rest)]}
    else
      _ -> :skip
    end
  end

  defp unpipe({:|>, _, [lhs, rhs]}) do
    {seed, stages} = unpipe(lhs)
    {seed, stages ++ [rhs]}
  end

  defp unpipe(node), do: {node, []}

  defp as_call({{:., _, _}, _, args} = call) when is_list(args) and args != [], do: {:ok, call}

  defp as_call({fun, _, args} = call) when is_atom(fun) and is_list(args) and args != [] do
    cond do
      Macro.operator?(fun, length(args)) -> :skip
      fun == :|> -> :skip
      special_form?(call) -> :skip
      true -> {:ok, call}
    end
  end

  defp as_call(_), do: :skip

  defp headless_text(callee, args),
    do: {callee, [], args} |> Sourceror.to_string()

  defp reads?(ast, var), do: MapSet.member?(used_var_names(ast), var)

  defp uses_once?(ast, var) do
    ast
    |> Macro.prewalker()
    |> Enum.count(&var_ref?(&1, var))
    |> Kernel.==(1)
  end

  defp render_pipe(seed, stages),
    do: [seed | Enum.map(stages, &("|> " <> &1))] |> Enum.join(" ")

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
