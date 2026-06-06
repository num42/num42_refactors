defmodule Number42.Refactors.Ex.NegatedBooleanNameTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.NegatedBooleanName

  @subject NegatedBooleanName

  describe "rewrites" do
    test "not_valid binding becomes invalid via antonym map" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(cs) do
            not_valid = cs.errors != []
            not_valid
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(cs) do
            invalid = cs.errors != []
            invalid
          end
        end
        '''
      )
    end

    test "not_found binding becomes found via not_ strip" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(list) do
            not_found = list == []
            handle(not_found)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(list) do
            found = list == []
            handle(found)
          end
        end
        '''
      )
    end

    test "renames every reference of the binding in scope" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(x) do
            not_enabled = check(x)

            if not_enabled do
              log(not_enabled)
            end
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(x) do
            disabled = check(x)

            if disabled do
              log(disabled)
            end
          end
        end
        '''
      )
    end

    test "project known override wins" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(x) do
            not_ready = prepare(x)
            not_ready
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(x) do
            pending = prepare(x)
            pending
          end
        end
        ''',
        known: %{"not_ready" => "pending"}
      )
    end
  end

  describe "skip conditions" do
    test "non-negated binding name is left alone" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(x) do
          valid = check(x)
          valid
        end
      end
      ''')
    end

    test "rename collides with an existing binding in the same scope — skip" do
      # `not_valid` would become `invalid`, but `invalid` is already
      # bound in the same body. Renaming would merge two distinct
      # bindings; refuse.
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(cs) do
          invalid = other(cs)
          not_valid = cs.errors != []
          {invalid, not_valid}
        end
      end
      ''')
    end

    test "negate is a no-op (word maps to itself) — nothing to do" do
      # A binding whose negation equals the original is not negated.
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(x) do
          ready = prepare(x)
          ready
        end
      end
      ''')
    end

    test "function parameters are out of scope" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(not_valid), do: not_valid
      end
      ''')
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, ~S'''
      defmodule M do
        def go(cs) do
          not_valid = cs.errors != []
          not_valid
        end
      end
      ''')
    end

    test "negated names with no clean antonym are left stable" do
      assert_idempotent(@subject, ~S'''
      defmodule M do
        def go(x) do
          not_frobnicate = run(x)
          not_frobnicate
        end
      end
      ''')
    end
  end
end
