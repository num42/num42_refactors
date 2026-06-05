defmodule Number42.Refactors.Ex.ExtractCaseToHelper do
  @moduledoc """
  Extracts a `case <call>(args) do ... end` that sits as the **last
  expression** of a `def`/`defp` body into a private helper. Each `case`
  clause becomes a helper clause; the original `case` is replaced by a
  pipe call that threads the scrutinee result into the helper.

  ## Helper naming

  The helper is named after **what the clauses dispatch on**, not after
  the call that produced the value, because the patterns are what the
  reader needs to understand the branch:

  - **Pattern-derived (preferred).** When the clauses form a recognized
    pattern family, the name encodes that family. The canonical one is
    the `:ok`/`:error` *result* family (every clause leads with `:ok` or
    `:error`, bare or tagged) → `on_<scrutinee>_result/N`.
  - **Call-derived (fallback).** When no clear family is present, the
    name falls back to the mechanical `handle_<host_fn>_<scrutinee_fn>/N`.

  New families are added in one place (`pattern_family_suffix/1`) as a
  clause-set predicate — call sites stay untouched.

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
        fetch(a, b) |> on_fetch_result(ctx)
      end

      defp on_fetch_result({:ok, value}, ctx), do: use(value, ctx)
      defp on_fetch_result(:error, ctx), do: default(ctx)

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
      to keep the synthesized helper visually grouped.

  ## Why procedural

  Multi-node surgery: the existing `case` gets rewritten in place AND
  one or more new helper definitions get appended at module end. Not
  expressible as a single 1:1 declarative pattern.

  Source for clause patterns/bodies and call args is spliced via
  `slice_node/2` — preserves the user's exact formatting (string
  escapes, comments inside expressions, parens) where re-emitting
  through `Sourceror.to_string/1` would not.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description,
    do: "case <call>(...) do ... end at tail of fn -> extract pattern-named dispatch helper"

  @impl Number42.Refactors.Refactor
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

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)
  defp always_complex_call?(name), do: name in [:raise, :reraise, :throw, :exit]

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

  defp analyze_clause(_, _),
    do: %{body: nil, free_vars: [], guard: nil, pattern: nil, used_in_body: MapSet.new()}

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source
  defp body_text_or_render({:ok, text}, _body), do: text
  defp body_text_or_render(:error, body), do: body |> Sourceror.to_string()
  defp build_patches(ast, source), do: module_body(ast) |> extractions_in_body(source)

  defp build_replacement_call(source, scrutinee_node, helper_name, free_vars),
    do:
      slice_node(source, scrutinee_node)
      |> pipe_call_text_or_error(free_vars, helper_name)

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

  defp callee_name({{:., _, [{:__aliases__, _, _}, fname]}, _, _}) when is_atom(fname),
    do: {:ok, Atom.to_string(fname)}

  defp callee_name({fname, _, args}) when is_atom(fname) and is_list(args),
    do: {:ok, Atom.to_string(fname)}

  defp callee_name(_), do: :error

  defp clause_uses_pin?({:->, _meta, [[pattern_node], _body]}) do
    {pat, guard} = unwrap_when(pattern_node)
    contains_pin?(pat) or (guard && contains_pin?(guard))
  end

  defp clause_uses_pin?(_), do: false

  defp clause_uses_super?({:->, _meta, [[pattern_node], body]}) do
    {_pat, guard} = unwrap_when(pattern_node)
    contains_super?(body) or (guard && contains_super?(guard))
  end

  defp clause_uses_super?(_), do: false

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
            {MapSet.union(acc, collect_keyword_uses(kw, sc)), sc}

          other ->
            {MapSet.union(acc, collect_outer_uses(other, sc)), sc}
        end
      end)

    uses
  end

  defp collect_keyword_uses(kw, sc) do
    kw
    |> Enum.reduce(MapSet.new(), fn {_k, v}, kacc ->
      MapSet.union(kacc, collect_outer_uses(v, sc))
    end)
  end

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

  defp collect_in_binding({:in, _, [lhs, rhs]}, bound) do
    rhs_uses = collect_outer_uses(rhs, bound)
    new_bound = lhs |> pattern_var_names() |> MapSet.new() |> MapSet.union(bound)
    {rhs_uses, new_bound}
  end

  defp collect_in_binding(other, bound), do: {collect_outer_uses(other, bound), bound}

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
        |> Enum.map(&collect_fn_clause_uses(&1, bound))
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

  defp collect_fn_clause_uses({:->, _, [args, body]}, bound) do
    inner_bound =
      args |> Enum.flat_map(&pattern_var_names/1) |> MapSet.new() |> MapSet.union(bound)

    collect_outer_uses(body, inner_bound)
  end

  defp collect_fn_clause_uses(other, bound), do: collect_outer_uses(other, bound)

  defp contains_pin?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:^, _, [_]} -> true
      _ -> false
    end)
  end

  defp contains_super?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:super, _, args} when is_list(args) -> true
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
      base_name = synth_handler_name(host_name, scrutinee_name, clauses)

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
  defp function_name({:when, _, [{name, _, _} | _]}) when is_atom(name), do: name
  defp function_name({name, _, _}) when is_atom(name), do: name
  defp function_name(_), do: :unknown
  defp function_param_patterns({:when, _, [inner | _]}), do: function_param_patterns(inner)
  defp function_param_patterns({name, _, args}) when is_atom(name) and is_list(args), do: args
  defp function_param_patterns(_), do: []
  defp guard_text_or_render({:ok, text}, _guard), do: text
  defp guard_text_or_render(:error, guard), do: guard |> Sourceror.to_string()
  # The sliced body text has its first line at column 0 (the slice
  # starts mid-source-line, at the expression) while continuation lines
  # keep their original source indentation — the case/clause nesting
  # depth, not the helper's. Re-anchor: the first line was at source
  # column `C`; continuation lines are at `C + relative`, and the
  # *minimum* continuation indent is exactly `C` (top-level-aligned
  # tokens like a leading `|>` or a closing `end` sit at `C`). Strip `C`
  # from continuation lines to recover their relative shape, leave the
  # first line untouched, then indent the whole block by the canonical 4
  # spaces. Blank lines stay blank.
  defp indent_body(str) do
    case String.split(str, "\n") do
      [single] ->
        "    " <> single

      [first | rest] ->
        common = continuation_indent(rest)
        reindented = Enum.map(rest, &dedent_line(&1, common))
        [first | reindented] |> Enum.map_join("\n", &prefix_line/1)
    end
  end

  defp continuation_indent(lines) do
    lines
    |> Enum.reject(&blank?/1)
    |> Enum.map(&leading_spaces/1)
    |> Enum.min(fn -> 0 end)
  end

  defp dedent_line(line, common) do
    if blank?(line), do: "", else: String.slice(line, common..-1//1)
  end

  defp prefix_line(""), do: ""
  defp prefix_line(line), do: "    " <> line

  defp blank?(line), do: String.trim(line) == ""
  defp leading_spaces(line), do: byte_size(line) - byte_size(String.trim_leading(line))

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

  defp module_body({:defmodule, _, [_name, [{_do, body}]]}) do
    toed_expr = body_to_exprs(body)
    last = List.last(toed_expr)
    line = end_of_expression_line(last) + 1
    {toed_expr, line}
  end

  defp module_body(_), do: nil
  defp non_complex?(ast), do: non_complex_node?(ast)

  defp non_complex_case?(clauses) do
    clauses
    |> Enum.all?(fn
      {:->, _, [[_pat], body]} -> non_complex?(body)
      _ -> false
    end)
  end

  defp non_complex_node?({:__block__, _, [literal]})
       when is_atom(literal) or is_number(literal) or is_binary(literal),
       do: true

  defp non_complex_node?(literal)
       when is_atom(literal) or is_number(literal) or is_binary(literal),
       do: true

  defp non_complex_node?({a, b}), do: non_complex?(a) and non_complex?(b)
  defp non_complex_node?({:__block__, _, [single]}), do: non_complex?(single)
  defp non_complex_node?({:__block__, _, _}), do: false

  defp non_complex_node?({:{}, _, elems}) when is_list(elems),
    do: elems |> Enum.all?(&non_complex?/1)

  defp non_complex_node?({:&, _, _}), do: false
  defp non_complex_node?({:fn, _, _}), do: false

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

  defp non_complex_node?({:%{}, _, _}), do: false
  defp non_complex_node?({:%, _, _}), do: false
  defp non_complex_node?({:<<>>, _, _}), do: false
  defp non_complex_node?(list) when is_list(list), do: false
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

  defp non_complex_node?({fname, _, args} = node) when is_atom(fname) and is_list(args) do
    call_non_complex?(node)
  end

  defp non_complex_node?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true

  defp non_complex_node?({{:., _, [_callee, fname]}, _, args} = node)
       when is_atom(fname) and is_list(args) do
    call_non_complex?(node)
  end

  defp non_complex_node?(_), do: false
  defp outer_used_var_names(ast), do: collect_outer_uses(ast, MapSet.new())
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

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

  defp pattern_text_or_render({:ok, text}, _pattern), do: text
  defp pattern_text_or_render(:error, pattern), do: pattern |> Sourceror.to_string()

  defp pipe_call_text_or_error({:ok, scrutinee_text}, free_vars, helper_name) do
    helper_args = free_vars |> Enum.map_join(", ", &Atom.to_string/1)
    {:ok, "#{scrutinee_text} |> #{helper_name}(#{helper_args})"}
  end

  defp pipe_call_text_or_error(:error, _free_vars, _helper_name), do: :error

  defp render_body_text({:not, _, [{:in, _, [_lhs, _rhs]}]} = body, _source),
    do: body |> Sourceror.to_string()

  defp render_body_text(body, source), do: slice_node(source, body) |> body_text_or_render(body)

  defp render_guard_text(guard, source),
    do: slice_node(source, guard) |> guard_text_or_render(guard)

  defp render_helper_clauses(def_kind, helper_name, branches, free_vars, source) do
    # Always private — helpers are an internal dispatch step, not a
    # public API. Even when the host was `def`, the synthesized helper
    # is `defp`. Callers stay through the public host.
    _ = def_kind

    branches
    |> Enum.map_join("\n", &render_clause(&1, helper_name, free_vars, source))
  end

  defp render_clause(
         %{body: body, guard: guard, pattern: pattern, used_in_body: used},
         helper_name,
         free_vars,
         source
       ) do
    pattern_text = render_pattern_text(pattern, source)
    body_text = render_body_text(body, source)
    extra_params = render_extra_params(free_vars, used)

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
  end

  # Per-clause: prefix `_` on extra params not referenced in this
  # clause's body or guard. The pipe call site keeps the real
  # names — this only affects the signature, mirroring the
  # compiler's "variable X is unused" hint.
  defp render_extra_params(free_vars, used) do
    free_vars
    |> Enum.map(fn var ->
      name = Atom.to_string(var)
      if MapSet.member?(used, var), do: name, else: "_" <> name
    end)
  end

  defp render_pattern_text(pattern, source),
    do: slice_node(source, pattern) |> pattern_text_or_render(pattern)

  defp replacement_range(range),
    do: %{
      end: [line: range.end[:line], column: range.end[:column]],
      start: [line: range.start[:line], column: range.start[:column]]
    }

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

  defp strip_name_suffix(name),
    do: name |> to_string() |> String.replace_suffix("?", "") |> String.replace_suffix("!", "")

  # Name the helper after what the dispatch *decides on* — the clause
  # patterns — when those patterns form a recognizable family, else fall
  # back to the mechanical `handle_<host>_<scrutinee>` (the scrutinee
  # call name). Pattern-derived names beat call-derived ones: the call
  # is "how we got the value", the patterns are "what we branch on".
  defp synth_handler_name(host_name, scrutinee_name, clauses) do
    scrutinee = strip_name_suffix(scrutinee_name)

    case pattern_family_suffix(clauses) do
      nil ->
        synth_compound_name("handle", strip_name_suffix(host_name), scrutinee, "")

      suffix ->
        # `on_<scrutinee>_<suffix>` — the family suffix already encodes
        # the dispatch identity, so the host name is redundant noise.
        synth_compound_name("on", "", scrutinee, suffix)
    end
  end

  # Recognize a pattern *family* across the clauses and return its
  # semantic name suffix, or nil when no family matches. Generic by
  # design — a family is "all clauses share a recognizable leading-tag
  # shape". Each family is one `{predicate_on_leading_tags, suffix}`
  # entry; add a family by appending a tuple here, call sites stay
  # untouched. The canonical one is the `:ok`/`:error` result family →
  # `_result`.
  defp pattern_family_suffix(clauses) do
    tags = clauses |> Enum.map(&leading_tag/1)
    families = [{&result_family?/1, "result"}]

    Enum.find_value(families, fn {matches?, suffix} ->
      if matches?.(tags), do: suffix
    end)
  end

  # The result family: every clause leads with `:ok` or `:error` (bare
  # atom `:ok`/`:error` or a tagged tuple `{:ok, …}`/`{:error, …}`), with
  # at least one clause actually tagged so we don't fire on a plain
  # `:ok | :other` enum. This is the shape `{:ok, _}` / `{:error, _}`
  # dispatch the issue calls out, generalized over the tuple/atom mix.
  defp result_family?(tags) do
    Enum.all?(tags, &(&1 in [:ok, :error])) and :ok in tags
  end

  # The "leading tag" of a clause: the first element's atom when the
  # pattern is a tuple, or the atom itself for a bare-atom pattern. Any
  # other shape (bound var, `nil`, map, list, pin, …) has no leading tag.
  # Sourceror wraps atoms/literals in `:__block__`, hence the unwrapping.
  defp leading_tag({:->, _meta, [[pattern_node], _body]}) do
    {pattern, _guard} = unwrap_when(pattern_node)
    pattern_leading_tag(pattern)
  end

  defp leading_tag(_), do: nil

  # 2-element tuple: Sourceror represents `{a, b}` as a `:__block__`
  # wrapping a raw 2-tuple. The first element is the tag.
  defp pattern_leading_tag({:__block__, _, [{tag_node, _second}]}),
    do: atom_literal(tag_node)

  # 3+-element tuple: `{:{}, _, [first | _]}`.
  defp pattern_leading_tag({:{}, _, [first | _]}), do: atom_literal(first)

  # Bare atom pattern (`:ok`, `:error`, `nil`, …), possibly wrapped.
  defp pattern_leading_tag({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp pattern_leading_tag(atom) when is_atom(atom), do: atom
  defp pattern_leading_tag(_), do: nil

  defp atom_literal({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp atom_literal(atom) when is_atom(atom), do: atom
  defp atom_literal(_), do: nil

  defp unwrap_when({:when, _meta, [pat, guard]}), do: {pat, guard}
  defp unwrap_when(pat), do: {pat, nil}
end
