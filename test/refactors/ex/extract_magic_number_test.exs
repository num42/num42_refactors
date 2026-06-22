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
          def a, do: 1024
          def b, do: 1024
        end
        ''',
        ~S'''
        defmodule M do
          @kibi 1024
          def a, do: @kibi
          def b, do: @kibi
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

    test "enriches a generic key with the literal param and the call's noun" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def f(cs), do: validate_length(cs, :email, max: 160)
          def g(cs), do: validate_length(cs, :email, max: 160)
        end
        ''',
        ~S'''
        defmodule M do
          @email_max_length 160
          def f(cs), do: validate_length(cs, :email, max: @email_max_length)
          def g(cs), do: validate_length(cs, :email, max: @email_max_length)
        end
        ''',
        @on
      )
    end

    test "a punctuation delimiter param does not leak into the name" do
      # `String.split(entry, ":", parts: 4)` — the `":"` is a delimiter,
      # not a subject. It must not become part of the attribute name (a
      # raw `:` would yield the uncompilable `@:_parts`). With no usable
      # param the key stands alone, enriched only by the call noun if any.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a(e), do: String.split(e, ":", parts: 4)
          def b(e), do: String.split(e, ":", parts: 4)
        end
        ''',
        ~S'''
        defmodule M do
          @parts 4
          def a(e), do: String.split(e, ":", parts: @parts)
          def b(e), do: String.split(e, ":", parts: @parts)
        end
        ''',
        @on
      )
    end

    test "falls back to the enclosing function name when the call has no literal param" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def show(js), do: JS.show(js, time: 300)
          def hide(js), do: JS.hide(js, time: 200)
        end
        ''',
        ~S'''
        defmodule M do
          @show_time 300
          @hide_time 200
          def show(js), do: JS.show(js, time: @show_time)
          def hide(js), do: JS.hide(js, time: @hide_time)
        end
        ''',
        min_occurrences: 1,
        enabled: true
      )
    end

    test "deduplicates repeated tokens across param, key and call noun" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def f, do: set_size(:size, size: 12)
          def g, do: set_size(:size, size: 12)
        end
        ''',
        ~S'''
        defmodule M do
          @size 12
          def f, do: set_size(:size, size: @size)
          def g, do: set_size(:size, size: @size)
        end
        ''',
        @on
      )
    end

    test "hoists a repeated float literal when its key gives it a name" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: at(rate: 19.99)
          def b, do: at(rate: 19.99)
        end
        ''',
        ~S'''
        defmodule M do
          @rate 19.99
          def a, do: at(rate: @rate)
          def b, do: at(rate: @rate)
        end
        ''',
        @on
      )
    end

    test "two distinct repeated values: only the nameable one is hoisted" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: {1024, 7200}
          def b, do: {1024, 7200}
        end
        ''',
        ~S'''
        defmodule M do
          @kibi 1024
          def a, do: {@kibi, 7200}
          def b, do: {@kibi, 7200}
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
          def a, do: 1024
          def b, do: 1024
          def c, do: 1024
        end
        ''',
        ~S'''
        defmodule M do
          @kibi 1024
          def a, do: @kibi
          def b, do: @kibi
          def c, do: @kibi
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

    test "literals inside an arithmetic module-attribute body are not counted or rewritten" do
      # `@one_mb 1024 * 1024` is already a named constant; its body
      # literals must never be hoisted (that would yield `@kibi * @kibi`,
      # indirection over an already-named value) nor counted toward the
      # threshold. Here the only `1024`s are inside the attribute body, so
      # nothing crosses the threshold and the source is untouched.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          @one_mb 1024 * 1024
          def size, do: @one_mb
        end
        ''',
        @on
      )
    end

    test "the attribute body is left intact even when the same value is hoisted elsewhere" do
      # The free `1024`s in the def body are genuine magic numbers (twice,
      # universal `@kibi`) and may hoist — but the `@one_mb` body keeps its
      # literal `1024 * 1024`; it is never rewritten to `@kibi * @kibi`.
      actual =
        ExtractMagicNumber.transform(
          ~S'''
          defmodule M do
            @one_mb 1024 * 1024
            def chunk, do: stream(buffer_size: 1024 * 1024)
          end
          ''',
          @on
        )

      assert actual =~ "@one_mb 1024 * 1024"
      refute actual =~ "@one_mb @kibi"
    end

    test "literals inside a module-attribute lookup map are not hoisted" do
      # `@gap_map %{4 => "gap-4", ...}` is a closed lookup table. Replacing
      # an entry key with `@default` mixes a symbolic key into a literal
      # map. The map's literals are excluded; the lone remaining body
      # occurrence is below threshold → unchanged.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          @gap_map %{0 => "gap-0", 4 => "gap-4", 5 => "gap-5"}
          def class(g), do: Map.get(@gap_map, 4)
        end
        ''',
        @on
      )
    end

    test "no defmodule wrapper — nothing to do" do
      assert_unchanged(@subject, "def a, do: 3600\ndef b, do: 3600", @on)
    end

    test "component attr/slot defaults are declarations, not hoisted" do
      # `attr :gap, default: 4` declares a component's default; it reads as
      # a spec, not a repeated magic value. Its literal is excluded even
      # when two declarations share a value (and would otherwise collide on
      # one enriched name), so nothing is hoisted.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          attr :gap, :integer, default: 4
          attr :gap, :integer, default: 4
          slot :inner, default: 4
          def render(assigns), do: assigns
        end
        ''',
        @on
      )
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
          def f(1024), do: :match
          def g, do: at(1024)
          def h, do: at(1024)
        end
        ''',
        ~S'''
        defmodule M do
          @kibi 1024
          def f(1024), do: :match
          def g, do: at(@kibi)
          def h, do: at(@kibi)
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

  describe "import/alias/require directives are never touched" do
    test "an arity in an `import only:` list is never hoisted" do
      # `import M, only: [foo: 4]` — the `4` is a function arity, not data.
      # Replacing it with `@attr` yields `only: [foo: @attr]`, which is not
      # a valid directive. Directive literals are neither candidate nor
      # counted, so the body `4`s alone fall below the threshold.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          import Other, only: [foo: 4]
          def a, do: at(4)
          def b, do: at(4)
        end
        ''',
        @on
      )
    end

    test "arities across import and except do not pad a data literal's count" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          import A, only: [f: 4]
          import B, except: [g: 4]
          def a, do: at(4)
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

  describe "ambiguous cross-context values are left inline" do
    test "a value carrying two distinct keyword keys is not hoisted" do
      # `5` is a batch size at one site (`batch_size: 5`) and a concurrency
      # cap at another (`max_concurrency: 5`). They share a value by
      # coincidence, not meaning — fusing them into one `@attr` would stamp
      # one site's name onto the other. Divergent naming signals → inline.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def run, do: async(batch_size: 5)
          def cap, do: limit(max_concurrency: 5)
        end
        ''',
        @on
      )
    end

    test "a value with one consistent key across sites is still hoisted" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: connect(retries: 240)
          def b, do: reconnect(retries: 240)
        end
        ''',
        ~S'''
        defmodule M do
          @retries 240
          def a, do: connect(retries: @retries)
          def b, do: reconnect(retries: @retries)
        end
        ''',
        @on
      )
    end
  end

  describe "clause-head names" do
    test "derives a name from the function clause and its string pattern" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def image_width("md"), do: 80
          def image_width(_), do: 80
        end
        ''',
        ~S'''
        defmodule M do
          @image_width_md 80
          def image_width("md"), do: @image_width_md
          def image_width(_), do: @image_width_md
        end
        ''',
        @on
      )
    end

    test "derives a name from the function clause and its atom pattern" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def icon_size(:large), do: 96
          def icon_size(_), do: 96
        end
        ''',
        ~S'''
        defmodule M do
          @icon_size_large 96
          def icon_size(:large), do: @icon_size_large
          def icon_size(_), do: @icon_size_large
        end
        ''',
        @on
      )
    end

    test "a nil pattern names the constant, a wildcard names the default" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def quality_total_count(nil), do: 3
          def quality_total_count(_), do: 5
        end
        ''',
        ~S'''
        defmodule M do
          @quality_total_count_nil 3
          @quality_total_count_default 5
          def quality_total_count(nil), do: @quality_total_count_nil
          def quality_total_count(_), do: @quality_total_count_default
        end
        ''',
        min_occurrences: 1,
        enabled: true
      )
    end

    test "a keyword key still beats the clause head" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def gap("md"), do: [size: 80]
          def gap(_), do: [size: 80]
        end
        ''',
        ~S'''
        defmodule M do
          @size 80
          def gap("md"), do: [size: @size]
          def gap(_), do: [size: @size]
        end
        ''',
        @on
      )
    end
  end

  describe "value-only fallback is left inline" do
    test "a repeated literal with no derivable name is not hoisted" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def a, do: foo(240)
          def b, do: bar(240)
        end
        ''',
        @on
      )
    end

    test "a derivable literal in the same module is still hoisted" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a, do: foo(240) + 1024
          def b, do: bar(240) + 1024
        end
        ''',
        ~S'''
        defmodule M do
          @kibi 1024
          def a, do: foo(240) + @kibi
          def b, do: bar(240) + @kibi
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
            def a, do: 1024
            def b, do: 1024
          end
          ''',
          @on
        )

      assert actual =~ "@kibi 1024\n\n  def a"
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
