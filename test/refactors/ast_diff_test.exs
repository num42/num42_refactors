defmodule Num42.Refactors.AstDiffTest do
  use ExUnit.Case, async: true

  alias Num42.Refactors.AstDiff

  defp parse(src) do
    {:ok, ast} = Sourceror.parse_string(src)
    ast
  end

  describe "tree_diff/1 — identical inputs" do
    test "two identical ASTs produce zero holes" do
      a = parse("def f(x), do: g(x, 1)")
      b = parse("def f(x), do: g(x, 1)")

      assert %{holes: []} = AstDiff.tree_diff([a, b])
    end

    test "three identical ASTs produce zero holes" do
      a = parse("def f(x), do: g(x, 1)")
      b = parse("def f(x), do: g(x, 1)")
      c = parse("def f(x), do: g(x, 1)")

      assert %{holes: []} = AstDiff.tree_diff([a, b, c])
    end
  end

  describe "tree_diff/1 — single literal differences" do
    test "one int hole between two ASTs that differ only in an int literal" do
      a = parse("def f, do: 1")
      b = parse("def f, do: 2")

      assert %{holes: [hole]} = AstDiff.tree_diff([a, b])
      assert hole.kind == :literal
      assert length(hole.values) == 2
    end

    test "one atom hole" do
      a = parse("def f(x), do: tag(x, :foo)")
      b = parse("def f(x), do: tag(x, :bar)")

      assert %{holes: [hole]} = AstDiff.tree_diff([a, b])
      assert hole.kind == :literal
    end

    test "one string hole" do
      a = parse(~s|def f, do: "hi"|)
      b = parse(~s|def f, do: "ho"|)

      assert %{holes: [hole]} = AstDiff.tree_diff([a, b])
      assert hole.kind == :literal
    end

    test "one bool hole" do
      a = parse("def f, do: true")
      b = parse("def f, do: false")

      assert %{holes: [hole]} = AstDiff.tree_diff([a, b])
      assert hole.kind == :literal
    end
  end

  describe "tree_diff/1 — multiple holes" do
    test ~S(two literal holes for `{1, "a"}` vs `{2, "b"}`) do
      a = parse("def f, do: {1, \"a\"}")
      b = parse("def f, do: {2, \"b\"}")

      assert %{holes: holes} = AstDiff.tree_diff([a, b])
      assert length(holes) == 2
      assert holes |> Enum.all?(&(&1.kind == :literal))
    end

    test "three holes when three literals differ" do
      a = parse("def f, do: g(1, :a, \"x\")")
      b = parse("def f, do: g(2, :b, \"y\")")

      assert %{holes: holes} = AstDiff.tree_diff([a, b])
      assert length(holes) == 3
    end
  end

  describe "tree_diff/1 — :expr holes (formerly :complex, now parametrised)" do
    test "function-call divergence produces an :expr hole" do
      # The clones have the same outer shape (`String.<fn>(x)`) but
      # diverge at the function-name slot. The hole captures the
      # divergent subtree so callers can pass it as a parameter.
      a = parse("def f(x), do: String.upcase(x)")
      b = parse("def f(x), do: String.downcase(x)")

      assert %{holes: holes} = AstDiff.tree_diff([a, b])
      assert holes != []
      assert holes |> Enum.any?(&(&1.kind == :expr))
    end

    test "literal-vs-call mismatch produces an :expr hole" do
      a = parse("def f(x), do: tag(x, :foo)")
      b = parse("def f(x), do: tag(x, foo())")

      assert %{holes: holes} = AstDiff.tree_diff([a, b])
      assert holes |> Enum.any?(&(&1.kind == :expr))
    end

    test "module-attribute reference produces an :expr hole" do
      a = parse("def f(x), do: tag(x, @default)")
      b = parse("def f(x), do: tag(x, @custom)")

      assert %{holes: holes} = AstDiff.tree_diff([a, b])
      assert holes |> Enum.any?(&(&1.kind == :expr))
    end

    test "variable reference difference produces an :expr hole" do
      a = parse("def f(x, y), do: tag(x, x)")
      b = parse("def f(x, y), do: tag(x, y)")

      assert %{holes: holes} = AstDiff.tree_diff([a, b])
      assert holes |> Enum.any?(&(&1.kind == :expr))
    end
  end

  describe "tree_diff/2 — two-tree convenience form" do
    test "delegates to the N-ary variant" do
      a = parse("def f, do: tag(x, 1)")
      b = parse("def f, do: tag(x, 2)")

      assert AstDiff.tree_diff(a, b) == AstDiff.tree_diff([a, b])
    end

    test "two identical trees → zero holes" do
      a = parse("def f, do: 1")
      b = parse("def f, do: 1")

      assert %{holes: []} = AstDiff.tree_diff(a, b)
    end

    test "two trees with a single literal divergence → one :literal hole" do
      a = parse("def f(x), do: g(x, :foo)")
      b = parse("def f(x), do: g(x, :bar)")

      assert %{holes: [hole]} = AstDiff.tree_diff(a, b)
      assert hole.kind == :literal
      assert length(hole.values) == 2
    end

    test "structural divergence produces a hole" do
      a = parse("def f(x), do: String.upcase(x)")
      b = parse("def f(x), do: String.downcase(x)")

      assert %{holes: holes} = AstDiff.tree_diff(a, b)
      assert holes != []
    end
  end

  describe "tree_diff/1 — keyword-key divergence" do
    # Atom-key divergence in keyword pairs is now parametrised like
    # any other hole. The compiler is the source of truth — Ecto.Query
    # (and similar macros that need compile-time keyword keys) will
    # reject the rewritten code at compile time, which is the real
    # signal we want, not a pre-filter that masks the case.

    test "atom-key divergence in keyword pair produces a hole" do
      a = parse("def f, do: foo([order_by: :id, distinct: true])")
      b = parse("def f, do: foo([select: :id, distinct: true])")

      assert %{holes: holes} = AstDiff.tree_diff([a, b])
      assert holes != []
    end

    test "atom-value divergence in keyword pair → :literal" do
      a = parse("def f, do: foo([type: :foo])")
      b = parse("def f, do: foo([type: :bar])")

      assert %{holes: [hole]} = AstDiff.tree_diff([a, b])
      assert hole.kind == :literal
    end

    test "literal divergence in plain 2-tuple → :literal" do
      a = parse("def f, do: {1, \"a\"}")
      b = parse("def f, do: {2, \"b\"}")

      assert %{holes: holes} = AstDiff.tree_diff([a, b])
      assert length(holes) == 2
      assert holes |> Enum.all?(&(&1.kind == :literal))
    end
  end

  describe "tree_diff/1 — N > 2" do
    test "four identical ASTs — zero holes" do
      asts = 1..4 |> Enum.map(fn _ -> parse("def f, do: g(1)") end)
      assert %{holes: []} = AstDiff.tree_diff(asts)
    end

    test "four ASTs differing in one literal — one hole, four values" do
      asts =
        for n <- [1, 2, 3, 4] do
          parse("def f, do: g(#{n})")
        end

      assert %{holes: [hole]} = AstDiff.tree_diff(asts)
      assert length(hole.values) == 4
    end
  end

  describe "tree_diff/1 — pipeline-shape regressions" do
    # Pin down what AstDiff returns for the AST shapes ExtractParametricClone
    # actually feeds it: full function-body blocks (Sourceror's `:__block__`
    # wrapper around multi-statement bodies), Pipe operators, divergent
    # atoms at literal positions deep inside the tree.

    test "block body with single divergent atom literal — one :literal hole" do
      a =
        parse("""
        defp f(x, y) do
          base = thing(y, %{})
          process(x, base)
          |> Map.put(:action, :update)
        end
        """)

      b =
        parse("""
        defp f(x, y) do
          base = thing(y, %{})
          process(x, base)
          |> Map.put(:action, :insert)
        end
        """)

      # Pull body the same way ExtractParametricClone does it.
      {:defp, _, [_head, [{_, body_a}]]} = a
      {:defp, _, [_head, [{_, body_b}]]} = b

      result = AstDiff.tree_diff([body_a, body_b])
      assert %{holes: [hole]} = result, "expected exactly one hole, got: #{inspect(result.holes)}"

      assert hole.kind == :literal,
             "expected :literal classification (atom vs atom), got #{hole.kind}\nvalues:\n  A: #{inspect(hole.values |> Enum.at(0))}\n  B: #{inspect(hole.values |> Enum.at(1))}"
    end

    test "two clones with divergent atom in pipe RHS produce a literal hole, NOT a subtree hole" do
      # The hazard: AstDiff might treat the entire `Map.put(:action, X)`
      # subtree as the divergence and produce a single :expr hole, even
      # though only the trailing atom differs.
      a = parse("base |> Map.put(:action, :update)")
      b = parse("base |> Map.put(:action, :insert)")

      result = AstDiff.tree_diff([a, b])
      assert %{holes: holes} = result

      assert length(holes) == 1,
             "expected exactly 1 hole, got #{length(holes)}: #{inspect(holes)}"

      [hole] = holes

      assert hole.kind == :literal,
             "expected the divergence to be classified at the atom leaf (kind=:literal), not promoted to a subtree (kind=:expr). Got: kind=#{hole.kind}\n  val A: #{inspect(hole.values |> Enum.at(0))}\n  val B: #{inspect(hole.values |> Enum.at(1))}"
    end

    test "divergent atom INSIDE a block-wrapped multi-statement body is still :literal" do
      # Same as above but wrapped in a :__block__ (multi-statement body).
      a =
        parse("""
        base = setup(arg)
        base |> Map.put(:action, :update)
        """)

      b =
        parse("""
        base = setup(arg)
        base |> Map.put(:action, :insert)
        """)

      result = AstDiff.tree_diff([a, b])
      assert %{holes: [hole]} = result, "expected one hole, got: #{inspect(result.holes)}"

      assert hole.kind == :literal,
             "got kind=#{hole.kind}\nval A: #{inspect(hole.values |> Enum.at(0))}\nval B: #{inspect(hole.values |> Enum.at(1))}"
    end

    test "exact `map_item_errors_to_form_schema` clone shape from the codebase" do
      # Replays the production case that caused the `|> param_0`
      # compile error. AstDiff should see exactly one literal hole.
      a =
        parse("""
        defp map_item_errors_to_form_schema(item_cs, %FormSchema{} = form_schema) do
          base = FormSchema.changeset(form_schema, %{})

          Enum.reduce(item_cs.errors, base, fn {field, {msg, opts}}, acc ->
            Ecto.Changeset.add_error(acc, field, msg, opts)
          end)
          |> Map.put(:action, :update)
        end
        """)

      b =
        parse("""
        defp map_item_errors_to_form_schema(item_cs, %FormSchema{} = form_schema) do
          base = FormSchema.changeset(form_schema, %{})

          Enum.reduce(item_cs.errors, base, fn {field, {msg, opts}}, acc ->
            Ecto.Changeset.add_error(acc, field, msg, opts)
          end)
          |> Map.put(:action, :insert)
        end
        """)

      {:defp, _, [_head, [{_, body_a}]]} = a
      {:defp, _, [_head, [{_, body_b}]]} = b

      result = AstDiff.tree_diff([body_a, body_b])

      assert length(result.holes) == 1,
             "expected exactly 1 hole, got #{length(result.holes)}: #{inspect(result.holes |> Enum.map(& &1.kind))}"

      [hole] = result.holes

      assert hole.kind == :literal,
             "expected :literal (the divergence is the trailing :update / :insert atom), got #{hole.kind}\nvalues:\n  A: #{Sourceror.to_string(hole.values |> Enum.at(0))}\n  B: #{Sourceror.to_string(hole.values |> Enum.at(1))}"
    end

    test "clones at DIFFERENT line numbers — meta divergence in form-tuple must not block descent" do
      # The production hazard: same skeleton, different source positions
      # → the `form` tuple of `Map.put` carries `line: 168` vs `line: 178`
      # in its meta; if same_outer_shape? compares forms with `==`, the
      # whole subtree gets promoted to a hole. Force this by parsing two
      # heredocs whose Map.put sits at different line numbers.
      a =
        parse("""
        defp f(x, y) do
          base = thing(y, %{})

          process(x, base)
          |> Map.put(:action, :update)
        end
        """)

      b =
        parse("""
        defp f(x, y) do
          base = thing(y, %{})

          # extra leading comment to push the pipe one line down
          process(x, base)
          |> Map.put(:action, :insert)
        end
        """)

      {:defp, _, [_head, [{_, body_a}]]} = a
      {:defp, _, [_head, [{_, body_b}]]} = b

      result = AstDiff.tree_diff([body_a, body_b])

      assert length(result.holes) == 1,
             "expected exactly 1 hole, got #{length(result.holes)}: #{inspect(result.holes |> Enum.map(& &1.kind))}"

      [hole] = result.holes

      assert hole.kind == :literal,
             "expected :literal (only the trailing atom diverges) — meta divergence in the call's form-tuple must not promote the subtree to :expr. Got #{hole.kind}\n  A: #{Sourceror.to_string(hole.values |> Enum.at(0))}\n  B: #{Sourceror.to_string(hole.values |> Enum.at(1))}"
    end

    test "MIXED bucket: 2 pipe-rhs clones + 2 unrelated-but-same-shape produce subtree :expr hole" do
      # Hypothesis: when the aggressive skeleton hash buckets clones
      # whose outer shape matches but whose pipe-RHS calls actually
      # diverge (different function names), AstDiff sees the entire
      # `Module.fn(args)` subtree as a hole — kind=:expr, not :literal.
      # That subtree-hole is what produces the broken `|> param_0` at
      # the call-site.
      a = parse("base |> Map.put(:action, :update)")
      b = parse("base |> Map.put(:action, :insert)")
      c = parse("base |> Map.merge(other_map)")
      d = parse("base |> Map.delete(:foo)")

      result = AstDiff.tree_diff([a, b, c, d])

      assert result.holes != [], "expected at least one hole"

      # Document what actually happens — failing this test is a
      # regression *finding*, not a bug.
      hole_kinds = result.holes |> Enum.map(& &1.kind)

      assert :expr in hole_kinds or :data in hole_kinds,
             "with 4 mixed clones, expected at least one non-literal hole (since the call-args differ in arity/shape between clones). Got: #{inspect(hole_kinds)}"
    end
  end
end
