defmodule Number42.Refactors.Ex.RemoveTrivialElseClauseTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.RemoveTrivialElseClause

  @subject RemoveTrivialElseClause

  describe "rewrites" do
    test "identity {:error, e} -> {:error, e} else is dropped" do
      assert_rewrites(
        @subject,
        """
        with {:ok, x} <- foo(),
             {:ok, y} <- bar(x) do
          {:ok, y}
        else
          {:error, e} -> {:error, e}
        end
        """,
        """
        with {:ok, x} <- foo(),
             {:ok, y} <- bar(x) do
          {:ok, y}
        end
        """
      )
    end

    test "identity catch-any e -> e else is dropped" do
      assert_rewrites(
        @subject,
        """
        with {:ok, x} <- foo() do
          {:ok, x}
        else
          e -> e
        end
        """,
        """
        with {:ok, x} <- foo() do
          {:ok, x}
        end
        """
      )
    end
  end

  describe "leaves alone" do
    test "else arm transforms the error — must keep" do
      assert_unchanged(@subject, """
      with {:ok, x} <- foo() do
        {:ok, x}
      else
        {:error, e} -> {:error, format_error(e)}
      end
      """)
    end

    test "mixed trivial and non-trivial arms — keep whole else" do
      assert_unchanged(@subject, """
      with {:ok, x} <- foo() do
        {:ok, x}
      else
        {:error, :not_found} -> {:error, :gone}
        {:error, e} -> {:error, e}
      end
      """)
    end

    test "with without else is untouched" do
      assert_unchanged(@subject, """
      with {:ok, x} <- foo() do
        {:ok, x}
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      with {:ok, x} <- foo() do
        {:ok, x}
      else
        {:error, e} -> {:error, e}
      end
      """)
    end
  end
end
