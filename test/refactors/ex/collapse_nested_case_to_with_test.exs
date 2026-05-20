defmodule Number42.Refactors.Ex.CollapseNestedCaseToWithTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.CollapseNestedCaseToWith

  @subject CollapseNestedCaseToWith

  describe "rewrites" do
    test "two-level nested case with passthrough errors becomes with" do
      assert_rewrites(
        @subject,
        """
        case step_one() do
          {:ok, x} ->
            case step_two(x) do
              {:ok, y} -> {:ok, y}
              {:error, e} -> {:error, e}
            end

          {:error, e} ->
            {:error, e}
        end
        """,
        """
        with {:ok, x} <- step_one(),
             {:ok, y} <- step_two(x) do
          {:ok, y}
        end
        """
      )
    end

    test "three-level chain with mixed :ok / {:ok, _} tags" do
      assert_rewrites(
        @subject,
        """
        case validate(cs) do
          {:ok, cs} ->
            case check(cs) do
              :ok ->
                case Repo.insert(cs) do
                  {:ok, m} -> {:ok, m}
                  {:error, e} -> {:error, e}
                end

              {:error, e} ->
                {:error, e}
            end

          {:error, e} ->
            {:error, e}
        end
        """,
        """
        with {:ok, cs} <- validate(cs),
             :ok <- check(cs),
             {:ok, m} <- Repo.insert(cs) do
          {:ok, m}
        end
        """
      )
    end
  end

  describe "leaves alone" do
    test "error arm does work other than propagation — must keep nesting" do
      assert_unchanged(@subject, """
      case step_one() do
        {:ok, x} ->
          case step_two(x) do
            {:ok, y} -> {:ok, y}
            {:error, e} -> {:error, e}
          end

        {:error, e} ->
          Logger.error(\"step one failed\")
          {:error, e}
      end
      """)
    end

    test "single non-nested case is untouched" do
      assert_unchanged(@subject, """
      case foo() do
        {:ok, x} -> x
        {:error, e} -> {:error, e}
      end
      """)
    end

    test "already a with chain" do
      assert_unchanged(@subject, """
      with {:ok, x} <- step_one(),
           {:ok, y} <- step_two(x) do
        {:ok, y}
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
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
  end
end
