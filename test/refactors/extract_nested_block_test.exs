defmodule Num42.Refactors.Refactors.ExtractNestedBlockTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.ExtractNestedBlock

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
