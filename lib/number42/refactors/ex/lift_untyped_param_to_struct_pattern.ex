defmodule Number42.Refactors.Ex.LiftUntypedParamToStructPattern do
  @moduledoc """
  Lifts a bare, untyped function parameter to a struct-pattern match
  when the body **proves** the value is that struct.

      # before
      def position_to_result(r), do: %Result{id: r.id, title: r.name}

      # after
      def position_to_result(%Position{} = r), do: %Result{id: r.id, title: r.name}

  Making the implicit contract explicit at the head gives the compiler a
  struct to check field access against and lets Dialyzer narrow the type.

  ## The hard part: field access gives the field *set*, not the *identity*

  `r.id` / `r.name` match a dozen structs. The refactor must not guess —
  it infers an identity only when it is **provable**, and **declines**
  (leaves the head untouched) otherwise. A wrong lift would insert a
  pattern that fails at runtime for the real value.

  Inference, strongest signal first:

  1. **An existing `@spec`** over the clause names the argument type
     outright (`@spec f(Position.t()) :: …`). Zero ambiguity — lift to it.
  2. **A unique `defstruct` superset.** Collect the `var.field` accesses;
     if exactly one in-project struct's field set is a superset of them
     *and no other struct's is*, that is the type. Two or more fit →
     ambiguous → decline. None fit → decline (the value is a map, not a
     struct — e.g. a `select`-projection with join/compute fields no
     struct carries).

  The decline-on-ambiguity guard is the core of the design, not an
  afterthought.

  ## What is lifted, what is left alone

  - **In:** a single bare parameter (`{var, _, ctx}` with `ctx` an atom)
    read in the body via at least `:min_fields` (default 2) distinct
    `var.field` accesses that resolve to one struct.
  - **Out (declined):**
    - parameters already typed (`%Struct{}`, `%{...}`, literals, tuples,
      lists) — nothing to lift,
    - **too few fields:** fewer than `:min_fields` distinct accesses — one
      generic field (`slug`, `source`, `id`) is a member of many structs,
      so a unique fit on it is usually a coincidence,
    - a `var` passed **whole** into another call (`helper(var)`): the
      helper may read fields we can't see, so the field set is incomplete
      and inference is unsafe,
    - a **builder**: `X_to_Y(arg)` constructing `%Y{field: arg.field, …}`.
      `arg` is the source projection feeding the build, not `%Y{}` — its
      fields coincide with some struct's only because the query selected
      exactly what the build needs. (An explicit `@spec` overrides this —
      a named type is binding.)
    - clauses whose inferred type would **diverge** across a multi-clause
      function (each clause is judged, but a function lifts only when its
      lift is internally consistent),
    - any `{name, arity}` where no unique struct fits.

  These guards distinguish a value that *is* a struct from a same-shaped
  projection. Distinguishing-power has limits: a body reading only the
  most generic field names (`type`, `name`) can still coincide with a
  domain struct. Hence default off + manual review.

  The field-access count (`var.field`) excludes zero-arg **calls**
  (`var.fun()`): a field access carries `no_parens: true` in its AST
  meta, a call carries `closing:` — counting `module.values()` as a field
  would pin a struct on a value that is actually a module.

  ## Project-wide struct index

  Inference needs every `defstruct` in the project, so this is a
  cross-file refactor: `prepare/1` scans all non-test sources for
  `defstruct` declarations into `%{module => MapSet(fields)}`, threaded
  to `transform/2` via the prepared plan. Reads source AST only — no
  compilation required.

  ## Default on

  Shipped **on** by default. The inference is heuristic, but the layered
  decline guards make a wrong lift unlikely: a value is typed only when
  at least `:min_fields` (default 2) **distinctive** (non-generic) fields
  read off it match exactly one project struct, the param isn't passed
  whole into a call, and the body isn't a struct builder — or an explicit
  `@spec` names the type. Calibrated against a real Phoenix app (375
  files): every surviving lift was correct, and the library's own source
  yields zero lifts. A miss still inserts a pattern that only fails at
  runtime, so review the diff (`mix refactor --only
  LiftUntypedParamToStructPattern --dry-run`) before applying to an
  unfamiliar codebase, or add it to `skipped_modules` to opt out.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  # A single accessed field is far too thin a proof: one generic field
  # (`slug`, `source`, `id`) is a member of many structs, so a unique fit
  # on one field is usually a coincidence (`form.source` happens to match
  # a struct with a `:source` field). Require at least this many *distinctive*
  # fields read off the var before the field-superset inference fires.
  # The `@spec` path is exempt — a named type is proof on its own.
  @default_min_fields 2

  # Fields so common across structs that they carry almost no
  # identifying signal — half the schemas in a project have an `id` and a
  # `name`. They still count toward the struct-superset match (the value
  # really does have them), but they do NOT count toward the `min_fields`
  # threshold: a clause reading only `var.type` and `var.name` has shown
  # nothing distinctive, so it is not enough to pin a type (the real
  # `format_column(column)` miss read exactly `column.type`/`column.name`
  # and coincided with an unrelated domain struct).
  @generic_fields ~w(id name type key value label slug status kind
                     inserted_at updated_at)a

  @excluded_path_prefixes ["test/", "dev/"]

  @impl Number42.Refactors.Refactor
  def description, do: "lift def f(r) to def f(%Struct{} = r) when the body proves the type"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A bare parameter whose body only ever reads `var.field` has an
    implicit struct contract. Naming the struct at the head makes the
    compiler check field access, lets Dialyzer narrow the type, and
    documents the contract where callers see it. The struct is inferred
    only when provable (a unique `defstruct` fits the field set, or an
    existing `@spec` names it); on any ambiguity the head is left alone.
    """
  end

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    {:ok, build_plan(plan_sources(opts), opts)}
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    case Keyword.get(opts, :prepared) do
      %{structs: structs} = plan ->
        rewrite(source, structs, Map.get(plan, :min_fields, @default_min_fields))

      _ ->
        source
    end
  end

  @doc """
  Build the cross-file plan: the project-wide struct field index plus,
  for reporting, every lift the refactor would perform.

  Plan shape:

      %{
        structs: %{module => MapSet(field_atoms)},
        min_fields: pos_integer,
        lifts: [%{module:, name:, arity:, param:, struct:, via:, path:}],
        declined: [%{module:, name:, arity:, param:, reason:}]
      }

  `via` is `:spec` or `:fields` — which signal resolved the type.
  `:min_fields` (default #{@default_min_fields}) is the field-count floor
  for the field-superset inference (the `@spec` path ignores it).
  """
  @spec build_plan([{String.t(), String.t()}], keyword()) :: map()
  def build_plan(sources, opts \\ []) do
    min_fields = Keyword.get(opts, :min_fields, @default_min_fields)

    visible =
      sources
      |> Enum.reject(fn {path, _src} -> excluded_path?(path) end)

    structs = struct_index(visible)

    {lifts, declined} =
      visible |> Enum.flat_map(&clauses_in_source/1) |> resolve_lifts(structs, min_fields)

    %{structs: structs, min_fields: min_fields, lifts: lifts, declined: declined}
  end

  @doc """
  Human-readable report of a plan for `--log`/dry-run review.
  """
  @spec report(map()) :: String.t()
  def report(%{lifts: []}), do: "no untyped params to lift"

  def report(%{lifts: lifts}) do
    "liftable params:\n" <>
      Enum.map_join(lifts, "\n", fn l ->
        "  #{inspect(l.module)}.#{l.name}/#{l.arity} (#{l.param}) -> %#{module_suffix(l.struct)}{} (via #{l.via})"
      end)
  end

  defp module_suffix(mod), do: mod |> Module.split() |> Enum.join(".")

  # --- project-wide struct index ---

  # `%{module => MapSet(field_atoms)}` for every `defstruct` in the
  # project. Handles `defstruct [:a, :b]` and `defstruct a: 1, b: 2`.
  defp struct_index(sources) do
    sources
    |> Enum.flat_map(&structs_in_source/1)
    |> Map.new()
  end

  defp structs_in_source({_path, src}) do
    case Sourceror.parse_string(src) do
      {:ok, ast} -> ast |> Macro.prewalker() |> Enum.flat_map(&module_struct/1)
      {:error, _} -> []
    end
  end

  defp module_struct({:defmodule, _, [name_ast, [{_do, body}]]}) do
    with {:ok, module} <- alias_to_module(name_ast),
         {:ok, fields} <- struct_fields(body) do
      [{module, fields}]
    else
      _ -> []
    end
  end

  defp module_struct(_node), do: []

  defp struct_fields(body) do
    body
    |> body_to_exprs()
    |> Enum.find_value(:error, fn
      {:defstruct, _, [fields]} -> {:ok, field_names(unwrap_block(fields))}
      _ -> nil
    end)
  end

  defp field_names(fields) when is_list(fields) do
    fields
    |> Enum.map(fn
      {:__block__, _, [atom]} when is_atom(atom) -> atom
      atom when is_atom(atom) -> atom
      {key, _value} -> field_key(key)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp field_names(_), do: MapSet.new()

  defp field_key({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp field_key(atom) when is_atom(atom), do: atom
  defp field_key(_), do: nil

  # --- clause collection ---

  # Each clause as `%{module:, name:, arity:, path:, params:, body:,
  # spec:}`; `params` is the head arg list, `spec` the arg-type list from
  # a matching `@spec` (or nil).
  defp clauses_in_source({path, src}) do
    case Sourceror.parse_string(src) do
      {:ok, ast} -> ast |> Macro.prewalker() |> Enum.flat_map(&module_clauses(&1, path))
      {:error, _} -> []
    end
  end

  defp module_clauses({:defmodule, _, [name_ast, [{_do, body}]]}, path) do
    case alias_to_module(name_ast) do
      {:ok, module} ->
        exprs = body_to_exprs(body)
        specs = spec_table(exprs)

        Enum.flat_map(exprs, &clause_record(&1, module, path, specs))

      :error ->
        []
    end
  end

  defp module_clauses(_node, _path), do: []

  defp clause_record({kind, _, [head | rest]}, module, path, specs) when kind in [:def, :defp] do
    case name_and_args(strip_when(head)) do
      {:ok, name, args} ->
        [
          %{
            module: module,
            name: name,
            arity: length(args),
            path: path,
            params: args,
            body: clause_body(rest),
            spec: Map.get(specs, {name, length(args)})
          }
        ]

      :error ->
        []
    end
  end

  defp clause_record(_node, _module, _path, _specs), do: []

  defp clause_body([[{_do, body} | _]]), do: body
  defp clause_body(_), do: nil

  # `%{ {name, arity} => [arg_type_ast] }` from `@spec name(t1, t2) :: r`.
  defp spec_table(exprs) do
    exprs
    |> Enum.flat_map(&spec_entry/1)
    |> Map.new()
  end

  defp spec_entry({:@, _, [{:spec, _, [{:"::", _, [head, _return]}]}]}) do
    case name_and_args(head) do
      {:ok, name, arg_types} -> [{{name, length(arg_types)}, arg_types}]
      :error -> []
    end
  end

  defp spec_entry(_), do: []

  # --- inference + resolution ---

  # Each clause yields a lift or a decline. A function lifts a given
  # parameter position only when every clause of that `{name, arity}`
  # agrees on the same struct for it — divergent clauses decline.
  defp resolve_lifts(clauses, structs, min_fields) do
    clauses
    |> Enum.group_by(fn c -> {c.module, c.name, c.arity} end)
    |> Enum.flat_map(fn {_key, group} -> resolve_group(group, structs, min_fields) end)
    |> Enum.split_with(&match?(%{struct: _}, &1))
  end

  # Judge each parameter position across all clauses of the function. A
  # position is lifted only if every clause infers the SAME struct for it
  # (a divergent or any-declining clause kills the position).
  defp resolve_group([first | _] = group, structs, min_fields) do
    0..(first.arity - 1)//1
    |> Enum.flat_map(fn pos -> resolve_position(group, pos, structs, min_fields) end)
  end

  defp resolve_position(group, pos, structs, min_fields) do
    inferences = Enum.map(group, fn clause -> infer_param(clause, pos, structs, min_fields) end)

    case consensus(inferences) do
      {:lift, struct, via, param} ->
        ref = hd(group)

        [
          %{
            module: ref.module,
            name: ref.name,
            arity: ref.arity,
            param: param,
            struct: struct,
            via: via,
            path: ref.path
          }
        ]

      {:decline, reason, param} ->
        ref = hd(group)
        [%{module: ref.module, name: ref.name, arity: ref.arity, param: param, reason: reason}]

      :skip ->
        []
    end
  end

  # All clauses must agree on one struct for the position. Any decline,
  # or two clauses inferring different structs, blocks the lift.
  defp consensus(inferences) do
    cond do
      Enum.any?(inferences, &match?({:skip, _}, &1)) ->
        :skip

      decline = Enum.find(inferences, &match?({:decline, _, _}, &1)) ->
        decline

      true ->
        structs = inferences |> Enum.map(fn {:lift, s, _v, _p} -> s end) |> Enum.uniq()
        params = inferences |> Enum.map(fn {:lift, _s, _v, p} -> p end) |> Enum.uniq()

        case {structs, params} do
          {[struct], _} -> {:lift, struct, lift_via(inferences), hd(params)}
          _ -> {:decline, :divergent_clauses, hd(params)}
        end
    end
  end

  defp lift_via(inferences) do
    if Enum.any?(inferences, &match?({:lift, _, :spec, _}, &1)), do: :spec, else: :fields
  end

  # Infer the struct for one parameter position of one clause.
  # Returns `{:lift, struct, via, param_name}`, `{:decline, reason,
  # param_name}`, or `{:skip, reason}` (position is not a bare untyped
  # param — nothing to say about it).
  defp infer_param(clause, pos, structs, min_fields) do
    param = Enum.at(clause.params, pos)

    case bare_var(param) do
      {:ok, var} -> infer_bare(clause, pos, var, structs, min_fields)
      :skip -> {:skip, :not_bare_param}
    end
  end

  defp infer_bare(clause, pos, var, structs, min_fields) do
    cond do
      # An explicit @spec is binding proof — it overrides every heuristic
      # below, including the builder guard.
      spec_struct = spec_struct(clause.spec, pos, structs) ->
        {:lift, spec_struct, :spec, var}

      passed_whole?(clause.body, var) ->
        {:decline, :param_passed_to_call, var}

      # `X_to_Y(arg)` building `%Y{field: arg.field, …}`: `arg` is the
      # SOURCE projection feeding the build, not the target struct. Its
      # fields coincide with some struct's only because the query selected
      # exactly what the build needs — inferring `arg :: %ThatStruct{}`
      # would type the projection as its own output. Decline.
      builds_struct_from?(clause.body, var) ->
        {:decline, :builds_struct_from_param, var}

      true ->
        infer_from_fields(clause.body, var, structs, min_fields)
    end
  end

  # True when the body constructs a struct literal `%Mod{...}` into which
  # a `var.field` access flows — the field-extraction-into-a-builder shape.
  defp builds_struct_from?(nil, _var), do: false

  defp builds_struct_from?(body, var) do
    body
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:%, _, [_alias, {:%{}, _, _} = fields]} -> reads_var?(fields, var)
      _ -> false
    end)
  end

  # Whether `var.field` appears anywhere inside the given AST fragment.
  defp reads_var?(ast, var) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {{:., _, [{^var, _, ctx}, field]}, _, []} when is_atom(ctx) and is_atom(field) -> true
      _ -> false
    end)
  end

  defp infer_from_fields(body, var, structs, min_fields) do
    accesses = field_accesses(body, var)
    distinctive = Enum.reject(accesses, &(&1 in @generic_fields))

    # The match still uses the FULL accessed set (the value genuinely has
    # those fields), but the threshold counts only distinctive ones:
    # `var.type`+`var.name` alone proves nothing.
    if length(distinctive) < min_fields do
      {:decline, :too_few_distinctive_fields, var}
    else
      case unique_superset(MapSet.new(accesses), structs) do
        {:ok, struct} -> {:lift, struct, :fields, var}
        :ambiguous -> {:decline, :ambiguous_struct, var}
        :none -> {:decline, :no_struct_fits, var}
      end
    end
  end

  # The struct a `@spec` names for this position, if it is an in-project
  # struct (`Position.t()` → `Position` when `Position` has a defstruct).
  defp spec_struct(nil, _pos, _structs), do: nil

  defp spec_struct(arg_types, pos, structs) do
    with type when not is_nil(type) <- Enum.at(arg_types, pos),
         {:ok, module} <- spec_type_module(type),
         true <- Map.has_key?(structs, module) do
      module
    else
      _ -> nil
    end
  end

  # `Position.t()` → `{:ok, Position}`; `Position.t` likewise; anything
  # else (`term()`, `String.t()`, a var) → :error.
  defp spec_type_module({{:., _, [alias_ast, :t]}, _, _args}), do: alias_to_module(alias_ast)
  defp spec_type_module(_), do: :error

  # Exactly one struct whose field set ⊇ the accessed fields, and no
  # other. Two fit → :ambiguous; none → :none.
  defp unique_superset(accessed, structs) do
    fits =
      structs
      |> Enum.filter(fn {_mod, fields} -> MapSet.subset?(accessed, fields) end)
      |> Enum.map(fn {mod, _fields} -> mod end)

    case fits do
      [single] -> {:ok, single}
      [] -> :none
      [_ | _] -> :ambiguous
    end
  end

  # --- AST probes ---

  # Every field read off `var` in the body. A field access `var.field`
  # and a zero-arg call `var.fun()` are BOTH `{{:., _, [var, name]}, _,
  # []}` — the only AST difference is the call carries a `closing:` (the
  # `()`) in its meta while a field access carries `no_parens: true`.
  # Counting `var.fun()` as a field would falsely pin a struct on a value
  # that's actually a module (`module.values()`), so only `no_parens`
  # dotted accesses count.
  defp field_accesses(nil, _var), do: []

  defp field_accesses(body, var) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {{:., _, [{^var, _, ctx}, field]}, meta, []}
      when is_atom(ctx) and is_atom(field) ->
        if Keyword.get(meta, :no_parens, false), do: [field], else: []

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  # `var` handed whole into a call (`helper(var)`, `f(a, var)`, a pipe
  # `var |> g()`): the callee may read fields we can't see, so the field
  # set is incomplete and inference is unsafe. A bare `var.field` access
  # is NOT "passed whole" — that's the dotted-remote form handled above.
  defp passed_whole?(nil, _var), do: false

  defp passed_whole?(body, var) do
    body
    |> Macro.prewalker()
    |> Enum.any?(&node_passes_var?(&1, var))
  end

  # `var.field` — the dotted-access form — is the ONE remote-call shape
  # that does NOT count as passing the var whole; it's exactly the access
  # we lift on. Match it first and reject it, so the generic call clause
  # below (which would see `.`/`[var, :field]` as a call with `var` as an
  # argument) never misfires on it.
  defp node_passes_var?({{:., _, [{var, _, ctx}, field]}, _, []}, var)
       when is_atom(ctx) and is_atom(field),
       do: false

  defp node_passes_var?({:|>, _, [{var, _, ctx}, _rhs]}, var) when is_atom(ctx), do: true

  # The bare `.` operator node (`{:., _, [var, :field]}`) is the access
  # itself, not a call passing the var — `:.` is not a real function
  # name. Excluding it here is what keeps `var.field` from reading as a
  # call with `var` as its argument.
  defp node_passes_var?({:., _, _}, _var), do: false

  defp node_passes_var?({fun, _, args}, var) when is_atom(fun) and is_list(args),
    do: var_in_args?(args, var)

  defp node_passes_var?({{:., _, _}, _, args}, var) when is_list(args),
    do: var_in_args?(args, var)

  defp node_passes_var?(_node, _var), do: false

  defp var_in_args?(args, var) do
    Enum.any?(args, fn
      {^var, _, ctx} when is_atom(ctx) -> true
      _ -> false
    end)
  end

  defp name_and_args({name, _, args}) when is_atom(name) and is_list(args),
    do: {:ok, name, args}

  defp name_and_args(_), do: :error

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  # --- rewriting ---

  defp rewrite(source, structs, min_fields) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.flat_map(&clause_patches(&1, structs, min_fields))
        |> patch_or_passthrough(source)

      {:error, _} ->
        source
    end
  end

  # Re-run inference on this source's own clauses (the prepared plan
  # carries the project struct index, but the patch positions are local
  # to each file). Group by `{name, arity}` so divergent clauses decline
  # consistently with the plan.
  defp clause_patches({:defmodule, _, [name_ast, [{_do, body}]]}, structs, min_fields) do
    case alias_to_module(name_ast) do
      {:ok, module} ->
        exprs = body_to_exprs(body)
        specs = spec_table(exprs)

        clauses =
          exprs
          |> Enum.flat_map(&clause_record(&1, module, "", specs))

        {lifts, _declined} = resolve_lifts(clauses, structs, min_fields)
        lift_set = MapSet.new(lifts, fn l -> {l.name, l.arity, l.param, l.struct} end)

        Enum.flat_map(exprs, &node_patches(&1, lift_set))

      :error ->
        []
    end
  end

  defp clause_patches(_node, _structs, _min_fields), do: []

  defp node_patches({kind, _, [head | _]}, lift_set) when kind in [:def, :defp] do
    case name_and_args(strip_when(head)) do
      {:ok, name, args} -> param_patches(args, name, length(args), lift_set)
      :error -> []
    end
  end

  defp node_patches(_node, _lift_set), do: []

  defp param_patches(args, name, arity, lift_set) do
    args
    |> Enum.with_index()
    |> Enum.flat_map(fn {arg, _pos} ->
      case bare_var(arg) do
        {:ok, var} -> var_patch(arg, var, name, arity, lift_set)
        :skip -> []
      end
    end)
  end

  defp var_patch(arg, var, name, arity, lift_set) do
    case Enum.find(lift_set, fn {n, a, p, _s} -> n == name and a == arity and p == var end) do
      {_n, _a, _p, struct} ->
        [Patch.new(Sourceror.get_range(arg), "%#{module_suffix(struct)}{} = #{var}")]

      nil ->
        []
    end
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  # --- engine plumbing ---

  defp excluded_path?(path), do: String.starts_with?(path, @excluded_path_prefixes)

  defp plan_sources(opts) do
    opts
    |> Keyword.get(:paths, [])
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, source} -> [{path, source}]
        {:error, _} -> []
      end
    end)
  end
end
