defmodule Number42.Refactors.Ex.ExtractBehaviourFromAdapterFamily do
  @moduledoc """
  Detects families of modules that share a public API shape, synthesizes
  a behaviour module for the shared surface, and marks every
  implementation with `@behaviour` and `@impl true`.

  ## Detection: BEAM introspection, not names

  Candidates come from the **compiled** project, never from module-name
  heuristics. For every selected module we load its BEAM and read

  - `__info__(:functions)` — the actual public surface,
  - `__info__(:attributes)[:behaviour]` — behaviours already declared
    (via `@behaviour` *and* `use`), expanded to their callbacks through
    `behaviour_info(:callbacks)`.

  Functions that are already callbacks of an implemented behaviour are
  removed from the surface — they are spoken for and re-extracting them
  would produce conflicting `@impl` annotations. Compiler-generated
  functions (`__struct__/1`, `__impl__/1`, `behaviour_info/1`, …) and
  protocol modules are excluded as well.

  Every pair of modules whose remaining surfaces intersect is a
  candidate — any shared `{name, arity}` subset counts. Pairs are
  scored:

  - `+10` per shared function,
  - `+30` when the modules are namespace siblings
    (`A.Sub.X` / `A.Sub.Y`),
  - `+15` when they sit at the same nesting depth without being
    siblings (`A.Sub.X` / `B.Sub.Y`).

  Pairs with an identical shared set are merged into a family; the
  family's members are all modules whose surface covers that set.
  Module names are only used for *presentation* (scoring bonuses,
  behaviour naming) — never to decide whether modules belong together.

  ## Dominant path group

  A family is reduced to its **dominant path group**: members are
  grouped by the namespace segment directly below the app root, the
  largest group wins, and members outside it are dropped — a single
  off-tree module no longer blocks the others
  (`Root.A.M1 + Root.A.M2 + Root.B.M3` → behaviour over `M1, M2` rooted
  at `Root.A`, `M3` dropped). A sub-namespace group always beats the
  bare root, so the behaviour name normally carries a path segment
  beside the root. A bare-root family (`Root.*`) survives only as a
  fallback — no sub-namespace group dominates *and* the root group is
  large (≥4 members, e.g. nine context modules sharing `authorize/3`) —
  yielding a top-level `Root.AuthorizerBehaviour`. A tie between the two
  largest groups resolves to the largest only when it alone clears that
  bar; otherwise no dominant group → skip.

  ## When a family is worth extracting

  A single shared function is a weak signal — half the codebase has a
  lone `init/1` or `render/2`. So the substance threshold (applied to
  the dominant group) is a disjunction:

  - **exactly one** shared callback across **three or more** modules, or
  - **two or more** shared callbacks across **two or more** modules.

  `:min_modules` and `:min_callbacks` stay hard floors *below* this rule
  (raise them per project to suppress more; lowering them never relaxes
  the disjunction).

  ## Dynamic dispatch (`:require_dispatch`)

  Shared API *shape* is not the same as a need for polymorphism. A
  behaviour only earns its keep when something dispatches one of its
  callbacks through a value whose module isn't known statically —
  `var.fun(args)` or `apply(var, :fun, args)`. With
  `require_dispatch: true` a family is kept only if such a call site
  exists somewhere in the sources (framework receivers like `repo`,
  `conn` are ignored — `repo.all()` is an Ecto call, not a family
  dispatch). With this on, families seed from the *smallest* dispatched
  core so divergent members coexist; functions a majority share become
  `@optional_callbacks`.

  Default is `false`: idiomatic Elixir rarely dispatches on module
  identity (it uses protocols, `@behaviour`, or struct pattern-matching),
  so requiring dispatch finds little. Dogfooding against two real
  codebases (this one and a Phoenix app) returned **zero** dispatched
  families — the shape-only matches were all called statically. Turn it
  on when you specifically want "only the families with a polymorphic
  caller"; leave it off for shape-based discovery (which is noisier).

  ## Default off

  Mechanically sound but precision-sensitive: on real codebases it tends
  to surface shape coincidences (e.g. every Ecto schema has a
  `changeset`) rather than genuine abstractions. It is therefore **not**
  in the default `.refactor.exs` — opt in per project where the trade is
  wanted. See `num42/num42_refactors#158` for the protocol-extraction
  sibling that reuses this engine on the data-type axis.

  ## False-positive guards

  - **Macro-generated surface**: a shared function only qualifies when
    every member defines it as a genuine `def` in its source file.
    `use`-injected functions (e.g. `child_spec/1`, `start_link` from
    `use GenServer`/`Supervisor`/`Ecto.Repo`) have no source `def`, so
    intersecting the BEAM surface with the parsed `def`s drops them —
    generalised across any `use` macro, no behaviour allow-list needed.
  - **Delegations**: `defdelegate`s are excluded from the surface. They
    mark call sites not yet rewritten, not real implementations; counting
    them would extract a behaviour the module doesn't actually implement.
  - **Already-covered callbacks**: excluded per module, see above. When
    inserting `@impl` flips a module into all-or-nothing mode, the
    pre-existing implementations of its other behaviours are annotated
    with `@impl <Behaviour>` too (resolved via BEAM introspection, the
    same way `ResolveImplTrue` does), so no new compiler warning fires.
  - **No clear name**: the behaviour is named after its dominant
    group's sub-namespace plus a descriptor (the members' common
    CamelCase suffix, or a domain noun derived from the shared function
    name). Families that resolve to no descriptor are skipped
    (recorded under `:skipped` in the plan).
  - **Naming collisions**: if the derived module is already loaded,
    part of the detection set, claimed by a higher-ranked family, or
    its target file exists with foreign content, the family is skipped.
  - **`@impl` conflicts**: when two families overlap in both members
    and callbacks, only the higher-ranked family is kept.

  ## Behaviour naming

  The name is rooted at the dominant group's namespace and carries a
  domain noun, not a bare verb: a known verb becomes its agent noun
  (`render` → `Renderer`), a verb phrase is named after its object
  (`send_message` → `Message`), and an unrecognized verb is offered to
  the shared `Semantic` static-embedding classifier as a fallback
  (a domain synonym still lands a bucket noun). Pure-noun names pass
  through unchanged (`changeset` → `Changeset`).

  ## Spec-derived callbacks

  `@callback` specs are derived from existing `@spec`s via
  `Code.Typespec.fetch_specs/1`: when every member that declares a spec
  for a shared function agrees on a single rendering, that spec becomes
  the callback spec. Otherwise the callback falls back to the broad
  `name(term(), …) :: term()`.

  ## Side effect: file write

  Like `ExtractSharedModule`, `prepare/1` writes one new `.ex` file per
  synthesized behaviour. The destination derives from the members' real
  source layout (`lib/my_app/adapters/` stays `lib/my_app/adapters/`),
  rooted at `opts[:write_root]` (defaults to `File.cwd!/0`). With
  `dry_run: true` the plan is fully populated but nothing is written.

  ## Limitations

  - Requires the project to be compiled (the engine runs after
    `mix compile`; unloadable modules are skipped).
  - Nested `defmodule` blocks resolve to their literal alias only —
    same restriction as `ResolveImplTrue`.
  - Shared `{name, arity}` tuples say nothing about *semantic*
    parallelism. Raise `:min_callbacks`/`:min_modules` per project when
    one-function overlaps produce noise.

  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Analysis.Semantic

  @default_min_modules 2
  @default_min_callbacks 1
  # The lone-callback case needs a third witness to be worth a behaviour;
  # two members sharing a single function is too thin a contract.
  @lone_callback_min_modules 3
  # A group this large carries its own weight: a bare-root family (every
  # member directly under the app root, e.g. nine context modules sharing
  # `authorize/3`) is accepted, and a path-group tie resolves to the
  # largest group instead of being skipped. Below it, both stay strict.
  @large_group_min_modules 4
  @shared_fun_weight 10
  @sibling_bonus 30
  @same_depth_bonus 15

  @excluded_path_prefixes ["test/", "dev/"]

  # Variable names that almost always hold a framework value, not a member
  # of a synthesized family. `repo.all()` is an Ecto call, not a behaviour
  # dispatch; counting it would falsely justify any family with an `all/0`.
  @framework_receivers ~w(repo conn socket query changeset multi conf config
                          meta assigns params adapter pid ref state)a

  @impl Number42.Refactors.Refactor
  def description, do: "extract shared module APIs into behaviours via BEAM introspection"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A family of modules implementing the same public API by convention
    is an implicit contract. Making it explicit as a behaviour lets the
    compiler verify each implementation (`@impl true` catches drifted
    names and arities), documents the contract in one place, and gives
    dialyzer a callback spec to check against. Detection works on the
    compiled BEAM surface, so it sees the API exactly as callers do.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    {:ok, build_plan(plan_modules(opts), plan_sources(opts), opts)}
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    with %{implementations: impls} when map_size(impls) > 0 <- Keyword.get(opts, :prepared),
         {:ok, ast} <- Sourceror.parse_string(source) do
      ast
      |> collect_modules()
      |> Enum.flat_map(&module_patches(&1, impls))
      |> patch_or_passthrough(source)
    else
      _ -> source
    end
  end

  @doc """
  Build the full plan from loaded `modules` and `[{path, source}]`
  tuples.

  Side effect: writes one behaviour `.ex` file per synthesized family
  under `opts[:write_root]` (defaults to `File.cwd!/0`) unless
  `dry_run: true`.

  Plan shape:

      %{
        pairs: [%{a:, b:, shared:, score:, siblings?:, same_depth?:, jaccard:}],
        families: [%{behaviour:, path:, rendered:, callbacks:, members:, score:}],
        skipped: [%{members:, callbacks:, reason:}],
        implementations: %{member => [%{behaviour:, callbacks:}]}
      }
  """
  @spec build_plan([module()], [{String.t(), String.t()}], keyword()) :: map()
  def build_plan(modules, sources, opts \\ []) do
    min_modules = Keyword.get(opts, :min_modules, @default_min_modules)
    min_callbacks = Keyword.get(opts, :min_callbacks, @default_min_callbacks)
    write_root = Keyword.get(opts, :write_root, File.cwd!())
    dry_run? = Keyword.get(opts, :dry_run, false)
    require_dispatch? = Keyword.get(opts, :require_dispatch, false)

    visible = visible_defs(sources)
    surfaces = modules |> introspect() |> restrict_to_visible(visible)
    pairs = candidate_pairs(surfaces)
    dispatched = if require_dispatch?, do: dynamic_dispatches(sources), else: :all

    {candidates, conflicted} =
      families(pairs, surfaces, dispatched, min_modules, min_callbacks)

    {families, skipped} = synthesize(candidates, visible, write_root, modules)

    unless dry_run?, do: Enum.each(families, &write_behaviour_file/1)

    %{
      pairs: pairs,
      families: families,
      skipped: Enum.map(conflicted, &skip_record(&1, :impl_conflict)) ++ skipped,
      implementations: implementations(families, surfaces)
    }
  end

  @doc """
  Pure BEAM introspection: load each module and return its surface map
  `%{module => %{funs: MapSet of {name, arity}, behaviours: [module]}}`.

  The surface excludes compiler-generated functions and every callback
  of a behaviour the module already implements. Unloadable modules and
  protocols are dropped.
  """
  @spec introspect([module()]) :: %{module() => %{funs: MapSet.t(), behaviours: [module()]}}
  def introspect(modules) do
    for mod <- modules,
        Code.ensure_loaded?(mod),
        # Erlang modules have no __info__/1
        function_exported?(mod, :__info__, 1),
        not protocol?(mod),
        into: %{} do
      {mod, surface(mod)}
    end
  end

  @doc """
  All module pairs with a non-empty shared surface, scored and ranked.

  Accepts a surface map as returned by `introspect/1`.
  """
  @spec candidate_pairs(%{module() => map()}) :: [map()]
  def candidate_pairs(surfaces) do
    mods = surfaces |> Map.keys() |> Enum.sort()

    for {a, i} <- Enum.with_index(mods),
        b <- Enum.drop(mods, i + 1),
        shared = MapSet.intersection(surfaces[a].funs, surfaces[b].funs),
        MapSet.size(shared) > 0 do
      pair(a, b, shared, surfaces)
    end
    |> Enum.sort_by(&{-&1.score, &1.a, &1.b})
  end

  # --- introspection ---

  defp surface(mod) do
    behaviours =
      mod.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    covered = behaviours |> Enum.flat_map(&callbacks_for/1) |> MapSet.new()

    funs =
      mod.__info__(:functions)
      |> Enum.reject(&generated?/1)
      |> MapSet.new()
      |> MapSet.difference(covered)

    %{funs: funs, behaviours: behaviours}
  end

  defp callbacks_for(behaviour) do
    if Code.ensure_loaded?(behaviour) and
         function_exported?(behaviour, :behaviour_info, 1) do
      behaviour.behaviour_info(:callbacks)
    else
      []
    end
  rescue
    _ -> []
  end

  defp generated?({:behaviour_info, 1}), do: true
  defp generated?({name, _arity}), do: name |> Atom.to_string() |> String.starts_with?("__")

  defp protocol?(mod), do: function_exported?(mod, :__protocol__, 1)

  # --- pair scoring ---

  defp pair(a, b, shared, surfaces) do
    split_a = Module.split(a)
    split_b = Module.split(b)
    siblings? = Enum.drop(split_a, -1) == Enum.drop(split_b, -1)
    same_depth? = length(split_a) == length(split_b)
    union = MapSet.union(surfaces[a].funs, surfaces[b].funs)

    %{
      a: a,
      b: b,
      shared: shared |> MapSet.to_list() |> Enum.sort(),
      score: @shared_fun_weight * MapSet.size(shared) + proximity_bonus(siblings?, same_depth?),
      siblings?: siblings?,
      same_depth?: same_depth?,
      jaccard: Float.round(MapSet.size(shared) / MapSet.size(union), 2)
    }
  end

  defp proximity_bonus(true, _same_depth?), do: @sibling_bonus
  defp proximity_bonus(false, true), do: @same_depth_bonus
  defp proximity_bonus(false, false), do: 0

  # --- families ---

  # A family is seeded from a callback core. With `require_dispatch: true`
  # the core must be a *dispatched* callback — a polymorphic call site is
  # what justifies a behaviour. By default (`require_dispatch: false`) the
  # core is any function shared by ≥2 modules (`:all`), recovering plain
  # form-based detection. Every module implementing the core joins the
  # family; its required set is what they ALL share, and functions a
  # majority share become optional callbacks. Seeding from the smallest
  # core (rather than the largest exact-shared set) lets divergent members
  # coexist under one behaviour instead of splintering into thin families.
  #
  # `pairs` is unused for seeding now but still drives `candidate_pairs`
  # reporting; families come straight from surfaces ∩ core.
  defp families(_pairs, surfaces, dispatched, min_modules, min_callbacks) do
    dispatched
    |> seed_families(surfaces)
    |> Enum.flat_map(&dominant_path_group/1)
    |> Enum.map(&with_optional_callbacks(&1, surfaces))
    |> Enum.map(&Map.put(&1, :score, family_score(&1.callbacks, &1.members, surfaces)))
    |> Enum.filter(&worth_extracting?(&1, min_modules, min_callbacks))
    |> Enum.sort_by(&{-&1.score, &1.callbacks})
    |> accept_disjoint()
  end

  # One seed family per dispatched callback: all modules whose surface
  # contains it, with the required set being everything those modules share
  # in common. A `{name, :any}` dispatch matches every arity of that name.
  defp seed_families(:all, surfaces), do: seed_families(all_surface_keys(surfaces), surfaces)

  defp seed_families(dispatched, surfaces) do
    dispatched
    |> Enum.flat_map(&expand_any(&1, surfaces))
    |> Enum.uniq()
    |> Enum.map(fn cb -> seed_family(cb, surfaces) end)
    |> Enum.reject(&(&1 == nil))
    |> Enum.uniq_by(& &1.members)
  end

  # `:all` (dispatch requirement off) seeds from every function present in
  # at least two surfaces — the old exact-set behaviour's coverage.
  defp all_surface_keys(surfaces) do
    surfaces
    |> Enum.flat_map(fn {_mod, %{funs: funs}} -> MapSet.to_list(funs) end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_cb, count} -> count >= 2 end)
    |> Enum.map(fn {cb, _count} -> cb end)
  end

  defp expand_any({name, :any}, surfaces) do
    for {_mod, %{funs: funs}} <- surfaces, {n, a} <- MapSet.to_list(funs), n == name, do: {n, a}
  end

  defp expand_any(cb, _surfaces), do: [cb]

  defp seed_family({_name, _arity} = core, surfaces) do
    members =
      surfaces
      |> Enum.filter(fn {_mod, %{funs: funs}} -> MapSet.member?(funs, core) end)
      |> Enum.map(fn {mod, _} -> mod end)
      |> Enum.sort()

    case members do
      [] ->
        nil

      _ ->
        required =
          members
          |> Enum.map(&surfaces[&1].funs)
          |> Enum.reduce(&MapSet.intersection/2)
          |> MapSet.to_list()
          |> Enum.sort()

        %{callbacks: required, members: members}
    end
  end

  # After `dominant_path_group` trims the membership, recompute the
  # contract over the *surviving* members: `callbacks` (required) is what
  # they all share; a function a strict majority (> 50%) share — but not
  # all — becomes an optional callback. Functions below the majority are
  # left out, so the behaviour stays meaningful. The substance rule keys
  # off the required set only.
  defp with_optional_callbacks(%{members: members} = fam, surfaces) do
    member_funs = Enum.map(members, &surfaces[&1].funs)

    required =
      member_funs |> Enum.reduce(&MapSet.intersection/2) |> MapSet.to_list() |> Enum.sort()

    required_set = MapSet.new(required)
    threshold = div(length(members), 2)

    optional =
      members
      |> Enum.flat_map(fn mod -> Enum.map(MapSet.to_list(surfaces[mod].funs), &{&1, mod}) end)
      |> Enum.group_by(fn {fun, _mod} -> fun end, fn {_fun, mod} -> mod end)
      |> Enum.filter(fn {fun, mods} -> length(mods) > threshold and fun not in required_set end)
      |> Enum.map(fn {fun, mods} -> {fun, Enum.sort(mods)} end)
      |> Enum.sort()

    %{fam | callbacks: required} |> Map.put(:optional, optional)
  end

  # Restrict a family to its dominant path group. Members are grouped by
  # their path segment directly below the app root; the largest
  # sub-namespace group wins and off-tree members are dropped (a single
  # stray module no longer blocks extraction). The winning `:root_path`
  # is threaded through for naming.
  #
  # A sub-namespace group beats the bare root. A bare-root family
  # (`root.*`) survives only as a fallback when no sub-namespace group
  # dominates and the root group is large enough (`@large_group_min_modules`)
  # — that admits e.g. nine context modules sharing `authorize/3` while
  # still rejecting thin top-level pairs. Ties between equal-size groups
  # resolve to the largest only when it clears the same bar; otherwise no
  # dominant group and the family is skipped.
  defp dominant_path_group(%{members: members} = fam) do
    groups = Enum.group_by(members, &path_group_key/1)
    sub_groups = Map.delete(groups, :root)

    case dominant(sub_groups) || root_fallback(groups) do
      nil ->
        []

      {root_path, group_members} ->
        root_path = if root_path == :root, do: [], else: root_path
        [%{fam | members: Enum.sort(group_members)} |> Map.put(:root_path, root_path)]
    end
  end

  # The path below the app root, excluding the module's own name. A
  # module sitting directly under the root (`PositionDb.Items`) has no
  # such path → `:root`. `PositionDb.Items.ItemPositions` → `[Items]`.
  defp path_group_key(mod) do
    case mod |> Module.split() |> Enum.drop(1) |> Enum.drop(-1) do
      [] -> :root
      path -> path
    end
  end

  defp dominant(groups) when map_size(groups) == 0, do: nil

  defp dominant(groups) do
    ranked = Enum.sort_by(groups, fn {path, members} -> {-length(members), path} end)

    case ranked do
      # Tie at the top: take the largest only if it clears the large-group
      # bar on its own (a genuine majority, not two thin rivals).
      [{_, a} = winner, {_, b} | _] when length(a) == length(b) ->
        if length(a) >= @large_group_min_modules, do: winner, else: nil

      [winner | _] ->
        winner
    end
  end

  defp root_fallback(%{root: members}) when length(members) >= @large_group_min_modules,
    do: {:root, members}

  defp root_fallback(_groups), do: nil

  # Extract a behaviour only when the shared contract is substantial
  # enough: exactly one shared callback demands at least three members,
  # otherwise two shared callbacks across two members suffice. The
  # configurable `min_modules`/`min_callbacks` remain hard floors below
  # this rule (raise them per project to suppress more).
  defp worth_extracting?(%{members: members, callbacks: callbacks}, min_modules, min_callbacks) do
    module_count = length(members)
    callback_count = length(callbacks)

    module_count >= min_modules and callback_count >= min_callbacks and
      substantial?(module_count, callback_count)
  end

  defp substantial?(module_count, 1), do: module_count >= @lone_callback_min_modules
  defp substantial?(module_count, callback_count) when callback_count >= 2, do: module_count >= 2
  defp substantial?(_module_count, _callback_count), do: false

  defp family_score(shared, members, _surfaces) do
    splits = Enum.map(members, &Module.split/1)
    parents = splits |> Enum.map(&Enum.drop(&1, -1)) |> Enum.uniq()
    depths = splits |> Enum.map(&length/1) |> Enum.uniq()

    cohesion =
      cond do
        length(parents) == 1 -> @sibling_bonus
        length(depths) == 1 -> @same_depth_bonus
        true -> 0
      end

    @shared_fun_weight * length(shared) * length(members) + cohesion
  end

  # A module can implement two synthesized behaviours only when their
  # callback sets are disjoint — otherwise the second `@impl` would be
  # ambiguous. Keep the higher-ranked family, report the rest.
  defp accept_disjoint(families) do
    {accepted, conflicted} =
      Enum.reduce(families, {[], []}, fn fam, {acc, dropped} ->
        if Enum.any?(acc, &conflicts?(&1, fam)),
          do: {acc, [fam | dropped]},
          else: {[fam | acc], dropped}
      end)

    {Enum.reverse(accepted), Enum.reverse(conflicted)}
  end

  defp conflicts?(f1, f2) do
    shares_member? = not MapSet.disjoint?(MapSet.new(f1.members), MapSet.new(f2.members))
    shares_callback? = not MapSet.disjoint?(MapSet.new(f1.callbacks), MapSet.new(f2.callbacks))
    shares_member? and shares_callback?
  end

  # --- dynamic dispatch detection ---

  # Every `{name, arity}` invoked through a *dynamic* receiver across the
  # sources — the evidence that a family is actually used polymorphically.
  # Two forms count:
  #
  #   * `receiver.fun(args)` where `receiver` is not a compile-time module
  #     alias (so a variable, a function result, `@attr`, …)
  #   * `apply(receiver, :fun, args)` with the same dynamic-receiver test;
  #     a literal arg list pins the arity, otherwise it matches any arity
  #     of that name (`{fun, :any}`).
  #
  # Static calls (`Foo.Bar.fun(x)`) are deliberately excluded: they need
  # no behaviour, they name their target directly.
  defp dynamic_dispatches(sources) do
    sources
    |> Enum.reject(fn {path, _src} -> excluded_path?(path) end)
    |> Enum.reduce(MapSet.new(), fn {_path, src}, acc ->
      case Sourceror.parse_string(src) do
        {:ok, ast} -> ast |> Macro.prewalker() |> Enum.reduce(acc, &collect_dispatch/2)
        {:error, _} -> acc
      end
    end)
  end

  # apply(receiver, :fun, arg_list)
  defp collect_dispatch({:apply, _, [receiver, fun_ast, args]}, acc) do
    case literal_atom(fun_ast) do
      {:ok, fun} ->
        if dynamic_receiver?(receiver),
          do: MapSet.put(acc, {fun, apply_arity(args)}),
          else: acc

      :error ->
        acc
    end
  end

  # receiver.fun(args) — a remote call whose receiver is not a module alias
  defp collect_dispatch({{:., _, [receiver, fun]}, _, args}, acc)
       when is_atom(fun) and is_list(args) do
    if dynamic_receiver?(receiver),
      do: MapSet.put(acc, {fun, length(args)}),
      else: acc
  end

  defp collect_dispatch(_node, acc), do: acc

  # A receiver is static when it resolves to a module alias (`Foo.Bar`) or
  # is an Erlang module atom (`:lists`). A variable is dynamic — except for
  # well-known framework names (`repo`, `conn`, …), which hold framework
  # values, not family members; treating those as dispatch would falsely
  # justify families that merely share a name with a framework function.
  defp dynamic_receiver?({:__aliases__, _, _}), do: false
  defp dynamic_receiver?(mod) when is_atom(mod), do: false

  defp dynamic_receiver?({var, _, ctx}) when is_atom(var) and is_atom(ctx),
    do: var not in @framework_receivers

  defp dynamic_receiver?(_), do: true

  defp apply_arity({:__block__, _, [args]}) when is_list(args), do: length(args)
  defp apply_arity(args) when is_list(args), do: length(args)
  defp apply_arity(_), do: :any

  # Sourceror wraps a bare atom literal in a `__block__` node.
  defp literal_atom(atom) when is_atom(atom), do: {:ok, atom}
  defp literal_atom({:__block__, _, [atom]}) when is_atom(atom), do: {:ok, atom}
  defp literal_atom(_), do: :error

  # --- visible surface (macro-generated guard) ---

  defp visible_defs(sources) do
    sources
    |> Enum.reject(fn {path, _src} -> excluded_path?(path) end)
    |> Enum.flat_map(fn {path, src} -> modules_in_source(path, src) end)
    |> Map.new(fn {mod, path, defs} -> {mod, %{path: path, defs: defs}} end)
  end

  defp excluded_path?(path), do: String.starts_with?(path, @excluded_path_prefixes)

  defp modules_in_source(path, src) do
    case Sourceror.parse_string(src) do
      {:ok, ast} -> ast |> Macro.prewalker() |> Enum.flat_map(&module_entry(&1, path))
      {:error, _} -> []
    end
  end

  defp module_entry({:defmodule, _, [name_ast, [{_do, body}]]}, path) do
    case alias_to_module(name_ast) do
      {:ok, mod} -> [{mod, path, public_def_keys(body)}]
      :error -> []
    end
  end

  defp module_entry(_node, _path), do: []

  # Detection surface: only genuine `def`s. `defdelegate` is excluded —
  # delegations are call sites we haven't rewritten yet, not real
  # implementations, and counting them would extract a behaviour the
  # module doesn't actually implement. Intersecting the BEAM surface with
  # this set also drops every `use`-injected function (child_spec/1,
  # start_link from GenServer/Supervisor/Ecto.Repo, …): macro-generated
  # functions have no source `def`, so they never appear here.
  defp public_def_keys(body) do
    body
    |> body_to_exprs()
    |> Enum.flat_map(&surface_def_keys/1)
    |> MapSet.new()
  end

  defp surface_def_keys({:def, _, _} = node), do: def_keys(node)
  defp surface_def_keys(_), do: []

  # Anchor search for inserting attributes — a delegated callback impl is
  # still a real clause that needs an `@impl`, so this matches `defdelegate`.
  defp def_keys({kind, _, [head | _]}) when kind in [:def, :defdelegate] do
    case head |> strip_when() |> name_and_args() do
      {:ok, name, args} -> Enum.map(def_arities(args), &{name, &1})
      :error -> []
    end
  end

  defp def_keys(_), do: []

  defp name_and_args({name, _, args}) when is_atom(name) and is_list(args),
    do: {:ok, name, args}

  defp name_and_args({name, _, nil}) when is_atom(name), do: {:ok, name, []}
  defp name_and_args(_), do: :error

  # `def foo(a, b \\ 1)` exports foo/1 and foo/2 — mirror that.
  defp def_arities(args) do
    required = Enum.count(args, fn arg -> not match?({:\\, _, _}, arg) end)
    Enum.to_list(required..length(args))
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp restrict_to_visible(surfaces, visible) do
    for {mod, surf} <- surfaces, info = visible[mod], info != nil, into: %{} do
      {mod, %{surf | funs: MapSet.intersection(surf.funs, info.defs)}}
    end
  end

  # --- synthesis ---

  defp synthesize(families, visible, write_root, modules) do
    {synthesized, skipped, _taken} =
      Enum.reduce(families, {[], [], MapSet.new()}, fn fam, {acc, skipped, taken} ->
        case synthesize_family(fam, visible, write_root, modules, taken) do
          {:ok, fam} -> {[fam | acc], skipped, MapSet.put(taken, fam.behaviour)}
          {:skip, reason} -> {acc, [skip_record(fam, reason) | skipped], taken}
        end
      end)

    {Enum.reverse(synthesized), Enum.reverse(skipped)}
  end

  defp synthesize_family(fam, visible, write_root, modules, taken) do
    with {:ok, name} <- behaviour_name(fam),
         :ok <- ensure_name_free(name, modules, taken),
         {:ok, path} <- behaviour_path(name, fam, visible, write_root) do
      rendered = render_behaviour(name, fam)

      case existing_file_status(path, rendered) do
        :foreign -> {:skip, :naming_collision}
        _free_or_ours -> {:ok, Map.merge(fam, %{behaviour: name, path: path, rendered: rendered})}
      end
    end
  end

  defp skip_record(fam, reason),
    do: %{members: fam.members, callbacks: fam.callbacks, reason: reason}

  # Each member maps to the families it joins PLUS a `prior_callbacks`
  # table of the behaviours it already implements (built from BEAM
  # introspection, same shape as ResolveImplTrue). Inserting `@impl` on
  # a freshly extracted callback flips the module into "every callback
  # must be `@impl`-annotated" mode, so the patcher needs that table to
  # annotate the pre-existing implementations too.
  defp implementations(families, surfaces) do
    families
    |> Enum.flat_map(fn fam ->
      Enum.map(fam.members, fn mod ->
        {mod, %{behaviour: fam.behaviour, callbacks: member_callbacks(fam, mod)}}
      end)
    end)
    |> Enum.group_by(fn {mod, _} -> mod end, fn {_, spec} -> spec end)
    |> Map.new(fn {mod, specs} ->
      {mod, %{families: specs, prior_callbacks: prior_callbacks(surfaces[mod])}}
    end)
  end

  # A member implements every required callback plus whichever optional
  # callbacks it actually provides — only those get an `@impl` insertion.
  defp member_callbacks(fam, mod) do
    optional_here =
      fam
      |> Map.get(:optional, [])
      |> Enum.filter(fn {_cb, implementers} -> mod in implementers end)
      |> Enum.map(fn {cb, _implementers} -> cb end)

    fam.callbacks ++ optional_here
  end

  # `{name, arity} => behaviour` for every callback of the behaviours
  # the module already declares — but only those resolving to exactly
  # one behaviour (a callback claimed by two behaviours can't be
  # annotated unambiguously, so it's left out and skipped at the site).
  defp prior_callbacks(nil), do: %{}

  defp prior_callbacks(%{behaviours: behaviours}) do
    behaviours
    |> Enum.flat_map(fn beh -> Enum.map(callbacks_for(beh), &{&1, beh}) end)
    |> Enum.group_by(fn {key, _beh} -> key end, fn {_key, beh} -> beh end)
    |> Enum.reduce(%{}, fn
      {key, [beh]}, acc -> Map.put(acc, key, beh)
      {_key, [_, _ | _]}, acc -> acc
    end)
  end

  # --- naming ---

  # The behaviour lives in the dominant group's sub-namespace
  # (`[app_root | root_path]`): a `get`/`all` family under `ItemTypes.*`
  # → `PositionDb.ItemTypes.GetterBehaviour`. For an accepted bare-root
  # family `root_path` is `[]`, so it lands directly under the app root
  # → `PositionDb.AuthorizerBehaviour`.
  defp behaviour_name(%{root_path: root_path} = fam) do
    case descriptor(fam) do
      {:ok, descriptor} ->
        namespace = [app_root(fam.members) | root_path]
        {:ok, Module.concat(namespace ++ [behaviour_basename(descriptor)])}

      :error ->
        {:skip, :no_clear_name}
    end
  end

  defp app_root(members), do: members |> hd() |> Module.split() |> hd()

  defp behaviour_basename(descriptor) do
    if String.ends_with?(descriptor, "Behaviour"),
      do: descriptor,
      else: descriptor <> "Behaviour"
  end

  defp longest_common_prefix([first | rest]),
    do: Enum.reduce(rest, first, &common_prefix(&2, &1))

  defp common_prefix([h | t1], [h | t2]), do: [h | common_prefix(t1, t2)]
  defp common_prefix(_, _), do: []

  defp descriptor(fam) do
    case common_suffix_tokens(fam.members) do
      [_ | _] = tokens -> {:ok, Enum.join(tokens)}
      [] -> descriptor_from_callbacks(fam.callbacks)
    end
  end

  defp common_suffix_tokens(members) do
    members
    |> Enum.map(fn mod -> mod |> Module.split() |> List.last() |> camel_tokens() end)
    |> Enum.map(&Enum.reverse/1)
    |> longest_common_prefix()
    |> Enum.reverse()
  end

  defp camel_tokens(name), do: Regex.scan(~r/[A-Z][a-z0-9_]*/, name) |> List.flatten()

  # Name the behaviour after its callbacks. One callback → its noun.
  # Several → the most distinctive one (longest name wins; it carries
  # the most domain meaning, and ties break alphabetically for
  # determinism), so a `{classify, transform}` family becomes
  # `Classifier`/`Transformer` rather than going unnamed.
  defp descriptor_from_callbacks(callbacks) do
    case callbacks |> Enum.map(fn {name, _arity} -> name end) |> Enum.uniq() do
      [] ->
        :error

      names ->
        principal = Enum.max_by(names, &{String.length(Atom.to_string(&1)), Atom.to_string(&1)})
        {:ok, principal |> Atom.to_string() |> noun_from_function()}
    end
  end

  # Turn a function name into a readable domain noun rather than a bare
  # verb camelization:
  #
  #   - table irregulars win first (`authorize` → `Authorizer`),
  #   - a verb phrase names itself after its OBJECT, not the verb
  #     (`send_message` → `Message`, `build_position_oz_map` →
  #     `PositionOzMap`, `update_item` → `Item`),
  #   - a lone known verb becomes its agent noun (`render` → `Renderer`,
  #     `preview` → `Previewer`),
  #   - anything not recognized as a verb is camelized as-is
  #     (`changeset` → `Changeset`, `item_row` → `ItemRow`).
  @verb_to_noun %{
    "authorize" => "Authorizer",
    "get" => "Getter",
    "list" => "Lister",
    "render" => "Renderer",
    "parse" => "Parser",
    "encode" => "Encoder",
    "decode" => "Decoder",
    "serialize" => "Serializer",
    "validate" => "Validator",
    "transform" => "Transformer",
    "build" => "Builder",
    "format" => "Formatter",
    "import" => "Importer",
    "export" => "Exporter",
    "fetch" => "Fetcher",
    "resolve" => "Resolver",
    "convert" => "Converter",
    "classify" => "Classifier",
    "translate" => "Translator",
    "compute" => "Calculator",
    "calculate" => "Calculator"
  }

  @known_verbs ~w(build send create update delete get list fetch make compute
                  calculate generate preview render parse encode decode transform
                  resolve convert classify translate import export validate apply
                  prepare assign move regenerate recalculate subscribe change cycle
                  deliver authorize serialize format)

  defp noun_from_function(fun_name) do
    base = fun_name |> String.trim_trailing("?") |> String.trim_trailing("!")

    case Map.fetch(@verb_to_noun, base) do
      {:ok, noun} -> noun
      :error -> base |> derive_noun() |> Macro.camelize()
    end
  end

  defp derive_noun(base) do
    case String.split(base, "_") do
      [single] -> agent_noun(single)
      [verb | [_ | _] = object] -> if verb in @known_verbs, do: Enum.join(object, "_"), else: base
    end
  end

  # Maps a `Semantic` verb bucket to the agent noun it should carry.
  # The classifier generalizes over synonyms the table can't enumerate
  # (`grant`/`permit` → near `:notify`/`:update`, `tokenize` →
  # `:normalize`), so an unrecognized verb still lands a readable suffix.
  @bucket_to_noun %{
    build: "Builder",
    compute: "Calculator",
    extract: "Extractor",
    fetch: "Fetcher",
    filter: "Filter",
    format: "Formatter",
    group: "Grouper",
    normalize: "Normalizer",
    notify: "Notifier",
    update: "Updater",
    validate: "Validator"
  }

  # Agent-noun morphology for a lone verb. A known verb gets plain
  # morphology; an unknown word is offered to the static-embedding
  # classifier (a domain synonym still lands a bucket noun), and only a
  # genuinely opaque name (`:unknown`) stays literal — so we never emit
  # artifacts like `changeseter` for a noun mistaken as a verb.
  defp agent_noun(verb) do
    cond do
      verb in @known_verbs -> morph_agent_noun(verb)
      bucket_noun = semantic_noun(verb) -> bucket_noun
      true -> verb
    end
  end

  defp morph_agent_noun(verb) do
    cond do
      String.ends_with?(verb, "e") -> verb <> "r"
      String.ends_with?(verb, "y") -> String.trim_trailing(verb, "y") <> "ier"
      true -> verb <> "er"
    end
  end

  defp semantic_noun(verb) do
    case Semantic.classify(verb) do
      {:ok, bucket, _score} -> Map.get(@bucket_to_noun, bucket)
      :unknown -> nil
    end
  end

  defp ensure_name_free(name, modules, taken) do
    cond do
      MapSet.member?(taken, name) -> {:skip, :naming_collision}
      name in modules -> {:skip, :naming_collision}
      Code.ensure_loaded?(name) -> {:skip, :naming_collision}
      true -> :ok
    end
  end

  # --- behaviour file ---

  defp behaviour_path(name, fam, visible, write_root) do
    derived = derive_from_layout(name, fam, visible) || derive_from_common_dir(name, fam, visible)
    {:ok, rooted(derived, write_root)}
  end

  # `lib/my_app/items/a.ex` defining `MyApp.Items.A` reveals the source
  # root `lib/`; the behaviour follows the same convention.
  defp derive_from_layout(name, fam, visible) do
    Enum.find_value(fam.members, fn member ->
      path = visible[member].path
      suffix = module_path_suffix(member)

      if String.ends_with?(path, suffix) do
        root = String.slice(path, 0, String.length(path) - String.length(suffix))
        root <> module_path_suffix(name)
      end
    end)
  end

  defp derive_from_common_dir(name, fam, visible) do
    dirs = fam.members |> Enum.map(&Path.dirname(visible[&1].path)) |> Enum.map(&Path.split/1)
    base = (name |> Module.split() |> List.last() |> Macro.underscore()) <> ".ex"
    Path.join(longest_common_prefix(dirs) ++ [base])
  end

  defp module_path_suffix(mod), do: (mod |> inspect() |> Macro.underscore()) <> ".ex"

  defp rooted(path, write_root) do
    case Path.type(path) do
      :absolute -> path
      _ -> Path.join(write_root, path)
    end
  end

  defp existing_file_status(path, rendered) do
    case File.read(path) do
      {:ok, ^rendered} -> :ours
      {:ok, _other} -> :foreign
      {:error, _} -> :free
    end
  end

  defp write_behaviour_file(%{path: path, rendered: rendered}) do
    File.mkdir_p!(Path.dirname(path))

    case File.read(path) do
      {:ok, ^rendered} -> :ok
      _ -> File.write!(path, rendered)
    end
  end

  defp render_behaviour(name, fam) do
    members = Enum.map_join(fam.members, "\n", &"    - `#{inspect(&1)}`")
    callbacks = fam |> callback_lines() |> Enum.map_join("\n\n", &("  " <> &1))

    """
    defmodule #{inspect(name)} do
      @moduledoc \"\"\"
      Shared behaviour extracted from a family of modules with a common
      public API surface.

      Implementations at extraction time:

    #{members}
      \"\"\"

    #{callbacks}#{optional_declaration(fam)}
    end
    """
  end

  # Both required and optional callbacks render as `@callback` lines;
  # optional ones are then listed in an `@optional_callbacks` attribute so
  # implementations may omit them without a warning. Optional specs only
  # consider the members that actually implement the function.
  defp callback_lines(fam) do
    member_info = Map.new(fam.members, &{&1, member_typespecs(&1)})
    optional = Map.get(fam, :optional, [])

    required_lines =
      Enum.map(fam.callbacks, &callback_line(fam.members, member_info, &1))

    optional_lines =
      Enum.map(optional, fn {cb, implementers} ->
        callback_line(implementers, member_info, cb)
      end)

    required_lines ++ optional_lines
  end

  defp callback_line(members, member_info, {name, arity}) do
    case agreed_spec(members, member_info, name, arity) do
      {:ok, spec_string} -> "@callback " <> spec_string
      :none -> "@callback #{name}(#{broad_args(arity)}) :: term()"
    end
  end

  defp optional_declaration(%{optional: [_ | _] = optional}) do
    list = Enum.map_join(optional, ", ", fn {{name, arity}, _mods} -> "#{name}: #{arity}" end)
    "\n\n  @optional_callbacks [#{list}]"
  end

  defp optional_declaration(_fam), do: ""

  defp broad_args(arity), do: List.duplicate("term()", arity) |> Enum.join(", ")

  defp member_typespecs(mod) do
    %{specs: fetch_specs(mod), local_types: fetch_local_types(mod)}
  end

  defp fetch_specs(mod) do
    case Code.Typespec.fetch_specs(mod) do
      {:ok, specs} -> Map.new(specs)
      :error -> %{}
    end
  end

  # `{type_name, arity}` of every type the module declares itself —
  # these are the ones that would dangle if copied into the behaviour
  # module verbatim, so they get qualified back to their origin.
  defp fetch_local_types(mod) do
    case Code.Typespec.fetch_types(mod) do
      {:ok, types} ->
        for {kind, {name, _def, args}} <- types,
            kind in [:type, :opaque],
            into: MapSet.new(),
            do: {name, length(args)}

      :error ->
        MapSet.new()
    end
  end

  # Agreement is checked on the UNqualified form, so two members that
  # express the same shape through their own local type (`attribute()`
  # in each) count as agreeing instead of diverging on the qualifier.
  # Only after agreement do we qualify ONE member's local types back to
  # its origin, so the emitted callback compiles in the behaviour module.
  defp agreed_spec(members, member_info, name, arity) do
    specs =
      Enum.flat_map(members, fn mod ->
        member_info[mod].specs
        |> Map.get({name, arity}, [])
        |> Enum.map(&{mod, &1})
      end)

    case Enum.uniq_by(specs, fn {_mod, spec} -> render_unqualified(name, spec) end) do
      [{origin, spec}] ->
        {:ok, render_qualified(name, spec, origin, member_info[origin].local_types)}

      _ ->
        :none
    end
  end

  # Strip line metadata (it would force the source's line breaks into
  # the single-line `@callback` form). No qualification — used only as
  # the agreement key.
  defp render_unqualified(name, spec) do
    name
    |> Code.Typespec.spec_to_quoted(spec)
    |> Macro.prewalk(&strip_meta/1)
    |> Macro.to_string()
  end

  defp render_qualified(name, spec, origin, local_types) do
    name
    |> Code.Typespec.spec_to_quoted(spec)
    |> Macro.prewalk(&qualify_local_type(&1, origin, local_types))
    |> Macro.to_string()
  end

  # A bare `{tname, meta, args}` whose `{tname, arity}` is one of the
  # origin's own `@type`s becomes `Origin.tname(args)`. Built-ins
  # (`term`, `integer`, …) and already-remote types (`String.t`) are
  # never in `local_types`, so they pass through untouched. The
  # function name node itself (`name/arity` head of the spec) is left
  # alone — it is never a type reference.
  defp qualify_local_type({tname, _meta, args} = node, origin, local_types)
       when is_atom(tname) and is_list(args) do
    if tname != :"::" and MapSet.member?(local_types, {tname, length(args)}) do
      {{:., [], [origin_alias(origin), tname]}, [], args}
    else
      strip_meta(node)
    end
  end

  defp qualify_local_type(node, _origin, _local_types), do: node

  defp origin_alias(origin),
    do: {:__aliases__, [], Module.split(origin) |> Enum.map(&String.to_atom/1)}

  defp strip_meta({node, meta, args}) when is_list(meta), do: {node, [], args}
  defp strip_meta(node), do: node

  # --- source patching ---

  defp collect_modules(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, mod} -> [{mod, body_to_exprs(body)}]
          :error -> []
        end

      _ ->
        []
    end)
  end

  # All @behaviour lines first, then all @impl lines — a module can be
  # member of several families sharing one insertion anchor, and
  # interleaving would push an @impl between two @behaviour attributes.
  defp module_patches({mod, exprs}, impls) do
    case Map.get(impls, mod) do
      nil -> []
      %{families: families, prior_callbacks: prior} -> patches_for_member(families, prior, exprs)
    end
  end

  defp patches_for_member(families, prior_callbacks, exprs) do
    behaviour_inserts = Enum.flat_map(families, &behaviour_insertion(&1.behaviour, exprs))

    new_callbacks = families |> Enum.flat_map(& &1.callbacks) |> Enum.uniq()
    new_impl_inserts = Enum.map(new_callbacks, &{&1, "@impl true"})

    # Adding `@impl` to any callback forces every other callback the
    # module implements to carry `@impl` too. If we introduce the first
    # one, annotate the pre-existing (still-unmarked) implementations
    # with their resolved behaviour to keep the module consistent.
    prior_impl_inserts =
      if new_impl_inserts == [] do
        []
      else
        for {key, behaviour} <- prior_callbacks,
            not Enum.member?(new_callbacks, key),
            do: {key, "@impl #{inspect(behaviour)}"}
      end

    impl_inserts = resolve_impl_inserts(new_impl_inserts ++ prior_impl_inserts, exprs)

    render_insertions(behaviour_inserts ++ impl_inserts, exprs)
  end

  defp behaviour_insertion(behaviour, exprs) do
    if behaviour_declared?(exprs, behaviour) do
      []
    else
      case anchor_index(exprs) do
        nil -> []
        idx -> [{idx, "@behaviour #{inspect(behaviour)}\n"}]
      end
    end
  end

  defp behaviour_declared?(exprs, behaviour) do
    Enum.any?(exprs, fn
      {:@, _, [{:behaviour, _, [arg]}]} -> alias_to_module(arg) == {:ok, behaviour}
      _ -> false
    end)
  end

  # `@behaviour` goes after the moduledoc/use/alias prologue, before the
  # first definition or attribute that follows it.
  defp anchor_index(exprs) do
    Enum.find_index(exprs, fn expr -> not prologue?(expr) end)
  end

  defp prologue?({:@, _, [{:moduledoc, _, _}]}), do: true
  defp prologue?({:@, _, [{:behaviour, _, _}]}), do: true
  defp prologue?({directive, _, _}) when directive in [:use, :alias, :import, :require], do: true
  defp prologue?(_), do: false

  # Map each `{callback_key, impl_text}` to the index of its first
  # clause, drop sites already carrying an `@impl`, and keep one insert
  # per index (a function implementing two callbacks gets one `@impl`).
  defp resolve_impl_inserts(keyed_inserts, exprs) do
    keyed_inserts
    |> Enum.flat_map(fn {key, text} ->
      impl_insert_at(first_clause_index(key, exprs), text, exprs)
    end)
    |> Enum.uniq_by(fn {idx, _text} -> idx end)
  end

  defp impl_insert_at(nil, _text, _exprs), do: []

  defp impl_insert_at(idx, text, exprs),
    do: if(impl_annotated?(exprs, idx), do: [], else: [{idx, text}])

  defp first_clause_index({name, arity}, exprs) do
    Enum.find_index(exprs, fn expr -> {name, arity} in def_keys(expr) end)
  end

  # `@impl` applies to the next definition even with other attributes
  # in between — scan the whole attribute block above the clause.
  defp impl_annotated?(exprs, idx) do
    exprs
    |> Enum.take(idx)
    |> Enum.reverse()
    |> Enum.take_while(&match?({:@, _, _}, &1))
    |> Enum.any?(&match?({:@, _, [{:impl, _, _}]}, &1))
  end

  # Insertions landing on the same node merge into one zero-width patch —
  # Sourceror cannot order two patches anchored at the same position.
  defp render_insertions([], _exprs), do: []

  defp render_insertions(insertions, exprs) do
    insertions
    |> Enum.group_by(fn {idx, _text} -> idx end, fn {_idx, text} -> text end)
    |> Enum.map(fn {idx, texts} ->
      range = exprs |> Enum.at(idx) |> Sourceror.get_range()
      pos = [line: range.start[:line], column: range.start[:column]]
      pad = String.duplicate(" ", range.start[:column] - 1)

      # preserve_indentation: false — we pad ourselves; Sourceror's
      # auto-indent would double the leading whitespace.
      %{
        change: Enum.join(texts, "\n" <> pad) <> "\n" <> pad,
        range: %{start: pos, end: pos},
        preserve_indentation: false
      }
    end)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  # --- engine plumbing ---

  defp plan_modules(opts) do
    case Keyword.get(opts, :modules) do
      nil -> host_app_modules()
      modules -> modules
    end
  end

  defp host_app_modules do
    with true <- Code.ensure_loaded?(Mix.Project),
         app when is_atom(app) and not is_nil(app) <- Mix.Project.config()[:app],
         _ = Application.load(app),
         {:ok, modules} <- :application.get_key(app, :modules) do
      modules
    else
      _ -> []
    end
  end

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
