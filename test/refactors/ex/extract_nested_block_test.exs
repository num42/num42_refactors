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

    test "names the helper via HelperNaming, never the mechanical extracted_<host>" do
      # The lifted body binds `matching` from a Map.get and returns a map
      # literal — no live-out, no inferable verb. HelperNaming routes through
      # the host name instead of the #305 sinner `extracted_surcharge_options_*`.
      # The host name itself is forbidden (would collide with `def
      # surcharge_options/3`), so it lands on the `surcharge_options_block`
      # fallback — distinct name, distinct from the host, and it compiles.
      before_source = """
      defmodule Pricing do
        def surcharge_options(items, bi, by_key) do
          Enum.map(items, fn group ->
            Enum.map(group, fn item ->
              Enum.map(item.parts, fn part ->
                matching = Map.get(by_key, {part.id, bi.brand_id})

                %{item: part, brand_item: matching, latest_price: latest_price(matching)}
              end)
            end)
          end)
        end
      end
      """

      result = apply_refactor(@subject, before_source, @opts)

      refute result =~ "extracted_surcharge_options"
      assert result =~ "defp surcharge_options_block("
      assert {:ok, _} = Code.string_to_quoted(result)
    end

    test "the helper never reuses the host name (would collide at the same arity)" do
      # `strip_suffix(host)` hands back the host name verbatim; for an
      # extracted helper that is the one name guaranteed to clash with the
      # enclosing definition. Regression guard: a single-token host whose body
      # gives no other signal must fall back to `<host>_block`, not `<host>`.
      before_source = """
      defmodule Foo do
        def render(rows, ctx) do
          Enum.map(rows, fn row ->
            Enum.map(row.cells, fn cell ->
              Enum.map(cell.parts, fn part ->
                shaped = decorate(part, ctx)
                {part.id, shaped}
              end)
            end)
          end)
        end
      end
      """

      result = apply_refactor(@subject, before_source, @opts)

      refute result =~ ~r/defp render\(/, "helper must not reuse the host name `render`"
      assert result =~ "defp render_block("
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
      assert result =~ ~r/defp \w+\([^)]*\bbi\b/,
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

      assert result =~ ~r/defp \w+\([^)]*\bprefix\b/,
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
