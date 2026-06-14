defmodule Number42.Refactors.Ex.ExtractRepeatedGuardToDefguardTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractRepeatedGuardToDefguard

  @subject ExtractRepeatedGuardToDefguard

  describe "repeated single-var guard across >= 3 clauses" do
    test "extracts an identical guard into a defguardp and names each head" do
      before_source = """
      defmodule M do
        def fetch(id) when is_integer(id) and id > 0, do: do_fetch(id)
        def update(id, attrs) when is_integer(id) and id > 0, do: do_update(id, attrs)
        def delete(id) when is_integer(id) and id > 0, do: do_delete(id)
      end
      """

      expected = """
      defmodule M do
        defguardp is_valid_id(id) when is_integer(id) and id > 0

        def fetch(id) when is_valid_id(id), do: do_fetch(id)
        def update(id, attrs) when is_valid_id(id), do: do_update(id, attrs)
        def delete(id) when is_valid_id(id), do: do_delete(id)
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "normalises the guarded var name across clauses" do
      before_source = """
      defmodule M do
        def a(id) when is_integer(id) and id > 0, do: id
        def b(n) when is_integer(n) and n > 0, do: n
        def c(x) when is_integer(x) and x > 0, do: x
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert actual =~ "defguardp is_valid_id(id) when is_integer(id) and id > 0"
      assert actual =~ "def a(id) when is_valid_id(id)"
      assert actual =~ "def b(n) when is_valid_id(n)"
      assert actual =~ "def c(x) when is_valid_id(x)"
    end

    test "output compiles with defguardp before its first use" do
      before_source = """
      defmodule M do
        def fetch(id) when is_integer(id) and id > 0, do: id
        def update(id) when is_integer(id) and id > 0, do: id + 1
        def delete(id) when is_integer(id) and id > 0, do: id - 1
      end
      """

      assert_compiles(apply_refactor(@subject, before_source))
    end

    test "handles block-body clauses" do
      before_source = """
      defmodule M do
        def a(id) when is_integer(id) and id > 0 do
          id * 2
        end

        def b(id) when is_integer(id) and id > 0 do
          id + 1
        end

        def c(id) when is_integer(id) and id > 0 do
          id - 1
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert actual =~ "defguardp is_valid_id(id) when is_integer(id) and id > 0"
      assert actual =~ "def a(id) when is_valid_id(id)"
      assert_compiles(actual)
    end

    test "multi-statement block bodies keep their do/end form" do
      before_source = """
      defmodule M do
        def a(id) when is_integer(id) and id > 0 do
          x = id * 2
          x + 1
        end

        def b(id) when is_integer(id) and id > 0 do
          y = id * 3
          y + 1
        end

        def c(id) when is_integer(id) and id > 0 do
          z = id * 4
          z + 1
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert actual =~ "def a(id) when is_valid_id(id) do"
      assert_compiles(actual)
    end
  end

  describe "preserves rescue/after/else blocks when swapping the guard" do
    test "a rescue block survives the guard swap" do
      before_source = """
      defmodule M do
        defp safe_to_integer(s) when is_binary(s) do
          String.to_integer(s)
        rescue
          ArgumentError -> nil
        end

        defp normalize(s) when is_binary(s) do
          String.trim(s)
        end

        defp echo(s) when is_binary(s) do
          s
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert actual =~ "defguardp is_valid_s(s) when is_binary(s)"
      assert actual =~ "defp safe_to_integer(s) when is_valid_s(s)"
      assert actual =~ "rescue"
      assert actual =~ "ArgumentError -> nil"
      assert_compiles(actual)
    end

    test "an after block survives the guard swap" do
      before_source = """
      defmodule M do
        def a(s) when is_binary(s) do
          String.length(s)
        after
          :ok
        end

        def b(s) when is_binary(s) do
          s
        end

        def c(s) when is_binary(s) do
          s
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert actual =~ "def a(s) when is_valid_s(s)"
      assert actual =~ "after"
      assert_compiles(actual)
    end

    test "an else block (try/rescue/else) survives the guard swap" do
      before_source = """
      defmodule M do
        def a(s) when is_binary(s) do
          String.to_integer(s)
        rescue
          ArgumentError -> :error
        else
          n -> {:ok, n}
        end

        def b(s) when is_binary(s) do
          s
        end

        def c(s) when is_binary(s) do
          s
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert actual =~ "def a(s) when is_valid_s(s)"
      assert actual =~ "rescue"
      assert actual =~ "else"
      assert actual =~ "{:ok, n}"
      assert_compiles(actual)
    end
  end

  describe "leaves alone" do
    test "a guard used only twice (below the default threshold)" do
      source = """
      defmodule M do
        def fetch(id) when is_integer(id) and id > 0, do: id
        def update(id) when is_integer(id) and id > 0, do: id + 1
      end
      """

      assert_unchanged(@subject, source)
    end

    test "a guard referencing two distinct parameters" do
      source = """
      defmodule M do
        def a(x, y) when x > 0 and y > 0, do: x
        def b(x, y) when x > 0 and y > 0, do: y
        def c(x, y) when x > 0 and y > 0, do: x + y
      end
      """

      assert_unchanged(@subject, source)
    end

    test "guards that differ structurally" do
      source = """
      defmodule M do
        def a(id) when is_integer(id), do: id
        def b(id) when id > 0, do: id
        def c(id) when is_binary(id), do: id
      end
      """

      assert_unchanged(@subject, source)
    end

    test "already-named guard via existing defguardp" do
      source = """
      defmodule M do
        defguardp is_valid_id(id) when is_integer(id) and id > 0

        def fetch(id) when is_valid_id(id), do: id
        def update(id) when is_valid_id(id), do: id + 1
        def delete(id) when is_valid_id(id), do: id - 1
      end
      """

      assert_unchanged(@subject, source)
    end

    test "unguarded clauses" do
      source = """
      defmodule M do
        def a(id), do: id
        def b(id), do: id
        def c(id), do: id
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "idempotence" do
    test "running twice equals running once" do
      source = """
      defmodule M do
        def fetch(id) when is_integer(id) and id > 0, do: do_fetch(id)
        def update(id, attrs) when is_integer(id) and id > 0, do: do_update(id, attrs)
        def delete(id) when is_integer(id) and id > 0, do: do_delete(id)
      end
      """

      assert_idempotent(@subject, source)
    end
  end
end
