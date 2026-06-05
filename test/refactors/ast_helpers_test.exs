defmodule Number42.Refactors.AstHelpersTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.AstHelpers

  describe "slice_node/2 — literal-direct rendering" do
    test "bare atom" do
      assert {:ok, ":foo"} = AstHelpers.slice_node("ignored", :foo)
    end

    test "bare integer" do
      assert {:ok, "42"} = AstHelpers.slice_node("ignored", 42)
    end

    test "bare float" do
      assert {:ok, "1.5"} = AstHelpers.slice_node("ignored", 1.5)
    end

    test "wrapped atom literal" do
      ast = {:__block__, [], [:foo]}
      assert {:ok, ":foo"} = AstHelpers.slice_node("ignored", ast)
    end

    test "wrapped boolean literal — direct render, not source slice" do
      # Sourceror's range for `true`/`false` over-shoots by 1 column.
      # Direct rendering side-steps that quirk completely.
      ast = {:__block__, [line: 1, column: 1], [true]}
      assert {:ok, "true"} = AstHelpers.slice_node("ignored", ast)
    end

    test "wrapped nil literal" do
      ast = {:__block__, [line: 1, column: 1], [nil]}
      assert {:ok, "nil"} = AstHelpers.slice_node("ignored", ast)
    end

    test "wrapped integer literal" do
      ast = {:__block__, [], [42]}
      assert {:ok, "42"} = AstHelpers.slice_node("ignored", ast)
    end

    test "wrapped float literal" do
      ast = {:__block__, [], [1.5]}
      assert {:ok, "1.5"} = AstHelpers.slice_node("ignored", ast)
    end
  end

  describe "slice_node/2 — operator nodes with boolish trailing leaf" do
    test "`x || false` does NOT include the surrounding call's `)`" do
      # Repro of the item_picker_component bug: Sourceror's range for
      # `x || false` ends one column past the right operand, leaking the
      # enclosing call's `)` into the slice. The helper must clip it.
      src = "foo(:k, x || false)"
      {:ok, ast} = Sourceror.parse_string(src)

      op_node =
        ast
        |> Macro.prewalker()
        |> Enum.find(fn
          {:||, _, _} -> true
          _ -> false
        end)

      assert {:ok, "x || false"} = AstHelpers.slice_node(src, op_node)
    end

    test "`x && nil` does NOT include the call's `)`" do
      src = "foo(x && nil)"
      {:ok, ast} = Sourceror.parse_string(src)

      op_node =
        ast
        |> Macro.prewalker()
        |> Enum.find(fn
          {:&&, _, _} -> true
          _ -> false
        end)

      assert {:ok, "x && nil"} = AstHelpers.slice_node(src, op_node)
    end

    test "`x || y` (non-boolish trailing leaf) — slice unchanged" do
      src = "foo(x || y)"
      {:ok, ast} = Sourceror.parse_string(src)

      op_node =
        ast
        |> Macro.prewalker()
        |> Enum.find(fn
          {:||, _, _} -> true
          _ -> false
        end)

      assert {:ok, "x || y"} = AstHelpers.slice_node(src, op_node)
    end
  end

  describe "slice_node/2 — non-literal expressions" do
    test "function call: `foo(:a, 1)`" do
      src = "x = foo(:a, 1)"
      {:ok, ast} = Sourceror.parse_string(src)

      call_node =
        ast
        |> Macro.prewalker()
        |> Enum.find(fn
          {:foo, _, _} -> true
          _ -> false
        end)

      assert {:ok, "foo(:a, 1)"} = AstHelpers.slice_node(src, call_node)
    end

    test "list literal: `[1, 2, 3]`" do
      src = "x = [1, 2, 3]"
      {:ok, ast} = Sourceror.parse_string(src)

      list_node =
        ast
        |> Macro.prewalker()
        |> Enum.find(fn
          {:__block__, _, [list]} when is_list(list) -> true
          _ -> false
        end)

      assert {:ok, "[1, 2, 3]"} = AstHelpers.slice_node(src, list_node)
    end
  end

  describe "special_form?/1" do
    test "recognizes do/end special forms" do
      for name <- [:case, :cond, :for, :fn, :if, :quote, :receive, :try, :unless, :unquote, :with] do
        assert AstHelpers.special_form?({name, [], [:scrutinee, [do: :body]]}),
               "expected #{inspect(name)} to be a special form"
      end
    end

    test "regular function calls are not special forms" do
      refute AstHelpers.special_form?({:assign, [], [:scrutinee, :body]})
      refute AstHelpers.special_form?({:foo, [], [1, 2]})
    end

    test "non-call AST shapes are not special forms" do
      refute AstHelpers.special_form?(:case)
      refute AstHelpers.special_form?({:., [], [{:__aliases__, [], [:Mod]}, :case]})
      refute AstHelpers.special_form?(42)
    end
  end

  describe "slice_source/3" do
    test "single-line slice — exclusive end column" do
      src = "abcdefghij"
      start_pos = [line: 1, column: 3]
      end_pos = [line: 1, column: 7]
      assert "cdef" = AstHelpers.slice_source(src, start_pos, end_pos)
    end

    test "multi-line slice — exclusive end column on last line" do
      src = "first line\nsecond line\nthird line"
      start_pos = [line: 1, column: 7]
      end_pos = [line: 3, column: 6]
      assert "line\nsecond line\nthird" = AstHelpers.slice_source(src, start_pos, end_pos)
    end

    test "two-line slice (no middle)" do
      src = "abc\ndef"
      start_pos = [line: 1, column: 2]
      end_pos = [line: 2, column: 3]
      assert "bc\nde" = AstHelpers.slice_source(src, start_pos, end_pos)
    end
  end

  describe "alias_to_module/1" do
    test "single-segment alias" do
      ast = {:__aliases__, [], [:Foo]}
      assert {:ok, Foo} = AstHelpers.alias_to_module(ast)
    end

    test "multi-segment alias" do
      ast = {:__aliases__, [], [:Foo, :Bar, :Baz]}
      assert {:ok, Foo.Bar.Baz} = AstHelpers.alias_to_module(ast)
    end

    test "non-alias AST returns :error" do
      assert :error = AstHelpers.alias_to_module({:foo, [], nil})
      assert :error = AstHelpers.alias_to_module(:not_a_tuple)
      assert :error = AstHelpers.alias_to_module(nil)
    end

    test "empty parts list returns :error" do
      ast = {:__aliases__, [], []}
      assert :error = AstHelpers.alias_to_module(ast)
    end
  end

  describe "extract_call_name/1" do
    test "local call" do
      ast = {:build_changeset, [], [{:x, [], nil}]}
      assert {:ok, :build_changeset} = AstHelpers.extract_call_name(ast)
    end

    test "remote call" do
      ast = {{:., [], [{:__aliases__, [], [:Foo]}, :bar]}, [], [{:x, [], nil}]}
      assert {:ok, :bar} = AstHelpers.extract_call_name(ast)
    end

    test "pipe — returns last stage's name" do
      lhs = {:x, [], nil}
      rhs = {:build_changeset, [], []}
      ast = {:|>, [], [lhs, rhs]}
      assert {:ok, :build_changeset} = AstHelpers.extract_call_name(ast)
    end

    test "pipe with remote on the right" do
      lhs = {:x, [], nil}
      rhs = {{:., [], [{:__aliases__, [], [:Foo]}, :bar]}, [], []}
      ast = {:|>, [], [lhs, rhs]}
      assert {:ok, :bar} = AstHelpers.extract_call_name(ast)
    end

    test "non-call returns :error" do
      assert :error = AstHelpers.extract_call_name({:x, [], nil})
      assert :error = AstHelpers.extract_call_name(42)
      assert :error = AstHelpers.extract_call_name(:foo)
    end
  end

  describe "module_body_exprs/1" do
    test "block body returns the wrapped expressions" do
      ast = {:defmodule, [], [{:__aliases__, [], [:Foo]}, [{:do, {:__block__, [], [:a, :b]}}]]}
      assert [:a, :b] = AstHelpers.module_body_exprs(ast)
    end

    test "single-expression body returns a 1-element list" do
      ast = {:defmodule, [], [{:__aliases__, [], [:Foo]}, [{:do, :single}]]}
      assert [:single] = AstHelpers.module_body_exprs(ast)
    end

    test "non-defmodule node returns nil" do
      assert nil == AstHelpers.module_body_exprs({:foo, [], nil})
      assert nil == AstHelpers.module_body_exprs(:not_a_module)
    end
  end

  describe "pipe_unsafe_op?/1 (defguard)" do
    require AstHelpers

    # Wrap the guard in a function-clause so we can table-drive tests
    # against it from regular function-call position.
    defp unsafe?(op) when AstHelpers.pipe_unsafe_op?(op), do: true
    defp unsafe?(_), do: false

    test "true for arithmetic operators" do
      for op <- [:+, :-, :*, :/, :++] do
        assert unsafe?(op), "expected #{inspect(op)} to be unsafe"
      end
    end

    test "true for comparison and boolean operators" do
      for op <- [:==, :!=, :===, :!==, :>, :<, :>=, :<=, :and, :or, :not, :&&, :||, :!] do
        assert unsafe?(op)
      end
    end

    test "true for special-form operators" do
      for op <- [:in, :|, :"::", :<>, :<-] do
        assert unsafe?(op)
      end
    end

    test "false for non-operators" do
      refute unsafe?(:foo)
      refute unsafe?(:|>)
      refute unsafe?(:=)
    end
  end

  describe "def_kind?/1 (defguard)" do
    require AstHelpers

    defp def_basic?(kind) when AstHelpers.def_kind?(kind), do: true
    defp def_basic?(_), do: false

    defp def_all?(kind) when AstHelpers.def_or_macro_kind?(kind), do: true
    defp def_all?(_), do: false

    test "def_kind? matches :def and :defp only" do
      assert def_basic?(:def)
      assert def_basic?(:defp)
      refute def_basic?(:defmacro)
      refute def_basic?(:defmacrop)
      refute def_basic?(:foo)
    end

    test "def_or_macro_kind? matches def, defp, defmacro, defmacrop" do
      assert def_all?(:def)
      assert def_all?(:defp)
      assert def_all?(:defmacro)
      assert def_all?(:defmacrop)
      refute def_all?(:defmodule)
      refute def_all?(:foo)
    end
  end

  describe "build_patch/3" do
    test "returns nil for nodes without a range" do
      bare_atom = :foo
      assert nil == AstHelpers.build_patch(bare_atom, "replacement")
    end

    test "builds a Sourceror.Patch from a parsed AST node" do
      {:ok, ast} = Sourceror.parse_string("foo")
      patch = AstHelpers.build_patch(ast, "bar")

      assert %Sourceror.Patch{} = patch
      assert patch.change == "bar"
    end

    test "with boolish_tail?: true clips the end column for trailing booleans" do
      # `foo(true)` — Sourceror over-shoots on the trailing `true`.
      {:ok, ast} = Sourceror.parse_string("@impl true")

      [_attr, true_node] =
        case ast do
          {:@, _, [{:impl, _, [arg]}]} -> [:attr, arg]
        end

      clipped = AstHelpers.build_patch(true_node, "X", boolish_tail?: true)
      unclipped = AstHelpers.build_patch(true_node, "X")

      # Clipped end column is one less than unclipped.
      assert clipped.range.end[:column] == unclipped.range.end[:column] - 1
    end
  end

  describe "short_name?/2" do
    defp ctx(opts \\ []),
      do: %{
        known: Keyword.get(opts, :known, %{}),
        whitelist: opts |> Keyword.get(:whitelist, []) |> MapSet.new()
      }

    test "single short subtoken triggers short" do
      assert AstHelpers.short_name?(:cs, ctx())
      assert AstHelpers.short_name?(:id, ctx())
    end

    test "multi-part name with at least one short non-whitelisted subtoken is short" do
      # cs is short and not whitelisted -> the whole name is short.
      assert AstHelpers.short_name?(:cs_id, ctx())
      # cs is short, changeset is long -> still short via cs.
      assert AstHelpers.short_name?(:cs_changeset, ctx())
      # mid-name short subtoken counts too.
      assert AstHelpers.short_name?(:user_cs_form, ctx())
    end

    test "whitelisted subtokens don't count toward short" do
      # id is whitelisted, no other short subtoken -> not short.
      refute AstHelpers.short_name?(:id_for_user, ctx(whitelist: [:id, :for]))
      # cs not whitelisted, id whitelisted -> short via cs.
      assert AstHelpers.short_name?(:cs_id, ctx(whitelist: [:id]))
    end

    test "whitelisted full name is never short" do
      # Even if subtokens would be short, an exact-name whitelist hit
      # short-circuits to not-short.
      refute AstHelpers.short_name?(:idx_map, ctx(whitelist: [:idx_map]))
    end

    test "known mapping forces short" do
      # `org_id` would not be short on the heuristic (org > 3? no, org is 3
      # so it's short anyway). Use a name that wouldn't otherwise be
      # short to prove `known` overrides.
      refute AstHelpers.short_name?(:something_else, ctx())
      assert AstHelpers.short_name?(:something_else, ctx(known: %{"something_else" => "x"}))
    end

    test "underscore-prefix names are not short" do
      # `_unused`, `_acc` etc. are intentional ignores; never rename.
      refute AstHelpers.short_name?(:_cs, ctx())
      refute AstHelpers.short_name?(:_unused, ctx())
    end

    test "all-long, non-whitelisted name is not short" do
      refute AstHelpers.short_name?(:user_account, ctx())
      refute AstHelpers.short_name?(:changeset, ctx())
    end

    test "all subtokens whitelisted -> not short" do
      refute AstHelpers.short_name?(:id_pid_acc, ctx(whitelist: [:id, :pid, :acc]))
    end
  end

  describe "resolve_handler_name/5" do
    # Build a defps-index entry from a defp source string. The index
    # shape used by ExtractCaseToHelper:
    #   %{{name_atom, arity} => [{head_ast, body_kw_ast}, ...]}
    defp defp_clauses(sources) when is_list(sources) do
      sources
      |> Enum.flat_map(fn src ->
        {:ok, ast} = Sourceror.parse_string(src)

        case ast do
          {kind, _, [head, kw]}
          when kind in [:defp, :defmacrop] and is_list(kw) ->
            {name, args} = AstHelpers.extract_fn_signature(head)
            [{{name, length(args)}, {head, kw}}]

          _ ->
            []
        end
      end)
      |> Enum.group_by(fn {key, _} -> key end, fn {_, clause} -> clause end)
    end

    # Build a single branch like ExtractCaseToHelper.analyze_clause/2
    # produces it.
    defp branch(pattern_src, body_src, free_vars, opts \\ []) do
      {:ok, pattern} = Sourceror.parse_string(pattern_src)
      {:ok, body} = Sourceror.parse_string(body_src)

      %{
        body: body,
        free_vars: free_vars,
        guard: opts[:guard],
        pattern: pattern,
        used_in_body: MapSet.new(opts[:used_in_body] || free_vars)
      }
    end

    test "no collision -> base name" do
      assert {:ok, "handle_host_fetch"} =
               AstHelpers.resolve_handler_name("handle_host_fetch", 2, [], [], %{})
    end

    test "exact structural match -> :skip" do
      defps =
        defp_clauses([
          """
          defp handle_host_fetch({:ok, value}, ctx) do
            use(value, ctx)
          end
          """,
          """
          defp handle_host_fetch(:error, ctx) do
            default(ctx)
          end
          """
        ])

      branches = [
        branch("{:ok, value}", "use(value, ctx)", [:ctx], used_in_body: [:ctx, :value]),
        branch(":error", "default(ctx)", [:ctx])
      ]

      assert :skip =
               AstHelpers.resolve_handler_name("handle_host_fetch", 2, branches, [:ctx], defps)
    end

    test "different body -> _2 suffix" do
      defps =
        defp_clauses([
          """
          defp handle_host_fetch({:ok, value}, ctx) do
            something_else(value, ctx)
          end
          """
        ])

      branches = [
        branch("{:ok, value}", "use(value, ctx)", [:ctx], used_in_body: [:ctx, :value])
      ]

      assert {:ok, "handle_host_fetch_2"} =
               AstHelpers.resolve_handler_name("handle_host_fetch", 2, branches, [:ctx], defps)
    end

    test "same name different arity -> _2 suffix (visual grouping)" do
      defps =
        defp_clauses([
          """
          defp handle_host_fetch(x, y, z) do
            other(x, y, z)
          end
          """
        ])

      branches = [
        branch("{:ok, value}", "use(value)", [], used_in_body: [:value])
      ]

      assert {:ok, "handle_host_fetch_2"} =
               AstHelpers.resolve_handler_name("handle_host_fetch", 1, branches, [], defps)
    end

    test "_2 also occupied with different body -> _3" do
      defps =
        defp_clauses([
          """
          defp handle_host_fetch({:ok, v}) do
            a(v)
          end
          """,
          """
          defp handle_host_fetch_2({:ok, v}) do
            b(v)
          end
          """
        ])

      branches = [
        branch("{:ok, v}", "c(v)", [], used_in_body: [:v])
      ]

      assert {:ok, "handle_host_fetch_3"} =
               AstHelpers.resolve_handler_name("handle_host_fetch", 1, branches, [], defps)
    end

    test "underscore-prefixed param matches branch with unused free var" do
      defps =
        defp_clauses([
          """
          defp handle_host_fetch({:ok, value}, _ctx) do
            value
          end
          """
        ])

      # ctx is in free_vars but not used in body -> existing helper has _ctx
      branches = [
        branch("{:ok, value}", "value", [:ctx], used_in_body: [:value])
      ]

      assert :skip =
               AstHelpers.resolve_handler_name("handle_host_fetch", 2, branches, [:ctx], defps)
    end
  end

  describe "resolve_collision/3" do
    test "no collision -> base name" do
      assert {:ok, "foo"} = AstHelpers.resolve_collision("foo", %{}, [])
    end

    test "default same? = false: name occupied -> _2 suffix" do
      existing = %{"foo" => :anything}
      assert {:ok, "foo_2"} = AstHelpers.resolve_collision("foo", existing, [])
    end

    test "_2 also occupied -> _3" do
      existing = %{"foo" => :a, "foo_2" => :b}
      assert {:ok, "foo_3"} = AstHelpers.resolve_collision("foo", existing, [])
    end

    test "same? returns true on base -> :skip" do
      existing = %{"foo" => :payload}

      opts = [same?: fn :payload -> true end]
      assert :skip = AstHelpers.resolve_collision("foo", existing, opts)
    end

    test "same? returns false on base, true on _2 -> :skip at _2" do
      existing = %{"foo" => :other, "foo_2" => :match}

      opts = [
        same?: fn
          :other -> false
          :match -> true
        end
      ]

      assert :skip = AstHelpers.resolve_collision("foo", existing, opts)
    end

    test "on_collision: :skip — first collision -> :skip immediately" do
      existing = %{"foo" => :anything}
      assert :skip = AstHelpers.resolve_collision("foo", existing, on_collision: :skip)
    end

    test "on_collision: :skip with no collision -> base name" do
      assert {:ok, "foo"} = AstHelpers.resolve_collision("foo", %{}, on_collision: :skip)
    end

    test "same? is called once per occupied slot until match or free slot" do
      ref = make_ref()
      pid = self()

      existing = %{"foo" => :a, "foo_2" => :b, "foo_3" => :c}

      opts = [
        same?: fn payload ->
          send(pid, {ref, payload})
          false
        end
      ]

      assert {:ok, "foo_4"} = AstHelpers.resolve_collision("foo", existing, opts)

      # The helper visited foo, foo_2, foo_3 in order.
      assert_received {^ref, :a}
      assert_received {^ref, :b}
      assert_received {^ref, :c}
    end
  end

  describe "replace_literals_with_holes/1" do
    # Hash equality after literal-blanking: Type-II clones (same skeleton,
    # different literals) must collapse to the same hash. Structural
    # differences must not.
    defp skeleton_hash(ast),
      do: ast |> AstHelpers.replace_literals_with_holes() |> :erlang.phash2()

    test "two bodies differing only in an integer literal hash equal" do
      {:ok, a} = Sourceror.parse_string("def f(x), do: x + 1")
      {:ok, b} = Sourceror.parse_string("def f(x), do: x + 2")

      assert skeleton_hash(a) == skeleton_hash(b)
    end

    test "two bodies differing only in an atom literal hash equal" do
      {:ok, a} = Sourceror.parse_string("def f(x), do: tag(x, :foo)")
      {:ok, b} = Sourceror.parse_string("def f(x), do: tag(x, :bar)")

      assert skeleton_hash(a) == skeleton_hash(b)
    end

    test "two bodies differing only in a string literal hash equal" do
      {:ok, a} = Sourceror.parse_string(~s|def f(x), do: greet(x, "hi")|)
      {:ok, b} = Sourceror.parse_string(~s|def f(x), do: greet(x, "ho")|)

      assert skeleton_hash(a) == skeleton_hash(b)
    end

    test "two bodies differing only in a boolean literal hash equal" do
      {:ok, a} = Sourceror.parse_string("def f(x), do: flag(x, true)")
      {:ok, b} = Sourceror.parse_string("def f(x), do: flag(x, false)")

      assert skeleton_hash(a) == skeleton_hash(b)
    end

    test "two bodies differing only in nil vs atom literal hash equal" do
      {:ok, a} = Sourceror.parse_string("def f(x), do: tag(x, nil)")
      {:ok, b} = Sourceror.parse_string("def f(x), do: tag(x, :foo)")

      assert skeleton_hash(a) == skeleton_hash(b)
    end

    test "two bodies differing only in a float literal hash equal" do
      {:ok, a} = Sourceror.parse_string("def f(x), do: scale(x, 1.5)")
      {:ok, b} = Sourceror.parse_string("def f(x), do: scale(x, 2.5)")

      assert skeleton_hash(a) == skeleton_hash(b)
    end

    test "structural differences DO produce different hashes" do
      {:ok, a} = Sourceror.parse_string("def f(x), do: x + 1")
      {:ok, b} = Sourceror.parse_string("def f(x), do: x * 1")

      refute skeleton_hash(a) == skeleton_hash(b)
    end

    test "different number of args → different hashes" do
      {:ok, a} = Sourceror.parse_string("def f(x), do: g(x, 1)")
      {:ok, b} = Sourceror.parse_string("def f(x), do: g(x, 1, 1)")

      refute skeleton_hash(a) == skeleton_hash(b)
    end

    test "function call vs literal is structural — different hashes" do
      {:ok, a} = Sourceror.parse_string("def f(x), do: tag(x, :foo)")
      {:ok, b} = Sourceror.parse_string("def f(x), do: tag(x, foo())")

      refute skeleton_hash(a) == skeleton_hash(b)
    end

    test "preserves variables (not literals)" do
      # `x` is a variable reference, not a literal — must NOT be holed.
      {:ok, a} = Sourceror.parse_string("def f(x, y), do: g(x, y)")
      {:ok, b} = Sourceror.parse_string("def f(x, y), do: g(y, x)")

      # Different positions of vars → should NOT collapse to same hash.
      # (Variables are positional; the `rename_vars` pass elsewhere
      # normalizes per-position naming, but `replace_literals_with_holes`
      # alone leaves names untouched.)
      refute skeleton_hash(a) == skeleton_hash(b)
    end
  end

  describe "collect_bound_vars/1 — pattern-bound variables in an AST" do
    defp parse(src), do: Sourceror.parse_string!(src)

    defp bound(src),
      do:
        src
        |> parse()
        |> AstHelpers.collect_bound_vars()

    test "empty body — no bindings" do
      assert MapSet.new() == bound("foo()")
    end

    test "literal — no bindings" do
      assert MapSet.new() == bound("42")
    end

    test "bare var reference — not a binding" do
      # `x` here is a usage (rvalue), not a binding (lvalue).
      assert MapSet.new() == bound("x")
    end

    test "match operator binds the LHS var" do
      assert MapSet.new([:x]) == bound("x = 1")
    end

    test "case-clause LHS binds the pattern var" do
      result =
        bound("""
        case fetch(thing) do
          slug when is_binary(slug) -> use_it(slug)
          _ -> :ok
        end
        """)

      assert MapSet.member?(result, :slug)
    end

    test "fn anonymous function binds its arg vars" do
      result = bound("Enum.map(xs, fn x -> x + 1 end)")
      assert MapSet.member?(result, :x)
    end

    test "for comprehension binds generator vars" do
      result = bound("for n <- xs, do: n * 2")
      assert MapSet.member?(result, :n)
    end

    test "with happy-path binds intermediate vars" do
      result =
        bound("""
        with {:ok, user} <- fetch(id),
             {:ok, account} <- account_for(user) do
          {user, account}
        end
        """)

      assert MapSet.member?(result, :user)
      assert MapSet.member?(result, :account)
    end

    test "struct match `%S{} = x` binds the alias var" do
      result = bound("case y do %Foo{} = f -> f.x end")
      assert MapSet.member?(result, :f)
    end

    test "underscore-prefixed names are NOT collected" do
      result = bound("case y do _ignored -> :ok end")
      refute MapSet.member?(result, :_ignored)
    end

    test "tuple destructuring `{a, b} = pair` binds both" do
      result = bound("{a, b} = pair")
      assert MapSet.member?(result, :a)
      assert MapSet.member?(result, :b)
    end

    test "nested clauses propagate up — each `case` clause contributes" do
      result =
        bound("""
        case x do
          {:ok, a} -> a
          {:error, b} -> b
        end
        """)

      assert MapSet.member?(result, :a)
      assert MapSet.member?(result, :b)
    end
  end

  describe "inline_pipes/1 — rewrite |> chains as nested calls" do
    alias Number42.Refactors.AstHelpers

    test "non-pipe AST is returned unchanged" do
      ast = quote do: foo(1, 2)
      assert AstHelpers.inline_pipes(ast) == ast
    end

    test "single pipe with bare-atom call: `a |> b(1)` → `b(a, 1)`" do
      input = quote do: a |> b(1)
      output = AstHelpers.inline_pipes(input)
      assert output == quote(do: b(a, 1))
    end

    test "single pipe with dotted call: `x |> Mod.f(1)` → `Mod.f(x, 1)`" do
      input = quote do: x |> Mod.f(1)
      output = AstHelpers.inline_pipes(input)
      assert output == quote(do: Mod.f(x, 1))
    end

    test "pipe to var (zero-arity-call shape) is preserved as call: `x |> f` → `f(x)`" do
      # `f` here is the AST `{:f, _, ctx}` (atom ctx == var); we treat
      # it as a 0-arg call when piped into.
      input = {:|>, [], [{:x, [], nil}, {:f, [], nil}]}
      output = AstHelpers.inline_pipes(input)
      assert output == {:f, [], [{:x, [], nil}]}
    end

    test "chained pipes fold left-to-right: `a |> b(1) |> c(2)` → `c(b(a, 1), 2)`" do
      input = quote do: a |> b(1) |> c(2)
      output = AstHelpers.inline_pipes(input)
      assert output == quote(do: c(b(a, 1), 2))
    end

    test "nested pipe inside a non-pipe: `case (a |> b(1)) do …` is unfolded too" do
      input =
        quote do
          case a |> b(1) do
            x -> x
          end
        end

      expected =
        quote do
          case b(a, 1) do
            x -> x
          end
        end

      assert AstHelpers.inline_pipes(input) == expected
    end
  end

  describe "humanize_module/1 — derive a snake_case name from a module" do
    alias Number42.Refactors.AstHelpers

    test "single-segment module" do
      assert AstHelpers.humanize_module(MyApp) == "my_app"
    end

    test "multi-segment module — only the last segment is humanized" do
      assert AstHelpers.humanize_module(MyApp.ReferenceBuilding) == "reference_building"
    end

    test "deeply nested module" do
      assert AstHelpers.humanize_module(MyAppWeb.Components.CoreComponents) ==
               "core_components"
    end

    test "single capital letter is preserved as one segment" do
      assert AstHelpers.humanize_module(A) == "a"
    end

    test "consecutive capitals get split before the trailing lowercase block" do
      assert AstHelpers.humanize_module(HTTPClient) == "http_client"
    end

    test "alias AST node `{:__aliases__, _, [:Foo, :Bar]}` works the same" do
      ast = {:__aliases__, [], [:MyApp, :ReferenceBuilding]}
      assert AstHelpers.humanize_module(ast) == "reference_building"
    end

    test "nil/non-module input returns nil" do
      assert AstHelpers.humanize_module(nil) == nil
      assert AstHelpers.humanize_module(:not_a_module) == nil
      assert AstHelpers.humanize_module("string") == nil
    end
  end

  describe "name_from_value/1 — derive a candidate identifier from an AST hole-value" do
    alias Number42.Refactors.AstHelpers

    test "bare variable: `{:building, _, nil}` → `building`" do
      assert AstHelpers.name_from_value({:building, [], nil}) == "building"
    end

    test "atom literal: `:slug` → `slug`" do
      ast = {:__block__, [], [:slug]}
      assert AstHelpers.name_from_value(ast) == "slug"
    end

    test "atom literal with multi-word: `:position_updated` → `position_updated`" do
      ast = {:__block__, [], [:position_updated]}
      assert AstHelpers.name_from_value(ast) == "position_updated"
    end

    test "atom literal containing reserved word like `:end` is sanitized" do
      # `end` is a reserved word — naming a function arg `end` would
      # be a parse error. Sanitize via leading-underscore.
      ast = {:__block__, [], [:end]}
      assert AstHelpers.name_from_value(ast) == "end_"
    end

    test "dot-call: `assigns.group` → `group` (last property)" do
      input = quote do: assigns.group
      assert AstHelpers.name_from_value(input) == "group"
    end

    test "function call: `Module.changeset(x, y)` → `changeset` (fn name)" do
      input = quote do: Module.changeset(x, y)
      assert AstHelpers.name_from_value(input) == "changeset"
    end

    test "local function call: `something_or_other(x)` → `something_or_other`" do
      input = quote do: something_or_other(x)
      assert AstHelpers.name_from_value(input) == "something_or_other"
    end

    test "struct match pattern: `%ReferenceBuilding{} = b` → `reference_building`" do
      input = quote do: %ReferenceBuilding{} = b
      assert AstHelpers.name_from_value(input) == "reference_building"
    end

    test "kebab-case string literal becomes a snake_case identifier" do
      ast = {:__block__, [], ["hero-photo"]}
      assert AstHelpers.name_from_value(ast) == "hero_photo"
    end

    test "integer literal returns nil" do
      ast = {:__block__, [], [42]}
      assert AstHelpers.name_from_value(ast) == nil
    end

    test "non-AST input returns nil" do
      assert AstHelpers.name_from_value(:bare_atom) == nil
      assert AstHelpers.name_from_value(42) == nil
      assert AstHelpers.name_from_value("string") == nil
    end

    test "kebab-case atom literal: `:\"oz-fragment\"` → `oz_fragment`" do
      ast = {:__block__, [], [:"oz-fragment"]}
      assert AstHelpers.name_from_value(ast) == "oz_fragment"
    end

    test "kebab-case atom literal: `:\"parent-id\"` → `parent_id`" do
      ast = {:__block__, [], [:"parent-id"]}
      assert AstHelpers.name_from_value(ast) == "parent_id"
    end

    test "atom with leading dash maps to underscore-prefix (a valid var name)" do
      ast = {:__block__, [], [:"-bad"]}
      assert AstHelpers.name_from_value(ast) == "_bad"
    end

    test "atom with embedded special chars (`@`, `!`) is rejected" do
      ast = {:__block__, [], [:foo@bar]}
      assert AstHelpers.name_from_value(ast) == nil
    end

    test "kebab-case string literal: `\"logo-asset-id\"` → `logo_asset_id`" do
      ast = {:__block__, [], ["logo-asset-id"]}
      assert AstHelpers.name_from_value(ast) == "logo_asset_id"
    end

    test "single-word string literal: `\"name\"` → `name`" do
      ast = {:__block__, [], ["name"]}
      assert AstHelpers.name_from_value(ast) == "name"
    end

    test "free-form string with spaces returns nil" do
      ast = {:__block__, [], ["hello world"]}
      assert AstHelpers.name_from_value(ast) == nil
    end

    test "string with mixed casing returns nil" do
      ast = {:__block__, [], ["FooBar"]}
      assert AstHelpers.name_from_value(ast) == nil
    end
  end

  describe "singularize/1 — trailing ?/! markers" do
    # Function names in Elixir may end in `?` (predicate) or `!`
    # (raises). When those names get split into compounds, the trailing
    # marker rides along on the last subtoken: `apply_assignments!`
    # → `["apply", "assignments!"]`. The marker has to be dropped from
    # the result — it's a function-name marker, not a noun marker, and
    # `singularize`/`pluralize_word` produce variable names where
    # `!`/`?` are nonsensical.
    test "drops trailing `!` and singularizes the base" do
      assert AstHelpers.singularize("assignments!") == "assignment"
    end

    test "drops trailing `?` and singularizes the base" do
      assert AstHelpers.singularize("entries?") == "entry"
    end

    test "short word with `!` (≤ 2 base chars) passes through stripped" do
      assert AstHelpers.singularize("is!") == "is"
    end
  end

  describe "pluralize_word/1 — trailing ?/! markers" do
    test "drops trailing `!` and pluralizes the base" do
      assert AstHelpers.pluralize_word("assignment!") == "assignments"
    end

    test "drops trailing `?` and pluralizes the base" do
      assert AstHelpers.pluralize_word("entry?") == "entries"
    end

    test "y → ies still fires with `!` suffix (marker dropped)" do
      assert AstHelpers.pluralize_word("entry!") == "entries"
    end
  end

  describe "safe_append_suffix/3 — appending suffixes to names that may end in ?/!" do
    # Function names in Elixir may end in `?` (predicate) or `!`
    # (raises). Appending a suffix naively (`name <> "_shared"`)
    # produces parse errors (`references_var?_shared` is invalid).
    # Two modes are supported because callers diverge:
    #   :keep — function-name context, marker is meaningful;
    #           output stays a callable function name with the
    #           marker re-attached after the suffix.
    #   :drop — variable-name context, marker is meaningless;
    #           output is a clean identifier with the marker
    #           discarded.
    test ":keep mode re-attaches `?` after the suffix" do
      assert AstHelpers.safe_append_suffix("references_var?", "_shared", :keep) ==
               "references_var_shared?"
    end

    test ":keep mode re-attaches `!` after the suffix" do
      assert AstHelpers.safe_append_suffix("fetch_user!", "_shared", :keep) ==
               "fetch_user_shared!"
    end

    test ":keep mode on a plain name is a normal append" do
      assert AstHelpers.safe_append_suffix("emit", "_shared", :keep) == "emit_shared"
    end

    test ":drop mode discards `?` and appends the suffix" do
      assert AstHelpers.safe_append_suffix("references_var?", "_shared", :drop) ==
               "references_var_shared"
    end

    test ":drop mode discards `!` and appends the suffix" do
      assert AstHelpers.safe_append_suffix("fetch_user!", "_shared", :drop) ==
               "fetch_user_shared"
    end

    test ":drop mode on a plain name is a normal append" do
      assert AstHelpers.safe_append_suffix("emit", "_shared", :drop) == "emit_shared"
    end
  end

  describe "collect_calls/1" do
    defp calls(src),
      do: src |> Sourceror.parse_string!() |> AstHelpers.collect_calls() |> Enum.sort()

    test "records unqualified local calls with their arity" do
      assert calls("foo(a, b) + bar(c)") == [bar: 1, foo: 2]
    end

    test "corrects pipe right-hand-side arity by one" do
      assert calls("x |> foo(y) |> bar()") == [bar: 1, foo: 2]
    end

    test "ignores remote calls" do
      assert calls("Enum.map(list, fun)") == []
    end

    test "records both &name/arity capture forms" do
      assert calls("Enum.map(list, &helper/1)") == [helper: 1]
    end

    test "ignores special forms and operators" do
      # `case` is a special form and `+` an operator — neither is a local
      # call; only the genuine `a/1` and `b/1` calls are recorded.
      assert calls("case x + 1 do\n  1 -> a(x)\n  _ -> b(x)\nend") == [a: 1, b: 1]
    end

    test "static apply on __MODULE__ with literal name resolves to a concrete call" do
      assert calls("apply(__MODULE__, :foo, [a, b])") == [foo: 2]
    end

    test "apply with a non-literal function name yields the dynamic-dispatch sentinel" do
      assert calls("apply(__MODULE__, name, args)") == [__dynamic_dispatch__: 0]
    end

    test "apply with literal name but non-literal args is dynamic (arity unknown)" do
      assert calls("apply(__MODULE__, :foo, args)") == [__dynamic_dispatch__: 0]
    end

    test "apply to a non-__MODULE__ target with a literal name is treated as remote and ignored" do
      assert calls("apply(other_mod, :bar, [])") == []
    end

    test "Kernel.apply with a non-literal name yields the sentinel" do
      assert calls("Kernel.apply(__MODULE__, f, a)") == [__dynamic_dispatch__: 0]
    end

    test "apply is never recorded as a plain {:apply, 3} local call" do
      refute Enum.any?(calls("apply(__MODULE__, :foo, [a])"), &match?({:apply, _}, &1))
    end
  end

  describe "collect_calls_in_clauses/1" do
    defp clause_calls(src) do
      src
      |> Sourceror.parse_string!()
      |> AstHelpers.module_body_exprs()
      |> Enum.filter(&match?({kind, _, _} when kind in [:def, :defp], &1))
      |> AstHelpers.collect_calls_in_clauses()
      |> MapSet.to_list()
      |> Enum.sort()
    end

    test "unions calls across every clause of a function" do
      src = """
      defmodule M do
        def f(0), do: a()
        def f(n), do: b(n)
      end
      """

      assert clause_calls(src) == [a: 0, b: 1]
    end

    test "bodyless default-argument stubs contribute nothing" do
      src = """
      defmodule M do
        def f(x \\\\ [])
        def f(x), do: g(x)
      end
      """

      assert clause_calls(src) == [g: 1]
    end
  end

  describe "collect_definitions/1" do
    defp defs(src),
      do:
        src
        |> Sourceror.parse_string!()
        |> AstHelpers.module_body_exprs()
        |> AstHelpers.collect_definitions()

    test "groups clauses by kind/name/arity and records their calls" do
      src = """
      defmodule M do
        def pub(x), do: helper(x)
        defp helper(x), do: x
      end
      """

      by_key = Map.new(defs(src), &{{&1.kind, &1.name, &1.arity}, &1})

      assert MapSet.to_list(by_key[{:def, :pub, 1}].calls) == [helper: 1]
      assert MapSet.to_list(by_key[{:defp, :helper, 1}].calls) == []
    end

    test "multiple clauses of the same function collapse into one definition" do
      src = """
      defmodule M do
        def f(0), do: :zero
        def f(_), do: :other
      end
      """

      assert [%{name: :f, arity: 1, clauses: clauses}] = defs(src)
      assert length(clauses) == 2
    end
  end

  describe "transitive_closure/2" do
    test "reaches every node transitively from the roots" do
      graph = %{
        {:a, 0} => MapSet.new([{:b, 0}]),
        {:b, 0} => MapSet.new([{:c, 0}]),
        {:c, 0} => MapSet.new(),
        {:orphan, 0} => MapSet.new()
      }

      reached = AstHelpers.transitive_closure(MapSet.new([{:a, 0}]), graph)

      assert MapSet.to_list(reached) |> Enum.sort() == [a: 0, b: 0, c: 0]
    end

    test "tolerates cycles" do
      graph = %{
        {:a, 0} => MapSet.new([{:b, 0}]),
        {:b, 0} => MapSet.new([{:a, 0}])
      }

      reached = AstHelpers.transitive_closure(MapSet.new([{:a, 0}]), graph)

      assert MapSet.to_list(reached) |> Enum.sort() == [a: 0, b: 0]
    end
  end

  describe "reachable_defs/2 — conservative apply/3 dead-code analysis" do
    defp reachable(src) do
      defs =
        src
        |> Sourceror.parse_string!()
        |> AstHelpers.module_body_exprs()
        |> AstHelpers.collect_definitions()

      roots =
        defs |> Enum.filter(&(&1.kind == :def)) |> Enum.map(&{&1.name, &1.arity}) |> MapSet.new()

      defs |> AstHelpers.reachable_defs(roots) |> MapSet.to_list() |> Enum.sort()
    end

    test "a private function reachable from a public root is live" do
      src = """
      defmodule M do
        def pub(x), do: helper(x)
        defp helper(x), do: x
      end
      """

      assert reachable(src) == [helper: 1, pub: 1]
    end

    test "an unreachable private function is dead (absent)" do
      src = """
      defmodule M do
        def pub(x), do: x
        defp orphan(x), do: x
      end
      """

      refute {:orphan, 1} in reachable(src)
    end

    test "a dynamic apply marks every local def as reachable" do
      src = """
      defmodule M do
        def pub(x, name), do: apply(__MODULE__, name, [x])
        defp only_via_apply(x), do: x
      end
      """

      assert {:only_via_apply, 1} in reachable(src)
    end
  end

  describe "dynamic_dispatch?/1" do
    test "true when the sentinel is present" do
      assert AstHelpers.dynamic_dispatch?([{:foo, 1}, {:__dynamic_dispatch__, 0}])
    end

    test "false for an ordinary call set" do
      refute AstHelpers.dynamic_dispatch?([{:foo, 1}, {:bar, 2}])
    end
  end

  describe "pure?/1 — total + exception-free + eager" do
    defp pure?(src), do: src |> Sourceror.parse_string!() |> AstHelpers.pure?()

    test "literals, variables and constructors are pure" do
      assert pure?("42")
      assert pure?(":atom")
      assert pure?(~s|"hi"|)
      assert pure?("x")
      assert pure?("[1, 2, x]")
      assert pure?("{:ok, x}")
      assert pure?("%{a: 1, b: x}")
    end

    test "arithmetic, comparison and boolean operators over pure leaves are pure" do
      assert pure?("a + b * 2")
      assert pure?("a == b and c > d")
      assert pure?("not flag || other")
    end

    test "eager Enum/Map/String over pure functions are pure" do
      assert pure?("Enum.map(list, fn x -> x + 1 end)")
      assert pure?("Map.get(m, :key)")
      assert pure?("String.downcase(s)")
      assert pure?("x |> Enum.map(fn y -> y * 2 end) |> Enum.sum()")
    end

    test "raising String conversions are impure" do
      refute pure?("String.to_integer(s)")
      refute pure?("String.to_atom(s)")
    end

    test "bang functions are impure" do
      refute pure?("Map.fetch!(m, :k)")
      refute pure?("File.read!(path)")
    end

    test "Stream sources are impure (lazy)" do
      refute pure?("Stream.map(list, fn x -> x end)")
    end

    test "division and integer division/remainder are impure (zero divisor raises)" do
      refute pure?("a / b")
      refute pure?("div(a, b)")
      refute pure?("rem(a, b)")
    end

    test "effects and dynamic dispatch are impure" do
      refute pure?(~s|raise "boom"|)
      refute pure?("send(pid, :msg)")
      refute pure?("apply(mod, :f, [])")
      refute pure?("IO.puts(x)")
    end

    test "partial Kernel functions are impure" do
      refute pure?("hd(list)")
      refute pure?("elem(tuple, 0)")
      refute pure?("Enum.at(list, 3)")
    end

    test "unknown remote and local calls are conservatively impure" do
      refute pure?("SomeMod.unknown_fn(x)")
      refute pure?("unknown_local(x)")
    end

    test "calls through an anonymous function value are impure (opaque target)" do
      refute pure?("fun.(x)")
    end

    test "map/struct dot-access is impure (KeyError on a missing key)" do
      refute pure?("m.field")
      refute pure?("Enum.filter(list, & &1.active)")
    end
  end

  describe "read_after?/3 — ordered liveness over a statement list" do
    defp stmts(src), do: src |> Sourceror.parse_string!() |> AstHelpers.body_to_exprs()

    test "a value read by a later statement is live after its binding" do
      e = stmts("(\n  x = compute()\n  y = 1\n  use(x)\n)")
      assert AstHelpers.read_after?(:x, e, 0)
    end

    test "a value never read again is dead after its binding" do
      e = stmts("(\n  x = compute()\n  y = 1\n  use(x)\n)")
      refute AstHelpers.read_after?(:y, e, 1)
    end

    test "the statement at the index itself is not counted as a later read" do
      e = stmts("(\n  x = compute()\n  y = 1\n  use(x)\n)")
      refute AstHelpers.read_after?(:x, e, 2)
    end

    test "a later read counts even if the variable is rebound first" do
      e = stmts("(\n  a = 1\n  a = 2\n  b = a\n)")
      assert AstHelpers.read_after?(:a, e, 0)
    end

    test "an out-of-range index yields false" do
      e = stmts("(\n  x = 1\n  use(x)\n)")
      refute AstHelpers.read_after?(:x, e, 99)
    end
  end

  describe "branches_reading/2 and live_in_single_branch?/2" do
    defp branch_bodies(src) do
      {:case, _, [_scrutinee, [{_do, clauses}]]} = Sourceror.parse_string!(src)
      Enum.map(clauses, fn {:->, _, [_head, body]} -> body end)
    end

    test "reports the indices of branches that read the variable" do
      branches =
        branch_bodies("""
        case val do
          :a -> use(x)
          :b -> other()
          _ -> also(x)
        end
        """)

      assert AstHelpers.branches_reading(:x, branches) == [0, 2]
    end

    test "a variable bound inside a branch is not read there" do
      branches =
        branch_bodies("""
        case val do
          :a -> (z = 1; use(z))
          :b -> use(z)
        end
        """)

      assert AstHelpers.branches_reading(:z, branches) == [1]
    end

    test "live_in_single_branch? is true for exactly one reading branch" do
      branches =
        branch_bodies("""
        case val do
          :a -> use(x)
          :b -> other()
        end
        """)

      assert AstHelpers.live_in_single_branch?(:x, branches)
    end

    test "live_in_single_branch? is false when two branches read the variable" do
      branches =
        branch_bodies("""
        case val do
          :a -> use(y)
          :b -> also(y)
        end
        """)

      refute AstHelpers.live_in_single_branch?(:y, branches)
    end
  end
end
