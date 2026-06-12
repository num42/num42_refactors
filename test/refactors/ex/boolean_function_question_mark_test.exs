defmodule Number42.Refactors.Ex.BooleanFunctionQuestionMarkTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.BooleanFunctionQuestionMark

  @subject BooleanFunctionQuestionMark

  describe "rewrites" do
    test "appends ? to a boolean-returning defp and renames the call site" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(x) do
            if valid(x), do: :ok, else: :error
          end

          defp valid(x) do
            x > 0
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(x) do
            if valid?(x), do: :ok, else: :error
          end

          defp valid?(x) do
            x > 0
          end
        end
        '''
      )
    end

    test "boolean via and/or operators" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(x), do: ready(x)
          defp ready(x), do: x.loaded and x.ok
        end
        ''',
        ~S'''
        defmodule M do
          def go(x), do: ready?(x)
          defp ready?(x), do: x.loaded and x.ok
        end
        '''
      )
    end

    test "multi-clause defp where every clause is boolean" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(x), do: admin(x)
          defp admin(%{role: :admin}), do: true
          defp admin(_), do: false
        end
        ''',
        ~S'''
        defmodule M do
          def go(x), do: admin?(x)
          defp admin?(%{role: :admin}), do: true
          defp admin?(_), do: false
        end
        '''
      )
    end

    test "renames a &name/arity capture along with the definition" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(list), do: Enum.filter(list, &active/1)
          defp active(x), do: x.state == :on
        end
        ''',
        ~S'''
        defmodule M do
          def go(list), do: Enum.filter(list, &active?/1)
          defp active?(x), do: x.state == :on
        end
        '''
      )
    end

    test "renames pipe and multiple call sites" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def a(x), do: enabled(x)
          def b(x), do: x |> enabled()
          defp enabled(x), do: x != nil
        end
        ''',
        ~S'''
        defmodule M do
          def a(x), do: enabled?(x)
          def b(x), do: x |> enabled?()
          defp enabled?(x), do: x != nil
        end
        '''
      )
    end
  end

  describe "skip conditions" do
    test "public def is never renamed (cross-module callers)" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def valid(x), do: x > 0
      end
      ''')
    end

    test "non-boolean body is left alone" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(x), do: build(x)
        defp build(x), do: %{value: x}
      end
      ''')
    end

    test "name already ending in ? is left alone" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(x), do: valid?(x)
        defp valid?(x), do: x > 0
      end
      ''')
    end

    test "mixed clauses where one clause is non-boolean — skip" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(x), do: check(x)
        defp check(0), do: false
        defp check(x), do: x
      end
      ''')
    end

    test "rename collides with an existing function — skip" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(x), do: valid(x)
        defp valid(x), do: x > 0
        defp valid?(x), do: x > 1
      end
      ''')
    end

    test "dynamic dispatch present — skip (call sites not all visible)" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(name, x), do: apply(__MODULE__, name, [x])
        defp valid(x), do: x > 0
      end
      ''')
    end

    test "name ending in ! is left alone" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(x), do: valid!(x)
        defp valid!(x), do: x > 0
      end
      ''')
    end
  end

  describe "semantic predicate gate (name must read as a predicate)" do
    test "action name with a boolean body is not turned into a predicate" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(x), do: parse_boolean(x)
        defp parse_boolean("true"), do: true
        defp parse_boolean("false"), do: false
        defp parse_boolean(_), do: false
      end
      ''')
    end

    test "a compute-shaped action name stays put even with a boolean body" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(a, b), do: compute_type_mismatch(a, b)
        defp compute_type_mismatch(a, b), do: a != b
      end
      ''')
    end

    test "a state-adjective name the model knows is renamed" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(x), do: active(x)
          defp active(x), do: x > 0
        end
        ''',
        ~S'''
        defmodule M do
          def go(x), do: active?(x)
          defp active?(x), do: x > 0
        end
        '''
      )
    end

    test "unknown name (model none) falls back to the verb heuristic — action stem skips" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(x), do: render_active(x)
        defp render_active(x), do: x > 0
      end
      ''')
    end

    test "unknown name (model none) with no action stem is renamed" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(x), do: gt_zero(x)
          defp gt_zero(x), do: x > 0
        end
        ''',
        ~S'''
        defmodule M do
          def go(x), do: gt_zero?(x)
          defp gt_zero?(x), do: x > 0
        end
        '''
      )
    end
  end

  describe "side-effect gate (a predicate cannot mutate)" do
    test "a body whose non-tail statement is a side effect is skipped" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(x), do: valid(x)
        defp valid(x) do
          Repo.update!(x)
          x.amount > 0
        end
      end
      ''')
    end

    test "a body whose non-tail statements are pure bindings is allowed" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(x), do: valid(x)
          defp valid(x) do
            amount = x.amount
            amount > 0
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(x), do: valid?(x)
          defp valid?(x) do
            amount = x.amount
            amount > 0
          end
        end
        '''
      )
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, ~S'''
      defmodule M do
        def go(x), do: valid(x)
        defp valid(x), do: x > 0
      end
      ''')
    end

    test "conformant code (already ?) is stable" do
      assert_idempotent(@subject, ~S'''
      defmodule M do
        def go(x), do: valid?(x)
        defp valid?(x), do: x > 0
      end
      ''')
    end
  end
end
