defmodule Number42.Refactors.Ex.ExtractPipelineToFunctionTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractPipelineToFunction

  @subject ExtractPipelineToFunction

  # Default-OFF: transform/2 is a no-op unless its own opts carry
  # `enabled: true`. Behaviour tests pass `@on`; the default-OFF gate has
  # its own test.
  @on [enabled: true]

  describe "default-OFF (opt-in only)" do
    test "without enabled: true, transform is a no-op" do
      source = """
      defmodule M do
        def index(conn, params) do
          result =
            params
            |> Map.get("filters", %{})
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)
            |> Enum.into(%{})
            |> Map.put(:org, conn)
            |> Enum.map(&serialize/1)

          json(conn, result)
        end
      end
      """

      assert apply_refactor(@subject, source) == source
    end
  end

  describe "rewrites — bound pipeline with free vars" do
    test "extracts a long bound pipeline into a defp and threads its free vars" do
      before_source = """
      defmodule M do
        def index(conn, params) do
          result =
            params
            |> Map.get("filters", %{})
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)
            |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
            |> Enum.into(%{})
            |> Map.put(:org_id, conn.assigns.current_org.id)
            |> Repo.all()

          json(conn, result)
        end
      end
      """

      # Terminal call is Repo.all → verb `load`; head seed `params` is the
      # object → `load_params`. Free vars: `params` (seed, first) and
      # `conn` (closed over in the Map.put stage), in that order. The
      # lambda-bound `k`/`v`/`_k` are bound inside the chain, not params.
      after_source = """
      defmodule M do
        def index(conn, params) do
          result = load_params(params, conn)

          json(conn, result)
        end

        defp load_params(params, conn) do
          params
          |> Map.get("filters", %{})
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
          |> Enum.into(%{})
          |> Map.put(:org_id, conn.assigns.current_org.id)
          |> Repo.all()
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end
  end

  describe "rewrites — tail pipeline returned directly" do
    test "extracts a long pipeline that is the body's tail" do
      before_source = """
      defmodule M do
        def run(items, factor) do
          log(items)

          items
          |> Enum.map(fn i -> i * factor end)
          |> Enum.filter(fn i -> i > 0 end)
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.take(10)
        end
      end
      """

      # Terminal call `Enum.take` has no verb mapping; object `items`
      # alone would shadow the parameter — so naming falls back to the
      # host-derived `run_pipeline`. Free vars: `items` (seed) and
      # `factor` (closed over).
      after_source = """
      defmodule M do
        def run(items, factor) do
          log(items)

          run_pipeline(items, factor)
        end

        defp run_pipeline(items, factor) do
          items
          |> Enum.map(fn i -> i * factor end)
          |> Enum.filter(fn i -> i > 0 end)
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.take(10)
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end
  end

  describe "free variables — captures and closures" do
    test "a variable closed over inside a lambda stage becomes a parameter" do
      before_source = """
      defmodule M do
        def f(list, threshold) do
          scaled =
            list
            |> Enum.map(fn x -> x * 2 end)
            |> Enum.filter(fn x -> x > threshold end)
            |> Enum.uniq()
            |> Enum.sort()
            |> Enum.reverse()

          use_it(scaled)
        end
      end
      """

      after_source = """
      defmodule M do
        def f(list, threshold) do
          scaled = f_pipeline(list, threshold)

          use_it(scaled)
        end

        defp f_pipeline(list, threshold) do
          list
          |> Enum.map(fn x -> x * 2 end)
          |> Enum.filter(fn x -> x > threshold end)
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.reverse()
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end
  end

  describe "leaves alone" do
    test "skips a pipeline shorter than the threshold" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            y =
              x
              |> g()
              |> h()
              |> i()

            use_it(y)
          end
        end
        """,
        @on
      )
    end

    test "skips a long pipeline whose result is never used" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            dead =
              x
              |> a()
              |> b()
              |> c()
              |> d()
              |> e()

            other(x)
          end
        end
        """,
        @on
      )
    end

    test "skips when the host body is exactly the pipeline (self-extraction)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            x
            |> a()
            |> b()
            |> c()
            |> d()
            |> e()
          end
        end
        """,
        @on
      )
    end

    test "skips a pipeline with no in-scope free variable to seed it" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f do
            result =
              [1, 2, 3]
              |> Enum.map(&(&1 * 2))
              |> Enum.filter(&(&1 > 0))
              |> Enum.uniq()
              |> Enum.sort()
              |> Enum.reverse()

            use_it(result)
          end
        end
        """,
        @on
      )
    end

    test "skips a pipeline referencing a module attribute" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          @rate 2

          def f(x) do
            y =
              x
              |> a()
              |> Enum.map(&(&1 * @rate))
              |> c()
              |> d()
              |> e()

            use_it(y)
          end
        end
        """,
        @on
      )
    end

    test "skips a multi-clause host" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(%{a: a}) do
            y =
              a
              |> g()
              |> h()
              |> i()
              |> j()
              |> k()

            use_it(y)
          end

          def f(_), do: :default
        end
        """,
        @on
      )
    end
  end

  describe "helper naming — derived from terminal call" do
    test "Repo.all-terminated pipeline names the helper load_<seed>" do
      before_source = """
      defmodule M do
        def fetch(scope, query) do
          rows =
            query
            |> where_scope(scope)
            |> order_by_recent()
            |> limit(50)
            |> preload_assocs()
            |> Repo.all()

          render(rows)
        end
      end
      """

      after_source = """
      defmodule M do
        def fetch(scope, query) do
          rows = load_query(query, scope)

          render(rows)
        end

        defp load_query(query, scope) do
          query
          |> where_scope(scope)
          |> order_by_recent()
          |> limit(50)
          |> preload_assocs()
          |> Repo.all()
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end
  end

  describe "idempotence & compilation" do
    test "stable after one extraction" do
      assert_idempotent(
        @subject,
        """
        defmodule M do
          def index(conn, params) do
            result =
              params
              |> Map.get("filters", %{})
              |> Enum.reject(fn {_k, v} -> is_nil(v) end)
              |> Enum.into(%{})
              |> Map.put(:org, conn)
              |> Enum.map(&serialize/1)

            json(conn, result)
          end
        end
        """,
        @on
      )
    end

    test "output compiles with the threaded parameters" do
      source = """
      defmodule ExtractPipelineToFunctionCompileCheck do
        def run(items, factor) do
          log(items)

          items
          |> Enum.map(fn i -> i * factor end)
          |> Enum.filter(fn i -> i > 0 end)
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.take(10)
        end

        defp log(_), do: :ok
      end
      """

      assert_compiles(apply_refactor(@subject, source, @on))
    end
  end
end
