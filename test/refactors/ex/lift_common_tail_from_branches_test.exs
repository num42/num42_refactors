defmodule Number42.Refactors.Ex.LiftCommonTailFromBranchesTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.LiftCommonTailFromBranches

  @subject LiftCommonTailFromBranches

  describe "case lifts" do
    test "single common tail statement lifts out of an exhaustive case" do
      before_source = """
      defmodule M do
        def f(x) do
          case x do
            :a ->
              do_a()
              log(:done)

            _ ->
              do_b()
              log(:done)
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(x) do
          case x do
            :a ->
              do_a()

            _ ->
              do_b()
          end

          log(:done)
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "multi-statement common tail lifts as a run" do
      before_source = """
      defmodule M do
        def f(x) do
          case x do
            :a ->
              do_a()
              cleanup()
              log(:done)

            _ ->
              do_b()
              cleanup()
              log(:done)
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(x) do
          case x do
            :a ->
              do_a()

            _ ->
              do_b()
          end

          cleanup()
          log(:done)
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "lifts even when the case is not the last statement in the body" do
      before_source = """
      defmodule M do
        def f(x) do
          case x do
            :a ->
              do_a()
              notify()

            _ ->
              do_b()
              notify()
          end

          :result
        end
      end
      """

      expected = """
      defmodule M do
        def f(x) do
          case x do
            :a ->
              do_a()

            _ ->
              do_b()
          end

          notify()

          :result
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "if lifts" do
    test "if/else with identical tail lifts the tail out" do
      before_source = """
      defmodule M do
        def f(x) do
          if x do
            do_a()
            log(:done)
          else
            do_b()
            log(:done)
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(x) do
          if x do
            do_a()
          else
            do_b()
          end

          log(:done)
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "idempotent" do
    test "case lift runs once" do
      source = """
      defmodule M do
        def f(x) do
          case x do
            :a ->
              do_a()
              log(:done)

            _ ->
              do_b()
              log(:done)
          end
        end
      end
      """

      assert_idempotent(@subject, source)
    end

    test "if lift runs once" do
      source = """
      defmodule M do
        def f(x) do
          if x do
            do_a()
            log(:done)
          else
            do_b()
            log(:done)
          end
        end
      end
      """

      assert_idempotent(@subject, source)
    end

    test "already-lifted code passes through unchanged" do
      source = """
      defmodule M do
        def f(x) do
          case x do
            :a -> do_a()
            _ -> do_b()
          end

          log(:done)
        end
      end
      """

      assert_idempotent(@subject, source)
    end
  end

  describe "leaves alone (skip cases)" do
    test "non-exhaustive case (no catch-all) is skipped" do
      source = """
      defmodule M do
        def f(x) do
          case x do
            :a ->
              do_a()
              log(:done)

            :b ->
              do_b()
              log(:done)
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "if without else is skipped (implicit nil branch has no tail)" do
      source = """
      defmodule M do
        def f(x) do
          if x do
            do_a()
            log(:done)
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "tail depends on a branch-local binding is skipped" do
      source = """
      defmodule M do
        def f(x) do
          case x do
            :a ->
              v = do_a()
              log(v)

            _ ->
              v = do_b()
              log(v)
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "tail depends on a branch pattern binding is skipped" do
      source = """
      defmodule M do
        def f(x) do
          case x do
            {:ok, v} ->
              do_a()
              log(v)

            v ->
              do_b()
              log(v)
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "case value is consumed by an assignment is skipped" do
      source = """
      defmodule M do
        def f(x) do
          y =
            case x do
              :a ->
                do_a()
                log(:done)

              _ ->
                do_b()
                log(:done)
            end

          y
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "case value is piped is skipped" do
      source = """
      defmodule M do
        def f(x) do
          case x do
            :a ->
              do_a()
              :done

            _ ->
              do_b()
              :done
          end
          |> handle()
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "branches do not share a tail is skipped" do
      source = """
      defmodule M do
        def f(x) do
          case x do
            :a ->
              do_a()
              log(:a)

            _ ->
              do_b()
              log(:b)
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "a branch is exactly the common tail (would leave it empty) is skipped" do
      source = """
      defmodule M do
        def f(x) do
          case x do
            :a ->
              log(:done)

            _ ->
              do_b()
              log(:done)
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "bare keyword-form case (do:) without a do/end block is skipped" do
      source = ~S"""
      defmodule M do
        def f(x), do: case x do
          :a -> (do_a(); log(:done))
          _ -> (do_b(); log(:done))
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "if/else where only one branch has the tail is skipped" do
      source = """
      defmodule M do
        def f(x) do
          if x do
            do_a()
            log(:done)
          else
            do_b()
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end
end
