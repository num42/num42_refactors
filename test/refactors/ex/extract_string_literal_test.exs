defmodule Number42.Refactors.Ex.ExtractStringLiteralTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractStringLiteral

  @subject ExtractStringLiteral

  # ExtractStringLiteral is default-OFF: transform/2 is a no-op unless its
  # own opts carry `enabled: true`. Behaviour tests pass `enabled: true`
  # as trailing opts; the default-OFF gate has its own dedicated test.
  @on [enabled: true]

  describe "default-OFF (opt-in only)" do
    test "without enabled: true, transform is a no-op" do
      source = ~S'''
      defmodule M do
        def a, do: "connection refused"
        def b, do: "connection refused"
      end
      '''

      assert apply_refactor(@subject, source) == source
    end
  end

  describe "rewrites" do
    test "hoists a repeated string literal into a content-named attribute" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: log("connection refused")
          def b, do: warn("connection refused")
        end
        ''',
        ~S'''
        defmodule M do
          @connection_refused "connection refused"
          def a, do: log(@connection_refused)
          def b, do: warn(@connection_refused)
        end
        ''',
        @on
      )
    end

    test "uses the key (enriched with a short value) when the literal sat at key: value" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: build(timeout_message: "active")
          def b, do: build(timeout_message: "active")
        end
        ''',
        ~S'''
        defmodule M do
          @timeout_message "active"
          def a, do: build(timeout_message: @timeout_message)
          def b, do: build(timeout_message: @timeout_message)
        end
        ''',
        @on
      )
    end

    test "thrice-repeated string hoists too" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: "pending review"
          def b, do: "pending review"
          def c, do: "pending review"
        end
        ''',
        ~S'''
        defmodule M do
          @pending_review "pending review"
          def a, do: @pending_review
          def b, do: @pending_review
          def c, do: @pending_review
        end
        ''',
        @on
      )
    end

    test "two distinct repeated strings get distinct names" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: {"first value", "second value"}
          def b, do: {"first value", "second value"}
        end
        ''',
        ~S'''
        defmodule M do
          @first_value "first value"
          @second_value "second value"
          def a, do: {@first_value, @second_value}
          def b, do: {@first_value, @second_value}
        end
        ''',
        @on
      )
    end
  end

  describe "thresholds" do
    test "an explicit min_occurrences overrides the per-role defaults" do
      # A plain call-arg defaults to min 1, but an explicit min_occurrences
      # of 2 raises every class — so a single use is left alone.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: render("connection refused")
        end
        ''',
        [min_occurrences: 2] ++ @on
      )
    end

    test "configurable: min_occurrences 3 leaves a twice-used string alone" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: "connection refused"
          def b, do: "connection refused"
        end
        ''',
        [min_occurrences: 3] ++ @on
      )
    end

    test "configurable: min_length floor leaves a short repeated string alone" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: "abcd"
          def b, do: "abcd"
        end
        ''',
        [min_length: 5] ++ @on
      )
    end
  end

  describe "context-dependent default thresholds" do
    test "a plain call-arg string hoists at one occurrence" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: render_status("pending review")
        end
        ''',
        ~S'''
        defmodule M do
          @pending_review "pending review"
          def a, do: render_status(@pending_review)
        end
        ''',
        @on
      )
    end

    test "a keyword-arg value needs two occurrences" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: to_form(%{}, as: "collection_form")
        end
        ''',
        @on
      )
    end

    test "a log-call string needs two occurrences" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: Logger.info("starting up sequence")
        end
        ''',
        @on
      )
    end

    test "a dbg-call string needs two occurrences" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: dbg("trace marker here")
        end
        ''',
        @on
      )
    end
  end

  describe "naming: enriched names over content slugify" do
    test "a generic key plus a short identifier value combine" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: to_form(%{}, as: "collection")
          def b, do: to_form(%{}, as: "collection")
        end
        ''',
        ~S'''
        defmodule M do
          @as_collection "collection"
          def a, do: to_form(%{}, as: @as_collection)
          def b, do: to_form(%{}, as: @as_collection)
        end
        ''',
        @on
      )
    end

    test "a sentence is named by its first content words, stopwords filtered" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: err("Your account has not been unlocked yet")
          def b, do: err("Your account has not been unlocked yet")
        end
        ''',
        ~S'''
        defmodule M do
          @account_not_unlocked_yet "Your account has not been unlocked yet"
          def a, do: err(@account_not_unlocked_yet)
          def b, do: err(@account_not_unlocked_yet)
        end
        ''',
        @on
      )
    end

    test "a punctuation-heavy string (SQL fragment) is left inline" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: fragment("COALESCE(? || '.', '') || ?", x, y)
          def b, do: fragment("COALESCE(? || '.', '') || ?", x, y)
        end
        ''',
        @on
      )
    end

    test "a string naming a special module attribute is left inline" do
      # `"type"` would name `@type`, which Elixir reads as a typespec —
      # `@type "type"` fails to compile. Special attributes (type, spec,
      # behaviour, impl, …) are off-limits as generated names.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: field("type")
          def b, do: field("type")
        end
        ''',
        @on
      )
    end

    test "a reserved-word content string is left inline (illegal attribute name)" do
      # `"true"` would name `@true`, but `true` is a reserved word and
      # `@true` does not compile. No valid stem → leave it inline.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: flag("true")
          def b, do: flag("true")
        end
        ''',
        @on
      )
    end

    test "a digit-leading content string is left inline (illegal attribute stem)" do
      # `"24h"` would slugify to `24h`, but `@24h` is not a valid attribute
      # name (identifiers can't start with a digit) and would crash the
      # formatter. With no leading-letter stem available, leave it inline.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: label("24h")
          def b, do: label("24h")
        end
        ''',
        @on
      )
    end

    test "a value whose stem starts with digits drops the leading digits when a letter follows" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: tag("3 day window")
          def b, do: tag("3 day window")
        end
        ''',
        ~S'''
        defmodule M do
          @day_window "3 day window"
          def a, do: tag(@day_window)
          def b, do: tag(@day_window)
        end
        ''',
        @on
      )
    end
  end

  describe "compile-time macro arguments" do
    test "string options to `use` are never hoisted" do
      # `use Foo, token: "X"` is a compile-time macro call; the option is
      # passed to `__using__/1` as raw AST. Replacing it with `@token`
      # hands the macro `{:@, …}` instead of the string and breaks compile
      # (`String.Chars not implemented for Tuple`).
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          use SomeProvider, api_token_env: "OPENAI_API_TOKEN"
          use OtherProvider, api_token_env: "OPENAI_API_TOKEN"
        end
        ''',
        @on
      )
    end
  end

  describe "Ecto query macros" do
    test "string literals inside a from/1 query are never hoisted" do
      # Ecto query macros (`ago`, `fragment`, `field`, `type`) evaluate
      # their string arguments at compile time; a `@attr` there is not a
      # literal and breaks compilation (`invalid interval: @day`). The whole
      # query subtree is off-limits, like a quote body.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a do
            from(t in "tokens", where: t.at > ago(7, "day"))
          end

          def b do
            from(t in "tokens", where: t.at > ago(30, "day"))
          end
        end
        ''',
        @on
      )
    end
  end

  describe "skip conditions" do
    test "trivial strings (empty, blank, single-char) are never hoisted" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: {"", " ", "x"}
          def b, do: {"", " ", "x"}
        end
        ''',
        @on
      )
    end

    test "interpolated strings are not plain literals — never hoisted" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a(x), do: "user #{x} active"
          def b(x), do: "user #{x} active"
        end
        ''',
        @on
      )
    end

    test "@moduledoc and @doc heredocs are documentation, not data" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          @moduledoc "the shared documentation string"
          @doc "the shared documentation string"
          def a, do: :ok
        end
        ''',
        @on
      )
    end

    test "strings already living in a module attribute are not re-hoisted" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          @status "active"
          def a, do: @status
          def b, do: @status
        end
        ''',
        @on
      )
    end

    test "no defmodule wrapper — nothing to do" do
      assert_unchanged(
        @subject,
        ~S'''
        def a, do: "connection refused"
        def b, do: "connection refused"
        ''',
        @on
      )
    end

    test "strings in pattern positions are never hoisted (module attr illegal in a pattern)" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def f("connection refused"), do: :a
          def f(_), do: :b
        end
        ''',
        @on
      )
    end

    test "body occurrences hoist while a same-valued pattern literal stays inline" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def f("connection refused"), do: :matched
          def g, do: "connection refused"
          def h, do: "connection refused"
        end
        ''',
        ~S'''
        defmodule M do
          @connection_refused "connection refused"
          def f("connection refused"), do: :matched
          def g, do: @connection_refused
          def h, do: @connection_refused
        end
        ''',
        @on
      )
    end
  end

  describe "macro hygiene — quote bodies" do
    test "a literal inside quote do ... end is never hoisted" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          defmacro __using__(_opts) do
            quote do
              def a, do: log("connection refused")
              def b, do: warn("connection refused")
            end
          end
        end
        ''',
        @on
      )
    end
  end

  describe "cross-module isolation" do
    test "a string shared across two modules in one file is not merged" do
      # The string is a keyword value (per-role threshold 2) seen once in
      # each module → below threshold in both → no hoist. Proves the
      # per-module walk never counts across module boundaries.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule A do
          def a, do: form(label: "connection refused")
        end

        defmodule B do
          def b, do: form(label: "connection refused")
        end
        ''',
        @on
      )
    end

    test "each module hoists its own repeated string independently" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule A do
          def a, do: "connection refused"
          def b, do: "connection refused"
        end

        defmodule B do
          def c, do: "timed out badly"
          def d, do: "timed out badly"
        end
        ''',
        ~S'''
        defmodule A do
          @connection_refused "connection refused"
          def a, do: @connection_refused
          def b, do: @connection_refused
        end

        defmodule B do
          @timed_out_badly "timed out badly"
          def c, do: @timed_out_badly
          def d, do: @timed_out_badly
        end
        ''',
        @on
      )
    end
  end

  describe "name collisions" do
    test "a derived name colliding with an existing attribute is suffixed" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          @pending_review :existing
          def a, do: render("pending review")
          def b, do: render("pending review")
        end
        ''',
        ~S'''
        defmodule M do
          @pending_review_2 "pending review"
          @pending_review :existing
          def a, do: render(@pending_review_2)
          def b, do: render(@pending_review_2)
        end
        ''',
        @on
      )
    end
  end

  describe "structural validity" do
    test "hoisted output compiles" do
      actual =
        apply_refactor(
          @subject,
          ~S'''
          defmodule CompilesM do
            def a, do: log("connection refused")
            def b, do: warn("connection refused")

            defp log(x), do: x
            defp warn(x), do: x
          end
          ''',
          @on
        )

      assert_compiles(actual)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(
        @subject,
        ~S'''
        defmodule M do
          def a, do: log("connection refused")
          def b, do: warn("connection refused")
        end
        ''',
        @on
      )
    end

    test "key-named hoist is idempotent" do
      assert_idempotent(
        @subject,
        ~S'''
        defmodule M do
          def a, do: build(status: "active")
          def b, do: build(status: "active")
        end
        ''',
        @on
      )
    end
  end
end
