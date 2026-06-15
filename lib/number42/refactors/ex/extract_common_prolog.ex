defmodule Number42.Refactors.Ex.ExtractCommonProlog do
  @moduledoc """
  Extracts a setup prolog shared by several functions into one private
  helper, lifting the bindings the callers still need through a tuple
  return.

      # before
      def handle_event("save", params, socket) do
        socket = assign(socket, :loading, true)
        socket = assign(socket, :error, nil)
        current_user = socket.assigns.current_user
        finish(socket, save(params, current_user))
      end

      def handle_event("delete", params, socket) do
        socket = assign(socket, :loading, true)
        socket = assign(socket, :error, nil)
        current_user = socket.assigns.current_user
        finish(socket, delete(params, current_user))
      end

      # after
      def handle_event("save", params, socket) do
        {current_user, socket} = prepare_handle_event(socket)
        finish(socket, save(params, current_user))
      end

      def handle_event("delete", params, socket) do
        {current_user, socket} = prepare_handle_event(socket)
        finish(socket, delete(params, current_user))
      end

      defp prepare_handle_event(socket) do
        socket = assign(socket, :loading, true)
        socket = assign(socket, :error, nil)
        current_user = socket.assigns.current_user
        {current_user, socket}
      end

  This is the **cross-function** counterpart to extracting a block out of
  one function (`ExtractFunctionFromBlock`) and to lifting a shared
  prologue across the *clauses* of one function
  (`DedupeClausePrologue`): here the same leading statements appear at
  the top of several distinct functions and collapse into a single
  shared helper.

  ## How a group qualifies

  - **≥ `:min_functions` definitions** (default `2`) that are
    **contiguous** in the source — the rewrite replaces one source range,
    so a group split by an unrelated definition is skipped.
  - **Identical prolog.** Their leading run of AST-identical statements
    (ignoring metadata) is at least `:min_prolog_statements` long
    (default `2`). A prefix that diverges in a literal
    (`assign(:loading, true)` vs `assign(:loading, :spinner)`) is a
    *parametric* clone — left for that family, not force-merged here.
  - **Divergent tail.** Every function must have at least one statement
    after the prolog. A function whose whole body *is* the prolog is a
    full-body duplicate, a different refactor's concern.
  - **Free vars are parameters everywhere.** Every variable the prolog
    reads but does not itself bind must be a bare parameter in *every*
    function of the group (so the helper can take it as an argument and
    each call site can pass it). If a needed input is pattern-matched or
    absent in some function, the group is skipped.
  - **No control flow in the prolog.** A prolog containing `case`/`with`/
    `if`/`fn`/… is left alone — its bindings can be conditional and the
    liveness/tuple lift would be unsound.

  ## Liveness & the tuple return

  Of the variables the prolog **binds** (including a parameter rebound
  in place, `socket = assign(socket, …)`), only those still **read** in
  the remaining body of *some* function are live. The live set —
  computed flow-sensitively so a self-rebind counts as a read — becomes
  the helper's return:

  - **0 live bindings** → nothing to thread back; the prolog is a pure
    side-effect run, out of scope here, so the group is skipped.
  - **1 live binding** → returned bare; the call site binds `x = helper(…)`.
  - **≥ 2 live bindings** → returned as a sorted tuple. The helper's
    returned shape is identical at every call site — a single shared
    shape keeps it monomorphic — but each call site's *binding pattern*
    underscores the positions its own tail never reads. A site that
    reads only `a` binds `{a, _b} = helper(…)`; a site that reads both
    binds `{a, b} = helper(…)`. Without this, a returned-but-unread
    binding would be an unused variable, rejected under
    `--warnings-as-errors`.

  The same applies to the single-binding case: a site that does not read
  the returned binding in its tail binds `_x = helper(…)`.

  ## Side-effect ordering

  The prolog statements move verbatim, in order, into the helper, and
  the helper is called at exactly the point the prolog occupied. No
  statement is duplicated. So the observable order of side effects per
  call site is preserved.

  ## Near matches — one boundary extra getter

  The prologs need not be byte-identical. Exactly **one** clause may
  carry a single extra binding statement at the prolog boundary (right
  after the shared run) — typically a getter the other clauses don't
  need. That extra is pulled into the helper too, and threaded back
  through its own return slot:

  - A **pure read** — a `param.field.field` chain (`socket.assigns.x`)
    or any `pure?/1`-true RHS (`Map.get`, arithmetic) — stays **eager**:
    it runs in the helper and is returned by value, exactly like a
    normal live binding. The non-needing clauses underscore the slot.
  - A **side-effect-possible getter** (`Repo.get`, a local `get_user/1`)
    is **lazy**: the helper returns a thunk (`fn -> … end`) in a
    `*_fun` slot. The needing clause forces it (`x = x_fun.()`); the
    others underscore the slot and never run it. Laziness here is a
    correctness requirement, not an optimisation — running the getter
    eagerly in the helper would execute it for clauses that don't need
    it (an extra query, a possible crash).

  The near match qualifies only when the extra is **safely deferrable**:
  it sits at the boundary, its binding is read solely in the bearer's
  own tail (no shared follow-up consumes it), it reads only helper
  params or shared-prolog bindings, and there is exactly one bearer. If
  any of these fail, the near-match layer declines and the exact-match
  path runs unchanged — never a relaxation of the exact-match guards,
  always an extra qualification on top of them.

  ## Helper placement & clause families

  The helper is emitted after the rewritten group. When the group is a
  *slice* of one multi-clause function — its clauses share a single
  name/arity and more clauses of that name/arity follow the group — the
  helper is instead placed after the **last** clause of that family, so
  the clause group is never split (Elixir warns, and rejects under
  `--warnings-as-errors`, on "clauses with the same name and arity
  should be grouped together"). When the group already is the family's
  tail (the common case), the helper sits directly after the call sites.

  ## Pass scope & idempotence

  One eligible group is rewritten per pass (the first found, in source
  order). After the rewrite each former call site opens with a helper
  call, not the shared statements, so a second pass finds no shared
  prolog to lift — the rewrite is idempotent. A near-match rewrite is
  idempotent for the same reason: the bearer opens with the helper call
  (and, for a lazy extra, a `x = x_fun.()` force) while the others open
  with a differently-shaped destructure, so no shared first statement
  remains to re-detect.
  """

  use Number42.Refactors.Refactor

  @control_flow_forms ~w(raise throw exit with case cond if unless try for fn receive)a

  @impl Number42.Refactors.Refactor
  def description,
    do: "Extract a setup prolog shared across functions into a tuple-returning private helper"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    When several functions open with the same run of setup statements,
    that prolog is duplicated work spread across definitions. Lifting it
    into one shared private helper that returns the still-needed bindings
    as a tuple removes the duplication while preserving side-effect
    order: the statements run once, in place, at each call site. Only
    bindings read after the prolog are returned (liveness), and prologs
    that diverge in a literal or contain control flow are left alone.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts),
    do: Sourceror.parse_string(source) |> apply_to_parse_result(source, opts)

  defp apply_to_parse_result({:ok, ast}, source, opts), do: apply_to_ast(ast, source, opts)
  defp apply_to_parse_result({:error, _}, source, _opts), do: source

  defp apply_to_ast(ast, source, opts) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value(source, fn
      {:defmodule, _, [_name, [{_do, _body}]]} = mod_ast ->
        extract_in_module(mod_ast, source, opts)

      _ ->
        nil
    end)
  end

  defp extract_in_module(mod_ast, source, opts) do
    case module_body_exprs(mod_ast) do
      [_ | _] = body_exprs -> first_eligible_patch(body_exprs, source, opts)
      _ -> nil
    end
  end

  defp first_eligible_patch(body_exprs, source, opts) do
    min_prolog = Keyword.get(opts, :min_prolog_statements, 2)
    min_funcs = Keyword.get(opts, :min_functions, 2)
    existing = def_names(body_exprs)

    parsed = Enum.map(body_exprs, &parse_def/1)

    parsed
    |> candidate_groups(min_funcs)
    |> Enum.find_value(nil, fn group ->
      with {:ok, plan} <- plan_group(group, existing, min_prolog),
           {:ok, patches} <- build_group_patches(group, parsed, plan) do
        Sourceror.patch_string(source, patches)
      else
        _ -> nil
      end
    end)
  end

  # --- grouping: contiguous runs sharing the same first statement ---

  # Defs sharing an identical leading statement are candidates for a
  # shared prolog. We chunk the body by that first-statement key so a
  # group is always a contiguous source run (the patch replaces one
  # range). Non-def nodes and bodyless heads break a run.
  defp candidate_groups(parsed, min_funcs) do
    parsed
    |> Enum.chunk_by(&first_stmt_key/1)
    |> Enum.filter(fn
      [first | _] = chunk ->
        first_stmt_key(first) != nil and length(chunk) >= min_funcs

      _ ->
        false
    end)
  end

  defp first_stmt_key(%{stmts: [first | _]}), do: strip_meta(first)
  defp first_stmt_key(_), do: nil

  defp parse_def({kind, _, [head, body_kw]} = node) when kind in [:def, :defp] do
    {bare_head, guard} = split_guard(head)

    with {name, params} <- extract_fn_signature(bare_head),
         {:ok, body} <- do_body(body_kw) do
      %{
        kind: kind,
        name: name,
        params: params,
        arity: length(params),
        guard: guard,
        head: head,
        stmts: body_to_exprs(body),
        node: node
      }
    else
      _ -> :other
    end
  end

  defp parse_def(_), do: :other

  # --- per-group analysis ---

  defp plan_group(group, existing, min_prolog) do
    with {:ok, prolog_len} <- shared_prolog_length(group, min_prolog),
         :ok <- ensure_no_control_flow(group, prolog_len),
         :ok <- ensure_divergent_tail(group, prolog_len),
         {:ok, params} <- helper_params(group, prolog_len),
         extra = detect_boundary_extra(group, prolog_len, params),
         {:ok, live} <- live_bindings(group, prolog_len, extra),
         {:ok, helper_name} <- helper_name(group, existing) do
      {:ok,
       %{
         prolog_len: prolog_len,
         params: params,
         live: live,
         extra: extra,
         helper_name: helper_name
       }}
    end
  end

  # --- near-match: a single boundary extra getter ---
  #
  # Beyond the shared prolog, exactly one clause may carry ONE extra
  # binding statement at the prolog boundary (index `prolog_len`). That
  # extra is pulled into the helper too: a pure read stays eager in the
  # return tuple; a side-effect-possible getter is deferred behind a
  # thunk so the non-bearing clauses never run it.
  #
  # Returns the extra descriptor map, or `nil` when no qualifying single
  # boundary extra exists — in which case the exact-match path runs
  # unchanged. The descriptor:
  #
  #   %{bearer: def, var: atom, rhs: ast, slot: atom, mode: :eager | :lazy}
  #
  # `slot` is the tuple position name: for `:eager` it is `var` itself
  # (the value is returned directly); for `:lazy` it is `:"#{var}_fun"`
  # (a thunk the bearer forces). Qualification (all must hold):
  #
  #   * exactly one clause has a statement at `prolog_len`; every other
  #     clause's tail begins there (its statement at `prolog_len` is the
  #     first of its divergent tail, never a second extra). "Exactly one
  #     bearer" — two clauses with extras disqualifies.
  #   * the extra is a binding `var = rhs` (a bare side-effecting call
  #     with no binding has nothing to thread back → disqualifies).
  #   * `var` is read only in the bearer's own tail, not by any shared
  #     follow-up the other clauses also run (deferrable to one clause).
  #   * every var `rhs` reads is a helper param or bound by the shared
  #     prolog (so the helper can evaluate it at call time).
  #   * `rhs` is either a pure field-access chain over a helper param
  #     (eager) or `pure?/1`-true (eager) or otherwise side-effect
  #     possible (lazy thunk). Anything that can't be classified — e.g.
  #     control flow — disqualifies.
  defp detect_boundary_extra(group, prolog_len, params) do
    available = MapSet.union(MapSet.new(params), prolog_binds(hd(group), prolog_len))

    case Enum.filter(group, &qualifying_bearer?(&1, group, prolog_len, available)) do
      [bearer] -> build_extra(bearer, prolog_len, params)
      _ -> nil
    end
  end

  # Whether `def` is a viable single-extra bearer: its statement at the
  # boundary is a binding `var = rhs` where `rhs` reads only available
  # names (params + shared-prolog bindings), and `var` is read in this
  # clause's own tail but nowhere else (not by any sibling's tail, not by
  # the shared prolog). "Read only here" is what makes the value safe to
  # defer to this one clause. Two qualifying clauses ⇒ caller declines.
  defp qualifying_bearer?(def, group, prolog_len, available) do
    with {:=, _, [lhs, rhs]} <- Enum.at(def.stmts, prolog_len),
         {:ok, var} <- bare_var(lhs),
         true <- MapSet.subset?(used_var_names(rhs), available) do
      var_read_only_in?(group, def, prolog_len, var)
    else
      _ -> false
    end
  end

  defp build_extra(bearer, prolog_len, params) do
    {:=, _, [lhs, rhs]} = Enum.at(bearer.stmts, prolog_len)
    {:ok, var} = bare_var(lhs)

    case classify_extra_rhs(rhs, MapSet.new(params)) do
      {:ok, mode} ->
        %{bearer: bearer, var: var, rhs: rhs, slot: slot_name(var, mode), mode: mode}

      :skip ->
        nil
    end
  end

  # `var` (bound by the bearer's boundary extra) must be read in the
  # bearer's OWN tail and nowhere else: not by any sibling clause (which
  # never even runs the extra) and not by the shared prolog (which runs
  # for everyone). That read-locality is what lets the value be deferred
  # to this single clause.
  defp var_read_only_in?(group, bearer, prolog_len, var) do
    read_in_bearer_tail? = bearer.stmts |> Enum.drop(prolog_len + 1) |> free_reads(var)

    read_elsewhere? =
      Enum.any?(group, fn
        ^bearer -> false
        %{stmts: stmts} -> stmts |> Enum.drop(prolog_len) |> free_reads(var)
      end)

    read_in_bearer_tail? and not read_elsewhere?
  end

  defp free_reads(stmts, var),
    do: var in free_vars_in_order(stmts, MapSet.new([var]))

  # Eager when `rhs` is a pure field-access chain rooted in a helper
  # param (`socket.assigns.current_user`) — `pure?/1` rejects the dotted
  # chain because its root is a dot-call, not an `__aliases__` — or when
  # `pure?/1` itself accepts it (`Map.get`, arithmetic). Otherwise the
  # call may have a side effect (`Repo.get`, a local getter) and is
  # deferred as a lazy thunk. Control flow never reaches here (the shared
  # prolog already bans it and the extra is a single binding RHS), but a
  # belt-and-braces guard keeps `fn`/`case`/… out of the helper.
  defp classify_extra_rhs(rhs, param_set) do
    cond do
      has_control_flow?(rhs) -> :skip
      field_access_over_param?(rhs, param_set) -> {:ok, :eager}
      pure?(rhs) -> {:ok, :eager}
      true -> {:ok, :lazy}
    end
  end

  # A nullary dotted field-access chain (`a.b.c`) whose root identifier
  # is a helper param. These are pure reads `pure?/1` can't see as pure
  # (the chain's root is a `{:., …}` dot-call, so `alias_to_module`
  # returns `:error`). Local: only this refactor needs the predicate.
  defp field_access_over_param?({{:., _, [inner, field]}, _, []}, param_set)
       when is_atom(field),
       do: field_access_over_param?(inner, param_set)

  defp field_access_over_param?({name, _, ctx}, param_set)
       when is_atom(name) and is_atom(ctx),
       do: MapSet.member?(param_set, name)

  defp field_access_over_param?(_, _), do: false

  defp slot_name(var, :eager), do: var
  defp slot_name(var, :lazy), do: :"#{var}_fun"

  # Longest leading run of AST-identical (metadata-stripped) statements
  # across every def in the group.
  defp shared_prolog_length(group, min_prolog) do
    max_len = group |> Enum.map(&length(&1.stmts)) |> Enum.min()

    len =
      Enum.reduce_while(0..(max_len - 1)//1, 0, fn i, acc ->
        if all_agree_at?(group, i), do: {:cont, acc + 1}, else: {:halt, acc}
      end)

    if len >= min_prolog, do: {:ok, len}, else: :skip
  end

  defp all_agree_at?([%{stmts: first} | _] = group, i) do
    ref = first |> Enum.at(i) |> strip_meta()
    Enum.all?(group, fn %{stmts: s} -> strip_meta(Enum.at(s, i)) == ref end)
  end

  defp ensure_no_control_flow(group, prolog_len) do
    [%{stmts: first} | _] = group
    prolog = Enum.take(first, prolog_len)

    if Enum.any?(prolog, &has_control_flow?/1), do: :skip, else: :ok
  end

  defp ensure_divergent_tail(group, prolog_len) do
    if Enum.all?(group, fn %{stmts: s} -> length(s) > prolog_len end), do: :ok, else: :skip
  end

  # Free vars of the prolog → helper params. Each must be a bare
  # parameter in every def of the group, else a call site can't pass it.
  # Flow-sensitive so a self-rebind (`socket = assign(socket, …)`) reads
  # `socket` as an input before binding it.
  defp helper_params(group, prolog_len) do
    [%{stmts: first} | _] = group
    reads = first |> Enum.take(prolog_len) |> prolog_input_reads()

    if Enum.all?(group, fn def -> MapSet.subset?(reads, bare_param_names(def)) end) do
      {:ok, reads |> MapSet.to_list() |> Enum.sort()}
    else
      :skip
    end
  end

  # Names a prolog reads before binding them — its inputs. Per statement
  # the reads are the RHS of an assignment (the LHS bare name is a
  # binding, not a read) or the whole statement otherwise; a name already
  # bound by an earlier statement is not an input. A self-rebind
  # (`socket = f(socket)`) keeps `socket` an input because its RHS read
  # is gathered before this statement's own binding joins the accumulator.
  defp prolog_input_reads(prolog) do
    {reads, _bound} =
      Enum.reduce(prolog, {MapSet.new(), MapSet.new()}, fn stmt, {reads, bound} ->
        stmt_reads = stmt |> stmt_read_names() |> MapSet.difference(bound)
        {MapSet.union(reads, stmt_reads), MapSet.union(bound, bound_in(stmt))}
      end)

    reads
  end

  defp stmt_read_names({:=, _, [_lhs, rhs]}), do: used_var_names(rhs)
  defp stmt_read_names(stmt), do: used_var_names(stmt)

  # Prolog-bound names still read in some def's tail. Flow-sensitive so a
  # self-rebind (`socket = assign(socket, …)`) followed by a later read
  # keeps the name live. The bearer of a near-match extra has that extra
  # statement at index `prolog_len`; its real tail begins one statement
  # later, so we drop the extra before scanning for reads (its own binding
  # is threaded back through the extra slot, not the live tuple).
  defp live_bindings(group, prolog_len, extra) do
    bound = group |> hd() |> prolog_binds(prolog_len)

    read_after =
      group
      |> Enum.flat_map(fn def ->
        def |> def_tail(prolog_len, extra) |> free_vars_in_order(bound)
      end)
      |> MapSet.new()

    case bound |> MapSet.intersection(read_after) |> MapSet.to_list() |> Enum.sort() do
      [] -> :skip
      live -> {:ok, live}
    end
  end

  # The statements of `def` after the shared prolog — and, for the bearer
  # of a near-match extra, after the extra too. Non-bearers and the
  # exact-match path drop only the shared prolog.
  defp def_tail(%{stmts: stmts} = def, prolog_len, %{bearer: bearer}) when def == bearer,
    do: Enum.drop(stmts, prolog_len + 1)

  defp def_tail(%{stmts: stmts}, prolog_len, _extra), do: Enum.drop(stmts, prolog_len)

  defp prolog_binds(%{stmts: stmts}, prolog_len) do
    stmts
    |> Enum.take(prolog_len)
    |> Enum.reduce(MapSet.new(), fn s, acc -> MapSet.union(acc, bound_in(s)) end)
  end

  # Derive a non-colliding helper name. Prefer `prepare_<name>` when the
  # group shares one function name; else a documented placeholder.
  defp helper_name(group, existing) do
    base =
      case group |> Enum.map(& &1.name) |> Enum.uniq() do
        [single] -> :"prepare_#{single}"
        _ -> :prepare_common_prolog
      end

    {:ok, dedupe_name(base, existing)}
  end

  defp dedupe_name(base, existing) do
    if MapSet.member?(existing, base), do: dedupe_name_n(base, 1, existing), else: base
  end

  defp dedupe_name_n(base, n, existing) do
    candidate = :"#{base}_#{n}"

    if MapSet.member?(existing, candidate),
      do: dedupe_name_n(base, n + 1, existing),
      else: candidate
  end

  # --- patch construction ---

  # The rewrite replaces the group's source range with the rewritten call
  # sites and emits the helper. Where the helper lands matters when the
  # group is a *slice* of a multi-clause function: if more clauses of the
  # same name/arity follow the group, dropping the helper right after the
  # group splits the clause family (compiler warns "clauses with the same
  # name and arity should be grouped together"). So we place the helper
  # after the LAST clause of that family. When the group already is the
  # family's tail (the common case, e.g. the moduledoc `handle_event`
  # example), `last` is the group itself and the two patches collapse to
  # the original single-range replacement.
  defp build_group_patches(group, parsed, plan) do
    case group_range(group) do
      %{} = range ->
        rewritten = Enum.map_join(group, "\n\n", &render_call_site(&1, plan))
        helper = render_helper(group, plan)
        {:ok, helper_patches(group, parsed, range, rewritten, helper)}

      _ ->
        :skip
    end
  end

  defp helper_patches(group, parsed, range, rewritten, helper) do
    with %{node: node} <- last_family_clause_after(group, parsed),
         %{end: end_pos} <- Sourceror.get_range(node) do
      [
        %{change: rewritten, range: range},
        %{change: "\n\n" <> helper, range: %{start: end_pos, end: end_pos}}
      ]
    else
      _ -> [%{change: rewritten <> "\n\n" <> helper, range: range}]
    end
  end

  # The last clause sharing the group's name/arity that sits AFTER the
  # group in the module body. `nil` when the group is already the tail of
  # its clause family (no splice hazard — keep the single patch). Only a
  # single-name/arity group can have a family to over-splice; a mixed
  # group keeps the helper directly after the call sites.
  defp last_family_clause_after(group, parsed) do
    with {:single, name, arity} <- group_signature(group),
         [_ | _] = family <- family_after_group(group, parsed, name, arity) do
      List.last(family)
    else
      _ -> nil
    end
  end

  defp family_after_group(group, parsed, name, arity) do
    last_in_group = List.last(group)

    parsed
    |> Enum.drop_while(&(&1 != last_in_group))
    |> Enum.drop(1)
    |> Enum.filter(&same_signature?(&1, name, arity))
  end

  defp group_signature(group) do
    case group |> Enum.map(&{&1.name, &1.arity}) |> Enum.uniq() do
      [{name, arity}] -> {:single, name, arity}
      _ -> :mixed
    end
  end

  defp same_signature?(%{name: name, arity: arity}, name, arity), do: true
  defp same_signature?(_, _, _), do: false

  defp render_call_site(%{kind: kind, head: head} = def, plan) do
    tail_stmts = def_tail(def, plan.prolog_len, plan.extra)
    binding = render_destructure(plan, read_slots(def, tail_stmts, plan))
    call = "#{plan.helper_name}(#{Enum.map_join(plan.params, ", ", &Atom.to_string/1)})"
    force = render_force(def, plan)
    tail = Enum.map_join(tail_stmts, "\n", &Sourceror.to_string/1)

    "  #{kind} #{Sourceror.to_string(head)} do\n" <>
      indent("#{binding} = #{call}\n#{force}#{tail}") <>
      "\n  end"
  end

  # The bearer of a lazy extra forces its thunk right after the helper
  # call (`var = var_fun.()`); every other site, and the eager/exact-match
  # paths, emit nothing here.
  defp render_force(def, %{extra: %{mode: :lazy, bearer: bearer, var: var, slot: slot}})
       when def == bearer,
       do: "#{var} = #{slot}.()\n"

  defp render_force(_def, _plan), do: ""

  # The return-tuple slots this site reads, so the others can be
  # underscored (an unread bound position is rejected under
  # `--warnings-as-errors`). Live bindings and an eager extra are read
  # when free in the tail. A lazy thunk slot is "read" only by the bearer
  # (it forces it); every other site underscores the slot.
  defp read_slots(def, tail_stmts, plan) do
    live_read = free_vars_in_order(tail_stmts, MapSet.new(plan.live)) |> MapSet.new()
    add_extra_read(live_read, def, tail_stmts, plan.extra)
  end

  defp add_extra_read(read, _def, tail_stmts, %{mode: :eager, var: var}) do
    if var in free_vars_in_order(tail_stmts, MapSet.new([var])),
      do: MapSet.put(read, var),
      else: read
  end

  defp add_extra_read(read, def, _tail_stmts, %{mode: :lazy, bearer: bearer, slot: slot})
       when def == bearer,
       do: MapSet.put(read, slot)

  defp add_extra_read(read, _def, _tail_stmts, _extra), do: read

  defp render_helper(group, plan) do
    [first | _] = group

    body =
      first.stmts
      |> Enum.take(plan.prolog_len)
      |> append_eager_extra(plan.extra)
      |> Enum.map_join("\n", &Sourceror.to_string/1)

    ret = render_return(plan)
    params = Enum.map_join(plan.params, ", ", &Atom.to_string/1)

    "  defp #{plan.helper_name}(#{params}) do\n" <>
      indent("#{body}\n#{ret}") <>
      "\n  end"
  end

  # An eager extra runs verbatim inside the helper (its value is returned
  # directly). A lazy extra is NOT a helper statement — it is captured by
  # the returned thunk — so the body stays the shared prolog only.
  defp append_eager_extra(prolog, %{mode: :eager, bearer: bearer}),
    do: prolog ++ [Enum.at(bearer.stmts, length(prolog))]

  defp append_eager_extra(prolog, _extra), do: prolog

  # Pattern for one call site. Positions follow the slot order (the
  # helper's returned tuple shape, identical everywhere); a position this
  # site does not read is underscored so it isn't bound unused.
  defp render_destructure(plan, read) do
    case return_slots(plan) do
      [one] -> bind_name(one, read)
      many -> "{#{Enum.map_join(many, ", ", &bind_name(&1, read))}}"
    end
  end

  defp bind_name(var, read) do
    if MapSet.member?(read, var), do: Atom.to_string(var), else: "_#{var}"
  end

  defp render_return(plan) do
    case return_slots(plan) do
      [one] -> render_slot(one, plan)
      many -> "{#{Enum.map_join(many, ", ", &render_slot(&1, plan))}}"
    end
  end

  # A live binding (or eager extra var) is returned by name; the lazy slot
  # is returned as a thunk over the extra's RHS.
  defp render_slot(slot, %{extra: %{mode: :lazy, slot: slot, rhs: rhs}}),
    do: "fn -> #{Sourceror.to_string(rhs)} end"

  defp render_slot(slot, _plan), do: Atom.to_string(slot)

  # The helper's returned tuple shape: live bindings plus, for a near
  # match, the extra's slot (the eager var, or the lazy `*_fun` thunk
  # name). Sorted for a deterministic, monomorphic shape across sites.
  defp return_slots(%{live: live, extra: nil}), do: live

  defp return_slots(%{live: live, extra: %{slot: slot}}),
    do: [slot | live] |> Enum.uniq() |> Enum.sort()

  # --- helpers ---

  defp bare_param_names(%{params: params}) do
    params
    |> Enum.flat_map(fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> [name]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp split_guard({:when, _, [inner, guard]}), do: {inner, guard}
  defp split_guard(head), do: {head, nil}

  defp has_control_flow?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {form, _, _} when form in @control_flow_forms -> true
      _ -> false
    end)
  end

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp group_range(group) do
    with %{start: start} <- Sourceror.get_range(List.first(group).node),
         %{end: stop} <- Sourceror.get_range(List.last(group).node) do
      %{start: start, end: stop}
    else
      _ -> nil
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

  defp do_body(body_kw) when is_list(body_kw) do
    Enum.find_value(body_kw, :skip, fn
      {{:__block__, _, [:do]}, value} -> {:ok, value}
      {:do, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp do_body(_), do: :skip

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "    " <> line
    end)
  end
end
