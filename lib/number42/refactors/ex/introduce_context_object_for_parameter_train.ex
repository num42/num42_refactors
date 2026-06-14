defmodule Number42.Refactors.Ex.IntroduceContextObjectForParameterTrain do
  @moduledoc """
  Detects a **parameter train** — the same group of `>= K` parameters
  threaded together, unchanged and in the same order, through a chain of
  local function calls — and bundles them into a generated **context
  struct** carried as one value.

      # before
      defmodule Pricing do
        def total(items, region, currency, rate) do
          subtotal(items, region, currency, rate) + tax(items, region, currency, rate)
        end

        defp subtotal(items, region, currency, rate), do: …
        defp tax(items, region, currency, rate), do: …
      end

      # after
      defmodule Pricing do
        defmodule Ctx do
          defstruct [:items, :region, :currency, :rate]
        end

        def total(items, region, currency, rate) do
          ctx = %Ctx{items: items, region: region, currency: currency, rate: rate}
          subtotal(ctx) + tax(ctx)
        end

        defp subtotal(%Ctx{items: items, region: region, currency: currency, rate: rate}), do: …
        defp tax(%Ctx{items: items, region: region, currency: currency, rate: rate}), do: …
      end

  The rewrite is mechanical. The hard, dangerous part is **recognising**
  that a pile of positional arguments threaded through several helpers is
  one cohesive context — a genuine *data clump* — and proving it can be
  bundled without changing meaning or breaking a caller we can't see.

  ## The unit of detection: a train across a call chain

  A parameter train qualifies only when, for a group of `>= K`
  parameters (default `K = 3`):

    1. **A callee** (`defp`) takes exactly those parameters, each as a
       **bare variable** in its head, in some fixed order. Pattern
       matches, defaults (`\\`), and guards on a train parameter
       disqualify the callee — substituting a struct destructure for a
       pattern/guard input is not mechanical.
    2. **Every call site** of that callee passes the **same variables**,
       by name, in the **same order** — proving the arguments travel as a
       unit, not reordered, transformed, or partially omitted.
    3. **The caller** binds all those variables as its own parameters (so
       it can forward them) — i.e. the train is itself a parameter train
       in the caller, threaded one level deeper.

  Requiring the train to be a *parameter* train in the caller (not an
  arbitrary local binding) is what makes the bundle safe and recursive:
  the same group flows caller → callee, and the caller's head can be
  rewritten to destructure the same struct. A group that merely appears
  in one head but is never forwarded as a unit is *not* a train — it is
  declined.

  ## Why `defp`-only (and the public wrapper mode)

  Bundling parameters into a struct is an **arity + signature change** at
  every call site. A private callee's caller set is bounded by its module
  (the corpus contains all of them via `prepare/1`), so the rewrite is
  provably complete. A public `def` could be called from outside the
  corpus, so by default every `def` is refused.

  With `public: true` a public `def` train *is* bundled, but a
  **backward-compat wrapper** at the original arity is kept:

      def render(a, b, c), do: render(%Ctx{a: a, b: b, c: c})  # old arity forwards

  Corpus callers move to the struct arity; the wrapper keeps external
  callers compiling. The new struct-arity clause carries the real body.

  ## Threshold K and scoring

  A train qualifies only at `>= K` parameters (default `K = 3`,
  configurable via `min_train_size:`). Fewer than three positional
  arguments rarely constitutes primitive obsession worth a struct, and
  K=3 is the issue's stated floor. A train is scored higher — and
  preferred when two overlap — when it crosses **more helper
  boundaries** (more distinct callees share it) and when it **dominates**
  the callee arity (the train is the whole parameter list, not a
  fragment). The highest-scoring non-overlapping trains in a module are
  bundled.

  ## False-positive guards (hard exclusions)

  - **Reordered / transformed / partial** — a call site passing the train
    variables in a different order, wrapping any in an expression, or
    omitting any, breaks the "travels as a unit" proof. The whole train
    is declined.
  - **Public API without wrapper** — a `def` train is skipped unless
    `public: true` authorises the compatibility wrapper.
  - **Callback / externally-imposed arity** — a callee with `@impl`, or
    whose name/arity matches a `@behaviour` callback or a known
    framework callback (`handle_call/3`, `init/1`, `mount/3`, …), has its
    arity fixed by an external contract; bundling would break the
    contract. Declined.
  - **Pattern / guard / default on a train param** — see the callee rule
    above.
  - **Captures and `apply`** — a `&callee/arity` capture or an
    `apply(_, :callee, _)` can reach the old arity dynamically. Declined.
  - **Name collision** — if the chosen context-struct name already exists
    as a module, decline rather than clash.

  ## Naming policy (and its known weakness)

  There is no signal in the code for what to call the context struct.
  Policy: a dictionary derivation from the parameter-name set
  (`conn`+`params`+`session` → `Request`, …), else the generic
  `Context<N>` with an inline rename reminder. Generic names are a known
  smell; default-off + manual review is the mitigation.

  ## Default-OFF (opt-in only)

  Disabled by default — `transform/2` is a no-op unless its opts carry
  `enabled: true`. Bundling parameters into a struct is a high-impact,
  architectural change whose detection is heuristic; enable per project
  after reviewing the dry-run diff:

      configured_modules: [
        {Number42.Refactors.Ex.IntroduceContextObjectForParameterTrain, enabled: true}
      ]
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  # >= K parameters before a group is a bundle-worthy train. K=3 is the
  # issue's stated floor; below it primitive obsession is rarely worth a
  # struct.
  @default_min_train_size 3

  @excluded_path_prefixes ["test/", "dev/"]

  @rename_reminder "# " <> "TODO: rename — generic context name"

  # parameter-name set -> context struct name. Tiny and English-biased by
  # design; first match wins. Sets are compared sorted.
  @name_dictionary [
    {~w(conn params)a, "Request"},
    {~w(conn params session)a, "Request"},
    {~w(socket assigns)a, "View"},
    {~w(user account)a, "Principal"},
    {~w(items region currency)a, "Order"},
    {~w(host port scheme)a, "Endpoint"},
    {~w(repo changeset)a, "Persist"}
  ]

  # Framework/OTP callbacks whose arity is externally imposed; a callee
  # matching one of these by {name, arity} is never bundled.
  @framework_callbacks MapSet.new([
                         {:init, 1},
                         {:handle_call, 3},
                         {:handle_cast, 2},
                         {:handle_info, 2},
                         {:handle_continue, 2},
                         {:terminate, 2},
                         {:code_change, 3},
                         {:mount, 3},
                         {:handle_event, 3},
                         {:handle_params, 3},
                         {:update, 2},
                         {:render, 1},
                         {:call, 2},
                         {:init, 1}
                       ])

  @type spec :: %{
          name: atom(),
          struct_name: String.t(),
          fields: [atom()],
          callees: [{atom(), arity()}],
          callers: [{atom(), arity()}],
          public: boolean()
        }

  @impl Number42.Refactors.Refactor
  def description,
    do: "bundle a parameter train threaded through local calls into a context struct"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    The same group of parameters threaded unchanged through a chain of
    helpers is a data clump: several values that always travel together
    and conceptually form one context. Bundling them into a named struct
    shrinks every signature in the chain, names the context, and removes
    the positional fragility of long argument lists. The dangerous part
    is proving the group genuinely travels as a unit — same variables,
    same order, no transform or omission — so a train is bundled only
    when every call site forwards it verbatim; otherwise it is declined.
    """
  end

  # Synthesising a `defmodule` block, rewriting heads, and inserting
  # struct constructions needs a formatting pass to settle.
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    public? = Keyword.get(opts, :public, false)
    min = Keyword.get(opts, :min_train_size, @default_min_train_size)

    case plan_sources(opts) do
      [] -> :no_cache
      sources -> {:ok, build_plan(sources, public: public?, min_train_size: min)}
    end
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      opts |> resolve_plan(source) |> rewrite_with_plan(source)
    else
      source
    end
  end

  defp resolve_plan(opts, source) do
    case Keyword.get(opts, :prepared) do
      %{} = plan ->
        plan

      _ ->
        public? = Keyword.get(opts, :public, false)
        min = Keyword.get(opts, :min_train_size, @default_min_train_size)
        build_plan([{"lib/inline.ex", source}], public: public?, min_train_size: min)
    end
  end

  @doc """
  Build a per-module rewrite plan from `[{path, source}]` tuples.

  Returns `%{module() => [spec()]}`. Modules absent need no rewrite.
  Exposed so tests can build a plan without the engine.
  """
  @spec build_plan([{String.t(), String.t()}], keyword()) :: %{module() => [spec()]}
  def build_plan(sources, opts \\ []) do
    public? = Keyword.get(opts, :public, false)
    min = Keyword.get(opts, :min_train_size, @default_min_train_size)
    existing = module_index(sources)

    sources
    |> Enum.reject(fn {path, _src} -> excluded_path?(path) end)
    |> Enum.flat_map(&module_bodies/1)
    |> Enum.group_by(fn {module, _body} -> module end, fn {_module, body} -> body end)
    |> Enum.flat_map(fn {module, bodies} ->
      case plan_for_module(module, List.flatten(bodies), public?, min, existing) do
        nil -> []
        spec -> [{module, [spec]}]
      end
    end)
    |> Map.new()
  end

  # --- module / source parsing ---

  defp module_bodies({_path, source}),
    do: source |> Sourceror.parse_string() |> module_bodies_or_empty()

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

  # Every module name defined across the corpus — for the name-collision
  # guard when synthesising the context struct's module.
  defp module_index(sources) do
    sources
    |> Enum.flat_map(&modules_in_source/1)
    |> MapSet.new()
  end

  defp modules_in_source({_path, src}) do
    case Sourceror.parse_string(src) do
      {:ok, ast} -> ast |> Macro.prewalker() |> Enum.flat_map(&module_name/1)
      {:error, _} -> []
    end
  end

  defp module_name({:defmodule, _, [name_ast, _]}) do
    case alias_to_module(name_ast) do
      {:ok, module} -> [module]
      :error -> []
    end
  end

  defp module_name(_), do: []

  defp excluded_path?(path) do
    normalized = String.trim_leading(path, "./")
    Enum.any?(@excluded_path_prefixes, &String.starts_with?(normalized, &1))
  end

  # --- detection (per module) ---

  defp plan_for_module(module, body_exprs, public?, min, existing) do
    clauses = def_clauses(body_exprs)

    body_exprs
    |> callee_candidates(clauses, public?, min)
    |> group_by_signature()
    |> rank_trains()
    |> Enum.find_value(nil, fn train ->
      finalize_train(module, train, existing)
    end)
  end

  defp def_clauses(body_exprs) do
    Enum.filter(body_exprs, fn
      {kind, _, [_head | _]} when kind in [:def, :defp] -> true
      _ -> false
    end)
  end

  # Every callee whose parameter list is itself a forwarded train: arity
  # >= K plain vars, no callback/capture/apply hazard, and every call site
  # forwards those vars verbatim from a caller that binds them. One entry
  # per eligible callee `{name, arity}`.
  defp callee_candidates(body_exprs, clauses, public?, min) do
    callee_groups =
      clauses
      |> Enum.group_by(&clause_kind_name_arity/1)
      |> Enum.reject(fn {key, _} -> key == :skip end)

    bodies = definition_bodies(body_exprs)

    callee_groups
    |> Enum.flat_map(fn {{kind, name, arity}, group} ->
      callee_candidate(kind, name, arity, group, clauses, bodies, public?, min)
    end)
  end

  defp callee_candidate(kind, name, arity, group, clauses, bodies, public?, min) do
    with true <- arity >= min,
         :ok <- check_visibility(kind, public?),
         :ok <- check_not_callback(name, arity, group),
         {:ok, params} <- plain_param_names(group),
         :ok <- check_no_capture_or_apply(name, arity, bodies),
         {:ok, callers} <- forwarded_uniformly(name, arity, params, clauses) do
      [%{name: name, arity: arity, params: params, public: kind == :def, callers: callers}]
    else
      _ -> []
    end
  end

  # A parameter train is a *field signature* (the ordered param-name list)
  # shared by one or more callees in the module. Group eligible callees by
  # that signature so a single context struct bundles the whole clump,
  # however many helpers it threads through.
  defp group_by_signature(candidates) do
    candidates
    |> Enum.group_by(& &1.params)
    |> Enum.map(fn {params, group} ->
      %{
        params: params,
        arity: length(params),
        callees:
          group
          |> Enum.map(fn c -> %{name: c.name, arity: c.arity, public: c.public} end)
          |> Enum.uniq()
          |> Enum.sort_by(& &1.name),
        callers:
          group
          |> Enum.flat_map(& &1.callers)
          |> Enum.map(fn {key, _count} -> key end)
          |> Enum.uniq(),
        public: Enum.any?(group, & &1.public)
      }
    end)
  end

  defp check_visibility(:defp, _public?), do: :ok
  defp check_visibility(:def, true), do: :ok
  defp check_visibility(:def, false), do: :skip

  defp clause_kind_name_arity({kind, _, [head | _]}) when kind in [:def, :defp] do
    case strip_when(head) do
      {name, _, args} when is_atom(name) and is_list(args) -> {kind, name, length(args)}
      _ -> :skip
    end
  end

  defp clause_kind_name_arity(_), do: :skip

  # `@impl`-adjacent or framework-callback-shaped callees have an
  # externally imposed arity and must not be bundled. We can't read the
  # preceding `@impl` attribute from a clause in isolation cheaply, so we
  # gate on the framework-callback name/arity table — the common case.
  defp check_not_callback(name, arity, _group) do
    if MapSet.member?(@framework_callbacks, {name, arity}), do: :skip, else: :ok
  end

  # Every clause of the callee must bind the *same* plain variable names,
  # in the same order, with no pattern/guard/default. Returns the ordered
  # param-name list shared by all clauses, or `:skip`.
  defp plain_param_names(group) do
    group
    |> Enum.map(&clause_param_names/1)
    |> Enum.reduce(:start, fn
      :skip, _ -> :skip
      _names, :skip -> :skip
      names, :start -> names
      names, acc when names == acc -> acc
      _names, _acc -> :skip
    end)
    |> case do
      :skip -> :skip
      :start -> :skip
      names -> {:ok, names}
    end
  end

  defp clause_param_names({kind, _, [head | rest]}) when kind in [:def, :defp] do
    if guarded?(head) do
      :skip
    else
      head |> strip_when() |> head_args() |> all_plain_vars(rest)
    end
  end

  defp guarded?({:when, _, [head, guard]}) do
    vars = head |> head_args() |> Enum.flat_map(&plain_var_name/1)

    guard
    |> Macro.prewalker()
    |> Enum.any?(fn
      {n, _, ctx} when is_atom(n) and is_atom(ctx) -> n in vars
      _ -> false
    end)
  end

  defp guarded?(_), do: false

  defp all_plain_vars(args, _rest) do
    names = Enum.map(args, &plain_var_name/1)

    if Enum.any?(names, &(&1 == [])) do
      :skip
    else
      flat = List.flatten(names)
      if length(Enum.uniq(flat)) == length(flat), do: flat, else: :skip
    end
  end

  defp plain_var_name({:\\, _, _}), do: []

  defp plain_var_name({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    if underscore?(name), do: [], else: [name]
  end

  defp plain_var_name(_), do: []

  # A `&callee/arity` (or `&callee(&1, …)`) capture or an
  # `apply(_, :callee, _)` can reach the callee at its old arity — both
  # pin the signature. Any such reference declines the train.
  defp check_no_capture_or_apply(name, _arity, bodies) do
    refs? =
      Enum.any?(bodies, fn expr ->
        expr
        |> Macro.prewalker()
        |> Enum.any?(&(capture_of?(&1, name) or apply_to?(&1, name)))
      end)

    if refs?, do: :skip, else: :ok
  end

  defp capture_of?({:&, _, [inner]}, name) do
    inner
    |> Macro.prewalker()
    |> Enum.any?(&match?({^name, _, _}, &1))
  end

  defp capture_of?(_, _), do: false

  defp apply_to?({:apply, _, [_mod, fun, _args]}, name), do: literal_atom(fun) == name
  defp apply_to?(_, _), do: false

  defp literal_atom({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp literal_atom(atom) when is_atom(atom), do: atom
  defp literal_atom(_), do: nil

  # Across the whole module, every call to `name/arity` must pass exactly
  # the `params` variables in order, and must sit inside a caller that
  # binds all those params in its own head. Returns `{:ok, callers}` where
  # `callers` are the `{name, arity}` of the enclosing definitions, or
  # `:skip` if any call site diverges or there is no call site at all.
  defp forwarded_uniformly(name, arity, params, clauses) do
    {ok?, callers} =
      Enum.reduce_while(clauses, {false, []}, fn clause, {seen?, callers} ->
        caller_key = clause_caller_key(clause)
        caller_params = caller_param_set(clause)

        case scan_call_sites(clause, name, arity, params, caller_params) do
          :diverge ->
            {:halt, :diverge}

          {:found, count} when count > 0 ->
            {:cont, {true, [{caller_key, count} | callers]}}

          {:found, 0} ->
            {:cont, {seen?, callers}}
        end
      end)
      |> normalise_forward()

    if ok?, do: {:ok, callers}, else: :skip
  end

  defp normalise_forward(:diverge), do: {false, []}
  defp normalise_forward({seen?, callers}), do: {seen?, callers}

  defp clause_caller_key({kind, _, [head | _]}) when kind in [:def, :defp] do
    case strip_when(head) do
      {n, _, args} when is_atom(n) and is_list(args) -> {n, length(args)}
      _ -> :skip
    end
  end

  defp caller_param_set({kind, _, [head | _]}) when kind in [:def, :defp] do
    head
    |> strip_when()
    |> head_args()
    |> Enum.flat_map(&plain_var_name/1)
    |> MapSet.new()
  end

  # Walk a clause body for calls to `name/arity`. A matching call must
  # forward exactly `params` (bare vars, in order) AND the enclosing
  # caller must bind every one of those params — else the train doesn't
  # travel as a unit here. Returns `:diverge` on any partial/reordered
  # match, or `{:found, count}` of verbatim forwards.
  defp scan_call_sites({_kind, _, [_head, body_kw]} = _clause, name, arity, params, caller_params)
       when is_list(body_kw) do
    body_kw
    |> Keyword.values()
    |> Enum.reduce_while({:found, 0}, fn expr, {:found, count} ->
      classify_calls(expr, name, arity, params, caller_params, count)
    end)
  end

  defp scan_call_sites(_clause, _name, _arity, _params, _caller_params), do: {:found, 0}

  defp classify_calls(expr, name, arity, params, caller_params, count) do
    expr
    |> Macro.prewalker()
    |> Enum.reduce_while({:found, count}, fn node, {:found, c} ->
      case call_match(node, name, arity, params, caller_params) do
        :verbatim -> {:cont, {:found, c + 1}}
        :diverge -> {:halt, :diverge}
        :other -> {:cont, {:found, c}}
      end
    end)
    |> case do
      :diverge -> {:halt, :diverge}
      acc -> {:cont, acc}
    end
  end

  # A call `name(a1, …, an)` to the target. `:verbatim` if the args are
  # exactly the train vars in order and the caller binds them all;
  # `:diverge` if it targets the callee but passes anything else (reorder,
  # transform, omission, or a pipe shifting positions).
  defp call_match({:|>, _, [_lhs, {n, _, args}]}, name, arity, _params, _caller)
       when n == name and is_list(args) and length(args) == arity - 1,
       do: :diverge

  defp call_match({n, _, args}, name, arity, params, caller_params)
       when n == name and is_list(args) and length(args) == arity do
    arg_names = Enum.map(args, &as_bare_var/1)

    cond do
      Enum.any?(arg_names, &is_nil/1) -> :diverge
      arg_names != params -> :diverge
      not Enum.all?(params, &MapSet.member?(caller_params, &1)) -> :diverge
      true -> :verbatim
    end
  end

  defp call_match({n, _, args}, name, _arity, _params, _caller)
       when n == name and is_list(args),
       do: :diverge

  defp call_match(_, _, _, _, _), do: :other

  defp as_bare_var({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: name
  defp as_bare_var(_), do: nil

  # The body AST of every def/defp clause, flattened. Heads excluded.
  defp definition_bodies(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {kind, _, [_head, body_kw]} when kind in [:def, :defp] and is_list(body_kw) ->
        Keyword.values(body_kw)

      _ ->
        []
    end)
  end

  # --- ranking ---

  # Higher score = crosses more helper boundaries (more distinct callees
  # share the train) and dominates a larger arity. Deterministic
  # tie-break by sorted field list keeps output stable.
  defp rank_trains(trains) do
    trains
    |> Enum.map(&score_train/1)
    |> Enum.sort_by(fn {score, train} -> {-score, Enum.sort(train.params)} end)
    |> Enum.map(fn {_score, train} -> train end)
  end

  defp score_train(train) do
    boundaries = length(train.callees)
    {boundaries * 10 + train.arity, train}
  end

  # --- finalisation ---

  defp finalize_train(module, train, existing) do
    case struct_name(train.params, module, existing) do
      nil ->
        nil

      name ->
        %{
          struct_name: name,
          fields: train.params,
          arity: train.arity,
          callees: train.callees,
          callers: train.callers,
          public: train.public
        }
    end
  end

  defp struct_name(params, module, existing) do
    sorted = Enum.sort(params)
    base = dict_name(sorted) || fallback_name(module, existing)
    full = Module.concat(module, base)
    if MapSet.member?(existing, full), do: distinct_name(module, existing), else: base
  end

  defp dict_name(sorted_params) do
    Enum.find_value(@name_dictionary, fn {keys, name} ->
      if Enum.sort(keys) == sorted_params, do: name
    end)
  end

  defp fallback_name(module, existing) do
    1
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(&"Context#{&1}")
    |> Enum.find(&(not MapSet.member?(existing, Module.concat(module, &1))))
  end

  defp distinct_name(module, existing), do: fallback_name(module, existing)

  # --- rewrite ---

  defp rewrite_with_plan(plan, source) when map_size(plan) == 0, do: source

  defp rewrite_with_plan(plan, source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> do_rewrite(ast, plan, source)
      {:error, _} -> source
    end
  end

  defp do_rewrite(ast, plan, source) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} = node ->
        patches_for_module(node, name_ast, body, plan)

      _ ->
        []
    end)
    |> patch_or_passthrough(source)
  end

  defp patches_for_module(module_node, name_ast, body, plan) do
    with {:ok, module} <- alias_to_module(name_ast),
         [spec | _] <- Map.get(plan, module, []) do
      module_patches(module_node, body, spec)
    else
      _ -> []
    end
  end

  defp module_patches(module_node, body, spec) do
    body_exprs = body_to_exprs(body)

    head_patches = body_exprs |> Enum.flat_map(&callee_head_patch(&1, spec))
    call_patches = body_exprs |> Enum.flat_map(&caller_body_patches(&1, spec))

    case head_patches ++ call_patches do
      [] -> []
      patches -> [defstruct_patch(module_node, spec) | patches]
    end
  end

  # Rewrite a callee head if it belongs to the train: replace its flat
  # param list with a single struct destructure. For a public `def`,
  # append a backward-compat wrapper at the original arity.
  defp callee_head_patch({kind, meta, [head, body_kw]} = node, spec)
       when kind in [:def, :defp] do
    case strip_when(head) do
      {n, _, args} when is_list(args) ->
        callee = callee_for(spec, n, length(args))

        if callee && param_list_matches?(args, spec.fields) do
          [build_callee_patch(kind, meta, head, body_kw, node, spec, callee)]
        else
          []
        end

      _ ->
        []
    end
  end

  defp callee_head_patch(_node, _spec), do: []

  defp callee_for(spec, name, arity) do
    Enum.find(spec.callees, fn c -> c.name == name and c.arity == arity end)
  end

  defp param_list_matches?(args, fields) do
    Enum.map(args, &as_bare_var/1) == fields
  end

  # Rebuild the clause AST with the struct-destructure head, render via
  # Sourceror (so the body keyword shape — `do:` vs `do/end` — is handled
  # correctly), then append the wrapper for a public `def`.
  defp build_callee_patch(kind, meta, head, body_kw, node, spec, callee) do
    new_head = struct_head(head, spec)
    rewritten = Sourceror.to_string({kind, meta, [new_head, body_kw]})
    wrapper = if callee.public, do: "\n\n" <> wrapper_source(spec, callee), else: ""
    Patch.replace(node, rewritten <> wrapper)
  end

  # `name(%Struct{f1: f1, …})` as AST, preserving a `when` guard if one
  # somehow survives (guards on train params are excluded upstream).
  defp struct_head({:when, meta, [inner, guard]}, spec),
    do: {:when, meta, [struct_head(inner, spec), guard]}

  defp struct_head({name, meta, _args}, spec), do: {name, meta, [struct_pattern_ast(spec)]}

  defp struct_pattern_ast(spec), do: Sourceror.parse_string!(struct_pattern(spec))

  defp struct_pattern(spec) do
    inner = Enum.map_join(spec.fields, ", ", fn f -> "#{f}: #{f}" end)
    "%#{spec.struct_name}{#{inner}}"
  end

  # Backward-compat wrapper at the original arity for a public `def`
  # callee: fresh positional params constructing the struct and forwarding
  # to the struct-arity clause.
  defp wrapper_source(spec, callee) do
    args = Enum.map_join(spec.fields, ", ", &Atom.to_string/1)
    "def #{callee.name}(#{args}), do: #{callee.name}(#{struct_ctor(spec)})"
  end

  defp struct_ctor(spec) do
    inner = Enum.map_join(spec.fields, ", ", fn f -> "#{f}: #{f}" end)
    "%#{spec.struct_name}{#{inner}}"
  end

  # Replace every verbatim call-site argument list (the train vars) with a
  # single inline struct construction. v1 builds the struct inline at each
  # call site (a small duplication) rather than hoisting a shared binding —
  # the latter is a follow-up slice. The wrapper's own forwarding call
  # passes a struct, not the train vars, so it never matches here.
  defp caller_body_patches({kind, _, [_head, body_kw]}, spec)
       when kind in [:def, :defp] and is_list(body_kw) do
    body_kw
    |> Keyword.values()
    |> Enum.flat_map(&call_site_patches(&1, spec))
  end

  defp caller_body_patches(_node, _spec), do: []

  defp call_site_patches(expr, spec) do
    expr
    |> Macro.prewalker()
    |> Enum.flat_map(&call_site_patch(&1, spec))
  end

  defp call_site_patch({n, _, args} = node, spec) when is_list(args) do
    if callee_for(spec, n, length(args)) && param_list_matches?(args, spec.fields) do
      [Patch.replace(node, "#{n}(#{struct_ctor(spec)})")]
    else
      []
    end
  end

  defp call_site_patch(_node, _spec), do: []

  # One `defmodule Name do defstruct […] end` prepended inside the module
  # body, above the first definition.
  defp defstruct_patch({:defmodule, _, [_name, [{_do, body}]]}, spec) do
    line = first_def_line(body)
    fields = Enum.map_join(spec.fields, ", ", &":#{&1}")
    reminder = if fallback?(spec.struct_name), do: "  #{@rename_reminder}\n", else: ""

    text =
      "defmodule #{spec.struct_name} do\n#{reminder}  defstruct [#{fields}]\nend\n\n"

    range = %{start: [line: line, column: 3], end: [line: line, column: 3]}
    Patch.new(range, text, false)
  end

  defp fallback?(name), do: String.starts_with?(name, "Context")

  defp first_def_line(body) do
    body
    |> body_to_exprs()
    |> Enum.find_value(1, fn
      {kind, meta, _} when kind in [:def, :defp] -> Keyword.get(meta, :line, 1)
      _ -> nil
    end)
  end

  # --- shared helpers ---

  defp head_args({_name, _, args}) when is_list(args), do: args
  defp head_args({_name, _, nil}), do: []
  defp head_args(_), do: []

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp plan_sources(opts) do
    opts
    |> Keyword.get(:paths, Keyword.get(opts, :source_files, []))
    |> List.wrap()
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, source} -> [{path, source}]
        {:error, _} -> []
      end
    end)
  end
end
