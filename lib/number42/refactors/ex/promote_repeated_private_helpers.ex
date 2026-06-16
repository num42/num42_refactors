defmodule Number42.Refactors.Ex.PromoteRepeatedPrivateHelpers do
  @moduledoc """
  Promotes recurring **private helper** clones (`defp`) that appear in two
  or more modules into one shared support module, then rewrites every
  call site to the support module and deletes the now-dead local `defp`.

      # before — two modules with the same private helper
      defmodule MyApp.Items.A do
        def caller(x), do: strip_meta(x)

        defp strip_meta(node) do
          node
          |> Map.delete(:line)
          |> Map.delete(:column)
        end
      end

      defmodule MyApp.Items.B do
        def other(y), do: strip_meta(y)

        defp strip_meta(ast) do
          ast
          |> Map.delete(:line)
          |> Map.delete(:column)
        end
      end

      # after — one support module, both call into it
      defmodule MyApp.Items.A do
        def caller(x), do: MyApp.Items.Support.strip_meta(x)
      end

      defmodule MyApp.Items.B do
        def other(y), do: MyApp.Items.Support.strip_meta(y)
      end

      defmodule MyApp.Items.Support do
        # extracted from: MyApp.Items.A, MyApp.Items.B
        def strip_meta(node) do
          node
          |> Map.delete(:line)
          |> Map.delete(:column)
        end
      end

  ## Why a dedicated refactor (vs. `DelegateExactDuplicates` /
  ## `ExtractSharedModule`)

  Those two target **public** duplicate functions and replace them with
  `defdelegate`/wrappers — the public contract of each module stays
  intact, callers don't move. This refactor targets the *recurring
  private plumbing* that grows across a codebase: AST metadata strippers,
  one-off block walkers, patch helpers, `single_do_body`-style variants.
  These are never part of a module's public contract, so the right move
  is not delegation but **relocation**: lift the implementation into a
  support module, rewrite the (necessarily local) call sites to remote
  calls, and delete the duplicates outright.

  ## Detection

  A `defp` is a clone candidate when it appears — structurally identical
  modulo metadata and variable names — under the same `{name, arity}` in
  at least `:min_modules` (default 2) distinct modules, and its combined
  body has at least `:min_mass` AST nodes (default 20). The structural
  hash strips meta and positionally renames variables, so cosmetic
  differences (`node` vs `ast`) don't split a genuine clone group.

  ## Safety gates (skip rather than guess)

  A clone group is dropped when any contributing helper:

    * **reads a module attribute** (`@foo`) — the attribute is per-module
      compile-time state and would vanish in the support module;
    * references `__MODULE__`/`__ENV__`/`__DIR__`/`__CALLER__` — these
      resolve against the *defining* module and change meaning when moved;
    * **makes any unqualified call other than to itself** — every
      unqualified call in the body must resolve to a clause of the helper
      group being moved (self/co-recursion). Anything else — another
      local `def`/`defp`, *or* a function injected by `use` in the source
      module (e.g. `AstHelpers` brought in via `use …Refactor`) — would be
      undefined in the bare support module, so the relocated body would
      fail to compile. Remote/qualified calls and Kernel special forms are
      fine (they resolve identically anywhere).

  The cross-module match also requires structural identity of the helper
  body itself; an alias used inside the body is only safe when it resolves
  the same way in the support module, so the body is rendered with every
  alias **fully qualified** (same approach as `ExtractSharedModule`),
  which sidesteps alias divergence between source modules entirely.

  ## Target module

  The support module's namespace is the longest common prefix (LCP) of the
  contributing modules' names, suffixed with `.Support` (configurable via
  `:suffix`). LCP must be **≥ 2 segments** — a single common segment would
  produce a project-wide `MyApp.Support` grab-bag, exactly what this
  refactor avoids. Groups whose LCP is shorter are skipped.

  ## Rewrite

    * The helper is written into the support module as a public `def`
      (so the remote call resolves), with every alias fully qualified.
    * In each source module, unqualified calls to the helper
      (`patch(x, 1)`, including pipe form `x |> patch(1)`) are rewritten
      to `Target.patch(x, 1)`.
    * The now-dead local `defp` clauses are deleted.

  ## Side effect: file write

  Like `ExtractSharedModule`, `build_plan/2` writes the support `.ex`
  file to disk (path derived from the module name via the standard
  Elixir layout convention). `:write_root` controls the destination
  (defaults to `File.cwd!/0`); `dry_run: true` produces a full plan but
  skips every disk write (used by `mix refactor --dry-run`). An existing
  support module is appended to, never clobbered, and a name already
  defined there wins (the clone is dropped for that name/arity).

  ## Default-OFF (opt-in only)

  Disabled by default — `transform/2` is a no-op unless its opts carry
  `enabled: true`. Relocating shared private plumbing across module
  boundaries is an aggressive structural move; whether a recurring
  `defp` is *conceptually* one helper or two coincidental look-alikes is
  a judgement call. Opt in per project where the trade is wanted:

      configured_modules: [
        {Number42.Refactors.Ex.PromoteRepeatedPrivateHelpers, enabled: true}
      ]
  """

  use Number42.Refactors.Refactor

  @default_min_mass 20
  @default_min_modules 2
  @default_suffix "Support"

  @excluded_path_prefixes ["test/", "dev/"]

  @reserved_macros [:__MODULE__, :__ENV__, :__CALLER__, :__DIR__, :__STACKTRACE__]

  @doc """
  Build a rewrite plan from `[{path, source_string}]` tuples.

  Side effect: writes one support `.ex` file per target module to
  `opts[:write_root]` (defaults to `File.cwd!/0`). Pass `dry_run: true`
  to skip writes while still returning a fully populated plan.

  Plan shape: `%{source_module => [%{name, arity, target}]}`.
  """
  @spec build_plan([{String.t(), String.t()}], keyword()) :: %{
          module() => [%{name: atom(), arity: arity(), target: module()}]
        }
  def build_plan(sources, opts \\ []) do
    cfg = config(opts)

    sources
    |> Enum.reject(fn {path, _src} -> excluded_path?(path) end)
    |> do_build_plan(cfg)
  end

  @impl Number42.Refactors.Refactor
  def description,
    do: "Cross-file: promote repeated private helpers into a {LCP}.Support module (default-OFF)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    The same private helper (`defp`) in two or more modules → lift the
    implementation into a shared `{LCP}.Support` module as a public
    `def`, rewrite every (local) call site to a remote call, and delete
    the duplicate `defp`s. Targets recurring private plumbing (AST
    strippers, block walkers, patch helpers) that delegation can't help
    with because it's not part of any public contract. Conservative:
    skips helpers that read module attributes, reference `__MODULE__`,
    or call other local functions, and only fires above a body-mass
    threshold across at least two modules. Default-OFF — opt in with
    `enabled: true`.
    """
  end

  @impl Number42.Refactors.Refactor
  def prepare(opts), do: Keyword.get(opts, :source_files) |> prepared_for_paths(opts)

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      Keyword.get(opts, :prepared) |> rewrite_with_plan_or_passthrough(source)
    else
      source
    end
  end

  # --- config -----------------------------------------------------------

  defp config(opts) do
    %{
      min_mass: Keyword.get(opts, :min_mass, @default_min_mass),
      min_modules: Keyword.get(opts, :min_modules, @default_min_modules),
      suffix: Keyword.get(opts, :suffix, @default_suffix),
      write_root: Keyword.get(opts, :write_root, File.cwd!()),
      dry_run?: Keyword.get(opts, :dry_run, false)
    }
  end

  defp excluded_path?(path) do
    normalized = String.trim_leading(path, "./")
    @excluded_path_prefixes |> Enum.any?(&String.starts_with?(normalized, &1))
  end

  # --- planning ---------------------------------------------------------

  defp do_build_plan(sources, cfg) do
    paths = sources |> Enum.map(fn {path, _src} -> path end)

    {loser_entries, support_specs} =
      sources
      |> Enum.flat_map(&extract_helpers(&1, cfg))
      |> Enum.group_by(fn e -> {e.name, e.arity, e.hash} end)
      |> Enum.flat_map_reduce(%{}, fn group, specs ->
        case plan_for_group(group, cfg) do
          {[], _spec_update} -> {[], specs}
          {entries, spec_update} -> {entries, merge_specs(specs, spec_update)}
        end
      end)

    # A name already public in the target support module wins — drop those
    # entries so we neither overwrite it nor rewrite callers at the wrong
    # target. Then write the (filtered) specs and group the surviving
    # entries by their source module.
    loser_entries =
      loser_entries |> drop_entries_blocked_by_existing(support_specs, cfg)

    unless cfg.dry_run? do
      support_specs
      |> Enum.each(fn {target, spec} -> write_support_module(target, spec, cfg, paths) end)
    end

    loser_entries
    |> Enum.group_by(fn {mod, _entry} -> mod end, fn {_mod, entry} -> entry end)
  end

  # All `defp` clone candidates in one source file, each tagged with its
  # owning module, structural hash, aliases, and a per-module reachability
  # flag (does the helper call other locals?).
  defp extract_helpers({_path, source}, cfg),
    do: Sourceror.parse_string(source) |> extract_helpers_or_empty(cfg)

  defp extract_helpers_or_empty({:ok, ast}, cfg), do: extract_helpers_from_ast(ast, cfg)
  defp extract_helpers_or_empty({:error, _}, _cfg), do: []

  defp extract_helpers_from_ast(ast, cfg) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        helpers_in_defmodule(name_ast, body, cfg)

      _ ->
        []
    end)
  end

  defp helpers_in_defmodule(name_ast, body, cfg) do
    case alias_to_module(name_ast) do
      {:ok, mod} ->
        if support_module?(mod, cfg) do
          # Never re-extract this refactor's own output.
          []
        else
          helpers_in_module(mod, body_to_exprs(body), cfg)
        end

      :error ->
        []
    end
  end

  defp helpers_in_module(module, body_exprs, cfg) do
    aliases = collect_aliases(body_exprs)

    body_exprs
    |> Enum.filter(&defp_clause?/1)
    |> Enum.group_by(&defp_name_arity_or_skip/1)
    |> Enum.reject(fn {key, _} -> key == :skip end)
    |> Enum.flat_map(fn {{name, arity}, clauses} ->
      build_helper_entry(module, name, arity, clauses, aliases, cfg)
    end)
  end

  defp build_helper_entry(module, name, arity, clauses, aliases, cfg) do
    cond do
      total_mass(clauses) < cfg.min_mass -> []
      references_module_attr_or_reserved?(clauses) -> []
      calls_unmigratable?(clauses) -> []
      true -> [helper_entry(module, name, arity, clauses, aliases)]
    end
  end

  defp helper_entry(module, name, arity, clauses, aliases) do
    %{
      aliases: aliases,
      arity: arity,
      clauses: clauses,
      hash: hash_clauses(clauses),
      module: module,
      name: name
    }
  end

  defp plan_for_group({_key, entries}, cfg) do
    distinct_modules = entries |> Enum.map(& &1.module) |> Enum.uniq()

    if length(distinct_modules) < cfg.min_modules do
      {[], %{}}
    else
      entries |> decide_target(cfg) |> emit_for_target(entries)
    end
  end

  defp decide_target(entries, cfg) do
    prefix =
      entries
      |> Enum.map(&Module.split(&1.module))
      |> longest_common_prefix()

    if length(prefix) >= 2 do
      {:ok, Module.concat(prefix ++ [cfg.suffix])}
    else
      :skip
    end
  end

  defp emit_for_target(:skip, _entries), do: {[], %{}}

  defp emit_for_target({:ok, target}, entries) do
    # Use one canonical helper body for the support module; the source
    # modules are losers whose call sites get rewritten + defp deleted.
    canonical = hd(entries)
    sources = entries |> Enum.map(& &1.module) |> MapSet.new()

    spec = %{
      target => %{
        aliases: canonical.aliases,
        name: canonical.name,
        arity: canonical.arity,
        clauses: canonical.clauses,
        sources: sources
      }
    }

    loser_entries =
      entries
      |> Enum.map(fn e ->
        {e.module, %{name: e.name, arity: e.arity, hash: e.hash, target: target}}
      end)

    {loser_entries, spec}
  end

  # Merge per-target specs. Two distinct helper clone groups can land in
  # the same support module; collect their function specs together.
  defp merge_specs(specs, updates) do
    Enum.reduce(updates, specs, fn {target, fn_spec}, acc ->
      Map.update(acc, target, %{functions: [fn_spec]}, fn existing ->
        %{functions: existing.functions ++ [fn_spec]}
      end)
    end)
  end

  # Drop loser entries whose `{name, arity}` is already a public `def` in
  # the (existing on-disk) support module — that definition wins.
  defp drop_entries_blocked_by_existing(loser_entries, support_specs, cfg) do
    targets = loser_entries |> Enum.map(fn {_m, %{target: t}} -> t end) |> Enum.uniq()

    existing_publics =
      Map.new(targets, fn target ->
        path = shared_module_path(target, cfg.write_root, [])
        {target, public_keys_on_disk(path, target)}
      end)

    fresh_publics = fresh_public_keys(support_specs)

    loser_entries
    |> Enum.reject(fn {_m, %{name: n, arity: a, target: t}} ->
      MapSet.member?(Map.fetch!(existing_publics, t), {n, a}) and
        not MapSet.member?(Map.get(fresh_publics, t, MapSet.new()), {n, a})
    end)
  end

  defp fresh_public_keys(support_specs) do
    Map.new(support_specs, fn {target, %{functions: fns}} ->
      {target, fns |> Enum.map(&{&1.name, &1.arity}) |> MapSet.new()}
    end)
  end

  defp public_keys_on_disk(path, target) do
    with true <- File.exists?(path),
         {:ok, source} <- File.read(path),
         {:ok, ast} <- Sourceror.parse_string(source),
         {:ok, body_exprs} <- find_module_body(ast, target) do
      body_exprs
      |> Enum.filter(&match?({:def, _, _}, &1))
      |> Enum.map(&clause_name_arity/1)
      |> Enum.reject(&match?({nil, _}, &1))
      |> MapSet.new()
    else
      _ -> MapSet.new()
    end
  end

  # --- rewrite (transform) ---------------------------------------------

  defp rewrite_with_plan_or_passthrough(nil, source), do: source

  defp rewrite_with_plan_or_passthrough(plan, source),
    do: Sourceror.parse_string(source) |> apply_plan_or_passthrough(plan, source)

  defp apply_plan_or_passthrough({:ok, ast}, plan, source), do: apply_plan(ast, plan, source)
  defp apply_plan_or_passthrough({:error, _}, _plan, source), do: source

  defp apply_plan(ast, plan, source) do
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

  defp patches_for_defmodule(name_ast, body, plan) do
    case alias_to_module(name_ast) do
      {:ok, mod} -> module_patches(Map.get(plan, mod), body_to_exprs(body))
      :error -> []
    end
  end

  defp module_patches(nil, _body_exprs), do: []

  defp module_patches(entries, body_exprs) do
    live_entries = Enum.filter(entries, &entry_still_applicable?(body_exprs, &1))

    rewrite_patches = live_entries |> Enum.flat_map(&call_site_patches(body_exprs, &1))
    delete_patches = live_entries |> Enum.flat_map(&delete_defp_patches(body_exprs, &1))

    rewrite_patches ++ delete_patches
  end

  # Skip an entry whose target `defp` was already rewritten by an earlier
  # pass (its body hash no longer matches the plan).
  defp entry_still_applicable?(body_exprs, %{name: name, arity: arity, hash: hash}) do
    clauses = body_exprs |> Enum.filter(&clause_matches?(&1, name, arity))
    clauses != [] and hash_clauses(clauses) == hash
  end

  # Rewrite every unqualified call to `name/arity` (plain or pipe-rhs) into
  # `Target.name(...)`. Patches the call head token only, leaving the
  # argument source verbatim.
  defp call_site_patches(body_exprs, %{name: name, arity: arity, target: target}) do
    body_exprs
    |> Enum.flat_map(&calls_in_expr(&1, name, arity))
    |> Enum.flat_map(&call_patch(&1, name, target))
  end

  defp calls_in_expr(expr, name, arity) do
    expr
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      # capture `&name/arity` — must be rewritten too, or the deleted
      # local `defp` leaves a dangling reference. Matched before the
      # plain-call clause so the inner `{name, _, _}` isn't double-counted.
      {:&, _, [{:/, _, [{^name, _, ctx}, ^arity]}]} = node when is_atom(ctx) ->
        [{:capture, node}]

      {:&, _, [{:/, _, [{^name, _, ctx}, {:__block__, _, [^arity]}]}]} = node when is_atom(ctx) ->
        [{:capture, node}]

      # plain local call `name(a, b)`
      {^name, _, args} = node when is_list(args) and length(args) == arity ->
        [node]

      # pipe form `x |> name(b)` — call node carries arity-1 args, the
      # piped lhs supplies the first argument.
      {:|>, _, [_lhs, {^name, _, args}]} = node when is_list(args) and length(args) == arity - 1 ->
        [{:pipe_rhs, node}]

      _ ->
        []
    end)
  end

  # Plain call: replace the leading `name` token with `Target.name`,
  # leaving the parenthesised args untouched.
  defp call_patch({name, _, _args} = node, name, target) when is_atom(name),
    do: head_token_patch(node, name, target)

  # Pipe form: replace the rhs call's `name` token only.
  defp call_patch({:pipe_rhs, {:|>, _, [_lhs, {name, _, _} = call]}}, name, target),
    do: head_token_patch(call, name, target)

  # Capture `&name/arity`: rewrite the inner `name` token to `Target.name`
  # so the resulting `&Target.name/arity` resolves after the local defp is
  # deleted.
  defp call_patch({:capture, {:&, _, [{:/, _, [{name, _, _} = ref, _arity]}]}}, name, target),
    do: head_token_patch(ref, name, target)

  defp call_patch(_, _name, _target), do: []

  # Replace exactly the `name` identifier token at the node's start with
  # `Target.name`, leaving everything after it (args / arity) verbatim.
  defp head_token_patch(node, name, target) do
    case Sourceror.get_range(node) do
      %{start: start_pos} ->
        head_end = %{
          line: start_pos[:line],
          column: start_pos[:column] + String.length(to_string(name))
        }

        replacement = "#{inspect(target)}.#{name}"
        [%{change: replacement, range: %{start: start_pos, end: head_end}}]

      _ ->
        []
    end
  end

  defp delete_defp_patches(body_exprs, %{name: name, arity: arity}) do
    clauses = body_exprs |> Enum.filter(&clause_matches?(&1, name, arity))

    case clauses do
      [] ->
        []

      [first | _] = list ->
        last = List.last(list)

        with %{start: start_pos} <- Sourceror.get_range(first),
             %{end: end_pos} <- Sourceror.get_range(last) do
          [%{change: "", range: %{start: start_pos, end: end_pos}}]
        else
          _ -> []
        end
    end
  end

  # --- support module writing ------------------------------------------

  defp write_support_module(target, spec, cfg, source_paths) do
    path = shared_module_path(target, cfg.write_root, source_paths)
    File.mkdir_p!(Path.dirname(path))

    case read_existing(path, target) do
      nil ->
        File.write!(path, render_fresh_module(target, spec))

      %{source: source, public_keys: keys} ->
        filtered = drop_existing_functions(spec, keys)
        write_appended(path, source, filtered)
    end
  end

  defp write_appended(_path, _source, %{functions: []}), do: :ok

  defp write_appended(path, source, spec) do
    addition = render_functions(spec.functions)
    File.write!(path, splice_before_module_end(source, addition))
  end

  defp drop_existing_functions(spec, existing_keys) do
    %{
      spec
      | functions:
          Enum.reject(spec.functions, &MapSet.member?(existing_keys, {&1.name, &1.arity}))
    }
  end

  defp read_existing(path, target) do
    with true <- File.exists?(path),
         {:ok, source} <- File.read(path),
         {:ok, ast} <- Sourceror.parse_string(source),
         {:ok, body_exprs} <- find_module_body(ast, target) do
      keys =
        body_exprs
        |> Enum.filter(fn {kind, _, _} -> kind in [:def, :defp] end)
        |> Enum.map(&clause_name_arity/1)
        |> Enum.reject(&match?({nil, _}, &1))
        |> MapSet.new()

      %{source: source, public_keys: keys}
    else
      _ -> nil
    end
  end

  defp render_fresh_module(target, spec) do
    body = render_functions(spec.functions)

    """
    defmodule #{inspect(target)} do
    #{indent(body, "  ")}
    end
    """
  end

  defp render_functions(functions) do
    functions
    |> Enum.map_join("\n\n", fn fn_spec ->
      comment = render_origin_comment(fn_spec.sources)
      body = render_promoted_def(fn_spec)
      [comment, body] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
    end)
  end

  defp render_promoted_def(%{aliases: aliases, clauses: clauses}) do
    clauses
    |> Enum.map(&promote_to_def/1)
    |> Enum.map_join("\n\n", fn clause ->
      clause |> qualify_aliases(aliases) |> Sourceror.to_string()
    end)
    |> String.trim()
  end

  defp render_origin_comment(sources) do
    case sources |> Enum.map(&inspect/1) |> Enum.sort() do
      [] -> ""
      list -> "# extracted from: " <> Enum.join(list, ", ")
    end
  end

  # --- shared AST helpers ----------------------------------------------

  defp support_module?(module, cfg),
    do: module |> Module.split() |> List.last() == cfg.suffix

  defp defp_clause?({:defp, _, [_head, body_kw]}) when is_list(body_kw), do: true
  defp defp_clause?(_), do: false

  defp defp_name_arity_or_skip({:defp, _, [head | _]}) do
    case strip_when(head) do
      {name, _, args} when is_atom(name) and is_list(args) -> {name, length(args)}
      {name, _, nil} when is_atom(name) -> {name, 0}
      _ -> :skip
    end
  end

  defp clause_matches?({:defp, _, [head | _]}, name, arity) do
    case strip_when(head) do
      {^name, _, args} when is_list(args) and length(args) == arity -> true
      {^name, _, nil} when arity == 0 -> true
      _ -> false
    end
  end

  defp clause_matches?(_, _, _), do: false

  defp clause_name_arity({_kind, _, [head | _]}) do
    case strip_when(head) do
      {name, _, args} when is_atom(name) and is_list(args) -> {name, length(args)}
      {name, _, nil} when is_atom(name) -> {name, 0}
      _ -> {nil, -1}
    end
  end

  # A helper is only relocatable when its body is self-contained in the
  # support module: every *unqualified* call it makes must resolve to a
  # clause of the helper itself (self/co-recursion within the migrated
  # `{name, arity}` group). Any other unqualified call — whether it
  # names another local `def`/`defp` *or* a function injected by `use`
  # in the source module (e.g. AstHelpers via `use ...Refactor`) — would
  # be undefined once the body moves into the bare support module. The
  # earlier `local_keys`-only check missed the `use`-injected case, since
  # those names are absent from the source module's local definitions.
  # `collect_calls_in_clauses/1` already excludes remote/qualified calls
  # and Kernel special forms, so what remains is exactly the unqualified
  # local surface.
  defp calls_unmigratable?(clauses) do
    own_keys = clauses |> Enum.map(&clause_name_arity/1) |> MapSet.new()

    clauses
    |> collect_calls_in_clauses()
    |> Enum.any?(fn {name, arity} -> not MapSet.member?(own_keys, {name, arity}) end)
  end

  defp references_module_attr_or_reserved?(clauses) do
    clauses
    |> Enum.any?(fn {:defp, _, [_head, body_kw]} ->
      body_kw |> Keyword.values() |> Enum.any?(&node_reserved?/1)
    end)
  end

  defp node_reserved?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:@, _, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) -> true
      {name, _, ctx} when is_atom(name) and is_atom(ctx) and name in @reserved_macros -> true
      _ -> false
    end)
  end

  defp promote_to_def({:defp, meta, args}), do: {:def, meta, args}
  defp promote_to_def(other), do: other

  defp collect_aliases(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {:alias, _, [{:__aliases__, _, parts}]} ->
        [{List.last(parts), Module.concat(parts)}]

      {:alias, _, [{:__aliases__, _, parts}, opts]} ->
        full = Module.concat(parts)
        short = alias_as(opts) || List.last(parts)
        [{short, full}]

      {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, subs}]} ->
        Enum.map(subs, fn {:__aliases__, _, sub_parts} ->
          {List.last(sub_parts), Module.concat(base ++ sub_parts)}
        end)

      _ ->
        []
    end)
    |> Map.new()
  end

  defp alias_as(opts) do
    opts
    |> unwrap_kw()
    |> Keyword.get(:as)
    |> case do
      {:__aliases__, _, [as_name]} -> as_name
      _ -> nil
    end
  end

  defp unwrap_kw({:__block__, _, [kw]}) when is_list(kw), do: kw
  defp unwrap_kw(kw) when is_list(kw), do: kw
  defp unwrap_kw(_), do: []

  defp qualify_aliases(ast, aliases) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, [single]} = node when is_atom(single) ->
        case Map.get(aliases, single) do
          nil -> node
          full -> {:__aliases__, meta, Module.split(full) |> Enum.map(&String.to_atom/1)}
        end

      other ->
        other
    end)
  end

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

  defp longest_common_prefix([]), do: []
  defp longest_common_prefix([single]), do: single

  defp longest_common_prefix(lists) do
    lists
    |> Enum.zip()
    |> Enum.take_while(fn tuple ->
      [head | rest] = Tuple.to_list(tuple)
      Enum.all?(rest, &(&1 == head))
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp hash_clauses(clauses), do: clauses |> Enum.map(&normalize_clause/1) |> :erlang.phash2()

  defp normalize_clause({:defp, _, [head, body_kw]}) do
    stripped_head = strip_meta(head)
    stripped_body = body_kw |> Keyword.values() |> Enum.map(&strip_meta/1)
    rename_vars({stripped_head, stripped_body})
  end

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp rename_vars(ast) do
    {result, _} = Macro.prewalk(ast, %{}, &rename_var_node/2)
    result
  end

  defp rename_var_node({name, [], ctx} = node, acc) when is_atom(name) and is_atom(ctx) do
    cond do
      underscore?(name) -> {node, acc}
      Map.has_key?(acc, name) -> {{:"$var", [], [Map.fetch!(acc, name)]}, acc}
      true -> {{:"$var", [], [map_size(acc)]}, Map.put(acc, name, map_size(acc))}
    end
  end

  defp rename_var_node(node, acc), do: {node, acc}

  defp total_mass(clauses), do: clauses |> Enum.map(&clause_mass/1) |> Enum.sum()

  defp clause_mass({:defp, _, [_head, body_kw]}),
    do: body_kw |> Keyword.values() |> Enum.map(&node_count/1) |> Enum.sum()

  defp node_count(ast) do
    {_, count} = Macro.prewalk(ast, 0, fn node, acc -> {node, acc + 1} end)
    count
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp indent(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end

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

  defp prepared_for_paths(nil, opts), do: load_default_sources() |> plan_from_sources(opts)

  defp prepared_for_paths(paths, opts) when is_list(paths) do
    sources = Enum.map(paths, fn p -> {p, File.read!(p)} end)
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
