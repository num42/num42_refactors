defmodule Number42.Refactors.Ex.MergePipelineIntoComprehensionTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.MergePipelineIntoComprehension

  @subject MergePipelineIntoComprehension

  # NOTE on test bodies: the fusion is gated on `AstHelpers.pure?/1`,
  # which deliberately treats map/struct dot-access (`x.field`) and
  # `&1.field` captures as IMPURE (KeyError on a missing key). So the
  # positive-rewrite fixtures here use genuinely pure bodies —
  # arithmetic, comparisons, `Map.get`, guards. `.field`-based pipelines
  # are exercised in the "leaves alone — impure" section, where they
  # correctly SKIP.

  describe "rewrites — capture form" do
    test "anon-capture pred and map fuse into a for comprehension" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(coll) do
            coll
            |> Enum.filter(&(&1 > 0))
            |> Enum.map(&(&1 * 2))
          end
        end
        """,
        """
        defmodule M do
          def go(coll) do
            for x <- coll, x > 0, do: x * 2
          end
        end
        """
      )
    end

    test "pred is an arbitrary expression, not a guard-only form" do
      # `for` filters allow ANY expression — `String.contains?/2` is not a
      # guard but is a perfectly valid (and pure) filter. The rewrite must
      # not be restricted to guard-safe predicates.
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(coll) do
            coll
            |> Enum.filter(&String.contains?(&1, "x"))
            |> Enum.map(&String.upcase(&1))
          end
        end
        """,
        """
        defmodule M do
          def go(coll) do
            for x <- coll, String.contains?(x, "x"), do: String.upcase(x)
          end
        end
        """
      )
    end
  end

  describe "rewrites — fn lambda form" do
    test "named single-clause lambdas fuse, binding kept" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(coll) do
            coll
            |> Enum.filter(fn item -> item > 0 end)
            |> Enum.map(fn item -> item * 2 end)
          end
        end
        """,
        """
        defmodule M do
          def go(coll) do
            for item <- coll, item > 0, do: item * 2
          end
        end
        """
      )
    end

    test "differing lambda param names are unified to one generator binding" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(coll) do
            coll
            |> Enum.filter(fn a -> a > 0 end)
            |> Enum.map(fn b -> b + 1 end)
          end
        end
        """,
        """
        defmodule M do
          def go(coll) do
            for a <- coll, a > 0, do: a + 1
          end
        end
        """
      )
    end

    test "mixed forms — capture pred, lambda map" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(coll) do
            coll
            |> Enum.filter(&(&1 > 0))
            |> Enum.map(fn r -> r + 1 end)
          end
        end
        """,
        """
        defmodule M do
          def go(coll) do
            for r <- coll, r > 0, do: r + 1
          end
        end
        """
      )
    end

    test "two independent chains in one module both fuse" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def one(a) do
            a |> Enum.filter(&(&1 > 0)) |> Enum.map(&(&1 + 1))
          end

          def two(b) do
            b |> Enum.filter(&(&1 < 9)) |> Enum.map(&(&1 - 1))
          end
        end
        """,
        """
        defmodule M do
          def one(a) do
            for x <- a, x > 0, do: x + 1
          end

          def two(b) do
            for x <- b, x < 9, do: x - 1
          end
        end
        """
      )
    end

    test "pure Map.get bodies fuse" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(coll) do
            coll
            |> Enum.filter(fn m -> Map.has_key?(m, :id) end)
            |> Enum.map(fn m -> Map.get(m, :id) end)
          end
        end
        """,
        """
        defmodule M do
          def go(coll) do
            for m <- coll, Map.has_key?(m, :id), do: Map.get(m, :id)
          end
        end
        """
      )
    end
  end

  describe "capture collision avoidance" do
    test "chosen generator binding does not shadow an outer var used in the other body" do
      # The map body references outer var `x`. The pred lambda's param is
      # `x` too. Naively unifying to `x` would capture the outer `x`, so
      # the rewrite must pick a non-colliding generator name. Here `x` is
      # read by the map body, so the pred param `x` is rejected and the
      # map param `n` (not read by the pred body) is used instead.
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(coll, x) do
            coll
            |> Enum.filter(fn x -> x > 0 end)
            |> Enum.map(fn n -> n + x end)
          end
        end
        """,
        """
        defmodule M do
          def go(coll, x) do
            for n <- coll, n > 0, do: n + x
          end
        end
        """
      )
    end

    test "falls back to a fresh name when both params collide with outer reads" do
      # Both lambda params (`a`, `b`) are also read as outer vars by the
      # other body, so neither can be reused — a fresh `x` is generated.
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(coll, a, b) do
            coll
            |> Enum.filter(fn a -> a > b end)
            |> Enum.map(fn b -> b + a end)
          end
        end
        """,
        """
        defmodule M do
          def go(coll, a, b) do
            for x <- coll, x > b, do: x + a
          end
        end
        """
      )
    end
  end

  describe "leaves alone — impure pred or map (interleaving is observable)" do
    test "map/struct dot-access pred (KeyError-capable, impure) is not fused" do
      # `& &1.active` is impure by `pure?/1` (dot-access can raise
      # KeyError). filter|>map batches; for interleaves — observably
      # different if the access raises. Decline.
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.filter(& &1.active)
          |> Enum.map(& &1.id)
        end
      end
      """)
    end

    test "side-effecting map (IO.inspect) is not fused" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.filter(&(&1 > 0))
          |> Enum.map(&IO.inspect(&1))
        end
      end
      """)
    end

    test "side-effecting pred (send) is not fused" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.filter(fn x -> send(self(), x) && x > 0 end)
          |> Enum.map(&(&1 + 1))
        end
      end
      """)
    end

    test "raising pred (String.to_integer) is not fused" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.filter(fn x -> String.to_integer(x) > 0 end)
          |> Enum.map(&(&1 + 1))
        end
      end
      """)
    end

    test "unknown remote call in map is treated impure and not fused" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.filter(&(&1 > 0))
          |> Enum.map(fn x -> MyMod.transform(x) end)
        end
      end
      """)
    end

    test "division in pred (zero-divisor raises) is not fused" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.filter(fn x -> 10 / x > 1 end)
          |> Enum.map(&(&1 + 1))
        end
      end
      """)
    end
  end

  describe "leaves alone — unsupported shapes" do
    test "function-reference capture (&name/1) has no body to splice" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.filter(&active?/1)
          |> Enum.map(&double/1)
        end
      end
      """)
    end

    test "multi-clause lambda" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.filter(fn
            1 -> true
            _ -> false
          end)
          |> Enum.map(&(&1 + 1))
        end
      end
      """)
    end

    test "lambda with a guard" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.filter(fn x when is_integer(x) -> x > 0 end)
          |> Enum.map(&(&1 + 1))
        end
      end
      """)
    end

    test "multi-statement lambda body" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.filter(fn x ->
            v = x + 1
            v > 0
          end)
          |> Enum.map(&(&1 + 1))
        end
      end
      """)
    end

    test "collection is itself a pipe — would emit a pipe in the generator head" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.uniq()
          |> Enum.filter(&(&1 > 0))
          |> Enum.map(&(&1 + 1))
        end
      end
      """)
    end

    test "Enum.map is not preceded by Enum.filter" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.sort()
          |> Enum.map(&(&1 + 1))
        end
      end
      """)
    end

    test "filter then map with extra stage between is not the target shape" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.filter(&(&1 > 0))
          |> Enum.sort()
          |> Enum.map(&(&1 + 1))
        end
      end
      """)
    end

    test "wrong namespace — MyEnum.filter |> MyEnum.map" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> MyEnum.filter(&(&1 > 0))
          |> MyEnum.map(&(&1 + 1))
        end
      end
      """)
    end

    test "filter with two args (arity mismatch) is not the capture/lambda shape" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.filter(some_pred, extra)
          |> Enum.map(&(&1 + 1))
        end
      end
      """)
    end

    test "multi-arg capture (&2) in pred is not single-binding fusable" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.filter(&(&1 > &2))
          |> Enum.map(&(&1 + 1))
        end
      end
      """)
    end
  end

  describe "leaves alone — quote blocks" do
    test "chain inside quote do … end is not rewritten" do
      assert_unchanged(@subject, """
      defmodule M do
        defmacro build(coll) do
          quote do
            unquote(coll)
            |> Enum.filter(&(&1 > 0))
            |> Enum.map(&(&1 + 1))
          end
        end
      end
      """)
    end
  end

  describe "rewrites — reject form" do
    test "operator-rooted reject pred fuses with parenthesized bang-negation" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(coll) do
            coll
            |> Enum.reject(&(&1 > 0))
            |> Enum.map(&(&1 * 2))
          end
        end
        """,
        """
        defmodule M do
          def go(coll) do
            for x <- coll, !(x > 0), do: x * 2
          end
        end
        """
      )
    end

    test "call-rooted reject pred negates without parens" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(coll) do
            coll
            |> Enum.reject(fn m -> Map.has_key?(m, :id) end)
            |> Enum.map(fn m -> Map.get(m, :id) end)
          end
        end
        """,
        """
        defmodule M do
          def go(coll) do
            for m <- coll, !Map.has_key?(m, :id), do: Map.get(m, :id)
          end
        end
        """
      )
    end
  end

  describe "leaves alone — reject shapes" do
    test "impure reject pred (dot-access) is not fused" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.reject(& &1.active)
          |> Enum.map(& &1.id)
        end
      end
      """)
    end

    test "function-reference reject capture has no body to splice" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&double/1)
        end
      end
      """)
    end

    test "reject without a downstream map" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll) do
          coll |> Enum.reject(&(&1 > 0))
        end
      end
      """)
    end
  end

  describe "idempotent — reject form" do
    test "reject rewrite is idempotent" do
      assert_idempotent(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.reject(&(&1 > 0))
          |> Enum.map(&(&1 * 2))
        end
      end
      """)
    end
  end

  describe "idempotent" do
    test "capture-form rewrite is idempotent" do
      assert_idempotent(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.filter(&(&1 > 0))
          |> Enum.map(&(&1 * 2))
        end
      end
      """)
    end

    test "lambda-form rewrite is idempotent" do
      assert_idempotent(@subject, """
      defmodule M do
        def go(coll) do
          coll
          |> Enum.filter(fn item -> item > 0 end)
          |> Enum.map(fn item -> item * 2 end)
        end
      end
      """)
    end

    test "already a for comprehension is left untouched" do
      assert_idempotent(@subject, """
      defmodule M do
        def go(coll) do
          for x <- coll, x > 0, do: x * 2
        end
      end
      """)
    end
  end
end
