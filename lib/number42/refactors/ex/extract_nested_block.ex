defmodule Number42.Refactors.Ex.ExtractNestedBlock do
  @moduledoc """
  Targets `Credo.Check.Refactor.Nesting`. Identifies functions whose
  body nests deeper than 2 levels and extracts the innermost
  too-deeply-nested anonymous-function body into a private helper.

  ## Strategy

  - Walk the module top, collect every `def`/`defp`.
  - For each, walk the body tracking nesting depth (each `fn`/`case`/
    `cond`/`if`/`unless`/`with`/`for`/`receive`/`try` adds 1).
  - Find the *innermost* `fn` whose body sits at depth > `max_nesting`
    AND is liftable. Liftable means either (a) a multi-statement body,
    or (b) a single-statement body that *is* a nesting construct
    (`case`/`if`/`with`/...), so lifting moves it to a fresh function
    where Credo's counter restarts at 0.
  - Lift that body into `defp extracted_<funcname>_<n>/<arity>` at the
    bottom of the module. The lambda's argument variables become the
    first parameters. Variables bound *before* the lambda in the host
    function and used inside the lambda body become further parameters.
  - Replace the lambda body with a call to the helper.
  - Prefix the helper with a FIXME comment so a human reviews the
    extraction.

  ## Known limitations

  - Lifts only via `fn`. Bare `case`/`if` clauses (where the depth
    driver isn't wrapped in a lambda) are left alone — see e.g.
    `pricing.ex:link_asset_to_brand_items` whose top-level `case` is
    not extractable through this pass.
  - Free-variable detection is conservative: it scans the host function
    body for assignments preceding the lambda. Module attributes,
    aliased modules, imported functions, and pinned variables are not
    counted as free vars.
  - Operates on one nest per pass; rerun the formatter to handle
    multiple violations in the same module.

  Auto-discovered. The nesting threshold mirrors
  `Credo.Check.Refactor.Nesting`: extract any `fn` whose body sits at
  effective depth `> max_nesting`. Configure via `.refactor.exs`:

      configured_modules: [
        {Number42.Refactors.Ex.ExtractNestedBlock, max_nesting: 2}
      ]

  Default is `max_nesting: 2` (matches Credo's default). The refactor
  always inserts a FIXME on the extracted helper so a human reviews
  the parameter list and chosen name.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.HelperNaming
  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Extract too-deeply-nested fn bodies into private helpers"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Three or four nested anonymous functions in one body forces the
    reader to keep a tower of bindings in their head and re-find the
    matching `end` for each level — the actual logic gets buried in
    plumbing. Lifting the innermost body to a named private helper
    flattens the visible structure, gives the lifted operation a name,
    and means a future bug can be tested against the helper directly
    instead of through the surrounding pipeline.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @default_max_nesting 2

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    max_nesting = Keyword.get(opts, :max_nesting, @default_max_nesting)

    Sourceror.parse_string(source) |> apply_patches(max_nesting, source)
  end

  @impl Number42.Refactors.Refactor
  def patches(ast, _source, opts) do
    max_nesting = Keyword.get(opts, :max_nesting, @default_max_nesting)
    build_patches(ast, max_nesting)
  end

  defp apply_patches({:ok, ast}, max_nesting, source),
    do:
      build_patches(ast, max_nesting)
      |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, _max_nesting, source), do: source
  defp bodies_equal?(a, b), do: strip_meta(a) == strip_meta(b)
  defp build_extracted_index(ast), do: module_body_exprs(ast) |> index_defps_by_name()

  defp build_patches(ast, max_nesting),
    do: module_body(ast) |> extractions_in_body(max_nesting, ast)

  defp collect_bound_names_before_fn_walk(body) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:=, _, [lhs, _rhs]} ->
        pattern_var_names(lhs)

      # `for` and `with` bind names through `<-` generators/clauses.
      # An extracted `fn` body sitting *inside* a `for bi <- list, do: ...`
      # or `with {:ok, x} <- ...` references those names as closure
      # variables — they must be passed into the lifted helper or the
      # helper sees an undefined variable.
      {:<-, _, [lhs, _rhs]} ->
        pattern_var_names(lhs)

      # Lambda parameters bind names too. A name introduced by an
      # *outer* `fn` on the path to the extracted node must be passed
      # in as a parameter — otherwise the helper closes over a name
      # that no longer exists in scope. We collect them all; the
      # final `used ∩ bound_before` intersection drops any that
      # aren't actually referenced.
      {:fn, _, clauses} ->
        clauses
        |> Enum.flat_map(fn
          {:->, _, [args, _body]} -> args |> Enum.flat_map(&pattern_var_names/1)
          _ -> []
        end)

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp deepest_too_deep_fn(body, max_nesting) do
    body
    |> walk_with_depth(0)
    |> Enum.filter(fn {node, depth} ->
      match?({:fn, _, _}, node) and depth >= max_nesting and liftable_fn?(node)
    end)
    |> case do
      [] -> nil
      candidates -> candidates |> Enum.max_by(fn {_, depth} -> depth end)
    end
  end

  defp emit_patches(target, append_at_line, extracted_index) do
    %{
      arg_names: arg_names,
      fn_body: fn_body,
      fn_node: fn_node,
      free_vars: free_vars,
      host_fn_name: host_fn_name
    } = target

    %{fn_args: fn_args} = target

    generate_helper_name(host_fn_name, fn_body, extracted_index)
    |> patches_for_helper(
      append_at_line,
      arg_names,
      fn_args,
      fn_body,
      fn_node,
      free_vars
    )
  end

  defp emit_target_or_skip(nil, _body, _bound_before, _def_node, _fn_name), do: []

  defp emit_target_or_skip(
         {fn_node, depth},
         body,
         bound_before,
         def_node,
         fn_name
       ) do
    {:fn, _, [{:->, _, [fn_args, fn_body]}]} = fn_node

    # `arg_names` = the bare variable names introduced by the
    # lambda's pattern args. We pass these into the helper.
    # `fn_args` (the AST patterns themselves) stays as-is on the
    # replacement lambda's LHS.
    arg_names = fn_args |> Enum.flat_map(&pattern_var_names/1) |> Enum.uniq()

    # Only count names bound *outside* the lambda body as free
    # vars. Anything bound inside the body is local — passing it
    # in as a parameter would either be no-op (right value, wrong
    # source) or use an undefined outer name.
    bound_inside = collect_bound_names_before_fn_walk(fn_body)
    used = used_var_names(fn_body)

    free_vars =
      used
      |> MapSet.difference(MapSet.new(arg_names))
      |> MapSet.difference(bound_inside)
      |> MapSet.intersection(bound_before)
      |> MapSet.to_list()
      |> Enum.sort()

    # If the lambda references a module that is only aliased
    # *locally* inside this `def`/`defp` body, lifting the lambda
    # to the module top-level breaks: the helper sees only top-level
    # aliases. Skip the extraction — the user has to resolve manually
    # (move the alias to module-top, or write the FQN).
    local_aliases = local_alias_names(body)
    referenced = referenced_alias_heads(fn_body)

    if MapSet.disjoint?(local_aliases, referenced) do
      [
        %{
          arg_names: arg_names,
          def_node: def_node,
          depth: depth,
          fn_args: fn_args,
          fn_body: fn_body,
          fn_node: fn_node,
          free_vars: free_vars,
          host_fn_name: fn_name
        }
      ]
    else
      []
    end
  end

  defp extractions_in_body(nil, _max_nesting, _ast), do: []

  defp extractions_in_body({body_exprs, append_at_line}, max_nesting, ast) do
    extracted_index = build_extracted_index(ast)

    body_exprs
    |> Enum.flat_map(&find_extraction(&1, max_nesting))
    # Pick the first violation per module per pass — keeps changes
    # small and easy to review. Rerun the pipeline to mop up more.
    |> Enum.take(1)
    |> Enum.flat_map(&emit_patches(&1, append_at_line, extracted_index))
  end

  defp fetch_do_body_keyword(keyword) do
    keyword
    |> Enum.find_value(:error, fn
      {{:__block__, _, [:do]}, value} -> {:ok, value}
      {:do, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp find_extraction({def_kind, _meta, [head, [{_do, body}]]} = def_node, max_nesting)
       when def_kind?(def_kind) do
    fn_name = function_name(head)
    # Names in scope at the lambda site: function parameters + any
    # `=`-bound names anywhere in the body. Conservative — a name
    # bound *after* the lambda would still appear here, but that's
    # safe (it just gets passed in as a possibly-redundant arg).
    head_params =
      head |> function_param_patterns() |> Enum.flat_map(&pattern_var_names/1) |> MapSet.new()

    body_binds = collect_bound_names_before_fn_walk(body)
    bound_before = MapSet.union(head_params, body_binds)

    deepest_too_deep_fn(body, max_nesting)
    |> emit_target_or_skip(body, bound_before, def_node, fn_name)
  end

  defp find_extraction(_, _max_nesting), do: []
  defp function_name({:when, _, [{name, _, _} | _]}) when is_atom(name), do: name
  defp function_name({name, _, _}) when is_atom(name), do: name
  defp function_name(_), do: :unknown
  defp function_param_patterns({:when, _, [inner | _]}), do: function_param_patterns(inner)
  defp function_param_patterns({name, _, args}) when is_atom(name) and is_list(args), do: args
  defp function_param_patterns(_), do: []

  defp generate_helper_name(host_fn_name, fn_body, extracted_index) do
    base = semantic_base(host_fn_name, fn_body, extracted_index)

    same? = fn existing_bodies ->
      existing_bodies |> Enum.any?(&bodies_equal?(&1, fn_body))
    end

    resolve_collision(base, extracted_index, same?: same?)
  end

  # Prefer a name that says what the lifted block *does* (via HelperNaming —
  # the producing call's verb plus the block's product) over the mechanical
  # `extracted_<host>`. The block has no live-out (it's the fn's return value),
  # so HelperNaming leans on the tail tuple/map product and the host name.
  # Fall back to `extracted_<host>` only when HelperNaming can find no
  # meaningful name (`:skip`).
  defp semantic_base(host_fn_name, fn_body, extracted_index) do
    # The host's own name is a forbidden candidate: a helper named exactly
    # `<host>` collides with the enclosing `def`/`defp` (same name, same
    # arity once free vars line up) → won't compile. Feed it into `existing`
    # so HelperNaming's `strip_suffix(host)` candidate is rejected and the
    # name falls back to `<host>_block`. The `extracted_index` carries only
    # `defp`s, not the host `def`, so we add it explicitly.
    # HelperNaming compares atom candidates against `existing`, so the set
    # must hold atoms. `extracted_index` is keyed by string defp names.
    existing =
      extracted_index
      |> Map.keys()
      |> Enum.map(&String.to_atom/1)
      |> MapSet.new()
      |> MapSet.put(host_fn_name)

    case HelperNaming.name(host_fn_name, [], body_stmts(fn_body), [], existing) do
      {:ok, name} -> Atom.to_string(name)
      :skip -> synth_compound_name("extracted", host_fn_name, "", "")
    end
  end

  defp body_stmts({:__block__, _, exprs}) when is_list(exprs), do: exprs
  defp body_stmts(single), do: [single]

  defp indent_body(str), do: String.split(str, "\n") |> Enum.map_join("\n", &("    " <> &1))
  defp index_defps_by_name(nil), do: %{}

  defp index_defps_by_name(exprs) do
    exprs
    |> Enum.flat_map(fn
      {kind, _, [head, kw]} when kind in [:defp, :defmacrop] and is_list(kw) ->
        case extract_fn_signature(head) do
          {name, _args} -> index_entry_for(name, kw)
          :error -> []
        end

      _ ->
        []
    end)
    |> Enum.group_by(fn {name, _} -> name end, fn {_, body} -> body end)
  end

  defp index_entry_for(name, kw) do
    case fetch_do_body_keyword(kw) do
      {:ok, body} -> [{Atom.to_string(name), body}]
      :error -> []
    end
  end

  defp liftable_fn?({:fn, _, [{:->, _, [_args, body]}]}),
    do: multi_statement_body?(body) or wraps_nesting_construct?(body)

  defp liftable_fn?(_), do: false

  defp local_alias_names(body) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:alias, _, [{:__aliases__, _, segments}, opts]} when is_list(opts) ->
        case Keyword.get(opts, :as) do
          {:__aliases__, _, [renamed]} when is_atom(renamed) -> [renamed]
          _ -> [List.last(segments)]
        end

      {:alias, _, [{:__aliases__, _, segments}]} ->
        [List.last(segments)]

      # Multi-alias `alias Foo.{Bar, Baz}` parses as `{:alias, _, [{{:., _, [_, :{}]}, _, inners}]}`
      {:alias, _, [{{:., _, [_, :{}]}, _, inners}]} ->
        inners
        |> Enum.flat_map(fn
          {:__aliases__, _, segments} -> [List.last(segments)]
          _ -> []
        end)

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp module_body({:defmodule, _, [_name, [{_do, body}]]}) do
    exprs =
      case body do
        {:__block__, _, list} -> list
        single -> [single]
      end

    last = List.last(exprs)
    line = end_of_expression_line(last) + 1
    {exprs, line}
  end

  defp module_body(_), do: nil
  defp multi_statement_body?({:__block__, _, exprs}) when length(exprs) >= 2, do: true
  defp multi_statement_body?(_), do: false
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)

  defp patches_for_helper(
         :skip,
         _append_at_line,
         _arg_names,
         _fn_args,
         _fn_body,
         _fn_node,
         _free_vars
       ),
       do: []

  defp patches_for_helper(
         {:ok, helper_name},
         append_at_line,
         arg_names,
         fn_args,
         fn_body,
         fn_node,
         free_vars
       ) do
    helper_params = arg_names ++ free_vars
    fn_range = Sourceror.get_range(fn_node)

    # Replace the fn's body with a call to the helper. We rewrite
    # the whole `fn args -> body end`, preserving the original
    # argument patterns (so destructuring like `{a, b}` survives)
    # and just swapping the body for a helper call.
    new_fn_text = render_replacement_fn(fn_args, helper_name, helper_params)
    body_patch = Patch.new(replacement_range(fn_range), new_fn_text, false)

    helper_text = render_helper(helper_name, helper_params, fn_body)

    helper_range = %{
      end: [line: append_at_line, column: 1],
      start: [line: append_at_line, column: 1]
    }

    helper_patch = Patch.new(helper_range, "\n" <> helper_text <> "\n", false)

    [body_patch, helper_patch]
  end

  defp referenced_alias_heads(expr) do
    expr
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:__aliases__, _, [first | _]} when is_atom(first) -> [first]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp render_helper(helper_name, params, body_ast) do
    params_str = params |> Enum.map_join(", ", &Atom.to_string/1)
    body_str = body_ast |> Sourceror.to_string() |> indent_body()

    """
      # FIXME: extracted automatically by ExtractNestedBlock — review
      # the parameter list and consider a better name.
      defp #{helper_name}(#{params_str}) do
    #{body_str}
      end
    """
  end

  defp render_replacement_fn(fn_args, helper_name, helper_params) do
    args_str = fn_args |> Enum.map_join(", ", &Sourceror.to_string/1)
    params_str = helper_params |> Enum.map_join(", ", &Atom.to_string/1)
    "fn #{args_str} -> #{helper_name}(#{params_str}) end"
  end

  defp replacement_range(range),
    do: %{
      end: [line: range.end[:line], column: range.end[:column]],
      start: [line: range.start[:line], column: range.start[:column]]
    }

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp walk_with_depth({_, _, _} = node, depth) do
    nested? =
      match?(
        {tag, _, _} when tag in [:fn, :case, :cond, :if, :unless, :with, :for, :receive, :try],
        node
      )

    next_depth = if nested?, do: depth + 1, else: depth

    children =
      case node do
        {_, _, args} when is_list(args) -> args
        _ -> []
      end

    [{node, depth}] ++ Enum.flat_map(children, &walk_with_depth(&1, next_depth))
  end

  defp walk_with_depth(list, depth) when is_list(list) do
    list |> Enum.flat_map(&walk_with_depth(&1, depth))
  end

  defp walk_with_depth({left, right}, depth),
    do: walk_with_depth(left, depth) ++ walk_with_depth(right, depth)

  defp walk_with_depth(_leaf, _depth), do: []

  defp wraps_nesting_construct?({tag, _, _})
       when tag in [:case, :cond, :if, :unless, :with, :for, :receive, :try],
       do: true

  defp wraps_nesting_construct?(_), do: false
end
