defmodule Number42.Refactors.Ex.PushParamIntoCallee do
  @moduledoc """
  When every call site passes the same computed argument at the same
  position, push that computation into the callee and drop the parameter.

      # before
      defmodule MyApp.Worker do
        def run(a), do: process(a, 42)
        def run_other(b), do: process(b, 42)

        defp process(data, factor), do: data * factor
      end

      # after
      defmodule MyApp.Worker do
        def run(a), do: process(a)
        def run_other(b), do: process(b)

        defp process(data), do: data * 42
      end

  ## Why only `defp`

  Dropping a parameter is an arity change at every call site. A private
  function's caller set is bounded by its defining module — the corpus
  always contains all of them. A public `def` could be called from
  outside the corpus (other apps, deps, runtime dispatch), so dropping
  its parameter would silently break callers we can't see. We refuse
  every `def`.

  ## Cross-file context (`prepare/1`)

  Although a `defp`'s callers live in its own module, a module can be
  *reopened* across files. `prepare/1` reads every input source listed
  in `opts[:source_files]` (defaulting to the `.refactor.exs` `:inputs`
  glob), groups defmodule fragments by module name, and proves the
  invariant per module across all fragments. The result is a per-module
  rewrite plan; `transform/2` looks up the plan for the module(s) in the
  file it is handed and patches both the callee and its call sites.

  When called outside the engine (tests, single-file CLI runs) the plan
  can be built inline with `build_plan/1` over `[{path, source}]` tuples.

  ## The invariant (all must hold, else skip)

    1. **Private callee** (`defp`) — see above.
    2. **Every call site** of the callee passes a **syntactically
       identical** expression at the same position. Missing callers,
       diverging values, or any caller at a different arity → skip.
    3. The expression is **pure/total** (`pure?/1`). Pushing it into the
       callee shifts its evaluation timing relative to the other
       arguments and may evaluate it more than once (multiple uses of
       the parameter in the body) — only a pure, total, eager
       expression survives that.
    4. The expression is **context-free**: no call-site-local variables,
       no `@module_attribute`, no `__MODULE__`. These either bind to a
       caller-local value or resolve per-module, so they would not mean
       the same thing inside the callee. What remains — literals and
       pure stdlib calls over literals — resolves identically in any
       module.
    5. **No default args** (`\\`) in the callee head and **no capture**
       (`&fun/arity`) of the callee anywhere in the corpus — both pin
       the old arity.
    6. **No `apply/3`** dispatch to the callee (the function name could
       be reached dynamically at the old arity).
    7. The parameter at the dropped position is a **plain variable** in
       every clause and is **not referenced by a guard** — otherwise
       substituting an expression for a pattern/guard input is unsound.

  Pipe call sites (`x |> callee(arg)`) are skipped: the leading operand
  shifts the argument positions and the position math is an extra hazard
  not worth the rare win.

  ## Idempotence

  After the rewrite the parameter is gone, the callee computes the
  value, and every call site passes one fewer argument. Re-running finds
  no uniformly-passed eligible argument → no change.

  ## Format

  `reformat_after?/0 == true` so the engine runs `mix format` to
  normalize whitespace produced by the patches.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @excluded_path_prefixes ["test/", "dev/"]

  @typedoc """
  One eligible callee rewrite within a module: the callee's
  `{name, arity}` (original arity, before the drop), the parameter
  position to drop, and the expression AST to inline into the body.
  """
  @type spec :: %{name: atom(), arity: arity(), pos: non_neg_integer(), expr: Macro.t()}

  @doc """
  Build a rewrite plan from `[{path, source}]` tuples.

  Returns a map keyed by module atom; each value is the list of
  `t:spec/0` rewrites for that module. Modules absent from the map need
  no rewrite. Exposed so tests can build a plan without the engine.
  """
  @spec build_plan([{String.t(), String.t()}]) :: %{module() => [spec()]}
  def build_plan(sources) do
    sources
    |> Enum.reject(fn {path, _src} -> excluded_path?(path) end)
    |> Enum.flat_map(&module_bodies/1)
    |> Enum.group_by(fn {module, _body} -> module end, fn {_module, body} -> body end)
    |> Enum.flat_map(fn {module, bodies} -> plan_for_module(module, List.flatten(bodies)) end)
    |> Enum.group_by(fn {module, _spec} -> module end, fn {_module, spec} -> spec end)
  end

  @impl Number42.Refactors.Refactor
  def description, do: "Cross-file: drop a uniformly-passed param, push its value into the callee"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    When every caller of a private function passes the same pure,
    context-free expression at the same position, that argument carries
    no information — it is a constant the callee could compute itself.
    Pushing the computation into the callee and dropping the parameter
    removes the repetition at every call site and makes the callee
    self-contained. Restricted to `defp` so the caller set is provably
    complete, and to pure/total context-free expressions so evaluation
    timing and module-scoped resolution stay sound.
    """
  end

  @impl Number42.Refactors.Refactor
  def prepare(opts), do: Keyword.get(opts, :source_files) |> prepared_for_paths()
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, opts),
    do: Keyword.get(opts, :prepared) |> rewrite_with_plan_or_passthrough(source)

  # ── prepare/1 plumbing ────────────────────────────────────────────

  defp prepared_for_paths(nil), do: load_default_sources() |> plan_from_sources()

  defp prepared_for_paths(paths) when is_list(paths) do
    sources = paths |> Enum.map(fn p -> {p, File.read!(p)} end)
    {:ok, build_plan(sources)}
  end

  defp plan_from_sources([]), do: :no_cache
  defp plan_from_sources(sources), do: {:ok, build_plan(sources)}

  defp load_default_sources, do: File.read(".refactor.exs") |> parse_inputs_from_config()

  defp parse_inputs_from_config({:ok, contents}) do
    {config, _} = Code.eval_string(contents)

    Map.get(config, :inputs, [])
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&excluded_path?/1)
    |> Enum.map(fn path -> {path, File.read!(path)} end)
  end

  defp parse_inputs_from_config(_), do: []

  defp excluded_path?(path) do
    normalized = String.trim_leading(path, "./")
    @excluded_path_prefixes |> Enum.any?(&String.starts_with?(normalized, &1))
  end

  defp module_bodies({_path, source}),
    do: Sourceror.parse_string(source) |> module_bodies_or_empty()

  defp module_bodies_or_empty({:ok, ast}) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, module} -> [{module, body_to_exprs(body)}]
          :error -> []
        end

      _ ->
        []
    end)
  end

  defp module_bodies_or_empty({:error, _}), do: []

  # ── Eligibility analysis (per module) ─────────────────────────────

  defp plan_for_module(module, body_exprs) do
    body_exprs
    |> private_clause_groups()
    |> Enum.flat_map(fn {{name, arity}, clauses} ->
      case eligible_spec(name, arity, clauses, body_exprs) do
        {:ok, spec} -> [{module, spec}]
        :skip -> []
      end
    end)
  end

  defp private_clause_groups(body_exprs) do
    body_exprs
    |> Enum.filter(&defp_clause?/1)
    |> Enum.group_by(&clause_name_arity/1)
    |> Enum.reject(fn {key, _} -> key == :skip end)
    |> Enum.filter(fn {{_name, arity}, _} -> arity >= 1 end)
  end

  defp defp_clause?({:defp, _, [_head | _]}), do: true
  defp defp_clause?(_), do: false

  defp clause_name_arity({:defp, _, [head | _]}) do
    case strip_when(head) do
      {name, _, args} when is_atom(name) and is_list(args) -> {name, length(args)}
      _ -> :skip
    end
  end

  defp eligible_spec(name, arity, clauses, body_exprs) do
    # Call sites only ever appear inside the *bodies* of definitions —
    # never in a head. Restricting the scan to clause bodies keeps a
    # callee's own head (which is shaped like a call) out of the
    # uniformity check.
    bodies = definition_bodies(body_exprs)

    with :ok <- check_no_defaults(clauses),
         :ok <- check_arity_below_free(name, arity, body_exprs),
         :ok <- check_no_capture(name, arity, bodies),
         :ok <- check_no_apply(name, bodies),
         :ok <- check_no_dynamic_dispatch(body_exprs),
         {:ok, call_args} <- uniform_call_args(name, arity, bodies),
         {:ok, pos, expr} <- pick_pushable_position(arity, call_args),
         :ok <- check_param_plain_and_unguarded(clauses, pos) do
      {:ok, %{arity: arity, expr: expr, name: name, pos: pos}}
    else
      _ -> :skip
    end
  end

  # Dropping a param turns `name/arity` into `name/(arity-1)`. If a
  # definition of that lower arity already exists, the rewrite would
  # collide two functions into the same name/arity — refuse.
  defp check_arity_below_free(name, arity, body_exprs) do
    taken? =
      body_exprs
      |> Enum.any?(fn
        {kind, _, [head | _]} when kind in [:def, :defp] ->
          clause_name_arity_any(head) == {name, arity - 1}

        _ ->
          false
      end)

    if taken?, do: :skip, else: :ok
  end

  defp clause_name_arity_any(head) do
    case strip_when(head) do
      {name, _, args} when is_atom(name) and is_list(args) -> {name, length(args)}
      {name, _, nil} when is_atom(name) -> {name, 0}
      _ -> :skip
    end
  end

  # The body AST of every `def`/`defp` clause (each `:do`/`:else`/...
  # value), flattened. Heads are excluded.
  defp definition_bodies(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {kind, _, [_head, body_kw]} when kind in [:def, :defp] and is_list(body_kw) ->
        Keyword.values(body_kw)

      _ ->
        []
    end)
  end

  defp check_no_defaults(clauses) do
    has_default? =
      clauses
      |> Enum.any?(fn {:defp, _, [head | _]} ->
        head |> strip_when() |> head_args() |> Enum.any?(&match?({:\\, _, _}, &1))
      end)

    if has_default?, do: :skip, else: :ok
  end

  # Any capture referencing the callee pins its arity: the `&fun/arity`
  # slash form *and* the partial-application form `&fun(&1, ...)`. Both
  # disqualify the candidate.
  defp check_no_capture(name, _arity, bodies) do
    captured? =
      bodies
      |> Enum.any?(fn expr ->
        expr
        |> Macro.prewalker()
        |> Enum.any?(&capture_refs?(&1, name))
      end)

    if captured?, do: :skip, else: :ok
  end

  defp capture_refs?({:&, _, [inner]}, name), do: references_name?(inner, name)
  defp capture_refs?(_, _), do: false

  defp references_name?(ast, name) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(&match?({^name, _, _}, &1))
  end

  # `apply(_, :name, _)` / `Kernel.apply(...)` could reach the callee at
  # its old arity through a literal name. Refuse if any apply targets the
  # callee name.
  defp check_no_apply(name, bodies) do
    applies? =
      bodies
      |> Enum.any?(fn expr ->
        expr
        |> Macro.prewalker()
        |> Enum.any?(&apply_to_name?(&1, name))
      end)

    if applies?, do: :skip, else: :ok
  end

  defp apply_to_name?({:apply, _, [_mod, fn_name, _args]}, name),
    do: literal_name(fn_name) == name

  defp apply_to_name?(
         {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [_m, fn_name, _a]},
         name
       ),
       do: literal_name(fn_name) == name

  defp apply_to_name?(_, _), do: false

  defp literal_name({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp literal_name(atom) when is_atom(atom), do: atom
  defp literal_name(_), do: nil

  # Any dynamic `apply/3` in the module is treated as possibly reaching
  # the callee at its old arity. Conservative: refuse the whole module's
  # candidate if a dynamic-dispatch sentinel is present anywhere.
  defp check_no_dynamic_dispatch(body_exprs) do
    dynamic? =
      body_exprs
      |> Enum.flat_map(&collect_calls/1)
      |> dynamic_dispatch?()

    if dynamic?, do: :skip, else: :ok
  end

  # Collect the argument lists of every call to `name/arity`, and bail
  # out if any call site is a pipe into the callee (position math
  # hazard). Returns `{:ok, [args_list]}` with at least one entry, or
  # `:skip`.
  defp uniform_call_args(name, arity, body_exprs) do
    {arg_lists, piped?} =
      body_exprs
      |> Enum.reduce({[], false}, fn expr, acc ->
        expr
        |> Macro.prewalker()
        |> Enum.reduce(acc, &accumulate_call(&1, &2, name, arity))
      end)

    cond do
      piped? -> :skip
      arg_lists == [] -> :skip
      true -> {:ok, arg_lists}
    end
  end

  defp accumulate_call({:|>, _, [_lhs, {n, _, args}]}, {lists, _piped}, name, arity)
       when n == name and is_list(args) and length(args) == arity - 1,
       do: {lists, true}

  defp accumulate_call({n, _, args}, {lists, piped}, name, arity)
       when n == name and is_list(args) and length(args) == arity,
       do: {[args | lists], piped}

  defp accumulate_call(_, acc, _name, _arity), do: acc

  # Find the first position whose argument is identical across all call
  # sites and eligible to push. One per pass keeps arity bookkeeping
  # simple; the engine's fixpoint catches additional positions.
  defp pick_pushable_position(arity, [first_args | _] = arg_lists) do
    0..(arity - 1)//1
    |> Enum.find_value(:skip, fn pos ->
      candidate = Enum.at(first_args, pos)

      with true <- uniform_at?(arg_lists, pos, candidate),
           true <- pushable_expr?(candidate) do
        {:ok, pos, candidate}
      else
        _ -> false
      end
    end)
  end

  defp uniform_at?(arg_lists, pos, candidate) do
    stripped = strip_meta(candidate)
    arg_lists |> Enum.all?(&(Enum.at(&1, pos) |> strip_meta() == stripped))
  end

  # Pure, total, and context-free: no bare vars, no @attr, no __MODULE__.
  # `pure?/1` already rejects opaque locals/remotes but *accepts* bare
  # vars and __MODULE__, so we screen those out explicitly.
  defp pushable_expr?(ast), do: pure?(ast) and context_free?(ast)

  defp context_free?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.all?(fn
      {:__MODULE__, _, ctx} when is_atom(ctx) -> false
      {:@, _, [{attr, _, attr_ctx}]} when is_atom(attr) and is_atom(attr_ctx) -> false
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> bare_var_ok?(name)
      _ -> true
    end)
  end

  # A `{name, _, ctx}` with atom ctx is a bare variable reference. The
  # only such nodes that are not call-site-local vars are the literal
  # atoms wrapped by Sourceror (handled elsewhere) — every genuine
  # variable disqualifies the expression.
  defp bare_var_ok?(_name), do: false

  defp check_param_plain_and_unguarded(clauses, pos) do
    ok? =
      clauses
      |> Enum.all?(fn {:defp, _, [head | _]} ->
        param_plain?(head, pos) and not param_in_guard?(head, pos)
      end)

    if ok?, do: :ok, else: :skip
  end

  defp param_plain?(head, pos) do
    case head |> strip_when() |> head_args() |> Enum.at(pos) do
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> not underscore?(name)
      _ -> false
    end
  end

  defp param_in_guard?({:when, _, [head, guard]}, pos) do
    case head |> head_args() |> Enum.at(pos) do
      {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
        guard
        |> Macro.prewalker()
        |> Enum.any?(&match?({^name, _, g_ctx} when is_atom(g_ctx), &1))

      _ ->
        false
    end
  end

  defp param_in_guard?(_head, _pos), do: false

  defp head_args({_name, _, args}) when is_list(args), do: args
  defp head_args({_name, _, nil}), do: []

  # ── Rewrite (per source/module) ───────────────────────────────────

  defp rewrite_with_plan_or_passthrough(nil, source), do: source
  defp rewrite_with_plan_or_passthrough(plan, source) when map_size(plan) == 0, do: source
  defp rewrite_with_plan_or_passthrough(plan, source), do: rewrite(plan, source)

  defp rewrite(plan, source),
    do: Sourceror.parse_string(source) |> apply_plan_to_parse_result(plan, source)

  defp apply_plan_to_parse_result({:ok, ast}, plan, source) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        patches_for_defmodule(name_ast, body, plan)

      _ ->
        []
    end)
    |> patch_or_passthrough(source)
  end

  defp apply_plan_to_parse_result({:error, _}, _plan, source), do: source

  defp patches_for_defmodule(name_ast, body, plan) do
    with {:ok, module} <- alias_to_module(name_ast),
         specs when is_list(specs) <- Map.get(plan, module) do
      patches_for_module(body_to_exprs(body), specs)
    else
      _ -> []
    end
  end

  defp patches_for_module(body_exprs, specs) do
    specs |> Enum.flat_map(&patches_for_spec(body_exprs, &1))
  end

  defp patches_for_spec(body_exprs, spec) do
    callee_patches(body_exprs, spec) ++ call_site_patches(body_exprs, spec)
  end

  # Rewrite each callee clause: drop the param, substitute the expr for
  # every reference to the dropped variable in head/guard/body.
  defp callee_patches(body_exprs, %{arity: arity, name: name} = spec) do
    body_exprs
    |> Enum.filter(&callee_clause?(&1, name, arity))
    |> Enum.flat_map(&rewrite_callee_clause(&1, spec))
  end

  defp callee_clause?({:defp, _, [head | _]}, name, arity) do
    case strip_when(head) do
      {^name, _, args} when is_list(args) and length(args) == arity -> true
      _ -> false
    end
  end

  defp callee_clause?(_, _, _), do: false

  defp rewrite_callee_clause({:defp, meta, [head, body_kw]}, %{expr: expr, pos: pos}) do
    var_name = param_var_name(head, pos)
    new_head = head |> drop_param(pos) |> substitute_var(var_name, expr)
    new_body = body_kw |> substitute_var(var_name, expr)
    replacement = {:defp, meta, [new_head, new_body]}
    [Patch.replace({:defp, meta, [head, body_kw]}, render(replacement))]
  end

  defp param_var_name(head, pos) do
    {name, _, _} = head |> strip_when() |> head_args() |> Enum.at(pos)
    name
  end

  defp drop_param({:when, meta, [head, guard]}, pos),
    do: {:when, meta, [drop_param(head, pos), guard]}

  defp drop_param({name, meta, args}, pos) when is_list(args),
    do: {name, meta, List.delete_at(args, pos)}

  defp substitute_var(ast, var_name, expr) do
    Macro.prewalk(ast, fn
      {^var_name, _, ctx} when is_atom(ctx) -> expr
      other -> other
    end)
  end

  # Drop the argument at `pos` from every call site of `name/arity`.
  # Scanned over clause bodies only, so the callee's own head — shaped
  # like a call — is left to `callee_patches/2`.
  defp call_site_patches(body_exprs, %{arity: arity, name: name, pos: pos}) do
    body_exprs
    |> definition_bodies()
    |> Enum.flat_map(fn expr ->
      expr
      |> Macro.prewalker()
      |> Enum.flat_map(&call_site_patch(&1, name, arity, pos))
    end)
  end

  defp call_site_patch({n, meta, args} = node, name, arity, pos)
       when n == name and is_list(args) and length(args) == arity do
    replacement = {n, meta, List.delete_at(args, pos)}
    [Patch.replace(node, render(replacement))]
  end

  defp call_site_patch(_, _, _, _), do: []

  defp render(ast), do: Sourceror.to_string(ast)

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end
end
