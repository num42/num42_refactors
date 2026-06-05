defmodule Number42.Refactors.Ex.DedupeClausePrologue do
  @moduledoc """
  Lifts an identical leading prologue shared by every clause of a
  multi-clause function into a single generic clause, dispatching the
  divergent tails to a `defp` that re-matches the original heads.

      # before
      def handle(:a, x) do
        log(x)
        check(x)
        do_a(x)
      end

      def handle(:b, x) do
        log(x)
        check(x)
        do_b(x)
      end

      # after
      def handle(arg1, x) do
        log(x)
        check(x)
        handle_dispatch(arg1, x)
      end

      defp handle_dispatch(:a, x) do
        do_a(x)
      end

      defp handle_dispatch(:b, x) do
        do_b(x)
      end

  ## How a function qualifies

  All clauses of one `name`/arity group are considered together:

  - **≥ 2 clauses.** A single-clause function has no shared prologue.
  - **Shared prologue.** The longest common leading run of
    AST-identical statements across *every* clause, at least
    `:min_prolog_statements` long (default `2`).
  - **Divergent tail.** At least one clause must have a non-empty tail
    after the prologue — a group whose bodies are wholly identical is a
    different refactor's concern (clause merge), not prologue dedup.
  - **Prologue variable safety.** Every variable the prologue *reads*
    must be bound identically (same bare parameter, same position) in
    every clause. A prologue that depends on a value pattern-matched
    differently per clause can't run before dispatch — skip.

  ## Generic clause & dispatch

  - **Generic parameters.** Per position: if every clause has the *same
    bare variable* there, that name is kept; otherwise a fresh
    non-colliding `argN` name is introduced and that position becomes
    dispatch-relevant.
  - **Dispatch arguments.** The generic parameters, in order, plus any
    prologue-bound variables a tail still reads (threaded through so the
    dispatch sees them).
  - **Dispatch clauses.** The original heads — patterns *and* guards
    preserved — with the divergent tail as their body. A clause whose
    only divergence is its guard keeps its bare params and carries the
    guard onto the dispatch.

  ## Pass scope & idempotence

  Every eligible `name`/arity group in the module is deduped in a single
  pass. After dedup the generic clause ends in a `*_dispatch(...)` call
  and there is exactly one public clause, so a second pass finds no
  multi-clause group with a shared prologue to lift.
  """

  use Number42.Refactors.Refactor

  @control_flow_forms ~w(raise throw exit with case cond if unless try for fn receive)a

  @impl Number42.Refactors.Refactor
  def description,
    do: "Lift a shared clause prologue into a generic clause dispatching the divergent tails"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    When every clause of a multi-clause function opens with the same run
    of statements, that prologue is duplicated work obscuring what
    actually differs between clauses. Lifting it into one generic clause
    that runs the prologue and then dispatches to a `defp` re-matching
    the original heads removes the duplication and isolates the dispatch.
    Patterns and guards are preserved on the dispatch; a prologue that
    depends on per-clause-divergent bindings is left alone.
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
        dedupe_module(mod_ast, source, opts)

      _ ->
        nil
    end)
  end

  defp dedupe_module(mod_ast, source, opts) do
    body_exprs = module_body_exprs(mod_ast)

    case body_exprs && eligible_patches(body_exprs, source, opts) do
      [_ | _] = patches -> patch_or_passthrough(source, patches)
      _ -> nil
    end
  end

  defp eligible_patches(body_exprs, source, opts) do
    min_prolog = Keyword.get(opts, :min_prolog_statements, 2)
    existing = def_names(body_exprs)

    body_exprs
    |> clause_groups()
    |> Enum.flat_map(fn group -> dedupe_group(group, existing, min_prolog, source) end)
  end

  # --- grouping clauses by name/arity, preserving source order ---

  # A group is the contiguous run of def-clauses sharing one name/arity.
  # Non-contiguous groups (interrupted by another def) are skipped — the
  # generic-clause rewrite must replace a single contiguous block.
  defp clause_groups(body_exprs) do
    body_exprs
    |> Enum.chunk_by(&clause_key/1)
    |> Enum.filter(fn
      [first | _] = chunk -> clause_key(first) != nil and length(chunk) >= 2
      _ -> false
    end)
  end

  defp clause_key({:def, _, [head | _]}) do
    case extract_fn_signature(strip_when(head)) do
      {name, args} -> {:def, name, length(args)}
      _ -> nil
    end
  end

  defp clause_key(_), do: nil

  # --- per-group dedup ---

  defp dedupe_group(clauses, existing, min_prolog, source) do
    with {:ok, parsed} <- parse_clauses(clauses),
         :ok <- ensure_no_control_flow(parsed),
         {fn_name, arity} <- name_arity(parsed),
         {:ok, prolog_len} <- shared_prolog_length(parsed, min_prolog),
         {:ok, generic_params, dispatch_relevant} <- generic_params(parsed, arity),
         :ok <- prologue_safe?(parsed, prolog_len, generic_params, dispatch_relevant),
         true <- divergent_tail?(parsed, prolog_len),
         dispatch_name = :"#{fn_name}_dispatch",
         false <- MapSet.member?(existing, dispatch_name),
         carried = carried_bindings(parsed, prolog_len),
         {:ok, patch} <-
           build_dedupe(
             clauses,
             parsed,
             prolog_len,
             generic_params,
             dispatch_name,
             carried,
             source
           ) do
      [patch]
    else
      _ -> []
    end
  end

  defp parse_clauses(clauses) do
    parsed =
      Enum.map(clauses, fn {:def, _, [head, body_kw]} ->
        {bare_head, guard} = split_guard(head)

        with {name, params} <- extract_fn_signature(bare_head),
             {:ok, body} <- do_body(body_kw) do
          %{name: name, params: params, guard: guard, stmts: body_to_exprs(body)}
        else
          _ -> :error
        end
      end)

    if Enum.all?(parsed, &is_map/1), do: {:ok, parsed}, else: :skip
  end

  defp ensure_no_control_flow(parsed) do
    any_cf? =
      Enum.any?(parsed, fn %{stmts: stmts} ->
        Enum.any?(stmts, &has_control_flow?/1)
      end)

    if any_cf?, do: :skip, else: :ok
  end

  defp name_arity([%{name: name, params: params} | _]), do: {name, length(params)}

  # The length of the longest leading run of AST-identical statements
  # across every clause (ignoring metadata), if it meets the floor.
  defp shared_prolog_length(parsed, min_prolog) do
    max_len = parsed |> Enum.map(&length(&1.stmts)) |> Enum.min()

    len =
      Enum.reduce_while(0..(max_len - 1)//1, 0, fn i, acc ->
        if all_agree_at?(parsed, i), do: {:cont, acc + 1}, else: {:halt, acc}
      end)

    if len >= min_prolog, do: {:ok, len}, else: :skip
  end

  defp all_agree_at?([%{stmts: first} | _] = parsed, i) do
    ref = first |> Enum.at(i) |> strip_meta()
    Enum.all?(parsed, fn %{stmts: s} -> strip_meta(Enum.at(s, i)) == ref end)
  end

  # Per position, the generic parameter name and whether the position is
  # dispatch-relevant. A position is dispatch-relevant only when its
  # *pattern* diverges across clauses (→ fresh name, re-match in
  # dispatch). Guard divergence does NOT make a position relevant: the
  # params stay identical bare vars (so the prologue may read them) and
  # the guards travel onto the dispatch clauses independently.
  defp generic_params(parsed, arity) do
    taken = used_names(parsed)

    {names, relevant, _taken} =
      Enum.reduce(0..(arity - 1)//1, {[], [], taken}, fn pos, {names, rel, taken} ->
        column = Enum.map(parsed, fn %{params: p} -> Enum.at(p, pos) end)

        case common_bare_var(column) do
          {:ok, name} ->
            {[name | names], rel, taken}

          :divergent ->
            fresh = fresh_name(pos, taken)
            {[fresh | names], [pos | rel], MapSet.put(taken, fresh)}
        end
      end)

    names = Enum.reverse(names)
    {:ok, names, MapSet.new(Enum.reverse(relevant))}
  end

  # Every variable read by the prologue must be a generic parameter that
  # is NOT dispatch-relevant (i.e. bound identically in every clause).
  defp prologue_safe?(parsed, prolog_len, generic_params, dispatch_relevant) do
    [%{stmts: first} | _] = parsed
    prologue = Enum.take(first, prolog_len)

    stable =
      generic_params
      |> Enum.with_index()
      |> Enum.reject(fn {_name, pos} -> MapSet.member?(dispatch_relevant, pos) end)
      |> Enum.map(fn {name, _pos} -> name end)
      |> MapSet.new()

    reads =
      prologue
      |> Enum.reduce(MapSet.new(), fn s, acc -> MapSet.union(acc, free_in(s)) end)

    if MapSet.subset?(reads, MapSet.union(stable, prologue_internal_binds(prologue))),
      do: :ok,
      else: :skip
  end

  defp prologue_internal_binds(prologue) do
    Enum.reduce(prologue, MapSet.new(), fn s, acc -> MapSet.union(acc, bound_in(s)) end)
  end

  defp divergent_tail?(parsed, prolog_len) do
    Enum.any?(parsed, fn %{stmts: stmts} -> length(stmts) > prolog_len end)
  end

  # Prologue-bound names that a tail still reads → thread through dispatch.
  defp carried_bindings(parsed, prolog_len) do
    [%{stmts: first} | _] = parsed
    bound = first |> Enum.take(prolog_len) |> prologue_internal_binds()

    read_by_tail =
      parsed
      |> Enum.flat_map(fn %{stmts: s} ->
        s |> Enum.drop(prolog_len) |> Enum.flat_map(&MapSet.to_list(free_in(&1)))
      end)
      |> MapSet.new()

    bound |> MapSet.intersection(read_by_tail) |> MapSet.to_list() |> Enum.sort()
  end

  # --- patch construction ---

  defp build_dedupe(clauses, parsed, prolog_len, generic_params, dispatch_name, carried, _source) do
    [%{name: fn_name, stmts: first} | _] = parsed
    prologue = Enum.take(first, prolog_len)

    dispatch_args =
      Enum.map(generic_params, &Atom.to_string/1) ++ Enum.map(carried, &Atom.to_string/1)

    generic_clause =
      render_generic_clause(fn_name, generic_params, prologue, dispatch_name, dispatch_args)

    dispatch_clauses =
      Enum.map(parsed, fn clause ->
        render_dispatch_clause(clause, prolog_len, dispatch_name, carried)
      end)

    case group_range(clauses) do
      %{} = range ->
        text = Enum.join([generic_clause | dispatch_clauses], "\n\n")
        {:ok, %{change: text, range: range}}

      _ ->
        :skip
    end
  end

  defp render_generic_clause(fn_name, generic_params, prologue, dispatch_name, dispatch_args) do
    params = Enum.map_join(generic_params, ", ", &Atom.to_string/1)
    prologue_text = Enum.map_join(prologue, "\n", &Sourceror.to_string/1)
    call = "#{dispatch_name}(#{Enum.join(dispatch_args, ", ")})"

    "  def #{fn_name}(#{params}) do\n" <>
      indent(prologue_text <> "\n" <> call) <>
      "\n  end"
  end

  defp render_dispatch_clause(
         %{params: params, guard: guard, stmts: stmts},
         prolog_len,
         dispatch_name,
         carried
       ) do
    head_params =
      (Enum.map(params, &Sourceror.to_string/1) ++ Enum.map(carried, &Atom.to_string/1))
      |> Enum.join(", ")

    guard_text = guard_suffix(guard)
    tail_text = stmts |> Enum.drop(prolog_len) |> Enum.map_join("\n", &Sourceror.to_string/1)

    "  defp #{dispatch_name}(#{head_params})#{guard_text} do\n" <>
      indent(tail_text) <>
      "\n  end"
  end

  defp guard_suffix(nil), do: ""
  defp guard_suffix(guard), do: " when #{Sourceror.to_string(guard)}"

  # --- analysis helpers ---

  defp common_bare_var(column) do
    names =
      Enum.map(column, fn node ->
        case bare_var(node) do
          {:ok, name} -> name
          :skip -> :__pattern__
        end
      end)

    case Enum.uniq(names) do
      [name] when name != :__pattern__ -> {:ok, name}
      _ -> :divergent
    end
  end

  defp split_guard({:when, _, [inner, guard]}), do: {inner, guard}
  defp split_guard(head), do: {head, nil}

  defp free_in(expr), do: MapSet.difference(used_var_names(expr), bound_in(expr))

  defp used_names(parsed) do
    parsed
    |> Enum.flat_map(fn %{params: p, stmts: s, guard: g} ->
      nodes = p ++ s ++ List.wrap(g)
      Enum.flat_map(nodes, &MapSet.to_list(used_var_names(&1)))
    end)
    |> MapSet.new()
  end

  defp fresh_name(pos, taken) do
    base = :"arg#{pos + 1}"
    if MapSet.member?(taken, base), do: fresh_name_n(pos, 1, taken), else: base
  end

  defp fresh_name_n(pos, n, taken) do
    candidate = :"arg#{pos + 1}_#{n}"
    if MapSet.member?(taken, candidate), do: fresh_name_n(pos, n + 1, taken), else: candidate
  end

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

  defp group_range(clauses) do
    with %{start: start} <- Sourceror.get_range(List.first(clauses)),
         %{end: stop} <- Sourceror.get_range(List.last(clauses)) do
      %{start: start, end: stop}
    else
      _ -> nil
    end
  end

  # --- shared helpers ---

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
    body_kw
    |> Enum.find_value(:skip, fn
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

  defp patch_or_passthrough(source, patches), do: Sourceror.patch_string(source, patches)
end
