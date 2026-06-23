defmodule Number42.Refactors.Ex.CaseToFunctionClausesTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.CaseToFunctionClauses

  @subject CaseToFunctionClauses

  # The refactor is enabled by default and takes no opts; `@on` is the
  # empty opts list, passed where a test wants to be explicit about it.
  @on []

  describe "lifts" do
    test "canonical case-on-param → one clause per branch" do
      before_source = """
      defmodule M do
        def handle(msg) do
          case msg do
            {:ok, v} -> log(v)
            {:error, e} -> warn(e)
          end
        end
      end
      """

      expected = """
      defmodule M do
        def handle({:ok, v}), do: log(v)
        def handle({:error, e}), do: warn(e)
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
    end

    test "extra params repeated verbatim on each clause" do
      before_source = """
      defmodule M do
        def handle(msg, ctx) do
          case msg do
            {:ok, v} -> log(v, ctx)
            {:error, e} -> warn(e, ctx)
          end
        end
      end
      """

      expected = """
      defmodule M do
        def handle({:ok, v}, ctx), do: log(v, ctx)
        def handle({:error, e}, ctx), do: warn(e, ctx)
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
    end

    test "scrutinee is a later param, not the first" do
      before_source = """
      defmodule M do
        def handle(ctx, msg) do
          case msg do
            :a -> one(ctx)
            :b -> two(ctx)
          end
        end
      end
      """

      expected = """
      defmodule M do
        def handle(ctx, :a), do: one(ctx)
        def handle(ctx, :b), do: two(ctx)
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
    end

    test "branch guard carries over to the clause when-guard" do
      before_source = """
      defmodule M do
        def handle(msg) do
          case msg do
            n when is_integer(n) -> double(n)
            other -> keep(other)
          end
        end
      end
      """

      expected = """
      defmodule M do
        def handle(n) when is_integer(n), do: double(n)
        def handle(other), do: keep(other)
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
    end

    test "multi-expression branch body becomes a do/end clause" do
      before_source = """
      defmodule M do
        def handle(msg) do
          case msg do
            {:ok, v} ->
              x = prep(v)
              done(x)

            :error ->
              fail()
          end
        end
      end
      """

      expected = """
      defmodule M do
        def handle({:ok, v}) do
          x = prep(v)
          done(x)
        end

        def handle(:error), do: fail()
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
    end

    test "branch body still references the scrutinee → pattern rebinds it" do
      before_source = """
      defmodule M do
        def deliver(user, url) do
          case user do
            %User{confirmed_at: nil} -> confirm(user, url)
            _ -> magic(user, url)
          end
        end
      end
      """

      expected = """
      defmodule M do
        def deliver(%User{confirmed_at: nil} = user, url), do: confirm(user, url)
        def deliver(user, url), do: magic(user, url)
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
    end

    test "guard branch rebinds scrutinee when body still uses it" do
      before_source = """
      defmodule M do
        def classify(n) do
          case n do
            x when x > 0 -> {:pos, n}
            0 -> :zero
            _ -> {:neg, n}
          end
        end
      end
      """

      expected = """
      defmodule M do
        def classify(x = n) when x > 0, do: {:pos, n}
        def classify(0), do: :zero
        def classify(n), do: {:neg, n}
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
    end

    test "extra param unused in a branch is underscore-prefixed there" do
      before_source = """
      defmodule M do
        def route(kind, id) do
          case kind do
            :show -> path(id)
            _ -> "/"
          end
        end
      end
      """

      expected = """
      defmodule M do
        def route(:show, id), do: path(id)
        def route(_, _id), do: "/"
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
    end

    test "bare-var pattern matching the scrutinee name needs no rebind" do
      before_source = """
      defmodule M do
        def f(msg) do
          case msg do
            msg -> handle(msg)
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(msg), do: handle(msg)
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
    end

    test "defp is lifted too" do
      before_source = """
      defmodule M do
        defp handle(msg) do
          case msg do
            :a -> 1
            :b -> 2
          end
        end
      end
      """

      expected = """
      defmodule M do
        defp handle(:a), do: 1
        defp handle(:b), do: 2
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
    end
  end

  describe "skips" do
    test "scrutinee is a call, not a bare param" do
      source = """
      defmodule M do
        def handle(msg) do
          case transform(msg) do
            {:ok, v} -> log(v)
            {:error, e} -> warn(e)
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "prefix before the case (closure loss risk)" do
      source = """
      defmodule M do
        def handle(msg) do
          prepared = prep(msg)

          case msg do
            {:ok, v} -> log(v, prepared)
            {:error, e} -> warn(e, prepared)
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "sibling clauses at the same name/arity" do
      source = """
      defmodule M do
        def handle(:special), do: :s

        def handle(msg) do
          case msg do
            {:ok, v} -> log(v)
            _ -> :skip
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "defmacro is out of scope" do
      source = """
      defmodule M do
        defmacro handle(msg) do
          case msg do
            {:ok, v} -> log(v)
            {:error, e} -> warn(e)
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "head has a when-guard" do
      source = """
      defmodule M do
        def handle(msg) when is_tuple(msg) do
          case msg do
            {:ok, v} -> log(v)
            {:error, e} -> warn(e)
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "branch pattern contains a pin" do
      source = """
      defmodule M do
        def handle(msg) do
          expected = compute()

          case msg do
            ^expected -> :hit
            other -> keep(other)
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "branch pattern contains a pin (case is sole body)" do
      source = """
      defmodule M do
        def handle(msg, expected) do
          case msg do
            ^expected -> :hit
            other -> keep(other)
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "head param is a pattern, not a bare variable" do
      source = """
      defmodule M do
        def handle(%{msg: msg}, _ignored) do
          case msg do
            :a -> 1
            :b -> 2
          end
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "statement after the case" do
      source = """
      defmodule M do
        def handle(msg) do
          case msg do
            {:ok, v} -> log(v)
            {:error, e} -> warn(e)
          end

          :done
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end
  end

  describe "idempotent" do
    test "canonical lift stays stable" do
      source = """
      defmodule M do
        def handle(msg) do
          case msg do
            {:ok, v} -> log(v)
            {:error, e} -> warn(e)
          end
        end
      end
      """

      assert_idempotent(@subject, source, @on)
    end

    test "already-lifted code passes through unchanged" do
      source = """
      defmodule M do
        def handle({:ok, v}), do: log(v)
        def handle({:error, e}), do: warn(e)
      end
      """

      assert_idempotent(@subject, source, @on)
    end
  end

  describe "output compiles" do
    test "lifted clauses are valid Elixir" do
      before_source = """
      defmodule CompileCheckCaseToFn do
        def handle(msg, ctx) do
          case msg do
            {:ok, v} -> {:logged, v, ctx}
            {:error, e} -> {:warned, e, ctx}
            n when is_integer(n) -> {:num, n, ctx}
          end
        end
      end
      """

      out = apply_refactor(@subject, before_source, @on)

      assert_compiles(out)
    end

    test "branch bodies reusing the scrutinee still compile (binding rebind)" do
      before_source = """
      defmodule CompileCheckCaseToFnRebind do
        def deliver(user, url) do
          case user do
            %{confirmed_at: nil} -> {:confirm, user, url}
            _ -> {:magic, user, url}
          end
        end
      end
      """

      out = apply_refactor(@subject, before_source, @on)

      assert_compiles(out)
    end
  end
end
