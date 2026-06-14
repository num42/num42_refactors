defmodule Number42.Refactors.Ex.RelocateMisplacedFunction do
  @moduledoc """
  Move a function that almost exclusively touches *another* module
  (Fowler's "Feature Envy") into that module, and rewrite every call
  site — direct (`A.f(x)`), pipe (`x |> A.f()`), and capture
  (`&A.f/1`, `&A.f(&1)`) forms alike.

      # before — MyApp.A
      defmodule MyApp.A do
        alias MyApp.B
        def brand_label(%B{} = brand), do: B.name(brand) <> B.code(brand)
      end
      # called elsewhere: A.brand_label(brand)

      # after — three files
      defmodule MyApp.A do
        alias MyApp.B
        defdelegate brand_label(brand), to: MyApp.B
      end

      defmodule MyApp.B do
        # ...
        def brand_label(%B{} = brand), do: B.name(brand) <> B.code(brand)
      end
      # call sites rewritten: MyApp.B.brand_label(brand)

  ## The envy metric (deliberately conservative)

  A `def` in host `A` is a relocation candidate only when its body
  exhibits *unambiguous* feature envy on a single other module `B`:

    * It references `B` (a `B.fun(...)` remote call or a `%B{}` struct)
      at least once.
    * Every envied remote reference points at the **same** module `B`
      — two equally-envied modules are ambiguous, so we skip.
    * The body makes **no local call** to any sibling `def`/`defp` in
      `A`, references **no `@attr`** of `A`, and never mentions
      `__MODULE__`. Any of those would break (or be silently
      mis-resolved) once the body lives in `B`, so they are hard skips
      rather than co-migrations.

  ## Graph / safety preconditions (all must hold)

    * `B` is defined somewhere in the corpus — we cannot append into a
      module we cannot see.
    * No `{name, arity}` clash already exists in `B`.
    * `B` does not (transitively, at file granularity) reference `A`.
      Moving the body into `B` while `A` keeps a `defdelegate ..., to:
      B` would otherwise close a dependency cycle `A → B → A`.
    * No call site uses a dynamic `apply(A, :name, …)`. A dynamic
      dispatch cannot be rewritten statically, so the move is unsafe —
      skip entirely.

  The host keeps a `defdelegate name(args), to: B` rather than deleting
  the function outright: external callers outside the corpus continue
  to resolve `A.name/arity`, and the delegate is itself idempotent
  (re-running finds no envious `def` left in `A`).

  ## `prepare/1` and the file-move trick

  Like `ExtractSharedModule`, the actual file move happens as a side
  effect of `prepare/1`: it appends the relocated function to `B`'s
  source file on disk (computed from `B`'s module name via the standard
  layout convention). `transform/2` then rewrites the host file (clauses
  → delegate) and every caller file (`A.name` → `B.name`). Pass
  `dry_run: true` to build a full plan without touching the filesystem.

  `write_root` defaults to `File.cwd!/0`; tests pass a per-test tmp dir.

  ## Configuring `min_envy_refs`

  How many references to a single other module `B` a body must make
  before it counts as feature envy. Defaults to `2`; raise it to demand
  stronger envy (fewer, more confident moves) or lower it to `1` to catch
  thin forwarders. A non-positive or non-integer value is ignored and the
  default applies.

      configured_modules: [
        {Number42.Refactors.Ex.RelocateMisplacedFunction,
         enabled: true, min_envy_refs: 3}
      ]

  ## Default-OFF (opt-in only)

  Disabled by default — both `prepare/1` and `transform/2` are no-ops
  unless its own opts carry `enabled: true`. A dogfood run against
  position-db surfaced two unsafe move classes the envy metric does not
  catch:

    * **Multi-clause functions with literal/pattern heads** — e.g.
      `handle_event("reseed", …)` / `handle_event("clear_all_data", …)`
      collapse into a single `defdelegate handle_event(arg, …)`, erasing
      the per-event clause routing.
    * **Framework callbacks** (`handle_event`, `mount`, `render`,
      `handle_info`, …) relocated into a plain context module that lacks
      the `use …, :live_view` providing `put_flash/3`, `push_navigate/2`,
      the `~p` sigil, etc. — the target no longer compiles.

  Enable per project once the metric also skips multi-clause/pattern
  heads and framework callbacks:

      configured_modules: [
        {Number42.Refactors.Ex.RelocateMisplacedFunction, enabled: true}
      ]
  """

  use Number42.Refactors.Refactor

  @excluded_path_prefixes ["test/", "dev/"]

  # Minimum number of references to a single other module before the
  # body counts as "envious". One reference is mere delegation
  # (`def f(x), do: B.g(x)`), not Feature Envy — and treating it as a
  # move would break idempotence (the delegate we leave behind is itself
  # a one-ref forwarder). The default requires at least two references so
  # only bodies that genuinely *work with* B's data qualify; teams can
  # tune it via `min_envy_refs:` in opts.
  @default_min_envy_refs 2

  @type relocation :: %{
          aliases: %{atom() => module()},
          arity: arity(),
          clauses: [term()],
          delegate_args: [atom()],
          host: module(),
          name: atom(),
          target: module()
        }

  @typedoc """
  Per-module rewrite plan. A host module maps to `{:delegate, [reloc]}`;
  a caller module maps to `{:rewrite_calls, [reloc]}`. A module that is
  both keeps both actions.
  """
  @type plan :: %{module() => [{:delegate | :rewrite_calls, [relocation()]}]}

  @doc """
  Build the corpus-wide relocation plan from `[{path, source}]` tuples.

  Side effect: appends each relocated function to its target module's
  source file under `opts[:write_root]` (defaults to `File.cwd!/0`).
  Pass `dry_run: true` to skip every disk write.
  """
  @spec build_plan([{String.t(), String.t()}], keyword()) :: plan()
  def build_plan(sources, opts \\ []) do
    write_root = Keyword.get(opts, :write_root, File.cwd!())
    dry_run? = Keyword.get(opts, :dry_run, false)
    min_envy_refs = min_envy_refs(opts)

    relevant = sources |> Enum.reject(fn {path, _src} -> excluded_path?(path) end)
    do_build_plan(relevant, sources, write_root, dry_run?, min_envy_refs)
  end

  # `min_envy_refs` must be a positive integer; anything else (zero,
  # negative, non-integer) is a misconfiguration that would silently
  # change which functions move, so fall back to the conservative
  # default rather than honour a nonsensical threshold.
  defp min_envy_refs(opts) do
    case Keyword.get(opts, :min_envy_refs, @default_min_envy_refs) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_min_envy_refs
    end
  end

  @impl Number42.Refactors.Refactor
  def description, do: "Cross-file: relocate a feature-envy function into its target module"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A `def` whose body almost exclusively touches another module B
    (Feature Envy) is moved into B and every call site is rewritten to
    `B.name(...)`. The host keeps a `defdelegate name(args), to: B` so
    external callers and dynamic resolution still work. Conservative:
    skips on any host-internal reference (private member, `@attr`,
    `__MODULE__`), name clash in B, dependency cycle, or dynamic
    `apply`.
    """
  end

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    if Keyword.get(opts, :enabled, false) do
      Keyword.get(opts, :source_files) |> prepared_for_paths(opts)
    else
      :no_cache
    end
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  # Suggested priority 100; run late and low given the risk so simpler
  # rewrites settle first and the corpus is stable before a move.
  @impl Number42.Refactors.Refactor
  def priority, do: 40

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      Keyword.get(opts, :prepared) |> rewrite_with_plan_or_passthrough(source)
    else
      source
    end
  end

  # ── Plan construction ────────────────────────────────────────────

  defp do_build_plan(relevant, all_sources, write_root, dry_run?, min_envy_refs) do
    modules = collect_modules(relevant)
    paths = source_paths(all_sources)

    relocations =
      relevant
      |> Enum.flat_map(&candidate_relocations(&1, modules, min_envy_refs))
      |> Enum.filter(&safe_relocation?(&1, modules, all_sources))

    unless dry_run? do
      relocations
      |> Enum.group_by(& &1.target)
      |> Enum.each(fn {target, relocs} ->
        append_to_target(target, relocs, write_root, paths)
      end)
    end

    build_module_plan(relocations)
  end

  # Per-module index of everything we need to reason about a module:
  # its public/private defs, attribute names, the AST of its body, and
  # whether it references another module.
  defp collect_modules(sources) do
    sources
    |> Enum.flat_map(fn {_path, source} ->
      case Sourceror.parse_string(source) do
        {:ok, ast} -> modules_in_ast(ast)
        {:error, _} -> []
      end
    end)
    |> Map.new(fn info -> {info.module, info} end)
  end

  defp modules_in_ast(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, mod} -> [module_info(mod, body_to_exprs(body))]
          :error -> []
        end

      _ ->
        []
    end)
  end

  defp module_info(module, body_exprs) do
    %{
      aliases: collect_aliases(body_exprs),
      attr_names: attr_names(body_exprs),
      body_exprs: body_exprs,
      function_keys: function_keys(body_exprs),
      module: module
    }
  end

  # ── Candidate detection (the envy metric) ────────────────────────

  defp candidate_relocations({_path, source}, modules, min_envy_refs) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.flat_map(&relocations_in_node(&1, modules, min_envy_refs))

      {:error, _} ->
        []
    end
  end

  defp relocations_in_node({:defmodule, _, [name_ast, [{_do, body}]]}, modules, min_envy_refs) do
    case alias_to_module(name_ast) do
      {:ok, host} -> relocations_in_module(host, body_to_exprs(body), modules, min_envy_refs)
      :error -> []
    end
  end

  defp relocations_in_node(_, _modules, _min_envy_refs), do: []

  defp relocations_in_module(host, body_exprs, modules, min_envy_refs) do
    host_info = Map.get(modules, host)
    sibling_keys = function_keys(body_exprs)

    body_exprs
    |> collect_definitions()
    |> Enum.filter(&(&1.kind == :def))
    |> Enum.flat_map(&relocation_for_def(&1, host, host_info, sibling_keys, min_envy_refs))
  end

  defp relocation_for_def(def_info, host, host_info, sibling_keys, min_envy_refs) do
    aliases = host_info.aliases
    host_attrs = host_info.attr_names

    with :ok <- references_only_other_modules(def_info, sibling_keys),
         :ok <- no_host_internals(def_info, host_attrs),
         {:ok, target} <- envied_target(def_info, aliases, host, min_envy_refs),
         {:ok, delegate_args} <- plain_delegate_args(def_info) do
      [
        %{
          aliases: aliases,
          arity: def_info.arity,
          clauses: def_info.clauses,
          delegate_args: delegate_args,
          host: host,
          name: def_info.name,
          target: target
        }
      ]
    else
      _ -> []
    end
  end

  # No local call into a sibling def/defp of the host.
  defp references_only_other_modules(def_info, sibling_keys) do
    calls = def_info.calls

    if dynamic_dispatch?(calls) or Enum.any?(calls, &MapSet.member?(sibling_keys, &1)) do
      :skip
    else
      :ok
    end
  end

  # No @attr of the host, no __MODULE__.
  defp no_host_internals(def_info, host_attrs) do
    bodies = clause_bodies(def_info.clauses)

    cond do
      Enum.any?(bodies, &references_host_attr?(&1, host_attrs)) -> :skip
      Enum.any?(bodies, &references_module_self?/1) -> :skip
      true -> :ok
    end
  end

  # The single envied module, resolved through the host's aliases.
  # Returns `:skip` for too-little envy, ambiguous (two equally-envied
  # modules), or a target that is the host itself.
  defp envied_target(def_info, aliases, host, min_envy_refs) do
    counts =
      def_info.clauses
      |> Enum.flat_map(&module_refs_in_clause(&1, aliases))
      |> Enum.reject(&(&1 == host))
      |> Enum.frequencies()

    case counts |> Enum.sort_by(fn {_mod, n} -> -n end) do
      [{target, n} | _] = sorted -> target_or_skip(target, n, sorted, min_envy_refs)
      [] -> :skip
    end
  end

  defp target_or_skip(target, n, sorted, min_envy_refs) do
    if n >= min_envy_refs and not ambiguous?(sorted, n), do: {:ok, target}, else: :skip
  end

  # Two modules envied an equal, maximal amount → cannot pick one.
  defp ambiguous?(counts, max), do: counts |> Enum.count(fn {_mod, n} -> n == max end) > 1

  # Args of the delegate signature. Reuse a readable name per argument:
  # a plain variable keeps its name, a `pattern = var` binding uses the
  # bound var, anything else falls back to a synthetic `name_i`. The
  # delegate head only needs distinct plain vars to compile.
  defp plain_delegate_args(%{arity: 0}), do: {:ok, []}

  defp plain_delegate_args(%{arity: arity, clauses: clauses, name: name}) do
    args =
      head_args(hd(clauses))
      |> Enum.with_index()
      |> Enum.map(fn {arg, i} -> delegate_arg_name(arg, name, i) end)

    if valid_arg_names?(args, arity),
      do: {:ok, args},
      else: {:ok, synthetic_args(name, arity)}
  end

  # The derived names form a valid `defdelegate` head only when there is
  # one per argument and they are all distinct — `def f(x, x)` is a
  # compile error. Otherwise we fall back to fully synthetic names.
  defp valid_arg_names?(args, arity),
    do: length(args) == arity and length(Enum.uniq(args)) == arity

  defp head_args({_kind, _, [head | _]}) do
    case strip_when(head) do
      {_name, _, args} when is_list(args) -> args
      _ -> []
    end
  end

  defp delegate_arg_name({var, _, ctx}, _name, _i) when is_atom(var) and is_atom(ctx),
    do: clean_var(var)

  defp delegate_arg_name({:=, _, [{var, _, ctx}, _]}, _name, _i)
       when is_atom(var) and is_atom(ctx),
       do: clean_var(var)

  defp delegate_arg_name({:=, _, [_, {var, _, ctx}]}, _name, _i)
       when is_atom(var) and is_atom(ctx),
       do: clean_var(var)

  defp delegate_arg_name(_arg, name, i), do: :"#{name_stub(name)}_#{i}"

  # Strip a leading underscore so the delegate head reads naturally; an
  # `_`-prefixed name in a delegate would be a warning.
  defp clean_var(var) do
    case Atom.to_string(var) do
      "_" <> rest when rest != "" -> String.to_atom(rest)
      _ -> var
    end
  end

  defp synthetic_args(name, arity),
    do: 0..(arity - 1)//1 |> Enum.map(fn i -> :"#{name_stub(name)}_#{i}" end)

  defp name_stub(name), do: name |> Atom.to_string() |> String.replace(~r/[?!]/, "")

  # ── Safety / graph preconditions ─────────────────────────────────

  defp safe_relocation?(reloc, modules, all_sources) do
    with {:ok, target_info} <- fetch_target(modules, reloc.target),
         :ok <- no_name_clash(reloc, target_info),
         :ok <- no_cycle(reloc, target_info),
         :ok <- no_dynamic_call_site(reloc, all_sources) do
      true
    else
      _ -> false
    end
  end

  defp fetch_target(modules, target), do: Map.fetch(modules, target)

  defp no_name_clash(%{arity: arity, name: name}, target_info) do
    if MapSet.member?(target_info.function_keys, {name, arity}), do: :skip, else: :ok
  end

  # Closing a cycle: if the target already references the host (anywhere
  # in its body), moving the function into the target — while the host
  # keeps a delegate back to the target — risks A → B → A. Skip.
  defp no_cycle(%{host: host}, target_info) do
    if module_referenced_in?(target_info.body_exprs, host, target_info.aliases),
      do: :skip,
      else: :ok
  end

  # Any caller doing `apply(Host, :name, …)` (literal or dynamic) makes
  # the rename unsafe — bail on the whole relocation.
  defp no_dynamic_call_site(%{host: host, name: name, arity: arity}, all_sources) do
    if Enum.any?(all_sources, fn {_path, src} ->
         apply_targets_host?(src, host, name, arity)
       end),
       do: :skip,
       else: :ok
  end

  defp apply_targets_host?(source, host, name, arity) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        ast |> Macro.prewalker() |> Enum.any?(&apply_node_targets?(&1, host, name, arity))

      {:error, _} ->
        false
    end
  end

  defp apply_node_targets?({:apply, _, [mod_ast, fn_ast, args_ast]}, host, name, arity),
    do: apply_args_match?(mod_ast, fn_ast, args_ast, host, name, arity)

  defp apply_node_targets?(
         {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [mod_ast, fn_ast, args_ast]},
         host,
         name,
         arity
       ),
       do: apply_args_match?(mod_ast, fn_ast, args_ast, host, name, arity)

  defp apply_node_targets?(_, _host, _name, _arity), do: false

  defp apply_args_match?(mod_ast, fn_ast, args_ast, host, name, arity) do
    case alias_to_module(mod_ast) do
      {:ok, ^host} -> apply_fn_matches?(fn_ast, args_ast, name, arity)
      _ -> false
    end
  end

  # Literal `:name` with a literal arg list of the right length is the
  # one concrete match; any non-literal name on the host is conservative
  # dynamic dispatch and also blocks.
  defp apply_fn_matches?(fn_ast, args_ast, name, arity) do
    case literal_fn_atom(fn_ast) do
      {:ok, ^name} -> literal_args_arity(args_ast) in [arity, :unknown]
      {:ok, _other} -> false
      :error -> true
    end
  end

  defp literal_fn_atom({:__block__, _, [atom]}) when is_atom(atom), do: {:ok, atom}
  defp literal_fn_atom(atom) when is_atom(atom), do: {:ok, atom}
  defp literal_fn_atom(_), do: :error

  defp literal_args_arity({:__block__, _, [list]}) when is_list(list), do: length(list)
  defp literal_args_arity(list) when is_list(list), do: length(list)
  defp literal_args_arity(_), do: :unknown

  # ── Module-reference analysis ────────────────────────────────────

  # Modules referenced in a single clause body: `B.fun(...)` remote
  # calls and `%B{}` structs, resolved through `aliases`.
  defp module_refs_in_clause(clause, aliases) do
    clause
    |> clause_body_asts()
    |> Enum.flat_map(&module_refs_in_ast(&1, aliases))
  end

  defp module_refs_in_ast(ast, aliases) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {{:., _, [mod_ast, fun]}, _, args} when is_atom(fun) and is_list(args) ->
        resolve_alias(mod_ast, aliases)

      {:%, _, [mod_ast, _]} ->
        resolve_alias(mod_ast, aliases)

      _ ->
        []
    end)
  end

  defp resolve_alias({:__aliases__, _, parts} = node, aliases) when is_list(parts) do
    case node do
      {:__aliases__, _, [single]} when is_atom(single) ->
        [Map.get(aliases, single, Module.concat(parts))]

      _ ->
        [Module.concat(parts)]
    end
  rescue
    _ -> []
  end

  defp resolve_alias(_, _aliases), do: []

  # Whether `module` is referenced anywhere in `body_exprs` (remote
  # call, struct, or bare alias), resolved through `aliases`.
  defp module_referenced_in?(body_exprs, module, aliases) do
    body_exprs
    |> Enum.flat_map(&module_refs_in_ast(&1, aliases))
    |> Enum.member?(module)
  end

  defp references_host_attr?(ast, host_attrs) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:@, _, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) ->
        MapSet.member?(host_attrs, name)

      _ ->
        false
    end)
  end

  defp references_module_self?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(&match?({:__MODULE__, _, ctx} when is_atom(ctx), &1))
  end

  # ── Plan assembly ────────────────────────────────────────────────

  defp build_module_plan(relocations) do
    host_actions =
      relocations
      |> Enum.group_by(& &1.host)
      |> Map.new(fn {host, relocs} -> {host, [{:delegate, relocs}]} end)

    relocations
    |> Enum.reduce(host_actions, fn reloc, acc ->
      add_caller_actions(acc, reloc)
    end)
  end

  # Every module (other than the host itself, which delegates) may carry
  # call-site rewrites for this relocation.
  defp add_caller_actions(plan, reloc) do
    Map.update(plan, :__callers__, [{:rewrite_calls, [reloc]}], fn existing ->
      merge_rewrite_calls(existing, reloc)
    end)
  end

  defp merge_rewrite_calls(existing, reloc) do
    case List.keyfind(existing, :rewrite_calls, 0) do
      {:rewrite_calls, relocs} ->
        List.keyreplace(existing, :rewrite_calls, 0, {:rewrite_calls, [reloc | relocs]})

      nil ->
        [{:rewrite_calls, [reloc]} | existing]
    end
  end

  # ── transform/2: apply the plan to one source string ─────────────

  defp rewrite_with_plan_or_passthrough(nil, source), do: source
  defp rewrite_with_plan_or_passthrough(plan, source), do: apply_plan(plan, source)

  defp apply_plan(plan, source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> ast |> patches_for_source(plan) |> patch_or_passthrough(source)
      {:error, _} -> source
    end
  end

  defp patches_for_source(ast, plan) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        patches_for_defmodule(name_ast, body_to_exprs(body), plan)

      _ ->
        []
    end)
  end

  defp patches_for_defmodule(name_ast, body_exprs, plan) do
    case alias_to_module(name_ast) do
      {:ok, mod} ->
        delegate = delegate_patches(Map.get(plan, mod), body_exprs)
        call_rewrites = call_site_patches(Map.get(plan, :__callers__), mod, body_exprs)
        delegate ++ call_rewrites

      :error ->
        []
    end
  end

  # Host side: replace the relocated function's clauses with a delegate.
  defp delegate_patches(nil, _body_exprs), do: []

  defp delegate_patches(actions, body_exprs) do
    case List.keyfind(actions, :delegate, 0) do
      {:delegate, relocs} -> relocs |> Enum.flat_map(&delegate_patch(&1, body_exprs))
      nil -> []
    end
  end

  defp delegate_patch(reloc, body_exprs) do
    clauses = body_exprs |> Enum.filter(&clause_matches?(&1, reloc.name, reloc.arity))

    case clauses do
      [] -> []
      [first | _] -> build_group_patch(first, List.last(clauses), render_delegate(reloc))
    end
  end

  # Caller side: rewrite `Host.name(...)` (and `host_alias.name(...)`)
  # into `Target.name(...)`, across direct, pipe, and capture call
  # shapes. The current module is never its own caller
  # for the delegate it owns, but it may call its own delegate — that
  # delegate already points at the target, so a rewrite there is a
  # harmless no-op we skip by excluding the host module.
  defp call_site_patches(nil, _mod, _body_exprs), do: []

  defp call_site_patches(actions, mod, body_exprs) do
    case List.keyfind(actions, :rewrite_calls, 0) do
      {:rewrite_calls, relocs} ->
        aliases = collect_aliases(body_exprs)

        relocs
        |> Enum.reject(&(&1.host == mod))
        |> Enum.flat_map(&call_patches_for_reloc(&1, body_exprs, aliases))

      nil ->
        []
    end
  end

  defp call_patches_for_reloc(reloc, body_exprs, aliases) do
    body_exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(&call_node_patch(&1, reloc, aliases))
  end

  # Pipe form `lhs |> Host.name(args)`: the left operand becomes the
  # implicit first argument, so the effective arity is one more than the
  # explicit `args`. Rewrite only the module of the right-hand call.
  defp call_node_patch(
         {:|>, _, [_lhs, {{:., _, [mod_ast, fun]}, _, args}]},
         reloc,
         aliases
       )
       when is_atom(fun) and is_list(args) do
    qualify_if_host(mod_ast, fun, length(args) + 1, reloc, aliases)
  end

  # Capture-with-arity form `&Host.name/arity`: the inner `Host.name`
  # carries empty `no_parens` args; the real arity is the `/` operand.
  defp call_node_patch(
         {:&, _, [{:/, _, [{{:., _, [mod_ast, fun]}, _, []}, arity_ast]}]},
         reloc,
         aliases
       )
       when is_atom(fun) do
    case literal_arity(arity_ast) do
      {:ok, arity} -> qualify_if_host(mod_ast, fun, arity, reloc, aliases)
      :error -> []
    end
  end

  # Direct form `Host.name(args)` (also the inner call of a capture body
  # `&Host.name(&1)`, which has matching arity). A `no_parens` zero-arg
  # node is the inner reference of a `&Host.name/arity` capture — handled
  # by the capture-with-arity clause above, so skip it here.
  defp call_node_patch({{:., _, [mod_ast, fun]}, meta, args}, reloc, aliases)
       when is_atom(fun) and is_list(args) do
    if Keyword.get(meta, :no_parens, false) and args == [] do
      []
    else
      qualify_if_host(mod_ast, fun, length(args), reloc, aliases)
    end
  end

  defp call_node_patch(_node, _reloc, _aliases), do: []

  defp qualify_if_host(mod_ast, fun, arity, reloc, aliases) do
    if fun == reloc.name and arity == reloc.arity and
         resolved_module(mod_ast, aliases) == reloc.host do
      replace_call_target(mod_ast, reloc.target)
    else
      []
    end
  end

  defp literal_arity({:__block__, _, [n]}) when is_integer(n), do: {:ok, n}
  defp literal_arity(n) when is_integer(n), do: {:ok, n}
  defp literal_arity(_), do: :error

  defp resolved_module(mod_ast, aliases) do
    case resolve_alias(mod_ast, aliases) do
      [mod] -> mod
      _ -> nil
    end
  end

  # Replace only the module part of the qualified call, leaving the
  # function name and arguments untouched.
  defp replace_call_target(mod_ast, target) do
    case Sourceror.get_range(mod_ast) do
      %{end: end_pos, start: start_pos} ->
        [%{change: inspect(target), range: %{end: end_pos, start: start_pos}}]

      _ ->
        []
    end
  end

  # ── Disk side-effect: append relocated functions to target file ──

  defp append_to_target(target, relocs, write_root, source_paths) do
    path = shared_module_path(target, write_root, source_paths)

    with true <- File.exists?(path),
         {:ok, source} <- File.read(path),
         {:ok, ast} <- Sourceror.parse_string(source),
         {:ok, body} <- find_module_body(ast, target),
         new_relocs when new_relocs != [] <- not_yet_present(relocs, body) do
      rendered = render_relocations(new_relocs)
      File.write!(path, splice_before_module_end(source, rendered))
    else
      _ -> :ok
    end
  end

  # Drop relocations already present in the target (idempotence: a
  # second run must not append the function again).
  defp not_yet_present(relocs, target_body) do
    existing = function_keys(target_body)
    relocs |> Enum.reject(&MapSet.member?(existing, {&1.name, &1.arity}))
  end

  defp render_relocations(relocs) do
    relocs
    |> Enum.uniq_by(&{&1.name, &1.arity})
    |> Enum.map_join("\n\n", fn reloc ->
      reloc.clauses
      |> Enum.map(&qualify_aliases(&1, reloc.aliases))
      |> Enum.map_join("\n\n", &Sourceror.to_string/1)
    end)
  end

  # Every short alias the host used (`B`, `Repo`, …) is fully qualified
  # before the body is written into the target module. The target has
  # none of the host's `alias` lines, so a bare `B.name(brand)` or
  # `%B{}` would resolve to a top-level `B` and fail to compile. After
  # qualification they read `MyApp.B.name(brand)` / `%MyApp.B{}`, which
  # resolves regardless of the target's own aliases.
  defp qualify_aliases(ast, aliases) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, [single]} = node when is_atom(single) ->
        case Map.get(aliases, single) do
          nil -> node
          full -> {:__aliases__, meta, module_parts(full)}
        end

      other ->
        other
    end)
  end

  defp module_parts(module),
    do: module |> Module.split() |> Enum.map(&String.to_atom/1)

  defp render_delegate(%{delegate_args: args, name: name, target: target}) do
    "defdelegate #{name}(#{Enum.join(args, ", ")}), to: #{inspect(target)}"
  end

  # ── Generic AST helpers (local) ──────────────────────────────────

  defp clause_matches?({:def, _, [head | _]}, name, arity) do
    case strip_when(head) do
      {^name, _, args} when is_list(args) and length(args) == arity -> true
      {^name, _, nil} when arity == 0 -> true
      _ -> false
    end
  end

  defp clause_matches?(_, _, _), do: false

  defp clause_bodies(clauses), do: clauses |> Enum.flat_map(&clause_body_asts/1)

  defp clause_body_asts({kind, _, [_head, body_kw]})
       when kind in [:def, :defp] and is_list(body_kw),
       do: Keyword.values(body_kw)

  defp clause_body_asts(_), do: []

  defp function_keys(body_exprs) do
    body_exprs
    |> Enum.filter(fn
      {kind, _, [_head | _]} when kind in [:def, :defp] -> true
      _ -> false
    end)
    |> Enum.map(&def_name_arity/1)
    |> Enum.reject(&(&1 == :skip))
    |> MapSet.new()
  end

  defp def_name_arity({_kind, _, [head | _]}) do
    case strip_when(head) do
      {name, _, args} when is_atom(name) and is_list(args) -> {name, length(args)}
      {name, _, nil} when is_atom(name) -> {name, 0}
      _ -> :skip
    end
  end

  defp attr_names(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {:@, _, [{name, _, [_value]}]} when is_atom(name) -> [name]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp collect_aliases(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {:alias, _, [{:__aliases__, _, parts}]} ->
        [{List.last(parts), Module.concat(parts)}]

      {:alias, _, [{:__aliases__, _, parts}, opts]} ->
        short = alias_as(opts) || List.last(parts)
        [{short, Module.concat(parts)}]

      {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, subs}]} ->
        subs
        |> Enum.map(fn {:__aliases__, _, sub} ->
          {List.last(sub), Module.concat(base ++ sub)}
        end)

      _ ->
        []
    end)
    |> Map.new()
  end

  defp alias_as(opts) do
    case unwrap_keyword(opts) |> Keyword.get(:as) do
      {:__aliases__, _, [name]} -> name
      _ -> nil
    end
  end

  # Sourceror wraps keyword keys (and atom/literal values) as
  # `{:__block__, _, [atom]}`, so `alias MyApp.A, as: Host` carries an
  # `:as` key that `Keyword.get/2` never matches against the bare atom.
  # Unwrap both sides into a plain keyword list before lookup.
  defp unwrap_keyword([{_, _} | _] = kw),
    do: Enum.map(kw, fn {k, v} -> {unwrap_block(k), unwrap_block(v)} end)

  defp unwrap_keyword(_), do: []

  defp find_module_body(ast, target) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value(:error, fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, ^target} -> {:ok, body_to_exprs(body)}
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp build_group_patch(first_node, last_node, replacement) do
    with %{start: start_pos} <- Sourceror.get_range(first_node),
         %{end: end_pos} <- Sourceror.get_range(last_node) do
      [%{change: replacement, range: %{end: end_pos, start: start_pos}}]
    else
      _ -> []
    end
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp splice_before_module_end(source, addition) do
    lines = String.split(source, "\n")
    {prefix, suffix} = split_at_last_end(lines)
    indented = indent(addition, "  ")
    (prefix ++ ["", indented] ++ suffix) |> Enum.join("\n")
  end

  defp split_at_last_end(lines) do
    idx =
      lines
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {line, i} -> if String.trim(line) == "end", do: i end)

    case idx do
      nil -> {lines, []}
      i -> {Enum.take(lines, i), Enum.drop(lines, i)}
    end
  end

  defp indent(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp excluded_path?(path) do
    normalized = String.trim_leading(path, "./")
    @excluded_path_prefixes |> Enum.any?(&String.starts_with?(normalized, &1))
  end

  defp source_paths(sources), do: sources |> Enum.map(fn {path, _src} -> path end)

  # ── prepare/1 wiring ─────────────────────────────────────────────

  defp prepared_for_paths(nil, opts), do: load_default_sources() |> plan_from_sources(opts)

  defp prepared_for_paths(paths, opts) when is_list(paths) do
    sources = paths |> Enum.map(fn p -> {p, File.read!(p)} end)
    {:ok, build_plan(sources, opts)}
  end

  defp plan_from_sources([], _opts), do: :no_cache
  defp plan_from_sources(sources, opts), do: {:ok, build_plan(sources, opts)}

  defp load_default_sources, do: File.read(".refactor.exs") |> parse_inputs_from_config()

  defp parse_inputs_from_config({:ok, contents}) do
    {config, _} = Code.eval_string(contents)

    config
    |> Map.get(:inputs, [])
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&excluded_path?/1)
    |> Enum.map(fn p -> {p, File.read!(p)} end)
  end

  defp parse_inputs_from_config(_), do: []
end
