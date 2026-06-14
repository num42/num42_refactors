defmodule Number42.Refactors.Ex.ExtractPipelineToFunction do
  @moduledoc """
  Extracts a long inline `|>` pipeline out of a function body into a
  named private helper. The pipeline's free variables become the
  helper's parameters; the call site passes them by name.

      # before
      def index(conn, params) do
        result =
          params
          |> Map.get("filters", %{})
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
          |> Enum.into(%{})
          |> Map.put(:org_id, conn.assigns.current_org.id)
          |> Repo.all()
          |> Enum.map(&serialize/1)

        json(conn, result)
      end

      # after
      def index(conn, params) do
        result = load_records(params, conn)
        json(conn, result)
      end

      defp load_records(params, conn) do
        params
        |> Map.get("filters", %{})
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
        |> Enum.into(%{})
        |> Map.put(:org_id, conn.assigns.current_org.id)
        |> Repo.all()
        |> Enum.map(&serialize/1)
      end

  ## Which pipeline is extracted

  The **first** statement in source order that is a single `|>` chain of
  at least `@min_stages` stages (default 5, where a stage is one `|>`
  operator), appearing either as

  - a binding `var = <pipeline>` (the bound var is read on after the
    extraction), or
  - a bare `<pipeline>` returned directly as the body's tail.

  A pipeline shorter than the threshold is a one-liner that reads fine
  inline — extracting it only adds indirection.

  ## Parameters and call

  **Parameters** = the pipeline's free variables — every bare variable
  referenced inside the chain that is not bound *within* the chain
  (lambda args, comprehension generators), restricted to names actually
  in scope at the extraction site (the host's parameters plus names
  bound by earlier statements). The **head seed** variable is the first
  parameter; the remaining free vars follow in source order. Each is
  threaded by its own name, so the call site is `helper(seed, …)` and
  the helper carries no unused arguments (warnings-as-errors safe).

  Closures inside the pipeline (`fn {_k, v} -> is_nil(v) end`,
  `&serialize/1`) are walked: a variable they *close over* from the
  outer scope is a free var and becomes a parameter; a variable they
  *bind themselves* is not.

  ## Helper naming

  Derived from the pipeline's **terminal call**, never a placeholder: a
  verb inferred from the last stage's function (`Repo.all` → `load`,
  `Enum.map` → `map`, `Enum.reduce` → `reduce`) joined to the head-seed
  variable as the object (`load_records`, `map_params`). When the verb
  or object is missing the host-derived `<fn>_pipeline` fallback is used
  (bang-safe: `build!` → `build_pipeline!`). A candidate that would
  shadow a parameter or the bound result variable is rejected; if even
  the fallback collides with an existing definition the extraction is
  skipped.

  ## Idempotence & determinism

  At most one pipeline is extracted per pass — the first eligible in
  source order. After extraction the host statement is a single
  `… = helper(…)` (or `helper(…)`) call, which is no longer a pipeline,
  so a second pass over the host finds nothing there. The freshly
  emitted helper body *is* the long pipeline, but a `defp` whose entire
  body is one extractable pipeline would extract to a helper that just
  calls itself — so a host whose body is exactly the pipeline (no other
  statement) is skipped, keeping the rewrite a fixpoint.

  ## What is skipped

  - A pipeline below `@min_stages`.
  - A pipeline whose result is never used (a bare-pipeline tail is fine —
    it is the return value; a `var = pipeline` whose `var` is never read
    afterwards is not extracted, the binding is dead).
  - A host whose body is *only* the pipeline — extracting it produces a
    helper identical to the host, pure churn (and the self-extraction
    above).
  - Multi-clause hosts — the helper is spliced as a sibling right after
    the host clause, which would split a multi-clause group.
  - A pipeline that references a module attribute (`@foo`) — attributes
    are in scope for the sibling `defp`, but threading them is subtle;
    conservative skip for v1.
  - A pipeline with no free variables in scope — nothing to seed the
    helper with (a chain off a literal or a module-only expression).

  ## Default-OFF (opt-in only)

  Disabled by default — `transform/2` is a no-op unless its own opts
  carry `enabled: true`. Pulling a pipeline into a `defp` is a judgement
  call: a long chain is sometimes the clearest expression of a transform
  right where it sits, and a name does not always pay for the
  indirection. Opt in per project:

      configured_modules: [
        {Number42.Refactors.Ex.ExtractPipelineToFunction, enabled: true}
      ]
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.HelperNaming

  @min_stages 5

  # Terminal-call function name → verb stem for the helper name. Kept
  # small and local: the helper is named after the *last* stage (what the
  # pipeline ultimately produces), so only the producing verbs matter.
  @terminal_verbs %{
    all: "load",
    one: "load",
    get: "load",
    get!: "load",
    list: "load",
    load: "load",
    fetch: "load",
    fetch!: "load",
    map: "map",
    flat_map: "map",
    reduce: "reduce",
    into: "build",
    new: "build",
    sum: "compute",
    count: "compute",
    filter: "filter",
    reject: "filter",
    group_by: "group",
    to_string: "format",
    join: "format"
  }

  @impl Number42.Refactors.Refactor
  def description,
    do: "Extract a long inline pipeline into a named private function (free vars → params)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A long inline `|>` chain bound to a variable, or returned directly,
    buries a named sub-computation inside its host. Lifting it into a
    `defp` — the chain's free variables as parameters, the head seed
    first — gives the transform a name and shrinks the host to its
    essential shape. The helper name is derived from the terminal call
    (`Repo.all` → `load_records`), never a generic placeholder.
    Conservative: only a single chain of at least five stages with an
    in-scope seed and no module-attribute dependency is moved.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      source |> Sourceror.parse_string() |> apply_to_parse_result(source)
    else
      source
    end
  end

  defp apply_to_parse_result({:ok, ast}, source), do: apply_to_ast(ast, source)
  defp apply_to_parse_result({:error, _}, source), do: source

  defp apply_to_ast(ast, source) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value(source, fn
      {:defmodule, _, [_name, [{_do, _body}]]} = mod_ast ->
        mod_ast
        |> module_body_exprs()
        |> first_extraction(source)

      _ ->
        nil
    end)
  end

  defp first_extraction(nil, _source), do: nil

  defp first_extraction(body_exprs, source) do
    existing_names = def_names(body_exprs)
    multi_keys = multi_clause_keys(body_exprs)

    Enum.find_value(body_exprs, fn expr ->
      extraction_for_def(expr, existing_names, multi_keys, source)
    end)
  end

  defp extraction_for_def(
         {kind, _, [head, body_kw]} = def_node,
         existing_names,
         multi_keys,
         source
       )
       when kind in [:def, :defp] and is_list(body_kw) do
    with {fn_name, params} <- extract_fn_signature(strip_when(head)),
         false <- MapSet.member?(multi_keys, {fn_name, length(params)}),
         {:ok, param_names} <- bare_param_names(params),
         {:ok, body} <- do_body(body_kw),
         exprs = body_to_exprs(body),
         true <- length(exprs) > 1,
         {:ok, index, target, stmt_node, seed, pipeline} <- find_pipeline(exprs, param_names),
         :ok <- ensure_extractable(pipeline),
         {:ok, args} <- pipeline_params(seed, pipeline, param_names, exprs, index),
         {:ok, helper_name} <-
           helper_name(fn_name, seed, pipeline, args, target, existing_names) do
      build_extraction(target, stmt_node, pipeline, args, helper_name, def_node, source)
    else
      _ -> nil
    end
  end

  defp extraction_for_def(_, _existing_names, _multi_keys, _source), do: nil

  # --- pipeline selection ---

  # The first statement that is a long-enough pipeline, either bound to a
  # single bare var that the rest of the body reads, or a bare-pipeline
  # tail. Returns {:ok, index, target, stmt_node, seed, pipeline} where
  # `target` is `{:bound, var}` or `:tail`, `stmt_node` is the whole
  # statement AST (its source range is what the call replaces), `seed` is
  # the chain's head expression and `pipeline` is the whole `|>` AST.
  defp find_pipeline(exprs, _param_names) do
    last_index = length(exprs) - 1

    exprs
    |> Enum.with_index()
    |> Enum.find_value(:skip, fn {expr, index} ->
      classify_statement(expr, index, last_index, exprs)
    end)
  end

  defp classify_statement({:=, _, [lhs, rhs]} = stmt, index, _last, exprs) do
    with {:ok, var} <- bare_var(lhs),
         {:ok, seed, pipeline} <- long_pipeline(rhs),
         true <- read_after?(var, exprs, index) do
      {:ok, index, {:bound, var}, stmt, seed, pipeline}
    else
      _ -> nil
    end
  end

  defp classify_statement(expr, index, last, _exprs) when index == last do
    case long_pipeline(expr) do
      {:ok, seed, pipeline} -> {:ok, index, :tail, expr, seed, pipeline}
      :skip -> nil
    end
  end

  defp classify_statement(_expr, _index, _last, _exprs), do: nil

  # A pipeline of at least @min_stages `|>` operators. Returns the head
  # seed (the left-most operand, not itself a pipe) and the whole node.
  defp long_pipeline({:|>, _, _} = node) do
    if pipe_stages(node) >= @min_stages, do: {:ok, pipe_head(node), node}, else: :skip
  end

  defp long_pipeline(_), do: :skip

  defp pipe_stages({:|>, _, [lhs, _rhs]}), do: 1 + pipe_stages(lhs)
  defp pipe_stages(_), do: 0

  defp pipe_head({:|>, _, [lhs, _rhs]}), do: pipe_head(lhs)
  defp pipe_head(node), do: node

  # --- eligibility ---

  defp ensure_extractable(pipeline) do
    if references_attribute?(pipeline), do: :skip, else: :ok
  end

  defp references_attribute?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:@, _, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) -> true
      _ -> false
    end)
  end

  # --- parameters ---

  # The pipeline's free variables, ordered head-seed-first then the rest
  # in source order. In scope = host params + names bound by statements
  # before this one. At least one is required (the seed) — a chain with
  # no in-scope variable has nothing to thread.
  defp pipeline_params(seed, pipeline, param_names, exprs, index) do
    in_scope =
      param_names
      |> MapSet.new()
      |> MapSet.union(bound_before(exprs, index))

    free =
      pipeline
      |> used_var_names()
      |> MapSet.difference(bound_in(pipeline))
      |> MapSet.intersection(in_scope)

    ordered = order_seed_first(seed, pipeline, free)

    case ordered do
      [] -> :skip
      names -> {:ok, names}
    end
  end

  defp bound_before(exprs, index) do
    exprs
    |> Enum.take(index)
    |> Enum.map(&bound_in/1)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  # Free vars in source order, with the head-seed var (if it is one of
  # the free vars) pulled to the front — the seed reads first in the
  # chain and is the conventional first parameter.
  defp order_seed_first(seed, pipeline, free) do
    seed_first =
      case bare_var(seed) do
        {:ok, name} -> if MapSet.member?(free, name), do: [name], else: []
        :skip -> []
      end

    rest =
      pipeline
      |> vars_in_source_order()
      |> Enum.filter(&MapSet.member?(free, &1))
      |> Enum.reject(&(&1 in seed_first))
      |> Enum.uniq()

    seed_first ++ rest
  end

  # Bare-variable names in left-to-right source order (a pre-order walk
  # of the AST yields them in textual order for a pipeline chain).
  defp vars_in_source_order(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
        if underscore?(name) or name in [:__MODULE__, :__CALLER__, :__ENV__],
          do: [],
          else: [name]

      _ ->
        []
    end)
  end

  # --- helper naming ---

  defp helper_name(fn_name, seed, pipeline, params, target, existing_names) do
    in_scope = MapSet.new(params ++ target_names(target))
    fallback = HelperNaming.suffixed(fn_name, "_pipeline")

    derived =
      [
        compose(terminal_verb(pipeline), seed_object(seed)),
        seed_object(seed),
        strip_suffix(fn_name)
      ]
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(in_scope, &1)))

    first_free(derived ++ [fallback], existing_names)
  end

  defp target_names({:bound, var}), do: [var]
  defp target_names(:tail), do: []

  defp terminal_verb(pipeline) do
    case extract_call_name(pipeline) do
      {:ok, fun} -> Map.get(@terminal_verbs, fun)
      :error -> nil
    end
  end

  # The head seed gives the object: a bare var (`params`) names what
  # flows in. A non-var seed (a literal, a call) yields nothing — the
  # name then leans on the host-derived fallback.
  defp seed_object(seed) do
    case bare_var(seed) do
      {:ok, name} -> if meaningful_name?(name), do: name, else: nil
      :skip -> nil
    end
  end

  defp compose(nil, _object), do: nil
  defp compose(_verb, nil), do: nil
  defp compose(verb, object), do: :"#{verb}_#{object}"

  defp strip_suffix(host) do
    name = Atom.to_string(host)
    if String.contains?(name, "_"), do: host, else: nil
  end

  defp meaningful_name?(name) do
    str = Atom.to_string(name)

    String.length(str) > 2 and
      not String.starts_with?(str, "_") and
      not String.ends_with?(str, ["?", "!"])
  end

  defp first_free([], _existing), do: :skip

  defp first_free([candidate | rest], existing) do
    if MapSet.member?(existing, candidate),
      do: first_free(rest, existing),
      else: {:ok, candidate}
  end

  # --- patch construction ---

  defp build_extraction(target, stmt_node, pipeline, params, helper_name, def_node, source) do
    call_args = Enum.map_join(params, ", ", &Atom.to_string/1)
    call_text = "#{helper_name}(#{call_args})"

    replacement = call_replacement(target, call_text)
    replace_patch = patch_for(Sourceror.get_range(stmt_node), replacement)

    helper_text = render_helper(helper_name, params, pipeline)
    insert_patch = helper_insert_patch(def_node, helper_text)

    patches = Enum.reject([replace_patch, insert_patch], &is_nil/1)
    patch_or_passthrough(source, patches)
  end

  # The whole statement's range is replaced: a bound pipeline becomes
  # `var = helper(args)`, a tail pipeline becomes `helper(args)`.
  defp call_replacement({:bound, var}, call_text), do: "#{var} = #{call_text}"
  defp call_replacement(:tail, call_text), do: call_text

  defp helper_insert_patch(def_node, helper_text) do
    case Sourceror.get_range(def_node) do
      %{end: end_pos} -> %{change: "\n\n" <> helper_text, range: %{start: end_pos, end: end_pos}}
      _ -> nil
    end
  end

  defp render_helper(helper_name, params, pipeline) do
    args = Enum.map_join(params, ", ", &Atom.to_string/1)
    body_text = Sourceror.to_string(pipeline)

    "  defp #{helper_name}(#{args}) do\n" <>
      indent(body_text) <>
      "\n  end"
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "    " <> line
    end)
  end

  defp patch_for(%{} = range, change), do: %{change: change, range: range}
  defp patch_for(_, _), do: nil

  # --- shared scaffolding ---

  defp do_body(body_kw) when is_list(body_kw) do
    Enum.find_value(body_kw, :skip, fn
      {{:__block__, _, [:do]}, value} -> {:ok, value}
      {:do, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp do_body(_), do: :skip

  defp bare_param_names(params) do
    params
    |> Enum.reduce_while([], fn param, acc ->
      case bare_var(param) do
        {:ok, name} -> {:cont, [name | acc]}
        :skip -> {:halt, :skip}
      end
    end)
    |> case do
      :skip -> :skip
      names -> {:ok, Enum.reverse(names)}
    end
  end

  defp def_names(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {kind, _, [head | _]} when kind in [:def, :defp] ->
        case extract_fn_signature(strip_when(head)) do
          {name, _args} -> [name]
          _ -> []
        end

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp multi_clause_keys(body_exprs) do
    body_exprs
    |> Enum.flat_map(&def_arity_key/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(fn {key, _count} -> key end)
    |> MapSet.new()
  end

  defp def_arity_key({kind, _, [head | _]}) when kind in [:def, :defp] do
    case extract_fn_signature(strip_when(head)) do
      {name, args} -> [{name, length(args)}]
      _ -> []
    end
  end

  defp def_arity_key(_), do: []

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp patch_or_passthrough(source, []), do: source
  defp patch_or_passthrough(source, patches), do: Sourceror.patch_string(source, patches)
end
