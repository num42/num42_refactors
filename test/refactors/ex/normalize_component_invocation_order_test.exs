defmodule Number42.Refactors.Ex.NormalizeComponentInvocationOrderTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.NormalizeComponentInvocationOrder

  @subject NormalizeComponentInvocationOrder

  # A self-contained file: a local component `foo` declaring attrs a, b, c and a
  # caller `page` that invokes `<.foo .../>` with the attrs in the wrong order.
  defp local_pair(call) do
    """
    defmodule MyAppWeb.Widgets do
      use MyAppWeb, :html

      attr :a, :string
      attr :b, :any
      attr :c, :integer
      def foo(assigns) do
        ~H"<i>{@a}{@b}{@c}</i>"
      end

      def page(assigns) do
        ~H\"\"\"
        #{call}
        \"\"\"
      end
    end
    """
  end

  defp prepared_for(sources) do
    files =
      for {name, src} <- sources do
        path = Path.join(tmp_dir(), name)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, src)
        path
      end

    {:ok, prepared} = NormalizeComponentInvocationOrder.prepare(source_files: files)
    {prepared, Map.new(sources, fn {name, src} -> {src, Path.join(tmp_dir(), name)} end)}
  end

  defp run(src, prepared, file, extra \\ []) do
    @subject.transform(
      src,
      Keyword.merge([enabled: true, prepared: prepared, file: file], extra)
    )
  end

  describe "declared_attr_order/1 — resolving declaration order from a module" do
    test "collects attrs in declaration order per component, ignoring slots" do
      src = """
      defmodule MyAppWeb.CoreComponents do
        use MyAppWeb, :html

        attr :a, :string
        attr :b, :any
        slot :inner_block
        attr :c, :integer
        def foo(assigns), do: ~H"<i/>"

        attr :x, :string
        def bar(assigns), do: ~H"<i/>"
      end
      """

      decls = NormalizeComponentInvocationOrder.declared_attr_order(src)
      assert decls["MyAppWeb.CoreComponents"]["foo"] == ["a", "b", "c"]
      assert decls["MyAppWeb.CoreComponents"]["bar"] == ["x"]
    end
  end

  describe "transform/2 — local component reorder" do
    test "orders call-site attrs to match the attr declaration order" do
      src = local_pair(~s(<.foo c={@c} a={@a} b={@b} />))
      {prepared, map} = prepared_for(%{"lib/widgets.ex" => src})

      out = run(src, prepared, map[src])

      assert out =~ ~s(<.foo a={@a} b={@b} c={@c} />)
    end

    test "resolves via the call site's alias (`<Alias.foo/>`)" do
      decl = """
      defmodule MyAppWeb.Widgets do
        use MyAppWeb, :html

        attr :a, :string
        attr :b, :any
        attr :c, :integer
        def foo(assigns), do: ~H"<i/>"
      end
      """

      caller = """
      defmodule MyAppWeb.PageLive do
        use MyAppWeb, :live_view
        alias MyAppWeb.Widgets

        def render(assigns) do
          ~H\"\"\"
          <Widgets.foo c={@c} a={@a} b={@b} />
          \"\"\"
        end
      end
      """

      {prepared, map} =
        prepared_for(%{"lib/widgets.ex" => decl, "lib/page_live.ex" => caller})

      out = run(caller, prepared, map[caller])

      assert out =~ ~s(<Widgets.foo a={@a} b={@b} c={@c} />)
    end

    test "reorders only the opening tag of an open/close call site, keeping children" do
      src =
        local_pair("""
        <.foo c={@c} a={@a} b={@b}>
              <span>hi</span>
            </.foo>\
        """)

      {prepared, map} = prepared_for(%{"lib/widgets.ex" => src})

      out = run(src, prepared, map[src])

      assert out =~ ~s(<.foo a={@a} b={@b} c={@c}>)
      assert out =~ ~s(<span>hi</span>)
      assert out =~ ~s(</.foo>)
    end

    test "resolves via the call site's import (`<.foo/>` imported)" do
      decl = """
      defmodule MyAppWeb.Widgets do
        use MyAppWeb, :html

        attr :a, :string
        attr :b, :any
        attr :c, :integer
        def foo(assigns), do: ~H"<i/>"
      end
      """

      caller = """
      defmodule MyAppWeb.PageLive do
        use MyAppWeb, :live_view
        import MyAppWeb.Widgets

        def render(assigns) do
          ~H\"\"\"
          <.foo c={@c} a={@a} b={@b} />
          \"\"\"
        end
      end
      """

      {prepared, map} =
        prepared_for(%{"lib/widgets.ex" => decl, "lib/page_live.ex" => caller})

      out = run(caller, prepared, map[caller])

      assert out =~ ~s(<.foo a={@a} b={@b} c={@c} />)
    end
  end

  describe "transform/2 — directives and unknown attrs" do
    test "structural directives (:for/:if/:let) always stay first" do
      src = local_pair(~s(<.foo c={@c} :for={x <- @xs} a={@a} :if={@ok} b={@b} />))
      {prepared, map} = prepared_for(%{"lib/widgets.ex" => src})

      out = run(src, prepared, map[src])

      assert out =~ ~s(<.foo :for={x <- @xs} :if={@ok} a={@a} b={@b} c={@c} />)
    end

    test "unknown / phx-* attrs keep their relative order AFTER declared ones" do
      src = local_pair(~s(<.foo phx-click="go" c={@c} data-x="1" a={@a} b={@b} />))
      {prepared, map} = prepared_for(%{"lib/widgets.ex" => src})

      out = run(src, prepared, map[src])

      assert out =~ ~s(<.foo a={@a} b={@b} c={@c} phx-click="go" data-x="1" />)
    end
  end

  describe "transform/2 — idempotence" do
    test "an already-ordered call site is unchanged" do
      src = local_pair(~s(<.foo a={@a} b={@b} c={@c} />))
      {prepared, map} = prepared_for(%{"lib/widgets.ex" => src})

      assert_unchanged(@subject, src, enabled: true, prepared: prepared, file: map[src])
    end

    test "a second pass is a no-op" do
      src = local_pair(~s(<.foo c={@c} a={@a} b={@b} />))
      {prepared, map} = prepared_for(%{"lib/widgets.ex" => src})

      once = run(src, prepared, map[src])
      # re-prepare against the rewritten file so resolution still holds
      {prepared2, _} = prepared_for(%{"lib/widgets.ex" => once})
      twice = run(once, prepared2, Path.join(tmp_dir(), "lib/widgets.ex"))

      assert nows(once) == nows(twice)
    end
  end

  describe "transform/2 — conservative declines" do
    test "declines when the component cannot be resolved (no declaration in corpus)" do
      src = """
      defmodule MyAppWeb.PageLive do
        use MyAppWeb, :live_view

        def render(assigns) do
          ~H\"\"\"
          <.mystery c={@c} a={@a} b={@b} />
          \"\"\"
        end
      end
      """

      {prepared, map} = prepared_for(%{"lib/page_live.ex" => src})

      assert_unchanged(@subject, src, enabled: true, prepared: prepared, file: map[src])
    end

    test "declines a plain HTML tag (not a component)" do
      src = """
      defmodule MyAppWeb.PageLive do
        use MyAppWeb, :live_view

        def render(assigns) do
          ~H\"\"\"
          <div c={@c} a={@a} b={@b} />
          \"\"\"
        end
      end
      """

      {prepared, map} = prepared_for(%{"lib/page_live.ex" => src})

      assert_unchanged(@subject, src, enabled: true, prepared: prepared, file: map[src])
    end
  end

  describe "transform/2 — default-OFF" do
    test "is a no-op without enabled: true" do
      src = local_pair(~s(<.foo c={@c} a={@a} b={@b} />))
      {prepared, map} = prepared_for(%{"lib/widgets.ex" => src})

      assert_unchanged(@subject, src, prepared: prepared, file: map[src])
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp nows(s), do: s |> String.replace(~r/\s+/, " ") |> String.trim()

  defp tmp_dir do
    dir = Process.get(:ncio_tmp_dir)

    if dir do
      dir
    else
      dir = Path.join(System.tmp_dir!(), "ncio-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      Process.put(:ncio_tmp_dir, dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      dir
    end
  end
end
