defmodule Number42.Refactors.Ex.FlattenDeepPipeBranchTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.FlattenDeepPipeBranch

  @subject FlattenDeepPipeBranch

  describe "shared prefix and suffix factoring" do
    test "hoists shared head and tail stages around a branched middle defp" do
      before_source = """
      defmodule M do
        def run(x) do
          case x do
            :a -> x |> prep() |> step_a() |> finalize()
            :b -> x |> prep() |> step_b() |> finalize()
          end
        end
      end
      """

      expected = """
      defmodule M do
        def run(x) do
          x
          |> prep()
          |> run_branch(x)
          |> finalize()
        end

        defp run_branch(piped, :a), do: piped |> step_a()
        defp run_branch(piped, :b), do: piped |> step_b()
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "factors a multi-stage divergent middle" do
      before_source = """
      defmodule M do
        def run(mode) do
          case mode do
            :fast -> mode |> load() |> quick() |> trim() |> save()
            :slow -> mode |> load() |> deep() |> verify() |> save()
          end
        end
      end
      """

      expected = """
      defmodule M do
        def run(mode) do
          mode
          |> load()
          |> run_branch(mode)
          |> save()
        end

        defp run_branch(piped, :fast), do: piped |> quick() |> trim()
        defp run_branch(piped, :slow), do: piped |> deep() |> verify()
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "idempotence" do
    test "applying twice equals applying once" do
      before_source = """
      defmodule M do
        def run(x) do
          case x do
            :a -> x |> prep() |> step_a() |> finalize()
            :b -> x |> prep() |> step_b() |> finalize()
          end
        end
      end
      """

      assert_idempotent(@subject, before_source)
    end

    test "factored result compiles" do
      before_source = """
      defmodule FlattenCompileCheck do
        def run(x) do
          case x do
            :a -> x |> prep() |> step_a() |> finalize()
            :b -> x |> prep() |> step_b() |> finalize()
          end
        end

        defp prep(v), do: v
        defp step_a(v), do: v
        defp step_b(v), do: v
        defp finalize(v), do: v
      end
      """

      before_source |> then(&apply_refactor(@subject, &1)) |> assert_compiles()
    end
  end

  describe "skips" do
    test "skips when there is no shared prefix" do
      source = """
      defmodule M do
        def run(x) do
          case x do
            :a -> x |> alpha() |> finalize()
            :b -> x |> beta() |> finalize()
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when there is no shared suffix" do
      source = """
      defmodule M do
        def run(x) do
          case x do
            :a -> x |> prep() |> alpha()
            :b -> x |> prep() |> beta()
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when a branch has no divergent middle" do
      source = """
      defmodule M do
        def run(x) do
          case x do
            :a -> x |> prep() |> finalize()
            :b -> x |> prep() |> step_b() |> finalize()
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when a shared stage is effectful" do
      source = """
      defmodule M do
        def run(x) do
          case x do
            :a -> x |> log!() |> step_a() |> finalize()
            :b -> x |> log!() |> step_b() |> finalize()
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips a non-exhaustive case with an effectful shared pre-pipe (Enum.each)" do
      source = """
      defmodule M do
        def run(x) do
          case x do
            :a -> x |> Enum.each(&log/1) |> step_a() |> end_it()
            :b -> x |> Enum.each(&log/1) |> step_b() |> end_it()
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips a non-exhaustive case even when only the shared suffix is effectful" do
      source = """
      defmodule M do
        def run(x) do
          case x do
            :a -> x |> prep() |> step_a() |> Enum.each(&log/1)
            :b -> x |> prep() |> step_b() |> Enum.each(&log/1)
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "exhaustive case allows hoisting effectful shared stages" do
    test "fires for an exhaustive case (catch-all) with an effectful shared pre-pipe" do
      before_source = """
      defmodule M do
        def run(x) do
          case x do
            :a -> x |> Enum.each(&log/1) |> step_a() |> end_it()
            _ -> x |> Enum.each(&log/1) |> step_b() |> end_it()
          end
        end
      end
      """

      expected = """
      defmodule M do
        def run(x) do
          x
          |> Enum.each(&log/1)
          |> run_branch(x)
          |> end_it()
        end

        defp run_branch(piped, :a), do: piped |> step_a()
        defp run_branch(piped, _), do: piped |> step_b()
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "skips when the scrutinee is not a bare variable" do
      source = """
      defmodule M do
        def run(x) do
          case fetch(x) do
            :a -> x |> prep() |> step_a() |> finalize()
            :b -> x |> prep() |> step_b() |> finalize()
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when a branch does not start from the scrutinee" do
      source = """
      defmodule M do
        def run(x) do
          case x do
            :a -> other |> prep() |> step_a() |> finalize()
            :b -> x |> prep() |> step_b() |> finalize()
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips a single-branch case" do
      source = """
      defmodule M do
        def run(x) do
          case x do
            _ -> x |> prep() |> step() |> finalize()
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when a branch body is not a pipe" do
      source = """
      defmodule M do
        def run(x) do
          case x do
            :a -> step_a(x)
            :b -> x |> prep() |> step_b() |> finalize()
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when the case is not the whole body" do
      source = """
      defmodule M do
        def run(x) do
          y = norm(x)

          case y do
            :a -> y |> prep() |> step_a() |> finalize()
            :b -> y |> prep() |> step_b() |> finalize()
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when a branch carries a guard" do
      source = """
      defmodule M do
        def run(x) do
          case x do
            n when n > 0 -> x |> prep() |> step_a() |> finalize()
            _ -> x |> prep() |> step_b() |> finalize()
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "skips when a branch pattern binds a variable used in its body" do
      source = """
      defmodule M do
        def run(x) do
          case x do
            {:a, n} -> x |> prep() |> step_a(n) |> finalize()
            :b -> x |> prep() |> step_b() |> finalize()
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end
end
