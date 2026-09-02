defmodule Number42.Refactors.Ex.ShortenVerboseIdentifierTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Analysis.IdentifierCompression
  alias Number42.Refactors.Ex.ShortenVerboseIdentifier, as: Shorten

  defp run(src, opts \\ []) do
    Shorten.transform(src, Keyword.merge([enabled: true], opts))
  end

  defp compiles?(src), do: match?({:ok, _}, Code.string_to_quoted(src))

  describe "private function names" do
    @over ~S'''
    defmodule M do
      def run(x), do: build_serie_match_conditions_match_binding(x)

      defp build_serie_match_conditions_match_binding(x), do: x
    end
    '''

    test "an over-long defp is renamed together with its call sites" do
      out = run(@over)

      assert compiles?(out)
      refute out =~ "build_serie_match_conditions_match_binding"
      assert out =~ "defp build_serie_match_conditions(x)"
      assert out =~ "do: build_serie_match_conditions(x)"
    end

    test "off by default" do
      assert Shorten.transform(@over, []) == @over
    end

    test "a name under the trigger is left alone" do
      src = ~S'''
      defmodule M do
        defp build_match_conditions(x), do: x
      end
      '''

      assert run(src) == src
    end

    test "every clause of the renamed function moves along" do
      src = ~S'''
      defmodule M do
        def run(x), do: fetch_serie_match_conditions_match_binding(x)

        defp fetch_serie_match_conditions_match_binding([]), do: []
        defp fetch_serie_match_conditions_match_binding(x), do: x
      end
      '''

      out = run(src)

      assert compiles?(out)
      refute out =~ "fetch_serie_match_conditions_match_binding"
      assert out =~ "defp fetch_serie_match_conditions([])"
      assert out =~ "defp fetch_serie_match_conditions(x)"
    end

    test "a public def is not renamed without a corpus — its callers are out of reach" do
      src = ~S'''
      defmodule M do
        def build_serie_match_conditions_match_binding(x), do: x
      end
      '''

      assert run(src) == src
    end

    test "declines when the shorter name is already taken in the module" do
      src = ~S'''
      defmodule M do
        defp build_serie_match_conditions(x), do: x
        defp build_serie_match_conditions_match_binding(x), do: x
      end
      '''

      assert run(src) == src
    end

    test "a capture of the renamed function follows" do
      src = ~S'''
      defmodule M do
        def run(xs), do: Enum.map(xs, &build_serie_match_conditions_match_binding/1)

        defp build_serie_match_conditions_match_binding(x), do: x
      end
      '''

      out = run(src)

      assert compiles?(out)
      assert out =~ "&build_serie_match_conditions/1"
    end

    test "is idempotent" do
      once = run(@over)

      assert run(once) == once
    end
  end

  describe "bindings" do
    test "an over-long binding is renamed within its clause" do
      src = ~S'''
      defmodule M do
        def run(x) do
          serie_match_conditions_match_fields_binding = compute(x)
          use_it(serie_match_conditions_match_fields_binding)
        end
      end
      '''

      out = run(src)

      assert compiles?(out)
      refute out =~ "serie_match_conditions_match_fields_binding"
      assert out =~ "use_it(serie_match_conditions_fields)"
    end

    test "a binding in another clause with the same name is untouched by this one" do
      src = ~S'''
      defmodule M do
        def run(x) do
          serie_match_conditions_match_fields_binding = compute(x)
          serie_match_conditions_match_fields_binding
        end

        def other(x) do
          other_thing = x
          other_thing
        end
      end
      '''

      out = run(src)

      assert compiles?(out)
      assert out =~ "other_thing = x"
    end

    test "declines when the shorter binding name is already used in the clause" do
      src = ~S'''
      defmodule M do
        def run(x) do
          serie_match_conditions_fields = x
          serie_match_conditions_match_fields_binding = compute(x)
          {serie_match_conditions_fields, serie_match_conditions_match_fields_binding}
        end
      end
      '''

      assert run(src) == src
    end

    test "a function parameter is not a binding this touches" do
      src = ~S'''
      defmodule M do
        def run(serie_match_conditions_match_fields_binding) do
          serie_match_conditions_match_fields_binding
        end
      end
      '''

      assert run(src) == src
    end
  end

  describe "corpus ranking" do
    test "with a corpus the ubiquitous token is the one that goes" do
      src = ~S'''
      defmodule M do
        def run(x), do: build_serie_match_conditions_binding_fields(x)

        defp build_serie_match_conditions_binding_fields(x), do: x
      end
      '''

      out = run(src, identifier_corpus: %{"serie" => 1, "binding" => 99, "match" => 2})

      assert compiles?(out)
      refute out =~ "binding_fields"
      assert out =~ "serie"
    end
  end

  describe "prepare/1 — corpus from the corpus" do
    setup do
      root = Path.join(System.tmp_dir!(), "shorten_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "the document frequencies come from the read files", ctx do
      a = Path.join(ctx.root, "a.ex")

      File.write!(a, ~S'''
      defmodule A do
        defp one_binding(x), do: x
        defp two_binding(x), do: x
        defp three_binding_serie(x), do: x
      end
      ''')

      assert {:ok, %{corpus: corpus}} = Shorten.prepare(source_files: [a])

      assert corpus["binding"] == 3
      assert corpus["serie"] == 1
    end

    test "a prepared corpus decides which token goes", ctx do
      a = Path.join(ctx.root, "a.ex")
      b = Path.join(ctx.root, "b.ex")

      # `binding` is everywhere in this corpus, `serie` is not.
      File.write!(a, ~S'''
      defmodule A do
        defp x_binding(v), do: v
        defp y_binding(v), do: v
        defp z_binding(v), do: v
      end
      ''')

      File.write!(b, ~S'''
      defmodule B do
        def run(v), do: build_serie_match_conditions_binding_fields(v)

        defp build_serie_match_conditions_binding_fields(v), do: v
      end
      ''')

      {:ok, prepared} = Shorten.prepare(source_files: [a, b])
      out = Shorten.transform(File.read!(b), enabled: true, prepared: prepared)

      assert compiles?(out)
      # `binding` is what the corpus repeats, so it goes before any token that
      # only this one identifier carries.
      refute out =~ "binding"
      assert out =~ "conditions"
    end

    test "without source files there is nothing to prepare" do
      assert Shorten.prepare([]) == :no_cache
    end
  end

  describe "public functions across the corpus" do
    setup do
      root = Path.join(System.tmp_dir!(), "shorten_pub_#{System.unique_integer([:positive])}")
      dir = Path.join([root, "lib", "app"])
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root, dir: dir}
    end

    defp write(dir, name, body) do
      path = Path.join(dir, name)
      File.write!(path, body)
      path
    end

    defp plan(files, opts \\ []) do
      {:ok, prepared} = Shorten.prepare([source_files: files] ++ opts)
      prepared
    end

    defp apply_to(path, prepared),
      do: Shorten.transform(File.read!(path), enabled: true, prepared: prepared)

    test "the def and its qualified call sites are renamed", ctx do
      a =
        write(ctx.dir, "a.ex", """
        defmodule App.A do
          def build_serie_match_conditions_match_binding(x), do: x
        end
        """)

      b =
        write(ctx.dir, "b.ex", """
        defmodule App.B do
          def run(x), do: App.A.build_serie_match_conditions_match_binding(x)
          def cap, do: &App.A.build_serie_match_conditions_match_binding/1
        end
        """)

      prepared = plan([a, b])
      out_a = apply_to(a, prepared)
      out_b = apply_to(b, prepared)

      assert compiles?(out_a)
      assert compiles?(out_b)
      assert out_a =~ "def build_serie_match_conditions(x)"
      assert out_b =~ "App.A.build_serie_match_conditions(x)"
      assert out_b =~ "&App.A.build_serie_match_conditions/1"
    end

    test "an importing file has its bare calls renamed too", ctx do
      a =
        write(ctx.dir, "a.ex", """
        defmodule App.A do
          def build_serie_match_conditions_match_binding(x), do: x
        end
        """)

      b =
        write(ctx.dir, "b.ex", """
        defmodule App.B do
          import App.A

          def run(x), do: build_serie_match_conditions_match_binding(x)
        end
        """)

      out_b = apply_to(b, plan([a, b]))

      assert compiles?(out_b)
      assert out_b =~ "do: build_serie_match_conditions(x)"
    end

    test "declines when the name is spoken as an atom literal anywhere", ctx do
      a =
        write(ctx.dir, "a.ex", """
        defmodule App.A do
          def build_serie_match_conditions_match_binding(x), do: x
        end
        """)

      b =
        write(ctx.dir, "b.ex", """
        defmodule App.B do
          def run(x), do: apply(App.A, :build_serie_match_conditions_match_binding, [x])
        end
        """)

      assert apply_to(a, plan([a, b])) == File.read!(a)
    end

    test "declines for a framework callback name", ctx do
      a =
        write(ctx.dir, "a.ex", """
        defmodule App.A do
          def handle_event("save_the_current_serie_form", params, socket), do: {params, socket}
        end
        """)

      assert apply_to(a, plan([a])) == File.read!(a)
    end

    test "declines for a function component", ctx do
      a =
        write(ctx.dir, "a.ex", """
        defmodule App.A do
          attr(:rows, :list, required: true)

          def render_serie_match_conditions_match_row(assigns) do
            ~H"<div>{@rows}</div>"
          end
        end
        """)

      assert apply_to(a, plan([a])) == File.read!(a)
    end

    test "declines when a template says the name", ctx do
      a =
        write(ctx.dir, "a.ex", """
        defmodule App.A do
          def build_serie_match_conditions_match_binding(x), do: x
        end
        """)

      File.write!(
        Path.join(ctx.dir, "page.html.heex"),
        "<div>{build_serie_match_conditions_match_binding(@x)}</div>"
      )

      assert apply_to(a, plan([a])) == File.read!(a)
    end

    test "declines when the shorter name is taken in the same module", ctx do
      long = "build_serie_match_conditions_match_binding"
      {:ok, shorter} = IdentifierCompression.compress(long, %{})

      a =
        write(ctx.dir, "a.ex", """
        defmodule App.A do
          def #{shorter}(x), do: x
          def #{long}(x), do: x
        end
        """)

      assert apply_to(a, plan([a], identifier_corpus: %{})) == File.read!(a)
    end

    test "is idempotent across the corpus", ctx do
      a =
        write(ctx.dir, "a.ex", """
        defmodule App.A do
          def build_serie_match_conditions_match_binding(x), do: x
        end
        """)

      once = apply_to(a, plan([a]))
      File.write!(a, once)

      assert apply_to(a, plan([a])) == once
    end
  end
end
