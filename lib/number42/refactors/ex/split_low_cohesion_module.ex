defmodule Number42.Refactors.Ex.SplitLowCohesionModule do
  @moduledoc """
  Split a low-cohesion "god module" into focused submodules along the
  seams revealed by its internal call-graph community structure.

      # before — one module, two unrelated islands
      defmodule MyApp.Accounts do
        def create_user(a), do: hash_password(a)
        defp hash_password(a), do: a

        def charge_card(c), do: settle(c)
        defp settle(c), do: c
      end

      # after — home module keeps one cluster, the other moves out
      defmodule MyApp.Accounts do
        defdelegate charge_card(c), to: MyApp.Accounts.ChargeCard
        def create_user(a), do: hash_password(a)
        defp hash_password(a), do: a
      end

      defmodule MyApp.Accounts.ChargeCard do
        def charge_card(c), do: settle(c)
        defp settle(c), do: c
      end

  **Detection is the entire problem; the rewrite is mechanical.** A
  wrong seam yields a structurally-wrong (usually still-compiling)
  codebase, which is worse than no split. This refactor therefore
  declines aggressively and only fires when the community structure is
  unambiguous and every false-positive guard passes.

  ## Detection — call-graph community structure

  1. Build the module-local **undirected** call graph: nodes are the
     local `def`/`defp` `{name, arity}` groups; an edge connects two
     functions that call each other (weight = number of call sites,
     summed over both directions). Cohesion is symmetric — two
     functions belong together if they are linked, regardless of who
     calls whom.
  2. Run greedy modularity-maximising community detection
     (`Number42.Refactors.Analysis.CommunityDetection`). Plain connected
     components is too blunt — a single shared helper bridges every
     island into one component. Modularity instead measures intra-
     community density *beyond chance*, so a lone bridge edge between
     two dense clusters does not fuse them.

  ## Thresholds (configurable, justified)

  All three gate the split; defaults are conservative on purpose.

    * `:min_modularity` (default `#{0.3}`) — the partition's modularity
      `Q` must clear this. `Q ≤ 0.3` is the textbook signal of *no*
      significant community structure (Newman): a tangled blob. Below
      it the refactor **declines** rather than impose an arbitrary cut.
    * `:max_cut_ratio` (default `#{0.25}`) — at most this fraction of
      edge weight may cross cluster boundaries. This is the direct
      "the islands barely call across" signal; a high cut ratio means
      the clusters are entangled and the seam is not real.
    * `:min_cluster_size` (default `#{2}`) — every emitted cluster must
      hold at least this many functions. A one-function "cluster" is
      noise, not a module.

  A module must also have at least `:min_module_functions` (default
  `#{6}`) local functions to be considered at all — small modules have
  nothing to split.

  ## False-positive guards (each one declines the whole module)

    * **Shared / orphaned module state.** Module attributes and the
      `%__MODULE__{}` struct are module-scoped. If a function being
      *moved out* references a `@attr` or the self-struct, the reference
      would silently re-resolve to `nil` (still compiles, semantically
      wrong) or break. The safe v1 stance: if **any moved cluster**
      touches module-scoped state, decline the whole split. (Migrating
      the attribute alongside the cluster is future work.)
    * **Behaviours / callbacks.** A module carrying `@behaviour`,
      `@impl`, or implementing framework callbacks cannot be split
      arbitrarily — the callbacks must stay attached to the module the
      behaviour is on. Detected → decline.
    * **Macro-generated functions.** A `use X` may inject `def`s that
      are invisible to the source call-graph, making the graph
      incomplete. Detected → decline (conservative).
    * **Dynamic dispatch.** Any reachable body doing `apply/3` with a
      non-literal target means call sites can't be statically rewritten
      and the graph is incomplete. Detected → decline.
    * **Unfindable public callers.** Every public `def` moved out of the
      home module changes its module path, breaking external callers.
      Call sites are rewritten cross-file; if any caller dispatches via
      `apply(Mod, …)` the rewrite is unsafe → decline.

  ## Where detection gives up (and says so)

  When the modularity is ambiguous, the cut too entangled, or any guard
  trips, the module is **not split**. The plan records every considered
  module under `:declined` with the reason, surfaced by `report/1` for
  `--dry-run`/`--log` review. This is the most important behaviour:
  *fire almost never, but when it fires, be correct.*

  ## Rewrite (the easy half)

  The cluster with the most public functions stays in the original
  ("home") module. Every other cluster becomes a submodule
  `Original.<Name>`, named after that cluster's dominant public
  function (camelised). For each moved cluster:

    * the functions (all clauses + attached specs) are written to a
      fresh file under the standard layout convention;
    * the home module keeps a `defdelegate` for each moved **public**
      function (external callers still resolve `Original.fun`);
    * moved private functions are deleted from the home module;
    * cross-file call sites `Original.fun(...)` are rewritten to
      `Original.Name.fun(...)`.

  ## Default-OFF (opt-in only)

  The single most destructive refactor in the catalogue. Both
  `prepare/1` and `transform/2` are no-ops unless the module's own opts
  carry `enabled: true`:

      configured_modules: [
        {Number42.Refactors.Ex.SplitLowCohesionModule, enabled: true}
      ]

  `--dry-run` is strongly recommended before enabling on real code.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Analysis.CommunityDetection
  alias Number42.Refactors.Analysis.VocabularyClassifier

  @default_min_modularity 0.3
  @default_max_cut_ratio 0.25
  @default_min_cluster_size 2
  @default_min_module_functions 6

  # A module whose god-probability (see `VocabularyClassifier`) is below
  # this is treated as single-concern and left alone. This is what breaks
  # the non-idempotence of issue #258: a freshly-split submodule has a
  # concentrated vocabulary, scores low, and is not re-split — so the
  # fixpoint converges. Default `0.5` (the classifier's decision
  # boundary); raise it to split more conservatively, set to `0.0` to
  # disable the gate.
  @default_vocab_split_threshold 0.5

  @excluded_path_prefixes ["test/", "dev/"]

  @typedoc """
  A planned split for one home module: the home module name, the list of
  clusters that move out, the resolved aliases for body qualification,
  the `{name, arity} => module` index that drives boundary-crossing call
  requalification, and the home-side keys/promotions that index implies.
  """
  @type split :: %{
          home: module(),
          home_path: String.t(),
          aliases: %{atom() => module()},
          moved: [moved_cluster()],
          target_index: %{{atom(), arity()} => module()},
          home_keys: MapSet.t({atom(), arity()}),
          home_promote: MapSet.t({atom(), arity()})
        }

  @type moved_cluster :: %{
          module: module(),
          keys: MapSet.t({atom(), arity()}),
          clauses: [term()],
          public_keys: MapSet.t({atom(), arity()}),
          promote_keys: MapSet.t({atom(), arity()}),
          path: String.t()
        }

  @impl Number42.Refactors.Refactor
  def description, do: "Cross-file: split a low-cohesion god module along call-graph communities"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A module whose internal call-graph splits cleanly into dense,
    barely-connected communities (high modularity, low cut ratio) is a
    god module. The lowest-priority cluster(s) move into submodules and
    the home module keeps `defdelegate` shims; call sites are rewritten.
    Declines on a tangled blob (no community structure), shared module
    state across clusters, behaviours/`@impl`, `use`-injected functions,
    or dynamic `apply`. Default-OFF — the most destructive refactor.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  # Lowest priority in the catalogue: a structural split must run after
  # every body-level rewrite has settled, never before.
  @impl Number42.Refactors.Refactor
  def priority, do: 10

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    if Keyword.get(opts, :enabled, false) do
      Keyword.get(opts, :source_files) |> prepared_for_paths(opts)
    else
      :no_cache
    end
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      Keyword.get(opts, :prepared) |> rewrite_with_plan_or_passthrough(source)
    else
      source
    end
  end

  @doc """
  Build the corpus-wide split plan from `[{path, source}]` tuples.

  Plan shape:

      %{
        splits: %{home_module => split()},
        declined: [%{module:, reason:, modularity: float | nil,
                     clusters: non_neg_integer()}]
      }

  Side effect: writes one new `.ex` file per moved cluster under
  `opts[:write_root]` (defaults to `File.cwd!/0`). Pass `dry_run: true`
  to skip every disk write while still returning the full plan.
  """
  @spec build_plan([{String.t(), String.t()}], keyword()) :: map()
  def build_plan(sources, opts \\ []) do
    write_root = Keyword.get(opts, :write_root, File.cwd!())
    dry_run? = Keyword.get(opts, :dry_run, false)
    thresholds = thresholds(opts)

    relevant = sources |> Enum.reject(fn {path, _src} -> excluded_path?(path) end)
    paths = source_paths(sources)
    all_modules = collect_module_keys(relevant)

    {splits, declined} =
      relevant
      |> Enum.flat_map(&analyze_source(&1, thresholds, write_root, paths))
      |> Enum.split_with(&match?({:split, _}, &1))

    splits =
      splits
      |> Enum.map(fn {:split, split} -> split end)
      |> Enum.filter(&safe_split?(&1, all_modules, relevant))
      |> Map.new(&{&1.home, &1})

    unless dry_run?, do: Enum.each(Map.values(splits), &write_moved_clusters/1)

    %{splits: splits, declined: Enum.map(declined, fn {:declined, d} -> d end)}
  end

  @doc """
  Human-readable report of a plan, for `--dry-run`/`--log` review.

  Lists the modules that were split and, crucially, every module that
  was *considered and declined*, with the reason — the audit trail the
  moduledoc promises.
  """
  @spec report(map()) :: String.t()
  def report(%{splits: splits, declined: declined}) do
    [split_lines(splits), declined_lines(declined)]
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> "no split candidates"
      sections -> Enum.join(sections, "\n\n")
    end
  end

  defp split_lines(splits) when map_size(splits) == 0, do: ""

  defp split_lines(splits) do
    "split modules:\n" <>
      Enum.map_join(splits, "\n", fn {home, split} ->
        moved = Enum.map_join(split.moved, ", ", &inspect(&1.module))
        "  #{inspect(home)} → #{moved}"
      end)
  end

  defp declined_lines([]), do: ""

  defp declined_lines(declined) do
    "considered but declined:\n" <>
      Enum.map_join(declined, "\n", fn d ->
        q = if d.modularity, do: " (Q=#{Float.round(d.modularity, 3)})", else: ""
        "  #{inspect(d.module)}: #{d.reason}#{q}"
      end)
  end

  defp thresholds(opts) do
    %{
      min_modularity: Keyword.get(opts, :min_modularity, @default_min_modularity),
      max_cut_ratio: Keyword.get(opts, :max_cut_ratio, @default_max_cut_ratio),
      min_cluster_size: Keyword.get(opts, :min_cluster_size, @default_min_cluster_size),
      min_module_functions:
        Keyword.get(opts, :min_module_functions, @default_min_module_functions),
      vocab_split_threshold:
        Keyword.get(opts, :vocab_split_threshold, @default_vocab_split_threshold)
    }
  end

  # ── Per-module analysis ──────────────────────────────────────────

  defp analyze_source({path, source}, thresholds, write_root, paths) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.flat_map(&analyze_module(&1, path, thresholds, write_root, paths))

      {:error, _} ->
        []
    end
  end

  defp analyze_module(
         {:defmodule, _, [name_ast, [{_do, body}]]},
         path,
         thresholds,
         write_root,
         paths
       ) do
    case alias_to_module(name_ast) do
      {:ok, mod} ->
        [analyze(mod, body_to_exprs(body), path, thresholds, write_root, paths)]

      :error ->
        []
    end
  end

  defp analyze_module(_, _, _, _, _), do: []

  defp analyze(mod, body_exprs, path, thresholds, write_root, paths) do
    defs = collect_definitions(body_exprs)

    with :ok <- guard_macro_injection(mod, body_exprs),
         :ok <- guard_behaviour(mod, body_exprs),
         :ok <- guard_dynamic_dispatch(mod, defs),
         :ok <- guard_module_size(mod, defs, thresholds),
         {:ok, partition} <- cluster(mod, defs, thresholds),
         {:ok, split} <- plan_split(mod, body_exprs, defs, partition, path, write_root, paths),
         :ok <- guard_shared_state(mod, body_exprs, defs, split) do
      {:split, split}
    end
  end

  # ── False-positive guards ────────────────────────────────────────

  defp guard_macro_injection(mod, body_exprs) do
    if Enum.any?(body_exprs, &match?({:use, _, _}, &1)),
      do: declined(mod, "use X may inject functions invisible to the call-graph"),
      else: :ok
  end

  defp guard_behaviour(mod, body_exprs) do
    cond do
      Enum.any?(body_exprs, &behaviour_attr?/1) ->
        declined(mod, "module implements a @behaviour — callbacks must stay together")

      Enum.any?(body_exprs, &impl_attr?/1) ->
        declined(mod, "module has @impl callbacks — callbacks must stay together")

      true ->
        :ok
    end
  end

  defp guard_dynamic_dispatch(mod, defs) do
    if Enum.any?(defs, &dynamic_dispatch?(&1.calls)),
      do: declined(mod, "dynamic apply/3 — call-graph incomplete, call sites unrewritable"),
      else: :ok
  end

  defp guard_module_size(mod, defs, %{min_module_functions: floor}) do
    if length(defs) < floor,
      do: declined(mod, "too few functions to split (#{length(defs)} < #{floor})"),
      else: :ok
  end

  # Module state — `@attr`s and the `%__MODULE__{}` struct — is
  # module-scoped. Moving a function that reads it into a submodule
  # silently re-resolves the attribute to `nil` (it compiles, but is
  # semantically wrong) or breaks the struct reference. The only safe
  # stance for v1 is: if **any moved cluster** references a module
  # attribute or the self-struct, decline the whole split. (A migrating
  # attribute would need its own machinery; until then, skip — a wrong
  # split is worse than no split.)
  defp guard_shared_state(mod, body_exprs, defs, split) do
    attr_names = module_attr_names(body_exprs)
    moved_def_keys = moved_def_keys(split)
    has_struct? = Enum.any?(body_exprs, &match?({:defstruct, _, _}, &1))

    moved_defs = Enum.filter(defs, &MapSet.member?(moved_def_keys, {&1.name, &1.arity}))

    cond do
      Enum.any?(moved_defs, &references_any_attr?(&1, attr_names)) ->
        declined(mod, "a moved cluster references module-scoped @attr state")

      has_struct? and Enum.any?(moved_defs, &def_references_self_struct?/1) ->
        declined(mod, "a moved cluster references %__MODULE__{} struct state")

      true ->
        :ok
    end
  end

  defp moved_def_keys(split) do
    split.moved
    |> Enum.flat_map(&MapSet.to_list(&1.keys))
    |> MapSet.new()
  end

  defp references_any_attr?(def_info, attr_names) do
    def_info.clauses
    |> Enum.flat_map(&clause_body_asts/1)
    |> Enum.any?(&attr_referenced?(&1, attr_names))
  end

  defp attr_referenced?(ast, attr_names) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:@, _, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) ->
        MapSet.member?(attr_names, name)

      _ ->
        false
    end)
  end

  # ── Clustering + ambiguity gate ──────────────────────────────────

  defp cluster(mod, defs, thresholds) do
    p_god = VocabularyClassifier.god_probability(Enum.map(defs, & &1.clauses))

    if p_god < thresholds.vocab_split_threshold do
      declined(
        mod,
        "single-concern vocabulary: god-probability #{Float.round(p_god, 3)} below split threshold #{thresholds.vocab_split_threshold}"
      )
    else
      cluster_by_communities(mod, defs, thresholds)
    end
  end

  defp cluster_by_communities(mod, defs, thresholds) do
    keys = Enum.map(defs, &{&1.name, &1.arity})
    key_set = MapSet.new(keys)
    edges = build_edges(defs, key_set)

    partition = CommunityDetection.detect(keys, edges)
    q = CommunityDetection.modularity(partition, edges)
    cut = CommunityDetection.cut_ratio(partition, edges)

    sizeable = Enum.filter(partition, &(MapSet.size(&1) >= thresholds.min_cluster_size))

    cond do
      length(partition) < 2 ->
        declined(mod, "no community structure (single cluster)", q)

      q < thresholds.min_modularity ->
        declined(mod, "ambiguous: modularity below threshold", q)

      cut > thresholds.max_cut_ratio ->
        declined(mod, "clusters too entangled: cut ratio #{Float.round(cut, 3)} too high", q)

      length(sizeable) < 2 ->
        declined(mod, "fewer than two clusters meet min size", q)

      true ->
        {:ok, partition}
    end
  end

  # Undirected weighted edges between locally-defined functions. A call
  # from u to a local v contributes weight 1; reciprocal calls and
  # multiplicities accumulate. Edges to names not defined locally
  # (remote-looking) are ignored.
  defp build_edges(defs, key_set) do
    Enum.reduce(defs, %{}, fn d, acc ->
      from = {d.name, d.arity}

      d.calls
      |> Enum.filter(&MapSet.member?(key_set, &1))
      |> Enum.reject(&(&1 == from))
      |> Enum.reduce(acc, fn to, inner ->
        Map.update(inner, normalize_pair(from, to), 1, &(&1 + 1))
      end)
    end)
  end

  defp normalize_pair(a, b) when a <= b, do: {a, b}
  defp normalize_pair(a, b), do: {b, a}

  # ── Split planning ───────────────────────────────────────────────

  defp plan_split(mod, body_exprs, defs, partition, path, write_root, paths) do
    def_index = Map.new(defs, &{{&1.name, &1.arity}, &1})
    aliases = collect_aliases(body_exprs)

    clusters =
      partition
      |> Enum.map(&cluster_info(&1, def_index))
      |> Enum.reject(&(&1.defs == []))

    {home_cluster, moved_clusters} = pick_home(clusters)

    moved =
      moved_clusters
      |> Enum.map(&build_moved_cluster(&1, mod, home_cluster, write_root, paths))

    cond do
      moved == [] ->
        declined(mod, "no movable cluster after home selection")

      not unique_module_names?(moved) ->
        declined(mod, "derived submodule names collide")

      true ->
        finalize_split(mod, path, aliases, def_index, home_cluster, moved)
    end
  end

  # Resolve every private call edge that crosses a cluster boundary
  # (the partition cuts by communication density, not by reachability,
  # so two mutually-calling privates can land in different modules). For
  # each crossing edge the callee is promoted to a public `def` (made
  # remote-callable) and the call site is qualified to the callee's new
  # home. Encode that as a per-module promote set + a global target index
  # the body rewriter consults; decline if an edge can't be requalified.
  defp finalize_split(mod, path, aliases, def_index, home_cluster, moved) do
    target_index = build_target_index(mod, home_cluster, moved)

    case cross_edge_promotions(def_index, target_index, mod) do
      {:error, reason} ->
        declined(mod, reason)

      {:ok, promote} ->
        moved =
          Enum.map(moved, fn cluster ->
            Map.put(cluster, :promote_keys, MapSet.intersection(cluster.keys, promote))
          end)

        {:ok,
         %{
           home: mod,
           home_path: path,
           aliases: aliases,
           moved: moved,
           target_index: target_index,
           home_keys: home_cluster.keys,
           home_promote: MapSet.intersection(home_cluster.keys, promote)
         }}
    end
  end

  # `{name, arity} => module` over every local def: home defs map to the
  # home module, moved defs to their submodule.
  defp build_target_index(mod, home_cluster, moved) do
    home_entries = Enum.map(home_cluster.keys, &{&1, mod})

    moved_entries =
      Enum.flat_map(moved, fn cluster ->
        Enum.map(cluster.keys, &{&1, cluster.module})
      end)

    Map.new(home_entries ++ moved_entries)
  end

  # The set of callee keys reached by at least one boundary-crossing
  # private call. A crossing whose callee can't be statically resolved
  # to a target module aborts the whole split — a wrong requalify is
  # worse than no split.
  defp cross_edge_promotions(def_index, target_index, mod) do
    def_index
    |> Map.values()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn def_info, {:ok, acc} ->
      from_module = Map.fetch!(target_index, {def_info.name, def_info.arity})

      case crossing_callees(def_info, target_index, from_module) do
        {:ok, callees} ->
          {:cont, {:ok, MapSet.union(acc, callees)}}

        :error ->
          {:halt, {:error, "cross-cluster call site cannot be requalified in #{inspect(mod)}"}}
      end
    end)
  end

  defp crossing_callees(def_info, target_index, from_module) do
    def_info.calls
    |> Enum.filter(&Map.has_key?(target_index, &1))
    |> Enum.filter(&(Map.fetch!(target_index, &1) != from_module))
    |> Enum.reduce_while({:ok, MapSet.new()}, fn callee, {:ok, acc} ->
      if requalifiable?(def_info, callee),
        do: {:cont, {:ok, MapSet.put(acc, callee)}},
        else: {:halt, :error}
    end)
  end

  # Every clause body must carry a position for each crossing call so the
  # renderer/patcher can rewrite it. Source built via `Sourceror.parse`
  # always has positions; a synthesised node (no range) would be
  # unrewritable — decline rather than emit a broken call.
  defp requalifiable?(def_info, {name, arity}) do
    def_info.clauses
    |> Enum.flat_map(&clause_body_asts/1)
    |> Enum.all?(&calls_have_positions?(&1, name, arity))
  end

  defp calls_have_positions?(ast, name, arity) do
    ast
    |> Macro.prewalker()
    |> Enum.all?(fn node ->
      if call_node_for?(node, name, arity), do: node_has_position?(node), else: true
    end)
  end

  defp node_has_position?({_, meta, _}), do: Keyword.has_key?(meta, :line)
  defp node_has_position?(_), do: false

  # The three call shapes the requalifier rewrites: a direct call, a pipe
  # right-hand side (implicit first arg → arity+1), and an `&name/arity`
  # capture.
  defp call_node_for?({:&, _, [{:/, _, [{name, _, ctx}, arity]}]}, name, arity)
       when is_atom(ctx) and is_integer(arity),
       do: true

  defp call_node_for?({:|>, _, [_lhs, {name, _, args}]}, name, arity)
       when is_list(args),
       do: length(args) + 1 == arity

  defp call_node_for?({name, _, args}, name, arity) when is_list(args),
    do: length(args) == arity

  defp call_node_for?(_, _, _), do: false

  defp cluster_info(key_set, def_index) do
    cluster_defs =
      key_set
      |> Enum.map(&Map.get(def_index, &1))
      |> Enum.reject(&is_nil/1)

    publics = cluster_defs |> Enum.filter(&(&1.kind == :def))

    %{
      keys: key_set,
      defs: cluster_defs,
      public_keys: publics |> Enum.map(&{&1.name, &1.arity}) |> MapSet.new(),
      public_defs: publics
    }
  end

  # The home cluster keeps the original module name. Pick the cluster
  # with the most public functions (the module's primary API surface);
  # tie-break on total function count, then on a stable key for
  # determinism. Everything else moves out.
  defp pick_home(clusters) do
    home =
      Enum.max_by(clusters, fn c ->
        {MapSet.size(c.public_keys), length(c.defs), -stable_rank(c)}
      end)

    {home, Enum.reject(clusters, &(&1 == home))}
  end

  defp stable_rank(cluster) do
    cluster.keys |> Enum.sort() |> :erlang.phash2()
  end

  defp build_moved_cluster(cluster, home, home_cluster, write_root, paths) do
    name = derive_submodule_name(cluster, home_cluster)
    submodule = Module.concat(home, name)

    %{
      module: submodule,
      keys: cluster.keys,
      public_keys: cluster.public_keys,
      clauses: cluster.defs |> Enum.sort_by(& &1.name) |> Enum.flat_map(& &1.clauses),
      path: shared_module_path(submodule, write_root, paths)
    }
  end

  # Submodule name from the cluster's dominant public function (most
  # local edges), camelised. Falls back to the dominant function of any
  # kind, then to a hash-stable `PartN`. Singular function verbs make
  # decent module names (`charge_card` → `ChargeCard`).
  defp derive_submodule_name(cluster, _home_cluster) do
    fallback = "Part#{rem(stable_rank(cluster), 1000)}"
    pool = if cluster.public_defs != [], do: cluster.public_defs, else: cluster.defs

    pool
    |> Enum.sort_by(&{-MapSet.size(callees_within(&1, cluster.keys)), &1.name})
    |> List.first()
    |> case do
      nil -> fallback
      d -> module_name_from(d.name, fallback)
    end
  end

  # Predicate/bang names (`same_outer_shape?`, `valid!`) and operator
  # names carry punctuation that is illegal in a module alias, so
  # `Macro.camelize` would yield e.g. `SameOuterShape?` and the emitted
  # `defmodule` would fail to compile. Strip every non-alias character
  # first; if nothing usable survives, fall back to the hash-stable name.
  defp module_name_from(fun_name, fallback) do
    stripped = fun_name |> Atom.to_string() |> String.replace(~r/[^A-Za-z0-9_]/, "")

    case Macro.camelize(stripped) do
      "" -> fallback
      camelized -> camelized
    end
  end

  defp callees_within(def_info, keys) do
    def_info.calls |> Enum.filter(&MapSet.member?(keys, &1)) |> MapSet.new()
  end

  defp unique_module_names?(moved) do
    names = Enum.map(moved, & &1.module)
    length(names) == length(Enum.uniq(names))
  end

  # ── Safety preconditions (corpus-level) ──────────────────────────

  defp safe_split?(split, all_modules, sources) do
    with :ok <- no_target_clash(split, all_modules),
         :ok <- no_dynamic_callers(split, sources) do
      true
    else
      _ -> false
    end
  end

  # A derived submodule must not already exist in the corpus — we never
  # overwrite a real module.
  defp no_target_clash(split, all_modules) do
    if Enum.any?(split.moved, &MapSet.member?(all_modules, &1.module)),
      do: :unsafe,
      else: :ok
  end

  # Any caller dispatching to a moved public function via `apply(Home,
  # …)` can't be rewritten statically — abort the whole split.
  defp no_dynamic_callers(split, sources) do
    moved_publics =
      split.moved
      |> Enum.flat_map(&MapSet.to_list(&1.public_keys))
      |> MapSet.new()

    if Enum.any?(sources, fn {_p, src} -> apply_targets?(src, split.home, moved_publics) end),
      do: :unsafe,
      else: :ok
  end

  defp apply_targets?(source, home, moved_publics) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.any?(&apply_node_targets?(&1, home, moved_publics))

      {:error, _} ->
        false
    end
  end

  defp apply_node_targets?({:apply, _, [mod_ast, fn_ast, _args]}, home, moved_publics),
    do: apply_match?(mod_ast, fn_ast, home, moved_publics)

  defp apply_node_targets?(
         {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [mod_ast, fn_ast, _args]},
         home,
         moved_publics
       ),
       do: apply_match?(mod_ast, fn_ast, home, moved_publics)

  defp apply_node_targets?(_, _, _), do: false

  defp apply_match?(mod_ast, fn_ast, home, moved_publics) do
    case alias_to_module(mod_ast) do
      {:ok, ^home} -> fn_name_in?(fn_ast, moved_publics)
      _ -> false
    end
  end

  # A literal `:name` matches when any moved public has that name; a
  # non-literal name is conservatively treated as a possible match.
  defp fn_name_in?({:__block__, _, [atom]}, moved) when is_atom(atom), do: name_in?(atom, moved)
  defp fn_name_in?(atom, moved) when is_atom(atom), do: name_in?(atom, moved)
  defp fn_name_in?(_, _), do: true

  defp name_in?(name, moved), do: Enum.any?(moved, fn {n, _a} -> n == name end)

  # ── Disk side-effect: write moved clusters ───────────────────────

  defp write_moved_clusters(split) do
    Enum.each(split.moved, fn cluster ->
      unless File.exists?(cluster.path) do
        File.mkdir_p!(Path.dirname(cluster.path))
        File.write!(cluster.path, render_module(cluster, split))
      end
    end)
  end

  defp render_module(cluster, split) do
    body =
      cluster.clauses
      |> Enum.map(&promote_clause(&1, cluster.promote_keys))
      |> Enum.map(&requalify_clause(&1, cluster.module, split.target_index))
      |> Enum.map(&qualify_aliases(&1, split.aliases))
      |> Enum.map_join("\n\n", &Sourceror.to_string/1)

    """
    defmodule #{inspect(cluster.module)} do
    #{indent(body, "  ")}
    end
    """
  end

  # A boundary-crossing private callee is published so callers in other
  # modules can reach it; intra-cluster privates keep `defp`.
  defp promote_clause({:defp, meta, args} = clause, promote_keys) do
    if MapSet.member?(promote_keys, clause_key(clause)),
      do: {:def, meta, args},
      else: clause
  end

  defp promote_clause(clause, _promote_keys), do: clause

  # Rewrite every local call whose callee lives in a different module to
  # `Target.callee(...)`; intra-module calls stay bare. Pipe right-hand
  # sides carry an implicit first arg (`x |> f(y)` is `f/2`), so they are
  # collected up front and arity-corrected — mirroring `collect_calls`.
  defp requalify_clause(clause, self_module, target_index) do
    pipe_rhs = pipe_rhs_nodes(clause)

    Macro.prewalk(clause, fn node ->
      requalify_call(node, self_module, target_index, pipe_rhs)
    end)
  end

  defp pipe_rhs_nodes(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:|>, _, [_lhs, rhs]} -> [rhs]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp requalify_call(
         {:&, meta, [{:/, sl, [{name, nmeta, ctx}, arity]}]} = node,
         self,
         index,
         _pipe
       )
       when is_atom(name) and is_atom(ctx) and is_integer(arity) do
    case cross_target({name, arity}, self, index) do
      nil ->
        node

      target ->
        {:&, meta, [{:/, sl, [{{:., nmeta, [alias_ast(target), name]}, nmeta, []}, arity]}]}
    end
  end

  defp requalify_call({:|>, meta, [lhs, {name, rmeta, args}]} = node, self, index, _pipe)
       when is_atom(name) and is_list(args) do
    case cross_target({name, length(args) + 1}, self, index) do
      nil -> node
      target -> {:|>, meta, [lhs, {{:., rmeta, [alias_ast(target), name]}, rmeta, args}]}
    end
  end

  defp requalify_call({name, meta, args} = node, self, index, pipe_rhs)
       when is_atom(name) and is_list(args) do
    if MapSet.member?(pipe_rhs, node) do
      node
    else
      case cross_target({name, length(args)}, self, index) do
        nil -> node
        target -> {{:., meta, [alias_ast(target), name]}, meta, args}
      end
    end
  end

  defp requalify_call(node, _self, _index, _pipe), do: node

  defp cross_target(key, self_module, target_index) do
    case Map.get(target_index, key) do
      nil -> nil
      ^self_module -> nil
      target -> target
    end
  end

  defp alias_ast(module) do
    {:__aliases__, [], module |> Module.split() |> Enum.map(&String.to_atom/1)}
  end

  defp clause_key({kind, _, [head | _]}) when kind in [:def, :defp] do
    case strip_when(head) do
      {name, _, args} when is_atom(name) and is_list(args) -> {name, length(args)}
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> {name, 0}
      _ -> nil
    end
  end

  defp clause_key(_), do: nil

  # ── transform/2: apply one source ────────────────────────────────

  defp rewrite_with_plan_or_passthrough(nil, source), do: source

  defp rewrite_with_plan_or_passthrough(%{splits: splits}, source) when map_size(splits) == 0,
    do: source

  defp rewrite_with_plan_or_passthrough(%{splits: splits}, source), do: apply_plan(splits, source)

  defp apply_plan(splits, source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> ast |> patches_for_source(splits) |> patch_or_passthrough(source)
      {:error, _} -> source
    end
  end

  defp patches_for_source(ast, splits) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        patches_for_defmodule(name_ast, body_to_exprs(body), splits)

      _ ->
        []
    end)
  end

  defp patches_for_defmodule(name_ast, body_exprs, splits) do
    case alias_to_module(name_ast) do
      {:ok, mod} ->
        home_patches(Map.get(splits, mod), body_exprs) ++
          caller_patches(mod, body_exprs, splits)

      :error ->
        []
    end
  end

  # Home module: delete moved private clauses, replace each moved public
  # function with a `defdelegate` to its new submodule, and requalify /
  # promote the functions that stay behind but participate in a
  # boundary-crossing call.
  defp home_patches(nil, _body_exprs), do: []

  defp home_patches(split, body_exprs) do
    Enum.flat_map(split.moved, &cluster_home_patches(&1, body_exprs)) ++
      home_keep_patches(split, body_exprs)
  end

  # Functions that remain in the home module but either are called from a
  # moved cluster (promote `defp` → `def`) or call into one (qualify the
  # call site). Re-render the whole clause group so promote + qualify
  # happen in one consistent patch.
  defp home_keep_patches(split, body_exprs) do
    split.home_keys
    |> Enum.flat_map(fn {name, arity} ->
      clauses = Enum.filter(body_exprs, &clause_matches?(&1, name, arity))
      home_keep_patch(clauses, split)
    end)
  end

  defp home_keep_patch([], _split), do: []

  defp home_keep_patch([first | _] = clauses, split) do
    rewritten =
      clauses
      |> Enum.map(&promote_clause(&1, split.home_promote))
      |> Enum.map(&requalify_clause(&1, split.home, split.target_index))

    if rewritten == clauses do
      []
    else
      replacement = Enum.map_join(rewritten, "\n\n", &Sourceror.to_string/1)
      group_patch(first, List.last(clauses), replacement)
    end
  end

  defp cluster_home_patches(cluster, body_exprs) do
    cluster.keys
    |> Enum.flat_map(fn {name, arity} ->
      clauses = body_exprs |> Enum.filter(&clause_matches?(&1, name, arity))
      function_home_patch(clauses, name, arity, cluster)
    end)
  end

  defp function_home_patch([], _name, _arity, _cluster), do: []

  defp function_home_patch([first | _] = clauses, name, arity, cluster) do
    last = List.last(clauses)

    replacement =
      if MapSet.member?(cluster.public_keys, {name, arity}) do
        render_delegate(name, arity, cluster.module)
      else
        ""
      end

    group_patch(first, last, replacement)
  end

  # Caller modules: rewrite `Home.fun(...)` → `Submodule.fun(...)` for
  # every moved public function. The home module itself only keeps
  # delegates (which already point at the submodule) so it never needs
  # a call rewrite for its own moved functions.
  defp caller_patches(current_mod, body_exprs, splits) do
    aliases = collect_aliases(body_exprs)

    splits
    |> Map.values()
    |> Enum.reject(&(&1.home == current_mod))
    |> Enum.flat_map(&caller_patches_for_split(&1, body_exprs, aliases))
  end

  defp caller_patches_for_split(split, body_exprs, aliases) do
    targets = moved_target_index(split)

    body_exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(&call_node_patch(&1, split.home, targets, aliases))
  end

  defp moved_target_index(split) do
    for cluster <- split.moved,
        {name, arity} <- cluster.public_keys,
        into: %{},
        do: {{name, arity}, cluster.module}
  end

  defp call_node_patch({{:., _, [mod_ast, fun]}, _, args}, home, targets, aliases)
       when is_atom(fun) and is_list(args) do
    with target when not is_nil(target) <- Map.get(targets, {fun, length(args)}),
         ^home <- resolved_module(mod_ast, aliases) do
      replace_call_target(mod_ast, target)
    else
      _ -> []
    end
  end

  defp call_node_patch(_, _, _, _), do: []

  defp resolved_module(mod_ast, aliases) do
    case resolve_alias(mod_ast, aliases) do
      [mod] -> mod
      _ -> nil
    end
  end

  defp replace_call_target(mod_ast, target) do
    case Sourceror.get_range(mod_ast) do
      %{end: end_pos, start: start_pos} ->
        [%{change: inspect(target), range: %{end: end_pos, start: start_pos}}]

      _ ->
        []
    end
  end

  defp render_delegate(name, arity, target) do
    args = delegate_args(name, arity)
    "defdelegate #{name}(#{Enum.join(args, ", ")}), to: #{inspect(target)}"
  end

  defp delegate_args(_name, 0), do: []
  defp delegate_args(name, arity), do: 0..(arity - 1)//1 |> Enum.map(&:"#{name_stub(name)}_#{&1}")
  defp name_stub(name), do: name |> Atom.to_string() |> String.replace(~r/[?!]/, "")

  # ── Module / state analysis ──────────────────────────────────────

  defp module_attr_names(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {:@, _, [{name, _, [_value]}]}
      when is_atom(name) and name not in [:moduledoc, :doc, :spec, :type, :typep, :opaque] ->
        [name]

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp def_references_self_struct?(def_info) do
    def_info.clauses
    |> Enum.any?(&references_self_struct?/1)
  end

  defp references_self_struct?(clause) do
    clause
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:%, _, [{:__MODULE__, _, ctx}, _]} when is_atom(ctx) -> true
      _ -> false
    end)
  end

  defp behaviour_attr?({:@, _, [{:behaviour, _, _}]}), do: true
  defp behaviour_attr?({:@, _, [{:behavior, _, _}]}), do: true
  defp behaviour_attr?(_), do: false

  defp impl_attr?({:@, _, [{:impl, _, _}]}), do: true
  defp impl_attr?(_), do: false

  # ── Generic helpers ──────────────────────────────────────────────

  defp declined(mod, reason),
    do: {:declined, %{module: mod, reason: reason, modularity: nil, clusters: 0}}

  defp declined(mod, reason, q),
    do: {:declined, %{module: mod, reason: reason, modularity: q, clusters: 0}}

  defp clause_matches?({kind, _, [head | _]}, name, arity) when kind in [:def, :defp] do
    case strip_when(head) do
      {^name, _, args} when is_list(args) and length(args) == arity -> true
      {^name, _, nil} when arity == 0 -> true
      _ -> false
    end
  end

  defp clause_matches?(_, _, _), do: false

  defp clause_body_asts({kind, _, [_head, body_kw]})
       when kind in [:def, :defp] and is_list(body_kw),
       do: Keyword.values(body_kw)

  defp clause_body_asts(_), do: []

  defp collect_aliases(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {:alias, _, [{:__aliases__, _, parts}]} ->
        [{List.last(parts), Module.concat(parts)}]

      {:alias, _, [{:__aliases__, _, parts}, opts]} ->
        short = alias_as(opts) || List.last(parts)
        [{short, Module.concat(parts)}]

      {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, subs}]} ->
        Enum.map(subs, fn {:__aliases__, _, sub} ->
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

  defp unwrap_keyword([{_, _} | _] = kw), do: kw
  defp unwrap_keyword(_), do: []

  defp resolve_alias({:__aliases__, _, [single]}, aliases) when is_atom(single),
    do: [Map.get(aliases, single, Module.concat([single]))]

  defp resolve_alias({:__aliases__, _, parts}, _aliases) when is_list(parts),
    do: [Module.concat(parts)]

  defp resolve_alias(_, _), do: []

  defp qualify_aliases(ast, aliases) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, [single]} = node when is_atom(single) ->
        case Map.get(aliases, single) do
          nil -> node
          full -> {:__aliases__, meta, full |> Module.split() |> Enum.map(&String.to_atom/1)}
        end

      other ->
        other
    end)
  end

  defp collect_module_keys(sources) do
    sources
    |> Enum.flat_map(fn {_path, source} ->
      case Sourceror.parse_string(source) do
        {:ok, ast} -> modules_in_ast(ast)
        {:error, _} -> []
      end
    end)
    |> MapSet.new()
  end

  defp modules_in_ast(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, _]} ->
        case alias_to_module(name_ast) do
          {:ok, mod} -> [mod]
          :error -> []
        end

      _ ->
        []
    end)
  end

  defp group_patch(first_node, last_node, replacement) do
    with %{start: start_pos} <- Sourceror.get_range(first_node),
         %{end: end_pos} <- Sourceror.get_range(last_node) do
      [%{change: replacement, range: %{end: end_pos, start: start_pos}}]
    else
      _ -> []
    end
  end

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

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp excluded_path?(path) do
    normalized = String.trim_leading(path, "./")
    @excluded_path_prefixes |> Enum.any?(&String.starts_with?(normalized, &1))
  end

  defp source_paths(sources), do: Enum.map(sources, fn {path, _src} -> path end)

  # ── prepare/1 wiring ─────────────────────────────────────────────

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
