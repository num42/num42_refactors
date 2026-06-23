defmodule Number42.Refactors.Ex.InlineSingleUseBindingTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.InlineSingleUseBinding

  @subject InlineSingleUseBinding

  # The refactor is enabled by default and takes no opts; `@on` is the
  # empty opts list, passed where a test wants to be explicit about it.
  @on []

  describe "rewrites — canonical inline" do
    test "inlines a use-once, read-never-after binding into its single use" do
      before_source = """
      defmodule M do
        def f(x) do
          result = Map.get(x, :a)
          use_it(result)
        end
      end
      """

      after_source = """
      defmodule M do
        def f(x) do
          use_it(Map.get(x, :a))
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "wraps the inlined RHS in parens to preserve precedence" do
      before_source = """
      defmodule M do
        def f(a, b) do
          sum = a + b
          sum * 2
        end
      end
      """

      after_source = """
      defmodule M do
        def f(a, b) do
          (a + b) * 2
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    # Regression: an inlined pipe spliced into an operator operand must
    # be parenthesised. `++` binds tighter than `|>`, so without parens
    # `ids ++ items |> Enum.map(f)` re-associates as
    # `(ids ++ items) |> Enum.map(f)` — the map captures the whole
    # concatenation instead of just `items`, changing the result.
    test "wraps an inlined pipe RHS spliced into an operator operand" do
      before_source = """
      defmodule M do
        def f(ids, items) do
          mapped = items |> Enum.map(fn {_, id} -> id end)
          ids ++ mapped
        end
      end
      """

      after_source = """
      defmodule M do
        def f(ids, items) do
          ids ++ (items |> Enum.map(fn {_, id} -> id end))
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    # The same pipe RHS spliced into a *call argument* (self-delimiting)
    # needs no parens — the comma/bracket bounds it.
    test "leaves an inlined pipe RHS unparenthesised in a call argument" do
      before_source = """
      defmodule M do
        def f(items, map) do
          key = items |> Enum.join(".")
          Map.get(map, key)
        end
      end
      """

      after_source = """
      defmodule M do
        def f(items, map) do
          Map.get(map, items |> Enum.join("."))
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end

    test "inlines from the middle of a block, leaving surrounding statements" do
      before_source = """
      defmodule M do
        def f(x) do
          a = first(x)
          b = String.upcase(x)
          combine(a, b)
        end
      end
      """

      # `b` is the use-once/read-never-after binding adjacent to its use.
      after_source = """
      defmodule M do
        def f(x) do
          a = first(x)
          combine(a, String.upcase(x))
        end
      end
      """

      assert_rewrites(@subject, before_source, after_source, @on)
    end
  end

  describe "skips unsafe inlines" do
    test "skips when the binding is read more than once" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            r = Map.get(x, :a)
            r + r
          end
        end
        """,
        @on
      )
    end

    test "skips when the binding is read by a later statement" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            r = Map.get(x, :a)
            first(r)
            second(r)
          end
        end
        """,
        @on
      )
    end

    test "skips when the RHS is impure (could raise)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(s) do
            n = String.to_integer(s)
            use_it(n)
          end
        end
        """,
        @on
      )
    end

    test "skips when the RHS performs a side effect" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            r = IO.inspect(x)
            use_it(r)
          end
        end
        """,
        @on
      )
    end

    test "skips a pattern-match LHS (not a simple binding)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            {:ok, r} = fetch(x)
            use_it(r)
          end
        end
        """,
        @on
      )
    end

    test "skips when the use is not adjacent to the binding" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            r = Map.get(x, :a)
            unrelated()
            use_it(r)
          end
        end
        """,
        @on
      )
    end

    test "skips when the binding is never read at all (dead binding)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            r = Map.get(x, :a)
            other(x)
          end
        end
        """,
        @on
      )
    end

    test "skips a single-expression body (nothing to inline into)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x), do: Map.get(x, :a)
        end
        """,
        @on
      )
    end

    # Inlining `if`/`case`/`cond`/`with`/`fn`/`unless` splices a body
    # carrying do:/else: keywords into a larger term; the trailing
    # keywords bleed out and the result no longer parses (e.g. into a
    # tuple: `{^if x, do: :a, else: :b, rest}`).
    test "skips an if-expression RHS" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            dir = if x == :asc, do: :asc_nulls_last, else: :desc_nulls_last
            order(dir)
          end
        end
        """,
        @on
      )
    end

    test "skips a case-expression RHS" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            v =
              case x do
                1 -> :a
                _ -> :b
              end

            use_it(v)
          end
        end
        """,
        @on
      )
    end

    # A short-circuit operator at the RHS root is a deliberate
    # default/guard pattern — the name marks "value-or-its-fallback".
    # Inlining buries that intent in a call argument, so skip.
    test "skips a fallback-operator RHS (||)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            tags = Map.get(x, :tags) || []
            render(tags)
          end
        end
        """,
        @on
      )
    end

    test "skips an and/&&-guard RHS" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            ok = Map.get(x, :ready) && Map.get(x, :enabled)
            use_it(ok)
          end
        end
        """,
        @on
      )
    end

    # A multi-line map/struct/list RHS, inlined, gets crammed into a
    # call argument and reads worse than the named binding. Leave it.
    test "skips a multi-line literal RHS" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            labels = %{
              a: "alpha",
              b: "beta"
            }

            Map.get(labels, x, "?")
          end
        end
        """,
        @on
      )
    end

    # The sole read sits behind a `^` pin (Ecto query / match pin).
    # Splicing lands an expression at the pin position (`^(expr)`),
    # which is illegal — leave the binding in place.
    test "skips a use behind a pin (^var)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def f(x) do
            dir = Map.get(x, :dir)
            from(r in q, order_by: [{^dir, r.id}])
          end
        end
        """,
        @on
      )
    end
  end

  describe "idempotence & compilation" do
    test "stable after one inline" do
      assert_idempotent(
        @subject,
        """
        defmodule M do
          def f(x) do
            r = Map.get(x, :a)
            use_it(r)
          end
        end
        """,
        @on
      )
    end

    test "output compiles" do
      source = """
      defmodule InlineSingleUseBindingCompileCheck do
        def f(a, b) do
          sum = a + b
          sum * 2
        end
      end
      """

      assert_compiles(apply_refactor(@subject, source, @on))
    end
  end
end
