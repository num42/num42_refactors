defmodule Number42.Refactors.Ex.ExtractMagicNumberTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractMagicNumber

  @subject ExtractMagicNumber

  # ExtractMagicNumber is opt-in / default-off. Every test that exercises
  # the rewrite passes `enabled: true`; a dedicated test asserts the
  # default-off behaviour.
  @on [enabled: true]

  describe "default-off" do
    test "without opt-in config the source is left untouched" do
      source = ~S'''
      defmodule M do
        def a, do: 3600
        def b, do: 3600
      end
      '''

      assert_unchanged(@subject, source)
    end
  end

  describe "rewrites" do
    test "hoists a repeated integer literal into a module attribute" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: 3600
          def b, do: 3600
        end
        ''',
        ~S'''
        defmodule M do
          @magic_number 3600
          def a, do: @magic_number
          def b, do: @magic_number
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
          def a, do: connect(timeout: 5000)
          def b, do: reconnect(timeout: 5000)
        end
        ''',
        ~S'''
        defmodule M do
          @timeout 5000
          def a, do: connect(timeout: @timeout)
          def b, do: reconnect(timeout: @timeout)
        end
        ''',
        @on
      )
    end

    test "hoists a repeated float literal" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: 19.99
          def b, do: 19.99
        end
        ''',
        ~S'''
        defmodule M do
          @default_float 19.99
          def a, do: @default_float
          def b, do: @default_float
        end
        ''',
        @on
      )
    end

    test "two distinct repeated values get distinct names" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: {3600, 7200}
          def b, do: {3600, 7200}
        end
        ''',
        ~S'''
        defmodule M do
          @magic_number 3600
          @magic_number_2 7200
          def a, do: {@magic_number, @magic_number_2}
          def b, do: {@magic_number, @magic_number_2}
        end
        ''',
        @on
      )
    end
  end

  describe "min_occurrences" do
    test "default >= 2: a value occurring once is left alone" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: 3600
        end
        ''',
        @on
      )
    end

    test "configurable: min_occurrences 3 leaves a twice-used value alone" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: 3600
          def b, do: 3600
        end
        ''',
        @on ++ [min_occurrences: 3]
      )
    end

    test "configurable: min_occurrences 3 hoists a thrice-used value" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: 3600
          def b, do: 3600
          def c, do: 3600
        end
        ''',
        ~S'''
        defmodule M do
          @magic_number 3600
          def a, do: @magic_number
          def b, do: @magic_number
          def c, do: @magic_number
        end
        ''',
        @on ++ [min_occurrences: 3]
      )
    end
  end

  describe "skip conditions" do
    test "idiomatic numbers are never hoisted" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: {0, 1, 2, 0.0, 1.0, 0.5}
          def b, do: {0, 1, 2, 0.0, 1.0, 0.5}
        end
        ''',
        @on
      )
    end

    test "literals already living in a module attribute are not re-hoisted" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          @timeout 5000
          def a, do: @timeout
          def b, do: @timeout
        end
        ''',
        @on
      )
    end

    test "no defmodule wrapper — nothing to do" do
      assert_unchanged(@subject, "def a, do: 3600\ndef b, do: 3600", @on)
    end

    test "literals in pattern positions are never hoisted (module attr is illegal in a pattern)" do
      # `def f(404)` and `x = 404` are match patterns; a module attribute
      # cannot appear there. Pattern literals are excluded from both the
      # candidate set and the occurrence count, so only the body
      # occurrences below the threshold remain → nothing hoisted.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def f(404), do: :a
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
          def f(404), do: :not_found
          def g, do: 404
          def h, do: 404
        end
        ''',
        ~S'''
        defmodule M do
          @magic_number 404
          def f(404), do: :not_found
          def g, do: @magic_number
          def h, do: @magic_number
        end
        ''',
        @on
      )
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(
        @subject,
        ~S'''
        defmodule M do
          def a, do: 3600
          def b, do: 3600
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
          def a, do: connect(timeout: 5000)
          def b, do: reconnect(timeout: 5000)
        end
        ''',
        @on
      )
    end
  end
end
