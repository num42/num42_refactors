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

    test "declines when a dropped clone has a caller in another file" do
      # With a corpus index showing brand_item_assets_container_2 is called from
      # another file, merging would delete that def and break the cross-file
      # caller. Cross-file caller rewriting is a follow-up — decline here.
      source = twin_module()

      prepared = %{
        callers: %{"brand_item_assets_container_2" => MapSet.new(["lib/other.ex"])},
        source_to_file: %{source => "lib/brand.ex"}
      }

      result = @subject.transform(source, enabled: true, prepared: prepared)
      assert result == source
    end

    test "merges when the only callers are in the module's own file" do
      source = twin_module()

      prepared = %{
        callers: %{
          "brand_item_assets_container" => MapSet.new(["lib/brand.ex"]),
          "brand_item_assets_container_2" => MapSet.new(["lib/brand.ex"])
        },
        source_to_file: %{source => "lib/brand.ex"}
      }

      result = @subject.transform(source, enabled: true, prepared: prepared)
      refute result =~ "def brand_item_assets_container_2("
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
end
