# A stand-in for ExUnit's `test` macro so generated table-driven test
# modules can be compile-checked WITHOUT registering into the running
# ExUnit suite (which would raise "cannot add module after suite starts").
# Each `test` expands to a uniquely-named zero-arity function carrying the
# body, so the `for %{...} <- [...] do test "#{desc}" do ... end end` +
# `unquote(arg_N)` shape is exercised by the real compiler.
defmodule Number42.Refactors.Ex.TableDriveSimilarTestsTest.TestStub do
  @moduledoc false
  defmacro test(_name, do: body) do
    fname = :"generated_test_#{System.unique_integer([:positive])}"

    quote do
      def unquote(fname)(), do: unquote(body)
    end
  end
end

defmodule Number42.Refactors.Ex.TableDriveSimilarTestsTest do
  @moduledoc """
  Tests for collapsing structurally-identical ExUnit `test` blocks into a
  single table-driven comprehension.

  Prove that a group of `>= min_tests` tests sharing one assertion skeleton
  (differing only in literals) is rewritten into
  `for %{...} <- cases, do: test ... end`, that the generated code compiles,
  that the per-test name becomes a row label, and that the conservative
  false-positive guards (too few tests, divergent assertion structure,
  setup-context tests, too many columns, non-test sources) fire.
  """
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.TableDriveSimilarTests

  @subject TableDriveSimilarTests

  # Default-OFF: `transform/2` is a no-op unless its opts carry
  # `enabled: true`. Behaviour tests opt in explicitly.
  @on [enabled: true]

  describe "default-OFF (opt-in only)" do
    test "without enabled: true, transform is a no-op" do
      source = three_similar_tests()
      assert apply_refactor(@subject, source) == source
    end
  end

  describe "basic literal-hole table extraction" do
    test "three structurally identical tests collapse into a for-comprehension" do
      out = apply_refactor(@subject, three_similar_tests(), @on)

      # One generated comprehension drives all three cases.
      assert out =~ "for %{"
      assert out =~ "<- ["

      # The divergent literals (1/2, 2/3, 3/4) are now data rows, not code.
      assert out =~ "1"
      assert out =~ "4"

      # The three original standalone `test "adds ..." do` heads are gone;
      # they now live as data rows inside the loop's `test "#{...}" do`.
      refute out =~ ~s(test "adds one" do)
      refute out =~ ~s(test "adds two" do)
      refute out =~ ~s(test "adds three" do)

      assert_compiles_as_test(out)
    end

    test "the per-test name survives as a row label" do
      out = apply_refactor(@subject, three_similar_tests(), @on)

      assert out =~ "adds one"
      assert out =~ "adds two"
      assert out =~ "adds three"
    end
  end

  describe "multiple holes" do
    test "tests differing in several literals get one column per divergence" do
      source = """
      defmodule ClampTest do
        use ExUnit.Case, async: true

        defp clamp(x, _hi), do: x

        test "small" do
          assert clamp(1, 10) == 1
        end

        test "medium" do
          assert clamp(2, 20) == 2
        end

        test "large" do
          assert clamp(3, 30) == 3
        end
      end
      """

      out = apply_refactor(@subject, source, @on)

      assert out =~ "for %{"
      assert out =~ "clamp("
      # All three divergent triples are present as data.
      assert out =~ "10"
      assert out =~ "20"
      assert out =~ "30"
      assert_compiles_as_test(out)
    end
  end

  describe "false-positive guards" do
    test "fewer than min_tests similar tests are left alone" do
      source = """
      defmodule AddTest do
        use ExUnit.Case, async: true

        defp add(x), do: x + 1

        test "adds one" do
          assert add(1) == 2
        end

        test "adds two" do
          assert add(2) == 3
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "min_tests is configurable" do
      source = """
      defmodule AddTest do
        use ExUnit.Case, async: true

        defp add(x), do: x + 1

        test "adds one" do
          assert add(1) == 2
        end

        test "adds two" do
          assert add(2) == 3
        end
      end
      """

      out = apply_refactor(@subject, source, @on ++ [min_tests: 2])
      assert out =~ "for %{"
      assert_compiles_as_test(out)
    end

    test "tests with different assertion structure are left alone" do
      source = """
      defmodule MixedTest do
        use ExUnit.Case, async: true

        defp add(x), do: x + 1
        defp add_all(x), do: [x + 1]
        defp valid?(x), do: x > 0

        test "checks equality" do
          assert add(1) == 2
        end

        test "checks membership" do
          assert 2 in add_all(1)
        end

        test "checks truthiness" do
          assert valid?(3)
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "tests taking a setup context are left alone" do
      source = """
      defmodule CtxTest do
        use ExUnit.Case, async: true

        defp get(_conn, x), do: x + 1

        test "one", %{conn: conn} do
          assert get(conn, 1) == 2
        end

        test "two", %{conn: conn} do
          assert get(conn, 2) == 3
        end

        test "three", %{conn: conn} do
          assert get(conn, 3) == 4
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "too many divergent columns leaves the group alone (max_columns)" do
      source = wide_table_source()

      # default max_columns should refuse a 5-wide table
      assert_unchanged(@subject, source, @on)
    end

    test "max_columns is configurable upward" do
      out = apply_refactor(@subject, wide_table_source(), @on ++ [max_columns: 6])
      assert out =~ "for %{"
      assert_compiles_as_test(out)
    end

    test "non-test sources are left alone" do
      source = """
      defmodule M do
        def add(x), do: x + 1
        def sub(x), do: x - 1
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "tests with leading comments are left alone" do
      source = """
      defmodule CommentTest do
        use ExUnit.Case, async: true

        defp add(x), do: x + 1

        test "adds one" do
          assert add(1) == 2
        end

        # this one is special and documented
        test "adds two" do
          assert add(2) == 3
        end

        test "adds three" do
          assert add(3) == 4
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end
  end

  describe "idempotence" do
    test "running twice equals running once" do
      assert_idempotent(@subject, three_similar_tests(), @on)
    end

    test "already-collapsed table is left alone" do
      source = """
      defmodule TableTest do
        use ExUnit.Case, async: true

        defp add(x), do: x + 1

        for %{desc: desc, arg_0: arg_0, arg_1: arg_1} <- [
              %{desc: "adds one", arg_0: 1, arg_1: 2},
              %{desc: "adds two", arg_0: 2, arg_1: 3},
              %{desc: "adds three", arg_0: 3, arg_1: 4}
            ] do
          test "\#{desc}" do
            assert add(arg_0) == arg_1
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end
  end

  # Compile-check generated table-driven output WITHOUT registering it into
  # the running ExUnit suite. Swaps `use ExUnit.Case` for `import`s of a
  # stub `test` macro + the real assertion macros, uniquifies the module
  # name (Code.compile_string would otherwise clash across async tests),
  # and compiles+purges. Proves the emitted `for`/`unquote`/`test` shape is
  # valid Elixir; behaviour as real ExUnit tests is covered separately.
  defp assert_compiles_as_test(source) do
    suffix = System.unique_integer([:positive])
    stub = "#{inspect(__MODULE__)}.TestStub"

    compilable =
      source
      |> String.replace(
        ~r/^(\s*)use ExUnit\.Case.*$/m,
        "\\1import #{stub}\n\\1import ExUnit.Assertions"
      )
      |> String.replace(~r/^defmodule\s+([A-Z][\w.]*)/m, "defmodule \\g{1}#{suffix}")

    assert_compiles(compilable)
  end

  # --- fixtures ----------------------------------------------------------

  defp three_similar_tests do
    """
    defmodule AddTest do
      use ExUnit.Case, async: true

      defp add(x), do: x + 1

      test "adds one" do
        assert add(1) == 2
      end

      test "adds two" do
        assert add(2) == 3
      end

      test "adds three" do
        assert add(3) == 4
      end
    end
    """
  end

  defp wide_table_source do
    """
    defmodule WideTest do
      use ExUnit.Case, async: true

      defp f(a, _b, _c, _d), do: a

      test "a" do
        assert f(1, 2, 3, 4) == 5
      end

      test "b" do
        assert f(6, 7, 8, 9) == 10
      end

      test "c" do
        assert f(11, 12, 13, 14) == 15
      end
    end
    """
  end
end
