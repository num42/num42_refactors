defmodule Number42.Refactors.Ex.MapNewLambdaToForComprehensionTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.MapNewLambdaToForComprehension

  @subject MapNewLambdaToForComprehension

  describe "rewrites — bare call form, multi-line tuple body" do
    # Threshold (see issue #16): the bare/simple-pipe expansion only fires
    # when the lambda's tuple body spans ≥ 2 source lines. A multi-line
    # body is where the comprehension head earns its keep — there's already
    # vertical real estate, so the `for`/`|> Map.new()` shape adds no tax
    # while gaining a place to hang filters and local bindings.

    test "Map.new(coll, fn x -> {\\n  k,\\n  v\\n} end) -> for x <- coll do … end |> Map.new()" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(rows) do
            Map.new(rows, fn r ->
              {compute_key(r),
               compute_value(r)}
            end)
          end
        end
        """,
        """
        defmodule M do
          def go(rows) do
            for r <- rows do
              {compute_key(r), compute_value(r)}
            end
            |> Map.new()
          end
        end
        """
      )
    end

    test "destructuring pattern in lambda arg is preserved as generator pattern" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(attrs) do
            Map.new(attrs, fn {k, v} ->
              {to_string(k),
               normalize(v)}
            end)
          end
        end
        """,
        """
        defmodule M do
          def go(attrs) do
            for {k, v} <- attrs do
              {to_string(k), normalize(v)}
            end
            |> Map.new()
          end
        end
        """
      )
    end

    test "two multi-line Map.new callsites in one module — both are rewritten" do
      # Guards against `rewrite-only-the-first-hit` walker bugs.
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def one(rows) do
            Map.new(rows, fn r ->
              {r.id,
               r}
            end)
          end

          def two(items) do
            Map.new(items, fn i ->
              {i.id,
               i.name}
            end)
          end
        end
        """,
        """
        defmodule M do
          def one(rows) do
            for r <- rows do
              {r.id, r}
            end
            |> Map.new()
          end

          def two(items) do
            for i <- items do
              {i.id, i.name}
            end
            |> Map.new()
          end
        end
        """
      )
    end
  end

  describe "rewrites — pipe form, multi-line tuple body" do
    test "coll |> Map.new(fn x -> {\\n…\\n} end) -> for + |> Map.new()" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(rows) do
            rows
            |> Map.new(fn r ->
              {r.id,
               build(r)}
            end)
          end
        end
        """,
        """
        defmodule M do
          def go(rows) do
            for r <- rows do
              {r.id, build(r)}
            end
            |> Map.new()
          end
        end
        """
      )
    end
  end

  describe "leaves alone — single-line tuple body (threshold, issue #16)" do
    # The verbosity-tax case: a one-line `Map.new(coll, fn x -> {k, v} end)`
    # carries no composability that's being used, so expanding it to a
    # 3-line `for`/`|> Map.new()` block is pure cost. Leave it.

    test "bare form: Map.new(counts, fn {k, v} -> {to_string(k), v} end)" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(counts) do
          Map.new(counts, fn {k, v} -> {to_string(k), v} end)
        end
      end
      """)
    end

    test "bare form: simple key/value tuple" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(rows) do
          Map.new(rows, fn r -> {r.id, r} end)
        end
      end
      """)
    end

    test "bare form: computed value still single-line stays" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(items) do
          Map.new(items, fn i -> {i.id, i.value || 0} end)
        end
      end
      """)
    end

    test "pipe form: single-line tuple body stays" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(rows) do
          rows |> Map.new(fn r -> {r.id, r} end)
        end
      end
      """)
    end
  end

  describe "rewrites — filter/reject lift to for-guard" do
    test "Enum.filter with capture lifts to for-condition" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(items) do
            items
            |> Enum.filter(& &1.active)
            |> Map.new(fn i -> {i.id, i} end)
          end
        end
        """,
        """
        defmodule M do
          def go(items) do
            for i <- items, i.active do
              {i.id, i}
            end
            |> Map.new()
          end
        end
        """
      )
    end

    test "Enum.filter with named lambda lifts to for-condition" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(items) do
            items
            |> Enum.filter(fn i -> i.active end)
            |> Map.new(fn i -> {i.id, i} end)
          end
        end
        """,
        """
        defmodule M do
          def go(items) do
            for i <- items, i.active do
              {i.id, i}
            end
            |> Map.new()
          end
        end
        """
      )
    end

    test "Enum.reject with capture lifts to negated for-condition" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(items) do
            items
            |> Enum.reject(& &1.deleted)
            |> Map.new(fn i -> {i.id, i} end)
          end
        end
        """,
        """
        defmodule M do
          def go(items) do
            for i <- items, not i.deleted do
              {i.id, i}
            end
            |> Map.new()
          end
        end
        """
      )
    end

    test "multiple filter stages compose into multiple for-conditions" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(items) do
            items
            |> Enum.filter(& &1.active)
            |> Enum.reject(& &1.deleted)
            |> Map.new(fn i -> {i.id, i} end)
          end
        end
        """,
        """
        defmodule M do
          def go(items) do
            for i <- items, i.active, not i.deleted do
              {i.id, i}
            end
            |> Map.new()
          end
        end
        """
      )
    end

    test "filter lift uses the Map.new lambda's binding name in the condition" do
      # Generator binding name comes from the Map.new lambda's parameter,
      # not from the capture's `&1`. The condition splices `&1` -> binding.
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(rows) do
            rows
            |> Enum.filter(& &1.kept?)
            |> Map.new(fn r -> {r.id, r} end)
          end
        end
        """,
        """
        defmodule M do
          def go(rows) do
            for r <- rows, r.kept? do
              {r.id, r}
            end
            |> Map.new()
          end
        end
        """
      )
    end

    test "named-lambda filter with destructuring binding still lifts" do
      # `Enum.filter(fn {_, v} -> v > 0 end)` uses its own parameter name;
      # since the generator binding is the Map.new lambda's arg, the
      # filter's parameter must be renamed at lift time. Skip this case
      # cleanly: keep filters whose lambda binding doesn't agree with
      # Map.new's binding as a single-arg call against the generator.
      assert_unchanged(@subject, """
      defmodule M do
        def go(items) do
          items
          |> Enum.filter(fn {_, v} -> v > 0 end)
          |> Map.new(fn {k, v} -> {to_string(k), v} end)
        end
      end
      """)
    end

    test "function-reference capture filter (&name/arity) is not liftable" do
      # `Enum.filter(&job_runner?/1)` parses as `{:&, _, [{:/, _, [name, 1]}]}`.
      # There's no `&1`-body to splice — lifting would produce
      # `for mod <- modules, job_runner? / 1 do …` (parse error).
      # Leave the whole pipe alone instead of half-rewriting.
      assert_unchanged(@subject, """
      defmodule M do
        def go(modules) do
          modules
          |> Enum.filter(&job_runner?/1)
          |> Map.new(fn m -> {m.id, m} end)
        end
      end
      """)
    end
  end

  describe "leaves alone — pipe-into-pipe (non-filter)" do
    test "Enum.map LHS is not a filter and stays as a pipe" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(items) do
          items
          |> Enum.map(& &1.payload)
          |> Map.new(fn i -> {i.id, i} end)
        end
      end
      """)
    end

    test "Enum.sort LHS is not a filter and stays as a pipe" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(items) do
          items
          |> Enum.sort()
          |> Map.new(fn i -> {i.id, i} end)
        end
      end
      """)
    end
  end

  describe "leaves alone — wrong arity / shape" do
    test "Map.new/1 — handled by MapNewToPipe, not us" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll), do: Map.new(coll)
      end
      """)
    end

    test "Map.new/0 — empty map builder" do
      assert_unchanged(@subject, """
      defmodule M do
        def go, do: Map.new()
      end
      """)
    end

    test "Map.new(coll, &capture) — capture instead of lambda" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(items), do: Map.new(items, &{&1.id, &1})
      end
      """)
    end

    test "pipe with &capture as second arg" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(items), do: items |> Map.new(&{&1.id, &1})
      end
      """)
    end
  end

  describe "leaves alone — lambda body not a 2-tuple literal" do
    test "body is a multi-statement block (local var before tuple)" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(items) do
          Map.new(items, fn i ->
            a = compute(i)
            {a.k, a.v}
          end)
        end
      end
      """)
    end

    test "body is an if expression that yields tuples" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(items) do
          Map.new(items, fn i ->
            if i.active, do: {i.id, :on}, else: {i.id, :off}
          end)
        end
      end
      """)
    end

    test "body is a case expression" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(items) do
          Map.new(items, fn i ->
            case i.kind do
              :a -> {i.id, :first}
              :b -> {i.id, :second}
            end
          end)
        end
      end
      """)
    end

    test "body is a with expression" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(items) do
          Map.new(items, fn i ->
            with {:ok, v} <- fetch(i), do: {i.id, v}
          end)
        end
      end
      """)
    end

    test "body is a non-tuple call returning a pair (we can't see that)" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(items), do: Map.new(items, fn i -> build_pair(i) end)
      end
      """)
    end

    test "body is a 3-tuple literal (not a key/value pair)" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(rows), do: Map.new(rows, fn r -> {r.a, r.b, r.c} end)
      end
      """)
    end

    test "body is a parenthesised 2-tuple — Sourceror wraps in :__block__" do
      # Sourceror represents `({k, v})` as `{:__block__, _, [{k, v}]}`.
      # That's not a bare 2-tuple at the AST level, so the strict
      # `is_tuple(body) and tuple_size(body) == 2` filter must skip it.
      # If a future relaxation wants to unwrap single-element blocks,
      # flip this to `assert_rewrites` — until then, skipping is safe.
      assert_unchanged(@subject, """
      defmodule M do
        def go(rows), do: Map.new(rows, fn r -> ({r.id, r}) end)
      end
      """)
    end
  end

  describe "leaves alone — unsupported lambda shapes" do
    test "multi-clause lambda" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(items) do
          Map.new(items, fn
            %{kind: :a} = i -> {i.id, :first}
            %{kind: :b} = i -> {i.id, :second}
          end)
        end
      end
      """)
    end

    test "lambda with a guard" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(items) do
          Map.new(items, fn i when is_map(i) -> {i.id, i} end)
        end
      end
      """)
    end

    test "lambda with multiple arguments (not a typical Map.new shape but be defensive)" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll), do: Map.new(coll, fn k, v -> {k, v} end)
      end
      """)
    end
  end

  describe "leaves alone — wrong namespace" do
    test "MyMap.new(coll, fn ...) — not the stdlib Map" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll), do: MyMap.new(coll, fn x -> {x.k, x.v} end)
      end
      """)
    end

    test "Keyword.new(coll, fn ...) — wrong module" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(coll), do: Keyword.new(coll, fn x -> {x.k, x.v} end)
      end
      """)
    end

    test "aliased non-stdlib Map (`alias SomeLib.Map`) — refactor over-reach guard" do
      # The match looks at the `Map` AST alias and cannot distinguish a
      # shadowed alias from the real one. Documenting current behaviour:
      # the refactor WILL rewrite this — alias-resolution is out of
      # scope. If this ever becomes a real problem, the AST walker
      # would need module-level alias resolution (see ResolveImplTrue).
      # The body is multi-line so the threshold doesn't mask the
      # over-reach this test is meant to pin.
      assert_rewrites(
        @subject,
        """
        defmodule M do
          alias SomeLib.Map

          def go(coll) do
            Map.new(coll, fn x ->
              {x.k,
               x.v}
            end)
          end
        end
        """,
        """
        defmodule M do
          alias SomeLib.Map

          def go(coll) do
            for x <- coll do
              {x.k, x.v}
            end
            |> Map.new()
          end
        end
        """
      )
    end
  end

  describe "leaves alone — quote blocks" do
    test "Map.new inside `quote do … end` is not rewritten" do
      # AST refactors that recurse into `quote` blocks corrupt macro
      # bodies — the contents are template AST, not code to transform.
      assert_unchanged(@subject, """
      defmodule M do
        defmacro build(coll) do
          quote do
            Map.new(unquote(coll), fn x -> {x.k, x.v} end)
          end
        end
      end
      """)
    end
  end

  describe "leaves alone — nested Map.new" do
    test "inner single-line Map.new is below the threshold — no asymmetric expansion (issue #16)" do
      # Issue #16's worst case: the outer Map.new has a multi-statement
      # lambda body (always skipped — not a bare tuple), and the inner
      # Map.new used to be expanded on its own, producing a confusing
      # asymmetric mix. With the single-line threshold the inner one is
      # also left alone, so the whole expression stays put.
      assert_unchanged(@subject, """
      defmodule M do
        def go(groups) do
          Map.new(groups, fn g ->
            values = Map.new(g.items, fn i -> {i.id, i.value} end)
            {g.id, values}
          end)
        end
      end
      """)
    end

    test "inner multi-line Map.new is still expanded; outer multi-statement body stays" do
      # When the inner lambda's tuple body itself spans multiple lines,
      # the inner one IS over the threshold and rewrites — the outer
      # (multi-statement body) is still left alone, as always.
      assert_rewrites(
        @subject,
        """
        defmodule M do
          def go(groups) do
            Map.new(groups, fn g ->
              values =
                Map.new(g.items, fn i ->
                  {i.id,
                   i.value}
                end)

              {g.id, values}
            end)
          end
        end
        """,
        """
        defmodule M do
          def go(groups) do
            Map.new(groups, fn g ->
              values =
                for i <- g.items do
                  {i.id, i.value}
                end
                |> Map.new()

              {g.id, values}
            end)
          end
        end
        """
      )
    end
  end

  describe "leaves alone — already conformant" do
    test "for/into/Map.new pipeline" do
      assert_unchanged(@subject, """
      defmodule M do
        def go(rows) do
          for r <- rows do
            {r.id, r}
          end
          |> Map.new()
        end
      end
      """)
    end

    test "for with :into option" do
      # We don't rewrite this either way — it's a different idiom and
      # touching it is out of scope.
      assert_unchanged(@subject, """
      defmodule M do
        def go(rows) do
          for r <- rows, into: %{} do
            {r.id, r}
          end
        end
      end
      """)
    end
  end

  describe "idempotent" do
    test "single-line bare form (now a no-op) is idempotent" do
      assert_idempotent(@subject, """
      defmodule M do
        def go(rows), do: Map.new(rows, fn r -> {r.id, r} end)
      end
      """)
    end

    test "multi-line bare-form rewrite is idempotent" do
      assert_idempotent(@subject, """
      defmodule M do
        def go(rows) do
          Map.new(rows, fn r ->
            {r.id,
             r}
          end)
        end
      end
      """)
    end

    test "multi-line pipe-form rewrite is idempotent" do
      assert_idempotent(@subject, """
      defmodule M do
        def go(rows) do
          rows
          |> Map.new(fn r ->
            {r.id,
             r}
          end)
        end
      end
      """)
    end
  end

  describe "comments are preserved exactly once" do
    # Whitespace-agnostic assertions hide double-emission of leading/
    # trailing comments — see `writing-refactors.md`. Substring-count
    # the comment text on the raw output.
    test "leading comment on the Map.new line is not duplicated" do
      source = """
      defmodule M do
        def go(rows) do
          # build id->row index
          Map.new(rows, fn r ->
            {r.id,
             r}
          end)
        end
      end
      """

      out = apply_refactor(@subject, source)

      assert count_occurrences(out, "build id->row index") == 1, """
      Comment was emitted #{count_occurrences(out, "build id->row index")} time(s):

      #{out}
      """
    end
  end

  defp count_occurrences(haystack, needle),
    do:
      haystack
      |> String.split(needle)
      |> length()
      |> Kernel.-(1)
end
