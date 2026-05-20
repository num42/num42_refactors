defmodule Num42.Refactors.Refactors.MapNewToPipeTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.MapNewToPipe

  @subject MapNewToPipe

  describe "rewrites" do
    test "Map.new(var) -> var |> Map.new()" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(coll), do: Map.new(coll)
        end
        """,
        """
        defmodule M do
          def go(coll), do: coll |> Map.new()
        end
        """
      )
    end

    test "Map.new(call) -> call |> Map.new()" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(x), do: Map.new(transform(x))
        end
        """,
        """
        defmodule M do
          def go(x), do: transform(x) |> Map.new()
        end
        """
      )
    end

    test "Map.new(remote_call) -> remote_call |> Map.new()" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(x), do: Map.new(Enum.zip(keys, values))
        end
        """,
        """
        defmodule M do
          def go(x), do: Enum.zip(keys, values) |> Map.new()
        end
        """
      )
    end

    test "Map.new(coll || fallback) — wraps `||` in parens to bind |> correctly" do
      # Without parens this would parse as `coll || (fallback |> Map.new())`,
      # silently changing semantics. The formatter strips redundant parens.
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(items), do: Map.new(items || [])
        end
        """,
        """
        defmodule M do
          def go(items), do: (items || []) |> Map.new()
        end
        """
      )
    end

    test "Map.new(xs ++ ys) — wraps `++` in parens" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(xs, ys), do: Map.new(xs ++ ys)
        end
        """,
        """
        defmodule M do
          def go(xs, ys), do: (xs ++ ys) |> Map.new()
        end
        """
      )
    end
  end

  describe "leaves alone" do
    test "Map.new(%{...}) — map literal would read worse as a pipe" do
      assert_unchanged(@subject, """
      defmodule M do
        def go, do: Map.new(%{a: 1})
      end
      """)
    end

    test "Map.new([...]) — list literal would read worse as a pipe" do
      assert_unchanged(@subject, """
      defmodule M do
        def go, do: Map.new([{:a, 1}, {:b, 2}])
      end
      """)
    end

    test "Map.new([]) — empty list literal" do
      assert_unchanged(@subject, """
      defmodule M do
        def go, do: Map.new([])
      end
      """)
    end

    test "Map.new(coll, fn ...) — arity-2 form is a different transformation" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll), do: Map.new(coll, fn {k, v} -> {k, v + 1} end)
      end
      """)
    end

    test "Map.new() — arity-0 (build empty map)" do
      assert_unchanged(@subject, """
      defmodule M do
        def go, do: Map.new()
      end
      """)
    end

    test "already piped: x |> Map.new()" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(x), do: x |> Map.new()
      end
      """)
    end

    test "pipe into arity-2 Map.new(fn ...) — fn is not a collection" do
      # `x |> Map.new(fn k -> ... end)` parses with `Map.new` as
      # arity-1 (the lambda). Without the fn-skip the refactor would
      # treat the lambda as `coll` and produce
      # `x |> fn ... end |> Map.new()` — nonsense.
      assert_unchanged(@subject, """
      defmodule M do
        def go(items) do
          items
          |> Enum.group_by(& &1.k, & &1)
          |> Map.new(fn {k, vs} -> {k, length(vs)} end)
        end
      end
      """)
    end

    test "Map.new(fn ...) standalone — also a lambda, not a collection" do
      assert_unchanged(@subject, """
      defmodule M do
        def go, do: Map.new(fn -> [a: 1] end)
      end
      """)
    end

    test "pipe into arity-2 Map.new(&capture) — same hazard as fn" do
      # `x |> Map.new(&{&1.name(), &1})` parses with `Map.new` as
      # arity-1 with the capture as the only arg. Treating it as
      # `coll` would produce `x |> (&{...}) |> Map.new()` — invalid.
      assert_unchanged(@subject, """
      defmodule M do
        def go(orgs) do
          orgs
          |> list_functions()
          |> Map.new(&{&1.name(), &1})
        end
      end
      """)
    end

    test "Map.new(&capture) standalone — capture is not a collection" do
      assert_unchanged(@subject, """
      defmodule M do
        def go, do: Map.new(&build_pair/1)
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      defmodule M do
        def go(coll), do: Map.new(coll)
      end
      """)
    end
  end
end
