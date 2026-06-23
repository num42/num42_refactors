defmodule Number42.Refactors.Ex.InlineSingleCallerPrivate do
  @moduledoc """
  Inlines a private function that has exactly one call site in the
  module, then deletes it.

      # before
      defp helper(x), do: x * 2 + offset()
      def f(n), do: helper(n) + 1

      # after
      def f(n), do: (n * 2 + offset()) + 1

  The inlined body is wrapped in parentheses when spliced into a larger
  expression so operator precedence is preserved
  (`(n * 2 + offset()) + 1`, not `n * 2 + offset() + 1`).

  ## What we inline

  A `defp` is inlined only when **all** of the following hold:

  - It is a single, guard-free clause.
  - Every parameter is a **bare variable** — no pattern params
    (`%X{a: a}`, `{a, b}`), no defaults (`\\\\`). Pattern params carry
    matching semantics (incl. `MatchError`) that a value substitution
    can't reproduce, so we skip them.
  - The body is a **single expression** that introduces **no new
    bindings**: no `=`, `case`, `cond`, `with`, `for`, `fn`, `receive`,
    `try`. A binding construct could capture or be captured by a
    variable live at the call site; rather than alpha-rename in v1, we
    skip. Single-expression bodies (the `helper(x), do: x * 2 + …`
    shape) substitute cleanly.
  - It is **not recursive** — the body never calls the same
    `{name, arity}`.
  - It has **exactly one use** in the whole module, and that use is a
    single direct call `helper(args)`.

  ## Multiple-evaluation trap

  We have no purity analysis (issue #34 builds it; we don't depend on
  it). If a parameter is used **more than once** in the body, naive
  substitution would duplicate the argument's evaluation. We only allow
  it when the argument at the call site is **trivially safe**: a bare
  variable, a literal (atom / number / string / boolean / nil), or a
  simple field access (`x.y` / `x[:y]`). Any param used more than once
  whose argument is non-trivial → skip. We do **not** attempt a
  `tmp = arg` binding rewrite in v1.

  ## What counts as a "use"

  A module-local scan counts:

  - direct calls `helper(args)` (the inlinable shape),
  - pipe-form calls `arg |> helper(rest)` — the piped value is the
    implicit first argument, so `x |> helper()` is really `helper/1`
    even though the right-hand AST node carries zero explicit args,
  - captures `&helper/arity` (both Sourceror AST forms),
  - any `apply/2,3` that names the helper, even dynamically.

  We have no shared call-graph helper yet (issue #34), so this scan is
  intentionally local and conservative:

  - If the sole use is a **capture** `&helper/1` → skip (a capture
    can't be substituted with an inlined body).
  - If **any** `apply` references the name → skip (we can't tell
    statically how many times it fires).
  - If **any** use is a **pipe-form call** → skip. v1 does not splice an
    inlined body into a pipe stage; counting the pipe caller (rather
    than missing it) also prevents deleting a `defp` that pipe callers
    still reference — the bug fixed in issue #80.
  - So we inline only when the single use is exactly one direct call.

  ## What we skip

  - `def` (public API — inlining + deleting removes the contract).
  - `defmacro` / `defmacrop` (macro hygiene differs).
  - Multi-clause or `when`-guarded `defp` (case/cond synthesis, not a
    substitution).
  - Recursive `defp`.
  - Zero, two, or more call sites.
  - Capture-only use, any `apply` mentioning the name, or any pipe-form
    caller `arg |> helper(...)`.
  - Pattern / default params.
  - Bodies containing a binding construct.
  - A param used >1× with a non-trivial argument.

  When a candidate qualifies, the helper's immediately-preceding
  attached attributes (`@doc`, `@spec`, `@impl`, `@deprecated`,
  `@dialyzer`, `@typedoc`, `@since`) are deleted along with it.

  ## Idempotence

  After inlining, the helper is gone and its single call site holds the
  spliced body. A second pass finds no single-caller private for that
  helper, so the output is stable. To stay deterministic we rewrite at
  most **one** helper per pass (the first eligible one in source
  order); the engine's fixpoint loop picks up the rest on later passes.

  ## Enabled by default

  This refactor runs unattended. Two shapes once made it unsafe; both
  are now handled:

  - **`rescue`-wrapped body** — `fetch_do_body/1` reads only the `:do`
    value, so inlining a `defp f do … rescue/catch/after/else … end`
    silently dropped the recovery clause and the call site started
    raising. `has_try_clause?/1` now skips any helper whose body keyword
    carries a `:rescue`/`:catch`/`:after`/`:else` entry — its semantics
    can't be reproduced by a value substitution.
  - **fixpoint miscount** — the concern that inlining a helper `A` whose
    body calls `B` turns `B`'s single call site into two and then a
    later pass still deletes `B`. It does not occur: the engine re-parses
    between passes and this refactor rewrites at most one helper per pass
    (see *Idempotence*), so `B`'s callers are recounted fresh on the next
    pass — once `A` is inlined `B` reads as two-caller and is left alone.

  With those, a full-suite dogfood run on position-db is green and
  matches the unrefactored baseline, so the conservative opt-in gate was
  removed.
  """

  use Number42.Refactors.Refactor

  @attached_attrs ~w(doc spec impl deprecated dialyzer typedoc since)a

  @impl Number42.Refactors.Refactor
  def description, do: "Inline a single-call-site private function and delete it"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A `defp` called from exactly one place is indirection without a
    payoff: it forces a reader to jump to the definition and back to
    follow a single thread of control. Inlining its body at the one
    call site — paren-wrapped to keep precedence — and deleting the
    helper removes the hop. Conservative by design: single-expression,
    binding-free, bare-var-param, non-recursive helpers only, and only
    when substitution can't duplicate a non-trivial evaluation.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts),
    do: Sourceror.parse_string(source) |> apply_to_parse_result(source)

  defp apply_to_parse_result({:ok, ast}, source),
    do: ast |> first_module_patches() |> patch_or_passthrough(source)

  defp apply_to_parse_result({:error, _}, source), do: source

  # Rewrite at most one helper per pass — the first eligible across all
  # modules in the file — so a multi-defmodule file stays deterministic.
  defp first_module_patches(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value([], fn
      {:defmodule, _, [_name, [{_do, body}]]} ->
        case patches_for_module(body_to_exprs(body)) do
          [] -> nil
          patches -> patches
        end

      _ ->
        nil
    end)
  end

  defp patches_for_module(body_exprs) do
    clauses = body_exprs |> Enum.filter(&def_or_macro_clause?/1)
    multi = multi_clause_keys(clauses)

    body_exprs
    |> Enum.with_index()
    |> Enum.find_value([], fn {expr, idx} ->
      patches_for_candidate(expr, idx, body_exprs, multi)
    end)
  end

  defp patches_for_candidate({:defp, _, [head, body_kw]} = defp_node, idx, body_exprs, multi) do
    with {name, params} <- extract_fn_signature(head),
         arity = length(params),
         false <- MapSet.member?(multi, {name, arity}),
         false <- guarded?(head),
         {:ok, param_names} <- bare_param_names(params),
         {:ok, body} <- single_inlinable_body(body_kw),
         false <- recursive?(body, name, arity),
         [call] <- uses(body_exprs, name, arity),
         {:ok, replacement} <- substitute(body, param_names, call) do
      [call_patch(call, replacement) | delete_patches(defp_node, idx, body_exprs)]
    else
      _ -> nil
    end
  end

  defp patches_for_candidate(_, _idx, _body_exprs, _multi), do: nil

  # --- eligibility predicates ---

  defp def_or_macro_clause?({kind, _, [_head, _body]}) when def_or_macro_kind?(kind), do: true
  defp def_or_macro_clause?(_), do: false

  defp multi_clause_keys(clauses) do
    clauses
    |> Enum.frequencies_by(&clause_key/1)
    |> Enum.filter(fn {_k, count} -> count > 1 end)
    |> Enum.map(fn {k, _} -> k end)
    |> MapSet.new()
  end

  defp clause_key({_kind, _, [head | _]}) do
    case extract_fn_signature(strip_when(head)) do
      {name, args} -> {name, length(args)}
      :error -> :skip
    end
  end

  defp guarded?({:when, _, _}), do: true
  defp guarded?(_), do: false

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

  defp single_inlinable_body(body_kw) do
    with false <- has_try_clause?(body_kw),
         {:ok, body} <- fetch_do_body(body_kw),
         {:ok, single} <- single_expression(body),
         false <- contains_binding_construct?(single) do
      {:ok, single}
    else
      _ -> :skip
    end
  end

  # A def-form `try`: `defp f do body rescue/catch/after/else ... end`. The
  # body keyword carries a `:rescue`/`:catch`/`:after`/`:else` entry beside
  # the `:do`. Splicing only the `:do` value (what `fetch_do_body/1` returns)
  # would silently drop the recovery/cleanup clause — a `rescue _ -> nil`
  # helper would start raising at the call site. Inlining can't reproduce
  # those semantics with a value substitution, so skip the whole helper.
  @try_clause_keys ~w(rescue catch after else)a
  defp has_try_clause?(body_kw) when is_list(body_kw) do
    Enum.any?(body_kw, fn
      {{:__block__, _, [key]}, _value} -> key in @try_clause_keys
      {key, _value} when is_atom(key) -> key in @try_clause_keys
      _ -> false
    end)
  end

  defp has_try_clause?(_), do: false

  defp fetch_do_body(body_kw) when is_list(body_kw) do
    body_kw
    |> Enum.find_value(:error, fn
      {{:__block__, _, [:do]}, value} -> {:ok, value}
      {:do, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp fetch_do_body(_), do: :error

  defp single_expression({:__block__, _, [single]}), do: {:ok, single}
  defp single_expression({:__block__, _, _}), do: :skip
  defp single_expression(other), do: {:ok, other}

  defp contains_binding_construct?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {name, _, _} when name in [:=, :case, :cond, :with, :for, :fn, :receive, :try] -> true
      _ -> false
    end)
  end

  defp recursive?(body, name, arity) do
    body
    |> Macro.prewalker()
    |> Enum.any?(fn
      {^name, _, args} when is_list(args) -> length(args) == arity
      _ -> false
    end)
  end

  # --- use counting (module-local call graph) ---

  # Returns the list of direct-call nodes for `{name, arity}`, but only
  # when the helper's *sole* use is exactly that one direct call. Any
  # capture, apply, pipe-form call, or extra direct call collapses the
  # result to `[]`.
  defp uses(body_exprs, name, arity) do
    {direct_calls, capture?, apply?, pipe?} =
      body_exprs
      |> Enum.reject(&(own_definition?(&1, name, arity) or module_attribute?(&1)))
      |> Enum.reduce({[], false, false, false}, fn expr, acc ->
        scan_uses(expr, name, arity, acc)
      end)

    cond do
      capture? -> []
      apply? -> []
      pipe? -> []
      true -> direct_calls
    end
  end

  defp own_definition?({kind, _, [head | _]}, name, arity) when def_or_macro_kind?(kind) do
    case extract_fn_signature(strip_when(head)) do
      {^name, args} -> length(args) == arity
      _ -> false
    end
  end

  defp own_definition?(_, _, _), do: false

  # A `@spec helper(...) :: ...` mentions the name as a type signature,
  # not a runtime call. Module attributes are never call sites.
  defp module_attribute?({:@, _, _}), do: true
  defp module_attribute?(_), do: false

  defp scan_uses(ast, name, arity, acc) do
    {_, result} =
      Macro.prewalk(ast, acc, fn node, {calls, capture?, apply?, pipe?} = inner ->
        cond do
          capture_of?(node, name, arity) -> {node, {calls, true, apply?, pipe?}}
          apply_of?(node, name) -> {node, {calls, capture?, true, pipe?}}
          pipe_call_of?(node, name, arity) -> {node, {calls, capture?, apply?, true}}
          direct_call_of?(node, name, arity) -> {node, {[node | calls], capture?, apply?, pipe?}}
          true -> {node, inner}
        end
      end)

    result
  end

  defp direct_call_of?({call_name, _, args}, name, arity)
       when is_atom(call_name) and is_list(args),
       do: call_name == name and length(args) == arity

  defp direct_call_of?(_, _name, _arity), do: false

  # A pipe `lhs |> f(args)` calls `f/(length(args) + 1)` — the piped value
  # is the implicit first argument, so the RHS node carries one fewer
  # explicit arg than the real arity. Counting the bare RHS node would
  # miss it (its arity is `real_arity - 1`); we match the pipe shape
  # directly. Substituting an inlined body into a pipe stage is not
  # something v1 attempts, so any pipe-form use disqualifies the helper.
  defp pipe_call_of?({:|>, _, [_lhs, {call_name, _, args}]}, name, arity)
       when is_atom(call_name) and is_list(args),
       do: call_name == name and length(args) + 1 == arity

  defp pipe_call_of?(_, _name, _arity), do: false

  defp capture_of?({:&, _, [{:/, _, [{cap_name, _, ctx}, cap_arity]}]}, name, arity)
       when is_atom(cap_name) and is_atom(ctx) and is_integer(cap_arity),
       do: cap_name == name and cap_arity == arity

  defp capture_of?(
         {:&, _, [{:/, _, [{cap_name, _, ctx}, {:__block__, _, [cap_arity]}]}]},
         name,
         arity
       )
       when is_atom(cap_name) and is_atom(ctx) and is_integer(cap_arity),
       do: cap_name == name and cap_arity == arity

  defp capture_of?(_, _name, _arity), do: false

  # Any apply that mentions the helper name (as a literal atom arg) is
  # treated as a dynamic use we can't count → skip conservatively.
  defp apply_of?({:apply, _, args}, name) when is_list(args) do
    args |> Enum.any?(&names_atom?(&1, name))
  end

  defp apply_of?(_, _name), do: false

  defp names_atom?({:__block__, _, [atom]}, name) when is_atom(atom), do: atom == name
  defp names_atom?(atom, name) when is_atom(atom), do: atom == name
  defp names_atom?(_, _), do: false

  # --- substitution ---

  defp substitute(body, param_names, {_call_name, _, args}) do
    with true <- length(param_names) == length(args),
         binding = Enum.zip(param_names, args),
         true <- multi_eval_safe?(body, binding) do
      {:ok, substitute_vars(body, Map.new(binding))}
    else
      _ -> :skip
    end
  end

  # A param used >1× in the body is safe only when its argument is
  # trivially safe to re-evaluate (no purity layer yet).
  defp multi_eval_safe?(body, binding) do
    counts = param_use_counts(body, Enum.map(binding, &elem(&1, 0)))

    Enum.all?(binding, fn {param, arg} ->
      Map.get(counts, param, 0) <= 1 or trivially_safe?(arg)
    end)
  end

  defp param_use_counts(body, params) do
    param_set = MapSet.new(params)

    body
    |> Macro.prewalker()
    |> Enum.reduce(%{}, fn
      {n, _, ctx}, acc when is_atom(n) and is_atom(ctx) ->
        if MapSet.member?(param_set, n), do: Map.update(acc, n, 1, &(&1 + 1)), else: acc

      _, acc ->
        acc
    end)
  end

  defp trivially_safe?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp trivially_safe?({:__block__, _, [literal]}), do: literal_value?(literal)

  defp trivially_safe?(literal) when is_atom(literal) or is_number(literal) or is_binary(literal),
    do: true

  # `x.y` field access
  defp trivially_safe?({{:., _, [{base, _, bctx}, field]}, _, []})
       when is_atom(base) and is_atom(bctx) and is_atom(field),
       do: true

  # `x[:y]` access
  defp trivially_safe?({{:., _, [Access, :get]}, _, [{base, _, bctx}, _key]})
       when is_atom(base) and is_atom(bctx),
       do: true

  defp trivially_safe?(_), do: false

  defp literal_value?(v) when is_atom(v) or is_number(v) or is_binary(v), do: true
  defp literal_value?(_), do: false

  defp substitute_vars(body, subst) do
    Macro.prewalk(body, fn
      {name, _meta, ctx} = node when is_atom(name) and is_atom(ctx) ->
        Map.get(subst, name, node)

      node ->
        node
    end)
  end

  # --- patching ---

  defp call_patch(call, replacement_ast) do
    text = "(" <> Sourceror.to_string(replacement_ast) <> ")"
    %{change: text, range: Sourceror.get_range(call)}
  end

  # Delete the defp node and any immediately-preceding attached
  # attributes (the contiguous run of @doc/@spec/... just above it).
  defp delete_patches(defp_node, idx, body_exprs) do
    first_node = leading_attr_start(body_exprs, idx, defp_node)

    with %{start: start_pos} <- Sourceror.get_range(first_node),
         %{end: end_pos} <- Sourceror.get_range(defp_node) do
      [%{change: "", range: %{end: end_pos, start: start_pos}}]
    else
      _ -> []
    end
  end

  defp leading_attr_start(body_exprs, idx, defp_node) do
    body_exprs
    |> Enum.take(idx)
    |> Enum.reverse()
    |> Enum.take_while(&attached_attr?/1)
    |> List.last()
    |> case do
      nil -> defp_node
      attr -> attr
    end
  end

  defp attached_attr?({:@, _, [{attr, _, _}]}) when is_atom(attr), do: attr in @attached_attrs
  defp attached_attr?(_), do: false

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other
end
