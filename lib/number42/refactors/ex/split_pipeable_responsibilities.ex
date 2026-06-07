defmodule Number42.Refactors.Ex.SplitPipeableResponsibilities do
  @moduledoc """
  Splits a long, pipeable function body into named `defp` phases joined
  by a pipe or a tuple-binding chain, using per-statement data-flow
  (`BlockSegmentation`) to find narrow cut points.

      # before
      def report(order) do
        subtotal = sum_lines(order)
        discount = lookup_discount(order)
        net = subtotal - discount
        doubled = net * 2
        adjusted = doubled + 1
        format(adjusted)
      end

      # after
      def report(order) do
        order
        |> report_phase_1()
        |> report_phase_2()
      end

      defp report_phase_1(order) do
        subtotal = sum_lines(order)
        discount = lookup_discount(order)
        net = subtotal - discount
        net
      end

      defp report_phase_2(net) do
        doubled = net * 2
        adjusted = doubled + 1
        format(adjusted)
      end

  ## How phases are chosen

  The body is segmented per statement and partitioned at the
  data-flow boundaries with the fewest crossing carriers
  (`BlockSegmentation.group_phases/2`). A boundary that carries a
  single value lets the next phase be a plain pipe; a boundary carrying
  2–3 values becomes a tuple binding (`{a, b} = phase_n(...)`).

  ## Requirements (otherwise skip the whole function)

  - **No side effects.** A body that calls `Repo.`/`Logger.`/`send`/
    `GenServer.`/`File.`/`IO.`/`Agent.`/`Task.`/`Process.`/`:ets`, or any
    bang function (`foo!`), is left untouched — reordering or relocating
    an effect across a phase boundary risks changing observable
    behaviour. This is the high-risk axis of the refactor; conservative
    skip is correct.
  - **No control flow.** `case`/`cond`/`if`/`with`/`for`/`fn`/`try`/
    `receive`/`raise`/`throw`/`exit` in the body — control flow can't be
    cleanly cut into value-returning phases.
  - **No module attributes.** An attribute-parameterised phase is
    subtle; conservative skip for v1 (matches `ExtractFunctionFromBlock`).
  - **A clean partition exists.** At least `min_phases` phases of at
    least `min_statements_per_phase` statements each, with every
    crossing boundary at most `max_carriers` wide.

  ## Options

  - `:min_statements_per_phase` (default `2`)
  - `:min_phases` (default `2`)
  - `:max_carriers` (default `3`)

  ## Pass scope & idempotence

  Every eligible function in the module is split in a single pass. After
  a split the host body is a pipe/binding chain of `phase_n` calls — no
  longer a multi-binding run — so a second pass finds nothing to split.
  The generated `phase_n` helpers each end in a value return, which is
  itself not re-splittable under the constraints.

  ## Default-OFF (opt-in only)

  Disabled by default — `transform/2` is a no-op unless its own opts carry
  `enabled: true`. A dogfood run surfaced rewrites that drop a function's
  tail expression (producing an unterminated string literal and empty
  statement stubs). Enable per project once the phase split preserves the
  host's return:

      configured_modules: [
        {Number42.Refactors.Ex.SplitPipeableResponsibilities, enabled: true}
      ]
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.BlockSegmentation

  @control_flow_forms ~w(raise throw exit with case cond if unless try for fn receive)a
  @effect_modules ~w(Repo Logger GenServer File IO Agent Task Process)a

  @impl Number42.Refactors.Refactor
  def description,
    do: "Split a long pipeable function into named defp phases joined by a pipe/binding chain"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A long function that threads a value through a sequence of binding
    steps is several responsibilities in a trench coat. Cutting it at the
    narrowest data-flow boundaries into named `defp` phases — each phase's
    free variables as parameters, the values the next phase needs as its
    return — names each responsibility and turns the host into a readable
    pipe (or tuple-binding) chain. Functions with side effects or control
    flow are skipped: relocating an effect across a phase boundary, or
    cutting through a branch, would change behaviour.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      Sourceror.parse_string(source) |> apply_to_parse_result(source, opts)
    else
      source
    end
  end

  defp apply_to_parse_result({:ok, ast}, source, opts), do: apply_to_ast(ast, source, opts)
  defp apply_to_parse_result({:error, _}, source, _opts), do: source

  defp apply_to_ast(ast, source, opts) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value(source, fn
      {:defmodule, _, [_name, [{_do, _body}]]} = mod_ast ->
        split_module(mod_ast, source, opts)

      _ ->
        nil
    end)
  end

  defp split_module(mod_ast, source, opts) do
    body_exprs = module_body_exprs(mod_ast)

    case body_exprs && eligible_splits(body_exprs, mod_ast, source, opts) do
      [_ | _] = patches -> patch_or_passthrough(source, patches)
      _ -> nil
    end
  end

  defp eligible_splits(body_exprs, mod_ast, source, opts) do
    existing_names = def_names(body_exprs)

    body_exprs
    |> Enum.flat_map(fn expr -> split_for_def(expr, existing_names, mod_ast, source, opts) end)
  end

  defp split_for_def(
         {kind, _, [head, body_kw]} = def_node,
         existing_names,
         _mod_ast,
         source,
         opts
       )
       when kind in [:def, :defp] and is_list(body_kw) do
    with {fn_name, params} <- extract_fn_signature(strip_when(head)),
         {:ok, param_names} <- bare_param_names(params),
         {:ok, body} <- do_body(body_kw),
         exprs = body_to_exprs(body),
         :ok <- ensure_splittable(exprs),
         segments = BlockSegmentation.segment(exprs),
         phases = BlockSegmentation.group_phases(segments, group_opts(opts)),
         true <- length(phases) >= Keyword.get(group_opts(opts), :min_phases, 2),
         param_set = MapSet.new(param_names),
         {:ok, plan} <- plan_phases(phases, param_set, fn_name, existing_names) do
      build_split(def_node, plan, source)
    else
      _ -> []
    end
  end

  defp split_for_def(_, _existing, _mod, _source, _opts), do: []

  defp group_opts(opts) do
    [
      min_statements_per_phase: Keyword.get(opts, :min_statements_per_phase, 2),
      min_phases: Keyword.get(opts, :min_phases, 2),
      max_carriers: Keyword.get(opts, :max_carriers, 3)
    ]
  end

  # --- eligibility ---

  defp ensure_splittable(exprs) do
    cond do
      Enum.any?(exprs, &has_side_effect?/1) -> :skip
      Enum.any?(exprs, &has_control_flow?/1) -> :skip
      Enum.any?(exprs, &references_attribute?/1) -> :skip
      true -> :ok
    end
  end

  defp has_control_flow?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {form, _, _} when form in @control_flow_forms -> true
      _ -> false
    end)
  end

  defp references_attribute?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:@, _, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) -> true
      _ -> false
    end)
  end

  defp has_side_effect?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(&effectful_node?/1)
  end

  # `Mod.fun(...)` where Mod is a known effect module.
  defp effectful_node?({{:., _, [{:__aliases__, _, [mod]}, _fun]}, _, _args})
       when mod in @effect_modules,
       do: true

  # Erlang-module effect call like `:ets.insert(...)`.
  defp effectful_node?({{:., _, [:ets, _fun]}, _, _args}), do: true

  # `send(pid, msg)` — bare local call.
  defp effectful_node?({:send, _, args}) when is_list(args), do: true

  # Any bang function call `foo!(...)` (local or remote).
  defp effectful_node?({:., _, [_mod, fun]}) when is_atom(fun), do: bang?(fun)
  defp effectful_node?({fun, _, args}) when is_atom(fun) and is_list(args), do: bang?(fun)
  defp effectful_node?(_), do: false

  defp bang?(fun), do: fun |> Atom.to_string() |> String.ends_with?("!")

  # --- phase planning ---

  # For each phase: parameters = free vars (read in this phase, written
  # by an earlier phase or a function param), return = live-out vars
  # (written here, read by a later phase) — or, for the final phase, its
  # natural tail value (no synthetic return appended).
  defp plan_phases(phases, param_set, fn_name, existing_names) do
    indexed = Enum.with_index(phases, 1)
    written_before = writes_before(phases)

    plan =
      Enum.map(indexed, fn {phase, n} ->
        helper = :"#{fn_name}_phase_#{n}"
        params = phase_params(phase, n, param_set, written_before)
        live_out = phase_live_out(phase, phases, n)
        %{helper: helper, params: params, live_out: live_out, stmts: Enum.map(phase, & &1.ast)}
      end)

    if Enum.any?(plan, &MapSet.member?(existing_names, &1.helper)),
      do: :skip,
      else: {:ok, plan}
  end

  # Names available to phase n as inputs: original params + everything
  # written by phases 1..n-1.
  defp phase_params(phase, n, param_set, written_before) do
    available = MapSet.union(param_set, Map.get(written_before, n, MapSet.new()))

    phase
    |> Enum.reduce(MapSet.new(), fn seg, acc -> MapSet.union(acc, seg.reads) end)
    |> MapSet.intersection(available)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  # Names written in this phase and read by any later phase. The final
  # phase has no later reader → empty (its tail value is the return).
  defp phase_live_out(_phase, phases, n) when n == length(phases), do: []

  defp phase_live_out(phase, phases, n) do
    written_here =
      phase
      |> Enum.reduce(MapSet.new(), fn seg, acc -> MapSet.union(acc, seg.writes) end)

    read_after =
      phases
      |> Enum.drop(n)
      |> Enum.flat_map(fn p -> Enum.flat_map(p, &MapSet.to_list(&1.reads)) end)
      |> MapSet.new()

    written_here |> MapSet.intersection(read_after) |> MapSet.to_list() |> Enum.sort()
  end

  defp writes_before(phases) do
    phases
    |> Enum.with_index(1)
    |> Enum.reduce({MapSet.new(), %{}}, fn {phase, n}, {acc_writes, map} ->
      map = Map.put(map, n, acc_writes)
      phase_writes = Enum.reduce(phase, MapSet.new(), fn s, a -> MapSet.union(a, s.writes) end)
      {MapSet.union(acc_writes, phase_writes), map}
    end)
    |> elem(1)
  end

  # --- patch construction ---

  defp build_split(def_node, plan, _source) do
    host_body = render_host_body(plan)
    helper_texts = Enum.map(plan, &render_helper/1)

    case body_ranges(def_node) do
      {first_range, delete_patches} ->
        body_patch = %{change: host_body, range: first_range}
        insert_patches = helper_insert_patches(def_node, helper_texts)
        [body_patch | delete_patches] ++ insert_patches

      :error ->
        []
    end
  end

  # Replace the host's do-block body with the phase chain. A pipe when
  # every transition carries exactly one value into the next phase's
  # sole pipeable slot; otherwise an explicit binding chain.
  defp render_host_body(plan) do
    if pipeable_chain?(plan), do: render_pipe_chain(plan), else: render_binding_chain(plan)
  end

  # Pipeable iff phase 1 takes a single param, and every phase n>1 takes
  # exactly the single value the previous phase returned (so the carrier
  # threads as the leading pipe argument with no extra params).
  defp pipeable_chain?([first | rest]) do
    length(first.params) == 1 and
      rest
      |> Enum.with_index()
      |> Enum.all?(fn {phase, i} ->
        prev = Enum.at([first | rest], i)
        prev_return = prev.live_out
        length(prev_return) == 1 and phase.params == prev_return
      end)
  end

  defp pipeable_chain?(_), do: false

  defp render_pipe_chain([first | rest]) do
    [arg] = first.params
    head = "#{arg}\n|> #{first.helper}()"

    rest
    |> Enum.map(fn phase -> "|> #{phase.helper}()" end)
    |> then(fn tail -> Enum.join([head | tail], "\n") end)
  end

  defp render_binding_chain(plan), do: Enum.map_join(plan, "\n", &phase_call_line/1)

  defp phase_call_line(%{helper: helper, params: params, live_out: live_out}) do
    call = "#{helper}(#{Enum.map_join(params, ", ", &Atom.to_string/1)})"

    case live_out do
      [] -> call
      [single] -> "#{single} = #{call}"
      many -> "{#{Enum.map_join(many, ", ", &Atom.to_string/1)}} = #{call}"
    end
  end

  defp render_helper(%{helper: helper, params: params, live_out: live_out, stmts: stmts}) do
    args = Enum.map_join(params, ", ", &Atom.to_string/1)
    body_text = stmts |> Enum.map_join("\n", &Sourceror.to_string/1)
    return_text = return_value(live_out)

    inner = if return_text == "", do: body_text, else: body_text <> "\n" <> return_text

    "  defp #{helper}(#{args}) do\n" <> indent(inner) <> "\n  end"
  end

  defp return_value([]), do: ""
  defp return_value([single]), do: Atom.to_string(single)
  defp return_value(many), do: "{" <> Enum.map_join(many, ", ", &Atom.to_string/1) <> "}"

  defp helper_insert_patches(def_node, helper_texts) do
    case Sourceror.get_range(def_node) do
      %{end: end_pos} ->
        joined = Enum.map_join(helper_texts, "", fn t -> "\n\n" <> t end)
        [%{change: joined, range: %{start: end_pos, end: end_pos}}]

      _ ->
        []
    end
  end

  # The range of the first body statement, plus delete-patches covering
  # the remaining statements (their ranges replaced with "").
  defp body_ranges(def_node) do
    with {:ok, body} <- def_body(def_node),
         [first | rest] <- body_to_exprs(body),
         %{} = first_range <- Sourceror.get_range(first) do
      delete = Enum.map(rest, fn s -> %{change: "", range: Sourceror.get_range(s)} end)
      {first_range, delete}
    else
      _ -> :error
    end
  end

  # build_split needs the delete-patches too; recompute and prepend.
  defp def_body({_kind, _, [_head, body_kw]}) when is_list(body_kw), do: do_body(body_kw)
  defp def_body(_), do: :skip

  # --- shared helpers ---

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

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "    " <> line
    end)
  end

  defp patch_or_passthrough(source, patches), do: Sourceror.patch_string(source, patches)
end
