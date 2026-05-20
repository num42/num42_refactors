defmodule Number42.Refactors.Ex.WithSingleClauseToCaseTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.WithSingleClauseToCase

  @subject WithSingleClauseToCase

  describe "rewrites" do
    test "single <- clause without else becomes case with passthrough arm" do
      # Bare `with X <- expr do body end` returns the un-matched value as
      # the with's value when the match fails. A naked `case` would crash
      # with CaseClauseError, so we emit `other -> other` to preserve
      # semantics.
      assert_rewrites(
        @subject,
        """
        with {:ok, _metadata} <- Mailer.deliver(email) do
          {:ok, email}
        end
        """,
        """
        case Mailer.deliver(email) do
          {:ok, _metadata} -> {:ok, email}
          other -> other
        end
        """
      )
    end

    test "single <- clause with else translates each else arm" do
      assert_rewrites(
        @subject,
        """
        with {:ok, user} <- fetch(id) do
          process(user)
        else
          {:error, e} -> {:error, e}
        end
        """,
        """
        case fetch(id) do
          {:ok, user} -> process(user)
          {:error, e} -> {:error, e}
        end
        """
      )
    end
  end

  describe "leaves alone" do
    test "with two or more <- clauses is preserved" do
      assert_unchanged(@subject, """
      with {:ok, a} <- step_one(),
           {:ok, b} <- step_two(a) do
        {:ok, b}
      end
      """)
    end

    test "already a case expression" do
      assert_unchanged(@subject, """
      case foo() do
        {:ok, x} -> x
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      with {:ok, x} <- foo() do
        {:ok, x}
      end
      """)
    end
  end

  describe "leaves alone (passthrough collisions)" do
    test "skips when passthrough name `other` already in scope" do
      # If something binds `other` in the surrounding scope (or as a
      # function param), our generated `other -> other` arm would shadow
      # it. We can't easily detect that here without scope analysis, so
      # skip the rewrite when the body or RHS references `other` as a
      # free var.
      assert_unchanged(@subject, """
      with {:ok, x} <- foo(other) do
        {:ok, x}
      end
      """)
    end
  end
end
