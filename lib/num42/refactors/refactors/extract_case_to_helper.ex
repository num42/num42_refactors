defmodule Num42.Refactors.Refactors.ExtractCaseToHelper do
  @moduledoc """
  Extracts a `case <call>(args) do ... end` that sits as the **last
  expression** of a `def`/`defp` body into a private helper named
  `handle_<host_fn>_<scrutinee_fn>/N`. Each `case` clause becomes a
  helper clause; the original `case` is replaced by a pipe call that
  threads the scrutinee result into the helper.

  ## Why

  `case` in tail position of a function tends to grow into the actual
  business of the function — the surrounding `def` becomes a thin
  shell whose only job is "call X then dispatch on the result". Lifting
  the dispatch into a separate, multi-clause helper lets each branch
  stand on its own (testable, named, without the visual noise of
  `{:ok, ...} ->` indentation), and turns the host function into a
  one-liner pipe.

  ## What fires

      def host(a, b, ctx) do
        # ...maybe other statements first...
        case fetch(a, b) do
          {:ok, value} -> use(value, ctx)
          :error       -> default(ctx)
        end
      end

  becomes

      def host(a, b, ctx) do
        # ...maybe other statements first...
        fetch(a, b) |> handle_host_fetch(ctx)
      end

      defp handle_host_fetch({:ok, value}, ctx), do: use(value, ctx)
      defp handle_host_fetch(:error, ctx), do: default(ctx)

  ## Constraints

  - The `case` must be the **last** top-level expression of a `def` or
    `defp` clause. Nested `case`-in-`if`-in-... is not extracted.
  - The scrutinee must be a **plain function call** `f(...)` or
    `Mod.f(...)` — no pipes, no operators, no literals. Mirrors what
    "extract this dispatch step" reads like in practice.
  - **Free variables** are computed per branch (variables referenced in
    a clause that are bound *outside* the `case` — i.e. function
    parameters or earlier `=`-bindings in the same `def` body), then
    unioned across all clauses to give every helper clause the same
    arity. The first parameter is always the scrutinee result.
  - **Collision handling** on the synthesized helper name:
    - If a private helper with the same name AND arity already exists
      and its clauses match the extraction's clauses one-for-one
      (patterns, guards, bodies, modulo metadata), the extraction is
      a no-op — the work has already happened.
    - Otherwise, the refactor walks `_2`, `_3`, ... appended to the
      base name until it finds a free slot (or another structural
      match → no-op). Same-name/different-arity counts as a collision
      to keep the FIXME helper visually grouped.

  ## Why procedural

  Multi-node surgery: the existing `case` gets rewritten in place AND
  one or more new helper definitions get appended at module end. Not
  expressible as a single 1:1 declarative pattern.

  Source for clause patterns/bodies and call args is spliced via
  `slice_node/2` — preserves the user's exact formatting (string
  escapes, comments inside expressions, parens) where re-emitting
  through `Sourceror.to_string/1` would not.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Num42.Refactors.Refactor
  def description, do: "case <call>(...) do ... end at tail of fn -> extract handle_<host>_<call>"

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    A `case` whose scrutinee is a function call and which sits as the
    last expression of a `def` body is doing two things at once: it
    runs the call, and it dispatches on the result. Each clause body
    is independently meaningful — a success path, an error path, a
    not-found path — but all four are visually merged into one block.

    Lifting the dispatch into a multi-clause private helper named after
    the scrutinee makes each branch standalone: it has a name, a
    signature, and can be unit-tested in isolation. The host function
    collapses to one line: "run the call, hand the result to the
    handler". The result is a flatter call graph and clauses you can
    point at by name when reviewing or debugging.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_patches(ast, source), do: module_body(ast) |> extractions_in_body(source)

  defp find_extraction({def_kind, _meta, [head, [{_do, body}]]}, defps)
       when def_kind?(def_kind) do
    host_name = function_name(head)
    body_exprs = body_to_exprs(body)
    last_expr = List.last(body_exprs)

    with {:ok, scrutinee, clauses, case_node} <- match_tail_case(last_expr),
         {:ok, scrutinee_name} <- callee_name(scrutinee),
         # `super` is bound to the enclosing `def`/`defp` — moving its
         # call into a synthesized helper would change which definition
         # it overrides (and the arity check fails). Skip extraction
         # entirely when any clause body or guard references `super`.
         false <- Enum.any?(clauses, &clause_uses_super?/1),
         # A pinned variable (`^var`) in a clause pattern or guard refers
         # to a binding from the enclosing function's scope. The
         # synthesized helper has its own scope, so the pin would refer
         # to nothing — extraction would emit code that fails to compile.
         # Skip whole-cloth; the reviewer can extract by hand if desired.
         false <- Enum.any?(clauses, &clause_uses_pin?/1),
         # If EVERY clause body is "non-complex" — i.e. a literal, bare
         # variable, tuple of non-complex parts, 0-2-arg call of
         # non-complex args, op of non-complex operands, or 1-stage
         # pipe of non-complex parts — the case is trivial dispatch
         # and lifting it into a helper costs more than it saves. The
         # `handle_*` indirection only earns its keep when at least
         # ONE branch carries real work (multi-stage pipe, 3+-arg call,
         # nested case/if/with, map literal, list literal, &-capture,
         # lambda, raise/throw/exit, block, …).
         false <- non_complex_case?(clauses) do
      base_name =
        synth_compound_name(
          "handle",
          strip_name_suffix(host_name),
          strip_name_suffix(scrutinee_name),
          ""
        )

      head_params =
        head |> function_param_patterns() |> Enum.flat_map(&pattern_var_names/1) |> MapSet.new()

      preceding_binds =
        body_exprs
        |> Enum.take_while(&(&1 != last_expr))
        |> Enum.reduce(MapSet.new(), fn expr, acc -> MapSet.union(acc, bound_in(expr)) end)

      available = MapSet.union(head_params, preceding_binds)

      branches = clauses |> Enum.map(&analyze_clause(&1, available))

      free_vars =
        branches
        |> Enum.flat_map(& &1.free_vars)
        |> Enum.uniq()
        |> Enum.sort()

      arity = length(free_vars) + 1

      case resolve_handler_name(base_name, arity, branches, free_vars, defps) do
        :skip ->
          []

        {:ok, helper_name} ->
          [
            %{
              branches: branches,
              case_node: case_node,
              def_kind: def_kind,
              free_vars: free_vars,
              helper_name: helper_name,
              scrutinee_node: scrutinee
            }
          ]
      end
    else
      _ -> []
    end
  end

  defp find_extraction(_, _), do: []

  # Recognize a `case <call>(...) do clauses end` whose scrutinee is a
  # plain function call (local or remote). Pipes, operators, literals,
  # and bare variables are rejected — the synthesized helper name is
  # derived from the scrutinee callee, so a non-call scrutinee would
  # produce a meaningless name.
  defp match_tail_case({:case, _, [scrutinee, [{_do, clauses_kw}]]} = node) do
    cond do
      not call?(scrutinee) ->
        :error

      not is_list(clauses_kw) ->
        :error

      true ->
        clauses =
          clauses_kw
          |> Enum.flat_map(fn
            {:->, meta, [pattern_list, body]} -> [{:->, meta, [pattern_list, body]}]
            _ -> []
          end)

        if clauses == [] do
          :error
        else
          {:ok, scrutinee, clauses, node}
        end
    end
  end

  defp match_tail_case(_), do: :error

  defp call?({{:., _, [{:__aliases__, _, _}, fname]}, _, args})
       when is_atom(fname) and is_list(args),
       do: true

  defp call?({fname, _, args}) when is_atom(fname) and is_list(args) do
    # Reject AST shapes that look like calls but aren't user-level
    # function calls. The variable disambiguation `{name, _, ctx}`
    # where `ctx` is atom ≠ list is already excluded by the
    # `args is_list` guard above. Operators (`|>`, `+`, `==`, ...)
    # and special forms have non-identifier names that fail the
    # identifier regex below.
    name = Atom.to_string(fname)

    Regex.match?(~r/^[a-z_][a-zA-Z0-9_]*[!?]?$/, name) and
      fname not in [:case, :cond, :if, :unless, :with, :for, :receive, :try, :fn, :__block__]
  end

  defp call?(_), do: false

  # Single AST clause `[{pattern}] -> body` (case clauses always have
  # exactly one pattern; multi-pattern is rare and we don't support it).
  # A `pattern when guard` clause is wrapped as
  # `{:when, _, [actual_pattern, guard]}`; we split it so pattern,
  # guard, and body each get their own variable analysis. The guard
  # stays attached to the synthesized helper clause as `… when guard do`.
  defp analyze_clause({:->, _meta, [[pattern_node], body]}, available) do
    {pattern, guard} = unwrap_when(pattern_node)
    pattern_names = pattern |> pattern_var_names() |> MapSet.new()

    # Vars bound by the pattern itself shadow outer scope inside the
    # branch body — so they're available there, not "free".
    branch_available = MapSet.difference(available, pattern_names)

    # Scope-aware uses: a `token` referenced inside `from(token in …)`
    # is the Ecto binding, not the outer var, so it doesn't count as a
    # use of the outer name. `free_vars/2` uses the syntactic walker
    # from `AstHelpers` which would over-include such names; we redo
    # the intersection here against `branch_available`.
    body_used = outer_used_var_names(body)
    guard_used = if guard, do: outer_used_var_names(guard), else: MapSet.new()
    used = MapSet.union(body_used, guard_used)

    free =
      used
      |> MapSet.intersection(branch_available)
      |> MapSet.to_list()
      |> Enum.sort()

    %{
      body: body,
      free_vars: free,
      guard: guard,
      pattern: pattern,
      used_in_body: used
    }
  end

  # Multi-pattern `case` clauses (`a, b -> ...`) are syntactically
  # invalid for `case`; fall through defensively.
  defp analyze_clause(_, _),
    do: %{body: nil, free_vars: [], guard: nil, pattern: nil, used_in_body: MapSet.new()}

  defp unwrap_when({:when, _meta, [pat, guard]}), do: {pat, guard}
  defp unwrap_when(pat), do: {pat, nil}

  # `super` is statically bound to the surrounding `def`/`defp` — it
  # references the parent module's same-name/arity definition (e.g. via
  # `defoverridable`). Moving the call into a synthesized helper makes
  # `super` resolve against the helper's name/arity instead, which is
  # either undefined or has the wrong arity and fails to compile.
  defp clause_uses_super?({:->, _meta, [[pattern_node], body]}) do
    {_pat, guard} = unwrap_when(pattern_node)
    contains_super?(body) or (guard && contains_super?(guard))
  end

  defp clause_uses_super?(_), do: false

  defp contains_super?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:super, _, args} when is_list(args) -> true
      _ -> false
    end)
  end

  # A pin (`^var`) in a case clause pattern or guard binds against a
  # variable from the enclosing function's scope. The synthesized helper
  # has its own scope, so emitting the pin verbatim would either reference
  # nothing (compile error) or shadow the wrong name. Detect any pin
  # anywhere in the pattern or guard and skip the whole extraction.
  defp clause_uses_pin?({:->, _meta, [[pattern_node], _body]}) do
    {pat, guard} = unwrap_when(pattern_node)
    contains_pin?(pat) or (guard && contains_pin?(guard))
  end

  defp clause_uses_pin?(_), do: false

  defp contains_pin?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:^, _, [_]} -> true
      _ -> false
    end)
  end

  defp emit_patches(target, source, append_at_line) do
    %{
      branches: branches,
      case_node: case_node,
      def_kind: def_kind,
      free_vars: free_vars,
      helper_name: helper_name,
      scrutinee_node: scrutinee_node
    } = target

    build_replacement_call(source, scrutinee_node, helper_name, free_vars)
    |> patches_for_call_or_skip(
      append_at_line,
      branches,
      case_node,
      def_kind,
      free_vars,
      helper_name,
      source
    )
  end

  defp build_replacement_call(source, scrutinee_node, helper_name, free_vars),
    do:
      slice_node(source, scrutinee_node)
      |> pipe_call_text_or_error(free_vars, helper_name)

  defp render_helper_clauses(def_kind, helper_name, branches, free_vars, source) do
    # Always private — helpers are an internal dispatch step, not a
    # public API. Even when the host was `def`, the synthesized helper
    # is `defp`. Callers stay through the public host.
    _ = def_kind

    fixme = """
      # FIXME: extracted automatically by ExtractCaseToHelper — review
      # the parameter list and consider a better name.\
    """

    clause_texts =
      branches
      |> Enum.map(fn %{body: body, guard: guard, pattern: pattern, used_in_body: used} ->
        pattern_text = render_pattern_text(pattern, source)
        body_text = render_body_text(body, source)

        # Per-clause: prefix `_` on extra params not referenced in this
        # clause's body or guard. The pipe call site keeps the real
        # names — this only affects the signature, mirroring the
        # compiler's "variable X is unused" hint.
        extra_params =
          free_vars
          |> Enum.map(fn var ->
            name = Atom.to_string(var)
            if MapSet.member?(used, var), do: name, else: "_" <> name
          end)

        params = [pattern_text | extra_params]
        params_str = params |> Enum.join(", ")

        guard_clause =
          case guard do
            nil -> ""
            node -> " when " <> render_guard_text(node, source)
          end

        """
          defp #{helper_name}(#{params_str})#{guard_clause} do
        #{indent_body(body_text)}
          end\
        """
      end)

    [fixme | clause_texts] |> Enum.join("\n")
  end

  defp render_pattern_text(pattern, source),
    do: slice_node(source, pattern) |> pattern_text_or_render(pattern)

  defp render_guard_text(guard, source),
    do: slice_node(source, guard) |> guard_text_or_render(guard)

  # Sourceror represents `lhs not in rhs` as `{:not, _, [{:in, _, [lhs, rhs]}]}`
  # — the `:not` node's range starts at the `not` keyword and does NOT include
  # the LHS. Slicing it would drop `lhs`, yielding the syntactically invalid
  # `not in rhs`. Re-emit via `Sourceror.to_string/1` for these shapes.
  defp render_body_text({:not, _, [{:in, _, [_lhs, _rhs]}]} = body, _source),
    do: body |> Sourceror.to_string()

  defp render_body_text(body, source), do: slice_node(source, body) |> body_text_or_render(body)

  defp indent_body(str), do: String.split(str, "\n") |> Enum.map_join("\n", &("    " <> &1))

  defp replacement_range(range),
    do: %{
      end: [line: range.end[:line], column: range.end[:column]],
      start: [line: range.start[:line], column: range.start[:column]]
    }

  # Strip trailing `?`/`!` from a name. Elixir terminates an identifier
  # at the first `?`/`!`, so `handle_refactor?_ensure_loaded` parses as
  # `handle_refactor?` followed by a stray `_ensure_loaded` call. The
  # synthesised helper is a dispatch step, not a predicate or bang, so
  # the suffix carries no meaning here.
  defp strip_name_suffix(name),
    do: name |> to_string() |> String.replace_suffix("?", "") |> String.replace_suffix("!", "")

  defp callee_name({{:., _, [{:__aliases__, _, _}, fname]}, _, _}) when is_atom(fname),
    do: {:ok, Atom.to_string(fname)}

  defp callee_name({fname, _, args}) when is_atom(fname) and is_list(args),
    do: {:ok, Atom.to_string(fname)}

  defp callee_name(_), do: :error

  defp function_name({:when, _, [{name, _, _} | _]}) when is_atom(name), do: name
  defp function_name({name, _, _}) when is_atom(name), do: name
  defp function_name(_), do: :unknown

  defp function_param_patterns({:when, _, [inner | _]}), do: function_param_patterns(inner)
  defp function_param_patterns({name, _, args}) when is_atom(name) and is_list(args), do: args
  defp function_param_patterns(_), do: []

  defp module_body({:defmodule, _, [_name, [{_do, body}]]}) do
    toed_expr = body_to_exprs(body)
    last = List.last(toed_expr)
    line = end_of_expression_line(last) + 1
    {toed_expr, line}
  end

  defp module_body(_), do: nil

  # ---- Scope-aware variable use detection ---------------------------
  #
  # `outer_used_var_names/1` returns the set of bare-var names that are
  # *referenced from the outer scope* of `ast`. It descends into the
  # tree and, at every shadowing construct (`fn`, `for`, `with`, plus
  # the Ecto `from(x in src, …)` pattern), removes from the descendant's
  # use-set the names that the construct rebinds. Inner uses of a
  # rebound name don't propagate up.
  #
  # A purely syntactic walker would mark `token` as "used" inside
  # `from(token in q, where: token.x)`, even though that `token` is the
  # Ecto binding, not the outer var — leading us to keep it as a real
  # param when it should be `_token` in the helper signature.
  #
  # Constructs covered:
  #   * `fn pat… -> body end` (multi-clause `fn`) — pats bind body
  #   * `for x <- src, …, do: body, into: …` — every `<-` binds the rest
  #   * `with x <- src, …, do: body, else: clauses` — same
  #   * `from(x in src, …)` — `:in` binds LHS for the remaining args
  #
  # Inner `case`/`cond`/`if` are not handled — their clause patterns
  # would shadow, but in practice they're rare as shadowing sources for
  # an outer var that the helper is also receiving as a param.
  defp outer_used_var_names(ast), do: collect_outer_uses(ast, MapSet.new())

  defp collect_outer_uses(ast, bound) do
    case ast do
      {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
        string = Atom.to_string(name)

        cond do
          String.starts_with?(string, "_") -> MapSet.new()
          name in [:__MODULE__, :__CALLER__, :__ENV__] -> MapSet.new()
          MapSet.member?(bound, name) -> MapSet.new()
          true -> MapSet.new([name])
        end

      {:fn, _, clauses} when is_list(clauses) ->
        clauses
        |> Enum.map(fn
          {:->, _, [args, body]} ->
            inner_bound =
              args |> Enum.flat_map(&pattern_var_names/1) |> MapSet.new() |> MapSet.union(bound)

            collect_outer_uses(body, inner_bound)

          other ->
            collect_outer_uses(other, bound)
        end)
        |> Enum.reduce(MapSet.new(), &MapSet.union/2)

      {:for, _, args} when is_list(args) ->
        collect_comprehension_uses(args, bound)

      {:with, _, args} when is_list(args) ->
        collect_comprehension_uses(args, bound)

      {{:., _, [_, _]} = dotcall, _, args} when is_list(args) ->
        # Remote call: `Mod.fun(args)`. Don't descend into the dotcall
        # head's atom — `Mod` is already an `__aliases__` and `fun` is
        # an atom literal. Just walk args.
        args
        |> Enum.reduce(collect_outer_uses(dotcall, bound), fn a, acc ->
          MapSet.union(acc, collect_outer_uses(a, bound))
        end)

      {:from, _, [src | rest]} ->
        # Ecto.Query.from/2: first arg is `binding in src` or just `src`,
        # rest is a keyword list whose `:join` entries also bind via
        # `… in …`. We sequentially collect uses; each `in` LHS adds
        # to bound for the remainder of the call.
        {first_uses, bound1} = collect_in_binding(src, bound)
        {rest_uses, _} = collect_from_rest(rest, bound1)
        MapSet.union(first_uses, rest_uses)

      {form, _, args} when is_list(args) ->
        # Generic call/special form: walk children with same scope.
        head_uses =
          case form do
            atom when is_atom(atom) -> MapSet.new()
            other -> collect_outer_uses(other, bound)
          end

        args
        |> Enum.reduce(head_uses, fn a, acc ->
          MapSet.union(acc, collect_outer_uses(a, bound))
        end)

      list when is_list(list) ->
        list
        |> Enum.reduce(MapSet.new(), fn item, acc ->
          MapSet.union(acc, collect_outer_uses(item, bound))
        end)

      {l, r} ->
        MapSet.union(collect_outer_uses(l, bound), collect_outer_uses(r, bound))

      _atom_or_literal ->
        MapSet.new()
    end
  end

  # Sequentially walk a `for`/`with`-style arg list. `<-` generators
  # bind their LHS for the remainder; `=` matches do too. Keyword pairs
  # like `do: body`, `into: x`, `reduce: x`, `else: clauses` walk under
  # the running scope.
  defp collect_comprehension_uses(args, bound) do
    {uses, _} =
      args
      |> Enum.reduce({MapSet.new(), bound}, fn arg, {acc, sc} ->
        case arg do
          {:<-, _, [lhs, rhs]} ->
            rhs_uses = collect_outer_uses(rhs, sc)
            new_bound = lhs |> pattern_var_names() |> MapSet.new() |> MapSet.union(sc)
            {MapSet.union(acc, rhs_uses), new_bound}

          {:=, _, [lhs, rhs]} ->
            rhs_uses = collect_outer_uses(rhs, sc)
            new_bound = lhs |> pattern_var_names() |> MapSet.new() |> MapSet.union(sc)
            {MapSet.union(acc, rhs_uses), new_bound}

          kw when is_list(kw) ->
            kw_uses =
              kw
              |> Enum.reduce(MapSet.new(), fn {_k, v}, kacc ->
                MapSet.union(kacc, collect_outer_uses(v, sc))
              end)

            {MapSet.union(acc, kw_uses), sc}

          other ->
            {MapSet.union(acc, collect_outer_uses(other, sc)), sc}
        end
      end)

    uses
  end

  defp collect_in_binding({:in, _, [lhs, rhs]}, bound) do
    rhs_uses = collect_outer_uses(rhs, bound)
    new_bound = lhs |> pattern_var_names() |> MapSet.new() |> MapSet.union(bound)
    {rhs_uses, new_bound}
  end

  defp collect_in_binding(other, bound), do: {collect_outer_uses(other, bound), bound}

  defp collect_from_rest([kw | _], bound) when is_list(kw) do
    # `from/2` takes a single keyword list as its second arg; the AST
    # places it as a list inside `args`. Keys: `:join` (LHS in RHS),
    # `:where`/`:select`/`:order_by`/etc. — only `:join` binds.
    {uses, final_bound} =
      kw
      |> Enum.reduce({MapSet.new(), bound}, fn
        {{:__block__, _, [:join]}, val}, {acc, sc} ->
          {val_uses, new_bound} = collect_in_binding(val, sc)
          {MapSet.union(acc, val_uses), new_bound}

        {:join, val}, {acc, sc} ->
          {val_uses, new_bound} = collect_in_binding(val, sc)
          {MapSet.union(acc, val_uses), new_bound}

        {_k, val}, {acc, sc} ->
          {MapSet.union(acc, collect_outer_uses(val, sc)), sc}
      end)

    {uses, final_bound}
  end

  defp collect_from_rest([], bound), do: {MapSet.new(), bound}

  defp collect_from_rest(args, bound) do
    uses =
      args
      |> Enum.reduce(MapSet.new(), fn a, acc ->
        MapSet.union(acc, collect_outer_uses(a, bound))
      end)

    {uses, bound}
  end

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp extractions_in_body(nil, _source), do: []

  defp extractions_in_body({body_exprs, append_at_line}, source) do
    defps = collect_defp_index(body_exprs)

    body_exprs
    |> Enum.flat_map(&find_extraction(&1, defps))
    # One extraction per pass keeps the diff focused. Fixpoint
    # loop in `Engine` re-runs until stable; subsequent passes
    # find no `case` to match (the original is rewritten) so
    # the pass converges in one iteration per host function.
    |> Enum.take(1)
    |> Enum.flat_map(&emit_patches(&1, source, append_at_line))
  end

  # Index every `defp <name>(args) do body end` (and shorthand) in the
  # module body, grouping clauses by `{name, arity}`. Used by collision
  # detection: when a synth helper name already exists with the exact
  # arity AND identical clauses, skip the extraction; when the name
  # exists but clauses differ, append `_2`/`_3`/... to the synth name.
  defp collect_defp_index(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {kind, _, [head, kw]} when kind in [:defp, :defmacrop] and is_list(kw) ->
        case extract_fn_signature(head) do
          {name, args} -> [{{name, length(args)}, {head, kw}}]
          :error -> []
        end

      _ ->
        []
    end)
    |> Enum.group_by(fn {key, _} -> key end, fn {_, clause} -> clause end)
  end

  defp patches_for_call_or_skip(
         {:ok, replacement_text},
         append_at_line,
         branches,
         case_node,
         def_kind,
         free_vars,
         helper_name,
         source
       ) do
    case_range = Sourceror.get_range(case_node)
    body_patch = Patch.new(replacement_range(case_range), replacement_text, false)

    helper_text = render_helper_clauses(def_kind, helper_name, branches, free_vars, source)

    helper_range = %{
      end: [line: append_at_line, column: 1],
      start: [line: append_at_line, column: 1]
    }

    helper_patch = Patch.new(helper_range, "\n" <> helper_text <> "\n", false)

    [body_patch, helper_patch]
  end

  defp patches_for_call_or_skip(
         :error,
         _append_at_line,
         _branches,
         _case_node,
         _def_kind,
         _free_vars,
         _helper_name,
         _source
       ),
       do: []

  defp pipe_call_text_or_error({:ok, scrutinee_text}, free_vars, helper_name) do
    helper_args = free_vars |> Enum.map_join(", ", &Atom.to_string/1)
    {:ok, "#{scrutinee_text} |> #{helper_name}(#{helper_args})"}
  end

  defp pipe_call_text_or_error(:error, _free_vars, _helper_name), do: :error

  defp pattern_text_or_render({:ok, text}, _pattern), do: text

  defp pattern_text_or_render(:error, pattern), do: pattern |> Sourceror.to_string()

  defp guard_text_or_render({:ok, text}, _guard), do: text

  defp guard_text_or_render(:error, guard), do: guard |> Sourceror.to_string()

  defp body_text_or_render({:ok, text}, _body), do: text

  defp body_text_or_render(:error, body), do: body |> Sourceror.to_string()

  # A `case` is "non-complex" iff EVERY clause body is non-complex.
  # See `non_complex?/1` for the definition. The check unwraps the
  # `:->` shape (`[{:->, _, [[pat], body]} | …]`); clauses with
  # malformed shape are conservatively treated as complex (return
  # `false` from the `all?` so the case still extracts).
  defp non_complex_case?(clauses) do
    clauses
    |> Enum.all?(fn
      {:->, _, [[_pat], body]} -> non_complex?(body)
      _ -> false
    end)
  end

  # Non-complex shapes (the dispatch isn't worth lifting):
  #
  #   - Literal: atom, integer, float, boolean, nil, string, charlist.
  #     Sourceror wraps these as `{:__block__, _, [literal]}`.
  #   - Bare variable: `{name, _, ctx}` where `ctx` is atom (not list).
  #   - Tuple: `{a, b}` (2-tuple AST form) or `{:{}, _, elems}` (N-tuple),
  #     when every element is itself non-complex.
  #   - Local or `Mod.fun` call with 0-2 args, where every arg is
  #     non-complex. Excludes operators (`+`, `==`, `|>`, …) and
  #     special-form names (`case`, `if`, `with`, `for`, `fn`,
  #     `cond`, `try`, `receive`, `quote`).
  #   - Binary operator with two non-complex operands (`a + b`,
  #     `x == y`, `s <> t`).
  #   - Unary operator with one non-complex operand (`!flag`, `-x`,
  #     `not done`).
  #   - 1-stage pipe `lhs |> f(args…)` where `lhs` is non-complex and
  #     the RHS is a 0-1-arg call of non-complex args (so the
  #     combined effect is a single ≤2-arg call).
  #
  # Everything else is complex: multi-stage pipes, 3+-arg calls,
  # nested `case`/`if`/`cond`/`with`/`try`/`receive`, `for`
  # comprehensions, `fn`-lambdas, `&`-captures, map literals,
  # list literals, `raise`/`reraise`/`throw`/`exit`, `__block__`
  # with 2+ statements.
  defp non_complex?(ast), do: non_complex_node?(ast)

  # Sourceror-wrapped literals: `{:__block__, _, [:atom | int | "str" | …]}`.
  # GUARDED — without the guard this clause would consume EVERY
  # 1-child `__block__` and return `literal?(non-literal)` = false,
  # preventing the recurse-into-block clause below from ever firing.
  defp non_complex_node?({:__block__, _, [literal]})
       when is_atom(literal) or is_number(literal) or is_binary(literal),
       do: true

  defp non_complex_node?(literal)
       when is_atom(literal) or is_number(literal) or is_binary(literal),
       do: true

  # 2-tuple AST form (Sourceror keeps this shape for `{a, b}`).
  defp non_complex_node?({a, b}), do: non_complex?(a) and non_complex?(b)

  # `__block__` with 1 non-literal child — unwrap and recurse.
  defp non_complex_node?({:__block__, _, [single]}), do: non_complex?(single)

  # `__block__` with 0 or 2+ children — multi-statement, complex.
  defp non_complex_node?({:__block__, _, _}), do: false

  # N-tuple: `{:{}, _, elems}`.
  defp non_complex_node?({:{}, _, elems}) when is_list(elems),
    do: elems |> Enum.all?(&non_complex?/1)

  # `&capture/N` and `&(...)` shorthand — extracted in their own
  # right, always complex here.
  defp non_complex_node?({:&, _, _}), do: false

  # `fn ... -> ... end` — complex.
  defp non_complex_node?({:fn, _, _}), do: false

  # Always-complex control-flow & block constructs.
  defp non_complex_node?({form, _, _})
       when form in [
              :case,
              :cond,
              :for,
              :if,
              :quote,
              :receive,
              :try,
              :unless,
              :with,
              :raise,
              :reraise,
              :throw,
              :exit
            ],
       do: false

  # Map/list/binary literals are complex.
  defp non_complex_node?({:%{}, _, _}), do: false
  defp non_complex_node?({:%, _, _}), do: false
  defp non_complex_node?({:<<>>, _, _}), do: false
  defp non_complex_node?(list) when is_list(list), do: false

  # Pipe: only the degenerate 1-stage form (`lhs |> f()` or
  # `lhs |> f(arg)`) counts as non-complex — equivalent to `f(lhs)`
  # or `f(lhs, arg)`, both of which are 1-2 args of non-complex
  # parts. Anything chained (`a |> f() |> g()`) is complex by
  # construction: the LHS is itself a `|>`.
  defp non_complex_node?({:|>, _, [{:|>, _, _}, _]}), do: false

  defp non_complex_node?({:|>, _, [lhs, {fname, _, rhs_args}]})
       when is_atom(fname) and is_list(rhs_args) do
    length(rhs_args) <= 1 and non_complex?(lhs) and
      Enum.all?(rhs_args, &non_complex?/1) and
      not Macro.operator?(fname, length(rhs_args) + 1) and
      not special_form_name?(fname)
  end

  defp non_complex_node?({:|>, _, [lhs, {{:., _, [_, fname]}, _, rhs_args}]})
       when is_atom(fname) and is_list(rhs_args) do
    length(rhs_args) <= 1 and non_complex?(lhs) and Enum.all?(rhs_args, &non_complex?/1)
  end

  defp non_complex_node?({:|>, _, _}), do: false

  # Binary/unary operator: `+`, `-`, `==`, `<>`, `!`, `not`, …
  # The structural shape is `{op_atom, _, [a, b]}` or `{op_atom, _, [a]}`.
  defp non_complex_node?({op, _, [a, b]}) when is_atom(op) do
    if Macro.operator?(op, 2),
      do: non_complex?(a) and non_complex?(b),
      else: call_non_complex?({op, [], [a, b]})
  end

  defp non_complex_node?({op, _, [a]}) when is_atom(op) do
    if Macro.operator?(op, 1),
      do: non_complex?(a),
      else: call_non_complex?({op, [], [a]})
  end

  # Local function call with 0 args: `f()`. Bare-var lookalike is
  # distinguished by `args == []` (vs. `ctx` being atom for vars).
  defp non_complex_node?({fname, _, args} = node) when is_atom(fname) and is_list(args) do
    call_non_complex?(node)
  end

  # Bare variable: `{name, _, ctx}` with `ctx` atom (not a list).
  defp non_complex_node?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true

  # `Mod.fun(args)` — `{{:., _, [_callee, fname]}, _, args}`.
  defp non_complex_node?({{:., _, [_callee, fname]}, _, args} = node)
       when is_atom(fname) and is_list(args) do
    call_non_complex?(node)
  end

  defp non_complex_node?(_), do: false

  # 0-2-arg local or qualified call where every arg is non-complex.
  # Operators and special forms are rejected — they have their own
  # rules higher up.
  defp call_non_complex?({fname, _, args}) when is_atom(fname) and is_list(args) do
    length(args) <= 2 and
      not Macro.operator?(fname, length(args)) and
      not special_form_name?(fname) and
      not always_complex_call?(fname) and
      Enum.all?(args, &non_complex?/1)
  end

  defp call_non_complex?({{:., _, [_callee, fname]}, _, args})
       when is_atom(fname) and is_list(args) do
    length(args) <= 2 and Enum.all?(args, &non_complex?/1)
  end

  defp call_non_complex?(_), do: false

  defp always_complex_call?(name), do: name in [:raise, :reraise, :throw, :exit]

  defp special_form_name?(name),
    do:
      name in [
        :case,
        :cond,
        :for,
        :fn,
        :if,
        :quote,
        :receive,
        :try,
        :unless,
        :with,
        :__block__
      ]

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
