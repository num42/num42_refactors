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

  # #408: the predicate model's vocabulary covers state adjectives
  # (`valid`, `active`, `enabled`) but not the modal/possessive class, so
  # `has_role`/`can_edit`/`needs_review` all return `:unknown`. They were
  # reaching the right verdict only by falling through the action-verb
  # check — decided by exclusion rather than recognition. These names are
  # grammatically interrogative, which is a structural fact about the
  # prefix and holds for any stem, including domain nouns no embedding
  # table will contain.
  describe "modal-prefix predicate gate (#408)" do
    for prefix <- ~w(has can should must is needs owns supports) do
      test "#{prefix}_-prefixed boolean defp is renamed" do
        name = "#{unquote(prefix)}_widget"

        assert_rewrites(
          @subject,
          """
          defmodule M do
            def go(x), do: #{name}(x)
            defp #{name}(x), do: x > 0
          end
          """,
          """
          defmodule M do
            def go(x), do: #{name}?(x)
            defp #{name}?(x), do: x > 0
          end
          """
        )
      end
    end

    test "a domain noun stem the model cannot know is still renamed" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(u), do: has_oz_fragment(u)
          defp has_oz_fragment(u), do: u.oz != nil
        end
        ''',
        ~S'''
        defmodule M do
          def go(u), do: has_oz_fragment?(u)
          defp has_oz_fragment?(u), do: u.oz != nil
        end
        '''
      )
    end

    test "the prefix must be a whole leading segment, not a substring" do
      # `island` starts with "is" but not with "is_"; it carries no modal
      # sense, so the modal tier must not claim it. It still renames via
      # the verb-stem tier (no action stem) — the point is that tier 2
      # did not decide it.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(x), do: island(x)
          defp island(x), do: x > 0
        end
        ''',
        ~S'''
        defmodule M do
          def go(x), do: island?(x)
          defp island?(x), do: x > 0
        end
        '''
      )
    end

    test "a modal prefix does not override an action verdict from the model" do
      # The model decides tier 1; the modal tier only runs on `:unknown`.
      # A name the model calls an action must stay an action.
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(x), do: update_flag(x)
        defp update_flag(x), do: x > 0
      end
      ''')
    end

    # The cases below are where the modal tier and the verb-stem tier
    # genuinely *disagree* — an action stem behind an auxiliary prefix.
    # Without tier 2 the verb-stem check sees the `update`/`fetch` stem and
    # declines, so these are the tests that actually exercise the new rule.
    test "an auxiliary prefix wins over an action stem behind it" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(x), do: has_update_flag(x)
          defp has_update_flag(x), do: x > 0
        end
        ''',
        ~S'''
        defmodule M do
          def go(x), do: has_update_flag?(x)
          defp has_update_flag?(x), do: x > 0
        end
        '''
      )
    end

    test "a modal prefix does not rescue a stem the model itself calls an action" do
      # `needs_fetch_row` never reaches tier 2: the model recognises the
      # `fetch` token and returns `:action` at tier 1. That precedence is
      # deliberate — a statistical verdict on the stem outranks a
      # structural guess from the prefix, so the modal list can stay small
      # without having to enumerate every action stem it must not claim.
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(x), do: needs_fetch_row(x)
        defp needs_fetch_row(x), do: x > 0
      end
      ''')
    end

    test "an ordinary transitive verb prefix does NOT claim an action stem" do
      # `uses_`/`owns_`/`contains_` are verbs in their own right, so
      # `uses_fetch_row` reads as an action and must keep falling through
      # to the verb-stem tier, which declines it. This is the boundary of
      # the modal list — widening it to any predicate-ish prefix would
      # rename genuine actions.
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(x), do: uses_fetch_row(x)
        defp uses_fetch_row(x), do: x > 0
      end
      ''')
    end

    test "a modal-prefixed name with a non-boolean body is still skipped" do
      # The name gate is necessary, not sufficient — the body gate stands.
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(x), do: has_widget(x)
        defp has_widget(x), do: x.count
      end
      ''')
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
