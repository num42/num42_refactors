defmodule Mix.Tasks.Refactor do
  @shortdoc "Run AST refactor pipeline on source files"

  @moduledoc """
  Runs every `Num42.Refactors.Refactor` against the project's
  source files.

  Configuration lives in `.refactoring.exs` at the project root:

      [
        inputs: ["{config,dev,lib,test}/**/*.{ex,exs}"],
        skipped_modules: [],
        configured_modules: [
          # {SomeRefactor, some_opt: true}
        ]
      ]

  ## Usage

      mix refactor                    # rewrite files in place
      mix refactor lib/foo.ex         # restrict to specific paths
      mix refactor --dry-run          # print git-style diff per file, don't write
      mix refactor --only AliasUsage  # run only this refactor (skip the rest)
      mix refactor --only AliasUsage --only RejectIsNil  # multiple
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
  is single-pass alphabetical; no fixpoint loop. Folge-Effekte (Refactor
  A's output feeding Refactor B that runs *before* it alphabetically)
  aren't captured — run `mix refactor` again afterwards if needed.
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
  reformatting and re-staging mid-loop, and stages **only** the files
  the refactor touched (via `git add <path>`), so unrelated dirty
  files in the working tree are left alone. The one caveat: if your
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

      mix refactor                                    # alles, in-place schreiben
      mix refactor lib/foo.ex                         # nur ein File
      mix refactor --dry-run                          # diff-preview, kein Write
      mix refactor --check                            # CI-Gate, exit non-zero wenn unsauber
      mix refactor --only RejectIsNil --only EnumCapture
      mix refactor -syl                               # stop, dry? nein → write, log
      mix refactor -y --dry-run --stop                # step-mode, halt nach erstem Refactor mit Hits
      mix refactor -ytl                               # step-mode + tests + log nach jedem Refactor

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

  alias Num42.Refactors.Engine
  import Mix.Tasks.Refactor.Shared, only: [expand_inputs_shared: 1]

  @config_path ".refactor.exs"
  @switches [
    dry_run: :boolean,
    only: :keep,
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

    configured_modules =
      config
      |> Map.get(:configured_modules, [])
      |> inject_paths_for_cross_file_refactors(files)

    engine_opts = [
      only_modules: only_modules,
      skipped_modules: Map.get(config, :skipped_modules, []),
      configured_modules: configured_modules,
      project_config: config,
      dry_run: Keyword.get(opts, :dry_run, false)
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
        # Per-unit commits already happened inline; just run the
        # final reformat sweep so the tree ends in a formatted state.
        # Any format-only changes are amended into the last commit
        # so the history stays atomic.
        if reformat_triggered? and changed_files != [] do
          maybe_reformat(changed_files, true)
          amend_format_into_last_commit(changed_files)
        end

      true ->
        maybe_reformat(changed_files, reformat_triggered?)
        if run_opts.test?, do: maybe_run_tests(changed_files)
        if run_opts.compile?, do: maybe_compile()
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

  defp auto_commit_file(path, applied, reformat?, run_opts) do
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
      git_commit!([path], subject, body, trailers)
    end
  end

  defp auto_commit_refactor(module, paths, reformat?, run_opts) do
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
      git_commit!(paths, subject, body, trailers)
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
    Num42.Refactors.Refactors.ExtractHeexExactClone
  ]

  # Cross-file refactors that historically read `:source_files` and
  # fall back to scanning the full `.refactoring.exs` inputs when
  # absent — which silently ignores the CLI path selection. Thread
  # the resolved file list through so explicit `mix refactor ./test/...`
  # actually constrains these refactors.
  @source_files_refactors [
    Num42.Refactors.Refactors.DelegateExactDuplicates,
    Num42.Refactors.Refactors.ExtractParametricClone,
    Num42.Refactors.Refactors.ExtractRenamedClone,
    Num42.Refactors.Refactors.ExtractSharedModule
  ]

  defp inject_paths_for_cross_file_refactors(configured, files),
    do:
      configured
      |> inject_into(@cross_file_refactors, :paths, files)
      |> inject_into(@source_files_refactors, :source_files, files)

  defp inject_into(configured, modules, key, value) do
    modules
    |> Enum.reduce(configured, fn mod, acc ->
      existing = Keyword.get(acc, mod, [])
      Keyword.put(acc, mod, Keyword.put(existing, key, value))
    end)
  end

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

  defp indent(text, prefix),
    do:
      text
      |> String.split("\n")
      |> Enum.map_join("\n", &(prefix <> &1))

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

  defp normalize_module(mod),
    do:
      mod
      |> short_name()
      |> normalize()

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

  defp process_file(path, engine_opts, run_opts) do
    source = File.read!(path)

    %{
      applied: applied,
      changed?: changed?,
      reformat_triggered?: reformat?,
      source: new_source
    } = Engine.run(source, engine_opts)

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
      case process_file(file, engine_opts, run_opts) do
        {:changed, reformat?, applied} ->
          new_acc = {[file | changed_acc], reformat_acc or reformat?}

          cond do
            run_opts.auto? ->
              auto_commit_file(file, applied, reformat?, run_opts)
              if run_opts.stop?, do: {:halt, new_acc}, else: {:cont, new_acc}

            halt? ->
              {:halt, new_acc}

            true ->
              {:cont, new_acc}
          end

        :unchanged ->
          {:cont, acc}
      end
    end)
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
      {hits, reformat?} = apply_module_to_files(module, files, engine_opts, run_opts)
      print_module_step(module, hits, run_opts)

      new_changed = merge_unique(changed_acc, hits |> Enum.map(fn {path, _, _} -> path end))
      new_acc = {new_changed, reformat_acc or reformat?}

      cond do
        hits == [] ->
          {:cont, new_acc}

        run_opts.auto? ->
          hit_paths = hits |> Enum.map(fn {p, _, _} -> p end)
          auto_commit_refactor(module, hit_paths, reformat?, run_opts)
          if run_opts.stop?, do: {:halt, new_acc}, else: {:cont, new_acc}

        halt_on_hit? ->
          {:halt, new_acc}

        true ->
          {:cont, new_acc}
      end
    end)
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
      cond do
        String.starts_with?(path, "lib/") ->
          path
          |> String.replace_prefix("lib/", "test/")
          |> swap_ex_for_test_exs()

        true ->
          nil
      end

    if is_binary(candidate) and File.exists?(candidate), do: candidate, else: nil
  end

  defp tmp_path,
    do: System.tmp_dir!() |> Path.join("refactor-log-#{System.unique_integer([:positive])}")

  defp validate_or_halt!(paths, run_opts) do
    if run_opts.test? do
      test_files = paths |> Enum.map(&test_file_for/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      if test_files != [] do
        case run_test_files(test_files) do
          :ok ->
            :ok

          {:error, code} ->
            Mix.raise(
              "--auto: tests failed (exit #{code}) after rewriting #{paths |> Enum.join(", ")}. " <>
                "Changes left on disk for inspection."
            )
        end
      end
    end

    if run_opts.compile? do
      case run_compile() do
        :ok ->
          :ok

        {:error, code} ->
          Mix.raise(
            "--auto: compile failed (exit #{code}) after rewriting #{paths |> Enum.join(", ")}. " <>
              "Changes left on disk for inspection."
          )
      end
    end

    :ok
  end

  defp validate_run_opts!(%{auto?: true, check?: true}),
    do: "--auto cannot be combined with --check / --ci (nothing to commit)" |> Mix.raise()

  defp validate_run_opts!(_), do: :ok

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

  defp parse_config_or_raise({:ok, contents}, path) do
    {config, _binding} = Code.eval_string(contents, [], file: path)
    config
  end

  defp parse_config_or_raise({:error, _}, path),
    do:
      "#{@config_path} not found at #{path}. Create one with at least an `inputs:` key (see README)."
      |> Mix.raise()

  defp handle_amend_result({_, 0}),
    do: "[refactor] --auto: folded post-format pass into last commit" |> Mix.shell().info()

  defp handle_amend_result({output, _}), do: "--auto: amend failed:\n#{output}" |> Mix.raise()
end
