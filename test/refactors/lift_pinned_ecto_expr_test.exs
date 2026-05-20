defmodule Num42.Refactors.Refactors.LiftPinnedEctoExprTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.LiftPinnedEctoExpr

  @subject LiftPinnedEctoExpr

  describe "rewrites" do
    test "lifts ^Enum.map(...) inside from/where to a binding above" do
      before_source = """
      defmodule M do
        def expire(tokens_to_expire) do
          Repo.delete_all(
            from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id))
          )
        end
      end
      """

      expected = """
      defmodule M do
        def expire(tokens_to_expire) do
          map_tokens_to_expire_binding = Enum.map(tokens_to_expire, & &1.id)

          Repo.delete_all(
            from(t in UserToken, where: t.id in ^map_tokens_to_expire_binding)
          )
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "inserts binding into innermost containing block, not at fn-top" do
      before_source = """
      defmodule M do
        defp run(changeset) do
          Repo.transact(fn ->
            with {:ok, user} <- Repo.update(changeset) do
              tokens = Repo.all_by(UserToken, user_id: user.id)

              Repo.delete_all(
                from(t in UserToken, where: t.id in ^Enum.map(tokens, & &1.id))
              )

              {:ok, user}
            end
          end)
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      # Binding sits inside the with-do-block (after `tokens = …`), not
      # outside `Repo.transact` where `tokens` is not yet bound.
      assert String.contains?(actual, "tokens = Repo.all_by(UserToken, user_id: user.id)")

      assert String.contains?(
               actual,
               "map_tokens_binding = Enum.map(tokens, & &1.id)"
             )

      assert String.contains?(actual, "in ^map_tokens_binding")
      assert {:ok, _} = Code.string_to_quoted(actual)
    end

    test "lifts ^@module_attr" do
      before_source = """
      defmodule M do
        @demo_items [%{name: "a"}, %{name: "b"}]

        def existing do
          Repo.all(from i in Item, where: i.name in ^Enum.map(@demo_items, & &1.name))
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert String.contains?(actual, "map_binding = Enum.map(@demo_items, & &1.name)")
      assert String.contains?(actual, "in ^map_binding)")
    end

    test "lifts pin inside a piped where(...) call" do
      before_source = """
      defmodule M do
        def filtered(rows) do
          Item
          |> where([i], i.id in ^Enum.map(rows, & &1.item_id))
          |> Repo.all()
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      assert String.contains?(actual, "map_rows_binding = Enum.map(rows, & &1.item_id)")
      assert String.contains?(actual, "in ^map_rows_binding)")
      # Pipe shape is preserved.
      assert String.contains?(actual, "Item")
      assert String.contains?(actual, "|> where")
      assert String.contains?(actual, "|> Repo.all()")
    end

    test "binding name uses callee + first var arg" do
      before_source = """
      defmodule M do
        def f(opts) do
          Repo.all(from u in User, where: u.id in ^do_something(opts))
        end
      end
      """

      actual = apply_refactor(@subject, before_source)
      assert String.contains?(actual, "do_something_opts_binding = do_something(opts)")
      assert String.contains?(actual, "in ^do_something_opts_binding")
    end
  end

  describe "with-clauses" do
    test "lifts pin in with-clause RHS as a `name = expr` clause before it" do
      before_source = """
      defmodule M do
        def expire_for(user, token) do
          with {:ok, ctx} <- verify(token),
               {_count, _result} <-
                 Repo.delete_all(
                   from(t in UserToken, where: t.id in ^Enum.map(ctx.tokens, & &1.id))
                 ) do
            {:ok, user}
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      # Binding sits *inside* the `with` as a `name = expr,` clause
      # before the clause that uses it — so `ctx` is in scope.
      assert {:ok, _} = Code.string_to_quoted(actual)
      assert String.contains?(actual, "map_binding = Enum.map(ctx.tokens, & &1.id),")
      assert String.contains?(actual, "in ^map_binding")
      # The binding is NOT outside the `with`.
      refute String.match?(actual, ~r/map_binding\s*=.*\n\s*with/s)
    end
  end

  describe "DSL macros (describe/test/setup)" do
    test "inserts binding inside the `test` block, not at module top" do
      before_source = """
      defmodule MyTest do
        use ExUnit.Case

        describe "stuff" do
          test "queries by id" do
            user = insert!(:user)
            row = Repo.one(from u in User, where: u.id == ^get_id(user))
          end
        end
      end
      """

      actual = apply_refactor(@subject, before_source)

      # The binding sits *inside* the test-do-block, after `user = insert!(...)`,
      # not at the module top where `user` isn't defined yet.
      assert {:ok, _} = Code.string_to_quoted(actual)
      assert String.contains?(actual, "user = insert!(:user)")
      assert String.contains?(actual, "get_id_user_binding = get_id(user)")
      assert String.contains?(actual, "where: u.id == ^get_id_user_binding")
      refute String.match?(actual, ~r/get_id_user_binding\s*=.*\n.*describe/s)
    end
  end

  describe "no-op" do
    test "leaves bare-var pins alone" do
      source = """
      defmodule M do
        def get(id) do
          Repo.one(from(u in User, where: u.id == ^id))
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves pattern-match pin in case alone" do
      source = """
      defmodule M do
        def f(x, expected) do
          case x do
            {:ok, ^expected} -> :match
            _ -> :no
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves pinned dotted access alone (^x.y)" do
      source = """
      defmodule M do
        def fetch(token) do
          Repo.one(from u in User, where: u.id == ^token.user_id)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves pinned chained dotted access alone (^x.y.z)" do
      source = """
      defmodule M do
        def fetch(token) do
          Repo.one(from u in User, where: u.id == ^token.relation.user_id)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves pinned @attr alone" do
      source = """
      defmodule M do
        @demo_id "abc"

        def fetch do
          Repo.one(from u in User, where: u.id == ^@demo_id)
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves pinned literal alone" do
      source = """
      defmodule M do
        def fetch do
          Repo.one(from u in User, where: u.role == ^"admin")
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves pinned interpolated string alone (parses as <<>>)" do
      source = """
      defmodule M do
        def fetch(key) do
          Repo.exists?(from m in Mass, where: fragment("formula::text LIKE ?", ^"%\\"#{"\#{key}"}\\"%"))
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves pinned `||` operator alone (synthesised name would be invalid)" do
      # `^(default_id || fallback_id)` parses as `{:^, _, [{:||, _, [...]}]}`.
      # Lifting it into a binding produces `||_default_id_binding = ...`,
      # which is not a valid Elixir identifier — `||` is an operator,
      # not part of any allowable variable name. Conservative skip.
      source = """
      defmodule M do
        def fetch(default_id, fallback_id) do
          Repo.one(from(u in User, where: u.id == ^(default_id || fallback_id)))
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves pinned `&&` operator alone" do
      source = """
      defmodule M do
        def fetch(a, b) do
          Repo.one(from(u in User, where: u.flag == ^(a && b)))
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves pinned `++` operator alone" do
      source = """
      defmodule M do
        def fetch(xs, ys) do
          Repo.all(from(u in User, where: u.id in ^(xs ++ ys)))
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves pin in non-Ecto code alone (e.g. quote)" do
      source = """
      defmodule M do
        def gen(thing) do
          quote do
            unquote(^thing)
          end
        end
      end
      """

      # Note: ^thing inside quote is not in our Ecto-macro list, so we
      # don't touch it.
      assert_unchanged(@subject, source)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      source = """
      defmodule M do
        def expire(tokens_to_expire) do
          Repo.delete_all(
            from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id))
          )
        end
      end
      """

      assert_idempotent(@subject, source)
    end
  end
end
