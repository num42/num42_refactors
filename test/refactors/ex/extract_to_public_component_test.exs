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
    test "names the module by motif qualified with the dominant assign" do
      # data_table motif + dominant @rows assign → rows_table / RowsTable
      [plan] = build(%{"lib/a.ex" => page_with_table("rows")})
      assert plan.name == :rows_table
      assert plan.module == "MyAppWeb.Components.RowsTable"
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
      assert plans |> Enum.map(& &1.module) |> Enum.uniq() == ["MyAppWeb.Components.RowsTable"]
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
      assert out =~ "<RowsTable.rows_table rows={@rows} />"
      assert out =~ "alias MyAppWeb.Components.RowsTable"
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

  describe "transform/2 — caller directive cleanup after extraction" do
    # A caller that uses `MediaUrl` ONLY inside the extracted table, plus
    # `ValueLabels` in code OUTSIDE it. After the lift, MediaUrl is dead in the
    # caller (it moved into the component) and must be dropped; ValueLabels is
    # still used in code and must survive.
    defp caller_with_mixed_directives do
      """
      defmodule MyAppWeb.UserListLive do
        use MyAppWeb, :live_view
        alias MyAppWeb.Helpers.MediaUrl
        alias MyAppWeb.Helpers.ValueLabels

        def label, do: ValueLabels.format(:x)

        def render(assigns) do
          ~H\"\"\"
          <section class="page">
            <h1>Users</h1>
            <table class="data">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Link</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @rows}>
                  <td>{row.name}</td>
                  <td><a href={MediaUrl.download_original_url(row)}>open</a></td>
                </tr>
              </tbody>
            </table>
          </section>
          \"\"\"
        end
      end
      """
    end

    test "drops an alias used only inside the extracted subtree" do
      src = caller_with_mixed_directives()
      plans = build(%{"lib/a.ex" => src})

      out =
        @subject.transform(src,
          enabled: true,
          dry_run: true,
          prepared: %{plans: plans, source_to_file: %{src => "lib/a.ex"}},
          project_config: @config
        )

      # MediaUrl moved into the component → dead in the caller → dropped
      refute out =~ "alias MyAppWeb.Helpers.MediaUrl"
    end

    test "keeps an alias still used in caller code outside the subtree" do
      src = caller_with_mixed_directives()
      plans = build(%{"lib/a.ex" => src})

      out =
        @subject.transform(src,
          enabled: true,
          dry_run: true,
          prepared: %{plans: plans, source_to_file: %{src => "lib/a.ex"}},
          project_config: @config
        )

      # ValueLabels is referenced in `label/0` → must survive the prune
      assert out =~ "alias MyAppWeb.Helpers.ValueLabels"
      assert out =~ "ValueLabels.format(:x)"
    end

    test "keeps an `as:`-renamed alias still used by its `as:` name" do
      # the prune must check the introduced name (the `as:` target), not the
      # module's last segment: `alias Foo.Formatter, as: AssetUseFormatter` is
      # alive while `AssetUseFormatter.x(...)` is referenced.
      src = """
      defmodule MyAppWeb.UserListLive do
        use MyAppWeb, :live_view
        alias MyAppWeb.Types.AssetUse.Formatter, as: AssetUseFormatter

        @groups [{:images, AssetUseFormatter.group_label(:images)}]

        def groups, do: @groups

        def render(assigns) do
          ~H\"\"\"
          <section class="page">
            <h1>Users</h1>
            <table class="data">
              <thead><tr><th>Name</th><th>X</th></tr></thead>
              <tbody>
                <tr :for={row <- @rows}>
                  <td>{row.name}</td>
                  <td>{row.x}</td>
                </tr>
              </tbody>
            </table>
          </section>
          \"\"\"
        end
      end
      """

      plans = build(%{"lib/a.ex" => src})

      out =
        @subject.transform(src,
          enabled: true,
          dry_run: true,
          prepared: %{plans: plans, source_to_file: %{src => "lib/a.ex"}},
          project_config: @config
        )

      assert out =~ "as: AssetUseFormatter"
      assert out =~ "AssetUseFormatter.group_label(:images)"
    end

    test "keeps an `import …, only:` whose function is still used as a HEEx tag" do
      # `import …ItemRow, only: [item_row: 1]` is alive while `<.item_row>` is
      # used outside the extracted subtree — the tag form must count as a use.
      src = """
      defmodule MyAppWeb.UserListLive do
        use MyAppWeb, :live_view
        import MyAppWeb.Components.ItemRow, only: [item_row: 1]

        def render(assigns) do
          ~H\"\"\"
          <section class="page">
            <h1>Users</h1>
            <.item_row label="kept" />
            <table class="data">
              <thead><tr><th>Name</th><th>X</th></tr></thead>
              <tbody>
                <tr :for={row <- @rows}>
                  <td>{row.name}</td>
                  <td>{row.x}</td>
                </tr>
              </tbody>
            </table>
          </section>
          \"\"\"
        end
      end
      """

      plans = build(%{"lib/a.ex" => src})

      out =
        @subject.transform(src,
          enabled: true,
          dry_run: true,
          prepared: %{plans: plans, source_to_file: %{src => "lib/a.ex"}},
          project_config: @config
        )

      assert out =~ "import MyAppWeb.Components.ItemRow, only: [item_row: 1]"
    end

    test "prunes a plain import resolved via the corpus when none of its components is used" do
      # AssetPreview exports asset_preview + pdf_document_viewer; the caller's
      # only use of <.asset_preview> sits inside the extracted table, so after
      # the lift NEITHER component is used → the plain import is dead. Resolved
      # from the corpus, not guessed from the module name.
      preview_mod = """
      defmodule MyAppWeb.Components.AssetPreview do
        use MyAppWeb, :html
        def asset_preview(assigns), do: ~H"<img src={@src} />"
        def pdf_document_viewer(assigns), do: ~H"<object data={@url} />"
      end
      """

      # The <.asset_preview> lives INSIDE a wrapped list block that lifts whole
      # into its own component — so the tag (and its import) move out of the
      # caller, leaving the import dead.
      caller = """
      defmodule MyAppWeb.GalleryLive do
        use MyAppWeb, :live_view
        import MyAppWeb.Components.AssetPreview

        def render(assigns) do
          ~H\"\"\"
          <article class="page">
            <h1>Gallery</h1>
            <section class="assets">
              <h2>Assets</h2>
              <ul class="grid">
                <li :for={asset <- @gallery.assets} class="cell flex flex-col gap-2">
                  <figure class="thumb">
                    <.asset_preview src={asset.src} size="full" />
                  </figure>
                  <span class="title truncate">{asset.title}</span>
                  <a href={asset.href} class="link">open</a>
                </li>
              </ul>
            </section>
          </article>
          \"\"\"
        end
      end
      """

      {:ok, prepared} =
        @subject.prepare(
          source_files: write_tmp(%{"asset_preview.ex" => preview_mod, "caller.ex" => caller}),
          project_config: @config
        )

      out =
        @subject.transform(caller,
          enabled: true,
          dry_run: true,
          prepared: prepared,
          project_config: @config
        )

      # the assets block (with <.asset_preview>) lifted out → import dead → pruned
      refute out =~ "<.asset_preview"
      refute out =~ "import MyAppWeb.Components.AssetPreview"
    end

    test "keeps a corpus-resolved plain import when one of its components is still used" do
      preview_mod = """
      defmodule MyAppWeb.Components.AssetPreview do
        use MyAppWeb, :html
        def asset_preview(assigns), do: ~H"<img src={@src} />"
        def pdf_document_viewer(assigns), do: ~H"<object data={@url} />"
      end
      """

      # <.pdf_document_viewer> sits OUTSIDE the extracted table → import alive,
      # even though the module-name heuristic (asset_preview) would not see it.
      caller = """
      defmodule MyAppWeb.UserListLive do
        use MyAppWeb, :live_view
        import MyAppWeb.Components.AssetPreview

        def render(assigns) do
          ~H\"\"\"
          <section class="page">
            <h1>Users</h1>
            <.pdf_document_viewer url={@doc} />
            <table class="data">
              <thead><tr><th>Name</th><th>X</th></tr></thead>
              <tbody>
                <tr :for={row <- @rows}>
                  <td>{row.name}</td>
                  <td>{row.x}</td>
                </tr>
              </tbody>
            </table>
          </section>
          \"\"\"
        end
      end
      """

      {:ok, prepared} =
        @subject.prepare(
          source_files: write_tmp(%{"asset_preview.ex" => preview_mod, "caller.ex" => caller}),
          project_config: @config
        )

      out =
        @subject.transform(caller,
          enabled: true,
          dry_run: true,
          prepared: prepared,
          project_config: @config
        )

      assert out =~ "import MyAppWeb.Components.AssetPreview"
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

      path = Path.join(root, "lib/my_app_web/components/rows_table.ex")
      assert File.exists?(path)
      module = File.read!(path)

      assert module =~ "defmodule MyAppWeb.Components.RowsTable do"
      assert module =~ "use MyAppWeb, :html"
      # alias whose name the body references is kept
      assert module =~ "alias MyAppWeb.Helpers.Formatting"
      # unused alias is dropped (no warning litter)
      refute module =~ "alias MyAppWeb.Helpers.Unused"
      # body has a local `<.badge>` → plain import kept (may expose it)
      assert module =~ "import MyAppWeb.TextComponents"
      assert module =~ "attr :rows"
      assert module =~ "def rows_table(assigns)"
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

      module = File.read!(Path.join(root, "lib/my_app_web/components/rows_table.ex"))
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
