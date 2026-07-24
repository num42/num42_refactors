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
        |> compute_net()
        |> format_total()
      end

      defp compute_net(order) do
        subtotal = sum_lines(order)
        discount = lookup_discount(order)
        net = subtotal - discount
        net
      end

      defp format_total(net) do
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
  - `:min_phases` (default `3`)
  - `:max_carriers` (default `3`)

  ## Naming: derive or decline (no placeholder)

  Each phase must earn a *meaningful* name from what it does and produces
  (`compute_net`, `format_total`) via `HelperNaming`. There is **no
  `<fn>_phase_n` placeholder fallback**: a `report_phase_1 |> report_phase_2`
  chain names nothing the original didn't and reads as machinery (#375,
  mirrors `ExtractPipelineToFunction`). If *any* phase — including the final
  tail phase, which has no live-out and so rarely yields a verb+object name —
  cannot be named, the whole split is **declined**. In practice this makes
  the refactor conservative: a body is split only when every phase has a
  nameable result, otherwise it is left as the original straight-line body.

  ## Pass scope & idempotence

  Every eligible function is split in a single pass into its *maximally
  fine* partition: `group_phases/2` cuts at every clean data-flow boundary
  at once, so a body that splits becomes a flat pipe/binding chain of named
  phase helpers, each already as short as the `min_statements_per_phase`
  floor allows. A re-run finds the host is now a chain and the helpers are
  minimal, so it is a no-op. As a defensive backstop a `defp` already named
  `<host>_phase_<int>` (legacy output from before the naming gate) is never
  re-split.

  ## Default-OFF (opt-in only)

  Disabled by default — `transform/2` is a no-op unless its own opts
  carry `enabled: true`. Cutting a body into pipeline phases is a
  structural judgement call: not every data-flow boundary is a
  responsibility boundary, so the split can fragment a coherent function
  into phases that read as machinery. Opt in per project where the trade
  is wanted:

      configured_modules: [
        {Number42.Refactors.Ex.SplitPipeableResponsibilities, enabled: true}
      ]
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Analysis.BlockSegmentation
  alias Number42.Refactors.Analysis.HelperNaming

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
         mod_ast,
         _source,
         opts
       )
       when kind in [:def, :defp] and is_list(body_kw) do
    with {fn_name, params} <- extract_fn_signature(strip_when(head)),
         false <- split_output?(fn_name),
         true <- suffixable_name?(fn_name),
         true <- single_clause?(def_node, mod_ast),
         {:ok, param_names} <- bare_param_names(params),
         {:ok, body} <- do_body(body_kw),
         exprs = body_to_exprs(body),
         :ok <- ensure_splittable(exprs),
         segments = BlockSegmentation.segment(exprs),
         phases = BlockSegmentation.group_phases(segments, group_opts(opts)),
         true <- length(phases) >= Keyword.get(group_opts(opts), :min_phases, 3),
         param_set = MapSet.new(param_names),
         {:ok, plan} <- plan_phases(phases, param_set, fn_name, existing_names) do
      build_split(def_node, plan, def_node)
    else
      :decline -> []
      _ -> []
    end
  end

  defp split_for_def(_, _existing, _mod, _source, _opts), do: []

  # A helper this refactor itself emitted (`<host>_phase_<int>`). The
  # maximal partition keeps most hosts single-pass, but a fan-in body
  # (many independent bindings feeding one tail) can only cut once under
  # `max_carriers` — its generated tail helper, with carriers now passed
  # as params, has a narrower cut profile and would otherwise re-split
  # into `_phase_2_phase_1`. Skipping anything already named `_phase_<n>`
  # is the safety net that makes the refactor single-pass idempotent.
  @phase_suffix ~r/_phase_\d+$/
  defp split_output?(fn_name), do: fn_name |> Atom.to_string() |> String.match?(@phase_suffix)

  # Helper names are formed as `<fn_name>_phase_<n>`. A `!`/`?` host name
  # can't carry that suffix — `foo!_phase_1` parses as `foo!(_phase_1)`.
  defp suffixable_name?(fn_name), do: not String.ends_with?(Atom.to_string(fn_name), ["!", "?"])

  # A function defined by more than one clause of the same name+arity.
  # Splitting one clause would insert the `phase_n` helpers between the
  # group's clauses (and a `do:`-shorthand clause has no `end` token to
  # anchor the insert on at all). Conservative skip for the whole group.
  defp single_clause?({kind, _, [head, _]}, mod_ast) do
    sig = clause_sig(kind, head)

    mod_ast
    |> module_body_exprs()
    |> Enum.count(fn
      {k, _, [h, _]} when k in [:def, :defp] -> clause_sig(k, h) == sig
      _ -> false
    end) <= 1
  end

  defp clause_sig(kind, head) do
    case extract_fn_signature(strip_when(head)) do
      {name, params} -> {kind, name, length(params)}
      _ -> :unknown
    end
  end

  defp group_opts(opts) do
    [
      min_statements_per_phase: Keyword.get(opts, :min_statements_per_phase, 2),
      min_phases: Keyword.get(opts, :min_phases, 3),
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
  #
  # Each phase is named after what it does and produces (via
  # HelperNaming) — `fetch_brands`, `compute_totals` — not the
  # positional `<fn>_phase_n`. Names are reserved as they are assigned so
  # two phases never collide; a phase HelperNaming can't name (no verb,
  # no meaningful live-out — typical of the final tail phase) falls back
  # to `<fn>_phase_n`.
  # Each phase must earn a *meaningful* name from what it does and produces
  # (`fetch_brands`, `compute_totals`). There is no `<fn>_phase_n`
  # placeholder fallback: a chain of `report_phase_1 |> report_phase_2`
  # names nothing the original didn't and reads as machinery (#375, mirrors
  # `ExtractPipelineToFunction`). If *any* phase can't be named, the whole
  # split is **declined** — a partition no one can name reads better as the
  # original straight-line body.
  defp plan_phases(phases, param_set, fn_name, existing_names) do
    indexed = Enum.with_index(phases, 1)
    written_before = writes_before(phases)

    Enum.reduce_while(indexed, {[], existing_names}, fn {phase, n}, {acc, taken} ->
      params = phase_params(phase, n, param_set, written_before)
      live_out = phase_live_out(phase, phases, n)
      stmts = Enum.map(phase, & &1.ast)

      case HelperNaming.name(fn_name, live_out, stmts, params, taken, fallback: :none) do
        {:ok, helper} ->
          entry = %{helper: helper, params: params, live_out: live_out, stmts: stmts}
          {:cont, {[entry | acc], MapSet.put(taken, helper)}}

        :skip ->
          {:halt, :decline}
      end
    end)
    |> case do
      :decline -> :decline
      {plan, _taken} -> {:ok, Enum.reverse(plan)}
    end
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

  defp build_split(def_node, plan, insert_anchor) do
    host_body = render_host_body(plan)
    helper_texts = Enum.map(plan, &render_helper/1)

    case body_interior_range(def_node) do
      %{} = range ->
        body_patch = %{change: "\n#{indent(host_body)}\n  ", range: range}
        insert_patches = helper_insert_patches(insert_anchor, helper_texts)
        [body_patch | insert_patches]

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

  # Insert helpers right after the anchor clause's `end` token. Anchored
  # on `meta[:end]` (token-exact) rather than `Sourceror.get_range/1`,
  # which undercounts a def ending in an interpolated/escaped-quote string
  # and would splice the helpers inside that string literal.
  defp helper_insert_patches({_kind, meta, _}, helper_texts) do
    case Keyword.get(meta, :end) do
      [line: end_line, column: end_col] ->
        pos = [line: end_line, column: end_col + 3]
        joined = Enum.map_join(helper_texts, "", fn t -> "\n\n" <> t end)
        [%{change: joined, range: %{start: pos, end: pos}}]

      _ ->
        []
    end
  end

  # The span between the `do` and `end` tokens of the function head,
  # replaced in one patch. Per-statement `Sourceror.get_range/1` undercounts
  # the end column of an interpolated/escaped-quote string tail, which left
  # the closing `"` behind as a stub; token positions from the def meta are
  # exact regardless of literal shape.
  defp body_interior_range({_kind, meta, _}) do
    with [line: do_line, column: do_col] <- Keyword.get(meta, :do),
         [line: end_line, column: end_col] <- Keyword.get(meta, :end) do
      %{start: [line: do_line, column: do_col + 2], end: [line: end_line, column: end_col]}
    else
      _ -> :error
    end
  end

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
