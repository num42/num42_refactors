defmodule Number42.Refactors.Ex.ExtractCondIfGuardClauses do
  @moduledoc """
  Lifts a `def`/`defp` whose entire body is a two-branch `if`/`else`
  with a guard-expressible condition into two guard-driven clauses.

      def classify(n) do
        if n < 0, do: :neg, else: :pos
      end
      ↓
      def classify(n) when n < 0, do: :neg
      def classify(n), do: :pos

  The two-branch sibling of `ExtractCondToGuardClauses`: where that lifts
  an N-way `cond`, this lifts a two-way `if`/`else`. The `if` condition
  becomes a `when` guard on the do-clause; the `else`-branch becomes a
  bare catch-all clause. Dispatch order is preserved (guard clause first,
  catch-all second), so semantics are identical to the original `if`.

  ## Difference from `IfLiftToClauses`

  `IfLiftToClauses` synthesizes head patterns (struct/map field
  destructuring, literal-equality patterns, pinning). This refactor is a
  strict subset: it lifts **only** a guard-expressible condition into a
  `when` guard, never touching the head pattern. It exists for the cases
  where `IfLiftToClauses` is over-qualified — the condition is a plain
  guard expression over the parameters and no pattern synthesis applies.

  Reuses the guard-safety predicate (`guard_safe?/2` over `guard_node_safe?`
  + `guard_allowed_call?/1`) from `ExtractCondToGuardClauses` so the two
  agree on exactly which conditions count as guards.

  Each lifted clause gets its own parameter list: a parameter used in
  neither the clause's guard nor its body is underscored (`_n`), so the
  result compiles without unused-variable warnings.

  ## What lifts

  An `if`/`else` is liftable only when its condition is a valid guard
  expression over the function's parameters:

    * comparison/equality operators (`<`, `>`, `==`, `!=`, …),
    * boolean combinators (`and`/`or`/`not`/`&&`/`||`/`!`),
    * arithmetic and bitwise operators allowed in guards,
    * the guard-allowed BIFs (`is_*`, `length`, `map_size`, `hd`, `elem`,
      `rem`, …),
    * leaves that are literals or references to the function's params.

  ## Truthiness preservation

  `if` takes the then-branch for any *truthy* value — everything except
  `nil` and `false`. A `when` guard, by contrast, fires only on a literal
  `true`. Copying the condition verbatim into the guard would therefore
  silently change behaviour whenever the condition evaluates to a truthy
  non-`true` value (a string, a number, a map, …): the guard would fail
  and the else-branch would run instead.

  To keep the lifted form semantically identical to the `if`, the
  condition is classified:

    * **Boolean-proven** — a comparison/equality (`==`, `<`, …), an `is_*`
      predicate, a boolean combinator (`and`/`or`/`not`/`&&`/`||`/`!`),
      `in`, or a boolean literal. Its value is already `true`/`false`, so
      the guard is used verbatim (`when n > 0`).
    * **Truthy but not boolean-proven** — a bare variable (`if prefix`),
      or another guard-legal term whose value need not be boolean
      (`elem(t, 0)`, arithmetic, `hd/1`, …). The guard is wrapped as
      `when COND not in [nil, false]`, which is guard-legal and reproduces
      `if`'s truthiness exactly.

  ## What we skip

    * A condition calling a non-guard function (`valid?(n)`,
      `String.length(s) > 3`) — not guard-safe. Left for the engine's
      other passes (or no pass).
    * A condition referencing anything other than a function parameter
      (a local binding, a module attribute) — out of guard scope.
    * An `if` without an `else` branch — that would need a `nil`
      catch-all clause (the value the falsy `if` returns); pattern-based
      single-branch lifting is `IfLiftToClauses`' job, and lifting a
      guard-only single-branch `if` here would change the function from
      total to a two-clause form whose catch-all returns `nil`, which is
      a behaviour the bare `if` already expresses more readably.
    * A `def`/`defp` head with any non-bare parameter or an existing
      `when`-guard — merging guards is risky (matches `IfLiftToClauses`
      and `ExtractCondToGuardClauses`).
    * `defmacro`/`defmacrop`.
    * A body that is anything other than exactly one `if` expression
      (an `if` embedded inside a larger body does not lift).

  ## Idempotence

  After lifting, the function is two guard clauses, neither of which has
  a single-`if` body, so a second pass finds no match.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Lift `def f(p) do if guard, do: x, else: y end` to guard-driven clauses"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A function whose whole body is `if guard, do: X, else: Y` over its
    parameters is a clause dispatch written as a branch. When the
    condition is a valid guard, the guard-clause form moves the decision
    into the clause heads and removes the `if` nesting level — without
    changing the do/else dispatch order. A strict subset of
    `IfLiftToClauses` (no pattern synthesis), for cases where that
    refactor is over-qualified.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 60

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast, source) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&maybe_patch(&1, source))
  end

  defp maybe_patch({kind, _, [head, body_kw]} = node, source)
       when kind in [:def, :defp] and is_list(body_kw) do
    with false <- has_when_guard?(head),
         {fn_name, params} <- extract_fn_signature(head),
         {:ok, param_names} <- bare_param_names(params),
         {:ok, body} <- do_body(body_kw),
         {:ok, {cond_ast, do_branch, else_branch}} <- if_branches(body),
         true <- guard_safe?(cond_ast, MapSet.new(param_names)) do
      clauses = [{:guard, cond_ast, do_branch}, {:catch_all, else_branch}]
      [Patch.replace(node, render_clauses(kind, fn_name, params, clauses, source))]
    else
      _ -> []
    end
  end

  defp maybe_patch(_, _), do: []

  defp has_when_guard?({:when, _, _}), do: true
  defp has_when_guard?(_), do: false

  defp bare_param_names(params), do: reduce_ok(params, &bare_var/1)

  # The body must be exactly one `if cond do ... else ... end` (or the
  # keyword form `if cond, do: x, else: y`). Both branches required.
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

  # A guard-safe condition: every operator/function is guard-allowed and
  # every leaf variable is one of the function parameters.
  defp guard_safe?(ast, param_set) do
    ast
    |> Macro.prewalker()
    |> Enum.all?(&guard_node_safe?(&1, param_set))
  end

  defp guard_node_safe?(lit, _param_set)
       when is_atom(lit) or is_integer(lit) or is_float(lit) or is_binary(lit),
       do: true

  defp guard_node_safe?({:__block__, _, _}, _param_set), do: true
  defp guard_node_safe?(list, _param_set) when is_list(list), do: true
  defp guard_node_safe?({_a, _b}, _param_set), do: true

  defp guard_node_safe?({name, _, ctx}, param_set) when is_atom(name) and is_atom(ctx),
    do: param_var?(name, param_set)

  defp guard_node_safe?({fun, _, args}, _param_set) when is_atom(fun) and is_list(args),
    do: guard_allowed_call?(fun)

  defp guard_node_safe?(_, _param_set), do: false

  defp param_var?(name, param_set) do
    name in [:__MODULE__, :__CALLER__, :__ENV__] or MapSet.member?(param_set, name)
  end

  # Guard-allowed operators and BIFs (Kernel guard subset). A bare local
  # call to anything outside this set is not guard-safe.
  @guard_ops ~w(== != === !== < > <= >= and or not && || ! + - * / in)a
  @guard_bifs ~w(is_atom is_binary is_bitstring is_boolean is_float is_function
                 is_integer is_list is_map is_map_key is_nil is_number is_pid
                 is_port is_reference is_tuple abs bit_size byte_size ceil
                 div elem floor hd length map_size node rem round self
                 tl trunc tuple_size)a
  @guard_callable MapSet.new(@guard_ops ++ @guard_bifs)

  defp guard_allowed_call?(fun), do: MapSet.member?(@guard_callable, fun)

  defp render_clauses(kind, fn_name, params, clauses, source) do
    clauses
    |> Enum.map_join("\n\n", &render_clause(&1, kind, fn_name, params, source))
  end

  defp render_clause({:guard, cond_ast, body}, kind, fn_name, params, source) do
    head = clause_head(kind, fn_name, params, [cond_ast, body])
    render_body("#{head} when #{guard_text(cond_ast)}", body, source)
  end

  defp render_clause({:catch_all, body}, kind, fn_name, params, source),
    do: render_body(clause_head(kind, fn_name, params, [body]), body, source)

  # `if` takes the then-branch for any truthy value (everything but
  # `nil`/`false`), but a `when` guard fires only on a literal `true`.
  # A boolean-proven condition already matches `if`'s truthiness, so its
  # guard is used verbatim. A non-boolean truthy term (a bare variable,
  # `elem/2`, arithmetic, …) is wrapped in `not in [nil, false]`, which is
  # guard-legal and reproduces `if`'s truthiness exactly.
  defp guard_text(cond_ast) do
    text = Sourceror.to_string(cond_ast)
    if boolean_guard?(cond_ast), do: text, else: "#{text} not in [nil, false]"
  end

  @boolean_ops ~w(== != === !== < > <= >= and or not && || ! in)a

  defp boolean_guard?(true), do: true
  defp boolean_guard?(false), do: true
  defp boolean_guard?({:__block__, _, [inner]}), do: boolean_guard?(inner)
  defp boolean_guard?({op, _, _}) when op in @boolean_ops, do: true
  defp boolean_guard?({fun, _, args}) when is_atom(fun) and is_list(args), do: predicate_bif?(fun)
  defp boolean_guard?(_), do: false

  defp predicate_bif?(fun), do: String.starts_with?(Atom.to_string(fun), "is_")

  # Each clause gets its own parameter list: params that appear in neither
  # the guard nor the body are underscored so the lifted form compiles
  # without unused-variable warnings.
  defp clause_head(kind, fn_name, params, used_in) do
    used = collect_var_names(used_in)
    "#{kind} #{fn_name}(#{param_text(underscore_unused(params, used))})"
  end

  defp collect_var_names(asts) do
    asts
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.reduce(MapSet.new(), fn
      {name, _, ctx}, acc when is_atom(name) and is_atom(ctx) -> MapSet.put(acc, name)
      _, acc -> acc
    end)
  end

  defp underscore_unused(params, used), do: Enum.map(params, &underscore_param(&1, used))

  defp underscore_param({name, meta, ctx} = param, used) do
    if MapSet.member?(used, name) or underscored?(name),
      do: param,
      else: {:"_#{name}", meta, ctx}
  end

  defp underscored?(name), do: String.starts_with?(Atom.to_string(name), "_")

  defp render_body(head, body, source) do
    case body_lines(body, source) do
      {:single, text} -> "#{head}, do: #{text}"
      {:multi, text} -> "#{head} do\n#{text}\nend"
    end
  end

  # A single-expression branch renders inline (`, do:`); a multi-statement
  # branch renders as a `do/end` block. The body text is sliced from the
  # source to preserve the user's formatting.
  defp body_lines({:__block__, _, exprs}, source) when length(exprs) > 1,
    do: {:multi, exprs |> Enum.map_join("\n", &render_node(&1, source))}

  defp body_lines(single, source) do
    text = render_node(single, source)
    if String.contains?(text, "\n"), do: {:multi, text}, else: {:single, text}
  end

  defp render_node(node, source) do
    case slice_node(source, node) do
      {:ok, text} -> String.trim(text)
      :error -> Sourceror.to_string(node)
    end
  end

  defp param_text(params), do: Enum.map_join(params, ", ", &Sourceror.to_string/1)

  defp do_body(body_kw) do
    body_kw
    |> Enum.find_value(:skip, fn
      {{:__block__, _, [:do]}, value} -> {:ok, value}
      {:do, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp reduce_ok(list, fun) do
    list
    |> Enum.reduce_while([], fn item, acc ->
      case fun.(item) do
        {:ok, value} -> {:cont, [value | acc]}
        :skip -> {:halt, :skip}
      end
    end)
    |> case do
      :skip -> :skip
      values -> {:ok, Enum.reverse(values)}
    end
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
