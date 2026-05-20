defmodule Num42.Refactors.Engine do
  @moduledoc """
  Pipeline engine that applies every `Num42.Refactors.Refactor`
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

  defp build_module_opts(module, opts) do
    configured = Keyword.get(opts, :configured_modules, [])
    dry_run? = Keyword.get(opts, :dry_run, false)
    project_config = Keyword.get(opts, :project_config, %{})

    configured
    |> Keyword.get(module, [])
    |> Keyword.put(:dry_run, dry_run?)
    |> Keyword.put(:project_config, project_config)
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

  Discovered by reading the loaded modules of the `:num42_refactors`
  application and keeping only those whose `:is_refactor` persistent
  attribute is `true` (set by `use Num42.Refactors.Refactor`). Sorted
  alphabetically as a stable base order — `pipeline_modules/1` re-sorts
  by priority before applying.
  """
  def refactors do
    Application.load(:num42_refactors)

    case :application.get_key(:num42_refactors, :modules) do
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

  # Per-refactor opt: `skip_in_modules: [Mod, ...]` tells the engine to
  # leave a source file alone if it defines any of the listed modules.
  # Useful for refactors whose heuristics misfire on specific modules
  # (e.g. `ExpandShortFormBindings` rewriting math single-letter names
  # in `MyApp.Color`). Generic — any refactor can configure it via
  # its entry in `configured_modules`.
  #
  # Matched by literal `defmodule X.Y.Z` text, which is faster than
  # parsing the AST and good enough for this filter (false matches in
  # comments or strings are vanishingly rare in practice).
  defp skip_for_source?(opts, source),
    do: Keyword.get(opts, :skip_in_modules, []) |> skip_for_source_get(source)

  defp source_defines_module?(source, mod) when is_atom(mod) do
    needle = "defmodule " <> trim_elixir_prefix(Atom.to_string(mod))
    String.contains?(source, needle)
  end

  defp trim_elixir_prefix("Elixir." <> rest), do: rest
  defp trim_elixir_prefix(other), do: other

  defp filter_only(modules, []), do: modules
  defp filter_only(modules, only), do: modules |> Enum.filter(&(&1 in only))

  # Stable sort: higher priority first, alphabetical within ties. The
  # incoming `modules` list is already alphabetical (from `refactors/0`),
  # so `Enum.sort_by/3` with a single negative-priority key preserves
  # that order for ties.
  defp sort_by_priority(modules, configured),
    do: modules |> Enum.sort_by(&(-priority_for(&1, configured)))

  # Per-module priority resolution. Config wins, module callback is the
  # fallback, default is 100.
  @default_priority 100
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

  # If the refactor implements `prepare/1`, run it once and inject the
  # cached value under `opts[:prepared]`. Refactors that don't implement
  # the optional callback get their opts unchanged.
  #
  # Cached in :persistent_term keyed by `{__MODULE__, module, opts}`.
  # Mix task layer iterates `apply_one` per file — without the cache,
  # `prepare/1` would re-run (and re-read every lib file for the
  # schema-field collector) once per source file, turning a O(n) walk
  # into O(n²). The cache makes the first call do the work and every
  # subsequent call a constant-time lookup.
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

      _ ->
        :ok
    end)
  end

  defp refactor?(module) when is_atom(module) do
    Code.ensure_loaded(module) |> refactor_ensure_loaded(module)
  end

  defp reformat_after?(module),
    do: function_exported?(module, :reformat_after?, 0) and module.reformat_after?()

  defp run_fixpoint(_modules, _configured, source, 0, reformat?, applied),
    do: {source, reformat?, applied}

  defp run_fixpoint(modules, configured, source, passes_left, reformat?, applied) do
    {new_source, reformat_now?, applied_after} =
      modules
      |> Enum.reduce({source, reformat?, applied}, fn module, {acc, needs_reformat?, log} ->
        module_opts = Keyword.get(configured, module, [])
        rewritten = apply_refactor(module, acc, module_opts)

        if rewritten == acc do
          {acc, needs_reformat?, log}
        else
          entry = %{after: rewritten, before: acc, module: module}
          {rewritten, needs_reformat? or reformat_after?(module), [entry | log]}
        end
      end)

    if new_source == source do
      {new_source, reformat_now?, applied_after}
    else
      run_fixpoint(modules, configured, new_source, passes_left - 1, reformat_now?, applied_after)
    end
  end

  defp refactor_ensure_loaded({:module, _}, module),
    do:
      module.__info__(:attributes)
      |> Keyword.get_values(:is_refactor)
      |> List.flatten()
      |> Enum.any?(&(&1 == true))

  defp refactor_ensure_loaded(_, _module), do: false

  defp skip_for_source_get([], _source), do: false

  defp skip_for_source_get(mods, source),
    do: mods |> Enum.any?(&source_defines_module?(source, &1))
end
