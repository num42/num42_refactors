defmodule Number42.Refactors.Ex.MergeNearCloneComponentsTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.MergeNearCloneComponents

  @subject MergeNearCloneComponents
  @enabled [enabled: true]

  # Two sibling function components that differ only in root tag, root class
  # (subset: "py-3" ⊂ "py-3 px-2"), and one heading text — the
  # brand_item_assets_container / _2 case. Bodies are large enough (~30 nodes)
  # that 3 edits clear the 0.85 similarity floor.
  defp twin_module do
    """
    defmodule MyAppWeb.Brand do
      use MyAppWeb, :html

      def brand_item_assets_container(assigns) do
        ~H\"\"\"
        <div class="py-3">
          <h2 class="head">Dokumentationsbilder</h2>
          <ul class="list">
            <li class="row"><figure class="f"><img src={@a1} /></figure></li>
            <li class="row"><figure class="f"><img src={@a2} /></figure></li>
            <li class="row"><figure class="f"><img src={@a3} /></figure></li>
            <li class="row"><figure class="f"><img src={@a4} /></figure></li>
            <li class="row"><figure class="f"><img src={@a5} /></figure></li>
            <li class="row"><figure class="f"><img src={@a6} /></figure></li>
            <li class="row"><figure class="f"><img src={@a7} /></figure></li>
          </ul>
        </div>
        \"\"\"
      end

      def brand_item_assets_container_2(assigns) do
        ~H\"\"\"
        <section class="py-3 px-2">
          <h2 class="head">Bilder</h2>
          <ul class="list">
            <li class="row"><figure class="f"><img src={@a1} /></figure></li>
            <li class="row"><figure class="f"><img src={@a2} /></figure></li>
            <li class="row"><figure class="f"><img src={@a3} /></figure></li>
            <li class="row"><figure class="f"><img src={@a4} /></figure></li>
            <li class="row"><figure class="f"><img src={@a5} /></figure></li>
            <li class="row"><figure class="f"><img src={@a6} /></figure></li>
            <li class="row"><figure class="f"><img src={@a7} /></figure></li>
          </ul>
        </section>
        \"\"\"
      end

      def page(assigns) do
        ~H\"\"\"
        <.brand_item_assets_container a1={@x} />
        <.brand_item_assets_container_2 a1={@y} />
        \"\"\"
      end
    end
    """
  end

  describe "default-OFF gate" do
    test "no-op when not enabled" do
      assert_unchanged(@subject, twin_module())
    end
  end

  describe "merges two near-clone sibling function components" do
    setup do
      %{result: apply_refactor(@subject, twin_module(), @enabled)}
    end

    test "the second (smaller/duplicate) def is removed", %{result: result} do
      refute result =~ "def brand_item_assets_container_2("
    end

    test "the survivor gains an `attr :label`", %{result: result} do
      assert result =~ ~r/attr :label/
    end

    test "the heading text becomes {@label}", %{result: result} do
      assert result =~ "{@label}"
      refute result =~ ">Dokumentationsbilder<"
      refute result =~ ">Bilder<"
    end

    test "the survivor keeps the base (larger-tree) tag", %{result: result} do
      # both defs have equal mass here; base is the first by name. Root stays a
      # single consistent tag — no leftover <section> root.
      assert result =~ ~r/def brand_item_assets_container\(assigns\)/
    end

    test "both call sites now call the survivor with their own label", %{result: result} do
      # the _2 call site is rewritten to the survivor name, passing label
      refute result =~ "<.brand_item_assets_container_2"
      assert result =~ ~r/<\.brand_item_assets_container[^_]/
      assert result =~ ~r/label=/
    end
  end

  describe "idempotent" do
    test "a single already-parametrised component is a no-op" do
      merged = apply_refactor(@subject, twin_module(), @enabled)
      assert_unchanged(@subject, merged, @enabled)
    end
  end

  describe "declines (derive-or-decline soundness gates)" do
    test "declines when one twin has an extra child subtree (structural diff)" do
      source = """
      defmodule MyAppWeb.Brand do
        use MyAppWeb, :html

        def card_a(assigns) do
          ~H\"\"\"
          <div class="c">
            <h2>A</h2>
            <ul class="l"><li>{@x}</li></ul>
          </div>
          \"\"\"
        end

        def card_b(assigns) do
          ~H\"\"\"
          <div class="c">
            <h2>B</h2>
            <ul class="l"><li>{@x}</li></ul>
            <footer class="f">extra</footer>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end

    test "declines when classes are not in a subset relation" do
      source = """
      defmodule MyAppWeb.Brand do
        use MyAppWeb, :html

        def box_a(assigns) do
          ~H\"\"\"
          <div class="p-2 text-red">
            <span class="s">{@label}</span>
            <span class="s">{@body}</span>
          </div>
          \"\"\"
        end

        def box_b(assigns) do
          ~H\"\"\"
          <div class="p-4 text-blue">
            <span class="s">{@label}</span>
            <span class="s">{@body}</span>
          </div>
          \"\"\"
        end
      end
      """

      # p-2 text-red vs p-4 text-blue: neither is a subset of the other → decline.
      assert_unchanged(@subject, source, @enabled)
    end

    test "declines when the divergent node is markup, not a pure text node" do
      source = """
      defmodule MyAppWeb.Brand do
        use MyAppWeb, :html

        def head_a(assigns) do
          ~H\"\"\"
          <div class="c">
            <h2 class="t"><strong>A</strong></h2>
            <ul class="l"><li>{@x}</li></ul>
          </div>
          \"\"\"
        end

        def head_b(assigns) do
          ~H\"\"\"
          <div class="c">
            <h2 class="t"><em>B</em></h2>
            <ul class="l"><li>{@x}</li></ul>
          </div>
          \"\"\"
        end
      end
      """

      # the heading differs in CHILD MARKUP (strong vs em), not a text node →
      # structural → decline (a slot would be needed; out of scope).
      assert_unchanged(@subject, source, @enabled)
    end

    test "declines a lone component with no near-clone twin" do
      source = """
      defmodule MyAppWeb.Solo do
        use MyAppWeb, :html

        def only(assigns) do
          ~H\"\"\"
          <div class="py-3">
            <h2 class="head">{@title}</h2>
            <ul class="list"><li :for={a <- @items}>{a}</li></ul>
          </div>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, source, @enabled)
    end
  end

  # ---- cross-file: near-clone single-def component MODULES across files -----

  describe "cross-file merge of single-def component modules" do
    # The real #380 shape: ExtractToPublicComponent emits each near-clone into
    # its OWN file-module (one `def name(assigns)`), with cross-file callers.
    # The merge keeps the larger as survivor, deletes the clone's file, and
    # rewrites the clone's callers to the survivor (alias + tag + label).

    defp images_module(mod, fn_name, root_tag, root_class, head_class, heading) do
      """
      defmodule #{mod} do
        use MyAppWeb, :html
        attr :brand_item, :any

        def #{fn_name}(assigns) do
          ~H\"\"\"
          <#{root_tag} :if={@brand_item.assets != []} class="#{root_class}">
            <p class="#{head_class}">#{heading}</p>
            <ul class="space-y-3">
              <li class="row"><figure class="thumb"><img src={@a1} /></figure></li>
              <li class="row"><figure class="thumb"><img src={@a2} /></figure></li>
              <li class="row"><figure class="thumb"><img src={@a3} /></figure></li>
              <li class="row"><figure class="thumb"><img src={@a4} /></figure></li>
              <li class="row"><figure class="thumb"><img src={@a5} /></figure></li>
              <li class="row"><figure class="thumb"><img src={@a6} /></figure></li>
            </ul>
          </#{root_tag}>
          \"\"\"
        end
      end
      """
    end

    defp caller_module(mod_name, alias_mod, tag_fn) do
      """
      defmodule MyAppWeb.#{mod_name} do
        use MyAppWeb, :live_view
        alias #{alias_mod}

        def render(assigns) do
          ~H\"\"\"
          <#{alias_mod |> String.split(".") |> List.last()}.#{tag_fn} brand_item={@brand_item} />
          \"\"\"
        end
      end
      """
    end

    defp setup_corpus do
      survivor =
        images_module(
          "MyAppWeb.Components.BrandItemAssetsImages",
          "brand_item_assets_images",
          "div",
          "py-3",
          "mb-2",
          "Dokumentationsbilder"
        )

      clone =
        images_module(
          "MyAppWeb.Components.BrandItemAssetsImages2",
          "brand_item_assets_images_2",
          "section",
          "px-2 py-2",
          "mb-1",
          "Bilder"
        )

      caller_a =
        caller_module(
          "CardA",
          "MyAppWeb.Components.BrandItemAssetsImages",
          "brand_item_assets_images"
        )

      caller_b =
        caller_module(
          "CardB",
          "MyAppWeb.Components.BrandItemAssetsImages2",
          "brand_item_assets_images_2"
        )

      paths =
        write_tmp(%{
          "survivor.ex" => survivor,
          "clone.ex" => clone,
          "caller_a.ex" => caller_a,
          "caller_b.ex" => caller_b
        })

      by_name = Map.new(paths, fn p -> {Path.basename(p), p} end)
      {:ok, prepared} = @subject.prepare(source_files: paths, threshold: 0.75, min_mass: 10)
      %{prepared: prepared, paths: by_name}
    end

    test "the survivor file gains attr :label and {@label}; clone file is deleted" do
      %{prepared: prepared, paths: paths} = setup_corpus()

      survivor_src = File.read!(paths["survivor.ex"])
      result = @subject.transform(survivor_src, enabled: true, prepared: prepared)

      assert result =~ ~r/attr :label/
      assert result =~ "{@label}"
      refute result =~ ">Dokumentationsbilder<"

      refute File.exists?(paths["clone.ex"])
    end

    test "the clone's caller is rewritten to the survivor, passing its label" do
      %{prepared: prepared, paths: paths} = setup_corpus()

      survivor_src = File.read!(paths["survivor.ex"])
      @subject.transform(survivor_src, enabled: true, prepared: prepared)

      caller_b = File.read!(paths["caller_b.ex"])
      refute caller_b =~ "BrandItemAssetsImages2"
      assert caller_b =~ "BrandItemAssetsImages."
      assert caller_b =~ ~r/label="Bilder"/
    end

    test "the survivor's own caller is untouched (no needless label)" do
      %{prepared: prepared, paths: paths} = setup_corpus()

      before_a = File.read!(paths["caller_a.ex"])
      survivor_src = File.read!(paths["survivor.ex"])
      @subject.transform(survivor_src, enabled: true, prepared: prepared)

      assert File.read!(paths["caller_a.ex"]) == before_a
    end

    test "non-subset root classes are unified (union), not declined" do
      %{prepared: prepared, paths: paths} = setup_corpus()

      survivor_src = File.read!(paths["survivor.ex"])
      result = @subject.transform(survivor_src, enabled: true, prepared: prepared)

      # py-3 ∪ px-2 py-2 = {py-3, px-2, py-2} — all three tokens survive.
      assert result =~ "py-3"
      assert result =~ "px-2"
      assert result =~ "py-2"
    end

    test "the dropped clone's own pass is a no-op (survivor owns the effects)" do
      %{prepared: prepared, paths: paths} = setup_corpus()

      clone_src = File.read!(paths["clone.ex"])
      assert @subject.transform(clone_src, enabled: true, prepared: prepared) == clone_src
    end

    test "dry-run performs no file deletions or caller writes" do
      %{prepared: prepared, paths: paths} = setup_corpus()

      survivor_src = File.read!(paths["survivor.ex"])
      before_b = File.read!(paths["caller_b.ex"])

      @subject.transform(survivor_src, enabled: true, prepared: prepared, dry_run: true)

      assert File.exists?(paths["clone.ex"])
      assert File.read!(paths["caller_b.ex"]) == before_b
    end

    test "idempotent: a second survivor pass after merge is a no-op" do
      %{prepared: prepared, paths: paths} = setup_corpus()

      survivor_src = File.read!(paths["survivor.ex"])
      merged = @subject.transform(survivor_src, enabled: true, prepared: prepared)

      # Re-prepare the corpus AS IT NOW STANDS (clone gone), then re-run: the
      # survivor has no twin left, so the merged source is returned unchanged.
      remaining =
        [paths["survivor.ex"], paths["caller_a.ex"], paths["caller_b.ex"]]
        |> Enum.filter(&File.exists?/1)

      File.write!(paths["survivor.ex"], merged)
      {:ok, prepared2} = @subject.prepare(source_files: remaining, threshold: 0.75, min_mass: 10)

      assert @subject.transform(merged, enabled: true, prepared: prepared2) == merged
    end

    test "merges nothing when no corpus is available (single-file fallback)" do
      # No `:prepared` and a single source with one component def → the
      # cross-file path can't fire; the same-module fallback finds no twin.
      lone =
        images_module(
          "MyAppWeb.Components.Solo",
          "solo",
          "div",
          "py-3",
          "mb-2",
          "Heading"
        )

      assert @subject.transform(lone, enabled: true) == lone
    end
  end

  defp write_tmp(files) do
    dir = Path.join(System.tmp_dir!(), "mncc-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    for {name, src} <- files do
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, src)
      path
    end
  end
end
