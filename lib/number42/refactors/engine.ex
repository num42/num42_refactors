defmodule Number42.Refactors.Engine do
  @moduledoc """
  Pipeline engine that applies every `Number42.Refactors.Refactor`
  implementation to a source string.

  Pure library — no I/O, no Mix coupling. The Mix task layer
  (`Mix.Tasks.Refactor`) is responsible for reading/writing files and
  for triggering an external `mix format` pass when needed.

  Refactors are applied in priority order (higher first), with ties
  broken alphabetically for determinism. Each refactor receives the
  output of the previous one. The pipeline is run in a fixpoint loop
  (capped to `@max_passes`) because refactors can feed each other —
  e.g. `MultiAliasExpand` produces single aliases that then become
  input for `AliasOrder`.

  A refactor's priority comes from its `priority/0` callback (default
  `100` when not implemented). The `.refactor.exs` config can
  override it per module via `configured_modules: [{Mod, priority: N}]`
  — config wins over the module default.

  When at least one applied refactor has `reformat_after?/0 == true`,
  the engine sets `reformat_triggered?: true` in the result. The Mix
  task layer reacts to that flag by running `mix format` on the
  affected files — that pass uses the project's `.formatter.exs`
  (with `import_deps: [:phoenix]`, plugins, etc.), which a bare
  `Code.format_string!/2` call would not.
  """

  alias Number42.Refactors.Detection
  alias Number42.Refactors.Detection.Finding

  @max_passes 5

  @type opts :: [
          only_modules: [module()],
          skipped_modules: [module()],
          configured_modules: [{module(), keyword()}]
        ]

  @typedoc """
  One entry per refactor application that actually changed the source.

  `before` and `after` are the source strings *immediately around* this
  module's pass. They're useful for logging a per-refactor diff in
  `mix refactor --log`. The same module can appear multiple times if
  the fixpoint loop runs more than once.
  """
  @type applied :: %{after: String.t(), before: String.t(), module: module()}

  @type result :: %{
          applied: [applied()],
          changed?: boolean(),
          reformat_triggered?: boolean(),
          source: String.t()
        }

  @doc """
  Apply a single refactor module to a source string with the given
  per-module opts (looked up against the `configured_modules` list).

  Returns the rewritten source. Idempotent for refactors that have
  already converged.
  """
  @spec apply_one(module(), String.t(), opts()) :: String.t()
  def apply_one(module, source, opts \\ []) do
    module_opts = build_module_opts(module, opts)
    apply_refactor(module, source, with_prepared(module, module_opts))
  end

  @doc """
  Run **detection only** over a corpus: report findings, change nothing.

  This is the standalone Detection layer (see
  `Number42.Refactors.Detection`) driven across every pipeline refactor
  that declares a `detector/0`. No `transform/2` is invoked, no file is
  written, no plan is built — the result is a diagnostic.

  Refactors without a detector are skipped rather than guessed at; their
  candidate-finding still lives inside `transform/2` and there is no way
  to reach it without rewriting. `detected_modules/1` reports which
  refactors this mode can actually see.

  Returns findings sorted by `{path, line, refactor}` so output is stable
  across runs, which is what makes it usable in CI.
  """
  @spec detect(nil | [Path.t()], opts()) :: [Finding.t()]
  def detect(paths, opts \\ []) do
    sources = paths |> corpus_sources() |> Enum.sort_by(fn {path, _source} -> path end)

    opts
    |> detected_modules()
    |> Enum.flat_map(fn module ->
      Detection.run(module.detector(), sources, build_module_opts(module, opts))
    end)
    |> Enum.sort_by(&{&1.path || "", &1.line || 0, &1.refactor})
  end

  @doc """
  The pipeline refactors that expose a runnable detector.

  A refactor qualifies when it implements the optional `detector/0`
  callback and the named module implements the `Detection` behaviour.
  Everything else is invisible to `detect/2` — deliberately, since
  inventing a detector for a refactor whose candidate-finding is still
  fused into `transform/2` would mean re-implementing its gate.
  """
  @spec detected_modules(opts()) :: [module()]
  def detected_modules(opts \\ []) do
    opts
    |> pipeline_modules()
    |> Enum.filter(fn module ->
      Code.ensure_loaded?(module) and function_exported?(module, :detector, 0) and
        Detection.detector?(module.detector())
    end)
  end

  @doc """
  The resolved, ordered module list for the given opts, after `:only_modules`
  and `:skipped_modules` filtering.

  Used by `mix refactor --step-by-step` to drive a refactor-by-refactor loop
  externally, without going through the per-file fixpoint.
  """
  @spec pipeline_modules(opts()) :: [module()]
  def pipeline_modules(opts \\ []) do
    only = Keyword.get(opts, :only_modules, [])
    skipped = Keyword.get(opts, :skipped_modules, [])
    configured = Keyword.get(opts, :configured_modules, [])

    refactors()
    |> filter_only(only)
    |> Enum.reject(&(&1 in skipped))
    |> sort_by_priority(configured)
  end

  @doc """
  All refactor modules wired into the pipeline.

  Discovered by reading the loaded modules of the `:number42_refactors`
  application and keeping only those whose `:is_refactor` persistent
  attribute is `true` (set by `use Number42.Refactors.Refactor`). Sorted
  alphabetically as a stable base order — `pipeline_modules/1` re-sorts
  by priority before applying.
  """
  def refactors do
    Application.load(:number42_refactors)

    case :application.get_key(:number42_refactors, :modules) do
      {:ok, modules} -> modules |> Enum.filter(&refactor?/1) |> Enum.sort()
      :undefined -> []
    end
  end

  @doc """
  Whether the given module declares `reformat_after?/0 == true`.
  Mix task uses this to know if the per-file `mix format` follow-up
  needs to run.
  """
  @spec reformat_after_module?(module()) :: boolean()
  def reformat_after_module?(module), do: reformat_after?(module)

  @doc """
  Run the refactor pipeline on a source string.

  Returns a `t:result/0` map carrying the rewritten source, two flags
  the caller can act on (anything changed at all; any refactor with
  `reformat_after?/0 == true` fired), and a list of every refactor
  application that actually altered the source — for `--log` output.
  """
  @spec run(String.t(), opts()) :: result()
  def run(source, opts \\ []) do
    modules = pipeline_modules(opts)

    configured =
      modules
      |> Enum.map(fn module ->
        {module, with_prepared(module, build_module_opts(module, opts))}
      end)

    {final_source, reformat?, applied_rev} =
      run_fixpoint(modules, configured, source, @max_passes, false, [])

    %{
      applied: applied_rev |> Enum.reverse(),
      changed?: final_source != source,
      reformat_triggered?: reformat?,
      source: final_source
    }
  end

  defp apply_refactor(module, source, opts) do
    cond do
      skip_for_source?(opts, source) ->
        source

      function_exported?(module, :transform, 2) ->
        module.transform(source, opts)

      true ->
        raise """
        #{inspect(module)} is registered as a refactor but does not
        implement transform/2.
        """
    end
  end

  defp build_module_opts(module, opts) do
    configured = Keyword.get(opts, :configured_modules, [])
    dry_run? = Keyword.get(opts, :dry_run, false)
    project_config = Keyword.get(opts, :project_config, %{})

    configured
    |> Keyword.get(module, [])
    |> Keyword.put(:dry_run, dry_run?)
    |> Keyword.put(:project_config, project_config)
  end

  defp filter_only(modules, []), do: modules
  defp filter_only(modules, only), do: modules |> Enum.filter(&(&1 in only))

  defp skip_for_source?(opts, source),
    do: Keyword.get(opts, :skip_in_modules, []) |> skip_for_source_get(source)

  defp sort_by_priority(modules, configured),
    do: modules |> Enum.sort_by(&(-priority_for(&1, configured)))

  defp source_defines_module?(source, module) when is_atom(module) do
    needle = "defmodule " <> trim_elixir_prefix(Atom.to_string(module))
    String.contains?(source, needle)
  end

  defp trim_elixir_prefix("Elixir." <> rest), do: rest
  defp trim_elixir_prefix(other), do: other

  # Per-module priority resolution. Config wins, module callback is the
  # fallback, default is 100.
  @default_priority 100
  @doc """
  Drop every `:persistent_term` plan cached by `with_prepared/2`.

  Useful between refactor modules in step-by-step mode so each module's
  `prepare/1` re-reads the current disk state instead of operating on
  the snapshot taken before the previous module ran.

  Cheap: walks `:persistent_term.get/0` once and erases only entries
  with our `{Engine, :prepared, _, _}` shape.
  """
  @spec invalidate_prepared_cache() :: :ok
  def invalidate_prepared_cache do
    :persistent_term.get()
    |> Enum.each(fn
      {{__MODULE__, :prepared, _module, _opts} = key, _value} ->
        :persistent_term.erase(key)

      {{__MODULE__, :corpus, _paths} = key, _value} ->
        :persistent_term.erase(key)

      _ ->
        :ok
    end)
  end

  @doc """
  Read and parse the corpus once per run, shared across every
  `prepare/1` that needs project-wide context.

  Every cross-file refactor builds its plan from the whole input set, and
  each one used to do its own `File.read!` plus `Sourceror.parse_string`
  over every path. With ~25 such refactors the corpus was parsed ~25
  times per run, and since Sourceror carries comments and byte ranges it
  is roughly an order of magnitude costlier than a plain quoted-form
  parse — so that repetition dominated the wall clock on a large project
  while per-file work stayed sub-second (#421).

  Returns `%{path => {source, ast_or_nil}}`. A path that cannot be read
  is omitted; a path that fails to parse is present with `nil` for the
  AST, so a caller can still see its source without re-reading it.

  ## Cache lifetime — the correctness constraint

  Cross-file refactors *write* files, and step-by-step mode rewrites
  between modules. A corpus snapshot that outlived a write would make a
  later refactor plan against pre-rewrite source: silently wrong output,
  not a crash. The cache therefore lives under the same
  `:persistent_term` sweep as the prepared-plan cache and is dropped by
  the same `invalidate_prepared_cache/0` call — the two lifetimes are
  identical by construction rather than by convention.
  """
  @spec corpus(nil | [Path.t()]) :: %{optional(Path.t()) => {String.t(), Macro.t() | nil}}
  def corpus(nil), do: %{}

  def corpus(paths) when is_list(paths) do
    key = {__MODULE__, :corpus, paths}

    case :persistent_term.get(key, :__miss__) do
      :__miss__ ->
        result = read_corpus(paths)
        :persistent_term.put(key, result)
        result

      cached ->
        cached
    end
  end

  @doc """
  Corpus sources only, as `%{path => source}`.

  For refactors that need the text but not the AST; still served from the
  one shared read, so it costs nothing extra beyond the first call.
  """
  @spec corpus_sources(nil | [Path.t()]) :: %{optional(Path.t()) => String.t()}
  def corpus_sources(paths) do
    paths |> corpus() |> Map.new(fn {path, {source, _ast}} -> {path, source} end)
  end

  defp read_corpus(paths) do
    paths
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn path, acc ->
      case File.read(path) do
        {:ok, source} -> Map.put(acc, path, {source, parse_or_nil(source)})
        {:error, _} -> acc
      end
    end)
  end

  defp parse_or_nil(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> ast
      {:error, _} -> nil
    end
  end

  defp prepared_for(module, opts) do
    key = {__MODULE__, :prepared, module, opts}

    case :persistent_term.get(key, :__miss__) do
      :__miss__ ->
        result = module.prepare(opts)
        :persistent_term.put(key, result)
        result

      cached ->
        cached
    end
  end

  defp priority_for(module, configured) do
    case configured |> Keyword.get(module, []) |> Keyword.fetch(:priority) do
      {:ok, value} when is_integer(value) ->
        value

      _ ->
        if Code.ensure_loaded?(module) and function_exported?(module, :priority, 0) do
          module.priority()
        else
          @default_priority
        end
    end
  end

  defp refactor?(module) when is_atom(module) do
    Code.ensure_loaded(module) |> refactor_ensure_loaded(module)
  end

  defp refactor_ensure_loaded({:module, _}, module),
    do:
      module.__info__(:attributes)
      |> Keyword.get_values(:is_refactor)
      |> List.flatten()
      |> Enum.any?(&(&1 == true))

  defp refactor_ensure_loaded(_, _module), do: false

  defp reformat_after?(module),
    do: function_exported?(module, :reformat_after?, 0) and module.reformat_after?()

  defp run_fixpoint(_modules, _configured, source, 0, reformat?, applied),
    do: {source, reformat?, applied}

  defp run_fixpoint(modules, configured, source, passes_left, reformat?, applied) do
    {new_source, reformat_now?, applied_after} =
      run_pass(modules, configured, {source, reformat?, applied})

    if new_source == source do
      {new_source, reformat_now?, applied_after}
    else
      run_fixpoint(modules, configured, new_source, passes_left - 1, reformat_now?, applied_after)
    end
  end

  # One fixpoint pass. Walks the priority-sorted modules, batching
  # consecutive parse-share-capable refactors (those implementing
  # `patches/3`) into a single parse + single render — but ONLY when their
  # patch ranges are pairwise disjoint, which makes the shared render
  # byte-identical to running them sequentially. Anything else (non-capable
  # module, range overlap, parse error) falls back to the per-module
  # `transform/2` path. Per-module `--log` entries are preserved exactly.
  defp run_pass(modules, configured, state) do
    modules
    |> chunk_shareable(configured)
    |> Enum.reduce(state, fn
      {:shared, batch}, acc -> apply_shared_batch(batch, configured, acc)
      {:solo, module}, acc -> apply_solo(module, configured, acc)
    end)
  end

  # Group the module list into {:shared, [m...]} runs of consecutive
  # parse-share-capable modules and {:solo, m} for the rest, preserving order.
  defp chunk_shareable(modules, configured) do
    modules
    |> Enum.chunk_by(&shareable?(&1, configured))
    |> Enum.flat_map(fn
      [first | _] = group ->
        if shareable?(first, configured),
          do: [{:shared, group}],
          else: Enum.map(group, &{:solo, &1})
    end)
  end

  defp shareable?(module, _configured), do: function_exported?(module, :patches, 3)

  defp apply_solo(module, configured, {acc, needs_reformat?, log}) do
    module_opts = Keyword.get(configured, module, [])
    rewritten = apply_refactor(module, acc, module_opts)
    record(module, acc, rewritten, needs_reformat?, log)
  end

  # Parse once, ask every batch module for its patches against the SAME ast,
  # render once iff all ranges are pairwise disjoint. Otherwise fall back to
  # running the whole batch sequentially (still correct, no speedup).
  defp apply_shared_batch([single], configured, state),
    do: apply_solo(single, configured, state)

  defp apply_shared_batch(batch, configured, {acc, needs_reformat?, log} = state) do
    case Sourceror.parse_string(acc) do
      {:ok, ast} ->
        per_module =
          Enum.map(batch, fn module ->
            opts = Keyword.get(configured, module, [])

            if skip_for_source?(opts, acc),
              do: {module, []},
              else: {module, module.patches(ast, acc, opts)}
          end)

        all_patches = Enum.flat_map(per_module, fn {_m, ps} -> ps end)

        if disjoint?(all_patches) do
          render_shared(per_module, acc, needs_reformat?, log)
        else
          batch_sequential(batch, configured, state)
        end

      {:error, _} ->
        batch_sequential(batch, configured, state)
    end
  end

  # Disjoint case: one render for the whole batch, but per-module log entries
  # computed from each module's own patches so `--log` stays sequential-faithful.
  defp render_shared(per_module, source, needs_reformat?, log) do
    log_after =
      Enum.reduce(per_module, {needs_reformat?, log}, fn {module, patches}, {nr?, lg} ->
        case patches do
          [] -> {nr?, lg}
          ps -> record_only(module, source, Sourceror.patch_string(source, ps), nr?, lg)
        end
      end)

    {nr?, lg} = log_after
    all = Enum.flat_map(per_module, fn {_m, ps} -> ps end)
    rendered = if all == [], do: source, else: Sourceror.patch_string(source, all)
    {rendered, nr?, lg}
  end

  defp batch_sequential(batch, configured, state),
    do: Enum.reduce(batch, state, fn module, acc -> apply_solo(module, configured, acc) end)

  defp record(module, before, after_src, needs_reformat?, log) do
    if after_src == before do
      {before, needs_reformat?, log}
    else
      entry = %{after: after_src, before: before, module: module}
      {after_src, needs_reformat? or reformat_after?(module), [entry | log]}
    end
  end

  # Like record/5 but does not advance the source (the shared render does that);
  # only appends the log entry + reformat flag for this module's contribution.
  defp record_only(module, before, after_src, needs_reformat?, log) do
    if after_src == before do
      {needs_reformat?, log}
    else
      entry = %{after: after_src, before: before, module: module}
      {needs_reformat? or reformat_after?(module), [entry | log]}
    end
  end

  # Pairwise-disjoint check over patch ranges. Sort by start; adjacent
  # non-overlap implies global non-overlap.
  defp disjoint?(patches) when length(patches) < 2, do: true

  defp disjoint?(patches) do
    patches
    |> Enum.map(& &1.range)
    |> Enum.sort_by(&{&1.start[:line], &1.start[:column]})
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] ->
      {a.end[:line], a.end[:column]} <= {b.start[:line], b.start[:column]}
    end)
  end

  defp skip_for_source_get([], _source), do: false

  defp skip_for_source_get(mods, source),
    do: mods |> Enum.any?(&source_defines_module?(source, &1))

  defp with_prepared(module, opts) do
    cond do
      not Code.ensure_loaded?(module) ->
        opts

      not function_exported?(module, :prepare, 1) ->
        opts

      true ->
        case prepared_for(module, opts) do
          {:ok, value} -> Keyword.put(opts, :prepared, value)
          :no_cache -> opts
        end
    end
  end
end
