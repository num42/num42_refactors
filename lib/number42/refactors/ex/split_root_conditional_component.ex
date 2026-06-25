defmodule Number42.Refactors.Ex.SplitRootConditionalComponent do
  @moduledoc """
  Splits a function-component whose body is a root-level `if`/`else` over two
  `~H` sigils into two pattern-matched/guarded clauses.

      def button(assigns) do
        if assigns.rest[:href] do
          ~H"<.link {@rest}>x</.link>"
        else
          ~H"<button {@rest}>x</button>"
        end
      end
      ↓
      def button(assigns) when is_map_key(assigns.rest, :href) do
        ~H"<.link {@rest}>x</.link>"
      end

      def button(assigns) do
        ~H"<button {@rest}>x</button>"
      end

  A component whose entire body chooses between two different root markups by a
  condition is two components fused into one; the choice belongs in the clause
  head as a guard, matching the style rule *"pattern matching over conditionals"*.

  ## Default-OFF (opt-in only)

  Opinionated and structural — it rewrites the clause list of a component. It
  follows the *derive-or-decline / sound-or-inert* line: when it cannot prove the
  split faithful, it **declines** rather than guess. Enable per-module:

      {Number42.Refactors.Ex.SplitRootConditionalComponent, enabled: true}

  ## What splits

  - A single-clause `def name(assigns)` (arity 1, the param binds `assigns`).
  - Body is exactly: an optional `assigns = <setup>` followed by one
    `if cond do ~H".." else ~H".." end`.
  - Both branches are `~H`/`~L` sigils.
  - `cond` is guard-safe over the param (after normalising `m[:k]` access to
    `is_map_key(m, :k)`), referencing only the **input** `assigns` — not a value
    the setup block derives.

  Both clauses keep `assigns` as the parameter name (the sigil reads it) and
  reproduce the `assigns = setup` line verbatim. The do-branch becomes the
  guarded clause; the else-branch becomes the catch-all.

  ## What we decline

  - A branch that is not a sigil, or a nested `if`/`case`/`cond` inside a branch.
  - A guard-unsafe condition (an arbitrary function call like `String.length/1`,
    or a non-guard operator) — a `when` cannot call arbitrary functions.
  - A condition over a **setup-derived** assign (the head cannot see values the
    body computes; cf. #371).
  - An `else`-less `if` (single branch) — that is a plain `:if=` hoist, not this.
  - A `def` whose single param does not bind `assigns`, a `when`-guarded head, a
    multi-arity head, or `defp`/`defmacro`.

  ## Idempotence

  After the split neither clause has a single-`if`-over-sigils body, so a second
  pass finds no match.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @guard_ops ~w(== != === !== < > <= >= and or not && || ! + - * / in)a
  @guard_bifs ~w(is_atom is_binary is_bitstring is_boolean is_float is_function
                 is_integer is_list is_map is_map_key is_nil is_number is_pid
                 is_port is_reference is_tuple abs bit_size byte_size ceil
                 div elem floor hd length map_size node rem round self
                 tl trunc tuple_size)a
  @guard_callable MapSet.new(@guard_ops ++ @guard_bifs)

  @impl Number42.Refactors.Refactor
  def description,
    do: "Split a component's root-level `if`-over-two-sigils into two pattern-matched clauses"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A function-component whose body is `if cond, do: ~H A, else: ~H B` is a
    clause-dispatch in disguise — two components fused by a boolean. When the
    condition lifts cleanly into a guard over the input assigns, the
    pattern-matched form makes the branch visible in the clause list and removes
    the boolean middle-step. Default-OFF and conservative: any branch that is
    not a sigil, a non-guard-safe condition, a body-derived condition, or a
    nested control-flow makes it decline.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      Sourceror.parse_string(source) |> apply_patches(source)
    else
      source
    end
  end

  defp apply_patches({:ok, ast}, source),
    do: ast |> Macro.prewalker() |> Enum.flat_map(&maybe_patch(&1, source)) |> patch(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch([], source), do: source
  defp patch(patches, source), do: Sourceror.patch_string(source, patches)

  defp maybe_patch({:def, _meta, [head, body_kw]} = node, source)
       when is_list(body_kw) do
    with false <- when_guarded?(head),
         {:ok, fn_name} <- component_head(head),
         {:ok, body} <- single_do_body(body_kw),
         {setup, if_node} <- split_setup_and_if(body),
         {:ok, {cond_ast, do_body, else_body}} <- if_over_two_sigils(if_node),
         :ok <- cond_uses_only_input?(cond_ast, setup),
         {:ok, guard_ast} <- guard_for(cond_ast) do
      [Patch.replace(node, render(fn_name, setup, guard_ast, do_body, else_body, source))]
    else
      _ -> []
    end
  end

  defp maybe_patch(_, _), do: []

  defp when_guarded?({:when, _, _}), do: true
  defp when_guarded?(_), do: false

  # arity-1 head whose param binds `assigns` (bare or `%{..} = assigns`).
  defp component_head({fn_name, _, [arg]}) when is_atom(fn_name) do
    if binds_assigns?(arg), do: {:ok, fn_name}, else: :error
  end

  defp component_head(_), do: :error

  defp binds_assigns?({:assigns, _, ctx}) when is_atom(ctx), do: true
  defp binds_assigns?({:=, _, [_lhs, {:assigns, _, ctx}]}) when is_atom(ctx), do: true
  defp binds_assigns?(_), do: false

  defp single_do_body(body_kw) do
    body_kw
    |> Enum.find_value(:error, fn
      {{:__block__, _, [:do]}, v} -> {:ok, v}
      {:do, v} -> {:ok, v}
      _ -> nil
    end)
  end

  # Body is either the bare `if`, or `assigns = setup` then the `if`. Anything
  # else (extra statements, no `if`) → no `if_node` and the if-shape gate fails.
  defp split_setup_and_if({:__block__, _, [{:=, _, [{:assigns, _, ctx}, _]} = setup, if_node]})
       when is_atom(ctx),
       do: {setup, if_node}

  defp split_setup_and_if({:__block__, _, _} = block), do: {nil, block}
  defp split_setup_and_if(if_node), do: {nil, if_node}

  defp if_over_two_sigils({:if, _, [cond_ast, body_kw]}) when is_list(body_kw) do
    {do_body, else_body} = if_branches(body_kw)

    cond do
      is_nil(do_body) or is_nil(else_body) -> :error
      not sigil_branch?(do_body) -> :error
      not sigil_branch?(else_body) -> :error
      true -> {:ok, {cond_ast, do_body, else_body}}
    end
  end

  defp if_over_two_sigils(_), do: :error

  defp if_branches(body_kw) do
    Enum.reduce(body_kw, {nil, nil}, fn
      {{:__block__, _, [:do]}, v}, {_, e} -> {v, e}
      {:do, v}, {_, e} -> {v, e}
      {{:__block__, _, [:else]}, v}, {d, _} -> {d, v}
      {:else, v}, {d, _} -> {d, v}
      _, acc -> acc
    end)
  end

  # A branch is exactly a sigil — no surrounding control flow. A nested
  # `if`/`case`/`cond`/etc. anywhere in the branch disqualifies the split.
  defp sigil_branch?(node) do
    sigil?(node) and not contains_control_flow?(node)
  end

  defp sigil?({sigil, _, _}) when is_atom(sigil), do: match?("sigil_" <> _, Atom.to_string(sigil))
  defp sigil?({:__block__, _, [inner]}), do: sigil?(inner)
  defp sigil?(_), do: false

  defp contains_control_flow?(node) do
    node
    |> Macro.prewalker()
    |> Enum.any?(fn
      {op, _, _} when op in [:if, :unless, :case, :cond, :with, :try, :receive, :for] -> true
      _ -> false
    end)
  end

  # The condition may read only the input `assigns`, never an assign the setup
  # block derives — the clause head runs before the body, so it cannot see a
  # body-computed value (cf. #371).
  defp cond_uses_only_input?(_cond_ast, nil), do: :ok

  defp cond_uses_only_input?(cond_ast, setup) do
    derived = derived_keys(setup)
    used = accessed_keys(cond_ast)

    if MapSet.disjoint?(derived, used), do: :ok, else: :error
  end

  # Keys the setup assigns onto `assigns` via `assign(assigns, :k, ..)` /
  # `assign_new(assigns, :k, ..)`. Conservative: any other setup shape returns
  # the empty set (so the disjointness check can't help) — but then the cond
  # would have to reference an unknown key, which is fine. We only block when we
  # can see a derived key the cond reads.
  defp derived_keys(setup) do
    setup
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {assignf, _, [_target, key, _val]} when assignf in [:assign, :assign_new] ->
        List.wrap(key_atom(key))

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp accessed_keys(cond_ast) do
    cond_ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      # assigns.key
      {{:., _, [{:assigns, _, ctx}, key]}, _, _} when is_atom(ctx) and is_atom(key) -> [key]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp key_atom(key) when is_atom(key), do: key
  defp key_atom({:__block__, _, [key]}) when is_atom(key), do: key
  defp key_atom(_), do: nil

  # Translate the condition into a guard-safe AST, normalising `m[:k]` access to
  # `is_map_key(m, :k)`. Declines (`:error`) when any node is not guard-safe.
  defp guard_for(cond_ast) do
    normalised = normalise_access(cond_ast)
    if guard_safe?(normalised), do: {:ok, normalised}, else: :error
  end

  # `m[:k]` is `Access.get(m, :k)` (not guard-safe) → `is_map_key(m, :k)`.
  defp normalise_access(ast) do
    Macro.prewalk(ast, fn
      {{:., _, [Access, :get]}, _, [container, key]} ->
        {:is_map_key, [], [container, key]}

      {{:., _, [{:__aliases__, _, [:Access]}, :get]}, _, [container, key]} ->
        {:is_map_key, [], [container, key]}

      other ->
        other
    end)
  end

  defp guard_safe?(ast) do
    ast |> Macro.prewalker() |> Enum.all?(&guard_node_safe?/1)
  end

  defp guard_node_safe?(lit)
       when is_atom(lit) or is_integer(lit) or is_float(lit) or is_binary(lit),
       do: true

  defp guard_node_safe?({:__block__, _, _}), do: true
  defp guard_node_safe?(list) when is_list(list), do: true
  defp guard_node_safe?({_a, _b}), do: true
  # `assigns` (or any var) — the head binds it, so a var reference is fine.
  defp guard_node_safe?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  # field access `assigns.foo` — the dot-call onto a var.
  defp guard_node_safe?({:., _, [_, field]}) when is_atom(field), do: true
  defp guard_node_safe?({{:., _, [_, field]}, _, []}) when is_atom(field), do: true
  defp guard_node_safe?({fun, _, args}) when is_atom(fun) and is_list(args), do: guard_call?(fun)
  defp guard_node_safe?(_), do: false

  defp guard_call?(fun), do: MapSet.member?(@guard_callable, fun)

  defp render(fn_name, setup, guard_ast, do_body, else_body, source) do
    do_clause =
      clause("def #{fn_name}(assigns) when #{guard_text(guard_ast)}", setup, do_body, source)

    else_clause = clause("def #{fn_name}(assigns)", setup, else_body, source)

    do_clause <> "\n\n" <> else_clause
  end

  # `cond` takes a branch for any truthy value; a `when` guard fires only on
  # literal `true`. A boolean-proven guard is used verbatim; anything else is
  # wrapped `not in [nil, false]` to reproduce truthiness exactly.
  defp guard_text(guard_ast) do
    text = Sourceror.to_string(guard_ast)
    if boolean_guard?(guard_ast), do: text, else: "#{text} not in [nil, false]"
  end

  @boolean_ops ~w(== != === !== < > <= >= and or not && || ! in)a
  defp boolean_guard?({:__block__, _, [inner]}), do: boolean_guard?(inner)
  defp boolean_guard?({op, _, _}) when op in @boolean_ops, do: true
  defp boolean_guard?({fun, _, _}) when is_atom(fun), do: predicate_bif?(fun)
  defp boolean_guard?(_), do: false

  defp predicate_bif?(fun), do: String.starts_with?(Atom.to_string(fun), "is_")

  defp clause(head, setup, body, source) do
    setup_text = if setup, do: render_node(setup, source) <> "\n\n", else: ""
    "#{head} do\n#{setup_text}#{render_node(body, source)}\nend"
  end

  defp render_node(node, source) do
    case slice_node(source, node) do
      {:ok, text} -> String.trim(text)
      :error -> Sourceror.to_string(node)
    end
  end
end
