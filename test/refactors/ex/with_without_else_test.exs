defmodule Number42.Refactors.Ex.WithWithoutElseTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.WithWithoutElse

  @subject WithWithoutElse

  describe "rewrites" do
    test "single :ok <- clause with redundant :error -> :error else" do
      assert_rewrites(
        @subject,
        """
        with :ok <- compatible_units?(a, b, c) do
          {:ok, row}
        else
          :error -> :error
        end
        """,
        """
        with :ok <- compatible_units?(a, b, c) do
          {:ok, row}
        end
        """
      )
    end

    test "chain whose failure shape is exactly the else's catch arm" do
      assert_rewrites(
        @subject,
        """
        with {:ok, x} <- foo(),
             {:ok, y} <- bar(x) do
          {:ok, y}
        else
          {:error, _} = err -> err
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
  end

  describe "leaves alone" do
    test "else arm transforms the value (not redundant)" do
      assert_unchanged(@subject, """
      with :ok <- compatible_units?(a, b, c) do
        {:ok, row}
      else
        :error -> {:error, :unit_mismatch}
      end
      """)
    end

    test "with already without else stays as is" do
      assert_unchanged(@subject, """
      with :ok <- compatible_units?(a, b, c) do
        {:ok, row}
      end
      """)
    end

    test "with that has no <- clauses (degenerate)" do
      assert_unchanged(@subject, """
      with x = 1 do
        x
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      with :ok <- compatible_units?(a, b, c) do
        {:ok, row}
      else
        :error -> :error
      end
      """)
    end
  end
end
