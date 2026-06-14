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

    test "uses the key as the constant name when the literal sat at key: value" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: build(status: "active")
          def b, do: build(status: "active")
        end
        ''',
        ~S'''
        defmodule M do
          @status "active"
          def a, do: build(status: @status)
          def b, do: build(status: @status)
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
    test "default min_occurrences >= 2: a string used once is left alone" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: "connection refused"
        end
        ''',
        @on
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
      # Each module sees the string once → below threshold in both → no
      # hoist. Proves the per-module walk never counts across module
      # boundaries.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule A do
          def a, do: "connection refused"
        end

        defmodule B do
          def b, do: "connection refused"
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
          @status :existing
          def a, do: build(status: "active")
          def b, do: build(status: "active")
        end
        ''',
        ~S'''
        defmodule M do
          @status_2 "active"
          @status :existing
          def a, do: build(status: @status_2)
          def b, do: build(status: @status_2)
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
