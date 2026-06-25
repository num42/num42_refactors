defmodule Mix.Tasks.Refactor do
  @shortdoc "Run AST refactor pipeline on source files"

  @moduledoc """
  Runs every `Number42.Refactors.Refactor` against the project's
  source files.

  Configuration lives in `.refactor.exs` at the project root:

      [
        inputs: ["{config,dev,lib,test}/**/*.{ex,exs}"],
        skipped_modules: [],
        configured_modules: [
          # {SomeRefactor, some_opt: true}
        ],
        # Skip a refactor for files matching any of its globs (per-file,
        # leaves the refactor active on every other file).
        disable_for_glob: %{
          # SomeRefactor => ["lib/legacy/**", "priv/**/*.ex"]
        },
        # Shortcut: when false (default), the literal hoisters
        # (ExtractMagicNumber/ExtractStringLiteral/HoistHardcodedConfig) do
        # not fire on `test/**` files — a literal in a test is its own
        # documentation. Set true to hoist literals in tests too.
        enable_in_tests: false
      ]

  ## Usage

      mix refactor                    # rewrite files in place
      mix refactor lib/foo.ex         # restrict to specific paths
      mix refactor --dry-run          # print git-style diff per file, don't write
      mix refactor --only AliasUsage  # run only this refactor (skip the rest)
      mix refactor --only AliasUsage --only RejectIsNil  # multiple
      mix refactor --exclude SortKeywords                # run all but this one
      mix refactor --stop             # halt on the first file that changes
      mix refactor --log              # print refactor name + rationale + diff
      mix refactor --test             # run the test for each file the refactor changed
      mix refactor --check            # exit non-zero if any file would change (CI gate)
      mix refactor --ci               # alias of --check
      mix refactor --step-by-step     # walk one refactor at a time over all files
      mix refactor --auto             # commit each unit (file or refactor) automatically
      mix refactor --auto --test      # run tests between units, only commit if green
      mix refactor --auto --compile   # run mix compile between units, only commit if green

  `--only` accepts the short module suffix (`AliasUsage`), the snake-case
  filename stem (`alias_usage`), or the fully-qualified module name. Pass
  it multiple times to whitelist several refactors.

  `--exclude` is the inverse blacklist: run every refactor *except* the
  named ones. Accepts the same name forms as `--only` and can be passed
  multiple times. Merged on top of the config's `skipped_modules`, so
  CLI exclusions add to (never replace) the project's permanent skips.

  `--stop` (`-s`) makes the task return as soon as one file actually
  changed. The change is written (or, with `--dry-run`, printed) before
  the task exits — so it pairs naturally with a `git diff` review loop.

  `--log` (`-l`) prints, for each file that changed, every refactor
  that fired with its `description/0` (a one-line summary) and
  `explanation/0` (long-form rationale; falls back to the description
  when the callback isn't implemented), followed by a per-refactor
  diff. Pairs especially well with `--stop` for review-as-you-go.

  `--test` (`-t`) runs `mix test` on the test files that correspond to
  the rewritten sources, by naming convention:

  - `lib/foo/bar.ex` → `test/foo/bar_test.exs`
  - test files (`test/...`) are skipped (they are their own coverage)

  Combined with `--stop`, this is "rewrite one file, run its test,
  exit" — a tight refactor-and-verify loop. Without `--stop`, all
  matching tests are batched into a single `mix test` invocation.

  `--check` (`-c`) is the CI gate: never writes, short-circuits on the
  first file that *would* change, and exits non-zero if anything is not
  yet refactored. Honors `--only`, so you can gate on a specific subset
  (`mix refactor --check --only RejectIsNil`). Run `mix refactor
  --dry-run` (with the same `--only`) locally to see the actual diff.

  `--step-by-step` (`-y`) inverts the iteration: instead of walking every
  refactor over each file before moving on, the task walks each refactor
  over *every* file before moving to the next refactor. For each refactor
  it prints either `[Module]: clear` or one `[Module]: hit <path>` line
  per file followed by the per-file hunk diff — so a human can review
  one refactor's effects across the whole codebase at a time. This mode
  is single-pass alphabetical; no fixpoint loop. Knock-on effects
  (refactor A's output feeding refactor B that runs *before* it
  alphabetically) aren't captured — run `mix refactor` again
  afterwards if needed.
  Combines with `--stop` (halt after the first refactor that has any
  hits), `--dry-run` (don't write), `--only`, `--log`, and `--test`.

  `--auto` (`-a`) turns the run into a sequence of atomic git commits.
  After each unit (a file in the default mode, a refactor in
  `--step-by-step`) it optionally validates with `--test` and/or
  `--compile`, and if everything is green (or no validators were
  requested) writes the commit with an auto-generated message naming
  the file and applied refactors (or the refactor and the files it
  touched). On validation failure the changes are *kept on disk*
  (not reverted) and the loop stops, so the user can inspect and fix
  manually. `--auto` always commits with `--no-verify` to avoid hooks
  reformatting and re-staging mid-loop, and stages the files the
  refactor touched plus any file it *generated* this unit (e.g. a
  cross-file refactor's new `*.Shared` host, written in `prepare/1`) —
  the latter detected as the working-tree delta against a pre-unit
  `git status --porcelain` snapshot. Untracked files that existed
  *before* the unit ran are excluded, so unrelated dirty files in the
  working tree are left alone. The one caveat: if your
  uncommitted changes happen to live in a file the refactor also
  modifies, those changes ride along in the auto-commit — review the
  diff before letting `--auto` run on a dirty tree. Combine with
  `--stop` to commit just one unit and exit. Mutually exclusive with
  `--dry-run` and `--check` (those modes don't write, so there's
  nothing to commit).

  `--compile` (`-n`) runs `mix compile --warnings-as-errors` as a
  validator. On its own it just adds the compile step to the end of
  the run; combined with `--auto` it gates each commit on a clean
  compile.

  ## Examples

      mix refactor                                    # everything, write in place
      mix refactor lib/foo.ex                         # one file only
      mix refactor --dry-run                          # diff preview, no write
      mix refactor --check                            # CI gate, exit non-zero when dirty
      mix refactor --only RejectIsNil --only EnumCapture
      mix refactor -syl                               # stop, write (not dry), log
      mix refactor -y --dry-run --stop                # step mode, halt after first refactor with hits
      mix refactor -ytl                               # step mode + tests + log after each refactor

  ## Pipeline

  For each input file:

  1. The refactor engine rewrites the source (idempotent, in-memory).
  2. If anything changed, the file is written.
  3. If at least one refactor with `reformat_after?/0 == true` fired
     across any file, `mix format` is invoked once on the changed
     files at the end — so external format plugins
     (`Phoenix.LiveView.HTMLFormatter`, ...) get a chance to run.

  `Mix.Task.reenable("format")` is called before that follow-up so it
  works even when `mix format` already ran in the same `mix` invocation
  (e.g. from the `precommit` alias).
  """

  use Mix.Task

  alias Number42.Refactors.Engine
  import Mix.Tasks.Refactor.Shared, only: [expand_inputs_shared: 1, glob_match?: 2]

  @literal_hoisters [
    Number42.Refactors.Ex.ExtractMagicNumber,
    Number42.Refactors.Ex.ExtractStringLiteral,
    Number42.Refactors.Ex.HoistHardcodedConfig
  ]
  @test_glob "test/**/*.{ex,exs}"

  @config_path ".refactor.exs"
  @switches [
    dry_run: :boolean,
    only: :keep,
    exclude: :keep,
    stop: :boolean,
    log: :boolean,
    test: :boolean,
    check: :boolean,
    ci: :boolean,
    step_by_step: :boolean,
    auto: :boolean,
    compile: :boolean
  ]
  @aliases [s: :stop, l: :log, t: :test, c: :check, y: :step_by_step, a: :auto, n: :compile]

  @impl Mix.Task
  def run(argv) do
    {opts, paths} = OptionParser.parse!(argv, strict: @switches, aliases: @aliases)

    config = load_config()
    inputs = if paths == [], do: Map.fetch!(config, :inputs), else: paths
    files = expand_inputs(inputs)

    only_modules = resolve_only(Keyword.get_values(opts, :only))
    excluded_modules = resolve_only(Keyword.get_values(opts, :exclude))

    skipped_modules =
      (Map.get(config, :skipped_modules, []) ++ excluded_modules) |> Enum.uniq()

    configured_modules =
      config
      |> Map.get(:configured_modules, [])
      |> inject_paths_for_cross_file_refactors(files)

    # `--check` / `--ci` are read-only gates: they report drift and exit,
    # but must write nothing. Cross-file refactors do their disk side
    # write in `prepare/1` (the `*.Shared` / `*.Support` host), which only
    # honours `dry_run`. So a check run has to thread `dry_run: true` too,
    # or it leaves the generated host files behind on every invocation.
    read_only? =
      Keyword.get(opts, :dry_run, false) or Keyword.get(opts, :check, false) or
        Keyword.get(opts, :ci, false)

    engine_opts = [
      only_modules: only_modules,
      skipped_modules: skipped_modules,
      configured_modules: configured_modules,
      project_config: config,
      dry_run: read_only?
    ]

    run_opts = %{
      auto?: Keyword.get(opts, :auto, false),
      check?: Keyword.get(opts, :check, false) or Keyword.get(opts, :ci, false),
      compile?: Keyword.get(opts, :compile, false),
      dry_run?: Keyword.get(opts, :dry_run, false),
      log?: Keyword.get(opts, :log, false),
      step?: Keyword.get(opts, :step_by_step, false),
      stop?: Keyword.get(opts, :stop, false),
      test?: Keyword.get(opts, :test, false)
    }

    validate_run_opts!(run_opts)

    {changed_files, reformat_triggered?} =
      if run_opts.step? do
        process_step_by_step(files, engine_opts, run_opts)
      else
        process_files(files, engine_opts, run_opts)
      end

    finalize_run(changed_files, reformat_triggered?, run_opts)
  end

  defp finalize_run(changed_files, reformat_triggered?, run_opts) do
    cond do
      run_opts.check? ->
        report_check(changed_files)

      run_opts.auto? and run_opts.dry_run? ->
        Mix.shell().info(
          "[refactor] --auto --dry-run: would create #{length(changed_files)} commit(s)"
        )

      run_opts.dry_run? ->
        Mix.shell().info("[refactor] dry-run: #{length(changed_files)} file(s) would change")

      run_opts.auto? ->
        finalize_auto(changed_files, reformat_triggered?)

      true ->
        maybe_reformat(changed_files, reformat_triggered?)
        if run_opts.test?, do: maybe_run_tests(changed_files)
        if run_opts.compile?, do: maybe_compile()
    end
  end

  # Per-unit commits already happened inline; just run the final
  # reformat sweep so the tree ends in a formatted state. Any
  # format-only changes are amended into the last commit so the
  # history stays atomic.
  defp finalize_auto(changed_files, reformat_triggered?) do
    if reformat_triggered? and changed_files != [] do
      maybe_reformat(changed_files, true)
      amend_format_into_last_commit(changed_files)
    end
  end

  defp amend_format_into_last_commit(paths) do
    case System.cmd("git", ["add" | paths], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> Mix.raise("--auto: post-format git add failed:\n#{output}")
    end

    System.cmd("git", ["diff", "--cached", "--quiet"], stderr_to_stdout: true)
    |> handle_cached_diff_probe()
  end

  defp apply_module_to_files(module, files, engine_opts, run_opts) do
    reformat? = Engine.reformat_after_module?(module)

    hits =
      files
      |> Enum.reject(&module_globbed_out?(module, &1, engine_opts))
      |> Enum.flat_map(fn path ->
        source = File.read!(path)
        rewritten = Engine.apply_one(module, source, engine_opts)

        cond do
          rewritten == source ->
            []

          run_opts.dry_run? or run_opts.check? ->
            [{path, source, rewritten}]

          true ->
            File.write!(path, rewritten)
            [{path, source, rewritten}]
        end
      end)

    {hits, reformat? and hits != []}
  end

  defp auto_commit_file(path, applied, reformat?, baseline, run_opts) do
    refactors_short = applied |> Enum.map(&short_name(&1.module)) |> Enum.uniq()
    subject = "refactor(auto): #{path}"
    body = ""

    trailers =
      [
        {"Refactored-By", "mix refactor"},
        {"Refactor-Mode", "file"}
      ] ++
        if refactors_short == [],
          do: [],
          else: [{"Applied", refactors_short |> Enum.join(", ")}]

    if run_opts.dry_run? do
      log_planned_commit([path], subject, body, trailers)
    else
      if reformat?, do: reformat_files([path])
      validate_or_halt!([path], run_opts)
      git_commit!(stage_paths([path], baseline), subject, body, trailers)
    end
  end

  defp auto_commit_refactor(module, paths, reformat?, baseline, run_opts) do
    name = short_name(module)
    subject = "refactor(auto): #{name} over #{length(paths)} file(s)"
    body = paths |> Enum.join("\n")

    trailers = [
      {"Refactored-By", "mix refactor"},
      {"Refactor-Mode", "step"},
      {"Applied", name}
    ]

    if run_opts.dry_run? do
      log_planned_commit(paths, subject, body, trailers)
    else
      if reformat?, do: reformat_files(paths)
      validate_or_halt!(paths, run_opts)
      git_commit!(stage_paths(paths, baseline), subject, body, trailers)
    end
  end

  defp changes_only_diff(old, new) do
    {old_path, new_path} = {tmp_path(), tmp_path()}
    File.write!(old_path, old)
    File.write!(new_path, new)

    try do
      case System.cmd(
             "git",
             [
               "--no-pager",
               "diff",
               "--no-index",
               "--no-color",
               "--unified=1",
               old_path,
               new_path
             ],
             stderr_to_stdout: true
           ) do
        {output, _exit} ->
          # `git diff --no-index` always exits 1 when files differ; that's
          # not an error, just "diff produced output". Strip the file
          # headers — they reference our temp paths, which are noise.
          output
          |> String.split("\n")
          |> Enum.drop_while(&(not String.starts_with?(&1, "@@")))
          |> Enum.join("\n")
          |> String.trim_trailing()
      end
    after
      File.rm(old_path)
      File.rm(new_path)
    end
  end

  defp describe(mod) do
    if function_exported?(mod, :description, 0), do: mod.description(), else: ""
  end

  defp expand_inputs(patterns), do: expand_inputs_shared(patterns)

  # Cross-file refactors that build a project-wide plan in `prepare/1`
  # need the full file list. We thread it through `configured_modules`
  # so each refactor's `prepare/1` receives `paths: <files>` without
  # adding a top-level engine concept.
  @cross_file_refactors [
    Number42.Refactors.Ex.ExtractBehaviourFromAdapterFamily,
    Number42.Refactors.Ex.ExtractPrimitiveToStruct,
    Number42.Refactors.Ex.ExtractProtocolFromStructFamily,
    Number42.Refactors.Ex.LiftUntypedParamToStructPattern,
    Number42.Refactors.Ex.ExtractHeexExactClone
  ]

  # Cross-file refactors that historically read `:source_files` and
  # fall back to scanning the full `.refactor.exs` inputs when
  # absent — which silently ignores the CLI path selection. Thread
  # the resolved file list through so explicit `mix refactor ./test/...`
  # actually constrains these refactors.
  @source_files_refactors [
    Number42.Refactors.Ex.ConvertLiveComponentToFunction,
    Number42.Refactors.Ex.DelegateExactDuplicates,
    Number42.Refactors.Ex.DropRedundantAttrDefaults,
    Number42.Refactors.Ex.ExtractParametricClone,
    Number42.Refactors.Ex.ExtractRenamedClone,
    Number42.Refactors.Ex.ExtractSharedModule,
    Number42.Refactors.Ex.ExtractToPublicComponent,
    Number42.Refactors.Ex.NormalizeComponentInvocationOrder,
    Number42.Refactors.Ex.ProposeSharedHeexComponent,
    Number42.Refactors.Ex.PromoteRepeatedPrivateHelpers,
    Number42.Refactors.Ex.PushParamIntoCallee
  ]

  defp explain(mod) do
    if function_exported?(mod, :explanation, 0), do: mod.explanation(), else: describe(mod)
  end

  defp format_why(text) do
    [first | rest] = text |> String.trim() |> String.split("\n")

    "    why: " <>
      Enum.reduce(rest, first, fn line, acc -> acc <> "\n         " <> line end)
  end

  defp git_commit!(paths, subject, body, trailers) do
    case System.cmd("git", ["add" | paths], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> Mix.raise("--auto: git add failed:\n#{output}")
    end

    message = if body == "", do: subject, else: subject <> "\n\n" <> body

    trailer_args = trailers |> Enum.flat_map(fn {k, v} -> ["--trailer", "#{k}: #{v}"] end)
    args = ["commit", "--no-verify", "-m", message] ++ trailer_args

    System.cmd("git", args, stderr_to_stdout: true) |> handle_git_commit_result(subject)
  end

  # Stage the input paths plus anything this unit newly created/touched.
  # The engine writes generated files (e.g. ExtractSharedModule's
  # `*.Shared` host) during `prepare/1`, before the per-file `paths` are
  # known — so without picking up the working-tree delta they'd stay
  # untracked, get re-created every fixpoint pass, and never converge
  # (#237). The baseline is the pre-unit snapshot; the difference against
  # the post-unit tree is exactly what this unit produced.
  #
  # `cwd` is a test seam (`stage_paths/3`); production passes the process
  # cwd so git runs against the project repo, consistent with the rest of
  # the `--auto` git calls.
  @doc false
  @spec stage_paths([String.t()], MapSet.t(String.t()), Path.t()) :: [String.t()]
  def stage_paths(paths, baseline, cwd \\ ".") do
    appeared = MapSet.difference(git_porcelain_paths(cwd), baseline) |> MapSet.to_list()
    (paths ++ appeared) |> Enum.uniq()
  end

  # Untracked + modified + staged paths git reports for the working tree,
  # as a set, so `stage_paths/3` can diff two snapshots. We pick up new
  # files (??), modifications (?M), and renames — see `parse_porcelain/1`.
  @doc false
  @spec git_porcelain_paths(Path.t()) :: MapSet.t(String.t())
  def git_porcelain_paths(cwd \\ ".") do
    case System.cmd("git", ["status", "--porcelain"], cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> parse_porcelain(output)
      {output, _} -> Mix.raise("--auto: git status failed:\n#{output}")
    end
  end

  # Parse `git status --porcelain` (v1) into the set of affected paths.
  # Each line is `XY <path>` or, for renames, `XY <orig> -> <new>` — we
  # keep the destination path in the rename case (that's the file now on
  # disk that needs staging).
  @doc false
  @spec parse_porcelain(String.t()) :: MapSet.t(String.t())
  def parse_porcelain(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&porcelain_path/1)
    |> MapSet.new()
  end

  defp porcelain_path(line) do
    line
    |> String.slice(3..-1//1)
    |> rename_destination()
  end

  defp rename_destination(path) do
    case String.split(path, " -> ", parts: 2) do
      [_orig, dest] -> dest
      [plain] -> plain
    end
  end

  defp handle_amend_result({_, 0}),
    do: "[refactor] --auto: folded post-format pass into last commit" |> Mix.shell().info()

  defp handle_amend_result({output, _}), do: "--auto: amend failed:\n#{output}" |> Mix.raise()
  defp handle_cached_diff_probe({_, 0}), do: :ok

  defp handle_cached_diff_probe({_, 1}),
    do:
      System.cmd(
        "git",
        ["commit", "--amend", "--no-verify", "--no-edit"],
        stderr_to_stdout: true
      )
      |> handle_amend_result()

  defp handle_cached_diff_probe({output, _}),
    do: "--auto: cached-diff probe failed:\n#{output}" |> Mix.raise()

  defp handle_git_commit_result({_output, 0}, subject),
    do: "[refactor] --auto: committed — #{subject}" |> Mix.shell().info()

  defp handle_git_commit_result({output, _}, _subject),
    do: "--auto: git commit failed:\n#{output}" |> Mix.raise()

  defp indent(text, prefix),
    do:
      text
      |> String.split("\n")
      |> Enum.map_join("\n", &(prefix <> &1))

  defp inject_into(configured, modules, key, value) do
    modules
    |> Enum.reduce(configured, fn mod, acc ->
      existing = Keyword.get(acc, mod, [])
      Keyword.put(acc, mod, Keyword.put(existing, key, value))
    end)
  end

  defp inject_paths_for_cross_file_refactors(configured, files),
    do:
      configured
      |> inject_into(@cross_file_refactors, :paths, files)
      |> inject_into(@source_files_refactors, :source_files, files)

  defp load_config do
    path = Path.join(File.cwd!(), @config_path)

    File.read(path) |> parse_config_or_raise(path)
  end

  defp log_applied(applied) do
    applied
    |> Enum.each(fn %{after: after_src, before: before_src, module: mod} ->
      Mix.shell().info("\n  ▸ #{short_name(mod)} — #{describe(mod)}")
      Mix.shell().info(format_why(explain(mod)))
      Mix.shell().info(indent(changes_only_diff(before_src, after_src), "    "))
    end)
  end

  defp log_planned_commit(paths, subject, body, trailers) do
    Mix.shell().info("\n[refactor] --auto --dry-run: would commit")
    Mix.shell().info("  subject:  #{subject}")

    if body != "",
      do: Mix.shell().info("  body:     " <> String.replace(body, "\n", "\n            "))

    trailers |> Enum.each(fn {k, v} -> Mix.shell().info("  trailer:  #{k}: #{v}") end)

    Mix.shell().info("  files:    " <> Enum.join(paths, "\n            "))
  end

  defp maybe_compile do
    Mix.shell().info("[refactor] running mix compile")
    Mix.Task.reenable("compile")
    Mix.Task.run("compile", ["--warnings-as-errors"])
  end

  defp maybe_reformat([], _reformat?), do: :ok
  defp maybe_reformat(_files, false), do: :ok

  defp maybe_reformat(files, true) do
    Mix.shell().info("[refactor] running mix format on #{length(files)} changed file(s)")
    Mix.Task.reenable("format")
    Mix.Task.run("format", files)
  end

  defp maybe_run_tests([]), do: :ok

  defp maybe_run_tests(files) do
    test_files =
      files
      |> Enum.map(&test_file_for/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case test_files do
      [] ->
        Mix.shell().info("[refactor] --test: no matching test files found")

      _ ->
        Mix.shell().info(
          "[refactor] --test: running #{length(test_files)} test file(s):\n  " <>
            Enum.join(test_files, "\n  ")
        )

        # Spawn `mix test` as a subprocess with MIX_ENV=test rather
        # than reusing the in-process Mix runtime. The current
        # invocation runs in :dev (or whichever env `mix refactor` was
        # called with); test code paths, deps and the Repo aren't
        # configured for it, so an in-process call would fail or
        # silently run the wrong env. The subprocess gets its own
        # fresh Mix application with the correct env.
        {_output, exit_code} =
          System.cmd("mix", ["test" | test_files],
            env: [{"MIX_ENV", "test"}],
            into: IO.stream(:stdio, :line)
          )

        if exit_code != 0 do
          Mix.raise("--test: mix test exited with status #{exit_code}")
        end
    end
  end

  defp merge_unique(acc, []), do: acc

  defp merge_unique(acc, paths) do
    paths |> Enum.reduce(acc, fn path, a -> if path in a, do: a, else: [path | a] end)
  end

  defp normalize(arg),
    do:
      arg
      |> to_string()
      |> String.split(".")
      |> List.last()
      |> String.replace("_", "")
      |> String.downcase()

  defp normalize_module(module),
    do:
      module
      |> short_name()
      |> normalize()

  defp parse_config_or_raise({:ok, contents}, path) do
    {config, _binding} = Code.eval_string(contents, [], file: path)
    config
  end

  defp parse_config_or_raise({:error, _}, path),
    do:
      "#{@config_path} not found at #{path}. Create one with at least an `inputs:` key (see README)."
      |> Mix.raise()

  defp print_module_step(module, [], _run_opts),
    do: "[#{short_name(module)}]: clear" |> Mix.shell().info()

  defp print_module_step(module, hits, run_opts) do
    if run_opts.log? do
      Mix.shell().info("\n[#{short_name(module)}] — #{describe(module)}")
      Mix.shell().info(format_why(explain(module)))
    end

    hits
    |> Enum.each(fn {path, before_src, after_src} ->
      Mix.shell().info("[#{short_name(module)}]: hit #{path}")
      Mix.shell().info(changes_only_diff(before_src, after_src))
      Mix.shell().info("")
    end)
  end

  # Per-file refactor gating. The base `skipped_modules` (config +
  # `--exclude`) is path-agnostic; this augments it with the modules that
  # `disable_for_glob` switches off for `path`, plus the `enable_in_tests`
  # sugar (a `test/**` glob-disable for the literal hoisters —
  # ExtractMagicNumber/ExtractStringLiteral/HoistHardcodedConfig). The
  # Engine stays path-blind — it just receives a per-file `skipped_modules`.
  @doc false
  @spec skipped_for_file(Path.t(), [module()], map()) :: [module()]
  def skipped_for_file(path, base_skipped, config) do
    (base_skipped ++ globbed_out_modules(path, config)) |> Enum.uniq()
  end

  defp globbed_out_modules(path, config) do
    config
    |> disable_for_glob_with_test_gate()
    |> Enum.filter(fn {_module, globs} -> Enum.any?(globs, &glob_match?(&1, path)) end)
    |> Enum.map(fn {module, _globs} -> module end)
  end

  defp disable_for_glob_with_test_gate(config) do
    base = Map.get(config, :disable_for_glob, %{})
    gate_literal_hoisters(base, test_globs(config))
  end

  defp gate_literal_hoisters(base, []), do: base

  defp gate_literal_hoisters(base, globs) do
    Enum.reduce(@literal_hoisters, base, fn module, acc ->
      Map.update(acc, module, globs, &(&1 ++ globs))
    end)
  end

  defp test_globs(%{enable_in_tests: true}), do: []
  defp test_globs(_config), do: [@test_glob]

  defp engine_opts_for_file(path, engine_opts) do
    base_skipped = Keyword.fetch!(engine_opts, :skipped_modules)
    config = Keyword.get(engine_opts, :project_config, %{})
    Keyword.put(engine_opts, :skipped_modules, skipped_for_file(path, base_skipped, config))
  end

  defp module_globbed_out?(module, path, engine_opts) do
    config = Keyword.get(engine_opts, :project_config, %{})
    module in skipped_for_file(path, [], config)
  end

  defp process_file(path, engine_opts, run_opts) do
    source = File.read!(path)

    %{
      applied: applied,
      changed?: changed?,
      reformat_triggered?: reformat?,
      source: new_source
    } = Engine.run(source, engine_opts_for_file(path, engine_opts))

    cond do
      not changed? ->
        :unchanged

      run_opts.check? ->
        {:changed, reformat?, applied}

      run_opts.dry_run? ->
        Mix.shell().info("--- #{path}")
        if run_opts.log?, do: log_applied(applied)
        Mix.shell().info(changes_only_diff(source, new_source))
        {:changed, reformat?, applied}

      true ->
        File.write!(path, new_source)
        Mix.shell().info("[refactor] rewrote #{path}")
        if run_opts.log?, do: log_applied(applied)
        {:changed, reformat?, applied}
    end
  end

  defp process_files(files, engine_opts, run_opts) do
    # `--check` only needs to answer "is anything dirty?" — short-circuit
    # on the first changed file like `--stop`, so CI doesn't pay for a
    # full sweep just to flip an exit code.
    halt? = run_opts.stop? or run_opts.check?

    files
    |> Enum.reduce_while({[], false}, fn file, {changed_acc, reformat_acc} = acc ->
      # Snapshot the working tree *before* the engine runs: `prepare/1`
      # of cross-file refactors (e.g. ExtractSharedModule) writes new
      # `*.Shared` files here, which never appear in the per-file `paths`
      # the auto-stager knows about. Capturing the baseline lets us stage
      # exactly what this unit created (see #237).
      baseline = if run_opts.auto?, do: git_porcelain_paths(), else: MapSet.new()

      case process_file(file, engine_opts, run_opts) do
        {:changed, reformat?, applied} ->
          new_acc = {[file | changed_acc], reformat_acc or reformat?}
          decide_file_step(file, applied, reformat?, baseline, new_acc, halt?, run_opts)

        :unchanged ->
          # The engine still ran `prepare/1` for every refactor on this
          # file (Engine.run resolves all plans up front), so a cross-file
          # side-write (e.g. ExtractSharedModule appending to an existing
          # `*.Shared` host) can land here even though THIS file did not
          # change. With no commit on the unchanged branch that write is
          # orphaned: it's already dirty by the time any later changed
          # unit snapshots its baseline, so #237's `after − before` delta
          # excludes it and it never gets staged. Commit the delta as its
          # own unit so no refactor-authored change is left behind (#243).
          commit_generated_orphans(baseline, run_opts)
          {:cont, acc}
      end
    end)
  end

  # Stage + commit any working-tree change that appeared during an
  # otherwise-unchanged unit. These are side-writes from a refactor's
  # `prepare/1` (cross-file destinations) that no per-file commit would
  # otherwise pick up.
  defp commit_generated_orphans(_baseline, %{auto?: false}), do: :ok
  defp commit_generated_orphans(_baseline, %{dry_run?: true}), do: :ok

  defp commit_generated_orphans(baseline, run_opts) do
    case stage_paths([], baseline) do
      [] ->
        :ok

      generated ->
        validate_or_halt!(generated, run_opts)

        git_commit!(
          generated,
          "refactor(auto): generated #{length(generated)} cross-file destination(s)",
          generated |> Enum.join("\n"),
          [{"Refactored-By", "mix refactor"}, {"Refactor-Mode", "generated"}]
        )
    end
  end

  defp decide_file_step(file, applied, reformat?, baseline, new_acc, halt?, run_opts) do
    cond do
      run_opts.auto? ->
        auto_commit_file(file, applied, reformat?, baseline, run_opts)
        if run_opts.stop?, do: {:halt, new_acc}, else: {:cont, new_acc}

      halt? ->
        {:halt, new_acc}

      true ->
        {:cont, new_acc}
    end
  end

  defp process_step_by_step(files, engine_opts, run_opts) do
    modules = Engine.pipeline_modules(engine_opts)
    halt_on_hit? = run_opts.stop? or run_opts.check?

    modules
    |> Enum.reduce_while({[], false}, fn module, {changed_acc, reformat_acc} ->
      # Drop any plan cached by an earlier module in this step-by-step
      # run. Cross-file refactors build their plan from the source on
      # disk; once an earlier module has rewritten files, the next
      # module's plan needs a fresh read or it operates on stale
      # symbols (e.g. `import …` lines pointing at functions a prior
      # refactor renamed).
      Engine.invalidate_prepared_cache()
      # See `process_files/3`: snapshot before the module runs so newly
      # generated files (written in `prepare/1`) can be staged (#237).
      baseline = if run_opts.auto?, do: git_porcelain_paths(), else: MapSet.new()
      {hits, reformat?} = apply_module_to_files(module, files, engine_opts, run_opts)
      print_module_step(module, hits, run_opts)

      new_changed = merge_unique(changed_acc, hits |> Enum.map(fn {path, _, _} -> path end))
      new_acc = {new_changed, reformat_acc or reformat?}

      decide_module_step(module, hits, reformat?, baseline, new_acc, halt_on_hit?, run_opts)
    end)
  end

  defp decide_module_step(module, hits, reformat?, baseline, new_acc, halt_on_hit?, run_opts) do
    cond do
      hits == [] ->
        {:cont, new_acc}

      run_opts.auto? ->
        hit_paths = hits |> Enum.map(fn {p, _, _} -> p end)
        auto_commit_refactor(module, hit_paths, reformat?, baseline, run_opts)
        if run_opts.stop?, do: {:halt, new_acc}, else: {:cont, new_acc}

      halt_on_hit? ->
        {:halt, new_acc}

      true ->
        {:cont, new_acc}
    end
  end

  defp reformat_files(paths) do
    Mix.Task.reenable("format")
    Mix.Task.run("format", paths)
  end

  defp report_check([]), do: "[refactor] check: clean" |> Mix.shell().info()

  defp report_check([first | _]) do
    Mix.shell().error("[refactor] check: #{first} needs refactoring")
    exit({:shutdown, 1})
  end

  defp resolve_one(arg, available) do
    arg_norm = normalize(arg)

    case available |> Enum.find(&(normalize_module(&1) == arg_norm)) do
      nil ->
        Mix.raise("""
        Unknown refactor: #{inspect(arg)}

        Available refactors:
        #{available |> Enum.map_join("\n", &"  - #{short_name(&1)}")}
        """)

      mod ->
        mod
    end
  end

  defp resolve_only([]), do: []

  defp resolve_only(args) do
    available = Engine.refactors()
    args |> Enum.map(&resolve_one(&1, available))
  end

  defp run_compile do
    Mix.shell().info("[refactor] --auto: running mix compile --warnings-as-errors")

    {_output, code} =
      System.cmd("mix", ["compile", "--warnings-as-errors"], into: IO.stream(:stdio, :line))

    if code == 0, do: :ok, else: {:error, code}
  end

  defp run_test_files(test_files) do
    Mix.shell().info("[refactor] --auto: running #{length(test_files)} test file(s)")

    {_output, code} =
      System.cmd("mix", ["test" | test_files],
        env: [{"MIX_ENV", "test"}],
        into: IO.stream(:stdio, :line)
      )

    if code == 0, do: :ok, else: {:error, code}
  end

  defp short_name(mod),
    do:
      mod
      |> Module.split()
      |> List.last()

  defp swap_ex_for_test_exs(path) do
    cond do
      String.ends_with?(path, ".ex") -> String.replace_suffix(path, ".ex", "_test.exs")
      String.ends_with?(path, ".exs") -> String.replace_suffix(path, ".exs", "_test.exs")
      true -> path
    end
  end

  defp test_file_for(path) do
    candidate =
      if String.starts_with?(path, "lib/") do
        path
        |> String.replace_prefix("lib/", "test/")
        |> swap_ex_for_test_exs()
      end

    if is_binary(candidate) and File.exists?(candidate), do: candidate, else: nil
  end

  defp tmp_path,
    do: System.tmp_dir!() |> Path.join("refactor-log-#{System.unique_integer([:positive])}")

  defp validate_or_halt!(paths, run_opts) do
    if run_opts.test?, do: validate_tests_or_halt!(paths)
    if run_opts.compile?, do: validate_compile_or_halt!(paths)

    :ok
  end

  defp validate_tests_or_halt!(paths) do
    test_files = paths |> Enum.map(&test_file_for/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if test_files != [], do: raise_on_test_failure!(run_test_files(test_files), paths)
  end

  defp raise_on_test_failure!(:ok, _paths), do: :ok

  defp raise_on_test_failure!({:error, code}, paths),
    do:
      Mix.raise(
        "--auto: tests failed (exit #{code}) after rewriting #{paths |> Enum.join(", ")}. " <>
          "Changes left on disk for inspection."
      )

  defp validate_compile_or_halt!(paths), do: raise_on_compile_failure!(run_compile(), paths)

  defp raise_on_compile_failure!(:ok, _paths), do: :ok

  defp raise_on_compile_failure!({:error, code}, paths),
    do:
      Mix.raise(
        "--auto: compile failed (exit #{code}) after rewriting #{paths |> Enum.join(", ")}. " <>
          "Changes left on disk for inspection."
      )

  defp validate_run_opts!(%{auto?: true, check?: true}),
    do: "--auto cannot be combined with --check / --ci (nothing to commit)" |> Mix.raise()

  defp validate_run_opts!(_), do: :ok
end
