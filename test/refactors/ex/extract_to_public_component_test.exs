defmodule Number42.Refactors.Ex.ExtractToPublicComponentTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractToPublicComponent

  @subject ExtractToPublicComponent
  @config %{
    heex: %{
      components_namespace: "MyAppWeb.Components",
      core_components_module: "MyAppWeb.CoreComponents"
    }
  }

  # A data_table motif wrapped in a page section (so it is NOT the whole sigil),
  # in a module that `use MyAppWeb, :live_view` (so imports can be reproduced).
  defp page_with_table(rows_assign) do
    """
    defmodule MyAppWeb.UserListLive do
      use MyAppWeb, :live_view
      import MyAppWeb.TextComponents

      def render(assigns) do
        ~H\"\"\"
        <section class="page">
          <h1>Users</h1>
          <table class="data">
            <thead>
              <tr>
                <th>Name</th>
                <th>Email</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @#{rows_assign}}>
                <td>{row.name}</td>
                <td>{row.email}</td>
              </tr>
            </tbody>
          </table>
        </section>
        \"\"\"
      end
    end
    """
  end

  # A button_group motif carrying phx-click events → stateful live_component.
  defp page_with_buttons do
    """
    defmodule MyAppWeb.ToolbarLive do
      use MyAppWeb, :live_view

      def render(assigns) do
        ~H\"\"\"
        <section class="page">
          <h1>Toolbar</h1>
          <p>Some leading copy so the section is not the button_group itself.</p>
          <div class="toolbar">
            <button phx-click="save">
              {@save_label}
            </button>
            <button phx-click="cancel">
              {@cancel_label}
            </button>
            <button phx-click="reset">
              {@reset_label}
            </button>
            <button phx-click="archive">
              {@archive_label}
            </button>
          </div>
        </section>
        \"\"\"
      end
    end
    """
  end

  defp build(sources, opts \\ []) do
    ExtractToPublicComponent.build_plan(sources, Keyword.put(opts, :project_config, @config))
  end

  describe "find_candidates/2 — motif-driven detection" do
    test "accepts a data_table that is not the whole sigil and classifies it stateless" do
      table =
        page_with_table("rows")
        |> ExtractToPublicComponent.find_candidates()
        |> Enum.find(&(&1.tag == "table"))

      assert table.motif == :data_table
      assert table.component_kind == :function
      assert table.accepted
      assert table.assigns == ["rows"]
      assert table.free_vars == []
    end

    test "a motif with phx-events is classified live_component but DECLINED (#374)" do
      # A stateful (phx-event) motif can't be auto-lifted into a public
      # live_component safely: Phoenix needs a single static root, a
      # guaranteed-unique `id`, and correct `update/2` assign flow, none of
      # which a motif cut can synthesize. It is recognised as a
      # live_component kind but declined.
      group =
        page_with_buttons()
        |> ExtractToPublicComponent.find_candidates()
        |> Enum.find(&(&1.component_kind == :live_component))

      assert group
      refute group.accepted
      assert group.decline =~ "live_component"
    end

    test "declines a motif whose body carries a literal id= (would duplicate on reuse, #374)" do
      # A reusable component invoked more than once would render the same
      # hardcoded DOM id twice → LiveView "Duplicate id found". A literal
      # `id="…"` in the lifted body is declined; a dynamic `id={@x}` is fine.
      src = """
      defmodule MyAppWeb.UserListLive do
        use MyAppWeb, :live_view

        def render(assigns) do
          ~H\"\"\"
          <section class="page">
            <h1>Users</h1>
            <table id="user-table" class="data">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Email</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @rows}>
                  <td>{row.name}</td>
                  <td>{row.email}</td>
                </tr>
              </tbody>
            </table>
          </section>
          \"\"\"
        end
      end
      """

      table =
        src
        |> ExtractToPublicComponent.find_candidates()
        |> Enum.find(&(&1.tag == "table"))

      assert table
      refute table.accepted
      assert table.decline =~ "literal id"
    end

    test "declines a subtree with no recognised motif" do
      amorphous = """
      defmodule MyAppWeb.X do
        use MyAppWeb, :live_view

        def render(assigns) do
          ~H\"\"\"
          <section class="page">
            <div class="wrapper">
              <div class="inner">
                <span>{@a}</span>
                <span>{@b}</span>
                <span>{@c}</span>
                <span>{@d}</span>
                <span>{@e}</span>
                <span>{@f}</span>
              </div>
            </div>
          </section>
          \"\"\"
        end
      end
      """

      cands = ExtractToPublicComponent.find_candidates(amorphous)
      assert Enum.all?(cands, &(not &1.accepted))
      assert Enum.any?(cands, &(&1.decline == "no recognised structural motif"))
    end

    test "declines a body that calls a caller-local function (would be undefined in the new module)" do
      # a data_table whose cell calls a caller-local `cell_label/1` helper
      with_local_call = """
      defmodule MyAppWeb.UserListLive do
        use MyAppWeb, :live_view

        def render(assigns) do
          ~H\"\"\"
          <section class="page">
            <h1>Users</h1>
            <table class="data">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Email</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @rows}>
                  <td>{cell_label(row.name)}</td>
                  <td>{row.email}</td>
                </tr>
              </tbody>
            </table>
          </section>
          \"\"\"
        end

        defp cell_label(value), do: value
      end
      """

      cand =
        with_local_call
        |> ExtractToPublicComponent.find_candidates()
        |> Enum.find(&(&1.tag == "table"))

      refute cand.accepted
      assert cand.decline =~ "caller-local function"
    end

    test "declines a body that calls a caller-local COMPONENT (<.backdrop/>)" do
      with_local_component = """
      defmodule MyAppWeb.Layouts do
        use MyAppWeb, :html

        def page(assigns) do
          ~H\"\"\"
          <main>
            <h1>Layout</h1>
            <section class="page">
              <.backdrop for="toggle" />
              <table class="data">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Email</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @rows}>
                    <td>{row.name}</td>
                    <td>{row.email}</td>
                  </tr>
                </tbody>
              </table>
            </section>
          </main>
          \"\"\"
        end

        defp backdrop(assigns), do: ~H"<div class=\\"backdrop\\" />"
      end
      """

      cand =
        with_local_component
        |> ExtractToPublicComponent.find_candidates()
        |> Enum.find(&(&1.tag == "section"))

      refute cand.accepted
      assert cand.decline =~ "caller-local function backdrop"
    end

    test "declines when the caller has no `use <App>Web` to reproduce" do
      no_use = """
      defmodule Bare do
        def render(assigns) do
          ~H\"\"\"
          <section class="page">
            <table class="data">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Email</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @rows}>
                  <td>{row.name}</td>
                  <td>{row.email}</td>
                </tr>
              </tbody>
            </table>
          </section>
          \"\"\"
        end
      end
      """

      table =
        no_use
        |> ExtractToPublicComponent.find_candidates()
        |> Enum.find(&(&1.tag == "table"))

      refute table.accepted
      assert table.decline =~ "no `use <App>Web`"
    end
  end

  describe "build_plan/2 — module + naming" do
    test "names the module by motif under the configured namespace" do
      [plan] = build(%{"lib/a.ex" => page_with_table("rows")})
      assert plan.name == :data_table
      assert plan.module == "MyAppWeb.Components.DataTable"
      assert plan.component_kind == :function
    end

    test "excludes the configured CoreComponents module as a source" do
      core = """
      defmodule MyAppWeb.CoreComponents do
        use MyAppWeb, :html

        def render(assigns) do
          ~H\"\"\"
          <section class="page">
            <table class="data">
              <thead><tr><th>A</th><th>B</th></tr></thead>
              <tbody>
                <tr :for={row <- @rows}>
                  <td>{row.a}</td>
                  <td>{row.b}</td>
                </tr>
              </tbody>
            </table>
          </section>
          \"\"\"
        end
      end
      """

      {:ok, prepared} =
        ExtractToPublicComponent.prepare(
          source_files: write_tmp(%{"core_components.ex" => core}),
          project_config: @config
        )

      assert prepared.plans == []
    end

    test "structurally identical tables with same assigns share one module" do
      sources = %{
        "lib/a.ex" => page_with_table("rows"),
        "lib/b.ex" => String.replace(page_with_table("rows"), "UserListLive", "OtherLive")
      }

      plans = build(sources)
      assert plans |> Enum.map(& &1.module) |> Enum.uniq() == ["MyAppWeb.Components.DataTable"]
    end
  end

  describe "transform/2 — rewrite (enabled, dry_run)" do
    test "rewrites a stateless occurrence to <Alias.name/> and adds the alias" do
      src = page_with_table("rows")
      sources = %{"lib/a.ex" => src}
      plans = build(sources)
      prepared = %{plans: plans, source_to_file: %{src => "lib/a.ex"}}

      out =
        @subject.transform(src,
          enabled: true,
          dry_run: true,
          prepared: prepared,
          project_config: @config
        )

      refute out =~ ~s(<thead>)
      assert out =~ "<DataTable.data_table rows={@rows} />"
      assert out =~ "alias MyAppWeb.Components.DataTable"
    end

    test "a stateful (phx-event) occurrence is left unchanged — live_components are declined (#374)" do
      src = page_with_buttons()
      sources = %{"lib/a.ex" => src}
      plans = build(sources)
      prepared = %{plans: plans, source_to_file: %{src => "lib/a.ex"}}

      out =
        @subject.transform(src,
          enabled: true,
          dry_run: true,
          prepared: prepared,
          project_config: @config
        )

      # No live_component plan survives, so the stateful motif stays put.
      refute out =~ "<.live_component"
      refute Enum.any?(plans, &(&1.component_kind == :live_component))
    end

    test "is a no-op without enabled: true" do
      src = page_with_table("rows")
      plans = build(%{"lib/a.ex" => src})

      out =
        @subject.transform(src,
          dry_run: true,
          prepared: %{plans: plans, source_to_file: %{src => "lib/a.ex"}},
          project_config: @config
        )

      assert out == src
    end
  end

  describe "module file generation" do
    test "writes a stateless function-component module keeping used directives, dropping unused aliases" do
      # body uses `Formatting.humanize/1` → that alias is kept; the unused
      # `alias MyAppWeb.Other` is dropped; a plain `import` is always kept
      # (it may expose snake_case component funcs the body calls).
      src = """
      defmodule MyAppWeb.UserListLive do
        use MyAppWeb, :live_view
        import MyAppWeb.TextComponents
        alias MyAppWeb.Helpers.Formatting
        alias MyAppWeb.Helpers.Unused

        def render(assigns) do
          ~H\"\"\"
          <section class="page">
            <h1>Users</h1>
            <table class="data">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Email</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @rows}>
                  <td><.badge>{Formatting.humanize(row.name)}</.badge></td>
                  <td>{row.email}</td>
                </tr>
              </tbody>
            </table>
          </section>
          \"\"\"
        end
      end
      """

      root = unique_tmp_dir()
      caller = "lib/my_app_web/live/user_list_live.ex"
      sources = %{caller => src}
      plans = build(sources)
      prepared = %{plans: plans, source_to_file: %{src => caller}}

      @subject.transform(src,
        enabled: true,
        write_root: root,
        file: caller,
        prepared: prepared,
        project_config: @config
      )

      path = Path.join(root, "lib/my_app_web/components/data_table.ex")
      assert File.exists?(path)
      module = File.read!(path)

      assert module =~ "defmodule MyAppWeb.Components.DataTable do"
      assert module =~ "use MyAppWeb, :html"
      # alias whose name the body references is kept
      assert module =~ "alias MyAppWeb.Helpers.Formatting"
      # unused alias is dropped (no warning litter)
      refute module =~ "alias MyAppWeb.Helpers.Unused"
      # body has a local `<.badge>` → plain import kept (may expose it)
      assert module =~ "import MyAppWeb.TextComponents"
      assert module =~ "attr :rows"
      assert module =~ "def data_table(assigns)"
    end

    test "drops plain imports when the body has no local component tag (pure HTML)" do
      src = """
      defmodule MyAppWeb.UserListLive do
        use MyAppWeb, :live_view
        import MyAppWeb.TextComponents

        def render(assigns) do
          ~H\"\"\"
          <section class="page">
            <h1>Users</h1>
            <table class="data">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Email</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @rows}>
                  <td>{row.name}</td>
                  <td>{row.email}</td>
                </tr>
              </tbody>
            </table>
          </section>
          \"\"\"
        end
      end
      """

      root = unique_tmp_dir()
      caller = "lib/my_app_web/live/user_list_live.ex"
      plans = build(%{caller => src})
      prepared = %{plans: plans, source_to_file: %{src => caller}}

      @subject.transform(src,
        enabled: true,
        write_root: root,
        file: caller,
        prepared: prepared,
        project_config: @config
      )

      module = File.read!(Path.join(root, "lib/my_app_web/components/data_table.ex"))
      refute module =~ "import MyAppWeb.TextComponents"
    end

    test "no live_component module is written — stateful motifs are declined (#374)" do
      src = page_with_buttons()
      root = unique_tmp_dir()
      caller = "lib/my_app_web/live/toolbar_live.ex"
      sources = %{caller => src}
      plans = build(sources)
      prepared = %{plans: plans, source_to_file: %{src => caller}}

      @subject.transform(src,
        enabled: true,
        write_root: root,
        file: caller,
        prepared: prepared,
        project_config: @config
      )

      # No live_component plan survives, so no module file is generated.
      refute File.exists?(Path.join(root, "lib/my_app_web/components/button_group.ex"))
      refute Enum.any?(plans, &(&1.component_kind == :live_component))
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp unique_tmp_dir do
    dir = Path.join(System.tmp_dir!(), "etpc-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_tmp(files) do
    dir = unique_tmp_dir()

    for {name, src} <- files do
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, src)
      path
    end
  end
end
