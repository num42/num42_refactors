defmodule Number42.Refactors.Ex.ExtractMagicNumberTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractMagicNumber

  @subject ExtractMagicNumber

  # ExtractMagicNumber is default-OFF: transform/2 is a no-op unless its
  # own opts carry `enabled: true`. Every behaviour test below passes
  # `enabled: true` as the trailing opts so it exercises the enabled
  # refactor; the default-OFF gate has its own dedicated test.
  @on [enabled: true]

  describe "default-OFF (opt-in only)" do
    test "without enabled: true, transform is a no-op" do
      source = ~S'''
      defmodule M do
        def a, do: 3600
        def b, do: 3600
      end
      '''

      assert apply_refactor(@subject, source) == source
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
          @seconds_per_hour 3600
          def a, do: @seconds_per_hour
          def b, do: @seconds_per_hour
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
          @seconds_per_hour 3600
          @int_7200 7200
          def a, do: {@seconds_per_hour, @int_7200}
          def b, do: {@seconds_per_hour, @int_7200}
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
        [min_occurrences: 3] ++ @on
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
          @seconds_per_hour 3600
          def a, do: @seconds_per_hour
          def b, do: @seconds_per_hour
          def c, do: @seconds_per_hour
        end
        ''',
        [min_occurrences: 3] ++ @on
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
          @int_404 404
          def f(404), do: :not_found
          def g, do: @int_404
          def h, do: @int_404
        end
        ''',
        @on
      )
    end
  end

  describe "capture arity is not a data literal (Bug 1)" do
    test "a literal in the arity position of &fun/N is never hoisted" do
      # `&do_search_items/3` — the `3` is an arity, not data. Replacing it
      # with `@magic_number` yields `&do_search_items/@magic_number`, an
      # invalid capture. The arity literal must be neither candidate nor
      # counted, so the two body 3s alone fall below the threshold.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def s, do: [{:items, &do_search_items/3}, {:assets, &do_search_assets/3}]
        end
        ''',
        @on
      )
    end

    test "an arity literal does not pad the count of a same-valued data literal" do
      # Two arity `3`s plus one data `3`. If arities were counted the data
      # `3` would cross the threshold and hoist; excluded, the lone data
      # `3` stays below it.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def s, do: {&a/3, &b/3}
          def t, do: 3
        end
        ''',
        @on
      )
    end
  end

  describe "macro hygiene — quote bodies (Bug 2)" do
    test "a literal inside quote do ... end is never hoisted" do
      # A `@magic_number` hoisted from a quote-body would resolve at
      # expansion time in the *calling* module, where the attribute does
      # not exist → undefined module attribute. Literals under `quote`
      # are pruned entirely.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          defmacro __using__(_opts) do
            quote do
              def a, do: connect(timeout: 5000)
              def b, do: reconnect(timeout: 5000)
            end
          end
        end
        ''',
        @on
      )
    end
  end

  describe "call-context names (Aufgabe 4)" do
    test "derives a name from the surrounding call when no keyword key applies" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a(x), do: String.slice(x, 0, 200)
          def b(x), do: String.slice(x, 0, 200)
        end
        ''',
        ~S'''
        defmodule M do
          @max_slice 200
          def a(x), do: String.slice(x, 0, @max_slice)
          def b(x), do: String.slice(x, 0, @max_slice)
        end
        ''',
        @on
      )
    end
  end

  describe "blank line after attribute block (Aufgabe 5)" do
    test "a blank line separates the hoisted attribute from the first definition" do
      actual =
        ExtractMagicNumber.transform(
          ~S'''
          defmodule M do
            def a, do: 3600
            def b, do: 3600
          end
          ''',
          @on
        )

      assert actual =~ "@seconds_per_hour 3600\n\n  def a"
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
