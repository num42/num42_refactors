defmodule Number42.Refactors.Ex.ExtractRepeatedGuardToDefguard do
  @moduledoc """
  Name a complex guard predicate as a `defguardp` and route clause
  dispatch through it. Two sources feed the same target:

  ## Source A — a `when`-guard repeated across **N >= 3** clauses

  Extract a single-variable guard that appears on three or more clause
  heads into a `defguardp`, and replace each occurrence with the named
  guard.

      def fetch(id) when is_integer(id) and id > 0, do: do_fetch(id)
      def update(id, attrs) when is_integer(id) and id > 0, do: do_update(id, attrs)
      def delete(id) when is_integer(id) and id > 0, do: do_delete(id)
      ↓
      defguardp is_valid_id(id) when is_integer(id) and id > 0

      def fetch(id) when is_valid_id(id), do: do_fetch(id)
      def update(id, attrs) when is_valid_id(id), do: do_update(id, attrs)
      def delete(id) when is_valid_id(id), do: do_delete(id)

  ## Source B — a body `if` whose condition is a complex guard

  A `def f(p) do if COND, do: A, else: B end` whose `COND` is a
  guard-expressible predicate over the parameters is lifted into a
  named `defguardp` plus two guard-driven clauses — but **only** when
  the condition is *complex* (`>= 2` guard operators). Naming a
  one-operator condition (`n < 0`, `is_atom(x)`) adds no value, so those
  are left to `ExtractCondIfGuardClauses`, which lifts them inline as a
  `when` guard. This refactor takes over exactly the cases where the
  condition is worth a name — it cannot be read at a glance as a single
  guard term.

      def classify(n) do
        if is_integer(n) and n > 0, do: :pos, else: :other
      end
      ↓
      defguardp is_valid_n(n) when is_integer(n) and n > 0

      def classify(n) when is_valid_n(n), do: :pos
      def classify(n), do: :other

  Source A runs first; a module with a repeated head-guard is handled
  there. Source B only fires when source A finds nothing in the module.

  ## Why this is sound

  A guard expression already passed the compiler's guard-clause check
  (it stood in a `when`), so it is guard-legal — and `defguard`/`defguardp`
  accept exactly the guard-legal subset. The extraction therefore never
  produces an illegal guard body; it only gives a name to one that
  already type-checked as a guard.

  ## Trigger

  The same guard, **structurally equal modulo the single guarded var
  name**, appears in `>= min_occurrences` (default `3`) clause heads in
  one module. `is_integer(id) and id > 0` and `is_integer(n) and n > 0`
  are the *same* guard — the variable is normalised before comparison.

  ## Naming and placement

  The `defguardp <name>(<param>) when <expr>` is inserted at the first
  top-level expression of the module body (after aliases, before the
  first clause that uses it). The name is `is_valid_<var>` derived from
  the guarded variable; on collision a numeric suffix is appended.

  ## v1 scope: single guarded variable

  Only guards over **one** parameter are handled. The guard may name
  that parameter any number of times, but every other leaf must be a
  literal. A guard touching two parameters (`a > 0 and b > 0`) would
  need a multi-arg `defguardp` with a positional convention — left as a
  follow-up.

  ## Skip conditions (source left unchanged when any holds)

  - **Below threshold.** Fewer than `min_occurrences` clauses share the
    guard.
  - **Multiple guarded variables.** The guard references more than one
    distinct parameter name — out of v1 scope.
  - **Guarded variable not a bare parameter.** The variable in the
    guard must be a bare parameter of *every* clause carrying the guard;
    a destructured or absent slot disqualifies that clause.
  - **Already a named guard.** A `when <name>(<var>)` whose `<name>` is
    a guard defined in the same module is left alone — idempotence.
  - **`defmacro`/`defmacrop`.** Only `def`/`defp` heads are touched.

  ## Idempotence

  All eligible groups in a module are extracted in a single pass, so the
  rewrite converges immediately. After it, each head reads
  `when is_valid_<var>(<var>)`, a named-guard call rather than the
  original expression, and the synthesised `defguardp` is recognised as
  an existing module guard — so a re-run finds nothing to do. Safe to run
  repeatedly.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @default_min_occurrences 3

  @impl Number42.Refactors.Refactor
  def description,
    do: "Extract a `when`-guard repeated across >= 3 clauses into a `defguardp`"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A guard expression copy-pasted onto three or more clause heads has
    its meaning spread across every copy and drifts when one copy is
    edited. Naming it once as a `defguardp` gives the predicate a single
    definition and an intent-revealing name, and each head says
    `when is_valid_id(id)` instead of restating the arithmetic. The
    extraction is sound because a guard that compiled in a `when` is by
    definition guard-legal, which is exactly what `defguardp` accepts.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  # Source B competes with `ExtractCondIfGuardClauses` (priority 60) on a
  # body `if`: both can lift a guard-expressible condition. We run first
  # (higher priority) so a *complex* condition is named as a `defguardp`
  # before the other refactor would inline it. After our rewrite the body
  # is no longer a single `if`, so the inline lifter no longer matches.
  # A simple (one-operator) condition we decline via `complex_guard?/1`,
  # leaving it to the inline lifter — the intended division of labour.
  @impl Number42.Refactors.Refactor
  def priority, do: 70

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    min = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
    Sourceror.parse_string(source) |> apply_patches(source, min)
  end

  @impl Number42.Refactors.Refactor
  def patches(ast, _source, opts) do
    min = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
    build_patches(ast, min)
  end

  defp apply_patches({:ok, ast}, source, min),
    do: ast |> build_patches(min) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source, _min), do: source

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp build_patches(ast, min) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value([], fn
      {:defmodule, _, [_name, [{_do, body}]]} -> module_patches(body, min)
      _ -> nil
    end)
  end

  # Every eligible group is extracted in a single pass. Source A (repeated
  # head-guard) runs first; if it finds nothing, source B (complex body-`if`)
  # gets a turn. Emitting all groups at once is what makes the refactor
  # converge in one pass — lifting one group per pass left the rest for a
  # follow-up pass and broke idempotence (#269).
  defp module_patches(body, min) do
    exprs = body_to_exprs(body)
    existing = existing_guard_names(exprs)

    case head_guard_patches(exprs, existing, min) do
      [] -> body_if_patches(exprs, existing)
      patches -> patches
    end
  end

  # All groups at or above the threshold, in source order, each named into a
  # `defguardp`. Two sets are threaded: `existing` are guards already defined
  # in the module — a group whose base name is one of them is left alone (the
  # re-run idempotence path, #269). `minted` are names created earlier in this
  # same pass — a fresh group colliding with one is disambiguated rather than
  # re-defining a name. Emitting every group here is what converges the
  # refactor in one pass.
  defp head_guard_patches(exprs, existing, min) do
    exprs
    |> Enum.flat_map(&guarded_clause/1)
    |> Enum.group_by(& &1.key)
    |> Map.values()
    |> Enum.filter(&(length(&1) >= min))
    |> Enum.sort_by(fn [first | _] -> line_of(first.node) end)
    |> Enum.reduce({[], MapSet.new()}, fn group, {patches, minted} ->
      case emit_group(group, exprs, existing, minted) do
        nil -> {patches, minted}
        {group_patches, name} -> {patches ++ group_patches, MapSet.put(minted, name)}
      end
    end)
    |> elem(0)
  end

  # --- candidate extraction --------------------------------------------

  # A guarded `def`/`defp` clause whose guard is a single-variable guard
  # over a bare parameter. Returns the data needed to group and rewrite,
  # or `[]` to skip.
  defp guarded_clause({kind, _, [{:when, _, [head, guard]}, _body]} = node)
       when kind in [:def, :defp] do
    with {:ok, params} <- head_params(head),
         {:ok, var} <- single_guard_var(guard),
         true <- var in params do
      [%{node: node, guard: guard, var: var, key: guard_key(guard, var)}]
    else
      _ -> []
    end
  end

  defp guarded_clause(_), do: []

  defp head_params({name, _, args}) when is_atom(name) and is_list(args) do
    args
    |> Enum.reduce_while([], fn arg, acc ->
      case bare_var(arg) do
        {:ok, n} -> {:cont, [n | acc]}
        :skip -> {:cont, acc}
      end
    end)
    |> then(&{:ok, &1})
  end

  defp head_params(_), do: :skip

  # The set of distinct variable names a guard reads. Exactly one →
  # single-var guard. A named-guard call already counts as a guard call
  # in `guard_callable?`, so an already-extracted head with one arg also
  # has a single var — but it carries no repeated *literal* expression to
  # group on, so it never reaches the threshold with peers.
  defp single_guard_var(guard) do
    case guard |> guard_vars() |> MapSet.to_list() do
      [var] -> {:ok, var}
      _ -> :skip
    end
  end

  defp guard_vars(guard) do
    guard
    |> Macro.prewalker()
    |> Enum.reduce(MapSet.new(), fn
      {name, _, ctx}, acc when is_atom(name) and is_atom(ctx) ->
        if special_var?(name), do: acc, else: MapSet.put(acc, name)

      _, acc ->
        acc
    end)
  end

  defp special_var?(name), do: name in [:__MODULE__, :__CALLER__, :__ENV__]

  # --- grouping --------------------------------------------------------

  # Structural key: the guard with its single var renamed to a canonical
  # hole and all metadata stripped, so `is_integer(id) and id > 0` and
  # `is_integer(n) and n > 0` hash to the same group.
  defp guard_key(guard, var) do
    guard
    |> normalise_var(var)
    |> strip_all_meta()
    |> :erlang.phash2()
  end

  defp normalise_var(guard, var) do
    Macro.prewalk(guard, fn
      {^var, meta, ctx} when is_atom(ctx) -> {:__guard_var__, meta, ctx}
      node -> node
    end)
  end

  # --- emit ------------------------------------------------------------

  # The group shares one name, derived from the first member's var; each
  # head keeps its own var as the argument. A group whose base name is
  # already a module guard (re-running on extracted output) is skipped —
  # this is the idempotence guard. Otherwise the name is disambiguated
  # against names minted earlier in this pass and the group's patches plus
  # the chosen name are returned.
  defp emit_group([first | _] = group, exprs, existing, minted) do
    base = guard_name(first.var)

    if MapSet.member?(existing, base) do
      nil
    else
      name = unique_name(base, minted)

      head_replacements =
        Enum.map(group, fn %{guard: guard, var: var} ->
          Patch.replace(guard, "#{name}(#{var})")
        end)

      {[defguardp_patch(first, name, exprs) | head_replacements], name}
    end
  end

  # One line-anchored insertion of the `defguardp ... when ...` line,
  # placed at the first top-level expression's line, column 1 — after
  # the module's aliases, before the first clause that uses it.
  defp defguardp_patch(%{guard: guard, var: var}, name, exprs) do
    line = exprs |> hd() |> line_of()
    text = "defguardp #{name}(#{var}) when #{Sourceror.to_string(guard)}\n\n"
    range = %{start: [line: line, column: 1], end: [line: line, column: 1]}
    Patch.new(range, text, false)
  end

  # --- naming ----------------------------------------------------------

  # `id → is_valid_id`. An underscore-led var keeps a clean name.
  defp guard_name(var) do
    base = var |> Atom.to_string() |> String.trim_leading("_")
    :"is_valid_#{base}"
  end

  # Two distinct guards over identically-named vars derive the same base
  # name; when emitting them in one pass the second gets a numeric suffix so
  # the module never defines a `defguardp` name twice. `taken` are names
  # already minted in this pass.
  defp unique_name(base, taken) do
    if MapSet.member?(taken, base),
      do: next_free_name(base, taken, 1),
      else: base
  end

  defp next_free_name(base, taken, n) do
    candidate = :"#{base}#{n}"
    if MapSet.member?(taken, candidate), do: next_free_name(base, taken, n + 1), else: candidate
  end

  # Guard names already defined in the module via `defguard`/`defguardp`,
  # so a head already calling one is recognised and left alone.
  defp existing_guard_names(exprs) do
    exprs
    |> Enum.flat_map(fn
      {kind, _, [{:when, _, [{name, _, args}, _guard]} | _]}
      when kind in [:defguard, :defguardp] and is_atom(name) and is_list(args) ->
        [name]

      _ ->
        []
    end)
    |> MapSet.new()
  end

  # --- Source B: complex body-`if` -> named defguardp ------------------

  # Scan the module body in source order for every `def`/`defp` whose entire
  # body is a two-branch `if COND, do: A, else: B` with a *complex*
  # guard-expressible condition over the parameters. Each is lifted to a
  # `defguardp` plus two guard clauses. All candidates are emitted in one
  # pass, with names disambiguated against each other and skipped when the
  # base name already names a module guard (#269).
  defp body_if_patches(exprs, existing) do
    exprs
    |> Enum.flat_map(fn expr -> List.wrap(body_if_candidate(expr)) end)
    |> Enum.reduce({[], MapSet.new()}, fn cand, {patches, minted} ->
      case emit_body_if(cand, exprs, existing, minted) do
        nil -> {patches, minted}
        {cand_patches, name} -> {patches ++ cand_patches, MapSet.put(minted, name)}
      end
    end)
    |> elem(0)
  end

  defp emit_body_if(%{var: var} = cand, exprs, existing, minted) do
    base = guard_name(var)

    if MapSet.member?(existing, base) do
      nil
    else
      name = unique_name(base, minted)
      {[defguardp_patch_for_cond(cand, name, exprs), clauses_patch(cand, name)], name}
    end
  end

  # A liftable body-`if`: head has no `when`-guard and only bare params,
  # the whole body is one `if`/`else`, and the condition is a complex
  # (`>= 2` guard-operator) guard over a single parameter.
  defp body_if_candidate({kind, _, [head, body_kw]} = node)
       when kind in [:def, :defp] and is_list(body_kw) do
    with false <- has_when_guard?(head),
         {fn_name, params} <- fn_signature(head),
         {:ok, param_names} <- bare_param_names(params),
         {:ok, body} <- do_body(body_kw),
         {:ok, {cond_ast, do_branch, else_branch}} <- if_branches(body),
         param_set = MapSet.new(param_names),
         true <- guard_safe?(cond_ast, param_set),
         true <- complex_guard?(cond_ast),
         {:ok, var} <- single_cond_var(cond_ast, param_set) do
      %{
        node: node,
        kind: kind,
        fn_name: fn_name,
        params: params,
        cond: cond_ast,
        do_branch: do_branch,
        else_branch: else_branch,
        var: var
      }
    else
      _ -> nil
    end
  end

  defp body_if_candidate(_), do: nil

  defp has_when_guard?({:when, _, _}), do: true
  defp has_when_guard?(_), do: false

  defp fn_signature({:when, _, [head | _]}), do: fn_signature(head)
  defp fn_signature({name, _, args}) when is_atom(name) and is_list(args), do: {name, args}
  defp fn_signature(_), do: :skip

  defp bare_param_names(params) do
    params
    |> Enum.reduce_while([], fn arg, acc ->
      case bare_var(arg) do
        {:ok, n} -> {:cont, [n | acc]}
        :skip -> {:halt, :skip}
      end
    end)
    |> case do
      :skip -> :skip
      names -> {:ok, Enum.reverse(names)}
    end
  end

  defp do_body(body_kw) do
    Enum.find_value(body_kw, :skip, fn
      {{:__block__, _, [:do]}, value} -> {:ok, value}
      {:do, value} -> {:ok, value}
      _ -> nil
    end)
  end

  # The body must be exactly one `if cond do ... else ... end`. Both
  # branches required — a guard-only single-branch `if` is left alone
  # (it would need a `nil` catch-all, a behaviour the bare `if` states
  # more readably; see ExtractCondIfGuardClauses).
  defp if_branches(body) do
    case body_to_exprs(body) do
      [{:if, _, [cond_ast, branches]}] when is_list(branches) ->
        split_branches(cond_ast, branches)

      _ ->
        :skip
    end
  end

  defp split_branches(cond_ast, branches) do
    {do_branch, else_branch} =
      Enum.reduce(branches, {nil, nil}, fn
        {{:__block__, _, [:do]}, v}, {_, e} -> {v, e}
        {:do, v}, {_, e} -> {v, e}
        {{:__block__, _, [:else]}, v}, {d, _} -> {d, v}
        {:else, v}, {d, _} -> {d, v}
        _, acc -> acc
      end)

    if do_branch != nil and else_branch != nil,
      do: {:ok, {cond_ast, do_branch, else_branch}},
      else: :skip
  end

  # The condition must read exactly one parameter — a multi-param guard
  # would need a positional `defguardp` convention (same v1 boundary as
  # source A).
  defp single_cond_var(cond_ast, param_set) do
    cond_ast
    |> guard_vars()
    |> Enum.filter(&MapSet.member?(param_set, &1))
    |> case do
      [var] -> {:ok, var}
      _ -> :skip
    end
  end

  # --- guard safety + complexity (Source B) ----------------------------

  # A guard-safe condition: every operator/function is guard-allowed and
  # every leaf variable is one of the function parameters. Mirrors
  # ExtractCondIfGuardClauses' `guard_safe?/2` so the two agree on which
  # conditions count as guards.
  defp guard_safe?(ast, param_set) do
    ast |> Macro.prewalker() |> Enum.all?(&guard_node_safe?(&1, param_set))
  end

  defp guard_node_safe?(lit, _set)
       when is_atom(lit) or is_integer(lit) or is_float(lit) or is_binary(lit),
       do: true

  defp guard_node_safe?({:__block__, _, _}, _set), do: true
  defp guard_node_safe?(list, _set) when is_list(list), do: true
  defp guard_node_safe?({_a, _b}, _set), do: true

  defp guard_node_safe?({name, _, ctx}, set) when is_atom(name) and is_atom(ctx),
    do: name in [:__MODULE__, :__CALLER__, :__ENV__] or MapSet.member?(set, name)

  defp guard_node_safe?({fun, _, args}, _set) when is_atom(fun) and is_list(args),
    do: guard_allowed_call?(fun)

  defp guard_node_safe?(_, _set), do: false

  @guard_ops ~w(== != === !== < > <= >= and or not && || ! + - * / in)a
  @guard_bifs ~w(is_atom is_binary is_bitstring is_boolean is_float is_function
                 is_integer is_list is_map is_map_key is_nil is_number is_pid
                 is_port is_reference is_tuple abs bit_size byte_size ceil
                 div elem floor hd length map_size node rem round self
                 tl trunc tuple_size)a
  @guard_callable MapSet.new(@guard_ops ++ @guard_bifs)

  defp guard_allowed_call?(fun), do: MapSet.member?(@guard_callable, fun)

  # The naming gate: a condition is worth a `defguardp` only when it is a
  # compound predicate — at least two guard operators/BIFs. A single
  # comparison or `is_*` predicate (`n < 0`, `is_atom(x)`) reads fine
  # inline, so it's left to ExtractCondIfGuardClauses.
  defp complex_guard?(cond_ast) do
    cond_ast
    |> Macro.prewalker()
    |> Enum.count(fn
      {fun, _, args} when is_atom(fun) and is_list(args) -> guard_allowed_call?(fun)
      _ -> false
    end)
    |> Kernel.>=(2)
  end

  # --- emit (Source B) -------------------------------------------------

  defp defguardp_patch_for_cond(%{cond: cond_ast, var: var}, name, exprs) do
    line = exprs |> hd() |> line_of()
    text = "defguardp #{name}(#{var}) when #{guard_text(cond_ast)}\n\n"
    range = %{start: [line: line, column: 1], end: [line: line, column: 1]}
    Patch.new(range, text, false)
  end

  defp clauses_patch(%{var: var} = cand, name) do
    %{kind: kind, fn_name: fn_name, params: params, do_branch: do_b, else_branch: else_b} = cand

    # Guard clause: `var` is read by the named guard, so force-keep it
    # un-underscored; other params follow the do-branch. Catch-all: the
    # guard is gone, so `var` follows the else-branch like any other param.
    guard_head =
      "#{clause_head(kind, fn_name, params, [do_b], [var])} when #{name}(#{var})"

    catch_head = clause_head(kind, fn_name, params, [else_b], [])

    guard_clause = render_clause_body(guard_head, do_b)
    catch_all = render_clause_body(catch_head, else_b)

    Patch.replace(cand.node, "#{guard_clause}\n\n#{catch_all}")
  end

  # `if` takes the then-branch for any truthy value, but a `when` guard
  # fires only on literal `true`. A boolean-proven condition matches `if`'s
  # truthiness verbatim; a non-boolean truthy term is wrapped in
  # `not in [nil, false]`. Mirrors ExtractCondIfGuardClauses.
  defp guard_text(cond_ast) do
    text = Sourceror.to_string(cond_ast)
    if boolean_guard?(cond_ast), do: text, else: "#{text} not in [nil, false]"
  end

  @boolean_ops ~w(== != === !== < > <= >= and or not && || ! in)a

  defp boolean_guard?(true), do: true
  defp boolean_guard?(false), do: true
  defp boolean_guard?({:__block__, _, [inner]}), do: boolean_guard?(inner)
  defp boolean_guard?({op, _, _}) when op in @boolean_ops, do: true

  defp boolean_guard?({fun, _, args}) when is_atom(fun) and is_list(args),
    do: String.starts_with?(Atom.to_string(fun), "is_")

  defp boolean_guard?(_), do: false

  # A param is kept (not underscored) when it appears in the clause body or
  # in `forced` (the guard arg names, for the do-clause). Mirrors
  # ExtractCondIfGuardClauses' unused-var underscoring.
  defp clause_head(kind, fn_name, params, body_asts, forced) do
    used = MapSet.new(collect_var_names(body_asts) ++ forced)
    "#{kind} #{fn_name}(#{param_text(underscore_unused(params, used))})"
  end

  defp collect_var_names(asts) do
    asts
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> [name]
      _ -> []
    end)
  end

  defp underscore_unused(params, used), do: Enum.map(params, &underscore_param(&1, used))

  defp underscore_param({name, meta, ctx} = param, used) do
    if MapSet.member?(used, name) or underscored?(name),
      do: param,
      else: {:"_#{name}", meta, ctx}
  end

  defp underscore_param(other, _used), do: other
  defp underscored?(name), do: String.starts_with?(Atom.to_string(name), "_")

  defp render_clause_body(head, body) do
    case body_lines(body) do
      {:single, text} -> "#{head}, do: #{text}"
      {:multi, text} -> "#{head} do\n#{text}\nend"
    end
  end

  defp body_lines({:__block__, _, exprs}) when length(exprs) > 1,
    do: {:multi, exprs |> Enum.map_join("\n", &Sourceror.to_string/1)}

  defp body_lines(single) do
    text = Sourceror.to_string(single)
    if String.contains?(text, "\n"), do: {:multi, text}, else: {:single, text}
  end

  defp param_text(params), do: Enum.map_join(params, ", ", &Sourceror.to_string/1)

  # --- small utils -----------------------------------------------------

  defp strip_all_meta(ast),
    do:
      Macro.prewalk(ast, fn
        {f, _m, a} -> {f, [], a}
        other -> other
      end)
end
