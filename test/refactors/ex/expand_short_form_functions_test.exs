defmodule Number42.Refactors.Ex.ExpandShortFormFunctionsTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExpandShortFormFunctions

  @subject ExpandShortFormFunctions

  describe "known mapping" do
    test "explicit known mapping renames defp and call sites" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def public(x) do
            fetch_kw(x)
          end

          defp fetch_kw(arg) do
            arg
          end
        end
        ''',
        ~S'''
        defmodule M do
          def public(x) do
            fetch_keyword(x)
          end

          defp fetch_keyword(arg) do
            arg
          end
        end
        ''',
        known: %{"kw" => "keyword"}
      )
    end

    test "leaves public defs alone (cross-module risk)" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def fetch_kw(arg) do
            arg
          end
        end
        ''',
        known: %{"kw" => "keyword"}
      )
    end

    test "renames defmacrop the same way" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          defmacrop wrap_kw(arg) do
            quote do: unquote(arg)
          end

          def go(x) do
            wrap_kw(x)
          end
        end
        ''',
        ~S'''
        defmodule M do
          defmacrop wrap_keyword(arg) do
            quote do: unquote(arg)
          end

          def go(x) do
            wrap_keyword(x)
          end
        end
        ''',
        known: %{"kw" => "keyword"}
      )
    end
  end

  describe "skip conditions" do
    test "all parts whitelisted — no rename" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          defp do_id(id), do: id
        end
        ''',
        known: %{}
      )
    end

    test "name has no short part — no rename" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          defp normalize_value(value), do: value
        end
        ''',
        known: %{}
      )
    end

    test "rename would collide with existing function in module — skip" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          defp fetch_kw(arg), do: arg
          defp fetch_keyword(arg), do: arg
        end
        ''',
        known: %{"kw" => "keyword"}
      )
    end

    test "no mapping, no heuristic signal — leave alone" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          defp xyz_q(arg), do: arg
        end
        ''',
        known: %{}
      )
    end
  end

  describe "heuristic resolution via aliases" do
    test "alias-based: defp fetch_cs renames using Ecto.Changeset alias" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          alias Ecto.Changeset

          defp fetch_cs(arg) do
            arg
          end

          def go(x) do
            fetch_cs(x)
          end
        end
        ''',
        ~S'''
        defmodule M do
          alias Ecto.Changeset

          defp fetch_changeset(arg) do
            arg
          end

          def go(x) do
            fetch_changeset(x)
          end
        end
        '''
      )
    end
  end

  describe "HEEx ~H sigils — rename references" do
    test "component reference <.foo /> is renamed when foo is a renamed defp" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <.dep_row :for={d <- @deps} dep={d} />
            """
          end

          defp dep_row(assigns) do
            ~H"""
            <span>x</span>
            """
          end
        end
        ''',
        ~S'''
        defmodule M do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <.dependency_row :for={d <- @deps} dep={d} />
            """
          end

          defp dependency_row(assigns) do
            ~H"""
            <span>x</span>
            """
          end
        end
        ''',
        known: %{"dep" => "dependency"},
        whitelist: [:row]
      )
    end

    test "open and close component tags both renamed" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <.dep_block>
              <span>inside</span>
            </.dep_block>
            """
          end

          defp dep_block(assigns) do
            ~H"""
            <div>{render_slot(@inner_block)}</div>
            """
          end
        end
        ''',
        ~S'''
        defmodule M do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <.dependency_block>
              <span>inside</span>
            </.dependency_block>
            """
          end

          defp dependency_block(assigns) do
            ~H"""
            <div>{render_slot(@inner_block)}</div>
            """
          end
        end
        ''',
        known: %{"dep" => "dependency"}
      )
    end

    test "function call inside {...} expression is renamed" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <span>{dep_formula(@dep)}</span>
            """
          end

          defp dep_formula(_), do: "?"
        end
        ''',
        ~S'''
        defmodule M do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <span>{dependency_formula(@dep)}</span>
            """
          end

          defp dependency_formula(_), do: "?"
        end
        ''',
        known: %{"dep" => "dependency"}
      )
    end

    test "capture &name/arity is renamed" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <button phx-click={&dep_handler/1}>x</button>
            """
          end

          defp dep_handler(_), do: :ok
        end
        ''',
        ~S'''
        defmodule M do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <button phx-click={&dependency_handler/1}>x</button>
            """
          end

          defp dependency_handler(_), do: :ok
        end
        ''',
        known: %{"dep" => "dependency"}
      )
    end

    test "@doc strings are NOT touched even when they mention the renamed function" do
      # `@doc "See `dep_row/1`"` is a doc-string literal, not an AST
      # call site. Renaming references inside doc strings would change
      # text the user wrote intentionally — leave them alone. The
      # function head and HEEx call sites are renamed; the doc text
      # stays byte-identical (same as `~r` sigils).
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          use Phoenix.Component

          @doc "See `dep_row/1` for the row component."
          def render(assigns) do
            ~H"""
            <.dep_row x={@x} />
            """
          end

          defp dep_row(assigns) do
            ~H"""
            <span>{@x}</span>
            """
          end
        end
        ''',
        ~S'''
        defmodule M do
          use Phoenix.Component

          @doc "See `dep_row/1` for the row component."
          def render(assigns) do
            ~H"""
            <.dependency_row x={@x} />
            """
          end

          defp dependency_row(assigns) do
            ~H"""
            <span>{@x}</span>
            """
          end
        end
        ''',
        known: %{"dep" => "dependency"},
        whitelist: [:row]
      )
    end

    test "non-HEEx sigils (~r) are NOT touched even when content mentions the function" do
      # The HEEx-rename code walks every sigil but should only patch
      # `:sigil_H` nodes. A regex literal that happens to mention the
      # function name as a search pattern must remain byte-identical.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <.dep_row x={@x} />
            """
          end

          defp dep_row(assigns) do
            re = ~r/dep_row/
            ~H"""
            <span>{@x}-{Regex.source(re)}</span>
            """
          end
        end
        ''',
        ~S'''
        defmodule M do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <.dependency_row x={@x} />
            """
          end

          defp dependency_row(assigns) do
            re = ~r/dep_row/
            ~H"""
            <span>{@x}-{Regex.source(re)}</span>
            """
          end
        end
        ''',
        known: %{"dep" => "dependency"},
        whitelist: [:row, :re]
      )
    end

    test "word boundary protects similarly-named functions" do
      # `my_dep_formula` must NOT become `my_dependency_formula` when only
      # `dep_formula` is being renamed.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <span>{dep_formula(@dep)}</span>
            <span>{my_dep_formula(@dep)}</span>
            """
          end

          defp dep_formula(_), do: "?"
          defp my_dep_formula(_), do: "?"
        end
        ''',
        ~S'''
        defmodule M do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <span>{dependency_formula(@dep)}</span>
            <span>{my_dep_formula(@dep)}</span>
            """
          end

          defp dependency_formula(_), do: "?"
          defp my_dep_formula(_), do: "?"
        end
        ''',
        known: %{"dep" => "dependency"}
      )
    end
  end

  describe "Elixir captures &name/arity" do
    test "capture in an Enum.sort_by call is renamed alongside the defp" do
      # `&pair_sort_key/1` is a function capture, not a call. The
      # AST shape is `{:&, _, [{:/, _, [{name, meta, ctx}, arity]}]}`
      # — `name` is NOT a call node (no arg list), so the call-site
      # patcher must learn this separate shape. Without it, the defp
      # gets renamed but the capture stays stale → compile-error.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(pairs) do
            Enum.sort_by(pairs, &pair_sort_kw/1)
          end

          defp pair_sort_kw({k, _v}), do: k
        end
        ''',
        ~S'''
        defmodule M do
          def go(pairs) do
            Enum.sort_by(pairs, &pair_sort_keyword/1)
          end

          defp pair_sort_keyword({k, _v}), do: k
        end
        ''',
        known: %{"kw" => "keyword"}
      )
    end

    test "capture with multi-arity defp group is renamed at every arity site" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(x) do
            f1 = &fetch_kw/1
            f2 = &fetch_kw/2
            {f1.(x), f2.(x, :default)}
          end

          defp fetch_kw(arg), do: arg
          defp fetch_kw(arg, _default), do: arg
        end
        ''',
        ~S'''
        defmodule M do
          def go(x) do
            f1 = &fetch_keyword/1
            f2 = &fetch_keyword/2
            {f1.(x), f2.(x, :default)}
          end

          defp fetch_keyword(arg), do: arg
          defp fetch_keyword(arg, _default), do: arg
        end
        ''',
        known: %{"kw" => "keyword"}
      )
    end
  end

  describe "stop words" do
    test "common English short words in function names are never expanded" do
      # `key`, `for`, `or`, `of` are not abbreviations; they are
      # English function words that carry meaning inside a function
      # name (`pair_sort_key`, `patches_for_node`, `group_or_skip`,
      # `length_of_list`). The heuristic must not expand them even
      # when a context compound would latch (e.g. the module name
      # being `SortKeywords`, which would otherwise let `key` →
      # `keywords`).
      assert_unchanged(
        @subject,
        ~S'''
        defmodule SortKeywords do
          defp atom_block_key(x), do: x
          defp pair_sort_key({k, _}), do: k
          defp patches_for_node(_), do: []
          defp group_or_skip(_), do: []
          defp length_of_list(l), do: length(l)
        end
        '''
      )
    end

    test "stop words are not expanded even with an explicit known mapping" do
      # If a user accidentally configured `known: %{"key" => "..."}`
      # we still refuse — the stop-list is a hard guarantee that
      # English function words are never silently rewritten in
      # identifier positions where they carry semantic meaning.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          defp atom_block_key(x), do: x
        end
        ''',
        known: %{"key" => "keyword"}
      )
    end
  end

  describe "regression: weak-signal module-subtoken matches" do
    test "does not pluralize a subtoken just because the module name's last token is its plural" do
      # Regression from position-db: `defp build_item_row/...` in
      # module `PositionDbWeb.PriceListLive.ReviewRows` was renamed to
      # `build_item_rows/...`. The `row` subtoken latched on `rows` in
      # the module's last segment — but a function literally called
      # `*_row` building a single row should not become `*_rows`. The
      # module-name-tail compound is too weak a signal when it differs
      # from the short by exactly a singular/plural flip: it
      # systematically inverts the cardinality the author chose.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule PositionDbWeb.PriceListLive.ReviewRows do
          defp build_item_row(item), do: item
        end
        '''
      )
    end

    test "does not blow up a name when the expansion already appears in it" do
      # Regression from position-db: `defp ip_item_component/1` in
      # module `PositionDbWeb.ReferenceBuildingLive.ItemPickerComponent`
      # became `defp item_picker_component_item_component/1`. The `ip`
      # short latched on `ItemPicker…` as initials-of-subtokens → 100
      # score → expansion `item_picker_component`, which was then
      # concatenated with the unchanged tail `_item_component`. The
      # result duplicates the `item_component` segment.
      #
      # General rule: if the expansion of a subtoken contains another
      # subtoken of the same function name, we are about to write
      # `expansion_<that_subtoken>` — silently duplicating. Skip.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule PositionDbWeb.ReferenceBuildingLive.ItemPickerComponent do
          defp ip_item_component(assigns), do: assigns
        end
        '''
      )
    end
  end

  describe "regression: re-expansion loop on deliberately-truncated names (#15)" do
    test "does not re-expand a short that is a contiguous prefix of a context word" do
      # Regression #15: the heuristic latched `str` against the module
      # name `Stream` and rewrote `defp str_token/1` to
      # `stream_token/1`. But `str` is just the first three (contiguous)
      # characters of `stream` — the author wrote a deliberately
      # truncated leading word, not an abbreviation that drops internal
      # letters (`cs → changeset`, `kw → keyword`). Auto-completing a
      # prefix-truncation fights the author: every run re-expands it,
      # and after the human renames it back the loop repeats. A short
      # that is a contiguous prefix of its only-word heuristic expansion
      # is too weak a signal — leave the compound name alone.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule StreamView do
          defp str_token(v), do: v

          def go(v), do: str_token(v)
        end
        '''
      )
    end

    test "the prefix-truncation name is stable across repeated runs" do
      # The loop in #15 is observable as a fixpoint failure: applying
      # the refactor must not keep flipping the name. Here the name is
      # already the author's deliberate form, so once == twice == the
      # original.
      assert_idempotent(
        @subject,
        ~S'''
        defmodule StreamView do
          defp str_token(v), do: v

          def go(v), do: str_token(v)
        end
        '''
      )
    end

    test "still expands genuine abbreviations that are not prefixes of the expansion" do
      # Guard against over-correcting: `cs` is NOT a prefix of
      # `changeset` (it drops internal letters), so the alias-driven
      # heuristic must still expand it. Only contiguous prefix-
      # truncations are treated as deliberate.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          alias Ecto.Changeset

          defp fetch_cs(arg), do: arg

          def go(x), do: fetch_cs(x)
        end
        ''',
        ~S'''
        defmodule M do
          alias Ecto.Changeset

          defp fetch_changeset(arg), do: arg

          def go(x), do: fetch_changeset(x)
        end
        '''
      )
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(
        @subject,
        ~S'''
        defmodule M do
          def public(x), do: fetch_kw(x)
          defp fetch_kw(arg), do: arg
        end
        ''',
        known: %{"kw" => "keyword"}
      )
    end

    test "HEEx renames are also idempotent" do
      assert_idempotent(
        @subject,
        ~S'''
        defmodule M do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <.dep_row :for={d <- @deps} dep={d} />
            <span>{dep_formula(@dep)}</span>
            """
          end

          defp dep_row(assigns), do: ~H""
          defp dep_formula(_), do: "?"
        end
        ''',
        known: %{"dep" => "dependency"}
      )
    end
  end
end
