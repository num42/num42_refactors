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

  describe "multiple distinct repeated guards in one module" do
    # Two independent guard groups, each >= 3 occurrences. Both must be
    # extracted in a single pass; lifting one per pass leaves work for the
    # next pass and breaks idempotence (#269).
    test "extracts every eligible group in one pass" do
      before_source = """
      defmodule M do
        def a(id) when is_integer(id) and id > 0, do: id
        def b(id) when is_integer(id) and id > 0, do: id
        def c(id) when is_integer(id) and id > 0, do: id

        def d(name) when is_binary(name), do: name
        def e(name) when is_binary(name), do: name
        def f(name) when is_binary(name), do: name
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert actual =~ "defguardp is_valid_id(id) when is_integer(id) and id > 0"
      assert actual =~ "defguardp is_valid_name(name) when is_binary(name)"
      assert actual =~ "def a(id) when is_valid_id(id)"
      assert actual =~ "def d(name) when is_valid_name(name)"
      assert_compiles(actual)
    end

    # Two distinct guards over identically-named first vars would derive the
    # same `is_valid_<var>` name. Emitting both in one pass must disambiguate
    # rather than define the guard name twice (which would not compile).
    test "disambiguates two groups that derive the same name" do
      before_source = """
      defmodule M do
        def a(x) when is_integer(x) and x > 0, do: x
        def b(x) when is_integer(x) and x > 0, do: x
        def c(x) when is_integer(x) and x > 0, do: x

        def d(x) when is_binary(x), do: x
        def e(x) when is_binary(x), do: x
        def f(x) when is_binary(x), do: x
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert_compiles(actual)
      assert_idempotent(@subject, before_source)
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

    # Mirrors the position-db shape from #269: a module with two distinct
    # repeated-guard groups (one `is_list`, one `is_binary`) over several
    # different variable names. The old code lifted one group per pass, so
    # pass 2 still found the second group → not idempotent.
    test "running twice equals running once with two distinct guard groups" do
      source = """
      defmodule M do
        def load(position_ids) when is_list(position_ids), do: position_ids
        def fetch(position_ids) when is_list(position_ids), do: position_ids
        def map(position_ids) when is_list(position_ids), do: position_ids

        def children(parent_id) when is_binary(parent_id), do: parent_id
        def chain(oz_chain) when is_binary(oz_chain), do: oz_chain
        def search(search_term) when is_binary(search_term), do: search_term
      end
      """

      assert_idempotent(@subject, source)
    end
  end

  # --- Source B: body-if conditions lifted into a named defguardp --------
  #
  # A `def f(x) do if COND, do: A, else: B end` whose COND is a *complex*
  # guard expression (>= 2 guard operators) is lifted to a named defguardp
  # plus two guard-driven clauses. Single-operator conditions are left to
  # `ExtractCondIfGuardClauses` (inline `when`), which has no naming value.
  describe "body-if condition lifted to a named defguardp" do
    test "complex condition (>= 2 guard ops) is named and lifted to guard clauses" do
      before_source = """
      defmodule M do
        def classify(n) do
          if is_integer(n) and n > 0, do: :pos, else: :other
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert actual =~ "defguardp is_valid_n(n) when is_integer(n) and n > 0"
      assert actual =~ "def classify(n) when is_valid_n(n), do: :pos"
      # `n` is unused in the catch-all body (`:other`), so it's underscored.
      assert actual =~ "def classify(_n), do: :other"
      assert_compiles(actual)
    end

    test "three-operator condition lifts" do
      before_source = """
      defmodule M do
        def bucket(n) do
          if is_integer(n) and n > 0 and n < 100, do: :small, else: :big
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert actual =~ "defguardp is_valid_n(n) when is_integer(n) and n > 0 and n < 100"
      assert actual =~ "def bucket(n) when is_valid_n(n), do: :small"
      assert_compiles(actual)
    end

    test "block-body branches keep their do/end form" do
      before_source = """
      defmodule M do
        def run(n) do
          if is_integer(n) and n > 0 do
            x = n * 2
            x + 1
          else
            0
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert actual =~ "defguardp is_valid_n(n) when is_integer(n) and n > 0"
      assert actual =~ "def run(n) when is_valid_n(n) do"
      assert_compiles(actual)
    end

    test "second parameter unused in the do-clause is underscored" do
      before_source = """
      defmodule M do
        def pick(n, fallback) do
          if is_integer(n) and n > 0, do: n, else: fallback
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert actual =~ "defguardp is_valid_n(n) when is_integer(n) and n > 0"
      # do-clause uses only n → fallback underscored; catch-all uses fallback.
      assert actual =~ "def pick(n, _fallback) when is_valid_n(n), do: n"
      assert actual =~ "def pick(_n, fallback), do: fallback"
      assert_compiles(actual)
    end
  end

  describe "body-if leaves alone" do
    test "single-operator condition is left to inline lifting (no defguardp)" do
      # `n < 0` is a single comparison — naming it adds no value, so this
      # refactor declines and ExtractCondIfGuardClauses handles it inline.
      source = """
      defmodule M do
        def classify(n) do
          if n < 0, do: :neg, else: :pos
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "single is_* predicate is left alone (one operator)" do
      source = """
      defmodule M do
        def kind(x) do
          if is_atom(x), do: :atom, else: :other
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "non-guard-safe condition is left alone" do
      source = """
      defmodule M do
        def valid(s) do
          if String.length(s) > 3 and is_binary(s), do: :ok, else: :bad
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "condition over a non-parameter (local binding) is left alone" do
      source = """
      defmodule M do
        def run(x) do
          y = x + 1

          if is_integer(y) and y > 0, do: :a, else: :b
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "if without an else branch is left alone" do
      source = """
      defmodule M do
        def run(n) do
          if is_integer(n) and n > 0, do: :pos
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "if embedded in a larger body is left alone" do
      source = """
      defmodule M do
        def run(n) do
          log(n)
          if is_integer(n) and n > 0, do: :pos, else: :other
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "a head with an existing when-guard is left alone" do
      source = """
      defmodule M do
        def run(n) when is_number(n) do
          if is_integer(n) and n > 0, do: :pos, else: :other
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "body-if idempotence" do
    test "running twice on a complex-cond body equals running once" do
      source = """
      defmodule M do
        def classify(n) do
          if is_integer(n) and n > 0, do: :pos, else: :other
        end
      end
      """

      assert_idempotent(@subject, source)
    end
  end
end
