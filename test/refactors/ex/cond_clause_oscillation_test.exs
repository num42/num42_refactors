defmodule Number42.Refactors.Ex.CondClauseOscillationTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractCondToGuardClauses
  alias Number42.Refactors.Ex.MergeClausesIntoCondOrGuard

  # ExtractCondToGuardClauses and MergeClausesIntoCondOrGuard are
  # inverses. The shared complexity heuristic
  # (AstHelpers.clause_worthy_body?) assigns every function exactly one
  # stable form — simple bodies live in a `cond`, clause-worthy bodies
  # live in clauses — so running both refactors in any order reaches a
  # fixpoint. Found as a commit ping-pong when dogfooding the suite
  # against position-db.

  test "simple bodies settle on the cond form" do
    clauses = """
    defmodule M do
      def label(n) when n < 0, do: "neg"
      def label(n) when n == 0, do: "zero"
      def label(n), do: "rest"
    end
    """

    merged = apply_refactor(MergeClausesIntoCondOrGuard, clauses)
    refute merged == clauses
    assert_unchanged(ExtractCondToGuardClauses, merged)
  end

  test "clause-worthy bodies settle on the clause form" do
    cond_form = """
    defmodule M do
      def step(n) do
        cond do
          n > 0 ->
            x = n * 2
            x + 1

          true ->
            n
        end
      end
    end
    """

    extracted = apply_refactor(ExtractCondToGuardClauses, cond_form)
    refute extracted == cond_form
    assert_unchanged(MergeClausesIntoCondOrGuard, extracted)
  end

  test "both orders reach the same fixpoint for the position-db repro" do
    # format_ago-style: the single param is used in every body, so the
    # param lists stay identical after extraction — exactly the shape
    # that ping-ponged before the shared heuristic.
    clause_form = """
    defmodule M do
      defp format_ago(seconds) when seconds < 60, do: "just now"

      defp format_ago(seconds) when seconds < 3600 do
        minutes = div(seconds, 60)
        if minutes == 1, do: "1 minute ago", else: "\#{minutes} minutes ago"
      end

      defp format_ago(seconds), do: "long ago"
    end
    """

    assert_unchanged(MergeClausesIntoCondOrGuard, clause_form)
    assert_unchanged(ExtractCondToGuardClauses, clause_form)
  end
end
