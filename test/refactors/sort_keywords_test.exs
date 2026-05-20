defmodule Num42.Refactors.Refactors.SortKeywordsTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.SortKeywords

  @subject SortKeywords

  describe "rewrites — map literals" do
    test "sorts a single-line map alphabetically" do
      before_source = "x = %{b: 1, a: 2}"
      after_source = "x = %{a: 2, b: 1}"
      assert_rewrites(@subject, before_source, after_source)
    end

    test "sorts a multi-line map alphabetically" do
      before_source = """
      x = %{
        b: 1,
        a: 2,
        c: 3
      }
      """

      after_source = """
      x = %{
        a: 2,
        b: 1,
        c: 3
      }
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "sorts a map whose last value's right-most leaf is `false` inside a closed call" do
      # Regression: rightmost_is_boolish? must NOT recurse through a
      # node that has its own closing-bracket meta (function call,
      # parenthesised expression). Sourceror's range over-shoot only
      # applies to bare boolish literals at the right edge — calls
      # like `Keyword.get(opts, :ci, false)` already account for `)`.
      before_source = """
      x = %{
        b: 1,
        a: Keyword.get(opts, :ci, false) or Keyword.get(opts, :check, false)
      }
      """

      after_source = """
      x = %{
        a: Keyword.get(opts, :ci, false) or Keyword.get(opts, :check, false),
        b: 1
      }
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "sorts a map whose last value is `nil` without dropping a comma" do
      # Regression: Sourceror over-shoots the range of a right-most
      # `nil` / `true` / `false` literal by one column, which used to
      # leak the trailing `}` into the slice. The refactor must clip
      # via AstHelpers.slice_node/2.
      before_source = "x = %{type: String.t(), manufacturer_id: String.t() | nil}"
      after_source = "x = %{manufacturer_id: String.t() | nil, type: String.t()}"
      assert_rewrites(@subject, before_source, after_source)
    end

    test "sorts nested maps independently" do
      before_source = "x = %{b: %{y: 1, x: 2}, a: 1}"
      after_source = "x = %{a: 1, b: %{x: 2, y: 1}}"
      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "rewrites — struct literals" do
    test "sorts struct fields alphabetically" do
      before_source = "x = %MyStruct{b: 1, a: 2}"
      after_source = "x = %MyStruct{a: 2, b: 1}"
      assert_rewrites(@subject, before_source, after_source)
    end

    test "sorts a multi-line struct with pipe-chain values" do
      # Regression: `Macro.prewalker/1` visits both the outer `:%`
      # and its inner `:%{}` for a struct literal, producing two
      # identical patches that double-write and corrupt the source.
      # `build_patches/2` must dedupe by range.
      before_source = """
      x = %Row{
        b: foo(:b) |> bar(),
        a: foo(:a) |> bar()
      }
      """

      after_source = """
      x = %Row{
        a: foo(:a) |> bar(),
        b: foo(:b) |> bar()
      }
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "rewrites — defstruct" do
    test "sorts defstruct keyword list" do
      before_source = """
      defmodule Foo do
        defstruct b: 1, a: 0
      end
      """

      after_source = """
      defmodule Foo do
        defstruct a: 0, b: 1
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "sorts multi-line defstruct keyword list with map values" do
      # Regression: multi-line `defstruct k1: %{}, k2: %{}` is what
      # bracketless multi-line keyword lists actually look like in the
      # codebase — the patcher must produce a comma-newline-indented
      # join that re-parses cleanly.
      before_source = """
      defmodule Foo do
        defstruct params: %{},
                  masses: %{},
                  functions: %{},
                  accessors: %{}
      end
      """

      after_source = """
      defmodule Foo do
        defstruct accessors: %{},
                  functions: %{},
                  masses: %{},
                  params: %{}
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "sorts defstruct atom list" do
      before_source = """
      defmodule Foo do
        defstruct [:b, :a, :c]
      end
      """

      after_source = """
      defmodule Foo do
        defstruct [:a, :b, :c]
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "leaves alone" do
    test "already-sorted map" do
      assert_unchanged(@subject, "x = %{a: 1, b: 2}")
    end

    test "single-pair map" do
      assert_unchanged(@subject, "x = %{only: 1}")
    end

    test "empty map" do
      assert_unchanged(@subject, "x = %{}")
    end

    test "map with mixed key types is left alone" do
      # `%{1 => :a, b: 2}` — partial sort would mislead readers into
      # thinking the whole map was canonicalised.
      assert_unchanged(@subject, ~s|x = %{1 => :a, b: 2}|)
    end

    test "map with string-quoted keyword keys is left alone" do
      # `"brand-id": v` parses with `format: :keyword` like a bare
      # atom key, but rendering it as `brand-id:` is invalid syntax.
      # Until we slice the original source, skip.
      assert_unchanged(@subject, ~S|x = %{"brand-id": 1, a: 2}|)
    end

    test "map update syntax with sorted pairs" do
      assert_unchanged(@subject, "%{base | a: 1, b: 2}")
    end

    test "keyword arg lists at function call sites are left alone" do
      # Reordering may or may not be safe depending on the callee
      # (e.g. `Ecto.Query.from(.., where: .., order_by: ..)`); the
      # safe-by-default refactor stays out.
      assert_unchanged(@subject, "Repo.all(Foo, timeout: 5_000, log: false)")
    end

    test "do/end keyword list is left alone" do
      assert_unchanged(@subject, """
      if cond do
        :ok
      else
        :error
      end
      """)
    end

    test "case clause list is left alone" do
      assert_unchanged(@subject, """
      case x do
        :b -> 2
        :a -> 1
      end
      """)
    end
  end

  describe "idempotent" do
    test "sorting a map is idempotent" do
      assert_idempotent(@subject, "x = %{c: 3, a: 1, b: 2}")
    end

    test "sorting a defstruct is idempotent" do
      assert_idempotent(@subject, """
      defmodule Foo do
        defstruct b: 1, a: 0
      end
      """)
    end
  end
end
