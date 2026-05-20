defmodule Number42.Refactors.Ex.EnumCaptureTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.EnumCapture

  @subject EnumCapture

  # EnumCapture flips Enum.<fn>(coll, fn x -> body(x) end) into
  # `coll |> Enum.<fn>(&(body(&1)))`. The result uses `&(...)`, not
  # `&fn/arity`. We assert that exact form (whitespace-agnostic).
  describe "rewrites" do
    test "Enum.map with single-call lambda becomes &-capture pipe" do
      assert_rewrites(
        @subject,
        "Enum.map(list, fn x -> to_string(x) end)",
        "list |> Enum.map(&(to_string(&1)))"
      )
    end

    test "Enum.filter with single-call lambda" do
      assert_rewrites(
        @subject,
        "Enum.filter(list, fn x -> is_nil(x) end)",
        "list |> Enum.filter(&(is_nil(&1)))"
      )
    end

    test "Stream.map with single-call lambda" do
      assert_rewrites(
        @subject,
        "Stream.map(list, fn x -> Atom.to_string(x) end)",
        "list |> Stream.map(&(Atom.to_string(&1)))"
      )
    end

    test "lambda whose call uses arg in non-positional way (x, x)" do
      # The refactor accepts this and emits f(&1, &1). We test it stays
      # in scope rather than asserting it's left alone.
      assert_rewrites(
        @subject,
        "Enum.map(list, fn x -> f(x, x) end)",
        "list |> Enum.map(&(f(&1, &1)))"
      )
    end
  end

  describe "leaves alone" do
    test "lambda with multi-statement body" do
      assert_unchanged(@subject, """
      Enum.map(list, fn x ->
        y = x + 1
        y * 2
      end)
      """)
    end

    test "lambda with multiple args" do
      assert_unchanged(@subject, "Enum.reduce(list, %{}, fn x, acc -> Map.put(acc, x, x) end)")
    end

    test "already a capture" do
      assert_unchanged(@subject, "Enum.map(list, &to_string/1)")
    end

    test "non-Enum / non-Stream caller is out of scope" do
      assert_unchanged(@subject, "Foo.map(list, fn x -> to_string(x) end)")
    end

    # Lambdas whose body contains a `|>` pipe rewrite to `&(a |> b |> c)`
    # — legal, but unreadable: the leading `&` mixes with the pipe and
    # the eye loses the function-value framing. The original `fn _ ->
    # ... end` is plainly a side-effect block and should stay that way.
    test "lambda whose body contains a pipe is left alone" do
      assert_unchanged(@subject, """
      Enum.each(params, fn _p ->
        lv |> element("button[phx-click=\\"add_param\\"]") |> render_click()
      end)
      """)
    end

    test "lambda piping the arg through is left alone" do
      assert_unchanged(@subject, """
      Enum.map(list, fn x -> x |> foo() |> bar() end)
      """)
    end

    # `case`/`if`/`cond`/`with`/`fn`/`try`/`receive` in the lambda body
    # turns `&(case &1 do …)`-style captures, which are unreadable. The
    # lambda already names the binding the control-flow uses; keep it.
    test "lambda with case in body is left alone" do
      assert_unchanged(@subject, """
      Enum.map(rows, fn row ->
        case Map.get(items_by_id, row.item_id) do
          nil -> row
          item -> Map.put(row, :item, item)
        end
      end)
      """)
    end

    test "lambda with if in body is left alone" do
      assert_unchanged(
        @subject,
        "Enum.map(0..n, fn j -> if j == idx, do: nested, else: placeholder() end)"
      )
    end

    test "lambda with cond in body is left alone" do
      assert_unchanged(@subject, """
      Enum.find(items, fn x ->
        cond do
          x.kind == :a -> true
          x.kind == :b -> true
          true -> false
        end
      end)
      """)
    end

    # Outer lambda has a nested `fn` in its body — outer stays as a
    # lambda (control-flow-in-body gate). The inner `fn it -> it.id`
    # is itself a valid capture target and gets rewritten on its own.
    test "outer lambda with nested fn body stays; inner is rewritten on its own" do
      before_source =
        "Enum.flat_map(rows, fn row -> Enum.map(row.items, fn it -> it.id end) end)"

      actual = apply_refactor(@subject, before_source)

      assert String.contains?(actual, "fn row ->")
      assert String.contains?(actual, "row.items |> Enum.map(&(&1.id))")
    end

    # `f(x) <op> g(x)` becomes `f(&1) <op> g(&1)`. Without a named
    # binding the relationship between the two sides has to be re-read
    # from the slot positions. Cheaper to leave the lambda.
    test "operator with calls on both sides — and" do
      assert_unchanged(
        @subject,
        "Enum.filter(fks, fn fk -> MapSet.member?(t, fk.to_table) and MapSet.member?(t, fk.from_table) end)"
      )
    end

    test "operator with calls on both sides — or" do
      assert_unchanged(
        @subject,
        ~S|Enum.reject(tables, fn t -> t.name == "schema_migrations" or MapSet.member?(skip, t.name) end)|
      )
    end

    test "operator with calls on both sides — ||" do
      assert_unchanged(
        @subject,
        "Enum.map(choices, fn choice -> Map.get(choice, \"key\") || Map.get(choice, :key) end)"
      )
    end

    test "operator with calls on both sides — &&" do
      assert_unchanged(
        @subject,
        "Enum.filter(items, fn m -> m.formula && json_contains?(m.formula, key) end)"
      )
    end

    test "operator with calls on both sides — ==" do
      assert_unchanged(
        @subject,
        "Enum.any?(items, fn item -> item.brand_item_availability_id == avail.id end)"
      )
    end

    test "operator with calls on both sides — !=" do
      assert_unchanged(
        @subject,
        "Enum.split_with(items, fn item -> item.item_positions != some_other.thing end)"
      )
    end

    test "operator with calls on both sides — ++" do
      assert_unchanged(
        @subject,
        "Enum.map(cases, fn c -> walk(c.cond) ++ walk(c.value) end)"
      )
    end

    test "operator with calls on both sides — in" do
      assert_unchanged(
        @subject,
        "Enum.filter(rows, fn r -> Map.get(r, :kind) in classes() end)"
      )
    end

    test "field access on both sides of operator is left alone" do
      assert_unchanged(
        @subject,
        "Enum.find(specs, fn s -> s.name == other.name end)"
      )
    end

    # `fn x -> x end` would become `& &1` — pointless.
    test "bare-var lambda is left alone" do
      assert_unchanged(@subject, "Enum.map(list, fn x -> x end)")
    end

    # `fn _ -> :literal end` has no reference to the lambda's parameter,
    # so there is no `&1` slot to materialize. Rewriting it to
    # `&:literal` produces invalid `&`-capture syntax — `:literal` is
    # not a function. Leave the lambda alone (it's a constant fn).
    test "lambda with literal body and no param ref is left alone — atom" do
      assert_unchanged(@subject, ~S|Enum.map(segments, fn _ -> :"$alias" end)|)
    end

    test "lambda with literal body and no param ref is left alone — integer" do
      assert_unchanged(@subject, "Enum.map(segments, fn _ -> 0 end)")
    end

    test "lambda with literal body and no param ref is left alone — string" do
      assert_unchanged(@subject, ~S|Enum.map(segments, fn _ -> "x" end)|)
    end

    test "lambda whose body references only outer vars is left alone" do
      assert_unchanged(@subject, "Enum.map(segments, fn _ -> default end)")
    end

    # Collection literals with the slot referenced more than once
    # read poorly as captures — the named binding kept the slot's
    # role obvious at each position.
    test "2-tuple literal with slot used twice is left alone" do
      assert_unchanged(@subject, "Enum.map(values, fn v -> {label(v), v} end)")
    end

    test "2-tuple with non-trivial first elem and slot reuse is left alone" do
      assert_unchanged(
        @subject,
        "Enum.map(values, fn v -> {attribute_value_label(v, labels), v} end)"
      )
    end

    test "map literal with multiple slot refs is left alone" do
      assert_unchanged(
        @subject,
        "Enum.map(mods, fn mod -> %{name: Info.name!(mod), label: safe_label(mod)} end)"
      )
    end

    test "list literal with multiple slot refs is left alone" do
      assert_unchanged(@subject, "Enum.map(items, fn i -> [i.id, i.name, i.id] end)")
    end
  end

  describe "rewrites — non-trivial but allowed" do
    # Operator with one call/field side and one trivial (var/literal)
    # side stays in scope: `&1.kind == name` keeps the relationship
    # readable because only one side moved.
    test "operator with call and var" do
      assert_rewrites(
        @subject,
        "Enum.find(specs, fn s -> s.string_name == name end)",
        "specs |> Enum.find(&(&1.string_name == name))"
      )
    end

    test "operator with call and literal" do
      assert_rewrites(
        @subject,
        "Enum.filter(rows, fn r -> r.count > 0 end)",
        "rows |> Enum.filter(&(&1.count > 0))"
      )
    end

    test "field access" do
      assert_rewrites(
        @subject,
        "Enum.find_value(rows, fn r -> r.currency end)",
        "rows |> Enum.find_value(&(&1.currency))"
      )
    end

    # Tuple-3 literal that refs the slot once is fine — `&1.key` is
    # the only slot use, so the capture reads cleanly.
    test "tuple-3 literal with single slot ref" do
      assert_rewrites(
        @subject,
        "Enum.map(masses, fn m -> {:mass, m.key, :formula} end)",
        "masses |> Enum.map(&({:mass, &1.key, :formula}))"
      )
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "Enum.map(list, fn x -> to_string(x) end)")
    end
  end
end
