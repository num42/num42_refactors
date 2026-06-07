defmodule Number42.Refactors.Ex.ExtractFunctionFromBlock do
  @moduledoc """
  Extracts a coherent leading block of bindings out of a function body
  into a private helper. Free variables become parameters; bindings the
  rest of the body still reads become the helper's return value.

      # before
      def report(order) do
        subtotal = sum_lines(order)
        tax = subtotal * region_rate(order)
        total = subtotal + tax
        format(total, tax)
      end

      # after
      def report(order) do
        {total, tax} = report_block(order)
        format(total, tax)
      end

      defp report_block(order) do
        subtotal = sum_lines(order)
        tax = subtotal * region_rate(order)
        total = subtotal + tax
        {total, tax}
      end

  ## Which block is extracted

  The **maximal leading run of bare-variable bindings** — the
  contiguous prefix `var = expr; …` before the first non-binding (tail)
  statement. This is the safest slice: a run of `=`-bindings has no
  hidden control flow, and everything live after it is recoverable from
  the bound names.

  Requirements (otherwise skip):

  - The prefix is **at least two** bindings, and there is **at least
    one** tail statement after it (extracting the whole body, or a
    single binding, is pointless / a different refactor's job).
  - Every prefix statement is `bare_var = rhs` — no pattern-match LHS,
    no non-binding statement mixed in.
  - The prefix performs **no non-local control flow** — no `raise`,
    `throw`, `exit`, `with`, `case`/`cond`/`if`/`try`, `for`, `fn`, or
    early-return shape that would determine the function's tail. Such a
    construct can't be moved behind a value-returning call.
  - The prefix references **no module attribute** (`@rate`) — the
    helper is a sibling `defp` and attributes are in scope, but an
    attribute-parameterised block is subtle; conservative skip for v1.
  - No prefix binding contains **string interpolation or a sigil**
    (`"… \#{x} …"`, `~H` templates). Interpolation carries implicit
    reads and a multi-line heredoc range Sourceror can't slice
    precisely, so a range-patch relocation would leave a dangling
    triple-quote in the host.

  ## Parameters and return

  - **Parameters** = the prefix's free variables (`AstHelpers.free_vars/2`
    over the prefix, restricted to the host's parameters). Because the
    prefix leads the body, a free var can only resolve to a parameter,
    so only the parameters the prefix actually reads are threaded — not
    the whole signature.
  - **Return** = the prefix-bound names that are still read in the tail.
    One live-out binding returns the bare value
    (`total = report_block(order)`); two or more return a tuple
    (`{total, tax} = report_block(order)`). At least one is required.

  ## Idempotence & determinism

  At most **one** function is extracted per pass — the first eligible
  in source order. After extraction the host body's prefix is a single
  `… = helper(…)` call, so the maximal-binding-prefix scan no longer
  finds an extractable run there; the engine's fixpoint loop handles
  other functions on later passes.

  ## Extraction safety

  The helper's parameters are the prefix's free variables only (not the
  whole host signature), so no unused-argument warnings. Bindings holding
  string interpolation or a sigil are skipped — relocating an interpolated
  heredoc by range patch left a dangling `\"""` in the host.
  """

  use Number42.Refactors.Refactor

  @control_flow_forms ~w(raise throw exit with case cond if unless try for fn receive)a

  @impl Number42.Refactors.Refactor
  def description,
    do:
      "Extract a leading binding block into a private function (free vars → params, live → return)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A function that opens with a run of bindings computing intermediate
    values, then does its real work, hides a cohesive sub-computation
    inside its prologue. Lifting that prologue into a named `defp` —
    free variables as parameters, the values the rest of the body still
    needs as a (possibly tuple) return — gives the sub-computation a
    name and shrinks the host to its essential shape. Conservative:
    only a clean leading run of bare-variable bindings with no control
    flow and no module-attribute dependency is moved.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts) do
    Sourceror.parse_string(source) |> apply_to_parse_result(source)
  end

  defp apply_to_parse_result({:ok, ast}, source), do: apply_to_ast(ast, source)
  defp apply_to_parse_result({:error, _}, source), do: source

  defp apply_to_ast(ast, source) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value(source, fn
      {:defmodule, _, [_name, [{_do, _body}]]} = mod_ast ->
        mod_ast
        |> module_body_exprs()
        |> first_extraction(mod_ast, source)

      _ ->
        nil
    end)
  end

  defp first_extraction(nil, _mod_ast, _source), do: nil

  defp first_extraction(body_exprs, _mod_ast, source) do
    existing_names = def_names(body_exprs)
    multi_keys = multi_clause_keys(body_exprs)

    body_exprs
    |> Enum.find_value(fn expr ->
      extraction_for_def(expr, existing_names, multi_keys, source)
    end)
  end

  defp extraction_for_def(
         {kind, _, [head, body_kw]} = def_node,
         existing_names,
         multi_keys,
         source
       )
       when kind in [:def, :defp] and is_list(body_kw) do
    with {fn_name, params} <- extract_fn_signature(strip_when(head)),
         false <- MapSet.member?(multi_keys, {fn_name, length(params)}),
         {:ok, param_names} <- bare_param_names(params),
         {:ok, body} <- do_body(body_kw),
         exprs = body_to_exprs(body),
         {:ok, prefix, tail} <- maximal_binding_prefix(exprs),
         :ok <- ensure_extractable(prefix),
         true <- meaningful_tail?(tail),
         args = prefix_free_vars(prefix, param_names),
         live_out = live_out_bindings(prefix, tail),
         {:ok, helper_name} <- helper_name(fn_name, existing_names) do
      build_extraction(prefix, live_out, args, helper_name, def_node, source)
    else
      _ -> nil
    end
  end

  defp extraction_for_def(_, _existing_names, _multi_keys, _source), do: nil

  # --- block selection ---

  # The maximal leading run of `var = rhs` bindings, returned with the
  # remaining tail. Requires >= 2 bindings and >= 1 tail statement.
  defp maximal_binding_prefix(exprs) do
    prefix = Enum.take_while(exprs, &simple_binding?/1)
    k = length(prefix)
    tail = Enum.drop(exprs, k)

    if k >= 2 and tail != [], do: {:ok, prefix, tail}, else: :skip
  end

  defp simple_binding?({:=, _, [lhs, _rhs]}),
    do: match?({name, _, ctx} when is_atom(name) and is_atom(ctx), lhs)

  defp simple_binding?(_), do: false

  # The tail must do real work — at least one statement that is not a
  # bare variable / tuple / literal. A tail that is only a value-return
  # (`{tax, total}` / `total`) makes extraction circular: the
  # synthesised helper's own body would be `prefix; {…}`, which the next
  # pass would extract again (`report_block` → `report_block_block`).
  # Requiring a meaningful tail keeps the rewrite idempotent.
  defp meaningful_tail?(tail), do: Enum.any?(tail, &does_work?/1)

  # Sourceror wraps a single bare expression in `{:__block__, _, [inner]}`
  # — unwrap before deciding, so a `{tax, total}` value-return reads as
  # the tuple it is, not as an opaque block.
  defp does_work?({:__block__, _, [inner]}), do: does_work?(inner)
  defp does_work?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: false
  defp does_work?({:{}, _, elems}), do: Enum.any?(elems, &does_work?/1)
  defp does_work?(lit) when is_atom(lit) or is_number(lit) or is_binary(lit), do: false
  defp does_work?({a, b}), do: does_work?(a) or does_work?(b)
  defp does_work?(_), do: true

  # --- eligibility ---

  defp ensure_extractable(prefix) do
    cond do
      Enum.any?(prefix, &references_attribute?/1) -> :skip
      Enum.any?(prefix, &has_control_flow?/1) -> :skip
      Enum.any?(prefix, &has_interpolation_or_sigil?/1) -> :skip
      true -> :ok
    end
  end

  # String interpolation (`{:<<>>, _, _}`) and sigils (`~H`, `~s`, …)
  # carry implicit reads (`@assigns`) and multi-line heredoc ranges that
  # Sourceror can't slice precisely — relocating such a binding by range
  # patch leaves a dangling heredoc terminator in the host. Skip rather
  # than corrupt.
  defp has_interpolation_or_sigil?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:<<>>, _, _} -> true
      {form, _, _} when is_atom(form) -> sigil?(form)
      _ -> false
    end)
  end

  defp sigil?(form), do: form |> Atom.to_string() |> String.starts_with?("sigil_")

  defp references_attribute?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:@, _, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) -> true
      _ -> false
    end)
  end

  defp has_control_flow?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {form, _, _} when form in @control_flow_forms -> true
      _ -> false
    end)
  end

  # --- data-flow ---

  # The prefix's free variables, restricted to the host's parameters and
  # kept in parameter-declaration order. Because the prefix leads the
  # body, a free var can only resolve to a parameter — so these are
  # exactly the helper's arguments. Threading every parameter instead
  # would leave the helper with unused arguments (warnings-as-errors).
  #
  # Scanned **left-to-right**, accumulating bound names: a name is free
  # only on a read that precedes its own binding. A binding that shadows
  # a parameter and reads it on the RHS (`s = s / 100`) is therefore
  # still a free read of that parameter — a whole-block `used - bound`
  # would wrongly cancel it.
  defp prefix_free_vars(prefix, param_names) do
    params = MapSet.new(param_names)

    {free, _bound} =
      Enum.reduce(prefix, {MapSet.new(), MapSet.new()}, fn {:=, _, [lhs, rhs]}, {free, bound} ->
        reads = used_var_names(rhs) |> MapSet.difference(bound) |> MapSet.intersection(params)
        {MapSet.union(free, reads), MapSet.union(bound, MapSet.new(pattern_var_names(lhs)))}
      end)

    Enum.filter(param_names, &MapSet.member?(free, &1))
  end

  defp live_out_bindings(prefix, tail) do
    read_in_tail =
      tail |> Enum.map(&used_var_names/1) |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    # A prefix-bound name is live-out if the tail references it anywhere.
    # `used_var_names` (a plain read set, no binding subtraction) is the
    # safe side: a `cond`/`with` clause head reads its test vars, and
    # over-returning a value the tail happens to rebind is harmless,
    # while under-returning leaves the tail with an undefined variable.
    prefix
    |> Enum.map(&binding_name/1)
    |> Enum.filter(&MapSet.member?(read_in_tail, &1))
    |> Enum.uniq()
  end

  defp binding_name({:=, _, [{name, _, ctx}, _]}) when is_atom(name) and is_atom(ctx), do: name

  # --- helper naming ---

  defp helper_name(fn_name, existing_names) do
    candidate = suffixed_name(fn_name, "_block")
    if MapSet.member?(existing_names, candidate), do: :skip, else: {:ok, candidate}
  end

  # Append `_block` to the source name, but keep a trailing `!`/`?` at
  # the very end — `verify_siblings!` must become `verify_siblings_block!`,
  # not the illegal `verify_siblings!_block` (a bang is only valid as the
  # final character of an identifier).
  defp suffixed_name(fn_name, suffix) do
    name = Atom.to_string(fn_name)

    case String.split_at(name, -1) do
      {stem, marker} when marker in ["!", "?"] -> :"#{stem}#{suffix}#{marker}"
      {_, _} -> :"#{name}#{suffix}"
    end
  end

  defp def_names(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {kind, _, [head | _]} when kind in [:def, :defp] ->
        case extract_fn_signature(strip_when(head)) do
          {name, _args} -> [name]
          _ -> []
        end

      _ ->
        []
    end)
    |> MapSet.new()
  end

  # `{name, arity}` keys defined by more than one clause. The helper is
  # inserted as a sibling directly after the host clause; doing that to
  # one clause of a multi-clause function splits the group ("clauses
  # with the same name and arity should be grouped together"). Skip
  # multi-clause hosts rather than reorder the module.
  defp multi_clause_keys(body_exprs) do
    body_exprs
    |> Enum.flat_map(&def_arity_key/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(fn {key, _count} -> key end)
    |> MapSet.new()
  end

  defp def_arity_key({kind, _, [head | _]}) when kind in [:def, :defp] do
    case extract_fn_signature(strip_when(head)) do
      {name, args} -> [{name, length(args)}]
      _ -> []
    end
  end

  defp def_arity_key(_), do: []

  # --- patch construction ---

  defp build_extraction([], _live_out, _params, _helper, _def_node, _source), do: nil
  defp build_extraction(_prefix, [], _params, _helper, _def_node, _source), do: nil

  defp build_extraction(prefix, live_out, param_names, helper_name, def_node, source) do
    call_args = Enum.map_join(param_names, ", ", &Atom.to_string/1)
    call_text = "#{helper_name}(#{call_args})"
    lhs_text = return_lhs(live_out)

    [first | rest] = prefix
    replace_patch = patch_for(Sourceror.get_range(first), "#{lhs_text} = #{call_text}")
    delete_patches = Enum.map(rest, &patch_for(Sourceror.get_range(&1), ""))

    helper_text = render_helper(helper_name, param_names, prefix, live_out)
    insert_patch = helper_insert_patch(def_node, helper_text)

    patches = [replace_patch, insert_patch | delete_patches] |> Enum.reject(&is_nil/1)
    patch_or_passthrough(source, patches)
  end

  # Insert the helper as a sibling `defp` immediately after the host
  # function — a zero-width patch at the end of the host def's range.
  # Sibling placement keeps it in the same module and needs no
  # module-end search (multi-module safe).
  defp helper_insert_patch(def_node, helper_text) do
    case Sourceror.get_range(def_node) do
      %{end: end_pos} -> %{change: "\n\n" <> helper_text, range: %{start: end_pos, end: end_pos}}
      _ -> nil
    end
  end

  defp return_lhs([single]), do: Atom.to_string(single)
  defp return_lhs(live_out), do: "{" <> Enum.map_join(live_out, ", ", &Atom.to_string/1) <> "}"

  defp render_helper(helper_name, param_names, prefix, live_out) do
    args = Enum.map_join(param_names, ", ", &Atom.to_string/1)
    prefix_text = prefix |> Enum.map_join("\n", &Sourceror.to_string/1)
    return_text = return_value(live_out)

    "  defp #{helper_name}(#{args}) do\n" <>
      indent(prefix_text <> "\n" <> return_text) <>
      "\n  end"
  end

  defp return_value([single]), do: Atom.to_string(single)
  defp return_value(live_out), do: "{" <> Enum.map_join(live_out, ", ", &Atom.to_string/1) <> "}"

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "    " <> line
    end)
  end

  defp patch_for(%{} = range, change), do: %{change: change, range: range}
  defp patch_for(_, _), do: nil

  defp do_body(body_kw) when is_list(body_kw) do
    body_kw
    |> Enum.find_value(:skip, fn
      {{:__block__, _, [:do]}, value} -> {:ok, value}
      {:do, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp do_body(_), do: :skip

  defp bare_param_names(params) do
    params
    |> Enum.reduce_while([], fn param, acc ->
      case bare_var(param) do
        {:ok, name} -> {:cont, [name | acc]}
        :skip -> {:halt, :skip}
      end
    end)
    |> case do
      :skip -> :skip
      names -> {:ok, Enum.reverse(names)}
    end
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp patch_or_passthrough(source, []), do: source
  defp patch_or_passthrough(source, patches), do: Sourceror.patch_string(source, patches)
end
