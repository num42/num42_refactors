defmodule Number42.Refactors.Ex.ExtractParametricClone.CrossFileTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractParametricClone

  @subject ExtractParametricClone

  # Cross-file emission has two flavours:
  #
  #   * `:suffix` — at least one of the clone-bearing modules has a
  #     known suffix (`Format` / `Formatter` / `Helper` / `Helpers` /
  #     `Shared`). The helper is *appended* to that existing module's
  #     file. Other clone modules get an `import Target, only: [...]`
  #     plus the per-clone rewrite.
  #
  #   * `:lcp_shared` — none of the clone modules has a qualifying
  #     suffix and there's no intra-module concentration. We synthesise
  #     a `{LCP}.Shared` module by writing a *fresh* file (same as
  #     `ExtractSharedModule`).
  #
  # Both side-effects (write to disk) land under `:write_root` exactly
  # like `ExtractSharedModule`. Tests pass a per-test tmp_dir to keep
  # writes contained, and pass `dry_run: true` to assert the planner
  # never writes when the engine is in dry-run mode.

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "extract_parametric_cross_file_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp prepared(sources, opts),
    do: sources |> ExtractParametricClone.build_plan(Keyword.merge([min_mass: 5], opts))

  # ---------------------------------------------------------------------
  # :suffix — helper appended to existing Helper/Formatter/Shared module
  # ---------------------------------------------------------------------

  describe ":suffix — helper landed in the existing Helper module" do
    test "1+1 clone with one Helper module: helper appended; both clones rewritten",
         %{tmp: tmp} do
      a = """
      defmodule MyApp.Foo do
        def emit(t) do
          "until " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      b = """
      defmodule MyApp.Bar.Helper do
        def emit(t) do
          "ago " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/bar/helper.ex"), b}
      ]

      # Pre-write the Helper module file at the location the planner
      # will append to (suffix branch must edit an existing file).
      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      plan = prepared(sources, write_root: tmp)

      result_a = @subject.transform(a, prepared: plan)
      assert result_a =~ "MyApp.Bar.Helper"

      assert result_a =~ ~r/import\s+MyApp\.Bar\.Helper,\s*only:/,
             "expected `import` of host module in caller; got:\n#{result_a}"

      refute result_a =~ "Calendar.strftime",
             "the original `Calendar.strftime` call should be replaced by the helper-call"

      # Helper's own file must now contain the helper.
      helper_file = Path.join(tmp, "lib/my_app/bar/helper.ex")
      assert File.exists?(helper_file)

      helper_src = File.read!(helper_file)
      assert helper_src =~ "defmodule MyApp.Bar.Helper"
      assert helper_src =~ ~r/def(p)?\s+emit_shared/
      assert helper_src =~ "Calendar.strftime"
    end

    test "with dry_run: cross-file plan is populated but no files are written", %{tmp: tmp} do
      # `mix refactor --dry-run` forwards `dry_run: true` into the
      # planner. The plan must still be fully populated (so the diff
      # preview can render), but no helper file may land on disk.
      a = """
      defmodule MyApp.Foo do
        def emit(t) do
          "until " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      b = """
      defmodule MyApp.Bar.Helper do
        def emit(t) do
          "ago " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      sources = [
        {"lib/my_app/foo.ex", a},
        {"lib/my_app/bar/helper.ex", b}
      ]

      plan =
        ExtractParametricClone.build_plan(sources,
          min_mass: 5,
          write_root: tmp,
          dry_run: true
        )

      assert Map.has_key?(plan, MyApp.Foo)
      refute File.exists?(Path.join(tmp, "lib/my_app/bar/helper.ex"))
    end

    test "intra-only sources work without write_root (no cross-file, no writes)" do
      # When no clone group needs cross-file, the planner is happy
      # without `:write_root`. Intra-module emission has no
      # side-effects and produces a usable plan.
      source = """
      defmodule MyApp.Time do
        def format_until(t) do
          "until " <> Calendar.strftime(t, "%H:%M")
        end

        def format_ago(t) do
          "ago " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      plan =
        ExtractParametricClone.build_plan([{"lib/time.ex", source}],
          min_mass: 5,
          dry_run: true
        )

      result = @subject.transform(source, prepared: plan)

      assert result =~ ~r/def(p)?\s+\w*shared/
    end
  end

  describe ":suffix — Helper appended to module that already has its own functions" do
    test "Helper file keeps existing functions; new helper is added before the closing end",
         %{tmp: tmp} do
      a = """
      defmodule MyApp.Foo do
        def emit(t) do
          "until " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      b = """
      defmodule MyApp.Bar.Helper do
        def existing_thing(x), do: x

        def emit(t) do
          "ago " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/bar/helper.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      _plan = prepared(sources, write_root: tmp)

      helper_src = File.read!(Path.join(tmp, "lib/my_app/bar/helper.ex"))

      # existing function preserved
      assert helper_src =~ "def existing_thing"

      # synthesised helper inserted
      assert helper_src =~ ~r/def(p)?\s+emit_shared/
    end
  end

  # ---------------------------------------------------------------------
  # :lcp_shared — fresh {LCP}.Shared module file is written
  # ---------------------------------------------------------------------

  describe ":lcp_shared — fresh Shared module from LCP" do
    test "1+1 clone, no qualifying suffix: writes {LCP}.Shared.ex; both modules import + rewrite",
         %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.Foo do
        def emit(t) do
          "until " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      b = """
      defmodule MyApp.Items.Bar do
        def emit(t) do
          "ago " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/items/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/items/bar.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      plan = prepared(sources, write_root: tmp)

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path), "expected fresh {LCP}.Shared file at #{shared_path}"

      shared_src = File.read!(shared_path)
      assert shared_src =~ "defmodule MyApp.Items.Shared"
      assert shared_src =~ ~r/def\s+emit_shared/

      result_a = @subject.transform(a, prepared: plan)
      assert result_a =~ ~r/import\s+MyApp\.Items\.Shared/
      refute result_a =~ "Calendar.strftime"
    end

    test "LCP < 1 segment → :skip, no file written", %{tmp: tmp} do
      a = """
      defmodule Foo do
        def emit(t) do
          "until " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      b = """
      defmodule Bar do
        def emit(t) do
          "ago " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/foo.ex"), a},
        {Path.join(tmp, "lib/bar.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      _plan = prepared(sources, write_root: tmp)

      assert_unchanged(@subject, a, prepared: prepared(sources, write_root: tmp))
      assert_unchanged(@subject, b, prepared: prepared(sources, write_root: tmp))

      refute File.exists?(Path.join(tmp, "lib/shared.ex"))
    end

    test "predicate function name keeps `?` after the `_shared` suffix", %{tmp: tmp} do
      # `?` and `!` are valid only at the END of an Elixir identifier.
      # Naively appending `_shared` to `references_var?` produces
      # `references_var?_shared`, which is a parse error. Strip the
      # marker, append `_shared`, then put the marker back.
      a = """
      defmodule MyApp.Items.Foo do
        def references_var?(ast, name) do
          ast |> Macro.prewalker() |> Enum.any?(&match?({^name, _, _}, &1)) and is_atom(name)
        end
      end
      """

      b = """
      defmodule MyApp.Items.Bar do
        def references_var?(ast, name) do
          ast |> Macro.prewalker() |> Enum.any?(&match?({^name, _, _}, &1)) and is_atom(name)
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/items/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/items/bar.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      plan = prepared(sources, write_root: tmp)

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path)

      shared_src = File.read!(shared_path)
      assert shared_src =~ ~r/def\s+references_var_shared\?/
      refute shared_src =~ "references_var?_shared"

      result_a = @subject.transform(a, prepared: plan)
      assert result_a =~ "references_var_shared?"
      refute result_a =~ "references_var?_shared"
    end

    test "bang function name keeps `!` after the `_shared` suffix", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.Foo do
        def fetch_user!(scope, id) do
          scope.repo.get!(MyApp.User, id) |> MyApp.User.assert_active!(scope)
        end
      end
      """

      b = """
      defmodule MyApp.Items.Bar do
        def fetch_user!(scope, id) do
          scope.repo.get!(MyApp.User, id) |> MyApp.User.assert_active!(scope)
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/items/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/items/bar.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      _plan = prepared(sources, write_root: tmp)

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path)

      shared_src = File.read!(shared_path)
      assert shared_src =~ ~r/def\s+fetch_user_shared!/
      refute shared_src =~ "fetch_user!_shared"
    end
  end

  # ---------------------------------------------------------------------
  # Idempotence: cross-file
  # ---------------------------------------------------------------------

  describe "idempotence — cross-file" do
    test ":lcp_shared run twice doesn't duplicate helpers", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.Foo do
        def emit(t) do
          "until " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      b = """
      defmodule MyApp.Items.Bar do
        def emit(t) do
          "ago " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      sources_v1 = [
        {Path.join(tmp, "lib/my_app/items/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/items/bar.ex"), b}
      ]

      sources_v1
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      plan = prepared(sources_v1, write_root: tmp)
      a_once = @subject.transform(a, prepared: plan)
      b_once = @subject.transform(b, prepared: plan)

      sources_v2 = [
        {Path.join(tmp, "lib/my_app/items/foo.ex"), a_once},
        {Path.join(tmp, "lib/my_app/items/bar.ex"), b_once},
        {Path.join(tmp, "lib/my_app/items/shared.ex"),
         File.read!(Path.join(tmp, "lib/my_app/items/shared.ex"))}
      ]

      plan2 = prepared(sources_v2, write_root: tmp)
      a_twice = @subject.transform(a_once, prepared: plan2)

      norm = fn s -> s |> String.replace(~r/\s+/, " ") |> String.trim() end

      assert norm.(a_once) == norm.(a_twice), """
      Cross-file refactor not idempotent:
      --- once ---
      #{a_once}
      --- twice ---
      #{a_twice}
      """
    end
  end

  # ---------------------------------------------------------------------
  # ExDNA-style regression cases
  # ---------------------------------------------------------------------

  describe "regression — embedding_openai/embedding_ollama style" do
    # Two modules under the same parent define near-identical functions.
    # Without intra-concentration and without a qualifying suffix, we
    # expect :lcp_shared to kick in and produce {Embedding}.Shared.

    test "two embedding modules under common parent collapse via :lcp_shared", %{tmp: tmp} do
      a = """
      defmodule MyApp.Embedding.OpenAI do
        def embed(text) do
          payload = %{model: "text-embedding-3-small", input: text}
          encoded = Jason.encode!(payload)
          encoded
        end
      end
      """

      b = """
      defmodule MyApp.Embedding.Ollama do
        def embed(text) do
          payload = %{model: "nomic-embed-text", input: text}
          encoded = Jason.encode!(payload)
          encoded
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/embedding/open_ai.ex"), a},
        {Path.join(tmp, "lib/my_app/embedding/ollama.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      plan = prepared(sources, min_mass: 4, write_root: tmp)

      shared_path = Path.join(tmp, "lib/my_app/embedding/shared.ex")
      assert File.exists?(shared_path), "expected {LCP}.Shared at #{shared_path}"

      shared_src = File.read!(shared_path)
      assert shared_src =~ "defmodule MyApp.Embedding.Shared"

      # Caller A is rewritten + imports the shared module.
      result_a = @subject.transform(a, prepared: plan)
      assert result_a =~ ~r/import\s+MyApp\.Embedding\.Shared/
      refute result_a =~ "Jason.encode!"
    end
  end

  # ---------------------------------------------------------------------
  # Body-context migration — aliases, imports, defp helpers, attributes
  # ---------------------------------------------------------------------

  describe "alias qualification — body uses Source's aliases" do
    test "aliased call in body becomes fully qualified in the helper", %{tmp: tmp} do
      # Both source modules `alias MyApp.Repo`. The Shared module
      # itself never sees that alias declaration; the helper body must
      # qualify the call to `MyApp.Repo.all(...)` so it resolves there.
      a = """
      defmodule MyApp.Items.Foo do
        alias MyApp.Repo

        def list_things(scope) do
          scope
          |> Repo.all()
          |> Enum.map(fn x -> {:foo, x} end)
        end
      end
      """

      b = """
      defmodule MyApp.Items.Bar do
        alias MyApp.Repo

        def list_things(scope) do
          scope
          |> Repo.all()
          |> Enum.map(fn x -> {:bar, x} end)
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/items/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/items/bar.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      _plan = prepared(sources, min_mass: 4, write_root: tmp)

      shared_src = File.read!(Path.join(tmp, "lib/my_app/items/shared.ex"))

      # The helper body must use the FULL module path, not the alias.
      assert shared_src =~ "MyApp.Repo.all",
             "expected fully-qualified `MyApp.Repo.all` in shared module:\n#{shared_src}"

      refute shared_src =~ ~r/^\s*alias\s+/m,
             "shared module should not declare aliases (qualified at use-site instead):\n#{shared_src}"
    end

    test "multi-segment alias `alias A.B.C` is fully qualified", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.Foo do
        alias MyApp.Some.Deep.Module

        def proc(x) do
          Module.work(x, "alpha")
        end
      end
      """

      b = """
      defmodule MyApp.Items.Bar do
        alias MyApp.Some.Deep.Module

        def proc(x) do
          Module.work(x, "beta")
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/items/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/items/bar.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      _plan = prepared(sources, min_mass: 3, write_root: tmp)
      shared_src = File.read!(Path.join(tmp, "lib/my_app/items/shared.ex"))
      assert shared_src =~ "MyApp.Some.Deep.Module.work"
    end
  end

  describe "import propagation — Ecto.Query and friends" do
    test "Ecto.Query macros (where/select) → import propagated to shared module",
         %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.Foo do
        import Ecto.Query
        alias MyApp.Repo

        def list_active(scope) do
          scope
          |> where([i], i.status == "active")
          |> select([i], {:foo, i.id})
          |> Repo.all()
        end
      end
      """

      b = """
      defmodule MyApp.Items.Bar do
        import Ecto.Query
        alias MyApp.Repo

        def list_active(scope) do
          scope
          |> where([i], i.status == "active")
          |> select([i], {:bar, i.id})
          |> Repo.all()
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/items/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/items/bar.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      _plan = prepared(sources, min_mass: 4, write_root: tmp)
      shared_src = File.read!(Path.join(tmp, "lib/my_app/items/shared.ex"))

      assert shared_src =~ ~r/^\s*import\s+Ecto\.Query/m,
             "expected `import Ecto.Query` in shared module:\n#{shared_src}"
    end

    test "diverging imports between source modules → clone group rejected",
         %{tmp: tmp} do
      # Source A imports Ecto.Query, source B doesn't. Even though the
      # ASTs of `list_active` happen to be identical, we can't safely
      # extract because the body's macros only resolve under one
      # module's import set. Reject the group.
      a = """
      defmodule MyApp.Items.Foo do
        import Ecto.Query

        def list_active(scope) do
          scope
          |> where([i], i.status == "active")
          |> select([i], {:foo, i.id})
        end
      end
      """

      b = """
      defmodule MyApp.Items.Bar do
        def list_active(scope) do
          scope
          |> where([i], i.status == "active")
          |> select([i], {:bar, i.id})
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/items/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/items/bar.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      _plan = prepared(sources, min_mass: 4, write_root: tmp)

      refute File.exists?(Path.join(tmp, "lib/my_app/items/shared.ex")),
             "expected NOT to create a Shared module for clones with diverging imports"
    end
  end

  describe "local defp helper migration — transitively reachable" do
    test "body calls a defp only used by the cloned function → defp migrated",
         %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.Foo do
        def emit(t) do
          prefix = "until "
          prefix <> format_time(t)
        end

        defp format_time(t) do
          to_string(t) <> " UTC"
        end
      end
      """

      b = """
      defmodule MyApp.Items.Bar do
        def emit(t) do
          prefix = "ago "
          prefix <> format_time(t)
        end

        defp format_time(t) do
          to_string(t) <> " UTC"
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/items/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/items/bar.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      _plan = prepared(sources, min_mass: 5, write_root: tmp)
      shared_src = File.read!(Path.join(tmp, "lib/my_app/items/shared.ex"))

      assert shared_src =~ ~r/def(p)?\s+format_time/,
             "expected `format_time` helper to be migrated:\n#{shared_src}"

      assert shared_src =~ "to_string"
    end

    test "defp also called by another (non-clone) def → NOT migrated, group rejected",
         %{tmp: tmp} do
      # `format_time/1` is used by both `emit/1` (the clone) AND
      # `other/1` (non-clone). Migrating it would orphan `other/1`.
      a = """
      defmodule MyApp.Items.Foo do
        def emit(t) do
          prefix = "until "
          prefix <> format_time(t)
        end

        def other(t) do
          format_time(t)
        end

        defp format_time(t), do: to_string(t)
      end
      """

      b = """
      defmodule MyApp.Items.Bar do
        def emit(t) do
          prefix = "ago "
          prefix <> format_time(t)
        end

        def other(t) do
          format_time(t)
        end

        defp format_time(t), do: to_string(t)
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/items/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/items/bar.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      _plan = prepared(sources, min_mass: 5, write_root: tmp)

      refute File.exists?(Path.join(tmp, "lib/my_app/items/shared.ex")),
             "expected the clone group to be rejected (defp shared with non-clone caller)"
    end
  end

  describe "module attribute migration" do
    test "body references `@retries` with identical literal value → @retries migrated",
         %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.Foo do
        @retries 3

        def fetch(t) do
          {@retries, "until " <> to_string(t)}
        end
      end
      """

      b = """
      defmodule MyApp.Items.Bar do
        @retries 3

        def fetch(t) do
          {@retries, "ago " <> to_string(t)}
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/items/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/items/bar.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      _plan = prepared(sources, min_mass: 5, write_root: tmp)
      shared_src = File.read!(Path.join(tmp, "lib/my_app/items/shared.ex"))

      assert shared_src =~ ~r/@retries\s+3/,
             "expected `@retries 3` in shared module:\n#{shared_src}"
    end

    test "diverging @-values across sources → group rejected", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.Foo do
        @retries 3

        def fetch(t) do
          {@retries, "until " <> to_string(t)}
        end
      end
      """

      b = """
      defmodule MyApp.Items.Bar do
        @retries 5

        def fetch(t) do
          {@retries, "ago " <> to_string(t)}
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/items/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/items/bar.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      _plan = prepared(sources, min_mass: 5, write_root: tmp)

      refute File.exists?(Path.join(tmp, "lib/my_app/items/shared.ex")),
             "expected rejection on diverging @retries"
    end

    test "non-literal @-value (function call) → group rejected", %{tmp: tmp} do
      a = """
      defmodule MyApp.Items.Foo do
        @retries System.get_env("RETRIES")

        def fetch(t) do
          {@retries, "until " <> to_string(t)}
        end
      end
      """

      b = """
      defmodule MyApp.Items.Bar do
        @retries System.get_env("RETRIES")

        def fetch(t) do
          {@retries, "ago " <> to_string(t)}
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/items/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/items/bar.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      _plan = prepared(sources, min_mass: 5, write_root: tmp)

      refute File.exists?(Path.join(tmp, "lib/my_app/items/shared.ex")),
             "expected rejection on non-literal @-value (System.get_env)"
    end
  end

  # ---------------------------------------------------------------------
  # #9 — fresh Shared file lands in the real lib subdir, not a naive
  # Macro.underscore of the namespace.
  # ---------------------------------------------------------------------

  describe "lib path derivation (#9)" do
    test "namespace whose underscore differs from the on-disk dir writes to the real dir",
         %{tmp: tmp} do
      # `Macro.underscore("CodeQA")` == "code_qa", but the project lays
      # the namespace out under `lib/codeqa/`. The fresh Shared file must
      # follow the on-disk layout, not the naive underscore.
      a = """
      defmodule CodeQA.AST.Nodes.Foo do
        def emit(t) do
          "until " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      b = """
      defmodule CodeQA.AST.Nodes.Bar do
        def emit(t) do
          "ago " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/codeqa/ast/nodes/foo.ex"), a},
        {Path.join(tmp, "lib/codeqa/ast/nodes/bar.ex"), b}
      ]

      sources
      |> Enum.each(fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      _plan = prepared(sources, write_root: tmp)

      real_path = Path.join(tmp, "lib/codeqa/ast/nodes/shared.ex")
      naive_path = Path.join(tmp, "lib/code_qa/ast/nodes/shared.ex")

      assert File.exists?(real_path),
             "expected fresh Shared file at the real on-disk dir #{real_path}"

      refute File.exists?(naive_path),
             "must not create a duplicate top-level dir from Macro.underscore"

      shared_src = File.read!(real_path)
      assert shared_src =~ "defmodule CodeQA.AST.Nodes.Shared"
    end
  end

  describe "lexically-scoped macros in clone body" do
    # `__MODULE__` resolves against the lexical module. When a cross-file
    # clone body uses it, the helper is lifted into a `*.Shared` module
    # where `__MODULE__` would rebind to the struct-less shared module.
    # So the cross-file emitter parametrises it: the module is threaded
    # in as a first argument, `%__MODULE__{...}` becomes
    # `struct!(module, ...)`, and each caller passes its own
    # `__MODULE__`. `__ENV__`/`__CALLER__`/`__DIR__`/`__STACKTRACE__`
    # have no runtime value to pass, so a clone body using one is still
    # skipped.

    defp assert_compiles!(src, label) do
      mods = Code.compile_string(src)
      Enum.each(mods, fn {mod, _bin} -> :code.purge(mod) and :code.delete(mod) end)
      :ok
    rescue
      e ->
        flunk("#{label} did not compile:\n#{src}\n\n#{Exception.message(e)}")
    end

    test "six `%__MODULE__{}` struct clones → struct!/2 helper that compiles", %{tmp: tmp} do
      # Issue #5 repro: six modules with an identical `cast/1` building
      # `%__MODULE__{}`. Extracting verbatim into a `*.Shared` module
      # rebinds `__MODULE__` to the struct-less Shared module and fails
      # to compile. Option A: parametrise the module — emit
      # `cast_shared(module, node) -> struct!(module, ...)` and have each
      # caller pass `__MODULE__`.
      mk = fn name ->
        """
        defmodule CodeQA.AST.Nodes.#{name} do
          alias CodeQA.AST.Enrichment.Node
          defstruct [:tokens, :line_count, :children, :start_line, :end_line, :label]

          def cast(%Node{} = node) do
            %__MODULE__{
              tokens: node.tokens,
              line_count: node.line_count,
              children: node.children,
              start_line: node.start_line,
              end_line: node.end_line,
              label: node.label
            }
          end
        end
        """
      end

      names = ~w(CodeNode DocNode FunctionNode ImportNode ModuleNode TestNode)

      sources =
        names
        |> Enum.map(fn n ->
          p = Path.join(tmp, "lib/codeqa/ast/nodes/#{Macro.underscore(n)}.ex")
          src = mk.(n)
          File.mkdir_p!(Path.dirname(p))
          File.write!(p, src)
          {p, src}
        end)

      plan = prepared(sources, write_root: tmp)

      [shared] = Path.wildcard(Path.join(tmp, "**/shared.ex"))
      shared_src = File.read!(shared)

      # struct!/2 with the module as the first parameter, no bare
      # `%__MODULE__{}` left to rebind.
      assert shared_src =~ "struct!(module"
      refute shared_src =~ "%__MODULE__"

      # The lifted Shared module compiles — the original bug is gone.
      assert_compiles!(shared_src, "Shared module")

      # Every caller passes its own `__MODULE__` and imports arity 2.
      Enum.each(sources, fn {_p, src} ->
        out = apply_refactor(@subject, src, prepared: plan)
        assert out =~ "cast_shared(__MODULE__, node)"
        assert out =~ "cast_shared: 2"
      end)
    end

    test "bare `__MODULE__` (non-struct) cross-file clone → module var, compiles", %{tmp: tmp} do
      # `__MODULE__` outside a struct literal is parametrised the same
      # way: the bare reference becomes the threaded-in module var.
      mk = fn name ->
        """
        defmodule MyApp.Reg.#{name} do
          def reg(x) do
            {__MODULE__, :tag, to_string(x), String.upcase(to_string(x))}
          end
        end
        """
      end

      sources =
        ~w(Foo Bar)
        |> Enum.map(fn n ->
          p = Path.join(tmp, "lib/my_app/reg/#{Macro.underscore(n)}.ex")
          src = mk.(n)
          File.mkdir_p!(Path.dirname(p))
          File.write!(p, src)
          {p, src}
        end)

      plan = prepared(sources, min_mass: 4, write_root: tmp)

      [shared] = Path.wildcard(Path.join(tmp, "**/shared.ex"))
      shared_src = File.read!(shared)

      # The helper takes the module first and uses it in the tuple;
      # no bare `__MODULE__` survives in the lifted body.
      assert shared_src =~ "reg_shared(module"
      refute shared_src =~ "__MODULE__"
      assert_compiles!(shared_src, "Shared module (bare __MODULE__)")

      Enum.each(sources, fn {_p, src} ->
        out = apply_refactor(@subject, src, prepared: plan)
        assert out =~ "reg_shared(__MODULE__"
      end)
    end

    test "`__ENV__` in clone body → group skipped", %{tmp: tmp} do
      mk = fn name ->
        """
        defmodule MyApp.Items.#{name} do
          def trace(x) do
            mod = __ENV__.module
            {mod, "tag", to_string(x), String.upcase(to_string(x))}
          end
        end
        """
      end

      sources =
        ~w(Foo Bar)
        |> Enum.map(fn n ->
          p = Path.join(tmp, "lib/my_app/items/#{Macro.underscore(n)}.ex")
          src = mk.(n)
          File.mkdir_p!(Path.dirname(p))
          File.write!(p, src)
          {p, src}
        end)

      _plan = prepared(sources, min_mass: 4, write_root: tmp)

      refute File.exists?(Path.join(tmp, "lib/my_app/items/shared.ex")),
             "expected no Shared module when clone body uses `__ENV__`"
    end

    test "`__CALLER__` in clone body → group skipped", %{tmp: tmp} do
      mk = fn name ->
        """
        defmodule MyApp.Items.#{name} do
          defmacro emit(x) do
            caller = __CALLER__.module
            quote do
              {unquote(caller), unquote(x), "lit", to_string(unquote(x))}
            end
          end
        end
        """
      end

      sources =
        ~w(Foo Bar)
        |> Enum.map(fn n ->
          p = Path.join(tmp, "lib/my_app/items/#{Macro.underscore(n)}.ex")
          src = mk.(n)
          File.mkdir_p!(Path.dirname(p))
          File.write!(p, src)
          {p, src}
        end)

      _plan = prepared(sources, min_mass: 4, write_root: tmp)

      refute File.exists?(Path.join(tmp, "lib/my_app/items/shared.ex")),
             "expected no Shared module when clone body uses `__CALLER__`"
    end

    test "a shared `__MODULE__` helper is itself parametrised and compiles", %{tmp: tmp} do
      # A `defp` that two modules share and that uses `__MODULE__` is a
      # clone in its own right: the differing literal becomes an ordinary
      # hole and `__MODULE__` becomes the threaded-in module var. The
      # lifted Shared helper therefore compiles — `__MODULE__` is never
      # left bare in the shared module.
      mk = fn name, tag ->
        """
        defmodule MyApp.Wrap.#{name} do
          def emit(x), do: wrap(x)

          defp wrap(x) do
            {__MODULE__, #{inspect(tag)}, to_string(x), String.upcase(to_string(x))}
          end
        end
        """
      end

      sources =
        [{"Foo", "foo_tag"}, {"Bar", "bar_tag"}]
        |> Enum.map(fn {n, tag} ->
          p = Path.join(tmp, "lib/my_app/wrap/#{Macro.underscore(n)}.ex")
          src = mk.(n, tag)
          File.mkdir_p!(Path.dirname(p))
          File.write!(p, src)
          {p, src}
        end)

      _plan = prepared(sources, min_mass: 4, write_root: tmp)

      [shared] = Path.wildcard(Path.join(tmp, "**/shared.ex"))
      shared_src = File.read!(shared)

      assert shared_src =~ "module"
      refute shared_src =~ "__MODULE__"
      assert_compiles!(shared_src, "Shared helper with __MODULE__")
    end

    test "ordinary clone (no lexical macros) still extracts and Shared compiles", %{tmp: tmp} do
      # Guard against an over-broad skip: a body with no lexical macro
      # must still be extracted, and the emitted Shared module must
      # compile.
      a = """
      defmodule MyApp.Items.Foo do
        def emit(t) do
          "until " <> to_string(t)
        end
      end
      """

      b = """
      defmodule MyApp.Items.Bar do
        def emit(t) do
          "ago " <> to_string(t)
        end
      end
      """

      sources = [
        {Path.join(tmp, "lib/my_app/items/foo.ex"), a},
        {Path.join(tmp, "lib/my_app/items/bar.ex"), b}
      ]

      Enum.each(sources, fn {p, src} ->
        File.mkdir_p!(Path.dirname(p))
        File.write!(p, src)
      end)

      _plan = prepared(sources, min_mass: 4, write_root: tmp)

      shared_path = Path.join(tmp, "lib/my_app/items/shared.ex")
      assert File.exists?(shared_path), "expected Shared module for ordinary clones"

      assert_compiles!(File.read!(shared_path), "shared module")
    end
  end
end
