defmodule Number42.Refactors.Ex.RelocateMisplacedFunctionTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.RelocateMisplacedFunction

  @subject RelocateMisplacedFunction

  # RelocateMisplacedFunction is a real move-method refactor with a
  # graph constraint. Like ExtractSharedModule it has a disk side-effect:
  # prepare/1 appends the moved function to the target module's file.
  # Tests run in a per-test tmp_dir and pass `:write_root` so writes are
  # contained.

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "relocate_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp prepared(sources, opts),
    do: RelocateMisplacedFunction.build_plan(sources, opts)

  # The relocation appends the moved function to the *existing* target
  # file on disk. In production that file is already on disk; here we
  # materialize the source strings under `tmp` (mirroring `write_root`)
  # before planning so `append_to_target/4` has a file to append into.
  defp materialize(sources, tmp) do
    Enum.each(sources, fn {rel, src} ->
      path = Path.join(tmp, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, src)
    end)

    sources
  end

  describe "rewrites — feature-envy move" do
    test "moves an envious function into its target module and delegates", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def brand_label(%B{} = brand) do
          B.name(brand) <> " (" <> B.code(brand) <> ")"
        end
      end
      """

      b = """
      defmodule MyApp.B do
        defstruct [:name, :code]

        def name(%__MODULE__{name: n}), do: n
        def code(%__MODULE__{code: c}), do: c
      end
      """

      caller = """
      defmodule MyApp.Caller do
        alias MyApp.A

        def render(brand), do: A.brand_label(brand)
      end
      """

      paths =
        materialize(
          [{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}, {"lib/my_app/caller.ex", caller}],
          tmp
        )

      plan = prepared(paths, write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan)
      # The host keeps a deprecated defdelegate to the target.
      assert result_a =~ "defdelegate brand_label(brand), to: MyApp.B"

      result_caller = apply_refactor(@subject, caller, prepared: plan)
      # The call site now points at the target module.
      assert result_caller =~ "MyApp.B.brand_label(brand)"
      refute result_caller =~ "A.brand_label"

      target_source = File.read!(Path.join(tmp, "lib/my_app/b.ex"))
      # The moved body keeps its struct pattern, and the host's `B`
      # alias is fully qualified so it resolves inside the target.
      assert target_source =~ "def brand_label(%MyApp.B{} = brand)"
      assert target_source =~ "MyApp.B.name(brand)"

      # The whole rewritten corpus compiles together.
      assert_compiles(result_a <> "\n" <> target_source <> "\n" <> result_caller)
    end

    test "host file with no other content is rewritten to just the delegate", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def describe(%B{} = b) do
          B.name(b) <> B.code(b)
        end
      end
      """

      b = """
      defmodule MyApp.B do
        defstruct [:name, :code]

        def name(%__MODULE__{name: n}), do: n
        def code(%__MODULE__{code: c}), do: c
      end
      """

      paths = materialize([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], tmp)
      plan = prepared(paths, write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan)
      assert result_a =~ "defdelegate describe(b), to: MyApp.B"
      refute result_a =~ "B.name(b)"

      target_source = File.read!(Path.join(tmp, "lib/my_app/b.ex"))
      assert target_source =~ "def describe(%MyApp.B{} = b)"
    end
  end

  describe "idempotence" do
    test "second pass after move is a no-op", %{tmp: tmp} do
      # The host already delegates; the target already owns the function.
      a_after = """
      defmodule MyApp.A do
        alias MyApp.B

        defdelegate brand_label(brand), to: MyApp.B
      end
      """

      b_after = """
      defmodule MyApp.B do
        defstruct [:name, :code]

        def name(%__MODULE__{name: n}), do: n
        def code(%__MODULE__{code: c}), do: c

        def brand_label(%B{} = brand) do
          B.name(brand) <> " (" <> B.code(brand) <> ")"
        end
      end
      """

      caller_after = """
      defmodule MyApp.Caller do
        alias MyApp.A

        def render(brand), do: MyApp.B.brand_label(brand)
      end
      """

      paths = [
        {"lib/my_app/a.ex", a_after},
        {"lib/my_app/b.ex", b_after},
        {"lib/my_app/caller.ex", caller_after}
      ]

      plan = prepared(paths, write_root: tmp)

      assert_unchanged(@subject, a_after, prepared: plan)
      assert_unchanged(@subject, b_after, prepared: plan)
      assert_unchanged(@subject, caller_after, prepared: plan)
    end
  end

  describe "skips" do
    test "function referencing a host private member is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def label(%B{} = brand) do
          B.name(brand) <> suffix()
        end

        defp suffix, do: "!"
      end
      """

      b = struct_b()
      plan = prepared([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan)
      refute File.exists?(Path.join(tmp, "lib/my_app/b.ex"))
    end

    test "function referencing __MODULE__ of the host is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def label(%B{} = brand) do
          B.name(brand) <> inspect(__MODULE__)
        end
      end
      """

      b = struct_b()
      plan = prepared([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan)
    end

    test "function referencing a host module attribute is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        @sep " - "

        def label(%B{} = brand) do
          B.name(brand) <> @sep <> B.code(brand)
        end
      end
      """

      b = struct_b()
      plan = prepared([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan)
    end

    test "name clash of same arity in target is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def name(%B{} = brand) do
          B.code(brand) <> B.code(brand)
        end
      end
      """

      # B already defines name/1.
      b = struct_b()
      plan = prepared([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan)
    end

    test "would-be cycle (target already references host) is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def label(%B{} = brand) do
          B.name(brand) <> B.code(brand)
        end

        def helper(x), do: x
      end
      """

      # B references A → moving label into B keeps A.helper around and A
      # would delegate to B, but B already depends on A: a cycle risk.
      b = """
      defmodule MyApp.B do
        defstruct [:name, :code]

        def name(%__MODULE__{name: n}), do: MyApp.A.helper(n)
        def code(%__MODULE__{code: c}), do: c
      end
      """

      plan = prepared([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan)
    end

    test "dynamic apply of the function makes the move unsafe", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def label(%B{} = brand) do
          B.name(brand) <> B.code(brand)
        end
      end
      """

      caller = """
      defmodule MyApp.Caller do
        def render(brand), do: apply(MyApp.A, :label, [brand])
      end
      """

      b = struct_b()

      plan =
        prepared(
          [
            {"lib/my_app/a.ex", a},
            {"lib/my_app/b.ex", b},
            {"lib/my_app/caller.ex", caller}
          ],
          write_root: tmp
        )

      assert_unchanged(@subject, a, prepared: plan)
    end

    test "function with no envied module reference is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        def add(x, y) do
          x + y + 1
        end
      end
      """

      plan = prepared([{"lib/my_app/a.ex", a}], write_root: tmp)
      assert_unchanged(@subject, a, prepared: plan)
    end

    test "function envying two different modules equally is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B
        alias MyApp.C

        def combine(b, c) do
          B.name(b) <> C.name(c)
        end
      end
      """

      b = struct_b()

      c = """
      defmodule MyApp.C do
        defstruct [:name]
        def name(%__MODULE__{name: n}), do: n
      end
      """

      plan =
        prepared(
          [{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}, {"lib/my_app/c.ex", c}],
          write_root: tmp
        )

      assert_unchanged(@subject, a, prepared: plan)
    end

    test "target module not present in corpus is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def label(%B{} = brand) do
          B.name(brand) <> B.code(brand)
        end
      end
      """

      # No file defines MyApp.B — we cannot append into a module we
      # cannot see.
      plan = prepared([{"lib/my_app/a.ex", a}], write_root: tmp)
      assert_unchanged(@subject, a, prepared: plan)
    end
  end

  defp struct_b do
    """
    defmodule MyApp.B do
      defstruct [:name, :code]

      def name(%__MODULE__{name: n}), do: n
      def code(%__MODULE__{code: c}), do: c
    end
    """
  end
end
