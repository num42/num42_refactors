defmodule Number42.Refactors.Ex.ConsolidateParallelClauseFunctionsTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ConsolidateParallelClauseFunctions

  @subject ConsolidateParallelClauseFunctions

  describe "rewrites" do
    test "two functions differing in one local capture collapse into a helper" do
      source = """
      defmodule MyApp.Stats do
        def sum_active(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
        def sum_pending(xs), do: Enum.filter(xs, &pending?/1) |> Enum.sum()
      end
      """

      expected = """
      defmodule MyApp.Stats do
        def sum_active(xs), do: sum_by(xs, &active?/1)
        def sum_pending(xs), do: sum_by(xs, &pending?/1)
        defp sum_by(xs, pred), do: Enum.filter(xs, pred) |> Enum.sum()
      end
      """

      assert_rewrites(@subject, source, expected)
    end

    test "remote captures (&Mod.fun/arity) are consolidated too" do
      source = """
      defmodule MyApp.Validate do
        def all_valid(xs), do: Enum.filter(xs, &String.valid?/1) |> length()
        def all_atoms(xs), do: Enum.filter(xs, &Kernel.is_atom/1) |> length()
      end
      """

      rewritten = apply_refactor(@subject, source)

      assert rewritten =~ "defp"
      assert rewritten =~ "&String.valid?/1"
      assert rewritten =~ "&Kernel.is_atom/1"
      # The shared body appears once — in the helper.
      assert occurrences(rewritten, "Enum.filter") == 1
    end

    test "private originals stay private wrappers with a private helper" do
      source = """
      defmodule MyApp.Stats do
        defp sum_active(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
        defp sum_pending(xs), do: Enum.filter(xs, &pending?/1) |> Enum.sum()
      end
      """

      rewritten = apply_refactor(@subject, source)

      assert rewritten =~ "defp sum_active(xs)"
      assert rewritten =~ "defp sum_pending(xs)"
      assert occurrences(rewritten, "Enum.filter") == 1
    end

    test "public originals stay public wrappers (cross-module API preserved)" do
      source = """
      defmodule MyApp.Stats do
        def sum_active(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
        def sum_pending(xs), do: Enum.filter(xs, &pending?/1) |> Enum.sum()
      end
      """

      rewritten = apply_refactor(@subject, source)

      assert rewritten =~ "def sum_active(xs)"
      assert rewritten =~ "def sum_pending(xs)"
      # The synthesised helper is always private.
      assert rewritten =~ "defp sum_by(xs, pred)"
    end

    test "synthesises a colliding-free helper name with a suffix" do
      # `sum_by` already exists with a *different* shape, so the helper
      # must take `sum_by_2`.
      source = """
      defmodule MyApp.Stats do
        def sum_by(xs), do: xs
        def sum_active(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
        def sum_pending(xs), do: Enum.filter(xs, &pending?/1) |> Enum.sum()
      end
      """

      rewritten = apply_refactor(@subject, source)

      assert rewritten =~ "defp sum_by_2(xs, pred)"
      assert_compiles(inject_predicates(rewritten))
    end

    test "output compiles" do
      source = """
      defmodule MyApp.Stats do
        def sum_active(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
        def sum_pending(xs), do: Enum.filter(xs, &pending?/1) |> Enum.sum()
        defp active?(_), do: true
        defp pending?(_), do: false
      end
      """

      rewritten = apply_refactor(@subject, source)
      assert_compiles(rewritten)
    end

    test "emitted clauses are grouped (no ungrouped clauses)" do
      source = """
      defmodule MyApp.Stats do
        def sum_active(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
        def sum_pending(xs), do: Enum.filter(xs, &pending?/1) |> Enum.sum()
      end
      """

      rewritten = apply_refactor(@subject, source)
      assert ungrouped_clauses(rewritten) == []
    end

    test "is idempotent — a second pass leaves the consolidated source alone" do
      source = """
      defmodule MyApp.Stats do
        def sum_active(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
        def sum_pending(xs), do: Enum.filter(xs, &pending?/1) |> Enum.sum()
      end
      """

      assert_idempotent(@subject, source)
    end

    test "already-consolidated wrappers are not re-consolidated" do
      # Wrappers `sum_by(xs, &active?/1)` vs `sum_by(xs, &pending?/1)`
      # differ in one capture, but `sum_by` already exists — there's no
      # shared structure left to lift. Leave it alone.
      source = """
      defmodule MyApp.Stats do
        defp sum_by(xs, pred), do: Enum.filter(xs, pred) |> Enum.sum()
        def sum_active(xs), do: sum_by(xs, &active?/1)
        def sum_pending(xs), do: sum_by(xs, &pending?/1)
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "skips" do
    test "differ in more than one position" do
      source = """
      defmodule M do
        def a(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
        def b(xs), do: Enum.reject(xs, &pending?/1) |> Enum.sum()
      end
      """

      assert_unchanged(@subject, source)
    end

    test "differ in a literal, not a capture" do
      source = """
      defmodule M do
        def a(xs), do: Enum.take(xs, 1)
        def b(xs), do: Enum.take(xs, 2)
      end
      """

      assert_unchanged(@subject, source)
    end

    test "partial-application capture is skipped (free vars)" do
      source = """
      defmodule M do
        def a(xs, ctx), do: Enum.filter(xs, &active?(&1, ctx)) |> Enum.sum()
        def b(xs, ctx), do: Enum.filter(xs, &pending?(&1, ctx)) |> Enum.sum()
      end
      """

      assert_unchanged(@subject, source)
    end

    test "different arity" do
      source = """
      defmodule M do
        def a(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
        def b(xs, y), do: Enum.filter([xs | y], &pending?/1) |> Enum.sum()
      end
      """

      assert_unchanged(@subject, source)
    end

    test "multi-clause function" do
      source = """
      defmodule M do
        def a([]), do: 0
        def a(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
        def b(xs), do: Enum.filter(xs, &pending?/1) |> Enum.sum()
      end
      """

      assert_unchanged(@subject, source)
    end

    test "guarded head" do
      source = """
      defmodule M do
        def a(xs) when is_list(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
        def b(xs) when is_list(xs), do: Enum.filter(xs, &pending?/1) |> Enum.sum()
      end
      """

      assert_unchanged(@subject, source)
    end

    test "pattern parameters" do
      source = """
      defmodule M do
        def a(%{items: xs}), do: Enum.filter(xs, &active?/1) |> Enum.sum()
        def b(%{items: xs}), do: Enum.filter(xs, &pending?/1) |> Enum.sum()
      end
      """

      assert_unchanged(@subject, source)
    end

    test "defmacro is left alone" do
      source = """
      defmodule M do
        defmacro a(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
        defmacro b(xs), do: Enum.filter(xs, &pending?/1) |> Enum.sum()
      end
      """

      assert_unchanged(@subject, source)
    end

    test "only one function present" do
      source = """
      defmodule M do
        def a(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
      end
      """

      assert_unchanged(@subject, source)
    end

    test "identical bodies (no differing capture) are left for the exact-clone refactors" do
      source = """
      defmodule M do
        def a(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
        def b(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  # Count non-overlapping occurrences of `needle` in `haystack`.
  defp occurrences(haystack, needle),
    do: (haystack |> String.split(needle) |> length()) - 1

  # The canonical fixture references `&active?/1` / `&pending?/1`; the
  # helper-collision fixture omits those defs, so inject stubs to make
  # the rewritten output compilable.
  defp inject_predicates(source) do
    String.replace(
      source,
      ~r/^end\s*$/m,
      "  defp active?(_), do: true\n  defp pending?(_), do: false\nend\n",
      global: false
    )
  end
end
