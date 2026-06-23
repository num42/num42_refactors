defmodule Number42.Refactors.Ex.TopologicallyClusterIndependentBindingsTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.TopologicallyClusterIndependentBindings

  @subject TopologicallyClusterIndependentBindings

  # Enabled by default and takes no opts; `@on` is the empty opts list.
  @on []

  describe "rewrites — clustering independent bindings by family" do
    test "reorders two independent siblings so same-family ops cluster (issue example)" do
      before_source = """
      defmodule M do
        def bla() do
          bind1 = Map.put(%{}, 2, 3)
          bind2 = Map.get(bind1, 1)
          bind3 = Map.put(bind1, 3, 4)

          {bind2, bind3}
        end
      end
      """

      after_source = """
      defmodule M do
        def bla() do
          bind1 = Map.put(%{}, 2, 3)
          bind3 = Map.put(bind1, 3, 4)
          bind2 = Map.get(bind1, 1)

          {bind2, bind3}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "clusters by family; ready siblings break ties on family key" do
      # `a` (Map.put/3) and `b` (Keyword.put/3) are both ready first; with no
      # last-family yet, family key decides — "Keyword.put/3" < "Map.put/3",
      # so `b` leads. `c` then depends on `a` and continues the Map family.
      before_source = """
      defmodule M do
        def f(opts) do
          a = Map.put(%{}, :x, 1)
          b = Keyword.put([], :y, 2)
          c = Map.put(a, :z, 3)

          {a, b, c}
        end
      end
      """

      after_source = """
      defmodule M do
        def f(opts) do
          b = Keyword.put([], :y, 2)
          a = Map.put(%{}, :x, 1)
          c = Map.put(a, :z, 3)

          {a, b, c}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "a piped stage clusters with the equivalent direct call (arity normalised)" do
      # `bind2`'s `bind1 |> Map.put(9, 9)` normalises to `Map.put/3`, the
      # same family as the direct `Map.put(bind1, 3, 4)` of `bind3`, so the
      # two Map.put lines cluster ahead of the lone `Map.get`.
      before_source = """
      defmodule M do
        def f() do
          bind1 = Map.put(%{}, 2, 3)
          bind2 = Map.get(bind1, 1)
          bind3 = bind1 |> Map.put(9, 9)

          {bind2, bind3}
        end
      end
      """

      after_source = """
      defmodule M do
        def f() do
          bind1 = Map.put(%{}, 2, 3)
          bind3 = bind1 |> Map.put(9, 9)
          bind2 = Map.get(bind1, 1)

          {bind2, bind3}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end
  end

  describe "leaves code alone — data dependency forbids reorder" do
    test "a binding that reads an earlier binding never moves before it" do
      source = """
      defmodule M do
        def f() do
          a = Map.put(%{}, 1, 2)
          b = Map.get(a, 1)

          {a, b}
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "already-clustered window is untouched" do
      source = """
      defmodule M do
        def f() do
          a = Map.put(%{}, 1, 2)
          b = Map.put(a, 3, 4)
          c = Map.get(a, 1)

          {b, c}
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "a transitive chain (a -> b -> c) keeps its order" do
      source = """
      defmodule M do
        def f() do
          a = Map.put(%{}, 1, 2)
          b = Map.put(a, 3, 4)
          c = Map.get(b, 1)

          {a, b, c}
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end
  end

  describe "leaves code alone — safety gates" do
    test "skips when any RHS is impure (side-effecting call)" do
      source = """
      defmodule M do
        def f() do
          a = Map.put(%{}, 1, 2)
          b = IO.inspect(a)
          c = Map.put(a, 3, 4)

          {a, b, c}
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "skips when a window statement is a bang call (may raise)" do
      source = """
      defmodule M do
        def f(opts) do
          a = Map.put(%{}, 1, 2)
          b = Map.fetch!(opts, :k)
          c = Map.put(a, 3, 4)

          {a, b, c}
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "skips a window that rebinds the same variable" do
      source = """
      defmodule M do
        def f() do
          a = Map.put(%{}, 1, 2)
          a = Map.put(a, 3, 4)
          b = Map.get(a, 1)

          {a, b}
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "skips a non-bare LHS (destructuring pattern)" do
      source = """
      defmodule M do
        def f(opts) do
          a = Map.put(%{}, 1, 2)
          {b, c} = Map.split(opts, [:k])
          d = Map.put(a, 3, 4)

          {a, b, c, d}
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "skips a window containing an anonymous function" do
      source = """
      defmodule M do
        def f() do
          a = Map.put(%{}, 1, 2)
          b = fn x -> x end
          c = Map.put(a, 3, 4)

          {a, b, c}
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "skips when a moving statement carries an attached comment" do
      source = """
      defmodule M do
        def f() do
          bind1 = Map.put(%{}, 2, 3)
          # keep this comment with bind2
          bind2 = Map.get(bind1, 1)
          bind3 = Map.put(bind1, 3, 4)

          {bind2, bind3}
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "runs by default (no enable opt needed)" do
      before_source = """
      defmodule M do
        def bla() do
          bind1 = Map.put(%{}, 2, 3)
          bind2 = Map.get(bind1, 1)
          bind3 = Map.put(bind1, 3, 4)

          {bind2, bind3}
        end
      end
      """

      after_source = """
      defmodule M do
        def bla() do
          bind1 = Map.put(%{}, 2, 3)
          bind3 = Map.put(bind1, 3, 4)
          bind2 = Map.get(bind1, 1)

          {bind2, bind3}
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, [])
    end
  end

  describe "idempotence & compilation" do
    test "idempotent on the reorderable example" do
      source = """
      defmodule M do
        def bla() do
          bind1 = Map.put(%{}, 2, 3)
          bind2 = Map.get(bind1, 1)
          bind3 = Map.put(bind1, 3, 4)

          {bind2, bind3}
        end
      end
      """

      assert_idempotent(@subject, source, @on)
    end

    test "idempotent on already-clustered code" do
      source = """
      defmodule M do
        def f() do
          a = Map.put(%{}, 1, 2)
          b = Map.put(a, 3, 4)
          c = Map.get(a, 1)

          {b, c}
        end
      end
      """

      assert_idempotent(@subject, source, @on)
    end

    test "output compiles" do
      source = """
      defmodule M do
        def bla() do
          bind1 = Map.put(%{}, 2, 3)
          bind2 = Map.get(bind1, 1)
          bind3 = Map.put(bind1, 3, 4)

          {bind2, bind3}
        end
      end
      """

      assert_compiles(apply_refactor(@subject, source, @on))
    end
  end
end
