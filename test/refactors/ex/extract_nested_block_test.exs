defmodule Number42.Refactors.Ex.ExtractNestedBlockTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractNestedBlock

  @subject ExtractNestedBlock

  # The refactor only lifts a deepest fn body when it is either (a)
  # multi-statement, or (b) a nesting construct (case/if/with). A
  # single-expression deepest body is intentionally left alone — the
  # lift wouldn't reduce nesting in any meaningful way.
  @opts [max_nesting: 2]

  describe "rewrites" do
    test "extracts a too-deeply-nested fn with multi-statement body into a private helper" do
      before_source = """
      defmodule Foo do
        def go(list) do
          Enum.map(list, fn x ->
            Enum.map(x.items, fn i ->
              Enum.map(i.tags, fn t ->
                n = t.name
                n
              end)
            end)
          end)
        end
      end
      """

      result = apply_refactor(@subject, before_source, @opts)

      assert result =~ "defp ", "expected a private helper to be lifted"
      assert result =~ "FIXME"
      refute result == before_source
    end
  end

  describe "leaves alone" do
    test "shallow code (no nesting beyond max)" do
      assert_unchanged(
        @subject,
        """
        defmodule Foo do
          def go(list), do: Enum.map(list, & &1)
        end
        """,
        @opts
      )
    end

    test "deep nesting with single-expression deepest body (unliftable)" do
      assert_unchanged(
        @subject,
        """
        defmodule Foo do
          def go(list) do
            Enum.map(list, fn x ->
              Enum.map(x.items, fn i ->
                Enum.map(i.tags, fn t -> t.name end)
              end)
            end)
          end
        end
        """,
        @opts
      )
    end

    test "no defmodule wrapper" do
      assert_unchanged(@subject, "x = 1\n", @opts)
    end
  end

  describe "module attributes inside lifted helper" do
    test "extracted helper retains access to @attr (defp lives in same module)" do
      # The lifted helper lands in the same module, so any `@attr`
      # reference in the lifted body keeps working — no need to
      # thread the value as a parameter. Pin the behaviour: extraction
      # happens, output compiles.
      before_source = """
      defmodule Foo do
        @prefix "X"

        def go(list) do
          Enum.map(list, fn x ->
            Enum.map(x.items, fn i ->
              Enum.map(i.tags, fn t ->
                name = @prefix <> t.name
                name
              end)
            end)
          end)
        end
      end
      """

      result = apply_refactor(@subject, before_source, @opts)

      assert result =~ "defp ", "expected a private helper to be lifted"
      assert result =~ "@prefix", "module attribute must remain accessible"
      assert {:ok, _} = Code.string_to_quoted(result)
    end
  end

  describe "closure variables from enclosing scope" do
    test "captures `for`-comprehension generator binding as helper param" do
      # Regression from position-db: a `for bi <- list, into: %{} do ... end`
      # binds `bi` via the `<-` generator. An `fn` extracted from inside
      # the comprehension body that references `bi` must receive it as
      # a parameter — otherwise the lifted helper sees an undefined
      # variable and the module fails to compile.
      before_source = """
      defmodule Foo do
        def go(list, by_key) do
          if list != [] do
            for bi <- list, into: %{} do
              grouped =
                bi.items
                |> Enum.map(fn item ->
                  matching = Map.get(by_key, {item.id, bi.brand_id})
                  %{item: item, matching: matching}
                end)

              {bi.id, grouped}
            end
          end
        end
      end
      """

      result = apply_refactor(@subject, before_source, @opts)

      assert {:ok, _} = Code.string_to_quoted(result),
             "extracted helper must produce parseable code"

      # The helper must accept `bi` (or whatever Sourceror renames it to)
      # so the captured closure variable resolves.
      assert result =~ ~r/defp extracted_\w+\([^)]*\bbi\b/,
             "extracted helper must take `bi` (the `for` generator binding) as a parameter:\n#{result}"
    end

    test "captures `with` clause binding as helper param" do
      before_source = """
      defmodule Foo do
        def go(list, by_key) do
          with {:ok, prefix} <- fetch_prefix() do
            Enum.map(list, fn x ->
              Enum.map(x.items, fn i ->
                key = prefix <> i.name
                %{key: key, x: x}
              end)
            end)
          end
        end
      end
      """

      result = apply_refactor(@subject, before_source, @opts)

      assert {:ok, _} = Code.string_to_quoted(result)

      assert result =~ ~r/defp extracted_\w+\([^)]*\bprefix\b/,
             "extracted helper must take `prefix` (the `with`-clause binding) as a parameter:\n#{result}"
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      source = """
      defmodule Foo do
        def go(list) do
          Enum.map(list, fn x ->
            Enum.map(x.items, fn i ->
              Enum.map(i.tags, fn t ->
                n = t.name
                n
              end)
            end)
          end)
        end
      end
      """

      assert_idempotent(@subject, source, @opts)
    end
  end
end
