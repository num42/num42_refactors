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

  Inference draws on five sources, strongest signal first. A stronger
  source's verdict is never overturned by a weaker one:

  1. **An existing `@spec`** over the clause names the argument type
     outright (`@spec f(Position.t()) :: …`). Zero ambiguity — lift to it.
     Binding even over the builder guard below.
  2. **Call sites (AST).** A project-wide scan of every call to the
     function: an argument that is a struct literal (`f(%Brand{})`,
     `f(%Brand{} = x)`) reveals the parameter's type by real data flow.
     Overrides a weaker field guess to the same struct (and a *conflict*
     with the field guess declines); rescues a body that proved nothing.
     When callers pass **several** distinct structs, see Polymorphism.
  3. **Field-superset.** Collect the `var.field` accesses; if exactly one
     in-project struct's field set is a superset of them *and no other
     struct's is*, that is the type. Two or more fit → ambiguous →
     decline. None fit → decline (the value is a map, not a struct — e.g.
     a `select`-projection with join/compute fields no struct carries).
  4. **AST delegation.** A param the body proves nothing about but passes
     **whole** into a call (`f(arg), do: Shared.g(arg)`) borrows its type
     from the receiver's head: if `g/1` pattern-matches `%Scope{}` at that
     position in *every* clause, `arg` must be a `%Scope{}`. Pure source,
     no PLT. Combined with the **fixpoint loop** (see below) this is the
     biggest single lever on real codebases, where most params are passed
     through context functions rather than read field-by-field.
  5. **Dialyzer success typing.** Last resort: the project PLT is read
     directly (`:dialyzer_cplt`/`:dialyzer_plt`) and the inferred type for
     the position is taken if it is an in-project struct. Catches
     delegation through receivers whose own heads are untyped (the AST
     source can't), at the cost of depending on a built PLT. Opt out with
     `dialyzer: false`.

  The decline-on-ambiguity guard is the core of the design, not an
  afterthought. The builder decline (a param fed *into* a struct build) is
  preserved by every external source — none of them retypes the source
  projection as its own output.

  ## Fixpoint loop

  Delegation has a chicken-and-egg limit: it can only borrow a type from a
  receiver head that is *already* struct-typed, and on a fresh codebase
  few are. So resolution **iterates to a fixpoint** — each round's lifts
  type their own heads, which become new delegation receivers for the next
  round. In `h(x), do: f(x)` / `f(arg), do: g(arg)` / `g(%Scope{} = s)`,
  round 1 lifts `f` (off `g`), round 2 lifts `h` (off the now-typed `f`).
  The receiver index grows monotonically and is finitely bounded, so it
  terminates; a round cap guards against any non-monotone surprise.

  ## Polymorphism: duplicate the clause per struct

  When call sites pass **two or more** distinct structs at the same
  position, the function is polymorphic over them. Instead of declining,
  the single clause is **duplicated** — one struct-typed head per target,
  sharing the body — but only when it is provably safe:

    - the function has exactly **one** clause (duplicating a multi-clause
      function would cross-multiply heads and reorder matching),
    - the param is a plain bare var,
    - the body neither passes the param whole into a call nor builds a
      struct from it, and
    - **every** `var.field` read in the body exists in **every** target
      struct — otherwise one duplicated head would fail at compile/run.

  `def label(r), do: {r.name, r.slogan}` with callers passing `%Brand{}`
  and `%Maker{}` (both carrying `name`/`slogan`) becomes two heads
  `def label(%Brand{} = r)` / `def label(%Maker{} = r)`. A field absent
  from one target declines the whole thing (`:polymorphic_unsafe`).

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

  ## Project-wide indexes

  Inference is cross-file. `prepare/1` builds three indexes, threaded to
  `transform/2` via the prepared plan:

    - **struct index** — every `defstruct` in the project, as
      `%{module => MapSet(fields)}` (source AST only),
    - **call-site index** — every call's struct-literal arguments, as
      `%{ {module, name, arity} => [%{pos => struct}] }` (source AST only),
    - **Dialyzer index** — the PLT's struct-typed argument positions, as
      `%{ {module, name, arity} => %{pos => struct} }`. Opt out with
      `dialyzer: false`; point at a specific PLT with `plt_path:`;
      otherwise the conventional locations (`priv/plts/*.plt`, …) are
      tried. The PLT is read once per plan; absence simply disables the
      source.

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

  # Conventional Dialyzer PLT locations, in priority order. The first
  # existing match drives the Dialyzer type source when no `:plt_path`
  # option is given; none existing simply disables that source.
  @plt_globs ["priv/plts/*.plt", "_build/*/*.plt", "*.plt"]

  # Belt-and-braces cap on the delegation fixpoint loop. The receiver
  # index grows monotonically and is finitely bounded, so the loop
  # terminates on its own (`enriched == receivers`); this only guards
  # against a non-monotone surprise. Real chains are a handful deep.
  @max_fixpoint_rounds 10

  # Forms that parse as `{atom, meta, args}` but aren't function calls
  # whose arguments we'd type at the call site — definitions, control
  # flow, operators. A local call `fun(args)` is attributed to its
  # enclosing module only when `fun` is not one of these.
  @non_call_forms ~w(def defp defmacro defmacrop defmodule defstruct
                     defprotocol defimpl when -> :: |> = if unless case cond
                     with for try receive fn quote __block__ __aliases__ %
                     %{} {} <<>> .)a

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

  # A polymorphic lift duplicates a clause into N freshly-rendered heads;
  # the synthesized layout (blank lines between copies) needs `mix format`
  # to settle. Single-struct lifts are in-place param patches and wouldn't
  # need it, but the refactor can't know in advance which path fired.
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    {:ok, build_plan(plan_sources(opts), opts)}
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    case Keyword.get(opts, :prepared) do
      %{structs: structs} = plan ->
        ctx = %{
          structs: structs,
          call_sites: Map.get(plan, :call_sites, %{}),
          dialyzer: Map.get(plan, :dialyzer, %{}),
          receivers: Map.get(plan, :receivers, %{}),
          min_fields: Map.get(plan, :min_fields, @default_min_fields)
        }

        rewrite(source, ctx)

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

    clauses = Enum.flat_map(visible, &clauses_in_source/1)

    structs = struct_index(visible)
    call_sites = call_site_index(visible, structs)
    dialyzer = dialyzer_index(opts, structs)
    seed_receivers = receiver_index(clauses, structs)

    base_ctx = %{
      structs: structs,
      call_sites: call_sites,
      dialyzer: dialyzer,
      min_fields: min_fields
    }

    {lifts, declined, receivers} = resolve_to_fixpoint(clauses, base_ctx, seed_receivers)

    %{
      structs: structs,
      call_sites: call_sites,
      dialyzer: dialyzer,
      receivers: receivers,
      min_fields: min_fields,
      lifts: lifts,
      declined: declined
    }
  end

  @doc """
  Human-readable report of a plan for `--log`/dry-run review.
  """
  @spec report(map()) :: String.t()
  def report(%{lifts: []}), do: "no untyped params to lift"

  def report(%{lifts: lifts}) do
    "liftable params:\n" <>
      Enum.map_join(lifts, "\n", fn l ->
        "  #{inspect(l.module)}.#{l.name}/#{l.arity} (#{l.param}) -> #{struct_display(l.struct)} (via #{l.via})"
      end)
  end

  # A single struct renders `%Mod{}`; a polymorphic lift renders all its
  # target structs (`%A{} | %B{}`).
  defp struct_display(structs) when is_list(structs) do
    Enum.map_join(structs, " | ", &"%#{module_suffix(&1)}{}")
  end

  defp struct_display(struct), do: "%#{module_suffix(struct)}{}"

  defp module_suffix(mod), do: mod |> Module.split() |> Enum.join(".")

  # --- project-wide call-site index ---

  # `%{ {module, name, arity} => [%{pos => struct | nil}] }` — one entry
  # per recorded call site, mapping each argument position to the struct
  # passed there (or nil when no struct is evident). Built from explicit
  # struct literals at the call site: `f(%Brand{...})` or `f(%Brand{} =
  # x)`. Only literals are read in this slice — a value that is merely a
  # variable carries no struct identity here (scope/spec tracking is a
  # later refinement). Remote calls (`Mod.f(..)`) key off the resolved
  # module; local calls (`f(..)`) key off the enclosing module. A key
  # that doesn't match a real clause is harmless — it's never looked up.
  defp call_site_index(sources, structs) do
    sources
    |> Enum.flat_map(&call_sites_in_source(&1, structs))
    |> Enum.group_by(fn {key, _arg_map} -> key end, fn {_key, arg_map} -> arg_map end)
  end

  defp call_sites_in_source({_path, src}, structs) do
    case Sourceror.parse_string(src) do
      {:ok, ast} -> ast |> Macro.prewalker() |> Enum.flat_map(&module_call_sites(&1, structs))
      {:error, _} -> []
    end
  end

  defp module_call_sites({:defmodule, _, [name_ast, [{_do, body}]]}, structs) do
    case alias_to_module(name_ast) do
      {:ok, module} -> calls_in_ast(body, module, structs)
      :error -> []
    end
  end

  defp module_call_sites(_node, _structs), do: []

  # Every call node under `body`, mapped to `{key, arg_struct_map}`.
  defp calls_in_ast(body, enclosing, structs) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(&call_record(&1, enclosing, structs))
  end

  # Remote call `Mod.fun(args)`.
  defp call_record({{:., _, [mod_ast, fun]}, _, args}, _enclosing, structs)
       when is_atom(fun) and is_list(args) do
    case alias_to_module(mod_ast) do
      {:ok, module} -> [{{module, fun, length(args)}, arg_structs(args, structs)}]
      :error -> []
    end
  end

  # Local call `fun(args)` — attributed to the enclosing module. Excludes
  # AST operators and the dotted-access node handled above.
  defp call_record({fun, _, args}, enclosing, structs)
       when is_atom(fun) and is_list(args) and fun not in @non_call_forms do
    [{{enclosing, fun, length(args)}, arg_structs(args, structs)}]
  end

  defp call_record(_node, _enclosing, _structs), do: []

  # `%{pos => struct | nil}` for each argument position, recording the
  # struct identity of explicit struct literals (`%Brand{}`, `%Brand{} =
  # x`) when the struct is in-project; nil otherwise.
  defp arg_structs(args, structs) do
    args
    |> Enum.with_index()
    |> Map.new(fn {arg, pos} -> {pos, literal_struct(arg, structs)} end)
  end

  # `%Brand{...}` -> Brand (if in-project); `%Brand{} = _` (either side) ->
  # same; anything else -> nil.
  defp literal_struct({:=, _, [lhs, rhs]}, structs) do
    literal_struct(lhs, structs) || literal_struct(rhs, structs)
  end

  defp literal_struct({:%, _, [alias_ast, {:%{}, _, _}]}, structs) do
    with {:ok, module} <- alias_to_module(alias_ast),
         true <- Map.has_key?(structs, module) do
      module
    else
      _ -> nil
    end
  end

  defp literal_struct(_node, _structs), do: nil

  # --- Dialyzer PLT index ---

  # `%{ {module, name, arity} => %{pos => struct} }` derived from the
  # project's Dialyzer PLT: for every function with a recorded success
  # typing, each argument whose inferred type is an in-project struct.
  #
  # The PLT is read directly via the `:dialyzer_cplt`/`:dialyzer_plt`
  # Erlang API (part of the OTP `dialyzer` app — always present, not the
  # dev-only `:dialyxir` Mix dep). A struct in `erl_types` is a map whose
  # `__struct__` key maps to a single concrete module atom; that atom IS
  # the Elixir module. Everything is best-effort: no PLT, an unreadable
  # PLT, or an unexpected term shape yields an empty index (Dialyzer
  # simply doesn't contribute), never a crash.
  defp dialyzer_index(opts, structs) do
    cond do
      # A pre-built index injected directly (tests, or a caller that read
      # the PLT once and threads it through several plans).
      index = Keyword.get(opts, :dialyzer_index) -> index
      Keyword.get(opts, :dialyzer, true) == false -> %{}
      path = plt_path(opts) -> load_dialyzer_index(path, structs)
      true -> %{}
    end
  end

  defp load_dialyzer_index(path, structs) do
    plt = :dialyzer_cplt.from_file(to_charlist(path))

    plt
    |> plt_modules()
    |> Enum.flat_map(&module_struct_args(plt, &1, structs))
    |> Map.new()
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp plt_modules(plt) do
    plt |> :dialyzer_plt.all_modules() |> :sets.to_list()
  rescue
    _ -> []
  end

  # Struct-typed argument positions for every function of one module.
  defp module_struct_args(plt, module, structs) do
    case :dialyzer_plt.lookup_module(plt, module) do
      {:value, entries} when is_list(entries) ->
        entries
        |> Enum.map(&elem(&1, 0))
        |> Enum.flat_map(&mfa_struct_args(plt, &1, structs))

      _ ->
        []
    end
  end

  defp mfa_struct_args(plt, {module, name, arity} = mfa, structs)
       when is_atom(module) and is_atom(name) and is_integer(arity) do
    arg_map =
      plt
      |> success_args(mfa)
      |> Enum.with_index()
      |> Enum.flat_map(fn {type, pos} -> typed_struct_arg(type, pos, structs) end)
      |> Map.new()

    if map_size(arg_map) == 0, do: [], else: [{{module, name, arity}, arg_map}]
  end

  defp mfa_struct_args(_plt, _mfa, _structs), do: []

  defp typed_struct_arg(type, pos, structs) do
    case erl_type_struct(type) do
      module when is_atom(module) and not is_nil(module) ->
        if Map.has_key?(structs, module), do: [{pos, module}], else: []

      _ ->
        []
    end
  end

  # The argument-type list of an MFA's success typing, `[]` on any miss.
  defp success_args(plt, mfa) do
    case :dialyzer_plt.lookup(plt, mfa) do
      {:value, {_ret, args}} when is_list(args) -> args
      _ -> []
    end
  end

  @doc """
  The module of an `erl_types` struct type, or nil.

  A struct in Dialyzer's `erl_types` is a map whose `__struct__` key maps
  to a single concrete module atom; that atom is the Elixir module. This
  is the one place coupled to Dialyzer's internal term shape, so it is
  exposed for a format-lock test against real `:erl_types` output. Not
  part of the stable public refactor API.
  """
  @spec erl_type_struct(term()) :: module() | nil
  def erl_type_struct({:c, :map, map_inner, _}) when is_tuple(map_inner) do
    case elem(map_inner, 0) do
      pairs when is_list(pairs) -> struct_module_from_pairs(pairs)
      _ -> nil
    end
  end

  def erl_type_struct(_type), do: nil

  defp struct_module_from_pairs(pairs) do
    Enum.find_value(pairs, fn
      {{:c, :atom, [:__struct__], _}, _opt, {:c, :atom, [module], _}} -> module
      _ -> nil
    end)
  end

  # The PLT file to read: an explicit `:plt_path` option wins; otherwise
  # the first match of the conventional locations. nil when none exists,
  # which disables the Dialyzer source.
  defp plt_path(opts) do
    case Keyword.get(opts, :plt_path) do
      nil -> default_plt_path()
      path -> if File.exists?(path), do: path, else: nil
    end
  end

  defp default_plt_path do
    @plt_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.find(&File.exists?/1)
  end

  # --- receiver-head index (AST delegation) ---

  # `%{ {module, name, arity} => %{pos => struct} }` — for each function,
  # the argument positions that ALREADY carry an in-project struct pattern
  # in the head (`def g(%Scope{} = s)`), and which struct. Only positions
  # where EVERY clause agrees on the same struct are recorded: a position
  # one clause leaves untyped (or types differently) is not a guaranteed
  # contract, so a value flowing there isn't provably that struct.
  #
  # This is what lets a passed-whole param be typed without a PLT: if
  # `f(arg), do: g(arg)` and `g/1` is recorded here as `%{0 => Scope}`,
  # then `arg` must be a `%Scope{}`.
  defp receiver_index(clauses, structs) do
    clauses
    |> Enum.group_by(fn c -> {c.module, c.name, c.arity} end)
    |> Enum.flat_map(fn {key, group} -> receiver_entry(key, group, structs) end)
    |> Map.new()
  end

  defp receiver_entry(key, [first | _] = group, structs) do
    arg_map =
      0..(first.arity - 1)//1
      |> Enum.flat_map(fn pos -> agreed_struct(group, pos, structs) end)
      |> Map.new()

    if map_size(arg_map) == 0, do: [], else: [{key, arg_map}]
  end

  # The struct every clause carries at `pos` in its head, or [] if they
  # disagree / any clause leaves it untyped / it isn't an in-project struct.
  defp agreed_struct(group, pos, structs) do
    structs_at =
      group
      |> Enum.map(fn c -> param_struct(Enum.at(c.params, pos), structs) end)
      |> Enum.uniq()

    case structs_at do
      [struct] when not is_nil(struct) -> [{pos, struct}]
      _ -> []
    end
  end

  # The in-project struct a head param pattern pins: `%Scope{}`,
  # `%Scope{} = s`, `%Scope{field: _}` -> Scope; anything else -> nil.
  defp param_struct({:=, _, [lhs, rhs]}, structs) do
    param_struct(lhs, structs) || param_struct(rhs, structs)
  end

  defp param_struct({:%, _, [alias_ast, {:%{}, _, _}]}, structs) do
    with {:ok, module} <- alias_to_module(alias_ast),
         true <- Map.has_key?(structs, module) do
      module
    else
      _ -> nil
    end
  end

  defp param_struct(_node, _structs), do: nil

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
  # Iterate resolution to a fixpoint: each round's lifts type their own
  # heads, which become new delegation receivers for the next round. A
  # `f(arg), do: g(arg)` lift makes `f` a typed receiver, so a caller
  # `h(x), do: f(x)` can now resolve `x` in the next round. The receiver
  # index grows monotonically and is finitely bounded, so this terminates;
  # a round-count cap is a belt-and-braces guard against any non-monotone
  # surprise. Returns the final lifts/declines plus the enriched receiver
  # index (so the rewrite phase patches consistently with the last round).
  defp resolve_to_fixpoint(clauses, base_ctx, receivers, round \\ 0) do
    ctx = Map.put(base_ctx, :receivers, receivers)
    {lifts, declined} = resolve_lifts(clauses, ctx)

    enriched = merge_lift_receivers(receivers, lifts)

    if enriched == receivers or round >= @max_fixpoint_rounds do
      {lifts, declined, receivers}
    else
      resolve_to_fixpoint(clauses, base_ctx, enriched, round + 1)
    end
  end

  # Fold this round's single-struct lifts into the receiver index: a lift
  # of `{module, name, arity}` param P to struct S means that function now
  # pattern-matches S at P's position. Polymorphic lifts (struct is a
  # list) are NOT fed back — a head matching several structs is not a
  # single guaranteed contract for a delegated value.
  defp merge_lift_receivers(receivers, lifts) do
    Enum.reduce(lifts, receivers, fn lift, acc ->
      add_lift_receiver(acc, lift)
    end)
  end

  defp add_lift_receiver(receivers, %{struct: struct}) when is_list(struct), do: receivers

  defp add_lift_receiver(receivers, %{pos: pos, struct: struct} = lift) do
    key = {lift.module, lift.name, lift.arity}
    Map.update(receivers, key, %{pos => struct}, &Map.put_new(&1, pos, struct))
  end

  defp resolve_lifts(clauses, ctx) do
    clauses
    |> Enum.group_by(fn c -> {c.module, c.name, c.arity} end)
    |> Enum.flat_map(fn {key, group} -> resolve_group(key, group, ctx) end)
    |> Enum.split_with(&match?(%{struct: _}, &1))
  end

  # Judge each parameter position across all clauses of the function. A
  # position is lifted only if every clause infers the SAME struct for it
  # (a divergent or any-declining clause kills the position).
  defp resolve_group(key, [first | _] = group, ctx) do
    0..(first.arity - 1)//1
    |> Enum.flat_map(fn pos -> resolve_position(key, group, pos, ctx) end)
  end

  defp resolve_position(key, group, pos, ctx) do
    inferences = Enum.map(group, fn clause -> infer_param(clause, pos, ctx) end)
    ref = hd(group)

    decided =
      inferences
      |> consensus()
      |> apply_call_sites(key, pos, group, ctx)
      |> apply_delegation(key, pos, group, ctx)
      |> apply_dialyzer(key, pos, group, ctx)

    case decided do
      {:lift, struct, via, param} ->
        [lift_record(ref, pos, param, struct, via)]

      {:poly, structs, param} ->
        # struct as a LIST + via :call_site_poly is the rewrite's signal to
        # duplicate the clause, one head per struct.
        [lift_record(ref, pos, param, structs, :call_site_poly)]

      {:decline, reason, param} ->
        [%{module: ref.module, name: ref.name, arity: ref.arity, param: param, reason: reason}]

      :skip ->
        []
    end
  end

  defp lift_record(ref, pos, param, struct, via) do
    %{
      module: ref.module,
      name: ref.name,
      arity: ref.arity,
      pos: pos,
      param: param,
      struct: struct,
      via: via,
      path: ref.path
    }
  end

  # Fold the call-site evidence into the body-internal verdict, honouring
  # the precedence @spec > call-site > fields:
  #
  #   - @spec lift   -> binding, untouched (the human wrote the type).
  #   - field lift   -> call-site OVERRIDES it when call sites agree on a
  #     single struct (real data flow beats a guessed field-superset); a
  #     call-site disagreement with the field guess declines as a conflict.
  #   - any decline  -> call-site RESCUES it when call sites agree on one
  #     struct (the body couldn't prove a type, but the callers reveal it).
  #   - :skip        -> not a bare param; nothing for call sites to say.
  defp apply_call_sites({:lift, _struct, :spec, _param} = spec_lift, _key, _pos, _group, _ctx),
    do: spec_lift

  defp apply_call_sites(:skip, _key, _pos, _group, _ctx), do: :skip

  defp apply_call_sites(body, key, pos, group, ctx) do
    param = body_param(body, group, pos)

    case {body, call_site_struct(ctx.call_sites, key, pos)} do
      {_, :none} ->
        body

      # A builder param IS the source projection, proven by the body — a
      # call site passing some struct doesn't change that the param is fed
      # INTO a struct build, not bound to one. Leave the decline standing.
      {{:decline, :builds_struct_from_param, _}, _} ->
        body

      {{:lift, struct, :fields, _}, {:ok, struct}} ->
        {:lift, struct, :call_site, param}

      {{:lift, _field_struct, :fields, _}, {:ok, _other}} ->
        {:decline, :call_site_field_conflict, param}

      {{:decline, _reason, _}, {:ok, struct}} ->
        {:lift, struct, :call_site, param}

      # Polymorphism: callers pass >=2 distinct structs at this position.
      # Duplicate the clause, one head per struct — but only when it is
      # provably safe to do so (see resolve_poly/4).
      {_, {:poly, structs}} ->
        resolve_poly(structs, group, pos, ctx) || {:decline, :polymorphic_unsafe, param}
    end
  end

  # AST delegation: a passed-whole param that flows into a call whose
  # receiver already pattern-matches a struct at that position. Runs after
  # call-sites, before Dialyzer — it's visible source (stronger than the
  # PLT), but weaker than @spec/call-site/fields. Only rescues a remaining
  # decline; the builder decline is preserved (the param is the projection
  # feeding a build, not a value flowing to a typed receiver).
  defp apply_delegation({:lift, _, _, _} = lift, _key, _pos, _group, _ctx), do: lift
  defp apply_delegation({:poly, _, _} = poly, _key, _pos, _group, _ctx), do: poly
  defp apply_delegation(:skip, _key, _pos, _group, _ctx), do: :skip

  defp apply_delegation({:decline, :builds_struct_from_param, _} = decline, _k, _p, _g, _c),
    do: decline

  defp apply_delegation({:decline, _reason, param} = decline, _key, _pos, group, ctx) do
    case delegation_struct(group, param, ctx.receivers) do
      {:ok, struct} -> {:lift, struct, :delegation, param}
      :none -> decline
    end
  end

  # The struct a passed-whole `param` must be, inferred by following it
  # into a receiver call. Every clause of the group must agree: for each
  # clause, the param flows into exactly one call position whose receiver
  # is typed there, and all clauses resolve the same struct. Disagreement,
  # ambiguity (the param flows to >1 distinct typed position), or any
  # clause with no typed receiver -> :none.
  defp delegation_struct(group, param, receivers) do
    resolved =
      group
      |> Enum.map(fn clause -> clause_delegation_struct(clause, param, receivers) end)
      |> Enum.uniq()

    case resolved do
      [struct] when not is_nil(struct) -> {:ok, struct}
      _ -> :none
    end
  end

  # Within one clause body: the distinct struct(s) the receivers of every
  # call carrying `param` agree on. nil unless there's exactly one.
  defp clause_delegation_struct(%{module: enclosing, body: body}, param, receivers) do
    structs =
      body
      |> receiver_calls(param, enclosing)
      |> Enum.flat_map(fn {key, arg_pos} -> receiver_struct_at(receivers, key, arg_pos) end)
      |> Enum.uniq()

    case structs do
      [struct] -> struct
      _ -> nil
    end
  end

  defp receiver_struct_at(receivers, key, arg_pos) do
    case receivers |> Map.get(key, %{}) |> Map.get(arg_pos) do
      nil -> []
      struct -> [struct]
    end
  end

  # Every call under `body` that passes `param` as a bare argument, as
  # `{receiver_key, arg_pos}`. Remote `Mod.g(..)` keys off the resolved
  # module; local `g(..)` off the enclosing module. The dotted-access
  # form (`param.field`) and operators are excluded — those aren't
  # whole-param calls.
  defp receiver_calls(nil, _param, _enclosing), do: []

  defp receiver_calls(body, param, enclosing) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(&call_receiver(&1, param, enclosing))
  end

  defp call_receiver({{:., _, [mod_ast, fun]}, _, args}, param, _enclosing)
       when is_atom(fun) and is_list(args) do
    case {alias_to_module(mod_ast), bare_arg_pos(args, param)} do
      {{:ok, module}, {:ok, pos}} -> [{{module, fun, length(args)}, pos}]
      _ -> []
    end
  end

  defp call_receiver({fun, _, args}, param, enclosing)
       when is_atom(fun) and is_list(args) and fun not in @non_call_forms do
    case bare_arg_pos(args, param) do
      {:ok, pos} -> [{{enclosing, fun, length(args)}, pos}]
      :none -> []
    end
  end

  defp call_receiver(_node, _param, _enclosing), do: []

  # The position at which bare `param` appears in an arg list, if exactly
  # once. Appearing more than once (or not at all) -> :none.
  defp bare_arg_pos(args, param) do
    positions =
      args
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{^param, _, ctx}, pos} when is_atom(ctx) -> [pos]
        _ -> []
      end)

    case positions do
      [pos] -> {:ok, pos}
      _ -> :none
    end
  end

  # The lowest-priority external source: Dialyzer's success typing. It
  # only speaks when nothing stronger decided — `apply_dialyzer` runs
  # AFTER `apply_call_sites`, so by here a lift means @spec/call-site/field
  # already won and Dialyzer must not touch it. It rescues a remaining
  # DECLINE (the body proved nothing and no caller passed a literal) when
  # the PLT inferred a single in-project struct for the position — exactly
  # the `passed_whole?` case (the param flows into a call the body can't
  # see, but Dialyzer followed it). The builder decline is preserved: a
  # success typing of the source projection doesn't make it the target.
  defp apply_dialyzer({:lift, _, _, _} = lift, _key, _pos, _group, _ctx), do: lift
  defp apply_dialyzer({:poly, _, _} = poly, _key, _pos, _group, _ctx), do: poly
  defp apply_dialyzer(:skip, _key, _pos, _group, _ctx), do: :skip

  defp apply_dialyzer({:decline, :builds_struct_from_param, _} = decline, _k, _p, _g, _c),
    do: decline

  defp apply_dialyzer({:decline, _reason, param} = decline, key, pos, _group, ctx) do
    case dialyzer_struct(ctx.dialyzer, key, pos) do
      {:ok, struct} -> {:lift, struct, :dialyzer, param}
      :none -> decline
    end
  end

  # The in-project struct Dialyzer inferred for this position, or :none.
  defp dialyzer_struct(dialyzer, key, pos) do
    case dialyzer |> Map.get(key, %{}) |> Map.get(pos) do
      nil -> :none
      struct -> {:ok, struct}
    end
  end

  # A polymorphic lift duplicates one clause into N struct-typed heads. It
  # is only sound when:
  #
  #   1. the function has exactly ONE clause — duplicating a multi-clause
  #      function would cross-multiply heads and reorder pattern matching,
  #   2. that clause's param is a plain bare var (not already a pattern),
  #   3. the body neither passes the param whole into a call nor builds a
  #      struct from it — those declines mean the param isn't a struct
  #      binding to begin with, and
  #   4. every `var.field` read in the body exists in EVERY target struct
  #      — otherwise one duplicated head would fail to compile/run.
  #
  # Any failure returns nil; the caller turns that into a decline.
  defp resolve_poly(_structs, [_, _ | _] = _multi_clause, _pos, _ctx), do: nil

  defp resolve_poly(structs, [clause], pos, ctx) do
    with {:ok, var} <- bare_var(Enum.at(clause.params, pos)),
         false <- passed_whole?(clause.body, var),
         false <- builds_struct_from?(clause.body, var),
         accessed = MapSet.new(field_accesses(clause.body, var)),
         true <- fields_in_all?(accessed, structs, ctx.structs) do
      {:poly, structs, var}
    else
      _ -> nil
    end
  end

  # Every accessed field is present in the field set of every target
  # struct — the precondition for a duplicated head to be valid for all.
  defp fields_in_all?(accessed, structs, struct_index) do
    Enum.all?(structs, fn s ->
      fields = Map.get(struct_index, s, MapSet.new())
      MapSet.subset?(accessed, fields)
    end)
  end

  # The bare-param name for this position, recovered from the head when
  # the body verdict doesn't carry one (a decline still names its param,
  # but be defensive for positions that resolved to :skip upstream).
  defp body_param({:lift, _s, _v, p}, _group, _pos), do: p
  defp body_param({:decline, _r, p}, _group, _pos), do: p

  defp body_param(_other, group, pos) do
    case bare_var(Enum.at(hd(group).params, pos)) do
      {:ok, var} -> var
      :skip -> nil
    end
  end

  # What the recorded call sites agree on at this position:
  #
  #   {:ok, struct}        all struct-passing sites pass the same struct
  #   {:poly, [s1, s2, …]} sites pass >=2 distinct structs (sorted)
  #   :none                no struct evident at any site
  #
  # Sites passing a non-struct value (recorded nil) are ignored — they
  # neither confirm nor contradict; only the struct-bearing sites speak.
  defp call_site_struct(call_sites, key, pos) do
    structs =
      call_sites
      |> Map.get(key, [])
      |> Enum.map(&Map.get(&1, pos))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case structs do
      [] -> :none
      [single] -> {:ok, single}
      many -> {:poly, Enum.sort(many)}
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
  defp infer_param(clause, pos, ctx) do
    param = Enum.at(clause.params, pos)

    case bare_var(param) do
      {:ok, var} -> infer_bare(clause, pos, var, ctx)
      :skip -> {:skip, :not_bare_param}
    end
  end

  defp infer_bare(clause, pos, var, ctx) do
    cond do
      # An explicit @spec is binding proof — it overrides every heuristic
      # below, including the builder guard.
      spec_struct = spec_struct(clause.spec, pos, ctx.structs) ->
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
        infer_from_fields(clause.body, var, ctx.structs, ctx.min_fields)
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

  defp rewrite(source, ctx) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.flat_map(&clause_patches(&1, ctx))
        |> patch_or_passthrough(source)

      {:error, _} ->
        source
    end
  end

  # Re-run inference on this source's own clauses (the prepared plan
  # carries the project struct index AND call-site index, but the patch
  # positions are local to each file). Group by `{name, arity}` so
  # divergent clauses decline consistently with the plan; the call-site
  # evidence flows through `ctx`, so a lift driven entirely by callers in
  # OTHER files still patches this file's head.
  defp clause_patches({:defmodule, _, [name_ast, [{_do, body}]]}, ctx) do
    case alias_to_module(name_ast) do
      {:ok, module} ->
        exprs = body_to_exprs(body)
        specs = spec_table(exprs)

        clauses =
          exprs
          |> Enum.flat_map(&clause_record(&1, module, "", specs))

        {lifts, _declined} = resolve_lifts(clauses, ctx)
        lift_set = MapSet.new(lifts, fn l -> {l.name, l.arity, l.param, l.struct} end)

        Enum.flat_map(exprs, &node_patches(&1, lift_set))

      :error ->
        []
    end
  end

  defp clause_patches(_node, _ctx), do: []

  defp node_patches({kind, _, [head | _]} = node, lift_set) when kind in [:def, :defp] do
    case name_and_args(strip_when(head)) do
      {:ok, name, args} -> clause_node_patches(node, name, args, lift_set)
      :error -> []
    end
  end

  defp node_patches(_node, _lift_set), do: []

  # A polymorphic lift on any param duplicates the WHOLE clause, so it
  # can't coexist with per-param patches on the same node — resolve the
  # node as a single unit, poly first.
  defp clause_node_patches(node, name, args, lift_set) do
    case poly_param(args, name, length(args), lift_set) do
      {var, structs} -> [duplicate_clause_patch(node, var, structs)]
      nil -> param_patches(args, name, length(args), lift_set)
    end
  end

  # The first param of this clause whose lift is polymorphic (struct is a
  # list), as `{var, structs}`; nil when no param lifts polymorphically.
  defp poly_param(args, name, arity, lift_set) do
    Enum.find_value(args, &poly_param_lift(&1, name, arity, lift_set))
  end

  defp poly_param_lift(arg, name, arity, lift_set) do
    with {:ok, var} <- bare_var(arg),
         {_n, _a, _p, structs} <- find_poly_lift(lift_set, name, arity, var) do
      {var, structs}
    else
      _ -> nil
    end
  end

  defp find_poly_lift(lift_set, name, arity, var) do
    Enum.find(lift_set, fn {n, a, p, s} ->
      n == name and a == arity and p == var and is_list(s)
    end)
  end

  # Replace the single clause's source with one copy per struct, the poly
  # param pattern-matched to that struct in each. Each copy is the node's
  # own rendered source with `var` rewritten to `%Struct{} = var`; we
  # re-parse that rendered text so the patch positions are local to it
  # (no manual range arithmetic against the file).
  defp duplicate_clause_patch(node, var, structs) do
    range = Sourceror.get_range(node)
    original = Sourceror.to_string(node)

    copies = Enum.map_join(structs, "\n\n", &typed_clause(original, var, &1))

    Patch.new(range, copies)
  end

  # One clause copy: re-parse the rendered single-clause source, find the
  # bare `var` param in its head, patch it to `%Struct{} = var`.
  defp typed_clause(original, var, struct) do
    with {:ok, ast} <- Sourceror.parse_string(original),
         arg when not is_nil(arg) <- head_param(ast, var) do
      Sourceror.patch_string(original, [
        Patch.new(Sourceror.get_range(arg), "%#{module_suffix(struct)}{} = #{var}")
      ])
    else
      _ -> original
    end
  end

  # The bare-`var` param AST node from a rendered clause's head.
  defp head_param({_kind, _, [head | _]}, var) do
    case name_and_args(strip_when(head)) do
      {:ok, _name, args} -> Enum.find(args, &match?({:ok, ^var}, bare_var(&1)))
      :error -> nil
    end
  end

  defp head_param(_node, _var), do: nil

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
    case Enum.find(lift_set, fn {n, a, p, s} ->
           n == name and a == arity and p == var and not is_list(s)
         end) do
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
