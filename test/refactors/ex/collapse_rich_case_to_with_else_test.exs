defmodule Number42.Refactors.Ex.CollapseRichCaseToWithElseTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.CollapseRichCaseToWithElse

  @subject CollapseRichCaseToWithElse

  describe "rewrites" do
    test "three-level pyramid with non-trivial error arms becomes with/else" do
      before = """
      case fetch_user(id) do
        {:ok, user} ->
          case authorize(user, action) do
            :ok ->
              case perform(action, user) do
                {:ok, result} -> {:ok, result}
                {:error, :timeout} -> {:error, "took too long"}
              end

            {:error, :forbidden} -> {:error, "not allowed"}
          end

        {:error, :not_found} -> {:error, "no such user"}
      end
      """

      expected = """
      with {:ok, user} <- fetch_user(id),
           :ok <- authorize(user, action),
           {:ok, result} <- perform(action, user) do
        {:ok, result}
      else
        {:error, :not_found} -> {:error, "no such user"}
        {:error, :forbidden} -> {:error, "not allowed"}
        {:error, :timeout} -> {:error, "took too long"}
      end
      """

      assert_rewrites(@subject, before, expected)

      assert_compiles("""
      defmodule M do
        def run(id, action) do
          #{apply_refactor(@subject, before)}
        end

        defp fetch_user(_), do: Process.get(:fetch_user)
        defp authorize(_, _), do: Process.get(:authorize)
        defp perform(_, _), do: Process.get(:perform)
      end
      """)
    end

    test "two-level pyramid with one non-trivial arm (distinct patterns)" do
      assert_rewrites(
        @subject,
        """
        case step_one() do
          {:ok, x} ->
            case step_two(x) do
              {:ok, y} -> {:ok, y}
              {:error, :inner} -> {:error, transform(:inner)}
            end

          {:error, :outer} ->
            {:error, :outer}
        end
        """,
        """
        with {:ok, x} <- step_one(),
             {:ok, y} <- step_two(x) do
          {:ok, y}
        else
          {:error, :outer} -> {:error, :outer}
          {:error, :inner} -> {:error, transform(:inner)}
        end
        """
      )
    end
  end

  describe "leaves alone" do
    test "all error arms are trivial passthrough — belongs to CollapseNestedCaseToWith" do
      assert_unchanged(@subject, """
      case step_one() do
        {:ok, x} ->
          case step_two(x) do
            {:ok, y} -> {:ok, y}
            {:error, e} -> {:error, e}
          end

        {:error, e} ->
          {:error, e}
      end
      """)
    end

    test "error arm references an outer success binding — uncompilable in else, skip" do
      assert_unchanged(@subject, """
      case fetch_user(id) do
        {:ok, user} ->
          case authorize(user, action) do
            :ok -> {:ok, user}
            {:error, :forbidden} -> {:error, "user \#{user.id} not allowed"}
          end

        {:error, :not_found} ->
          {:error, "no such user"}
      end
      """)
    end

    test "duplicate error patterns across levels — flat else collapses them, skip" do
      assert_unchanged(@subject, """
      case step_one() do
        {:ok, x} ->
          case step_two(x) do
            {:ok, y} -> {:ok, y}
            {:error, :conflict} -> {:error, "inner conflict"}
          end

        {:error, :conflict} ->
          {:error, "outer conflict"}
      end
      """)
    end

    test "single non-nested case is untouched" do
      assert_unchanged(@subject, """
      case foo() do
        {:ok, x} -> x
        {:error, e} -> {:error, transform(e)}
      end
      """)
    end

    test "already a with chain" do
      assert_unchanged(@subject, """
      with {:ok, x} <- step_one(),
           {:ok, y} <- step_two(x) do
        {:ok, y}
      else
        {:error, e} -> {:error, transform(e)}
      end
      """)
    end

    test "no success arm at the level (no ok-shaped pattern nesting) is untouched" do
      assert_unchanged(@subject, """
      case classify(x) do
        :a -> handle_a()
        :b -> handle_b()
      end
      """)
    end

    test "multiple success arms at one level — ambiguous spine, skip" do
      assert_unchanged(@subject, """
      case step_one() do
        {:ok, x} ->
          case step_two(x) do
            {:ok, y} -> {:ok, y}
            :ok -> {:ok, :unit}
            {:error, e} -> {:error, transform(e)}
          end

        {:error, e} ->
          {:error, e}
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      case fetch_user(id) do
        {:ok, user} ->
          case authorize(user, action) do
            :ok ->
              case perform(action, user) do
                {:ok, result} -> {:ok, result}
                {:error, :timeout} -> {:error, "took too long"}
              end

            {:error, :forbidden} -> {:error, "not allowed"}
          end

        {:error, :not_found} -> {:error, "no such user"}
      end
      """)
    end
  end

  describe "assert_compiles" do
    test "produced with/else is valid Elixir" do
      before = """
      case step_one() do
        {:ok, x} ->
          case step_two(x) do
            {:ok, y} -> {:ok, y}
            {:error, :inner} -> {:error, normalize(:inner)}
          end

        {:error, :outer} ->
          {:error, :outer}
      end
      """

      rewritten = apply_refactor(@subject, before)
      assert rewritten =~ "with"
      assert rewritten =~ "else"

      assert_compiles("""
      defmodule M do
        def run do
          #{rewritten}
        end

        defp step_one, do: Process.get(:step_one)
        defp step_two(_), do: Process.get(:step_two)
        defp normalize(e), do: e
      end
      """)
    end
  end
end
