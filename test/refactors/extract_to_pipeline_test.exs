defmodule Num42.Refactors.Refactors.ExtractToPipelineTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.ExtractToPipeline

  @subject ExtractToPipeline

  describe "rewrites — single call" do
    test "Enum.map(coll, fun) becomes coll |> Enum.map(fun)" do
      assert_rewrites(
        @subject,
        "Enum.map(list, fun)",
        "list |> Enum.map(fun)"
      )
    end

    test "Stream.filter(coll, fun) becomes coll |> Stream.filter(fun)" do
      assert_rewrites(
        @subject,
        "Stream.filter(list, fun)",
        "list |> Stream.filter(fun)"
      )
    end

    test "single-arg Enum.count(coll) becomes coll |> Enum.count()" do
      assert_rewrites(
        @subject,
        "Enum.count(list)",
        "list |> Enum.count()"
      )
    end

    test "Enum call with three args" do
      assert_rewrites(
        @subject,
        "Enum.reduce(list, %{}, reducer)",
        "list |> Enum.reduce(%{}, reducer)"
      )
    end

    test "Enum call with capture form" do
      assert_rewrites(
        @subject,
        "Enum.map(list, &to_string/1)",
        "list |> Enum.map(&to_string/1)"
      )
    end
  end

  describe "rewrites — nested calls" do
    test "nested Enum/Stream call as first arg gets pulled into pipe" do
      # Stream.filter(coll, pred) |> Enum.to_list() — first pass turns
      # the OUTER Enum.to_list call into a pipe; nested call stays as
      # its own pipe stage. Engine fixpoint will not re-extract because
      # the outer is already piped.
      assert_rewrites(
        @subject,
        "Enum.to_list(Stream.filter(list, pred))",
        "Stream.filter(list, pred) |> Enum.to_list()"
      )
    end

    test "Enum nested in Enum extracts the outer first" do
      # The inner Enum.filter would be picked up by a follow-up pass
      # on the new RHS. This refactor only rewrites one level per
      # call site per pass.
      assert_rewrites(
        @subject,
        "Enum.map(Enum.filter(list, pred), fun)",
        "Enum.filter(list, pred) |> Enum.map(fun)"
      )
    end
  end

  describe "leaves alone — already piped" do
    test "Enum call already on the RHS of a pipe stays put" do
      assert_unchanged(@subject, "list |> Enum.map(fun)")
    end

    test "multi-stage existing pipe stays put" do
      assert_unchanged(@subject, "list |> Enum.filter(pred) |> Enum.map(fun)")
    end

    test "Enum call as RHS of pipe with extra args stays put" do
      assert_unchanged(@subject, "list |> Enum.reduce(%{}, reducer)")
    end
  end

  describe "leaves alone — non-Enum/Stream callers" do
    test "Map call is out of scope" do
      assert_unchanged(@subject, "Map.get(map, :key)")
    end

    test "String call is out of scope" do
      assert_unchanged(@subject, "String.split(input, \",\")")
    end

    test "local function call is out of scope" do
      assert_unchanged(@subject, "process(items, opts)")
    end

    test "remote call on lowercase variable is out of scope" do
      assert_unchanged(@subject, "mod.run(arg)")
    end
  end

  describe "leaves alone — pipe-unsafe positions" do
    # Wrapping an arithmetic/boolean operand in a fresh `|>` pipe
    # silently re-associates because pipe has very low precedence.
    # Better to keep the call form than emit subtly wrong code.
    test "Enum call as ++ operand stays put" do
      assert_unchanged(@subject, "x ++ Enum.map(list, fun)")
    end

    test "Enum call as + operand stays put" do
      assert_unchanged(@subject, "1 + Enum.count(list)")
    end

    test "Enum call as comparison operand stays put" do
      assert_unchanged(@subject, "Enum.count(list) > 0")
    end

    test "Enum call as boolean operand stays put" do
      assert_unchanged(@subject, "Enum.empty?(list) and other")
    end

    test "Enum call as <> operand stays put" do
      assert_unchanged(@subject, "prefix <> Enum.join(parts, \",\")")
    end
  end

  describe "rewrites — inside larger expressions" do
    # Function-call argument position is pipe-safe — `f(a |> g())`
    # parses cleanly. The user's "schon innerhalb pipe" rule was
    # about the call ITSELF being a pipe stage, not about being
    # nested under one.
    test "Enum call as function argument is rewritten" do
      assert_rewrites(
        @subject,
        "wrap(Enum.map(list, fun))",
        "wrap(list |> Enum.map(fun))"
      )
    end

    test "Enum call inside a do-block is rewritten" do
      assert_rewrites(
        @subject,
        """
        if condition do
          Enum.map(list, fun)
        end
        """,
        """
        if condition do
          list |> Enum.map(fun)
        end
        """
      )
    end

    test "Enum call as RHS of a `=` is rewritten" do
      # Match-RHS is pipe-safe: `x = a |> b()` is fine.
      assert_rewrites(
        @subject,
        "result = Enum.map(list, fun)",
        "result = list |> Enum.map(fun)"
      )
    end
  end

  describe "edge cases" do
    test "Enum call with zero args is left alone" do
      # Enum.??(...) with no args has no first-arg to extract.
      assert_unchanged(@subject, "Enum.thing()")
    end

    test "Enum call whose first arg is a literal stays in scope" do
      # `[1, 2, 3] |> Enum.map(fun)` — still a valid extraction.
      assert_rewrites(
        @subject,
        "Enum.map([1, 2, 3], fun)",
        "[1, 2, 3] |> Enum.map(fun)"
      )
    end
  end

  describe "rewrites — non-trivial first arg" do
    test "first arg is itself a chain of pipes — flattens cleanly" do
      # `coll |> munge() |> Enum.map(fun)` — pipe is left-associative
      # so the inner pipe and the new pipe stage merge into one chain
      # without parens. Reads as the user wrote it: take coll, munge
      # it, then map over it.
      assert_rewrites(
        @subject,
        "Enum.map(coll |> munge(), fun)",
        "coll |> munge() |> Enum.map(fun)"
      )
    end

    test "first arg is a function call" do
      assert_rewrites(
        @subject,
        "Enum.map(fetch_items(), fun)",
        "fetch_items() |> Enum.map(fun)"
      )
    end

    test "first arg is a remote field access" do
      assert_rewrites(
        @subject,
        "Enum.map(socket.assigns.items, fun)",
        "socket.assigns.items |> Enum.map(fun)"
      )
    end

    test "first arg is an `||` expression — wrapped in parens so |> binds correctly" do
      # Without parens this would parse as `a || (b |> Enum.any?(fun))`,
      # silently changing semantics. The formatter strips parens that
      # aren't needed, so over-wrapping is safe.
      assert_rewrites(
        @subject,
        "Enum.any?(filters[:type] || [], pred)",
        "(filters[:type] || []) |> Enum.any?(pred)"
      )
    end

    test "first arg is an `&&` expression — wrapped in parens" do
      assert_rewrites(
        @subject,
        "Enum.map(a && b, fun)",
        "(a && b) |> Enum.map(fun)"
      )
    end

    test "first arg is an `or` expression — wrapped in parens" do
      assert_rewrites(
        @subject,
        "Enum.count(xs or ys)",
        "(xs or ys) |> Enum.count()"
      )
    end

    test "first arg is `++` — wrapped in parens" do
      assert_rewrites(
        @subject,
        "Enum.map(xs ++ ys, fun)",
        "(xs ++ ys) |> Enum.map(fun)"
      )
    end
  end

  describe "Enum/Stream calls inside ^-pin" do
    # `^Enum.map(...)` in an Ecto query/changeset context: the pin
    # operator expects a literal value or a variable, not a pipe
    # expression. Even if Elixir would parse `^(coll |> Enum.map(fun))`
    # syntactically, Ecto's query macros don't accept it. Leave it.
    test "Enum call inside ^-pin stays put" do
      assert_unchanged(
        @subject,
        "Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens, & &1.id)))"
      )
    end

    test "bare ^Enum.map stays put" do
      assert_unchanged(@subject, "where(q, [t], t.id in ^Enum.map(items, & &1.id))")
    end

    test "Stream call inside ^-pin stays put" do
      assert_unchanged(@subject, "where(q, [t], t.id in ^Stream.map(items, & &1.id))")
    end

    # Outer Enum/Stream call is fine to extract; only the inner pinned
    # call is off-limits.
    test "outer extracts; inner pinned call stays" do
      assert_rewrites(
        @subject,
        "Enum.each(items, fn _ -> where(q, [t], t.id in ^Enum.map(items, & &1.id)) end)",
        "items |> Enum.each(fn _ -> where(q, [t], t.id in ^Enum.map(items, & &1.id)) end)"
      )
    end
  end

  describe "Enum/Stream calls inside &-capture" do
    # `&Enum.join(&1, ".")` — rewriting the inner call to
    # `& &1 |> Enum.join(".")` produces `&&1 |> Enum.join(".")` which
    # the lexer reads as `&&` (boolean and) followed by `1` — broken.
    # Same issue with any nested rewrite inside a capture.
    test "outer extracts; inner Enum.join inside &-capture stays put" do
      # Outer `Enum.map(parts, &Enum.join(&1, "."))` IS extractable
      # (call form, not in pipe). The inner `Enum.join` inside the `&`
      # is what we must skip — rewriting it to `& &1 |> Enum.join(".")`
      # produces `&&1 |> Enum.join(".")` which the lexer reads as
      # `&&` (boolean and) followed by `1`, which is broken.
      assert_rewrites(
        @subject,
        "Enum.map(parts, &Enum.join(&1, \".\"))",
        "parts |> Enum.map(&Enum.join(&1, \".\"))"
      )
    end

    # Three nested captures with Enum/Stream calls inside — none of
    # the inner ones may be extracted; only the outermost (which is
    # already in a pipe in this test) is.
    test "deeply nested Enum inside capture stays put across the chain" do
      assert_rewrites(
        @subject,
        "Enum.map(rows, &Enum.map(&1, &Enum.count/1))",
        "rows |> Enum.map(&Enum.map(&1, &Enum.count/1))"
      )
    end
  end

  describe "Enum/Stream calls inside pipe-unsafe ops" do
    # The OUTER call is an unsafe operand → not rewritten. But a
    # nested Enum call NOT in an unsafe slot is fine to rewrite.
    test "operator with Enum operand — operand stays; inner unrelated call extracts" do
      assert_unchanged(@subject, "Enum.map(list, fun) ++ Enum.map(other, fun)")
    end

    # When a deeper nested non-operand position is fine again.
    test "Enum call inside a function arg of a comparison's operand is fine" do
      # `Enum.count(list) > 0` — outer count is an unsafe operand,
      # but `wrap(Enum.map(list, fun)) > 0` has an inner Enum.map
      # that's a function arg (pipe-safe), so it CAN extract.
      assert_rewrites(
        @subject,
        "wrap(Enum.map(list, fun)) > 0",
        "wrap(list |> Enum.map(fun)) > 0"
      )
    end
  end

  describe "idempotent" do
    test "single rewrite is idempotent" do
      assert_idempotent(@subject, "Enum.map(list, fun)")
    end

    test "already piped is idempotent" do
      assert_idempotent(@subject, "list |> Enum.map(fun)")
    end
  end
end
