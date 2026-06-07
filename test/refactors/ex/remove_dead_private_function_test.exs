defmodule Number42.Refactors.Ex.RemoveDeadPrivateFunctionTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.RemoveDeadPrivateFunction

  @subject RemoveDeadPrivateFunction

  # RemoveDeadPrivateFunction is opt-in / default-off. Every test that
  # exercises the rewrite passes `enabled: true`; a dedicated test asserts
  # the default-off behaviour.
  @on [enabled: true]

  describe "default-off" do
    test "without opt-in config the source is left untouched" do
      source = """
      defmodule M do
        def used, do: helper_a()
        defp helper_a, do: :ok
        defp helper_b, do: :never_called
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "rewrites — canonical dead-code elimination" do
    test "deletes a private function with no call site" do
      before_source = """
      defmodule M do
        def used, do: helper_a()
        defp helper_a, do: :ok
        defp helper_b, do: :never_called
      end
      """

      after_source = """
      defmodule M do
        def used, do: helper_a()
        defp helper_a, do: :ok
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "deletes the dead defp's attached @doc and @spec" do
      before_source = """
      defmodule M do
        def used, do: :ok

        @doc false
        @spec dead(integer()) :: integer()
        defp dead(x), do: x * 2
      end
      """

      after_source = """
      defmodule M do
        def used, do: :ok
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "deletes a whole transitive-dead cluster in one pass" do
      before_source = """
      defmodule M do
        def used, do: :ok
        defp dead_a, do: dead_b()
        defp dead_b, do: :unreachable
      end
      """

      after_source = """
      defmodule M do
        def used, do: :ok
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "deletes all clauses of a multi-clause dead defp" do
      before_source = """
      defmodule M do
        def used, do: :ok
        defp dead(:a), do: 1
        defp dead(:b), do: 2
      end
      """

      after_source = """
      defmodule M do
        def used, do: :ok
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end
  end

  describe "leaves live functions alone" do
    test "keeps a defp called directly" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used, do: helper()
          defp helper, do: :ok
        end
        """,
        @on
      )
    end

    test "keeps a defp referenced only via a capture &name/arity" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used, do: Enum.map([1, 2], &double/1)
          defp double(x), do: x * 2
        end
        """,
        @on
      )
    end

    test "keeps a defp reachable transitively from a public def" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used, do: mid()
          defp mid, do: leaf()
          defp leaf, do: :ok
        end
        """,
        @on
      )
    end

    # A defp with a default arg is callable at every arity from its
    # required count to its declared count. `build/2` calls it at /2;
    # the definition is /3. Reachability must register both arities, or
    # the live function is wrongly deleted (taking its recursive helper
    # with it) and the caller no longer compiles.
    test "keeps a defp called at a lower arity than declared (default arg)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def build(id, parent_map) do
            ancestry = build_ancestry(id, parent_map)
            ancestry ++ [id]
          end

          defp build_ancestry(id, parent_map, acc \\\\ []),
            do: parent_map |> Map.get(id) |> recurse_or_done(acc, parent_map)

          defp recurse_or_done(nil, acc, _parent_map), do: acc
          defp recurse_or_done(pid, acc, parent_map),
            do: build_ancestry(pid, parent_map, [pid | acc])
        end
        """,
        @on
      )
    end

    test "keeps a defp reached via __MODULE__.fn() inside a quote block" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used, do: :ok

          defmacro gen do
            quote do
              unquote(__MODULE__).runtime_helper()
            end
          end

          defp runtime_helper, do: :ok
        end
        """,
        @on
      )
    end

    test "keeps a defp reached via a fully-qualified self-call" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used, do: :ok
          def trampoline, do: M.target()
          defp target, do: :ok
        end
        """,
        @on
      )
    end

    test "keeps every defp when a quote block dispatches dynamically" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used, do: :ok

          defmacro gen(name) do
            quote do
              unquote(name)()
            end
          end

          defp maybe_target, do: :ok
        end
        """,
        @on
      )
    end

    test "keeps all defps when a dynamic apply is reachable" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used(name), do: apply(__MODULE__, name, [])
          defp maybe_target, do: :ok
        end
        """,
        @on
      )
    end

    test "leaves a public def alone even if uncalled (external contract)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def public_api, do: :ok
        end
        """,
        @on
      )
    end

    test "skips a module with no public def (roots unknown)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp only_private, do: :ok
        end
        """,
        @on
      )
    end
  end

  describe "idempotence" do
    test "stable after removing one dead function" do
      assert_idempotent(
        @subject,
        """
        defmodule M do
          def used, do: helper_a()
          defp helper_a, do: :ok
          defp helper_b, do: :dead
        end
        """,
        @on
      )
    end

    test "output still compiles" do
      source = """
      defmodule RemoveDeadPrivateFunctionCompileCheck do
        def used, do: helper()
        defp helper, do: :ok
        defp dead, do: :gone
      end
      """

      assert_compiles(apply_refactor(@subject, source, @on))
    end
  end
end
