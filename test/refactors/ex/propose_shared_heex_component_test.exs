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

    test "appends one PUBLIC component to the configured CoreComponents module" do
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

      # cross-module component must be PUBLIC: `import CoreComponents` only
      # exposes `def`, so `<.shared_*>` at the call sites would be undefined
      # if it were `defp` (and the unused `defp` fails --warnings-as-errors).
      assert out =~ "def #{plan.name}(assigns)"
      refute out =~ "defp #{plan.name}(assigns)"
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

  describe "build_plan/2 — #298: compile-safe lifting" do
    # Bug 1: a body calling a sub-component (`<.foo>`) cannot be lifted into
    # CoreComponents — `<.foo>` is imported into the caller, not the destination.
    test "SKIPS a motif whose body calls a custom sub-component (not in destination scope)" do
      with_subcomponent = """
      defmodule Demo do
        def render(assigns) do
          ~H\"\"\"
          <article class="card">
            <.announcing>{@title}</.announcing>
            <p class="card-body">{@body}</p>
          </article>
          \"\"\"
        end
      end
      """

      sources = %{
        "lib/a.ex" => with_subcomponent,
        "lib/b.ex" => String.replace(with_subcomponent, "Demo", "Demo2"),
        "lib/c.ex" => String.replace(with_subcomponent, "Demo", "Demo3")
      }

      assert ProposeSharedHeexComponent.build_plan(sources,
               min_occurrences: 3,
               min_files: 2,
               min_mass: 4
             ) ==
               []
    end

    # Bug 3 + latent: a slot reading an assign is ALWAYS a param, even when its
    # expression is byte-identical across occurrences — freezing `{@form}` into
    # the body references an assign the component does not have (runtime KeyError).
    test "parameterises an assign-reading slot even when identical across occurrences" do
      with_shared_assign = fn varying ->
        """
        defmodule Demo do
          def render(assigns) do
            ~H\"\"\"
            <article class="card">
              <h2 class="card-title">{@title}</h2>
              <form for={@form}>
                <input value={@#{varying}} />
              </form>
            </article>
            \"\"\"
          end
        end
        """
      end

      sources = %{
        "lib/a.ex" => with_shared_assign.("name"),
        "lib/b.ex" => with_shared_assign.("email"),
        "lib/c.ex" => with_shared_assign.("phone")
      }

      [plan] =
        ProposeSharedHeexComponent.build_plan(sources,
          min_occurrences: 3,
          min_files: 2,
          min_mass: 4
        )

      # @title, @form (byte-identical everywhere), and @name/@email/@phone all
      # read assigns → all three are params; nothing referencing an assign is
      # frozen into the body.
      assert length(plan.params) == 3

      # the body's `@x` references (after slot substitution) must ALL be
      # declared params — a frozen `@form` with no matching param is the
      # KeyError bug (#298 Bug 3). Param names happen to equal the rep's assign
      # names here, so the body reads `@title`/`@form`, but each is now an attr.
      param_names = MapSet.new(plan.params, &Atom.to_string(&1.name))

      body_assigns =
        ~r/@([a-z_][a-zA-Z0-9_]*[?!]?)/
        |> Regex.scan(plan.body)
        |> Enum.map(fn [_, n] -> n end)
        |> MapSet.new()

      assert MapSet.subset?(body_assigns, param_names),
             "body references undeclared assigns: #{inspect(MapSet.difference(body_assigns, param_names))}"
    end

    test "KEEPS a byte-identical slot literal when it reads no assign" do
      with_const = fn varying ->
        """
        defmodule Demo do
          def render(assigns) do
            ~H\"\"\"
            <article class="card">
              <h2 class="card-title">{@#{varying}}</h2>
              <p class="card-body">{String.upcase("static")}</p>
            </article>
            \"\"\"
          end
        end
        """
      end

      sources = %{
        "lib/a.ex" => with_const.("title"),
        "lib/b.ex" => with_const.("name"),
        "lib/c.ex" => with_const.("heading")
      }

      [plan] =
        ProposeSharedHeexComponent.build_plan(sources,
          min_occurrences: 3,
          min_files: 2,
          min_mass: 4
        )

      # only the varying assign slot is a param; the assign-free constant stays literal
      assert length(plan.params) == 1
      assert plan.body =~ ~s|{String.upcase("static")}|
    end

    # Bug 4: structurally-identical occurrences whose STATIC content diverges
    # (literal text / string attr values) do not render identically. Freezing
    # one occurrence's text into the shared body is a behaviour-changing merge.
    # The motif gate must not cluster them.
    test "SKIPS a motif whose static text diverges across occurrences" do
      card_text = fn assign, text ->
        """
        defmodule Demo do
          def render(assigns) do
            ~H\"\"\"
            <article class="card">
              <h2 class="card-title">#{text}</h2>
              <p class="card-body">{@#{assign}}</p>
            </article>
            \"\"\"
          end
        end
        """
      end

      sources = %{
        "lib/a.ex" => card_text.("body", "Neue Marke"),
        "lib/b.ex" => card_text.("summary", "Neue Organisation"),
        "lib/c.ex" => card_text.("content", "Organisation bearbeiten")
      }

      assert ProposeSharedHeexComponent.build_plan(sources,
               min_occurrences: 3,
               min_files: 2,
               min_mass: 4
             ) ==
               []
    end

    test "SKIPS a motif whose static string attr values diverge across occurrences" do
      card_attr = fn assign, id ->
        """
        defmodule Demo do
          def render(assigns) do
            ~H\"\"\"
            <article class="card" id="#{id}">
              <h2 class="card-title">{@title}</h2>
              <p class="card-body">{@#{assign}}</p>
            </article>
            \"\"\"
          end
        end
        """
      end

      sources = %{
        "lib/a.ex" => card_attr.("body", "brand-form"),
        "lib/b.ex" => card_attr.("summary", "organization-form"),
        "lib/c.ex" => card_attr.("content", "edit-organization-form")
      }

      assert ProposeSharedHeexComponent.build_plan(sources,
               min_occurrences: 3,
               min_files: 2,
               min_mass: 4
             ) ==
               []
    end

    test "STILL clusters when static content is identical (only assigns vary)" do
      card_same = fn assign ->
        """
        defmodule Demo do
          def render(assigns) do
            ~H\"\"\"
            <article class="card" id="card">
              <h2 class="card-title">Title</h2>
              <p class="card-body">{@#{assign}}</p>
            </article>
            \"\"\"
          end
        end
        """
      end

      sources = %{
        "lib/a.ex" => card_same.("body"),
        "lib/b.ex" => card_same.("summary"),
        "lib/c.ex" => card_same.("content")
      }

      assert [_plan] =
               ProposeSharedHeexComponent.build_plan(sources,
                 min_occurrences: 3,
                 min_files: 2,
                 min_mass: 4
               )
    end
  end
end
