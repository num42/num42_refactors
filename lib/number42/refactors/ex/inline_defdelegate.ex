defmodule Number42.Refactors.Ex.InlineDefdelegate do
  @moduledoc """
  The inverse of the move-method delegations: rewrite every in-corpus
  call site of a `defdelegate`'d function to call the delegated **target**
  directly, then drop the `defdelegate` when it is effectively private and
  has zero remaining corpus callers.

      # definition — MyApp.Deep.Internal.Facade
      defdelegate parse(input), to: MyApp.Deep.Parser

      # call site anywhere in the corpus
      MyApp.Deep.Internal.Facade.parse(data)
        -> Parser.parse(data)              # caller aliases MyApp.Deep.Parser
        -> MyApp.Deep.Parser.parse(data)   # caller has no alias

  This collapses thin pass-through delegations once a module is no longer
  meant to be the indirection point — the calls go straight to the real
  implementation. The default posture is: inline calls aggressively,
  remove definitions cautiously.

  ## Supported `defdelegate` forms

    * **1:1 delegation** — `defdelegate foo(a, b), to: Mod`. Call
      `Facade.foo(x, y)` becomes `Mod.foo(x, y)`.
    * **`as:` rename** — `defdelegate foo(a), to: Mod, as: :bar`. The call
      site uses the **target** name `bar`: `Mod.bar(x)`.

  ## Module reference at the rewritten call site

  Resolved exactly like the alias-as logic in `RelocateMisplacedFunction`:

    * If the **calling module** already `alias`es the target module → use
      the short alias form (`Parser.parse(x)`).
    * Otherwise → fully qualify (`MyApp.Deep.Parser.parse(x)`).
    * **Never inject a new alias.** Never change existing aliases.

  Only **qualified** references that resolve to the facade module are
  rewritten (`Facade.parse(x)`, `MyApp.Facade.parse(x)`, the pipe form
  `x |> Facade.parse()`). A bare unqualified `parse(x)` is left untouched:
  it resolves to a local function or an import, not to the facade — that
  is the name-clash skip, implicit in only touching qualified calls.

  ## Removal of the `defdelegate`

  A `defdelegate` always generates a public `def`, so it may have callers
  outside the corpus (other apps, tests, `apply/3`). We remove it **only
  when both** hold:

    1. The delegating module is **not a public API boundary**. A
       context/facade module's public delegations are never auto-removed.
       Conservative heuristic: a module is treated as a boundary unless it
       is nested at least four segments deep — shallow modules
       (`MyApp.Accounts`) are boundaries and kept; deep implementation
       modules (`MyApp.Deep.Internal.Helper`) are eligible.
    2. **Zero remaining callers in the corpus** after the rewrite.

  When in doubt, keep the delegate.

  ## Skips (the whole delegate is left untouched)

    * Multi-form keyword-list `defdelegate foo: 1, bar: 2`.
    * Append/prepend/default args or any arity-changing head, guards on
      the head — only plain single-clause heads are inlined.
    * Target module absent from the corpus (dynamic `to:`, external lib) —
      we cannot verify the target function exists.
    * The delegated name is dynamically dispatched anywhere in the corpus:
      an `apply(Facade, :name, …)` or a `&Facade.name/arity` capture (or a
      bare `&name/arity` capture inside the facade itself) → skip rewrite
      **and** removal, since not all call sites are static.

  ## Cross-file context (`prepare/1`)

  The delegate definition and its callers live in different files, so we
  read every input source, build a corpus-wide plan (which delegates
  exist, their targets, their call sites), and `transform/2` applies the
  per-file slice. Tests build the plan inline via
  `build_plan(sources, enabled: true)` and pass it as `opts[:prepared]`.

  ## Default-OFF

  Behind the in-module `enabled: true` gate (consistent with the
  aggressive cross-file refactors) since it both rewrites call sites
  across files and deletes definitions. Both `prepare/1` and
  `transform/2` are no-ops without it.
  """

  use Number42.Refactors.Refactor

  @excluded_path_prefixes ["test/", "dev/"]

  # A module nested at least this many segments deep is treated as an
  # implementation module whose delegates may be removed. Shallower
  # modules are conservatively treated as public API boundaries
  # (contexts, facades) and never auto-removed.
  @private_module_depth 4

  @type delegate :: %{
          facade: module(),
          name: atom(),
          arity: arity(),
          target: module(),
          target_name: atom()
        }

  @typedoc """
  Per-module rewrite plan. The `:__callers__` bucket carries the
  delegate descriptors whose qualified call sites get rewritten in any
  module. A facade module key carries the `{name, arity}` delegates to
  delete from that module.
  """
  @type plan :: %{
          optional(:__callers__) => [delegate()],
          optional(module()) => [{atom(), arity()}]
        }

  @doc """
  Build the corpus-wide plan from `[{path, source}]` tuples.

  Returns `%{}` (no-op) unless `opts[:enabled]` is true. Exposed publicly
  so tests can construct a plan inline; the engine calls it via
  `prepare/1`.
  """
  @spec build_plan([{String.t(), String.t()}], keyword()) :: plan()
  def build_plan(sources, opts \\ []) do
    if Keyword.get(opts, :enabled, false) do
      do_build_plan(sources)
    else
      %{}
    end
  end

  @impl Number42.Refactors.Refactor
  def description, do: "Cross-file: inline defdelegate call sites and drop the unused delegate"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Rewrites every in-corpus call site of a `defdelegate`'d function to
    call the delegated target directly (alias-aware), then removes the
    `defdelegate` when its module is not a public boundary and no corpus
    caller remains. Conservative: skips on an unresolvable target, a
    dynamic dispatch (`apply/3` or `&name/arity` capture) of the delegate,
    or any non-1:1 form; keeps the delegate when the module is a context
    or facade.
    """
  end

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    if Keyword.get(opts, :enabled, false) do
      Keyword.get(opts, :source_files) |> prepared_for_paths()
    else
      :no_cache
    end
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  # Low priority: inline late, after simpler body rewrites settle.
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

  defp do_build_plan(sources) do
    relevant = sources |> Enum.reject(fn {path, _src} -> excluded_path?(path) end)
    modules = collect_modules(relevant)
    self_calls = self_call_index(relevant)

    delegates =
      relevant
      |> Enum.flat_map(&delegates_in_source/1)
      |> Enum.filter(&target_resolvable?(&1, modules))
      |> Enum.reject(&dynamically_dispatched?(&1, relevant))

    build_module_plan(delegates, self_calls)
  end

  # `%{module => MapSet of {name, arity}}` of every bare local call each
  # module makes in its own body. A bare `parse(x)` inside the facade
  # resolves to the delegate locally; our call-site rewrite only touches
  # qualified references, so such a self-call would survive the rewrite
  # and break if we removed the delegate. Block removal when present.
  defp self_call_index(sources) do
    sources
    |> Enum.flat_map(&module_self_calls/1)
    |> Map.new()
  end

  defp module_self_calls({_path, source}) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> ast |> Macro.prewalker() |> Enum.flat_map(&module_self_calls_node/1)
      {:error, _} -> []
    end
  end

  defp module_self_calls_node({:defmodule, _, [name_ast, [{_do, body}]]}) do
    case alias_to_module(name_ast) do
      {:ok, mod} ->
        calls =
          body
          |> body_to_exprs()
          |> collect_definitions()
          |> Enum.reduce(MapSet.new(), fn d, acc -> MapSet.union(acc, d.calls) end)

        [{mod, calls}]

      :error ->
        []
    end
  end

  defp module_self_calls_node(_), do: []

  # All module names present in the corpus — used to verify the delegate
  # target actually exists somewhere we can see.
  defp collect_modules(sources) do
    sources
    |> Enum.flat_map(fn {_path, source} ->
      case Sourceror.parse_string(source) do
        {:ok, ast} -> module_names_in_ast(ast)
        {:error, _} -> []
      end
    end)
    |> MapSet.new()
  end

  defp module_names_in_ast(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, _body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, mod} -> [mod]
          :error -> []
        end

      _ ->
        []
    end)
  end

  # ── defdelegate detection ────────────────────────────────────────

  defp delegates_in_source({_path, source}) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.flat_map(&delegates_in_node/1)

      {:error, _} ->
        []
    end
  end

  defp delegates_in_node({:defmodule, _, [name_ast, [{_do, body}]]}) do
    case alias_to_module(name_ast) do
      {:ok, facade} ->
        body
        |> body_to_exprs()
        |> Enum.flat_map(fn expr -> delegate_descriptor(expr, facade) end)

      :error ->
        []
    end
  end

  defp delegates_in_node(_), do: []

  # Only the single-clause `defdelegate name(args), to: Mod[, as: :other]`
  # form is supported. The keyword-list multi-form
  # (`defdelegate foo: 1, bar: 2`) and any head with guards/defaults are
  # skipped.
  defp delegate_descriptor({:defdelegate, _, [head, opts]}, facade) when is_list(opts) do
    with {:ok, name, arity, args} <- plain_head(head),
         true <- plain_args?(args),
         {:ok, target} <- delegate_target(opts) do
      [
        %{
          arity: arity,
          facade: facade,
          name: name,
          target: target,
          target_name: delegate_as(opts) || name
        }
      ]
    else
      _ -> []
    end
  end

  defp delegate_descriptor(_expr, _facade), do: []

  # A plain head is `name(arg, ...)` or `name()`. A `when`-guard, a bare
  # atom-head (the multi-form `foo: 1`), or a non-call shape is rejected.
  defp plain_head({:when, _, _}), do: :error

  defp plain_head({name, _, args}) when is_atom(name) and is_list(args),
    do: {:ok, name, length(args), args}

  defp plain_head({name, _, nil}) when is_atom(name), do: {:ok, name, 0, []}
  defp plain_head(_), do: :error

  # Every argument must be a plain variable: no defaults (`\\`), no
  # pattern matches. Anything else risks an arity/semantics change.
  defp plain_args?(args), do: Enum.all?(args, &plain_var?/1)

  defp plain_var?({:\\, _, _}), do: false
  defp plain_var?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp plain_var?(_), do: false

  defp delegate_target(opts) do
    case opts |> unwrap_keyword() |> Keyword.fetch(:to) do
      {:ok, {:__aliases__, _, parts}} -> alias_to_module({:__aliases__, [], parts})
      _ -> :error
    end
  end

  defp delegate_as(opts) do
    case opts |> unwrap_keyword() |> Keyword.get(:as) do
      name when is_atom(name) and not is_nil(name) -> name
      _ -> nil
    end
  end

  # Sourceror wraps keyword keys/values as `{:__block__, _, [literal]}`.
  # Unwrap both sides into a plain keyword list so `Keyword.fetch/2`
  # matches against bare atoms.
  defp unwrap_keyword(opts) when is_list(opts) do
    opts
    |> Enum.flat_map(fn
      {k, v} -> [{unwrap_block(k), unwrap_block(v)}]
      _ -> []
    end)
  end

  defp unwrap_keyword(_), do: []

  # ── Resolvability + safety ───────────────────────────────────────

  defp target_resolvable?(%{target: target}, modules), do: MapSet.member?(modules, target)

  # The delegated `{facade, name, arity}` is dynamically dispatched
  # somewhere — an `apply(Facade, :name, …)` or a `&Facade.name/arity`
  # capture (or a bare `&name/arity` capture inside the facade itself).
  # Such call sites can't be rewritten statically, so skip the whole
  # delegate.
  defp dynamically_dispatched?(delegate, sources) do
    Enum.any?(sources, fn {_path, source} ->
      case Sourceror.parse_string(source) do
        {:ok, ast} -> source_dispatches_dynamically?(ast, delegate)
        {:error, _} -> false
      end
    end)
  end

  defp source_dispatches_dynamically?(ast, delegate) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(&node_dispatches_dynamically?(&1, delegate))
  end

  # `apply(Facade, :name, [a, b])` — literal name, literal arg list of the
  # right length, module resolving to the facade.
  defp node_dispatches_dynamically?({:apply, _, [mod_ast, fn_ast, args_ast]}, delegate),
    do: apply_targets_delegate?(mod_ast, fn_ast, args_ast, delegate)

  defp node_dispatches_dynamically?(
         {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [mod_ast, fn_ast, args_ast]},
         delegate
       ),
       do: apply_targets_delegate?(mod_ast, fn_ast, args_ast, delegate)

  # `&Facade.name/arity` capture.
  defp node_dispatches_dynamically?(
         {:&, _, [{:/, _, [{{:., _, [mod_ast, fun]}, _, []}, arity_ast]}]},
         %{name: name, arity: arity} = delegate
       )
       when is_atom(fun) do
    fun == name and literal_int(arity_ast) == arity and
      resolves_to?(mod_ast, delegate.facade, %{})
  end

  # Bare `&name/arity` capture inside the facade module's own file — the
  # name resolves to the delegate locally.
  defp node_dispatches_dynamically?(
         {:&, _, [{:/, _, [{fun, _, ctx}, arity_ast]}]},
         %{name: name, arity: arity}
       )
       when is_atom(fun) and is_atom(ctx) do
    fun == name and literal_int(arity_ast) == arity
  end

  defp node_dispatches_dynamically?(_node, _delegate), do: false

  defp apply_targets_delegate?(mod_ast, fn_ast, args_ast, delegate) do
    resolves_to?(mod_ast, delegate.facade, %{}) and
      literal_atom(fn_ast) == delegate.name and
      literal_args_arity(args_ast) in [delegate.arity, :unknown]
  end

  # ── Plan assembly ────────────────────────────────────────────────

  defp build_module_plan(delegates, self_calls) do
    callers = %{__callers__: delegates}

    delegates
    |> Enum.filter(&removable?(&1, self_calls))
    |> Enum.reduce(callers, fn delegate, acc ->
      Map.update(acc, delegate.facade, [{delegate.name, delegate.arity}], fn existing ->
        [{delegate.name, delegate.arity} | existing]
      end)
    end)
  end

  # Removable only when the facade is not a public API boundary AND no
  # caller survives the rewrite. Every delegate reaching here is
  # resolvable and not dynamically dispatched, so all in-corpus qualified
  # call sites are rewritten in the same pass — none remain. The two
  # residual-caller cases we still guard:
  #
  #   * a bare local `parse(x)` inside the facade itself, which resolves
  #     to the delegate but is never qualified, so the rewrite misses it;
  #   * out-of-corpus callers (other apps, excluded tests, `apply/3` in
  #     unseen code) — covered conservatively by the boundary heuristic.
  defp removable?(delegate, self_calls) do
    not public_boundary?(delegate.facade) and not facade_self_calls?(delegate, self_calls)
  end

  defp facade_self_calls?(delegate, self_calls) do
    self_calls
    |> Map.get(delegate.facade, MapSet.new())
    |> MapSet.member?({delegate.name, delegate.arity})
  end

  defp public_boundary?(module) do
    length(Module.split(module)) < @private_module_depth
  end

  # ── transform/2: apply the plan to one source string ─────────────

  defp rewrite_with_plan_or_passthrough(nil, source), do: source
  defp rewrite_with_plan_or_passthrough(plan, source) when plan == %{}, do: source

  defp rewrite_with_plan_or_passthrough(plan, source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> ast |> patches_for_source(plan) |> patch_or_passthrough(source)
      {:error, _} -> source
    end
  end

  defp patches_for_source(ast, plan) do
    delegates = Map.get(plan, :__callers__, [])

    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        patches_for_defmodule(name_ast, body_to_exprs(body), plan, delegates)

      _ ->
        []
    end)
  end

  defp patches_for_defmodule(name_ast, body_exprs, plan, delegates) do
    case alias_to_module(name_ast) do
      {:ok, mod} ->
        removal = removal_patches(Map.get(plan, mod), body_exprs)
        rewrites = call_rewrite_patches(delegates, body_exprs)
        removal ++ rewrites

      :error ->
        []
    end
  end

  # Facade side: delete the delegate lines marked for removal.
  defp removal_patches(nil, _body_exprs), do: []

  defp removal_patches(to_remove, body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {:defdelegate, _, [head, opts]} = node when is_list(opts) ->
        case plain_head(head) do
          {:ok, name, arity, _args} ->
            if {name, arity} in to_remove, do: delete_patch(node), else: []

          :error ->
            []
        end

      _ ->
        []
    end)
  end

  defp delete_patch(node) do
    case Sourceror.get_range(node) do
      %{end: end_pos, start: start_pos} ->
        [%{change: "", range: %{end: end_pos, start: start_pos}}]

      _ ->
        []
    end
  end

  # Caller side: rewrite each qualified facade call to the target. The
  # current module's aliases decide short vs fully-qualified target form.
  defp call_rewrite_patches(delegates, body_exprs) do
    aliases = collect_aliases(body_exprs)
    nodes = body_exprs |> Enum.flat_map(&Macro.prewalker/1)

    for delegate <- delegates,
        node <- nodes,
        patch <- rewrite_call_node(node, delegate, aliases) do
      patch
    end
  end

  # Pipe form `lhs |> Facade.name(args)`: effective arity is one more than
  # the explicit args. Replace the `Facade.name` prefix, keep args.
  defp rewrite_call_node(
         {:|>, _, [_lhs, {{:., _, [mod_ast, fun]} = dot, _, args}]},
         delegate,
         aliases
       )
       when is_atom(fun) and is_list(args) do
    if fun == delegate.name and length(args) + 1 == delegate.arity and
         resolves_to?(mod_ast, delegate.facade, aliases) do
      replace_dotted_prefix(dot, delegate, aliases)
    else
      []
    end
  end

  # Direct form `Facade.name(args)`.
  defp rewrite_call_node({{:., _, [mod_ast, fun]} = dot, meta, args}, delegate, aliases)
       when is_atom(fun) and is_list(args) do
    if not Keyword.get(meta, :no_parens, false) and fun == delegate.name and
         length(args) == delegate.arity and resolves_to?(mod_ast, delegate.facade, aliases) do
      replace_dotted_prefix(dot, delegate, aliases)
    else
      []
    end
  end

  defp rewrite_call_node(_node, _delegate, _aliases), do: []

  # Replace the dotted `Facade.name` prefix — the inner `{:., _, [mod,
  # fun]}` node ranges exactly over `Facade.name` (up to and including the
  # function name, before the arg list) — with `Target.target_name`,
  # which also handles the `as:` rename. The argument list is untouched.
  defp replace_dotted_prefix(dot_node, delegate, aliases) do
    case Sourceror.get_range(dot_node) do
      %{end: end_pos, start: start_pos} ->
        target_ref = target_reference(delegate.target, aliases)
        replacement = "#{target_ref}.#{delegate.target_name}"
        [%{change: replacement, range: %{end: end_pos, start: start_pos}}]

      _ ->
        []
    end
  end

  # ── Module reference resolution ──────────────────────────────────

  # Whether `mod_ast` resolves (through `aliases`) to `module`.
  defp resolves_to?({:__aliases__, _, [single]}, module, aliases) when is_atom(single) do
    Map.get(aliases, single, Module.concat([single])) == module
  end

  defp resolves_to?({:__aliases__, _, parts}, module, _aliases) when is_list(parts) do
    Module.concat(parts) == module
  rescue
    _ -> false
  end

  defp resolves_to?({:__MODULE__, _, ctx}, _module, _aliases) when is_atom(ctx), do: false
  defp resolves_to?(_mod_ast, _module, _aliases), do: false

  # Short alias form when the calling module aliases the target; otherwise
  # fully-qualified. Never injects a new alias.
  defp target_reference(target, aliases) do
    case alias_short_name(target, aliases) do
      {:ok, short} -> short
      :error -> module_qualified(target)
    end
  end

  defp alias_short_name(target, aliases) do
    aliases
    |> Enum.find(fn {_short, full} -> full == target end)
    |> case do
      {short, _full} -> {:ok, Atom.to_string(short)}
      nil -> :error
    end
  end

  defp module_qualified(module), do: module |> Module.split() |> Enum.join(".")

  # ── alias collection (#198 alias-as pattern) ─────────────────────

  defp collect_aliases(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {:alias, _, [{:__aliases__, _, parts}]} ->
        [{List.last(parts), Module.concat(parts)}]

      {:alias, _, [{:__aliases__, _, parts}, opts]} ->
        short = alias_as_opt(opts) || List.last(parts)
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

  defp alias_as_opt(opts) do
    case opts |> unwrap_keyword() |> Keyword.get(:as) do
      {:__aliases__, _, [name]} -> name
      name when is_atom(name) and not is_nil(name) -> name
      _ -> nil
    end
  end

  # ── small literal helpers ────────────────────────────────────────

  defp literal_atom({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp literal_atom(atom) when is_atom(atom), do: atom
  defp literal_atom(_), do: nil

  defp literal_int({:__block__, _, [n]}) when is_integer(n), do: n
  defp literal_int(n) when is_integer(n), do: n
  defp literal_int(_), do: nil

  defp literal_args_arity({:__block__, _, [list]}) when is_list(list), do: length(list)
  defp literal_args_arity(list) when is_list(list), do: length(list)
  defp literal_args_arity(_), do: :unknown

  # ── plumbing ─────────────────────────────────────────────────────

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp excluded_path?(path) do
    normalized = String.trim_leading(path, "./")
    @excluded_path_prefixes |> Enum.any?(&String.starts_with?(normalized, &1))
  end

  defp prepared_for_paths(nil), do: load_default_sources() |> plan_from_sources()

  defp prepared_for_paths(paths) when is_list(paths) do
    sources = paths |> Enum.map(fn p -> {p, File.read!(p)} end)
    {:ok, build_plan(sources, enabled: true)}
  end

  defp plan_from_sources([]), do: :no_cache
  defp plan_from_sources(sources), do: {:ok, build_plan(sources, enabled: true)}

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
