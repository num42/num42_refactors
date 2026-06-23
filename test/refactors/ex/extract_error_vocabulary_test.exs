defmodule Number42.Refactors.Ex.ExtractErrorVocabularyTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractErrorVocabulary

  @subject ExtractErrorVocabulary

  # Enabled by default and takes no enable gate; `@on` is the empty opts
  # list, kept on the behaviour tests for call-shape uniformity.
  @on []

  describe "enabled by default" do
    test "runs with no enable opt" do
      before_source = """
      defmodule M do
        def a, do: {:error, :not_found}
        def b, do: {:error, :not_found}
        def c, do: {:error, :not_found}
      end
      """

      expected = """
      defmodule M do
        defp error_not_found, do: {:error, :not_found}

        def a, do: error_not_found()
        def b, do: error_not_found()
        def c, do: error_not_found()
      end
      """

      assert_rewrites(@subject, before_source, expected, [])
    end
  end

  describe "repeated {:error, atom} construction across >= 3 sites" do
    test "extracts a defp helper and replaces every construction site" do
      before_source = """
      defmodule M do
        def a, do: {:error, :not_found}
        def b, do: {:error, :not_found}
        def c, do: {:error, :not_found}
      end
      """

      expected = """
      defmodule M do
        defp error_not_found, do: {:error, :not_found}

        def a, do: error_not_found()
        def b, do: error_not_found()
        def c, do: error_not_found()
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
    end

    test "rewrites construction sites inside case bodies" do
      before_source = """
      defmodule M do
        def a(x) do
          case x do
            :a -> {:error, :unauthorized}
            _ -> :ok
          end
        end

        def b, do: {:error, :unauthorized}
        def c, do: {:error, :unauthorized}
      end
      """

      expected = """
      defmodule M do
        defp error_unauthorized, do: {:error, :unauthorized}

        def a(x) do
          case x do
            :a -> error_unauthorized()
            _ -> :ok
          end
        end

        def b, do: error_unauthorized()
        def c, do: error_unauthorized()
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
    end

    test "rewrites construction sites in with-else bodies but not the clause heads" do
      before_source = """
      defmodule M do
        def run(x) do
          with {:ok, v} <- fetch(x) do
            {:ok, v}
          else
            {:error, :not_found} -> {:error, :not_found}
            _ -> {:error, :not_found}
          end
        end

        def b, do: {:error, :not_found}
      end
      """

      # The `{:error, :not_found}` clause HEAD stays a literal pattern;
      # only the three construction sites (two clause bodies + def b) are
      # replaced.
      expected = """
      defmodule M do
        defp error_not_found, do: {:error, :not_found}

        def run(x) do
          with {:ok, v} <- fetch(x) do
            {:ok, v}
          else
            {:error, :not_found} -> error_not_found()
            _ -> error_not_found()
          end
        end

        def b, do: error_not_found()
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
    end
  end

  describe "match positions are never rewritten (correctness)" do
    test "LHS of = is left as a literal pattern" do
      before_source = """
      defmodule M do
        def a do
          {:error, :not_found} = lookup()
          {:error, :not_found}
        end

        def b, do: {:error, :not_found}
        def c, do: {:error, :not_found}
      end
      """

      # Three construction sites: the bare return in a/0, and b/0 and c/0.
      # The `= lookup()` LHS is a match and must stay literal.
      expected = """
      defmodule M do
        defp error_not_found, do: {:error, :not_found}

        def a do
          {:error, :not_found} = lookup()
          error_not_found()
        end

        def b, do: error_not_found()
        def c, do: error_not_found()
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
    end

    test "function-head patterns are not rewritten" do
      before_source = """
      defmodule M do
        def handle({:error, :not_found}), do: :a
        def handle({:error, :not_found}), do: :b
        def handle({:error, :not_found}), do: :c
      end
      """

      # All three occurrences are head patterns (match positions). No
      # construction site exists, so the source is untouched.
      assert_unchanged(@subject, before_source, @on)
    end

    test "case/with clause heads are not rewritten even at high frequency" do
      before_source = """
      defmodule M do
        def a(x) do
          case x do
            {:error, :not_found} -> 1
            _ -> 2
          end
        end

        def b(x) do
          case x do
            {:error, :not_found} -> 3
            _ -> 4
          end
        end

        def c(x) do
          case x do
            {:error, :not_found} -> 5
            _ -> 6
          end
        end
      end
      """

      assert_unchanged(@subject, before_source, @on)
    end

    test "LHS of <- in a with generator is not rewritten" do
      before_source = """
      defmodule M do
        def run do
          with {:error, :not_found} <- step1(),
               {:error, :not_found} <- step2(),
               {:error, :not_found} <- step3() do
            :ok
          end
        end
      end
      """

      assert_unchanged(@subject, before_source, @on)
    end

    test "{:error, atom} inside an @spec is a type literal, not a construction" do
      # The tuple appears once in a @spec (a type context, where a `defp`
      # call is invalid) and three times as a constructed value. Only the
      # value positions are rewritten; the @spec stays a type literal so
      # the result still compiles (a function call there is a TypespecError).
      before_source = """
      defmodule M do
        @spec invite(term()) :: {:ok, term()} | {:error, :unauthorized}
        def invite(%{admin: true} = u), do: {:ok, u}
        def invite(_), do: {:error, :unauthorized}

        def lock(_), do: {:error, :unauthorized}
        def toggle(_), do: {:error, :unauthorized}
      end
      """

      expected = """
      defmodule M do
        defp error_unauthorized, do: {:error, :unauthorized}

        @spec invite(term()) :: {:ok, term()} | {:error, :unauthorized}
        def invite(%{admin: true} = u), do: {:ok, u}
        def invite(_), do: error_unauthorized()

        def lock(_), do: error_unauthorized()
        def toggle(_), do: error_unauthorized()
      end
      """

      assert_rewrites(@subject, before_source, expected, @on)
      assert_compiles(apply_refactor(@subject, before_source, @on))
    end

    test "@type referencing {:error, atom} is left untouched even when below other thresholds" do
      # All occurrences are inside type contexts (one @type, one @spec) →
      # no construction site exists → source unchanged.
      before_source = """
      defmodule M do
        @type result :: {:ok, term()} | {:error, :not_found}
        @spec fetch(term()) :: {:error, :not_found}
        def fetch(_), do: raise("x")
      end
      """

      assert_unchanged(@subject, before_source, @on)
    end
  end

  describe "threshold" do
    test "fewer than 3 construction sites is left unchanged" do
      before_source = """
      defmodule M do
        def a, do: {:error, :not_found}
        def b, do: {:error, :not_found}
      end
      """

      assert_unchanged(@subject, before_source, @on)
    end
  end

  describe "false-positive guards" do
    test "generic control-flow inner atoms are skipped" do
      before_source = """
      defmodule M do
        def a, do: {:error, :ok}
        def b, do: {:error, :ok}
        def c, do: {:error, :ok}
      end
      """

      assert_unchanged(@subject, before_source, @on)
    end

    test "tuples whose tag is not :error are skipped" do
      before_source = """
      defmodule M do
        def a, do: {:ok, :done}
        def b, do: {:ok, :done}
        def c, do: {:ok, :done}
      end
      """

      assert_unchanged(@subject, before_source, @on)
    end

    test "{:error, atom} with a non-atom payload arity (3-tuple) is skipped" do
      before_source = """
      defmodule M do
        def a, do: {:error, :not_found, "x"}
        def b, do: {:error, :not_found, "x"}
        def c, do: {:error, :not_found, "x"}
      end
      """

      assert_unchanged(@subject, before_source, @on)
    end

    test "name collision with an existing function is skipped" do
      before_source = """
      defmodule M do
        def error_not_found, do: :something_else

        def a, do: {:error, :not_found}
        def b, do: {:error, :not_found}
        def c, do: {:error, :not_found}
      end
      """

      assert_unchanged(@subject, before_source, @on)
    end
  end

  describe "idempotence and compilation" do
    test "running twice equals running once" do
      src = """
      defmodule M do
        def a, do: {:error, :not_found}
        def b, do: {:error, :not_found}
        def c, do: {:error, :not_found}
      end
      """

      assert_idempotent(@subject, src, @on)
    end

    test "rewritten output compiles" do
      src = """
      defmodule M do
        def a, do: {:error, :not_found}
        def b, do: {:error, :not_found}
        def c, do: {:error, :not_found}
      end
      """

      assert_compiles(apply_refactor(@subject, src, @on))
    end

    test "the synthesized helper itself is not re-extracted on a second pass" do
      src = """
      defmodule M do
        defp error_not_found, do: {:error, :not_found}

        def a, do: error_not_found()
        def b, do: error_not_found()
        def c, do: error_not_found()
      end
      """

      assert_unchanged(@subject, src, @on)
    end
  end
end
