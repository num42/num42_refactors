defmodule Number42.Refactors.Ex.SinkBindingIntoBranchesTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.SinkBindingIntoBranches

  @subject SinkBindingIntoBranches

  describe "rewrites — sink into case clause" do
    test "sinks a binding read in exactly one case clause into that clause" do
      before_source = """
      defmodule M do
        def f(mode, opts) do
          config = Map.get(opts, :config)

          case mode do
            :fast -> run_fast()
            :full -> run_full(config)
          end
        end
      end
      """

      after_source = """
      defmodule M do
        def f(mode, opts) do
          case mode do
            :fast ->
              run_fast()

            :full ->
              config = Map.get(opts, :config)
              run_full(config)
          end
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "sinks into a clause whose body is already a multi-statement block" do
      before_source = """
      defmodule M do
        def f(mode, opts) do
          config = Map.get(opts, :config)

          case mode do
            :fast ->
              warm()
              run_fast()

            :full ->
              warm()
              run_full(config)
          end
        end
      end
      """

      after_source = """
      defmodule M do
        def f(mode, opts) do
          case mode do
            :fast ->
              warm()
              run_fast()

            :full ->
              config = Map.get(opts, :config)
              warm()
              run_full(config)
          end
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "rewrites — sink into if branch" do
    test "sinks a binding read only in the else branch" do
      before_source = """
      defmodule M do
        def f(flag, opts) do
          config = Map.get(opts, :config)

          if flag do
            run_fast()
          else
            run_full(config)
          end
        end
      end
      """

      after_source = """
      defmodule M do
        def f(flag, opts) do
          if flag do
            run_fast()
          else
            config = Map.get(opts, :config)
            run_full(config)
          end
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "sinks a binding read only in the do branch" do
      before_source = """
      defmodule M do
        def f(flag, opts) do
          config = Map.get(opts, :config)

          if flag do
            run_full(config)
          else
            run_fast()
          end
        end
      end
      """

      after_source = """
      defmodule M do
        def f(flag, opts) do
          if flag do
            config = Map.get(opts, :config)
            run_full(config)
          else
            run_fast()
          end
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "skips unsafe sinks" do
    test "skips when the binding is read in more than one branch" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(mode, opts) do
          config = Map.get(opts, :config)

          case mode do
            :fast -> run_fast(config)
            :full -> run_full(config)
          end
        end
      end
      """)
    end

    test "skips when the RHS is impure (could raise)" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(mode, s) do
          n = String.to_integer(s)

          case mode do
            :fast -> run_fast()
            :full -> run_full(n)
          end
        end
      end
      """)
    end

    test "skips when the RHS performs a side effect" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(mode) do
          config = IO.inspect(:loaded)

          case mode do
            :fast -> run_fast()
            :full -> run_full(config)
          end
        end
      end
      """)
    end

    test "skips when the RHS is an opaque local call" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(mode) do
          config = load_config()

          case mode do
            :fast -> run_fast()
            :full -> run_full(config)
          end
        end
      end
      """)
    end

    test "skips when the scrutinee depends on the binding (cycle)" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(input) do
          mode = Map.get(input, :mode)

          case mode do
            :fast -> run_fast()
            :full -> run_full(mode)
          end
        end
      end
      """)
    end

    test "skips when the if condition depends on the binding (cycle)" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(input) do
          flag = Map.get(input, :flag)

          if flag do
            run_fast()
          else
            run_full(flag)
          end
        end
      end
      """)
    end

    test "skips when the binding is read after the case (still live)" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(mode, opts) do
          config = Map.get(opts, :config)

          case mode do
            :fast -> run_fast()
            :full -> run_full(config)
          end

          finalize(config)
        end
      end
      """)
    end

    test "skips a pattern-match LHS (not a simple binding)" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(mode, opts) do
          %{config: config} = opts

          case mode do
            :fast -> run_fast()
            :full -> run_full(config)
          end
        end
      end
      """)
    end

    test "skips when the binding is read in zero branches (dead relative to the case)" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(mode, opts) do
          config = Map.get(opts, :config)

          case mode do
            :fast -> run_fast()
            :full -> run_full()
          end
        end
      end
      """)
    end

    test "skips when the next statement is not a case/if" do
      assert_unchanged(@subject, """
      defmodule M do
        def f(opts) do
          config = Map.get(opts, :config)
          run_full(config)
        end
      end
      """)
    end
  end

  describe "idempotence & compilation" do
    test "stable after one sink" do
      assert_idempotent(@subject, """
      defmodule M do
        def f(mode, opts) do
          config = Map.get(opts, :config)

          case mode do
            :fast -> run_fast()
            :full -> run_full(config)
          end
        end
      end
      """)
    end

    test "output compiles" do
      source = """
      defmodule SinkBindingIntoBranchesCompileCheck do
        def f(mode, opts) do
          config = Map.get(opts, :config)

          case mode do
            :fast -> run_fast()
            :full -> run_full(config)
          end
        end

        defp run_fast, do: :fast
        defp run_full(c), do: {:full, c}
      end
      """

      assert_compiles(apply_refactor(@subject, source))
    end
  end
end
