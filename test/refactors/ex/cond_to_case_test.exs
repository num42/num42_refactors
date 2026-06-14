defmodule Number42.Refactors.Ex.CondToCaseTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.CondToCase

  @subject CondToCase

  describe "rewrites" do
    test "same-var == arms with true catch-all → case with _" do
      before_source = """
      defmodule M do
        def label(status) do
          cond do
            status == :pending -> "wartet"
            status == :active -> "läuft"
            status == :done -> "fertig"
            true -> "unbekannt"
          end
        end
      end
      """

      expected = """
      defmodule M do
        def label(status) do
          case status do
            :pending -> "wartet"
            :active -> "läuft"
            :done -> "fertig"
            _ -> "unbekannt"
          end
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
      assert_compiles(apply_refactor(@subject, before_source))
    end

    test "symmetric literal == var arms" do
      before_source = """
      defmodule M do
        def f(x) do
          cond do
            :a == x -> 1
            :b == x -> 2
            true -> 0
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(x) do
          case x do
            :a -> 1
            :b -> 2
            _ -> 0
          end
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "integer literals" do
      before_source = """
      defmodule M do
        def f(n) do
          cond do
            n == 1 -> :one
            n == 2 -> :two
            true -> :many
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(n) do
          case n do
            1 -> :one
            2 -> :two
            _ -> :many
          end
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
      assert_compiles(apply_refactor(@subject, before_source))
    end

    test "no default arm still rewrites (CondClauseError ≡ CaseClauseError)" do
      before_source = """
      defmodule M do
        def f(x) do
          cond do
            x == :a -> 1
            x == :b -> 2
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(x) do
          case x do
            :a -> 1
            :b -> 2
          end
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
      assert_compiles(apply_refactor(@subject, before_source))
    end

    test "string literals" do
      before_source = """
      defmodule M do
        def f(s) do
          cond do
            s == "a" -> 1
            true -> 0
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(s) do
          case s do
            "a" -> 1
            _ -> 0
          end
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "leaves alone" do
    test "different variables across arms" do
      source = """
      defmodule M do
        def f(a, b) do
          cond do
            a == 1 -> :x
            b == 2 -> :y
            true -> :z
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "relational arm" do
      source = """
      defmodule M do
        def f(x) do
          cond do
            x == 1 -> :one
            x > 5 -> :big
            true -> :other
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "rhs is another variable" do
      source = """
      defmodule M do
        def f(x, other) do
          cond do
            x == :a -> 1
            x == other -> 2
            true -> 0
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "rhs is a function call" do
      source = """
      defmodule M do
        def f(x) do
          cond do
            x == :a -> 1
            x == default() -> 2
            true -> 0
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "test is a function call (side-effect / short-circuit)" do
      source = """
      defmodule M do
        def f(x) do
          cond do
            ready?(x) -> 1
            x == :a -> 2
            true -> 0
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "composite-literal rhs (tuple) is skipped in v1" do
      source = """
      defmodule M do
        def f(x) do
          cond do
            x == {:ok, 1} -> 1
            true -> 0
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "module attribute rhs" do
      source = """
      defmodule M do
        @default :z
        def f(x) do
          cond do
            x == :a -> 1
            x == @default -> 2
            true -> 0
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "duplicate literals across arms" do
      source = """
      defmodule M do
        def f(x) do
          cond do
            x == :a -> 1
            x == :a -> 2
            true -> 0
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "non-final true arm" do
      source = """
      defmodule M do
        def f(x) do
          cond do
            x == :a -> 1
            true -> 0
            x == :b -> 2
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "cond with no equality arms at all" do
      source = """
      defmodule M do
        def f(x) do
          cond do
            is_atom(x) -> 1
            true -> 0
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "idempotence" do
    test "rewritten case is left alone on a second pass" do
      source = """
      defmodule M do
        def label(status) do
          cond do
            status == :pending -> "wartet"
            status == :active -> "läuft"
            true -> "unbekannt"
          end
        end
      end
      """

      assert_idempotent(@subject, source)
    end

    test "already-conformant case is unchanged" do
      source = """
      defmodule M do
        def f(x) do
          case x do
            :a -> 1
            _ -> 0
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end
end
