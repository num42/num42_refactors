defmodule Number42.Refactors.Ex.ProposeSharedHeexComponentTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ProposeSharedHeexComponent

  @subject ProposeSharedHeexComponent
  @project_config %{heex: %{core_components_module: "MyAppWeb.CoreComponents"}}

  # A card motif: same shape, different assign names + text per file.
  defp card(title_assign, body_assign) do
    """
    defmodule Demo do
      def render(assigns) do
        ~H\"\"\"
        <article class="card">
          <h2 class="card-title">{@#{title_assign}}</h2>
          <p class="card-body">{@#{body_assign}}</p>
        </article>
        \"\"\"
      end
    end
    """
  end

  defp sources_to_map(sources) do
    for {path, source} <- sources, into: %{}, do: {source, path}
  end

  describe "metadata" do
    test "implements Refactor behaviour and defaults OFF" do
      Code.ensure_loaded!(@subject)
      assert function_exported?(@subject, :description, 0)
      assert function_exported?(@subject, :transform, 2)
      assert function_exported?(@subject, :prepare, 1)
      # default OFF: with a plan but no `enabled: true`, transform is a no-op
      src = card("title", "body")

      plan = ProposeSharedHeexComponent.build_plan(%{"a.ex" => src, "b.ex" => src, "c.ex" => src})

      out =
        @subject.transform(src,
          prepared: %{plans: plan, source_to_file: %{}},
          file: "a.ex",
          project_config: @project_config
        )

      assert out == src
    end
  end

  describe "build_plan/2 — Slice 2: corpus motif clustering" do
    test "detects a motif recurring across the threshold of files" do
      sources = %{
        "lib/a.ex" => card("title", "body"),
        "lib/b.ex" => card("name", "summary"),
        "lib/c.ex" => card("heading", "content")
      }

      [plan] =
        ProposeSharedHeexComponent.build_plan(sources,
          min_occurrences: 3,
          min_files: 2,
          min_mass: 4
        )

      assert length(plan.occurrences) == 3

      assert plan.occurrences |> Enum.map(& &1.file) |> Enum.sort() == [
               "lib/a.ex",
               "lib/b.ex",
               "lib/c.ex"
             ]

      # two dynamic slots → two component params
      assert length(plan.params) == 2
    end

    test "SKIPS a motif below the occurrence threshold (near-miss)" do
      sources = %{
        "lib/a.ex" => card("title", "body"),
        "lib/b.ex" => card("name", "summary")
      }

      assert ProposeSharedHeexComponent.build_plan(sources,
               min_occurrences: 3,
               min_files: 2,
               min_mass: 4
             ) ==
               []
    end

    test "SKIPS a motif confined to a single file (no cross-file lever)" do
      two_in_one = """
      defmodule Demo do
        def render(assigns) do
          ~H\"\"\"
          <article class="card">
            <h2 class="card-title">{@a}</h2>
            <p class="card-body">{@b}</p>
          </article>
          <article class="card">
            <h2 class="card-title">{@c}</h2>
            <p class="card-body">{@d}</p>
          </article>
          \"\"\"
        end
      end
      """

      sources = %{"lib/a.ex" => two_in_one}

      assert ProposeSharedHeexComponent.build_plan(sources,
               min_occurrences: 2,
               min_files: 2,
               min_mass: 4
             ) ==
               []
    end

    test "SKIPS a motif whose occurrences reference a free non-assign var (unsafe to lift)" do
      with_free_var = """
      defmodule Demo do
        def render(assigns) do
          total = 5
          ~H\"\"\"
          <article class="card">
            <h2 class="card-title">{@a}</h2>
            <p class="card-body">{total}</p>
          </article>
          \"\"\"
        end
      end
      """

      sources = %{
        "lib/a.ex" => with_free_var,
        "lib/b.ex" => String.replace(with_free_var, "Demo", "Demo2"),
        "lib/c.ex" => String.replace(with_free_var, "Demo", "Demo3")
      }

      assert ProposeSharedHeexComponent.build_plan(sources,
               min_occurrences: 3,
               min_files: 2,
               min_mass: 4
             ) ==
               []
    end
  end

  describe "transform/2 — Slice 3: end-to-end multi-file rewrite (enabled)" do
    test "rewrites each occurrence to a shared component call and appends the component" do
      sources = %{
        "lib/a.ex" => card("title", "body"),
        "lib/b.ex" => card("name", "summary"),
        "lib/c.ex" => card("heading", "content")
      }

      plans =
        ProposeSharedHeexComponent.build_plan(sources,
          min_occurrences: 3,
          min_files: 2,
          min_mass: 4
        )

      prepared = %{plans: plans, source_to_file: sources_to_map(sources)}
      [plan] = plans

      out_a =
        @subject.transform(sources["lib/a.ex"],
          enabled: true,
          prepared: prepared,
          project_config: @project_config
        )

      # the inline card markup is gone, replaced by a component call
      refute out_a =~ ~s(<h2 class="card-title")
      assert out_a =~ "<.#{plan.name}"
      # the file's own assigns are forwarded as the params
      assert out_a =~ "@title"
      assert out_a =~ "@body"

      out_b =
        @subject.transform(sources["lib/b.ex"],
          enabled: true,
          prepared: prepared,
          project_config: @project_config
        )

      assert out_b =~ "<.#{plan.name}"
      assert out_b =~ "@name"
      assert out_b =~ "@summary"
    end

    test "appends one defp component to the configured CoreComponents module" do
      sources = %{
        "lib/a.ex" => card("title", "body"),
        "lib/b.ex" => card("name", "summary"),
        "lib/c.ex" => card("heading", "content")
      }

      core = """
      defmodule MyAppWeb.CoreComponents do
        use Phoenix.Component
      end
      """

      plans =
        ProposeSharedHeexComponent.build_plan(sources,
          min_occurrences: 3,
          min_files: 2,
          min_mass: 4
        )

      prepared = %{plans: plans, source_to_file: sources_to_map(sources)}
      [plan] = plans

      out =
        @subject.transform(core,
          enabled: true,
          prepared: prepared,
          project_config: @project_config
        )

      assert out =~ "defp #{plan.name}(assigns)"
      # the body uses slot params, not any one file's assign names
      assert out =~ "attr"
    end

    test "is idempotent: a second pass over already-rewritten sources is a no-op" do
      sources = %{
        "lib/a.ex" => card("title", "body"),
        "lib/b.ex" => card("name", "summary"),
        "lib/c.ex" => card("heading", "content")
      }

      plans =
        ProposeSharedHeexComponent.build_plan(sources,
          min_occurrences: 3,
          min_files: 2,
          min_mass: 4
        )

      prepared = %{plans: plans, source_to_file: sources_to_map(sources)}

      out_a =
        @subject.transform(sources["lib/a.ex"],
          enabled: true,
          prepared: prepared,
          project_config: @project_config
        )

      # rebuild a plan from the rewritten corpus — the motif is gone, so empty
      sources2 = %{"lib/a.ex" => out_a, "lib/b.ex" => out_a, "lib/c.ex" => out_a}

      plans2 =
        ProposeSharedHeexComponent.build_plan(sources2,
          min_occurrences: 3,
          min_files: 2,
          min_mass: 4
        )

      prepared2 = %{plans: plans2, source_to_file: sources_to_map(sources2)}

      out_a_2 =
        @subject.transform(out_a,
          enabled: true,
          prepared: prepared2,
          project_config: @project_config
        )

      assert out_a_2 == out_a
    end
  end
end
