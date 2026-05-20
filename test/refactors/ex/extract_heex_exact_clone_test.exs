defmodule Number42.Refactors.Ex.ExtractHeexExactCloneTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractHeexExactClone

  @subject ExtractHeexExactClone
  @project_config %{heex: %{core_components_module: "MyAppWeb.CoreComponents"}}

  describe "metadata" do
    test "implements Refactor behaviour" do
      assert function_exported?(@subject, :description, 0)
      assert function_exported?(@subject, :transform, 2)
      assert is_binary(@subject.description())
    end

    test "reformats after rewriting (HEEx sigils need formatter)" do
      assert @subject.reformat_after?() == true
    end
  end

  describe "find_free_vars/1" do
    alias Number42.Refactors.Heex.Tree

    defp parse!(body) do
      {:ok, tree} = Tree.parse_body(body)
      tree
    end

    test "collects @-prefixed assigns from eex_expr nodes" do
      tree = parse!(~s(<span>{@title}</span>))
      assert ExtractHeexExactClone.find_free_vars(tree) == %{assigns: [:title], locals: []}
    end

    test "collects assigns from attribute :expr values" do
      tree = parse!(~s(<a href={@url} class={@cls}>x</a>))
      assert %{assigns: assigns} = ExtractHeexExactClone.find_free_vars(tree)
      assert Enum.sort(assigns) == [:cls, :url]
    end

    test "collects assigns referenced inside :for and uses pattern as local" do
      tree =
        parse!("""
        <%= for x <- @items do %>
          <li>{x}</li>
        <% end %>
        """)

      result = ExtractHeexExactClone.find_free_vars(tree)
      assert :items in result.assigns
      assert :x in result.locals
      refute :x in result.assigns
    end

    test "ignores @-references that are also bound by a loop pattern within the subtree" do
      tree =
        parse!("""
        <%= for h <- @houses do %>
          <span>{h.name}</span>
        <% end %>
        """)

      result = ExtractHeexExactClone.find_free_vars(tree)
      assert :houses in result.assigns
      refute :h in result.assigns
      assert :h in result.locals
    end

    test "deduplicates and sorts" do
      tree = parse!(~s(<div>{@a}{@b}{@a}</div>))
      assert %{assigns: [:a, :b]} = ExtractHeexExactClone.find_free_vars(tree)
    end
  end

  describe "component_name/3" do
    test "builds name from file stem + root tag + hash prefix" do
      hash = <<0xAB, 0xCD, 0xEF, 0x12>> <> :binary.copy(<<0>>, 60)

      assert ExtractHeexExactClone.component_name(
               "lib/my_app_web/live/item_live/brand_item_card.ex",
               "li",
               hash
             ) == :shared_brand_item_card_li_abcdef12
    end

    test "snake-cases multi-word file stems and strips dot from component tags" do
      hash = <<0xDE, 0xAD, 0xBE, 0xEF>> <> :binary.copy(<<0>>, 60)

      assert ExtractHeexExactClone.component_name(
               "lib/foo/bar_baz.ex",
               ".my_widget",
               hash
             ) == :shared_bar_baz_my_widget_deadbeef
    end
  end

  describe "render_subtree/2" do
    test "renders a simple element verbatim" do
      [node] = parse!(~s(<span class="x">{@title}</span>))

      assert ExtractHeexExactClone.render_subtree(node, []) ==
               ~s(<span class="x">{@title}</span>)
    end

    test "rewrites loop-binding references to @binding" do
      [for_block] =
        parse!("""
        <%= for h <- @houses do %>
          <li>{h.name}</li>
        <% end %>
        """)

      [li] = elem(for_block, 2)
      assert ExtractHeexExactClone.render_subtree(li, [:h]) == "<li>{@h.name}</li>"
    end

    test "preserves attribute :expr interpolations" do
      [a] = parse!(~s(<a href={@url} class={@cls} download>x</a>))

      assert ExtractHeexExactClone.render_subtree(a, []) ==
               ~s(<a href={@url} class={@cls} download="">x</a>)
    end
  end

  describe "build_plan/2" do
    test "produces one plan entry per :exact cluster, with name and free vars" do
      sources = %{
        "lib/a.ex" => """
        defmodule A do
          def render(assigns) do
            ~H\"\"\"
            <article class="post">
              <h2>{@title}</h2>
              <p>{@body}</p>
            </article>
            \"\"\"
          end
        end
        """,
        "lib/b.ex" => """
        defmodule B do
          def render(assigns) do
            ~H\"\"\"
            <article class="post">
              <h2>{@title}</h2>
              <p>{@body}</p>
            </article>
            \"\"\"
          end
        end
        """
      }

      [plan] = ExtractHeexExactClone.build_plan(sources, min_mass: 4)

      assert plan.assigns == [:body, :title]
      assert plan.locals == []
      assert plan.root_tag == "article"
      assert is_atom(plan.name)
      assert length(plan.occurrences) == 2

      assert plan.occurrences |> Enum.map(& &1.file) |> Enum.sort() == ["lib/a.ex", "lib/b.ex"]
    end

    test "skips clusters with mass below the threshold" do
      sources = %{
        "lib/a.ex" => """
        defmodule A do
          def render(assigns), do: ~H"<span>{@x}</span>"
        end
        """,
        "lib/b.ex" => """
        defmodule B do
          def render(assigns), do: ~H"<span>{@x}</span>"
        end
        """
      }

      assert ExtractHeexExactClone.build_plan(sources, min_mass: 100) == []
    end
  end

  describe "transform/2 with injected plan" do
    test "replaces a single occurrence with a component call" do
      source_a = """
      defmodule A do
        def render(assigns) do
          ~H\"\"\"
          <article class="post">
            <h2>{@title}</h2>
            <p>{@body}</p>
          </article>
          \"\"\"
        end
      end
      """

      source_b = String.replace(source_a, "defmodule A", "defmodule B")

      sources = %{"lib/a.ex" => source_a, "lib/b.ex" => source_b}
      [plan] = ExtractHeexExactClone.build_plan(sources, min_mass: 4)

      result =
        ExtractHeexExactClone.transform(source_a,
          prepared: %{plans: [plan]},
          file: "lib/a.ex",
          project_config: @project_config
        )

      assert result =~ "<.#{plan.name}"
      assert result =~ "title={@title}"
      assert result =~ "body={@body}"
      refute result =~ "<article class=\"post\">"
    end
  end

  describe "prepare/1 + end-to-end source matching" do
    test "transform/2 finds the right file by matching original source bytes" do
      source_a = """
      defmodule MyApp.A do
        def render(assigns) do
          ~H\"\"\"
          <article class="post">
            <h2>{@title}</h2>
            <p>{@body}</p>
          </article>
          \"\"\"
        end
      end
      """

      source_b = String.replace(source_a, "defmodule MyApp.A", "defmodule MyApp.B")

      sources = %{"lib/a.ex" => source_a, "lib/b.ex" => source_b}
      plans = ExtractHeexExactClone.build_plan(sources, min_mass: 4)

      prepared = %{plans: plans, source_to_file: source_to_file_map(sources)}

      out_a =
        ExtractHeexExactClone.transform(source_a,
          prepared: prepared,
          project_config: @project_config
        )

      out_b =
        ExtractHeexExactClone.transform(source_b,
          prepared: prepared,
          project_config: @project_config
        )

      [plan] = plans
      assert out_a =~ "<.#{plan.name}"
      assert out_b =~ "<.#{plan.name}"
      refute out_a =~ "<article class=\"post\">"
      refute out_b =~ "<article class=\"post\">"
    end

    test "transform/2 appends component definitions to CoreComponents" do
      source_a = """
      defmodule MyApp.A do
        def render(assigns) do
          ~H\"\"\"
          <article class="post">
            <h2>{@title}</h2>
            <p>{@body}</p>
          </article>
          \"\"\"
        end
      end
      """

      source_b = String.replace(source_a, "defmodule MyApp.A", "defmodule MyApp.B")

      core_components = """
      defmodule MyAppWeb.CoreComponents do
        use Phoenix.Component
      end
      """

      sources = %{"lib/a.ex" => source_a, "lib/b.ex" => source_b}
      plans = ExtractHeexExactClone.build_plan(sources, min_mass: 4)
      prepared = %{plans: plans, source_to_file: source_to_file_map(sources)}

      result =
        ExtractHeexExactClone.transform(core_components,
          prepared: prepared,
          project_config: @project_config
        )

      [plan] = plans
      assert result =~ "defp #{plan.name}(assigns)"
      assert result =~ "attr :body, :any"
      assert result =~ "attr :title, :any"
    end
  end

  describe "idempotence" do
    test "running the refactor a second time does not change rewritten sources" do
      source_a = """
      defmodule MyApp.A do
        def render(assigns) do
          ~H\"\"\"
          <article class="post">
            <h2>{@title}</h2>
            <p>{@body}</p>
          </article>
          \"\"\"
        end
      end
      """

      source_b = String.replace(source_a, "defmodule MyApp.A", "defmodule MyApp.B")
      sources = %{"lib/a.ex" => source_a, "lib/b.ex" => source_b}

      plans = ExtractHeexExactClone.build_plan(sources, min_mass: 4)
      prepared = %{plans: plans, source_to_file: source_to_file_map(sources)}

      out_a =
        ExtractHeexExactClone.transform(source_a,
          prepared: prepared,
          project_config: @project_config
        )

      # Second pass: build a fresh plan from the *rewritten* sources.
      # The rewritten source has no clone left (only one component
      # call), so the new plan is empty and transform/2 is a no-op.
      sources2 = %{"lib/a.ex" => out_a, "lib/b.ex" => out_a}
      plans2 = ExtractHeexExactClone.build_plan(sources2, min_mass: 4)
      prepared2 = %{plans: plans2, source_to_file: source_to_file_map(sources2)}

      out_a_second =
        ExtractHeexExactClone.transform(out_a,
          prepared: prepared2,
          project_config: @project_config
        )

      assert out_a_second == out_a
    end
  end

  defp source_to_file_map(sources) do
    for {path, source} <- sources do
      {source, path}
    end
    |> Map.new()
  end
end
