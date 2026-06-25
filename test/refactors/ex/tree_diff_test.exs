defmodule Number42.Refactors.Ex.TreeDiffTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Ex.TreeDiff

  # Parse a `def`'s do-body to the raw AST the detector feeds TreeDiff.normalize/1.
  # Sourceror wraps the `do` key as `{:__block__, _, [:do]}` for both the block
  # and the `do:`-shorthand form, so match on the unwrapped key.
  defp body(src) do
    {:ok, {:def, _, [_head, body_kw]}} = Sourceror.parse_string(src)

    Enum.find_value(body_kw, fn {key, value} ->
      if unwrap(key) == :do, do: value
    end)
  end

  defp unwrap({:__block__, _, [k]}), do: k
  defp unwrap(k), do: k

  defp norm(src), do: src |> body() |> TreeDiff.normalize()

  describe "normalize/1 — α-renaming and pipe-sugar" do
    test "two bodies differing only in local names normalize equal" do
      a = norm("def f(order), do: (s = Enum.sum(order.lines); s * 1.19)")
      b = norm("def f(cart), do: (s = Enum.sum(cart.lines); s * 1.19)")
      assert TreeDiff.distance(a, b) == 0
    end

    test "pipe and nested call normalize equal" do
      a = norm("def f(x), do: Enum.sum(x.lines)")
      b = norm("def f(x), do: x.lines |> Enum.sum()")
      assert TreeDiff.distance(a, b) == 0
    end

    test "identical bodies score similarity 1.0" do
      a = norm("def f(x), do: (y = x + 1; y * 2)")
      assert TreeDiff.similarity(a, a) == 1.0
    end
  end

  describe "distance/2 — single liftable divergences" do
    test "one differing literal costs 1" do
      a = norm("def f(x), do: x * 1.19")
      b = norm("def f(x), do: x * 1.07")
      assert TreeDiff.distance(a, b) == 1
    end

    test "one swapped operator costs 1" do
      a = norm("def f(x), do: x + 1")
      b = norm("def f(x), do: x - 1")
      assert TreeDiff.distance(a, b) == 1
    end

    test "one different call form costs 1" do
      a = norm("def f(x), do: Enum.sum(x)")
      b = norm("def f(x), do: Enum.count(x)")
      assert TreeDiff.distance(a, b) == 1
    end
  end

  describe "distance/2 — structural edits" do
    test "an extra statement costs its mass (insert)" do
      a = norm("def f(x), do: (a = g(x); a)")
      b = norm("def f(x), do: (a = g(x); b = h(x); a)")
      assert TreeDiff.distance(a, b) > 0
    end

    test "a kind change (literal vs call) costs 1 relabel" do
      a = norm("def f(_x), do: 1")
      b = norm("def f(x), do: g(x)")
      assert TreeDiff.distance(a, b) >= 1
    end
  end

  describe "similarity/2" do
    test "two ~90%-equal bodies land >= 0.85" do
      a =
        norm("""
        def total(order) do
          subtotal = Enum.sum(order.lines)
          taxed = subtotal * 1.19
          rounded = Float.round(taxed, 2)
          {subtotal, taxed, rounded}
        end
        """)

      b =
        norm("""
        def total(cart) do
          subtotal = Enum.sum(cart.lines)
          taxed = subtotal * 1.07
          rounded = Float.round(taxed, 2)
          {subtotal, taxed, rounded}
        end
        """)

      sim = TreeDiff.similarity(a, b)
      assert sim >= 0.85
      assert sim < 1.0
    end

    test "similarity never goes negative" do
      a = norm("def f(_x), do: 1")
      b = norm("def f(x), do: (a = Enum.map(x, &g/1); Enum.reduce(a, 0, &+/2))")
      assert TreeDiff.similarity(a, b) >= 0.0
    end
  end

  describe "diff/2 — typed divergence descriptor" do
    test "identical trees produce no divergence" do
      a = norm("def f(x), do: x + 1")
      assert TreeDiff.diff(a, a) == []
    end

    test "a changed literal is reported as :literal" do
      a = norm("def f(x), do: x * 1.19")
      b = norm("def f(x), do: x * 1.07")
      assert [{:literal, _path, 1.19, 1.07}] = TreeDiff.diff(a, b)
    end

    test "a swapped operator is reported as :call" do
      a = norm("def f(x), do: x + 1")
      b = norm("def f(x), do: x - 1")
      assert [{:call, _path, :+, :-}] = TreeDiff.diff(a, b)
    end

    test "an inserted statement is reported as structural" do
      a = norm("def f(x), do: (a = g(x); a)")
      b = norm("def f(x), do: (a = g(x); b = h(x); a)")
      diffs = TreeDiff.diff(a, b)
      assert Enum.any?(diffs, &match?({:structural, _, op} when op in [:insert, :delete], &1))
    end

    test "a kind change is reported as structural" do
      a = norm("def f(_x), do: 1")
      b = norm("def f(x), do: g(x)")
      diffs = TreeDiff.diff(a, b)
      assert Enum.any?(diffs, &match?({:structural, _, :kind_change}, &1))
    end
  end
end
