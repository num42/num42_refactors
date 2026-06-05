defmodule Number42.Refactors.Ex.MergeAssignKeywords do
  @moduledoc """
  Merges runs of consecutive `lhs = lhs |> assign(:k, v)` statements
  into a single keyword-list call:

      assigns = assigns |> assign(:a, a_value)
      assigns = assigns |> assign(:b, b_value)
      ↓
      assigns = assigns |> assign(a: a_value, b: b_value)

  Captures a frequent LiveView/Component pattern where a function
  threads several assigns through `assign/3` one at a time. The merged
  form is one call, one place to read, and lets `mix format` lay the
  keyword list out vertically when it gets long.

  ## Scope

  We rewrite a run of statements only when **every** statement matches:

      <bare_lhs> = <bare_lhs> |> <callee>(:atom_key, value_expr)

  with all of the following holding across the run:

  - The **LHS variable** is the same bare name throughout.
  - The **callee** (local `assign` or remote `Mod.assign`) is
    identical (same function, same module path) — different modules
    aren't safely interchangeable.
  - The **first call argument** is an atom literal (`:foo`); dynamic
    keys would require a different output shape and aren't merged.
  - The statements are **adjacent** in the parent block (no expression
    between them, even side-effect-free ones — preserving execution
    order is the safer default).
  - The run has **at least two** statements; a single matching
    statement is left alone.

  Other `assign`-family functions (`assign_new`, `update`, ...) are
  not merged — their semantics differ from `assign/3` even when the
  call shape looks the same.

  ## Source slicing

  We splice each value expression's **original source bytes** via
  `Sourceror.get_range/1`. Re-emitting via `Sourceror.to_string/1`
  corrupts string escapes and adds spurious parens to map-access
  forms — slicing keeps the user's formatting verbatim and lets
  `mix format` reflow the keyword list afterwards.

  ## Idempotence

  The merged statement uses `assign(k: v, ...)` — a 2-arg call, not
  a 3-arg call with an atom-literal first arg. The match condition
  rejects it on a re-run, so a second pass is a no-op.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Merge consecutive `x = x |> assign(:k, v)` statements"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A run of single-key `assign/3` calls is one logical step (set up
    these assigns) written as N — every reader has to scan the LHS
    column to confirm it's the same name and every line is doing the
    same thing. The merged keyword form expresses the intent directly:
    one call, the keys named once next to their values. It also makes
    the diff for "added another assign" a single-line keyword
    insertion rather than another full repeat of the LHS-pipe-call
    boilerplate.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 120
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source
  defp ast_range_end(node), do: Sourceror.get_range(node) |> range_end_or_nil()
  defp atom_literal({:__block__, _, [atom]}) when is_atom(atom), do: {:ok, atom}
  defp atom_literal(atom) when is_atom(atom), do: {:ok, atom}
  defp atom_literal(_), do: :error
  defp bare_var_name({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {:ok, name}
  defp bare_var_name(_), do: :error

  defp block_patches({:__block__, _meta, stmts}, source) when is_list(stmts) do
    stmts
    |> classify_stmts()
    |> group_runs()
    |> Enum.flat_map(&run_to_patch(&1, source))
  end

  defp block_patches(_, _), do: []

  defp build_patches(ast, source) do
    nodes = ast |> Macro.prewalker() |> Enum.to_list()

    block = nodes |> Enum.flat_map(&block_patches(&1, source))
    chain = collect_chain_patches(ast, source, [])
    merge_patches = block ++ chain

    import_patches =
      if merges_local_assign?(merge_patches) do
        nodes |> Enum.flat_map(&import_widen_patch(&1, source))
      else
        []
      end

    merge_patches ++ import_patches
  end

  defp callee_signature(:assign), do: {:ok, {:local, :assign}}

  defp callee_signature({:., _, [mod_ast, :assign]}),
    do: {:ok, {:remote, strip_meta(mod_ast), :assign}}

  defp callee_signature(_), do: :error

  defp chain_patch(pipe_node, head_ast, merged_steps, source) do
    head_text = head_text(source, head_ast)

    steps_text =
      merged_steps
      |> Enum.map(&render_step(&1, source))
      |> Enum.reject(&is_nil/1)

    pipe_range = Sourceror.get_range(pipe_node)
    indent = String.duplicate(" ", pipe_range.start[:column] - 1)

    # Sourceror's range on the outermost `|>` over-shoots when the
    # last step contains a nested `fn ... end` (the range extends past
    # the trailing `)` and into the following `\n  defp ...`). Anchor
    # the patch's end to the **last step's** range instead — that's
    # always tight against the closing token of the step.
    end_pos = last_step_end(merged_steps) || pipe_range.end

    body =
      ([head_text] ++ Enum.map(steps_text, &("|> " <> &1)))
      |> Enum.join("\n" <> indent)

    Patch.new(%{end: end_pos, start: pipe_range.start}, body, false)
  end

  defp head_text(source, head_ast) do
    case slice_node(source, head_ast) do
      {:ok, t} -> t
      :error -> ""
    end
  end

  defp classify_step({callee_form, _, [key_ast, value_ast]} = step) do
    with {:ok, key_atom} <- atom_literal(key_ast),
         {:ok, signature} <- callee_signature(callee_form) do
      {:assign_step, signature, key_atom, value_ast, step}
    else
      _ -> {:other_step, step}
    end
  end

  defp classify_step(step), do: {:other_step, step}

  defp classify_stmt(
         {:=, _, [lhs, {:|>, _, [pipe_head, {callee_form, _, [key_ast, value_ast]}]}]} = node
       ) do
    with {:ok, lhs_name} <- bare_var_name(lhs),
         {:ok, head_name} <- bare_var_name(pipe_head),
         true <- lhs_name == head_name,
         {:ok, key_atom} <- atom_literal(key_ast),
         {:ok, signature} <- callee_signature(callee_form) do
      {:assign, lhs_name, signature, key_atom, value_ast, node}
    else
      _ -> :other
    end
  end

  defp classify_stmt(_), do: :other
  defp classify_stmts(classified_stmts), do: classified_stmts |> Enum.map(&classify_stmt/1)

  defp collect_chain_patches({:|>, _, _} = pipe_node, source, acc) do
    {head_ast, steps} = flatten_pipe(pipe_node)

    merge_runs(steps |> Enum.map(&classify_step/1))
    |> recurse_or_emit_chain(acc, head_ast, pipe_node, source, steps)
  end

  defp collect_chain_patches({_form, _meta, args}, source, acc) when is_list(args) do
    args |> Enum.reduce(acc, fn child, a -> collect_chain_patches(child, source, a) end)
  end

  defp collect_chain_patches({left, right}, source, acc) do
    acc = collect_chain_patches(left, source, acc)
    collect_chain_patches(right, source, acc)
  end

  defp collect_chain_patches(list, source, acc) when is_list(list) do
    list |> Enum.reduce(acc, fn child, a -> collect_chain_patches(child, source, a) end)
  end

  defp collect_chain_patches(_, _, acc), do: acc
  defp do_flatten_pipe({:|>, _, [lhs, step]}, acc), do: lhs |> do_flatten_pipe([step | acc])
  defp do_flatten_pipe(head, acc), do: {head, acc}

  defp fetch_only_list(keyword) do
    keyword
    |> Enum.find_value(fn
      {{:__block__, _, [:only]}, value} -> {:ok, value}
      {:only, value} -> {:ok, value}
      _ -> nil
    end) || :error
  end

  defp flatten_pipe(pipe_node), do: do_flatten_pipe(pipe_node, [])
  defp flush_chain_run([], acc), do: acc
  defp flush_chain_run([single], acc), do: [single | acc]

  defp flush_chain_run(run_rev, acc) do
    run = run_rev |> Enum.reverse()
    [{:assign_step, sig, _, _, _} | _] = run
    {:assign_step, _, _, _, last_step} = List.last(run)

    pairs =
      run |> Enum.map(fn {:assign_step, _, key, val_ast, _} -> {key, val_ast} end)

    [{:merged, sig, pairs, last_step} | acc]
  end

  defp flush_run([], runs), do: runs
  defp flush_run(acc, runs), do: [Enum.reverse(acc) | runs]

  defp group_runs(classified) do
    classified
    |> Enum.reduce({[], []}, fn item, {runs, current} ->
      case {item, current} do
        {{:assign, _, _, _, _, _} = m, []} ->
          {runs, [m]}

        {{:assign, lhs, sig, _, _, _} = m, [{:assign, prev_lhs, prev_sig, _, _, _} | _] = acc} ->
          extend_or_flush_run(lhs == prev_lhs and sig == prev_sig, m, acc, runs)

        {:other, []} ->
          {runs, []}

        {:other, acc} ->
          {flush_run(acc, runs), []}
      end
    end)
    |> then(fn {runs, current} -> flush_run(current, runs) end)
    |> Enum.reverse()
    |> Enum.filter(&(length(&1) >= 2))
  end

  defp extend_or_flush_run(true, m, acc, runs), do: {runs, [m | acc]}
  defp extend_or_flush_run(false, m, acc, runs), do: {flush_run(acc, runs), [m]}

  defp import_widen_patch({:import, _, [_mod_ast, kw]} = node, source) when is_list(kw) do
    fetch_only_list(kw) |> widen_patches_for_only_list(node, source)
  end

  defp import_widen_patch(_, _), do: []
  defp last_step_end(merged_steps), do: List.last(merged_steps) |> step_end_pos()

  defp local_assign_patch?(%{change: text}) when is_binary(text) do
    # Local-assign merges always look like `... |> assign(k: ...)`
    # or `lhs = lhs |> assign(k: ...)`. A remote-qualified merge
    # carries the module prefix and won't match this regex.
    Regex.match?(~r/(?<![A-Za-z0-9_\.])assign\(\w+:\s/, text)
  end

  defp local_assign_patch?(_), do: false

  defp merge_runs(classified) do
    {result, current} =
      classified
      |> Enum.reduce({[], []}, fn item, {acc, run} ->
        case {item, run} do
          {{:assign_step, _sig, _, _, _} = m, []} ->
            {acc, [m]}

          {{:assign_step, sig, _, _, _} = m,
           [{:assign_step, prev_sig, _, _, _} | _] = current_run} ->
            extend_or_flush_chain_run(sig == prev_sig, m, current_run, acc)

          {{:other_step, _} = o, []} ->
            {[o | acc], []}

          {{:other_step, _} = o, current_run} ->
            {[o | flush_chain_run(current_run, acc)], []}
        end
      end)

    final = flush_chain_run(current, result) |> Enum.reverse()

    if final |> Enum.any?(&match?({:merged, _, _, _}, &1)),
      do: {:changed, final},
      else: :unchanged
  end

  defp extend_or_flush_chain_run(true, m, current_run, acc), do: {acc, [m | current_run]}

  defp extend_or_flush_chain_run(false, m, current_run, acc),
    do: {flush_chain_run(current_run, acc), [m]}

  defp merges_local_assign?(patches), do: patches |> Enum.any?(&local_assign_patch?/1)
  defp only_list_atoms({:__block__, _, [list]}) when is_list(list), do: only_list_atoms(list)

  defp only_list_atoms(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      {{:__block__, _, [name]}, {:__block__, _, [arity]}}
      when is_atom(name) and is_integer(arity) ->
        [{name, arity}]

      {name, arity} when is_atom(name) and is_integer(arity) ->
        [{name, arity}]

      _ ->
        []
    end)
  end

  defp only_list_atoms(_), do: []
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
  defp range_end_or_nil(%{end: e}), do: e
  defp range_end_or_nil(_), do: nil

  defp recurse_or_emit_chain(
         :unchanged,
         acc,
         head_ast,
         _pipe_node,
         source,
         steps
       ) do
    acc = collect_chain_patches(head_ast, source, acc)
    steps |> Enum.reduce(acc, fn step, a -> collect_chain_patches(step, source, a) end)
  end

  defp recurse_or_emit_chain(
         {:changed, merged},
         acc,
         head_ast,
         pipe_node,
         source,
         _steps
       ),
       do: [chain_patch(pipe_node, head_ast, merged, source) | acc]

  defp render_callee({:local, name}), do: Atom.to_string(name)

  defp render_callee({:remote, mod_ast, fun}),
    do: render_module(mod_ast) <> "." <> Atom.to_string(fun)

  defp render_module({:__aliases__, _, parts}), do: parts |> Enum.map_join(".", &Atom.to_string/1)

  defp render_module({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    Atom.to_string(name)
  end

  defp render_module(_), do: ""
  defp render_step({:other_step, step}, source), do: slice_node(source, step) |> text_or_nil()

  defp render_step({:assign_step, _, _, _, step}, source),
    do: slice_node(source, step) |> text_or_nil()

  defp render_step({:merged, signature, pairs, _last_step}, source) do
    callee = render_callee(signature)

    keyword =
      pairs
      |> Enum.map(fn {key, val_ast} ->
        case slice_node(source, val_ast) do
          {:ok, val} -> "#{key}: #{val}"
          :error -> nil
        end
      end)

    if keyword |> Enum.any?(&is_nil/1) do
      nil
    else
      "#{callee}(#{keyword |> Enum.join(", ")})"
    end
  end

  defp run_to_patch(run, source) do
    [{:assign, lhs_name, signature, _first_key, _first_val, first_node} | _] = run
    {:assign, _, _, _, _, last_node} = List.last(run)

    pairs =
      run
      |> Enum.map(fn {:assign, _, _, key_atom, value_ast, _} ->
        case slice_node(source, value_ast) do
          {:ok, val_text} -> {:ok, key_atom, val_text}
          :error -> :error
        end
      end)

    if pairs |> Enum.any?(&(&1 == :error)) do
      []
    else
      kw_list =
        pairs |> Enum.map_join(", ", fn {:ok, key, val} -> "#{key}: #{val}" end)

      callee_text = render_callee(signature)
      replacement = "#{lhs_name} = #{lhs_name} |> #{callee_text}(#{kw_list})"

      first_range = Sourceror.get_range(first_node)
      last_range = Sourceror.get_range(last_node)

      range = %{
        end: last_range.end,
        start: first_range.start
      }

      [Patch.new(range, replacement, false)]
    end
  end

  defp step_end(step) do
    case step do
      {_form, meta, _args} when is_list(meta) ->
        case Keyword.get(meta, :closing) do
          [line: l, column: c] -> [line: l, column: c + 1]
          _ -> ast_range_end(step)
        end

      _ ->
        ast_range_end(step)
    end
  end

  defp step_end_pos({:other_step, step}), do: step |> step_end()
  defp step_end_pos({:assign_step, _, _, _, step}), do: step |> step_end()
  defp step_end_pos({:merged, _, _pairs, last_step}), do: last_step |> step_end()
  defp step_end_pos(_), do: nil

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp text_or_nil({:ok, text}), do: text
  defp text_or_nil(:error), do: nil

  defp widen_only_patch(import_node, only_list_ast, _source) do
    pairs = only_list_atoms(only_list_ast)
    widened = [{:assign, 2} | pairs] |> Enum.uniq() |> Enum.sort()
    rendered = widened |> Enum.map_join(", ", fn {name, arity} -> "#{name}: #{arity}" end)

    range = Sourceror.get_range(only_list_ast) || Sourceror.get_range(import_node)
    Patch.new(range, "[" <> rendered <> "]", false)
  end

  defp widen_patches_for_only_list({:ok, only_list_ast}, node, source) do
    names = only_list_atoms(only_list_ast)

    if {:assign, 3} in names and {:assign, 2} not in names do
      [widen_only_patch(node, only_list_ast, source)]
    else
      []
    end
  end

  defp widen_patches_for_only_list(:error, _node, _source), do: []
end
