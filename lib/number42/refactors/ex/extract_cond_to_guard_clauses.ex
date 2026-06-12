defmodule Number42.Refactors.Ex.ExtractCondToGuardClauses do
  @moduledoc """
  Lifts a `def`/`defp` whose entire body is a `cond` with
  guard-expressible branches into guard-driven function clauses.

      def classify(n) do
        cond do
          n < 0 -> :neg
          n == 0 -> :zero
          true -> :pos
        end
      end
      ↓
      def classify(n) when n < 0, do: :neg
      def classify(n) when n == 0, do: :zero
      def classify(_n), do: :pos

  The N-branch sibling of `IfLiftToClauses`: where that lifts a two-way
  `if`/`else`, this lifts an N-way `cond`. Each non-final branch's
  condition becomes a `when` guard on a clause; the final `true ->`
  branch becomes the bare catch-all clause. Branch order is preserved,
  so dispatch semantics are identical to the `cond`'s top-to-bottom scan.

  Each lifted clause gets its own parameter list: a parameter used in
  neither the clause's guard nor its body is underscored (`_min`), so
  the result compiles without unused-variable warnings.

  ## What lifts

  A `cond` is liftable only when **every** non-final branch condition is
  a valid guard expression over the function's parameters:

    * comparison/equality operators (`<`, `>`, `==`, `!=`, …),
    * boolean combinators (`and`/`or`/`not`/`&&`/`||`/`!`),
    * arithmetic and bitwise operators allowed in guards,
    * the guard-allowed BIFs (`is_*`, `length`, `map_size`, `hd`, `elem`,
      `rem`, …),
    * leaves that are literals or references to the function's params.

  The final branch must be a literal `true ->` catch-all.

  ## What we skip

    * A condition calling a non-guard function (`valid?(n)`,
      `String.length(s) > 3`) — not guard-safe.
    * A condition referencing anything other than a function parameter
      (a local binding, a module attribute) — out of guard scope.
    * A `cond` without a literal `true ->` final branch — the lifted
      clause list would be non-total and could raise `FunctionClauseError`
      where the `cond` raised `CondClauseError`; conservative skip.
    * A `def`/`defp` head with any non-bare parameter or an existing
      `when`-guard — merging guards is risky (matches `IfLiftToClauses`).
    * `defmacro`/`defmacrop`.
    * A body that is anything other than exactly one `cond`.

  ## Idempotence

  After lifting, the function is a list of guard clauses, none of which
  has a single-`cond` body, so a second pass finds no match.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Lift `def f(p) do cond do ... end end` to guard-driven clauses"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A function whose whole body is a `cond` over its parameters is a
    clause dispatch written as a branch. When every condition is a valid
    guard, the guard-clause form moves the decision into the clause heads,
    removes the `cond` nesting level, and lets the compiler check
    exhaustiveness — without changing the top-to-bottom dispatch order.
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
         {:ok, branches} <- cond_branches(body),
         {:ok, clauses} <- liftable_clauses(branches, MapSet.new(param_names)) do
      [Patch.replace(node, render_clauses(kind, fn_name, params, clauses, source))]
    else
      _ -> []
    end
  end

  defp maybe_patch(_, _), do: []

  defp has_when_guard?({:when, _, _}), do: true
  defp has_when_guard?(_), do: false

  defp bare_param_names(params) do
    params
    |> reduce_ok(&bare_var/1)
  end

  # The body must be exactly one `cond do ... end`.
  defp cond_branches(body) do
    case body_to_exprs(body) do
      [{:cond, _, [[{{:__block__, _, [:do]}, clauses}]]}] -> clause_list(clauses)
      [{:cond, _, [[{:do, clauses}]]}] -> clause_list(clauses)
      _ -> :skip
    end
  end

  defp clause_list(clauses) when is_list(clauses), do: {:ok, clauses}
  defp clause_list(_), do: :skip

  # Split into {guard-clauses, catch-all}. Every non-final branch must be
  # guard-safe over params; the final branch must be literal `true ->`.
  defp liftable_clauses(branches, param_set) do
    {init, last} = Enum.split(branches, -1)

    with [{:->, _, [[true_cond], catch_body]}] <- last,
         true <- literal_true?(true_cond),
         {:ok, guard_clauses} <- guard_clauses(init, param_set) do
      {:ok, guard_clauses ++ [{:catch_all, catch_body}]}
    else
      _ -> :skip
    end
  end

  defp guard_clauses(branches, param_set) do
    branches
    |> reduce_ok(fn
      {:->, _, [[cond_ast], body]} -> guard_clause(cond_ast, body, param_set)
      _ -> :skip
    end)
  end

  defp guard_clause(cond_ast, body, param_set) do
    if guard_safe?(cond_ast, param_set), do: {:ok, {:guard, cond_ast, body}}, else: :skip
  end

  defp literal_true?(true), do: true
  defp literal_true?({:__block__, _, [true]}), do: true
  defp literal_true?(_), do: false

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
    render_body("#{head} when #{Sourceror.to_string(cond_ast)}", body, source)
  end

  defp render_clause({:catch_all, body}, kind, fn_name, params, source),
    do: render_body(clause_head(kind, fn_name, params, [body]), body, source)

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
