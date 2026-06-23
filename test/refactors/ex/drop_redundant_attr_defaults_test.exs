defmodule Number42.Refactors.Ex.DropRedundantAttrDefaultsTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.DropRedundantAttrDefaults

  @subject DropRedundantAttrDefaults

  # A module declaring a local function component `button` with several typed
  # defaults, plus a `render/1` whose ~H invokes `<.button …/>` at a call site.
  defp local_module(call) do
    """
    defmodule MyAppWeb.Buttons do
      use MyAppWeb, :html

      attr :size, :string, default: "md"
      attr :count, :integer, default: 3
      attr :flag, :boolean, default: true
      attr :maybe, :any, default: nil
      attr :label, :string, default: "Save"
      attr :nodefault, :string
      slot :inner_block

      def button(assigns) do
        ~H\"\"\"
        <button class="btn">{render_slot(@inner_block)}</button>
        \"\"\"
      end

      def page(assigns) do
        ~H\"\"\"
        <section>
          #{call}
        </section>
        \"\"\"
      end
    end
    """
  end

  # The refactor is enabled by default; `enabled: true` is now ignored but
  # harmless. The helper keeps the behavioural tests explicit about opting in.
  defp enabled(opts \\ []), do: Keyword.put(opts, :enabled, true)

  describe "literal equal to declared default — dropped" do
    test "string literal equal to default is dropped" do
      out = apply_refactor(@subject, local_module(~s(<.button size="md" />)), enabled())
      refute out =~ ~s(size="md")
      assert out =~ "<.button />"
    end

    test "string default expressed as attr={\"md\"} is dropped" do
      out = apply_refactor(@subject, local_module(~s(<.button size={"md"} />)), enabled())
      refute out =~ "size="
      assert out =~ "<.button />"
    end

    test "integer literal equal to default is dropped" do
      out = apply_refactor(@subject, local_module("<.button count={3} />"), enabled())
      refute out =~ "count="
      assert out =~ "<.button />"
    end

    test "boolean literal equal to default is dropped" do
      out = apply_refactor(@subject, local_module("<.button flag={true} />"), enabled())
      refute out =~ "flag="
    end

    test "nil literal equal to default is dropped" do
      out = apply_refactor(@subject, local_module("<.button maybe={nil} />"), enabled())
      refute out =~ "maybe="
    end

    test "only the redundant attr is dropped; others survive" do
      out =
        apply_refactor(
          @subject,
          local_module(~s(<.button size="md" label="Custom" count={9} />)),
          enabled()
        )

      refute out =~ "size="
      assert out =~ ~s(label="Custom")
      assert out =~ "count={9}"
    end
  end

  describe "NOT equal / unresolvable / non-literal — kept" do
    test "literal not equal to default is kept" do
      assert_unchanged(@subject, local_module(~s(<.button size="lg" />)), enabled())
    end

    test "type-confused literal does not match (string \"3\" vs integer default 3)" do
      assert_unchanged(@subject, local_module(~s(<.button count="3" />)), enabled())
    end

    test "dynamic expression attr is never touched" do
      assert_unchanged(@subject, local_module("<.button size={@size} />"), enabled())
    end

    test "non-literal expression attr is never touched" do
      assert_unchanged(@subject, local_module("<.button size={compute()} />"), enabled())
    end

    test "attr declared without a default is kept" do
      assert_unchanged(@subject, local_module(~s(<.button nodefault="x" />)), enabled())
    end

    test "unknown attr (not declared on the component) is kept" do
      assert_unchanged(@subject, local_module(~s(<.button unknown="md" />)), enabled())
    end

    test "unresolvable component is declined" do
      src = """
      defmodule MyAppWeb.Page do
        use MyAppWeb, :html

        def page(assigns) do
          ~H\"\"\"
          <section>
            <.elsewhere size="md" />
          </section>
          \"\"\"
        end
      end
      """

      assert_unchanged(@subject, src, enabled())
    end
  end

  describe "idempotence" do
    test "idempotent on a droppable call site" do
      assert_idempotent(@subject, local_module(~s(<.button size="md" count={3} />)), enabled())
    end

    test "idempotent on an already-clean call site" do
      assert_idempotent(@subject, local_module("<.button />"), enabled())
    end
  end

  describe "multi-sigil safety" do
    # A component's own ~H sigil and the call-site sigil coexist in one file.
    # The drop must touch only the call-site sigil, never corrupt the other.
    test "leaves the component's own sigil intact while rewriting the call site" do
      out = apply_refactor(@subject, local_module(~s(<.button size="md" />)), enabled())

      # the component body sigil is untouched
      assert out =~ "render_slot(@inner_block)"
      assert out =~ ~s(<button class="btn">)
      # the call site dropped the redundant attr
      assert out =~ "<.button />"
    end

    test "preserves surrounding markup when the sole attr is dropped" do
      out = apply_refactor(@subject, local_module(~s(<.button size="md" />)), enabled())
      assert out =~ "<section>"
      assert out =~ "</section>"
    end

    # An inline `~H"…"` sigil must NOT be rewritten into a heredoc (uncompilable);
    # the inline delimiter is preserved when the body needs no escaping.
    test "rewrites an inline ~H sigil without producing uncompilable heredoc" do
      src = """
      defmodule MyAppWeb.Inline do
        attr :count, :integer, default: 3
        def w(assigns), do: ~H"<.w count={3} />"
      end
      """

      out = apply_refactor(@subject, src, enabled())
      assert out =~ ~s(~H"<.w />")
      refute out =~ "count="
      assert match?({:ok, _}, Code.string_to_quoted(out))
    end
  end

  describe "cross-file resolution via import / alias" do
    @components """
    defmodule MyAppWeb.CoreComponents do
      use MyAppWeb, :html

      attr :size, :string, default: "md"
      attr :variant, :string, default: "solid"

      def button(assigns) do
        ~H\"\"\"
        <button class="btn">x</button>
        \"\"\"
      end
    end
    """

    defp caller(directive, call) do
      """
      defmodule MyAppWeb.PageLive do
        use MyAppWeb, :live_view
        #{directive}

        def render(assigns) do
          ~H\"\"\"
          <section>
            #{call}
          </section>
          \"\"\"
        end
      end
      """
    end

    defp prepared(sources) do
      {:ok, prep} = DropRedundantAttrDefaults.prepare(source_files: write_tmp(sources))
      prep
    end

    test "import — local <.button> resolves to the imported module's default" do
      caller_src = caller("import MyAppWeb.CoreComponents", ~s(<.button size="md" />))
      prep = prepared(%{"core.ex" => @components, "page.ex" => caller_src})

      out =
        @subject.transform(caller_src,
          enabled: true,
          file: file_for(prep, caller_src),
          prepared: prep
        )

      refute out =~ "size="
      assert out =~ "<.button />"
    end

    test "alias — <Components.button> resolves via the alias to the module default" do
      caller_src =
        caller(
          "alias MyAppWeb.CoreComponents, as: Components",
          ~s(<Components.button size="md" />)
        )

      prep = prepared(%{"core.ex" => @components, "page.ex" => caller_src})

      out =
        @subject.transform(caller_src,
          enabled: true,
          file: file_for(prep, caller_src),
          prepared: prep
        )

      refute out =~ "size="
      assert out =~ "<Components.button />"
    end

    test "alias — non-default literal is kept across files" do
      caller_src =
        caller(
          "alias MyAppWeb.CoreComponents, as: Components",
          ~s(<Components.button size="xl" />)
        )

      prep = prepared(%{"core.ex" => @components, "page.ex" => caller_src})

      out =
        @subject.transform(caller_src,
          enabled: true,
          file: file_for(prep, caller_src),
          prepared: prep
        )

      assert out == caller_src
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp unique_tmp_dir do
    dir = Path.join(System.tmp_dir!(), "drad-#{System.unique_integer([:positive])}")
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

  defp file_for(prepared, source), do: Map.fetch!(prepared.source_to_file, source)
end
