defmodule Number42.Refactors.Ex.TableDriveSimilarTests do
  @moduledoc """
  Collapse a run of structurally-identical ExUnit `test` blocks — same
  assertion skeleton, differing only in literal values — into one
  table-driven comprehension that generates the cases from a data list.

      # before
      defmodule AddTest do
        use ExUnit.Case, async: true

        test "adds one" do
          assert add(1) == 2
        end

        test "adds two" do
          assert add(2) == 3
        end

        test "adds three" do
          assert add(3) == 4
        end
      end

      # after
      defmodule AddTest do
        use ExUnit.Case, async: true

        for %{desc: desc, arg_0: arg_0, arg_1: arg_1} <- [
              %{desc: "adds one", arg_0: 1, arg_1: 2},
              %{desc: "adds two", arg_0: 2, arg_1: 3},
              %{desc: "adds three", arg_0: 3, arg_1: 4}
            ] do
          test "\#{desc}" do
            assert add(arg_0) == arg_1
          end
        end
      end

  Each divergent literal position becomes one map column (`arg_0`,
  `arg_1`, …); the per-test name becomes the `desc` row label and drives
  the generated test's name (`test "\#{desc}" do`), keeping every
  generated case uniquely and meaningfully named.

  ## Detection

  Scoped to **ExUnit test modules** (`use …Case` / `ExUnit.Case`, or a
  `…Test` module name) — the engine sees only a source string, not its
  path, so test-ness is detected from the source itself. This is the
  `test/**/*.exs`-only scope the feature requires.

  Within such a module, *consecutive* 2-argument `test "name" do … end`
  blocks are bucketed by the structural hash of their bodies (literals
  replaced by a single hole). A bucket of `>= :min_tests` consecutive
  tests is a candidate; `Number42.Refactors.AstDiff` then computes the
  per-position literal divergences (the table columns).

  ## False-positive guards (skip — leave the tests alone)

    * **`:min_tests`** (default 3) — fewer similar tests than this is not
      worth a generated table; the standalone tests read fine.
    * **Divergent assertion structure** — only literal differences are
      collapsible. Any structural divergence (different calls, operators,
      added/removed assertions) lands in a different skeleton bucket and
      is never grouped.
    * **Setup-context tests** — a `test "name", %{…} = ctx do … end` pulls
      setup-scoped values that may be used differently per case; skipped.
    * **Comments** — a test carrying leading/trailing comments documents
      something case-specific that a generated row would erase; the whole
      group is skipped if any member has comments.
    * **`:max_columns`** (default 4) — a table needing more columns than
      this is less legible than the standalone tests; skipped.
    * **Non-literal divergences** — if tests differ in a non-literal
      subtree (a call, a variable), the hole is not a plain table value;
      skipped (conservative — only `:literal`/`:data` holes collapse).

  ## Default-OFF (opt-in only)

  Disabled by default — `transform/2` is a no-op unless its opts carry
  `enabled: true`. Rewriting hand-written tests into a generated loop is
  a judgement call (a table can hurt readability and obscures per-case
  failure locations), so it is opt-in per project:

      configured_modules: [
        {Number42.Refactors.Ex.TableDriveSimilarTests, enabled: true}
      ]
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.AstDiff
  alias Number42.Refactors.AstHelpers

  @default_min_tests 3
  @default_max_columns 4

  @impl Number42.Refactors.Refactor
  def description,
    do: "Collapse cloned ExUnit tests into a table-driven comprehension (test-only, default-OFF)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Detects a run of consecutive ExUnit `test` blocks that share one
    assertion skeleton and differ only in literal values, and rewrites
    them into a single `for %{...} <- cases, do: test ... end`
    comprehension. The divergent literals become table columns; each
    test's name becomes a `desc` row label that names the generated
    case. Conservative: only fires on >= :min_tests literal-only clones
    within a table no wider than :max_columns, and skips tests with a
    setup context, comments, or divergent assertion structure.
    Test-files only, default-OFF — opt in with `enabled: true`.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      source
      |> Sourceror.parse_string()
      |> apply_to_parse_result(config(opts), source)
    else
      source
    end
  end

  defp config(opts) do
    %{
      min_tests: Keyword.get(opts, :min_tests, @default_min_tests),
      max_columns: Keyword.get(opts, :max_columns, @default_max_columns)
    }
  end

  defp apply_to_parse_result({:ok, ast}, cfg, source), do: apply_to_ast(ast, cfg, source)
  defp apply_to_parse_result({:error, _}, _cfg, source), do: source

  defp apply_to_ast(ast, cfg, source) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [_name, [{_do, body}]]} = mod_node ->
        plan_for_module(mod_node, body, cfg)

      _ ->
        []
    end)
    |> patch_or_passthrough(source)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  # --- detection ---------------------------------------------------------

  defp plan_for_module(_mod_node, body, cfg) do
    exprs = AstHelpers.body_to_exprs(body)

    if test_module?(exprs) do
      exprs
      |> consecutive_test_runs()
      |> Enum.flat_map(&plan_for_run(&1, cfg))
    else
      []
    end
  end

  # A test module either `use`s an ExUnit-style `…Case`/`ExUnit.Case`, so
  # the `test` macro is in scope. The engine gives no path, so this stands
  # in for the `test/**/*.exs` scope.
  defp test_module?(exprs) do
    exprs
    |> Enum.any?(fn
      {:use, _, [alias_node | _]} -> case_use?(alias_node)
      _ -> false
    end)
  end

  defp case_use?({:__aliases__, _, parts}) do
    last = parts |> List.last() |> to_string()
    parts == [:ExUnit, :Case] or String.ends_with?(last, "Case")
  end

  defp case_use?(_), do: false

  # Group consecutive 2-arg, comment-free `test "name" do … end` nodes by
  # the structural hash of their bodies. Only *consecutive* tests are
  # grouped: an intervening non-test expr (a `setup`, a helper, a
  # differently-shaped test) breaks the run, so a collapsed group is always
  # a contiguous source span the rewrite can splice over cleanly.
  defp consecutive_test_runs(exprs) do
    exprs
    |> Enum.map(&classify_expr/1)
    |> chunk_runs()
  end

  defp classify_expr(expr) do
    case test_info(expr) do
      {:ok, info} -> {:test, info}
      :skip -> :break
    end
  end

  # Split the classified stream into maximal runs of same-skeleton tests.
  defp chunk_runs(classified) do
    classified
    |> Enum.chunk_by(fn
      {:test, %{skeleton_hash: h}} -> h
      :break -> make_ref()
    end)
    |> Enum.flat_map(fn
      [{:test, _} | _] = run -> [Enum.map(run, fn {:test, info} -> info end)]
      _ -> []
    end)
  end

  # A collapsible test: `test "literal name" do body end`. Returns its name
  # literal, body AST, source node, and a skeleton hash for bucketing.
  # Rejected (→ :skip, breaks the run):
  #   * 3-arg context form `test "name", %{…} do … end` (setup-scoped)
  #   * a non-literal name (interpolated / dynamic)
  #   * any leading/trailing comment on the node (case-specific docs)
  defp test_info({:test, meta, [name_node, [{_do, body}]]} = node) do
    cond do
      has_comments?(meta) or node_has_comments?(name_node) ->
        :skip

      literal_name(name_node) == :error ->
        :skip

      true ->
        {:ok,
         %{
           body: body,
           name: name_node,
           node: node,
           skeleton_hash: skeleton_hash(body)
         }}
    end
  end

  defp test_info(_), do: :skip

  defp literal_name({:__block__, _, [name]}) when is_binary(name), do: {:ok, name}
  defp literal_name(_), do: :error

  defp has_comments?(meta) do
    Keyword.get(meta, :leading_comments, []) != [] or
      Keyword.get(meta, :trailing_comments, []) != []
  end

  defp node_has_comments?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {_, meta, _} when is_list(meta) -> has_comments?(meta)
      _ -> false
    end)
  end

  # --- planning ----------------------------------------------------------

  defp plan_for_run(run, cfg) when length(run) < cfg.min_tests, do: []

  defp plan_for_run(run, cfg) do
    bodies = Enum.map(run, & &1.body)
    %{holes: holes, skeleton: skeleton} = AstDiff.tree_diff(bodies)

    with :ok <- check_body_has_comments(run),
         columns = dedupe_holes(holes),
         :ok <- check_collapsible(columns, cfg) do
      emit_patch(run, skeleton, columns)
    else
      :skip -> []
    end
  end

  # The diff only sees the *bodies*; a comment on a node inside a body
  # would be silently dropped by the generated single body. Reject the run.
  defp check_body_has_comments(run) do
    if Enum.any?(run, &node_has_comments?(&1.body)), do: :skip, else: :ok
  end

  defp check_collapsible([], _cfg), do: :skip

  defp check_collapsible(columns, cfg) do
    cond do
      length(columns) > cfg.max_columns -> :skip
      Enum.any?(columns, &(&1.kind == :expr)) -> :skip
      true -> :ok
    end
  end

  # Holes whose per-test value vector is identical collapse to one column
  # (the same value at every position is not a divergence worth a column —
  # it stays inlined via the shared value). Distinct vectors each get a
  # column var `arg_0`, `arg_1`, … in first-appearance order.
  defp dedupe_holes(holes) do
    holes
    |> Enum.reduce([], &merge_hole/2)
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {hole, idx} -> Map.put(hole, :var, :"arg_#{idx}") end)
  end

  defp merge_hole(hole, acc) do
    key = dedup_key(hole.values)

    case Enum.find_index(acc, &(&1.dedup_key == key)) do
      nil ->
        [%{dedup_key: key, kind: hole.kind, paths: [hole.path], values: hole.values} | acc]

      idx ->
        List.update_at(acc, idx, &%{&1 | paths: &1.paths ++ [hole.path]})
    end
  end

  defp dedup_key(values), do: values |> Enum.map(&strip_meta/1)

  # --- emission ----------------------------------------------------------

  # Replace the first test's source range with the generated `for`
  # comprehension; delete the trailing tests' ranges. The comprehension
  # binds `desc` + one var per column out of each data row and feeds them
  # into a single `test "\#{desc}" do <inflated body> end`.
  defp emit_patch([first | rest], skeleton, columns) do
    comprehension = render_comprehension(skeleton, columns, [first | rest])

    delete_patches =
      rest
      |> Enum.map(fn %{node: node} -> %{change: "", range: Sourceror.get_range(node)} end)

    [%{change: comprehension, range: Sourceror.get_range(first.node)} | delete_patches]
  end

  defp render_comprehension(skeleton, columns, run) do
    pattern = render_pattern(columns)
    rows = render_rows(columns, run)
    body = render_body(skeleton, columns)

    """
    for #{pattern} <- [
    #{rows}
        ] do
      test "\#{desc}" do
    #{body}
      end
    end\
    """
  end

  # `%{desc: desc, arg_0: arg_0, …}` — binds the label and every column.
  defp render_pattern(columns) do
    fields =
      [{:desc, :desc} | Enum.map(columns, &{&1.var, &1.var})]
      |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{v}" end)

    "%{#{fields}}"
  end

  # One `%{desc: "name", arg_0: <value>, …}` per test, indented as a list
  # element. Column values are the THIS-test slice of each hole's value
  # vector, rendered from their Sourceror AST.
  defp render_rows(columns, run) do
    run
    |> Enum.with_index()
    |> Enum.map_join(",\n", fn {info, test_idx} ->
      {:ok, name} = literal_name(info.name)

      cells =
        columns
        |> Enum.map(fn col ->
          value = col.values |> Enum.at(test_idx)
          "#{col.var}: #{Sourceror.to_string(value)}"
        end)

      fields = ["desc: #{inspect(name)}" | cells] |> Enum.join(", ")
      "      %{#{fields}}"
    end)
  end

  # The shared body with each hole replaced by its column var, rendered and
  # indented under the generated `test … do`.
  defp render_body(skeleton, columns) do
    skeleton
    |> inflate(columns)
    |> Sourceror.to_string()
    |> indent("    ")
  end

  # Replace every `{:"$hole", _, [path]}` placeholder with `unquote(var)`.
  #
  # The `unquote` is load-bearing: ExUnit's `test` macro quotes its body
  # into a generated function whose scope does NOT close over the
  # surrounding `for` comprehension's bindings. `unquote(arg_0)` splices the
  # per-iteration value in at macro-expansion time, which is exactly how
  # idiomatic ExUnit table-driven tests reference their loop variables.
  defp inflate(skeleton, columns) do
    path_to_var =
      columns
      |> Enum.flat_map(fn %{paths: paths, var: var} ->
        Enum.map(paths, &{&1, var})
      end)
      |> Map.new()

    Macro.prewalk(skeleton, fn
      {:"$hole", _, [path]} = node ->
        case Map.get(path_to_var, path) do
          nil -> node
          var -> {:unquote, [], [{var, [], nil}]}
        end

      other ->
        other
    end)
  end

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) -> {form, [], args}
      other -> other
    end)
  end

  # Structural hash of a test body modulo metadata and literal values — two
  # bodies bucket together iff they differ only in literals.
  defp skeleton_hash(body) do
    body
    |> Macro.prewalk(fn
      {:__block__, _meta, [v]}
      when is_atom(v) or is_integer(v) or is_float(v) or is_binary(v) ->
        {:"$lit", [], [0]}

      {form, meta, args} when is_list(meta) ->
        {form, [], args}

      other ->
        other
    end)
    |> :erlang.phash2()
  end

  defp indent(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end
end
