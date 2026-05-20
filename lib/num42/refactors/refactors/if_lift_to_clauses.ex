defmodule Num42.Refactors.Refactors.IfLiftToClauses do
  @moduledoc """
  Lifts a `def`/`defp` whose body is a single `if`/`else` into two
  pattern-matched clauses, when the condition is liftable.

      def f(x) do
        if is_atom(x) do
          :atom
        else
          :other
        end
      end
      ↓
      def f(x) when is_atom(x), do: :atom
      def f(_), do: :other

      def f(socket) do
        if socket.assigns.option == :new do :a else :b end
      end
      ↓
      def f(%{assigns: %{option: :new}} = socket), do: :a
      def f(_), do: :b

  ## What lifts

  Atomic sub-conditions, combined freely via `and`/`or`/`&&`/`||`/`not`/`!`:

    * `is_*(param)` / `length(param) > N` / `map_size(...) == 0` — BIF guard.
    * `param == literal` / `literal == param` — head pattern.
    * `param.f.g.h` (truthy) — nested map pattern + guard on the bound leaf.
    * `param.f == literal` — nested map pattern with literal at the leaf.
    * `param[:key]` — treated identically to `param.key`.
    * `lhs == rhs` where one side is a field chain and the other is a bare
      param (or another field chain) — bind the LHS leaf, pin the RHS leaf.
    * `param in [literal, literal, ...]` — guard.

  Multiple sub-conditions over the same param collapse into one nested
  map pattern (`%{f: f, g: g} = p`); the truthy/literal/`==` guards
  combine in a single `when` clause.

  ## What we skip

    * `def`/`defp` head with any non-bare-variable parameter (skip — we
      can't safely merge a new pattern into an existing one in v1).
    * `def` head with a `when`-guard (skip — guard composition is risky).
    * `defmacro`/`defmacrop`.
    * Body with anything other than exactly one `if` expression.
    * Bare-param-truthy (`if x do ...`) — would need a three-clause
      expansion (`def f(false); def f(nil); def f(_x)`) which is uglier
      than the source.
    * Disjunction (`or`, `||`) — a single `def` clause can't express
      "match either of these patterns"; two true-clauses would change
      the relative order against pre-existing clauses elsewhere.
    * Conditions referencing values outside the param list, or that use
      function calls other than the guard-allowed BIFs.
    * if-let (`if x = expr do …`) — different refactor.

  ## Multi-clause functions

  When the target `def`/`defp` is one clause among several at the same
  name/arity, we replace ONLY that specific clause (at its exact
  position) with the two new clauses. Sibling clauses are not touched.
  Their relative order is preserved, so dispatch semantics for inputs
  the original bare-clause did not match remain identical. (For inputs
  the original bare-clause WOULD have matched, the lift narrows the
  do-branch to a more specific pattern; the new catch-all takes over
  the fall-through role the original bare-clause played.)

  ## Catch-all

  The else-branch becomes a second clause with all params replaced by
  `_` (or `_name`-prefixed when the param appears in the else-body).
  A single-branch `if` (no `else`) lifts with the catch-all returning
  `nil` — the same value the original `if` produced when falsy.

  ## Idempotence

  After lifting, the function has two clauses, neither of which is a
  single-`if` body. A second pass finds no match.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Num42.Refactors.Refactor
  def description, do: "Lift `def f(p) do if ... else ... end end` to pattern-matched clauses"

  @impl Num42.Refactors.Refactor
  def priority, do: 60

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    A function whose entire body is `if cond, do: X, else: Y` is a
    clause-dispatch in disguise. When the condition lifts cleanly into
    a head pattern (literal equality, struct/map field, BIF guard), the
    pattern-matched form is shorter, removes the boolean middle-step,
    and makes the decision visible at the call-site/clause-list rather
    than buried inside a body.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp build_patches(ast, source),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch(&1, source))

  defp maybe_patch({kind, _meta, [head, body_kw]} = node, source)
       when kind in [:def, :defp] and is_list(body_kw) do
    with false <- has_when_guard?(head),
         {:ok, {fn_name, params}} <- extract_params(head),
         {:ok, body_ast} <- single_do_body(body_kw),
         {:ok, {cond_ast, do_body, else_body, single_branch?}} <- if_shape(body_ast),
         {:ok, atomics} <- atomize(cond_ast),
         bare_param_names <- bare_param_names(params),
         :ok <- all_atomics_use_known_params(atomics, bare_param_names),
         {:ok, plan} <-
           build_plan(atomics, params, cond_ast, do_body, else_body, single_branch?, source) do
      [Patch.replace(node, render_clauses(kind, fn_name, params, plan, source))]
    else
      _ -> []
    end
  end

  defp maybe_patch(_, _), do: []

  # Returns {:ok, {fn_name, [{name_or_nil, ast}, ...]}}. `name_or_nil` is
  # the bare-variable name when the param IS a bare variable; nil when
  # the param is a pattern, literal, or `_name`. Underscore-prefixed
  # names (`_params`) are treated as anonymous (name_or_nil = nil) so
  # the condition can't reference them — they're documentation slots,
  # not bindings.
  defp extract_params({fn_name, _, args}) when is_atom(fn_name) and is_list(args) do
    typed =
      args
      |> Enum.map(fn arg ->
        case bare_var(arg) do
          {:ok, name} -> {name, arg}
          :skip -> {nil, arg}
        end
      end)

    {:ok, {fn_name, typed}}
  end

  defp extract_params(_), do: :error

  defp bare_param_names(params) do
    for {name, _ast} <- params, name != nil, do: name
  end

  defp has_when_guard?({:when, _, _}), do: true
  defp has_when_guard?(_), do: false

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

  # Pulls the (cond, do-body, else-body, single_branch?) out of an `if`
  # node. Sourceror represents the body keywords as either
  # `{:__block__, _, [:do]}` or plain `:do`.
  defp if_shape({:if, _, [cond_ast, body_kw]}) when is_list(body_kw) do
    {do_body, else_body} =
      body_kw
      |> Enum.reduce({nil, nil}, fn
        {{:__block__, _, [:do]}, v}, {_, e} -> {v, e}
        {:do, v}, {_, e} -> {v, e}
        {{:__block__, _, [:else]}, v}, {d, _} -> {d, v}
        {:else, v}, {d, _} -> {d, v}
        _, acc -> acc
      end)

    cond do
      do_body && else_body -> {:ok, {cond_ast, do_body, else_body, false}}
      do_body -> {:ok, {cond_ast, do_body, nil_literal(), true}}
      true -> :error
    end
  end

  defp if_shape(_), do: :error

  defp nil_literal, do: {:__block__, [], [nil]}

  # -------- Atomic decomposition --------

  # Decompose a condition into a list of atoms combined by AND, with an
  # optional :not flag per atom. We support: bare AND chains (`a and b
  # and c`, or `a && b`), with `not`/`!` allowed at the leaf level. Any
  # `or`/`||` makes the whole condition non-liftable in v1.
  #
  # Each atom is `{kind, payload, negated?}`:
  #   - {:bif_call, {name, [param_ast], op_or_nil, lit_or_nil}, neg?}
  #   - {:field_truthy, {root_name, [field_atoms]}, neg?}
  #   - {:field_eq_lit, {root_name, [field_atoms], lit_ast}, neg?}
  #   - {:param_eq_lit, {param_name, lit_ast}, neg?}
  #   - {:param_in_list, {param_name, [lit_asts]}, neg?}
  #   - {:is_guard, {pred_name, param_name, extra?}, neg?}
  #   - {:eq_pin, {bind_side, pin_side}, neg?}
  #         where each side is {:param, name} | {:field, root, [atoms]}
  defp atomize(cond_ast), do: split_conjunction(cond_ast) |> handle_split_conjunction()

  defp reduce_atom({negated?, leaf}, {:ok, acc}),
    do: classify_atom(leaf, negated?) |> handle_classify_atom(acc)

  # Flatten an AST into a list of `{negated?, leaf}` pairs combined by
  # AND. Returns `:error` if the AST contains any OR-like combinator.
  defp split_conjunction({:and, _, [l, r]}),
    do: combine_conj(split_conjunction(l), split_conjunction(r))

  defp split_conjunction({:&&, _, [l, r]}),
    do: combine_conj(split_conjunction(l), split_conjunction(r))

  defp split_conjunction({:or, _, _}), do: :error
  defp split_conjunction({:||, _, _}), do: :error
  defp split_conjunction({:not, _, [inner]}), do: negate(split_conjunction(inner))
  defp split_conjunction({:!, _, [inner]}), do: negate(split_conjunction(inner))
  defp split_conjunction(leaf), do: [{false, leaf}]

  defp combine_conj(:error, _), do: :error
  defp combine_conj(_, :error), do: :error
  defp combine_conj(a, b) when is_list(a) and is_list(b), do: a ++ b

  defp negate(:error), do: :error
  defp negate(list) when is_list(list), do: list |> Enum.map(fn {n, leaf} -> {not n, leaf} end)

  # Classify one leaf node into an atomic-condition record.
  defp classify_atom(leaf, neg) do
    cond do
      r = match_is_guard(leaf) -> {:ok, put_neg(r, neg)}
      r = match_bif_op_lit(leaf) -> {:ok, put_neg(r, neg)}
      r = match_param_in_list(leaf) -> {:ok, put_neg(r, neg)}
      r = match_param_eq_lit(leaf) -> {:ok, put_neg(r, neg)}
      r = match_field_eq_lit(leaf) -> {:ok, put_neg(r, neg)}
      r = match_eq_two_sides(leaf) -> {:ok, put_neg(r, neg)}
      r = match_param_op_lift_to_clauses(leaf) -> {:ok, put_neg(r, neg)}
      r = match_field_truthy(leaf) -> {:ok, put_neg(r, neg)}
      r = match_param_truthy(leaf) -> {:ok, put_neg(r, neg)}
      true -> :error
    end
  end

  defp put_neg({kind, payload}, neg), do: {kind, payload, neg}

  # Bare param as truthy condition: `if x do …`.
  defp match_param_truthy({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    if String.starts_with?(Atom.to_string(name), "_"), do: nil, else: {:param_truthy, name}
  end

  defp match_param_truthy(_), do: nil

  # ---- atomic matchers ----

  # is_atom(x), is_struct(x, Foo), is_nil(x), etc.
  defp match_is_guard({pred, _, [{name, _, ctx} | rest]})
       when is_atom(pred) and is_atom(name) and is_atom(ctx) do
    pred_str = Atom.to_string(pred)

    cond do
      String.starts_with?(pred_str, "is_") and length(rest) in [0, 1] ->
        {:is_guard, {pred, name, rest}}

      true ->
        nil
    end
  end

  defp match_is_guard(_), do: nil

  # length(xs) > 0, map_size(m) == 0, byte_size(b) >= 4, etc.
  @bif_unary [:length, :map_size, :tuple_size, :byte_size, :bit_size]
  @op_cmps [:==, :!=, :<, :>, :<=, :>=]
  defp match_bif_op_lit({op, _, [{bif, _, [{pname, _, pctx}]}, lit]})
       when op in @op_cmps and bif in @bif_unary and is_atom(pname) and is_atom(pctx) do
    if literal?(lit), do: {:bif_call, {bif, pname, op, lit}}, else: nil
  end

  defp match_bif_op_lit({op, _, [lit, {bif, _, [{pname, _, pctx}]}]})
       when op in @op_cmps and bif in @bif_unary and is_atom(pname) and is_atom(pctx) do
    if literal?(lit), do: {:bif_call, {bif, pname, flip_op(op), lit}}, else: nil
  end

  defp match_bif_op_lit(_), do: nil

  # param in [literal, literal, ...]
  defp match_param_in_list({:in, _, [{pname, _, pctx}, list_ast]})
       when is_atom(pname) and is_atom(pctx) do
    literal_list(list_ast) |> handle_literal_list(pname)
  end

  defp match_param_in_list(_), do: nil

  # param == literal / literal == param  (also !=)
  defp match_param_eq_lit({op, _, [{pname, _, pctx}, lit]})
       when op in [:==, :!=] and is_atom(pname) and is_atom(pctx) do
    if literal?(lit), do: {:param_eq_lit, {pname, op, lit}}, else: nil
  end

  defp match_param_eq_lit({op, _, [lit, {pname, _, pctx}]})
       when op in [:==, :!=] and is_atom(pname) and is_atom(pctx) do
    if literal?(lit), do: {:param_eq_lit, {pname, op, lit}}, else: nil
  end

  defp match_param_eq_lit(_), do: nil

  # param.f.g == literal / literal == param.f.g  (also !=)
  defp match_field_eq_lit({op, _, [lhs, lit]}) when op in [:==, :!=] do
    with true <- literal?(lit),
         {:ok, {root, fields}} <- field_chain(lhs) do
      {:field_eq_lit, {root, fields, op, lit}}
    else
      _ -> nil
    end
  end

  defp match_field_eq_lit({op, _, [lit, rhs]}) when op in [:==, :!=] do
    with true <- literal?(lit),
         {:ok, {root, fields}} <- field_chain(rhs) do
      {:field_eq_lit, {root, fields, op, lit}}
    else
      _ -> nil
    end
  end

  defp match_field_eq_lit(_), do: nil

  # param != [] etc.  Param-against-literal with comparison ops.
  defp match_param_op_lift_to_clauses({op, _, [{pname, _, pctx}, lit]})
       when op in @op_cmps and is_atom(pname) and is_atom(pctx) do
    if literal?(lit), do: {:param_op_lit, {pname, op, lit}}, else: nil
  end

  defp match_param_op_lift_to_clauses({op, _, [lit, {pname, _, pctx}]})
       when op in @op_cmps and is_atom(pname) and is_atom(pctx) do
    if literal?(lit), do: {:param_op_lit, {pname, flip_op(op), lit}}, else: nil
  end

  defp match_param_op_lift_to_clauses(_), do: nil

  # field_chain == field_chain  /  field_chain == bare_param  /  bare_param == field_chain
  #
  # Two field chains rooted at the SAME param can't be safely lifted:
  # both leaves would live inside one map-pattern, and pinning one to
  # the other requires the binding to happen first, which is not
  # guaranteed within a single map match.
  defp match_eq_two_sides({op, _, [lhs, rhs]}) when op in [:==, :!=] do
    l = side_for_eq(lhs)
    r = side_for_eq(rhs)

    case {l, r} do
      {{:param, _}, {:param, _}} -> nil
      {{:field, root, _}, {:field, root, _}} -> nil
      {{:param, _} = a, {:field, _, _} = b} -> {:eq_pin, {a, b, op}}
      {{:field, _, _} = a, {:param, _} = b} -> {:eq_pin, {a, b, op}}
      {{:field, _, _} = a, {:field, _, _} = b} -> {:eq_pin, {a, b, op}}
      _ -> nil
    end
  end

  defp match_eq_two_sides(_), do: nil

  defp side_for_eq({pname, _, pctx}) when is_atom(pname) and is_atom(pctx), do: {:param, pname}

  defp side_for_eq(other), do: field_chain(other) |> handle_field_chain()

  # param.f.g.h  (truthy)
  defp match_field_truthy(node), do: field_chain(node) |> handle_field_chain_2()

  # Walk dot-access and bracket-access chains, ending at a bare var.
  # Bracket-access (`p[:foo]`) is treated identically to `p.foo`.
  defp field_chain({{:., _, [parent, field]}, _, []}) when is_atom(field) do
    field_chain(parent) |> handle_field_chain_3(field)
  end

  defp field_chain({{:., _, [Access, :get]}, _, [parent, key_ast]}) do
    with {:ok, key} <- block_atom(key_ast),
         {:ok, {root, fields}} <- field_chain(parent) do
      {:ok, {root, fields ++ [key]}}
    else
      _ -> :error
    end
  end

  defp field_chain({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {:ok, {name, []}}
  defp field_chain(_), do: :error

  defp block_atom({:__block__, _, [a]}) when is_atom(a), do: {:ok, a}
  defp block_atom(a) when is_atom(a), do: {:ok, a}
  defp block_atom(_), do: :error

  defp literal?({:__block__, _, [v]})
       when is_atom(v) or is_integer(v) or is_float(v) or is_binary(v),
       do: true

  defp literal?({:__block__, _, [list]}) when is_list(list), do: literal_list_inner?(list)
  defp literal?(v) when is_atom(v) and v in [nil, true, false], do: true
  defp literal?(v) when is_integer(v) or is_float(v) or is_binary(v), do: true
  defp literal?(_), do: false

  defp literal_list_inner?(list), do: list |> Enum.all?(&literal?/1)

  defp literal_list({:__block__, _, [list]}) when is_list(list) do
    if list |> Enum.all?(&literal?/1), do: {:ok, list}, else: :error
  end

  defp literal_list(list) when is_list(list) do
    if list |> Enum.all?(&literal?/1), do: {:ok, list}, else: :error
  end

  defp literal_list(_), do: :error

  defp flip_op(:<), do: :>
  defp flip_op(:>), do: :<
  defp flip_op(:<=), do: :>=
  defp flip_op(:>=), do: :<=
  defp flip_op(op), do: op

  # Param names that the GENERATED guard references directly (so the
  # head slot must keep the param bound to that name, not `_name`).
  # Field-pattern bind-vars introduce a fresh variable name into the
  # guard — the original param name isn't referenced via that path.
  defp guard_referenced_params(atomics) do
    atomics
    |> Enum.flat_map(fn
      {:is_guard, {_pred, pname, _rest}, _} ->
        [pname]

      {:bif_call, {_bif, pname, _op, _lit}, _} ->
        [pname]

      {:param_in_list, {pname, _lits}, _} ->
        [pname]

      # Top-level "param == lit" becomes a pattern, NOT a guard.
      {:param_eq_lit, {_pname, :==, _lit}, false} ->
        []

      {:param_eq_lit, {pname, _op, _lit}, _} ->
        [pname]

      {:param_op_lit, {pname, _op, _lit}, _} ->
        [pname]

      # eq_pin with a {:param, name} side: the name participates in
      # the guard as-is.
      {:eq_pin, {a, b, _op}, _} ->
        [a, b]
        |> Enum.flat_map(fn
          {:param, name} -> [name]
          _ -> []
        end)

      {:param_truthy, pname, _} ->
        [pname]

      _ ->
        []
    end)
    |> MapSet.new()
  end

  # All atomic conditions must reference a known function parameter as
  # their primary subject (root of a field chain, or a bare param).
  defp all_atomics_use_known_params(atomics, param_names) do
    ok? =
      atomics
      |> Enum.all?(fn
        {:is_guard, {_pred, pname, _rest}, _} -> pname in param_names
        {:bif_call, {_bif, pname, _op, _lit}, _} -> pname in param_names
        {:param_in_list, {pname, _lits}, _} -> pname in param_names
        {:param_eq_lit, {pname, _op, _lit}, _} -> pname in param_names
        {:param_op_lit, {pname, _op, _lit}, _} -> pname in param_names
        {:field_eq_lit, {root, _f, _op, _lit}, _} -> root in param_names
        {:field_truthy, {root, _f}, _} -> root in param_names
        {:eq_pin, {a, b, _op}, _} -> side_root(a) in param_names and side_root(b) in param_names
        {:param_truthy, pname, _} -> pname in param_names
        _ -> false
      end)

    if ok?, do: :ok, else: :error
  end

  defp side_root({:param, name}), do: name
  defp side_root({:field, root, _}), do: root

  # -------- Plan construction --------

  # The plan describes how to render the two clauses. We compute:
  #   - per-param map-pattern (nested) and pin assignments
  #   - guard expression (string)
  #   - which params the catch-all clause needs to keep bound (i.e.
  #     ones referenced by the else-body)
  defp build_plan(atomics, params, cond_ast, do_body, else_body, _single_branch?, source) do
    # patterns[param_name] => nested map of {field_atom => leaf}
    # where leaf is one of:
    #   {:value, lit_ast}            -- exact-value match at this leaf
    #   {:bind, var_name}            -- bind to a fresh var (used in guard)
    #   {:pin, var_name}             -- pin reference to a prior-bound var
    param_names = bare_param_names(params)

    # Pre-seed binding registry with all param names so freshly-bound
    # field vars won't collide with them (`id` param ⇒ field bind is
    # `id2`).
    initial_bindings = Map.new(param_names, &{Atom.to_string(&1), true})
    pin_state = %{bindings: initial_bindings, counter: %{}}

    try do
      {patterns, guards, pin_state} =
        atomics
        |> Enum.reduce({%{}, [], pin_state}, fn atom, {pats, gs, ps} ->
          accumulate_atom(atom, pats, gs, ps, param_names)
        end)

      _ = pin_state

      do_text = render_body_text(do_body, source)
      else_text = render_body_text(else_body, source)
      else_uses = used_var_names(else_body)

      _ = cond_ast
      do_uses = used_var_names(do_body)
      guard_uses = guard_referenced_params(atomics)
      head_uses = MapSet.union(do_uses, guard_uses)

      {:ok,
       %{
         do_body_ast: do_body,
         do_text: do_text,
         else_body_ast: else_body,
         else_text: else_text,
         else_uses: else_uses,
         guards: guards |> Enum.reverse(),
         head_uses: head_uses,
         patterns: patterns
       }}
    catch
      :throw, :skip -> :error
    end
  end

  # `pats` is a map: param_name => pattern-tree.
  # A pattern-tree is either:
  #   - {:fields, %{atom => subtree}}  with possibly merged leaves
  #   - {:eq, lit_ast}                 (top-level param == lit)
  defp accumulate_atom({:is_guard, {pred, pname, rest}, neg?}, pats, gs, ps, _params) do
    guard =
      case rest do
        [] -> "#{pred}(#{pname})"
        [extra] -> "#{pred}(#{pname}, #{Sourceror.to_string(extra)})"
      end

    {pats, [{neg?, guard} | gs], ps}
  end

  defp accumulate_atom({:bif_call, {bif, pname, op, lit}, neg?}, pats, gs, ps, _params) do
    guard = "#{bif}(#{pname}) #{Atom.to_string(op)} #{Sourceror.to_string(lit)}"
    {pats, [{neg?, guard} | gs], ps}
  end

  defp accumulate_atom({:param_in_list, {pname, lits}, neg?}, pats, gs, ps, _params) do
    list_text = "[" <> Enum.map_join(lits, ", ", &Sourceror.to_string/1) <> "]"
    guard = "#{pname} in #{list_text}"
    {pats, [{neg?, guard} | gs], ps}
  end

  # Top-level "param == literal" — bake the literal into the head
  defp accumulate_atom({:param_eq_lit, {pname, :==, lit}, false}, pats, gs, ps, _params),
    # pattern directly (replace the param's binding with the literal).
    do: {Map.put(pats, pname, {:eq, lit}), gs, ps}

  defp accumulate_atom({:param_eq_lit, {pname, op, lit}, neg?}, pats, gs, ps, _params) do
    # `!=` or negated `==` — emit as guard.
    real_op = if neg?, do: flip_eq(op), else: op
    guard = "#{pname} #{Atom.to_string(real_op)} #{Sourceror.to_string(lit)}"
    {pats, [{false, guard} | gs], ps}
  end

  defp accumulate_atom({:param_op_lit, {pname, op, lit}, neg?}, pats, gs, ps, _params) do
    guard = "#{pname} #{Atom.to_string(op)} #{Sourceror.to_string(lit)}"
    {pats, [{neg?, guard} | gs], ps}
  end

  defp accumulate_atom({:field_eq_lit, {root, fields, :==, lit}, false}, pats, gs, ps, _params) do
    tree = Map.get(pats, root, {:fields, []})
    new_tree = put_leaf_value(tree, fields, lit)
    {Map.put(pats, root, new_tree), gs, ps}
  end

  defp accumulate_atom({:field_eq_lit, {root, fields, op, lit}, neg?}, pats, gs, ps, _params) do
    # !=, or negated == → bind leaf, guard with op.
    {pats2, bind_name, ps2} = ensure_bind(pats, ps, root, fields)
    real_op = if neg?, do: flip_eq(op), else: op
    guard = "#{bind_name} #{Atom.to_string(real_op)} #{Sourceror.to_string(lit)}"
    {pats2, [{false, guard} | gs], ps2}
  end

  defp accumulate_atom({:field_truthy, {root, fields}, neg?}, pats, gs, ps, _params) do
    {pats2, bind_name, ps2} = ensure_bind(pats, ps, root, fields)
    # Guards can't express truthiness directly (`when x` is strict
    # boolean, not truthy; `!`/`!!` are not allowed in guards). Use
    # `x not in [nil, false]` — guard-safe and preserves `if`'s
    # truthy semantics for every value.
    guard = "#{bind_name} not in [nil, false]"
    {pats2, [{neg?, guard} | gs], ps2}
  end

  defp accumulate_atom({:param_truthy, pname, neg?}, pats, gs, ps, _params) do
    guard = "#{pname} not in [nil, false]"
    {pats, [{neg?, guard} | gs], ps}
  end

  defp accumulate_atom({:eq_pin, {a, b, op}, neg?}, pats, gs, ps, _params) do
    # Pin inside a function head can only reference variables bound
    # BEFORE the head — never siblings inside the same head, because a
    # function-head is a simultaneous match across all patterns and
    # there's no left-to-right binding order. So we bind both sides and
    # emit an equality guard. (We keep param sides unchanged — they're
    # already bound by the head — and add a binding leaf for field
    # sides.)
    {pats2, left_var, ps2} = ensure_side_bound(pats, ps, a)
    {pats3, right_var, ps3} = ensure_side_bound(pats2, ps2, b)

    real_op =
      case {op, neg?} do
        {:==, false} -> :==
        {:==, true} -> :!=
        {:!=, false} -> :!=
        {:!=, true} -> :==
      end

    guard = "#{left_var} #{Atom.to_string(real_op)} #{right_var}"
    {pats3, [{false, guard} | gs], ps3}
  end

  # Bind the value at `side` to a variable (or reuse the existing param
  # binding) and return its name.
  defp ensure_side_bound(pats, ps, {:param, name}), do: {pats, Atom.to_string(name), ps}

  defp ensure_side_bound(pats, ps, {:field, root, fields}),
    do: ensure_bind(pats, ps, root, fields)

  defp flip_eq(:==), do: :!=
  defp flip_eq(:!=), do: :==

  # Pattern tree is `{:fields, [{atom, leaf}, ...]}` — a keyword list so
  # insertion order survives rendering (it would be alphabetised in a
  # map).

  defp put_leaf_value({:fields, kw}, [field], lit) do
    case Keyword.fetch(kw, field) do
      :error -> {:fields, kw ++ [{field, {:value, lit}}]}
      {:ok, {:value, ^lit}} -> {:fields, kw}
      {:ok, _} -> throw(:skip)
    end
  end

  defp put_leaf_value({:fields, kw}, [field | rest], lit) do
    sub = Keyword.get(kw, field, {:fields, []})

    sub =
      case sub do
        {:fields, _} -> put_leaf_value(sub, rest, lit)
        _ -> throw(:skip)
      end

    {:fields, put_or_append(kw, field, sub)}
  end

  defp put_leaf_value(_, _, _), do: throw(:skip)

  defp ensure_bind(patchs, ps, root, fields) do
    last = List.last(fields)
    {var_name, ps2} = fresh_name(ps, sanitize_field_name(last))
    tree = Map.get(patchs, root, {:fields, []})
    new_tree = put_leaf_bind(tree, fields, var_name)
    {Map.put(patchs, root, new_tree), var_name, ps2}
  end

  # Field atoms like `:__trimmed_top__` would produce a binding
  # variable named `__trimmed_top__`, whose leading underscores tell
  # the compiler "this value should not be used" — but we DO use it
  # in the guard, so strip the leading underscores.
  defp sanitize_field_name(atom) do
    str = Atom.to_string(atom)
    stripped = String.replace_leading(str, "_", "")
    if stripped == "", do: "v", else: stripped
  end

  defp put_leaf_bind({:fields, kw}, [field], var),
    do: Keyword.fetch(kw, field) |> handle_put_leaf_bind_fetch(field, kw, var)

  defp put_leaf_bind({:fields, kw}, [field | rest], var) do
    sub = Keyword.get(kw, field, {:fields, []})

    sub =
      case sub do
        {:fields, _} -> put_leaf_bind(sub, rest, var)
        _ -> throw(:skip)
      end

    {:fields, put_or_append(kw, field, sub)}
  end

  defp put_leaf_bind(_, _, _), do: throw(:skip)

  defp put_or_append(keyword, key, value) do
    if Keyword.has_key?(keyword, key),
      do: Keyword.put(keyword, key, value),
      else: keyword ++ [{key, value}]
  end

  # Pick a fresh variable name based on a (string) suggestion. If the
  # name already exists in the bindings registry, suffix with a counter.
  defp fresh_name(state, suggested) when is_binary(suggested) do
    base = suggested

    if Map.has_key?(state.bindings, base) do
      n = Map.get(state.counter, base, 1) + 1
      name = base <> Integer.to_string(n)

      ps2 = %{
        state
        | counter: Map.put(state.counter, base, n),
          bindings: Map.put(state.bindings, name, true)
      }

      {name, ps2}
    else
      ps2 = %{state | bindings: Map.put(state.bindings, base, true)}
      {base, ps2}
    end
  end

  # -------- Rendering --------

  defp render_clauses(kind, fn_name, params, plan, source) do
    head_slots = render_head_slots(params, plan.patterns, plan.head_uses)
    guard_text = render_guard(plan.guards)

    head =
      "#{kind} #{fn_name}(" <>
        Enum.join(head_slots |> Enum.map(&elem(&1, 0)), ", ") <> ")" <> guard_text

    do_clause = render_clause(head, plan.do_body_ast, plan.do_text)

    catchall_params = render_catchall_params(params, plan.else_uses, head_slots)

    catchall_head = "#{kind} #{fn_name}(" <> Enum.join(catchall_params, ", ") <> ")"
    else_clause = render_clause(catchall_head, plan.else_body_ast, plan.else_text)

    _ = source
    do_clause <> "\n\n" <> else_clause
  end

  defp render_clause(head, body_ast, body_text) do
    if simple_body?(body_ast) do
      "#{head}, do: #{body_text}"
    else
      "#{head} do\n  #{body_text}\nend"
    end
  end

  # A body is "simple" if it's a single expression that contains no
  # block-construct (case/cond/if/unless/with/try/for/receive/quote/fn).
  # Block-constructs reopen `do/end` syntax which doesn't mix with the
  # keyword `do:` form.
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

  # Returns a list of {rendered_text, kind} where kind is :bare | :pattern | :literal
  defp render_head_slots(params, patterns, head_uses) do
    params
    |> Enum.map(fn {name, ast} ->
      cond do
        name == nil ->
          # Anonymous slot (literal, `_name`, or pattern). Pass through.
          {Sourceror.to_string(ast), :pattern}

        true ->
          case Map.get(patterns, name) do
            nil ->
              if MapSet.member?(head_uses, name),
                do: {Atom.to_string(name), :bare},
                else: {underscore_for(name), :bare}

            {:eq, lit} ->
              {Sourceror.to_string(lit), :literal}

            {:fields, _} = tree ->
              # Only emit `= name` binder when the do-body actually
              # references the whole param; otherwise the pattern
              # alone is enough (no `= _foo` noise).
              text =
                if MapSet.member?(head_uses, name) do
                  render_pattern_tree(tree) <> " = " <> Atom.to_string(name)
                else
                  render_pattern_tree(tree)
                end

              {text, :pattern}
          end
      end
    end)
  end

  defp non_bare_param?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: false
  defp non_bare_param?(_), do: true

  defp underscore_for(name) do
    string = Atom.to_string(name)
    if String.starts_with?(string, "_"), do: string, else: "_" <> string
  end

  defp render_pattern_tree({:fields, kw}) do
    inner =
      kw |> Enum.map_join(", ", fn {field, leaf} -> "#{field}: #{render_leaf(leaf)}" end)

    "%{" <> inner <> "}"
  end

  defp render_leaf({:value, lit}), do: Sourceror.to_string(lit)
  defp render_leaf({:bind, var}), do: var
  defp render_leaf({:fields, _} = tree), do: render_pattern_tree(tree)

  defp render_guard([]), do: ""

  defp render_guard(guards) do
    text =
      guards
      |> Enum.map_join(" and ", fn {neg?, g} -> if neg?, do: "not (" <> g <> ")", else: g end)

    " when " <> text
  end

  # Catch-all param rules (per slot):
  #   - else-body uses the name           → bind: `name`
  #   - do-clause has the slot bare-bound → `_name` (matches the do-slot)
  #   - else-body doesn't use it AND do-slot is pattern/literal → `_`
  #     (no need to mirror the do-slot's pattern; the literal/pattern
  #     was the discriminator, not a name to mirror)
  # Catch-all params: keep names that the else-body uses, drop the
  # rest. When NO name is preserved (every slot is unused in the
  # else-body), use bare `_`; when at least one slot is preserved,
  # mark the unused bare slots as `_name` so the diff with the
  # preserving slot stays readable.
  defp render_catchall_params(params, else_uses, head_slots) do
    any_preserved? =
      params |> Enum.any?(fn {name, _ast} -> name != nil and MapSet.member?(else_uses, name) end)

    params
    |> Enum.zip(head_slots)
    |> Enum.map(fn {{name, ast}, {head_text, _head_kind}} ->
      cond do
        name != nil and MapSet.member?(else_uses, name) -> Atom.to_string(name)
        name == nil -> head_text
        non_bare_param?(ast) -> "_"
        any_preserved? -> underscore_for(name)
        true -> "_"
      end
    end)
  end

  defp render_body_text(body, source), do: slice_node(source, body) |> handle_slice_node(body)

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_split_conjunction(:error), do: :error

  defp handle_split_conjunction(atoms) do
    case atoms |> Enum.reduce_while({:ok, []}, &reduce_atom/2) do
      {:ok, acc} -> {:ok, acc |> Enum.reverse()}
      :error -> :error
    end
  end

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_classify_atom({:ok, atom}, acc), do: {:cont, {:ok, [atom | acc]}}

  defp handle_classify_atom(:error, _acc), do: {:halt, :error}

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_literal_list({:ok, lits}, pname), do: {:param_in_list, {pname, lits}}

  defp handle_literal_list(:error, _pname), do: nil

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_field_chain({:ok, {root, fields}}), do: {:field, root, fields}

  defp handle_field_chain(:error), do: nil

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_field_chain_2({:ok, {root, fields}}) when fields != [] do
    {:field_truthy, {root, fields}}
  end

  defp handle_field_chain_2(_), do: nil

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_field_chain_3({:ok, {root, fields}}, field), do: {:ok, {root, fields ++ [field]}}

  defp handle_field_chain_3(:error, _field), do: :error

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_put_leaf_bind_fetch(:error, field, kw, var),
    do: {:fields, kw ++ [{field, {:bind, var}}]}

  defp handle_put_leaf_bind_fetch({:ok, {:bind, existing}}, field, kw, _var),
    do: {:fields, Keyword.put(kw, field, {:bind, existing})}

  defp handle_put_leaf_bind_fetch({:ok, _}, _field, _kw, _var), do: :skip |> throw()

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_slice_node({:ok, text}, _body), do: text |> String.trim()

  defp handle_slice_node(:error, body), do: body |> Sourceror.to_string()
end
