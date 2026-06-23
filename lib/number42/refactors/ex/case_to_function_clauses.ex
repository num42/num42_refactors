defmodule Number42.Refactors.Ex.CaseToFunctionClauses do
  @moduledoc """
  Lifts a `def`/`defp` whose entire body is a `case` on one of its bare
  parameters into one pattern-matched clause per `case` branch.

      def handle(msg) do
        case msg do
          {:ok, v} -> log(v)
          {:error, e} -> warn(e)
        end
      end
      ↓
      def handle({:ok, v}), do: log(v)
      def handle({:error, e}), do: warn(e)

  Extra parameters are kept verbatim and repeated on every emitted
  clause; only the scrutinised param slot is replaced by the branch
  pattern:

      def handle(msg, ctx) do
        case msg do
          {:ok, v} -> log(v, ctx)
          {:error, e} -> warn(e, ctx)
        end
      end
      ↓
      def handle({:ok, v}, ctx), do: log(v, ctx)
      def handle({:error, e}, ctx), do: warn(e, ctx)

  ## What lifts

    * The body is **exactly one** expression and that expression is a
      `case`.
    * The `case` scrutinee is a **bare variable** that is one of the
      head's parameters, syntactically unchanged. `case transform(msg)`
      is not eligible — the clause patterns would describe the call
      result, not a param, so they can't move into the head.
    * The def is the **sole clause** at its name/arity.
    * Branch guards (`{:ok, v} when is_pid(v) ->`) carry over to the
      emitted clause's `when`.

  ## What we skip

    * `defmacro`/`defmacrop` — out of scope.
    * A head with a `when`-guard — composing the head guard with each
      branch pattern/guard is risky.
    * A scrutinee that is anything other than a bare param (call,
      literal, field access, `param |> f()`, …).
    * Any prefix before the `case` (an `=`-binding, a log call, …). The
      branch bodies may reference those bindings; splitting drops them.
      The `case` must be the **sole** body expression.
    * A branch pattern (or branch guard) containing a `^pin`. The pinned
      variable refers to a binding outside the branch; once the pattern
      sits in the function head it may no longer be visible. Conservative
      blanket skip.
    * Sibling clauses at the same name/arity. A catch-all `_ ->` becomes
      `def f(_)` and would swallow inputs the siblings should match —
      ordering/exhaustiveness break.
    * A head with any non-bare-variable parameter — we can't tell which
      slot the scrutinee occupies, and pattern params can't carry a
      branch pattern.

  ## Idempotence

  After the split the function has one implementation clause per branch,
  none of which is a `case`-only body. A second pass finds no match.

  ## Binding-preserving lift

  Each emitted clause is its own head, so the lift carries the bindings
  the original single head provided:

    * **Scrutinee reused in a branch body/guard** — the pattern rebinds
      it (`%User{confirmed_at: nil} = user`), so `case user do %User{} ->
      f(user)` lifts to `def g(%User{} = user), do: f(user)` rather than
      leaving `user` unbound. A `_` catch-all whose body still uses the
      scrutinee becomes the scrutinee name (`def g(user)`); a branch
      whose pattern already binds the scrutinee name is left as-is.
    * **Extra param unused by a branch** — that param is `_`-prefixed on
      the clause that doesn't reference it (`def route(_, _id)`), so the
      split never injects unused-variable warnings the single head hid.

  ## Enabled by default

  This refactor runs unattended. A full-suite dogfood run on a real
  codebase is green with the binding-preserving lift above, so the
  conservative opt-in gate was removed.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Lift `def f(p) do case p do ... end end` to pattern-matched clauses"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A function whose entire body is a `case` on one of its parameters is
    clause-dispatch written the long way: the head binds the param, the
    body immediately re-matches it. Lifting each branch into its own
    `def` clause moves the dispatch where the reader expects it — the
    clause list — drops a level of indentation, and removes the `case`
    middle-step. The split is only safe when the `case` is the whole
    body (no prefix bindings to lose) and the function has no sibling
    clauses (no catch-all ordering hazard).
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts),
    do: Sourceror.parse_string(source) |> apply_patches(source)

  @impl Number42.Refactors.Refactor
  def patches(ast, source, _opts), do: build_patches(ast, source)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast, source) do
    sole_keys = sole_clause_keys(ast)

    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&maybe_patch(&1, sole_keys, source))
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  # Names/arities that appear exactly once across the module's top-level
  # defs — the "sole clause" set. Splitting is only safe for these.
  defp sole_clause_keys(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, _} = mod -> module_def_keys(mod)
      _ -> []
    end)
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {key, 1} -> [key]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp module_def_keys(mod) do
    mod
    |> module_body_exprs()
    |> List.wrap()
    |> Enum.flat_map(&def_key/1)
  end

  defp def_key({kind, _, [head | _]}) when def_kind?(kind) do
    case extract_fn_signature(head) do
      {name, args} -> [{kind, name, length(args)}]
      :error -> []
    end
  end

  defp def_key(_), do: []

  defp maybe_patch({kind, _meta, [head, body_kw]} = node, sole_keys, source)
       when def_kind?(kind) and is_list(body_kw) do
    with false <- has_when_guard?(head),
         {fn_name, params} <- extract_fn_signature(head),
         {:ok, param_names} <- all_bare_params(params),
         {:ok, body_ast} <- single_do_body(body_kw),
         {:ok, {scrutinee_name, clauses}} <- case_on_param(body_ast, param_names),
         true <- MapSet.member?(sole_keys, {kind, fn_name, length(params)}),
         false <- Enum.any?(clauses, &clause_uses_pin?/1) do
      [
        Patch.replace(
          node,
          render_clauses(kind, fn_name, params, scrutinee_name, clauses, source)
        )
      ]
    else
      _ -> []
    end
  end

  defp maybe_patch(_, _, _), do: []

  defp has_when_guard?({:when, _, _}), do: true
  defp has_when_guard?(_), do: false

  # Every param is a bare variable → `{:ok, [name, ...]}`, else `:error`.
  defp all_bare_params(params) do
    params
    |> Enum.reduce_while({:ok, []}, fn param, {:ok, acc} ->
      case bare_var(param) do
        {:ok, name} -> {:cont, {:ok, [name | acc]}}
        :skip -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, Enum.reverse(names)}
      :error -> :error
    end
  end

  defp single_do_body(body_kw) do
    case body_kw
         |> Enum.reduce({nil, 0}, fn
           {{:__block__, _, [:do]}, value}, {_, n} -> {value, n + 1}
           {:do, value}, {_, n} -> {value, n + 1}
           _, {v, n} -> {v, n + 1}
         end) do
      {body, 1} -> single_expr_of(body)
      _ -> :error
    end
  end

  defp single_expr_of({:__block__, _, [single]}), do: {:ok, single}
  defp single_expr_of({:__block__, _, _}), do: :error
  defp single_expr_of(other), do: {:ok, other}

  # The body is `case <bare-param> do <clauses> end` where the param is
  # one of the head's params.
  defp case_on_param({:case, _, [scrutinee, [{_do, clauses_kw}]]}, param_names) do
    with {:ok, name} <- bare_var(scrutinee),
         true <- name in param_names,
         clauses when clauses != [] <- arrow_clauses(clauses_kw) do
      {:ok, {name, clauses}}
    else
      _ -> :error
    end
  end

  defp case_on_param(_, _), do: :error

  defp arrow_clauses(clauses_kw) when is_list(clauses_kw) do
    clauses_kw
    |> Enum.flat_map(fn
      {:->, _, [_pattern_list, _body]} = clause -> [clause]
      _ -> []
    end)
  end

  defp arrow_clauses(_), do: []

  defp clause_uses_pin?({:->, _meta, [[pattern_node], _body]}) do
    {pattern, guard} = unwrap_when(pattern_node)
    contains_pin?(pattern) or (guard != nil and contains_pin?(guard))
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

  defp unwrap_when({:when, _meta, [pat, guard]}), do: {pat, guard}
  defp unwrap_when(pat), do: {pat, nil}

  defp render_clauses(kind, fn_name, params, scrutinee_name, clauses, source) do
    Enum.map_join(
      clauses,
      "\n",
      &render_clause(kind, fn_name, params, scrutinee_name, &1, source)
    )
  end

  defp render_clause(kind, fn_name, params, scrutinee_name, clause, source) do
    {:->, _, [[pattern_node], body]} = clause
    {pattern, guard} = unwrap_when(pattern_node)
    scrutinee_text = render_scrutinee_slot(pattern, body, guard, scrutinee_name, source)

    head_slots =
      params
      |> Enum.map_join(", ", fn param ->
        {:ok, name} = bare_var(param)

        cond do
          name == scrutinee_name -> scrutinee_text
          var_used_in_branch?(body, guard, name) -> Atom.to_string(name)
          true -> "_" <> Atom.to_string(name)
        end
      end)

    guard_text =
      case guard do
        nil -> ""
        node -> " when " <> render_guard(node, source)
      end

    head = "#{kind} #{fn_name}(#{head_slots})#{guard_text}"
    render_body(head, body, source)
  end

  # The text for the param slot the `case` scrutinised. When the branch
  # body (or guard) still references the scrutinee variable, the lift
  # must keep that name bound — otherwise `case user do %User{} -> f(user)`
  # becomes `def g(%User{}), do: f(user)` with `user` unbound. We rebind:
  #
  #   * scrutinee unused in the branch       → just the branch pattern
  #   * pattern already binds the same name  → just the branch pattern
  #   * pattern is `_`                       → the scrutinee name (the
  #     catch-all matched anything; `_ = user` would only warn)
  #   * any other pattern                    → `pattern = scrutinee`,
  #     which matches the branch pattern and re-binds the whole arg
  #     (`%User{} = user`, `{:ok, p} = res`, `n = msg`).
  defp render_scrutinee_slot(pattern, body, guard, scrutinee_name, source) do
    pattern_text = render_pattern(pattern, source)

    cond do
      not var_used_in_branch?(body, guard, scrutinee_name) -> pattern_text
      bare_var_named?(pattern, scrutinee_name) -> pattern_text
      underscore_pattern?(pattern) -> Atom.to_string(scrutinee_name)
      true -> "#{pattern_text} = #{scrutinee_name}"
    end
  end

  # A param is referenced by a branch if its name appears in the branch
  # body or guard. The scrutinee slot uses this to decide whether to
  # rebind; the other slots use it to decide whether to `_`-prefix an
  # unused param (each emitted clause is its own head, so a param a
  # branch never touches would otherwise warn).
  defp var_used_in_branch?(body, guard, name),
    do: var_referenced?(body, name) or (guard != nil and var_referenced?(guard, name))

  defp var_referenced?(ast, name) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {^name, _, ctx} when is_atom(ctx) -> true
      _ -> false
    end)
  end

  defp bare_var_named?(pattern, name) do
    case bare_var(pattern) do
      {:ok, ^name} -> true
      _ -> false
    end
  end

  defp underscore_pattern?({:_, _, ctx}) when is_atom(ctx), do: true
  defp underscore_pattern?(_), do: false

  defp render_body(head, body, source) do
    if simple_body?(body) do
      "#{head}, do: #{render_body_text(body, source)}"
    else
      "#{head} do\n  #{render_body_text(body, source)}\nend"
    end
  end

  defp render_pattern(pattern, source),
    do: slice_node(source, pattern) |> text_or_render(pattern)

  defp render_guard(guard, source),
    do: slice_node(source, guard) |> text_or_render(guard)

  defp render_body_text(body, source),
    do: slice_node(source, body) |> text_or_render(body)

  defp text_or_render({:ok, text}, _node), do: String.trim(text)
  defp text_or_render(:error, node), do: Sourceror.to_string(node)

  defp simple_body?({:__block__, _, [single]}), do: simple_body?(single)
  defp simple_body?({:__block__, _, _}), do: false
  defp simple_body?(ast), do: not contains_block_construct?(ast)

  defp contains_block_construct?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {name, _, _}
      when name in [:case, :cond, :if, :unless, :with, :try, :receive, :for, :quote, :fn] ->
        true

      _ ->
        false
    end)
  end
end
