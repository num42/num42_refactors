defmodule Mix.Tasks.RefactorTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Refactor
  alias Mix.Tasks.Refactor.Shared

  @extract_magic_number Number42.Refactors.Ex.ExtractMagicNumber
  @extract_string_literal Number42.Refactors.Ex.ExtractStringLiteral
  @hoist_hardcoded_config Number42.Refactors.Ex.HoistHardcodedConfig
  @literal_hoisters [@extract_magic_number, @extract_string_literal, @hoist_hardcoded_config]

  describe "Shared.glob_match?/2" do
    test "** matches across nested segments" do
      assert Shared.glob_match?("test/**/*.exs", "test/foo/bar_test.exs")
    end

    test "**/ collapses to zero segments — matches files directly under the prefix" do
      assert Shared.glob_match?("test/**/*.exs", "test/test_helper.exs")
    end

    test "a different top-level dir does not match" do
      refute Shared.glob_match?("test/**/*.exs", "lib/foo.ex")
    end

    test "a directory-prefix glob matches files at any depth below it" do
      assert Shared.glob_match?("lib/legacy/**", "lib/legacy/a.ex")
      assert Shared.glob_match?("lib/legacy/**", "lib/legacy/deep/a.ex")
    end

    test "a directory-prefix glob does not match a sibling dir" do
      refute Shared.glob_match?("lib/legacy/**", "lib/core/a.ex")
    end

    test "* stays within a single segment (no slash)" do
      assert Shared.glob_match?("lib/*.ex", "lib/foo.ex")
      refute Shared.glob_match?("lib/*.ex", "lib/sub/foo.ex")
    end

    test "brace alternation expands" do
      assert Shared.glob_match?("test/**/*.{ex,exs}", "test/x_test.exs")
      assert Shared.glob_match?("test/**/*.{ex,exs}", "test/sub/x.ex")
      refute Shared.glob_match?("test/**/*.{ex,exs}", "test/sub/x.heex")
    end
  end

  describe "skipped_for_file/3 — disable_for_glob" do
    test "a file matching a module's glob adds that module to the skip set" do
      glob_config = %{disable_for_glob: %{SomeRefactor => ["test/**/*.exs"]}}

      assert SomeRefactor in Refactor.skipped_for_file("test/foo_test.exs", [], glob_config)
    end

    test "a non-matching file does not skip the module" do
      glob_config = %{disable_for_glob: %{SomeRefactor => ["test/**/*.exs"]}}

      refute SomeRefactor in Refactor.skipped_for_file("lib/foo.ex", [], glob_config)
    end

    test "a different module is unaffected" do
      glob_config = %{disable_for_glob: %{SomeRefactor => ["test/**/*.exs"]}}

      refute OtherRefactor in Refactor.skipped_for_file("test/foo_test.exs", [], glob_config)
    end

    test "the base skip set is always preserved" do
      glob_config = %{disable_for_glob: %{}}

      assert BaseSkip in Refactor.skipped_for_file("lib/foo.ex", [BaseSkip], glob_config)
    end

    test "no config leaves the base skip set untouched" do
      assert Refactor.skipped_for_file("lib/foo.ex", [BaseSkip], %{}) == [BaseSkip]
    end
  end

  describe "skipped_for_file/3 — enable_in_tests sugar over disable_for_glob" do
    test "enable_in_tests: false (default) skips ExtractMagicNumber on a test path only" do
      config = %{enable_in_tests: false}

      assert @extract_magic_number in Refactor.skipped_for_file("test/x_test.exs", [], config)
      refute @extract_magic_number in Refactor.skipped_for_file("lib/x.ex", [], config)
    end

    test "enable_in_tests: false skips ExtractMagicNumber for a .ex test path too" do
      config = %{enable_in_tests: false}

      assert @extract_magic_number in Refactor.skipped_for_file("test/support/x.ex", [], config)
    end

    test "enable_in_tests: true does not skip ExtractMagicNumber on either path" do
      config = %{enable_in_tests: true}

      refute @extract_magic_number in Refactor.skipped_for_file("test/x_test.exs", [], config)
      refute @extract_magic_number in Refactor.skipped_for_file("lib/x.ex", [], config)
    end

    test "enable_in_tests: false skips ALL literal hoisters on a test path" do
      config = %{enable_in_tests: false}
      skipped = Refactor.skipped_for_file("test/x_test.exs", [], config)

      for module <- @literal_hoisters, do: assert(module in skipped)
    end

    test "enable_in_tests: false skips none of the literal hoisters on a lib path" do
      config = %{enable_in_tests: false}
      skipped = Refactor.skipped_for_file("lib/x.ex", [], config)

      for module <- @literal_hoisters, do: refute(module in skipped)
    end

    test "enable_in_tests: true leaves every literal hoister active on a test path" do
      config = %{enable_in_tests: true}
      skipped = Refactor.skipped_for_file("test/x_test.exs", [], config)

      for module <- @literal_hoisters, do: refute(module in skipped)
    end

    test "the test-gate touches only the literal hoisters, not arbitrary refactors" do
      config = %{enable_in_tests: false}

      refute OtherRefactor in Refactor.skipped_for_file("test/x_test.exs", [], config)
    end
  end

  describe "end-to-end: enable_in_tests gates ExtractMagicNumber per file (real Engine)" do
    @magic_source """
    defmodule Sample do
      def a, do: connect(timeout: 5000)
      def b, do: reconnect(timeout: 5000)
    end
    """

    setup do
      config = %{enable_in_tests: false}

      engine_opts = [
        configured_modules: [{@extract_magic_number, enabled: true}],
        only_modules: [@extract_magic_number]
      ]

      {:ok, config: config, engine_opts: engine_opts}
    end

    test "lib file is rewritten (magic number hoisted)", %{config: c, engine_opts: opts} do
      lib_opts = Keyword.put(opts, :skipped_modules, Refactor.skipped_for_file("lib/x.ex", [], c))

      assert Number42.Refactors.Engine.run(@magic_source, lib_opts).changed?
    end

    test "test file is left untouched (gate fires)", %{config: c, engine_opts: opts} do
      test_opts =
        Keyword.put(opts, :skipped_modules, Refactor.skipped_for_file("test/x_test.exs", [], c))

      refute Number42.Refactors.Engine.run(@magic_source, test_opts).changed?
    end

    test "enable_in_tests: true rewrites the test file too", %{engine_opts: opts} do
      c = %{enable_in_tests: true}

      test_opts =
        Keyword.put(opts, :skipped_modules, Refactor.skipped_for_file("test/x_test.exs", [], c))

      assert Number42.Refactors.Engine.run(@magic_source, test_opts).changed?
    end
  end

  # These cover the `--auto` staging fix (#237): a file generated by a
  # refactor during `prepare/1` (e.g. ExtractSharedModule's `*.Shared`
  # host) lands on disk but isn't in the per-unit `paths` the auto-stager
  # knows about. Without picking up the working-tree delta it stays
  # untracked and gets re-created every fixpoint pass, so the run never
  # converges. `stage_paths/3` snapshots the tree before the unit and
  # stages exactly what appeared afterwards.

  describe "parse_porcelain/1" do
    test "extracts paths from untracked, modified and added entries" do
      output = """
      ?? lib/my_app/items/shared.ex
       M lib/my_app/items.ex
      A  lib/new_file.ex
      """

      assert Refactor.parse_porcelain(output) ==
               MapSet.new([
                 "lib/my_app/items/shared.ex",
                 "lib/my_app/items.ex",
                 "lib/new_file.ex"
               ])
    end

    test "keeps the destination path for renames" do
      output = "R  lib/old_name.ex -> lib/new_name.ex\n"

      assert Refactor.parse_porcelain(output) ==
               MapSet.new(["lib/new_name.ex"])
    end

    test "is empty for a clean tree" do
      assert Refactor.parse_porcelain("") == MapSet.new()
    end
  end

  describe "stage_paths/3 (real git repo)" do
    setup do
      repo =
        Path.join(System.tmp_dir!(), "refactor_stage_#{System.unique_integer([:positive])}")

      File.mkdir_p!(repo)
      git!(repo, ["init", "-q"])
      git!(repo, ["config", "user.email", "test@example.com"])
      git!(repo, ["config", "user.name", "Test"])

      File.write!(Path.join(repo, "a.ex"), "defmodule A do\nend\n")
      git!(repo, ["add", "a.ex"])
      git!(repo, ["commit", "-q", "-m", "init"])

      on_exit(fn -> File.rm_rf!(repo) end)
      {:ok, repo: repo}
    end

    test "stages a file the unit newly generated, in addition to the input paths", %{repo: repo} do
      # Baseline: tree is clean before the "refactor" runs.
      baseline = Refactor.git_porcelain_paths(repo)
      assert baseline == MapSet.new()

      # The unit modifies its input file *and* generates a brand new one
      # (the `*.Shared` host analogue) that no caller reported as touched.
      File.write!(Path.join(repo, "a.ex"), "defmodule A do\n  def x, do: 1\nend\n")
      File.write!(Path.join(repo, "shared.ex"), "defmodule Shared do\nend\n")

      staged = Refactor.stage_paths(["a.ex"], baseline, repo)

      assert "a.ex" in staged
      assert "shared.ex" in staged
    end

    test "ignores pre-existing dirty files that this unit did not create", %{repo: repo} do
      # A stray untracked file sits in the tree *before* the unit runs.
      File.write!(Path.join(repo, "stray.txt"), "not from the refactor\n")

      baseline = Refactor.git_porcelain_paths(repo)
      assert "stray.txt" in baseline

      # The unit only touches its input and generates one file.
      File.write!(Path.join(repo, "a.ex"), "defmodule A do\n  def x, do: 1\nend\n")
      File.write!(Path.join(repo, "shared.ex"), "defmodule Shared do\nend\n")

      staged = Refactor.stage_paths(["a.ex"], baseline, repo)

      assert "a.ex" in staged
      assert "shared.ex" in staged
      refute "stray.txt" in staged
    end

    test "stages a side-write generated during an unchanged unit (#243)", %{repo: repo} do
      # The unit's own input file does NOT change, but a refactor's
      # `prepare/1` appended to an existing tracked destination. With no
      # input paths to stage, the baseline delta must still surface the
      # modified destination so it can be committed instead of orphaned.
      baseline = Refactor.git_porcelain_paths(repo)
      assert baseline == MapSet.new()

      File.write!(Path.join(repo, "a.ex"), "defmodule A do\n  def y, do: 2\nend\n")

      generated = Refactor.stage_paths([], baseline, repo)

      assert "a.ex" in generated,
             "a destination modified during an unchanged unit was not detected: #{inspect(generated)}"
    end

    test "after staging + commit, the generated file is tracked and the tree converges", %{
      repo: repo
    } do
      baseline = Refactor.git_porcelain_paths(repo)

      File.write!(Path.join(repo, "a.ex"), "defmodule A do\n  def x, do: 1\nend\n")
      File.write!(Path.join(repo, "shared.ex"), "defmodule Shared do\nend\n")

      staged = Refactor.stage_paths(["a.ex"], baseline, repo)
      git!(repo, ["add" | staged])
      git!(repo, ["commit", "-q", "-m", "extract shared"])

      # Convergence: the generated file is now tracked, so a clean tree
      # has no untracked `shared.ex` left to regenerate on the next pass.
      assert Refactor.git_porcelain_paths(repo) == MapSet.new()
      assert {_, 0} = System.cmd("git", ["ls-files", "--error-unmatch", "shared.ex"], cd: repo)
    end
  end

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}):\n#{output}")
    end
  end
end
