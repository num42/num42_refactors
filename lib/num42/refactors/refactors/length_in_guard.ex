defmodule Num42.Refactors.Refactors.LengthInGuard do
  @moduledoc """
  Eliminates `length/1` from `when` guards by splitting the guarded
  clause into N+1 explicit clauses: one per "smaller-than-required"
  size (each using the existing catch-all's body), plus the original
  clause with the var-slot constrained to a cons-tail "at-least-N"
  pattern and the `length` conjunct stripped.

      case node do
        %{type: :switch, cases: cases, default: d} when length(cases) >= 2 ->
          # body
        _ ->
          {:noreply, socket}
      end

      ↓

      case node do
        %{type: :switch, cases: [], default: d} ->
          {:noreply, socket}
        %{type: :switch, cases: [_], default: d} ->
          {:noreply, socket}
        %{type: :switch, cases: [_, _ | _] = cases, default: d} ->
          # body
        _ ->
          {:noreply, socket}
      end

  Same idea for `def`/`defp`:

      def f(list) when length(list) > 1, do: …
      def f(_), do: nil

      ↓

      def f([]), do: nil
      def f([_]), do: nil
      def f([_, _ | _] = list), do: …
      def f(_), do: nil

  ## Why this matters: clause-order invariance

  `length/1` in a guard walks the whole list O(n) every time the
  clause is considered — replacing with cons-pattern shapes is O(1).
  The bigger payoff is *clause-order invariance*: the rewritten
  clauses are pairwise disjoint by pattern, so reordering them does
  not change the dispatch outcome (modulo the catch-all which by
  convention stays last).

  ## Required: an existing catch-all

  We only fire when the surrounding clause-list (sibling `def` heads
  or sibling `case`/`with`/`receive` arms) contains a *catch-all*:
  a clause whose pattern is a bare variable or `_` and whose guard
  is empty. We use that catch-all's body verbatim for the synthesized
  fallback clauses. Without a catch-all we have no idea what should
  happen for the smaller sizes, so we skip — there are no FIXMEs in
  this refactor's output.

  ## Required: a top-level pattern slot for the variable

  The `length(x)` argument must be a name bound by the surrounding
  pattern. Supported slots:

  - bare-variable arg (`def f(list) when …`, `list when …` arm)
  - map-key arg (`%{cases: cases} when …`)

  Nested-deeper patterns (e.g. `%{row: %{slot_variants: v}} when …`)
  are skipped — the surgery gets noisy and the wins are marginal.

  ## What we match in the guard

  Guard *conjunct* of shape `length(var) <op> <int_literal>`:

  - `<op>` is `>` or `>=`
  - `<int_literal>` capped at `@max_n` (so we don't emit pages of clauses)
  - `var` resolves to a supported pattern slot in the head

  ## What we DON'T touch

  - `==`, `<`, `<=`, `!=` — those don't fit the
    "smaller-than-required" fallback model
  - non-literal RHS (`length(x) > @page_size`, `length(x) > limit`)
  - clauses with no surrounding catch-all

  ## Idempotence

  After a rewrite, the original clause has no `when length(...)`
  guard. The synthesized clauses use literal cons patterns. A second
  pass finds nothing. Safe to run repeatedly.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  @max_n 4

  @impl Num42.Refactors.Refactor
  def description,
    do: "Replace `length/1` guards with explicit pattern clauses + existing catch-all body"

  @impl Num42.Refactors.Refactor
  def priority, do: 120

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    `when length(list) > 0` walks the entire list at runtime just to
    check whether it has any elements — `O(n)` for a question pattern
    matching answers in `O(1)`. `[_ | _]` (non-empty) and `[]` (empty)
    are the patterns the BEAM is built around; using them lets the
    compiler dispatch by structure rather than by guard, which is
    faster *and* makes the function head say "for the empty case…"
    instead of "when the length is zero…".
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp bare_or_underscore?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp bare_or_underscore?(_), do: false

  defp body_text(body_ast, source),
    do: slice_node(source, body_ast) |> body_text_or_fallback(body_ast)

  defp build_patches(ast, source),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(
        &node_patches(
          &1,
          source
        )
      )

  defp case_clause_list_patches({tag, _meta, args}, source),
    do: extract_clauses(tag, args) |> clause_list_patches_or_skip(source)

  defp classify_guard(fn_args, guard),
    do: extract_length_conjunct(guard) |> classify_def_guard_with_conjunct(fn_args)

  defp classify_guard_arm(head_pat, guard),
    do: extract_length_conjunct(guard) |> classify_arm_guard_with_conjunct(head_pat)

  defp clause_list_patches(clauses, source) do
    catch_all = find_clause_list_catch_all(clauses)

    if catch_all do
      clauses
      |> Enum.flat_map(
        &case maybe_arm_patch(&1, catch_all, source) do
          nil -> []
          patch -> [patch]
        end
      )
    else
      []
    end
  end

  defp def_signature({def_kind, _, [{:when, _, [{name, _, args}, _g]} | _]})
       when def_kind?(def_kind) and is_atom(name) and is_list(args),
       do: {def_kind, name, length(args)}

  defp def_signature({def_kind, _, [{name, _, args} | _]})
       when def_kind?(def_kind) and is_atom(name) and is_list(args),
       do: {def_kind, name, length(args)}

  defp def_signature(_), do: nil

  defp do_extract({:and, _, [lhs, rhs]}), do: do_extract(lhs) |> combine_lhs_extract(lhs, rhs)

  defp do_extract({op, _, [{:length, _, [{var, _, ctx}]}, rhs]})
       when op in [:>, :>=] and is_atom(var) and is_atom(ctx) do
    rhs_int(rhs) |> wrap_extract_with_int(op, var)
  end

  defp do_extract(_), do: :skip
  defp do_keyword_kind(:do), do: :block

  defp do_keyword_kind({:__block__, meta, [:do]}) do
    if Keyword.get(meta, :format) == :keyword, do: :keyword, else: :block
  end

  defp extract_clauses(:case, [_subject, kws]) when is_list(kws),
    do: extract_clauses_from_kws(kws)

  defp extract_clauses(:with, args) when is_list(args),
    do: extract_clauses_from_kws(List.last(args) || [])

  defp extract_clauses(:receive, [kws]) when is_list(kws), do: extract_clauses_from_kws(kws)

  defp extract_clauses(:try, args) when is_list(args),
    do: extract_clauses_from_kws(List.last(args) || [])

  defp extract_clauses(_, _), do: :no

  defp extract_clauses_from_kws(fromed_kws) do
    fromed_kws
    |> Enum.find_value(:no, fn
      {{:__block__, _, [:do]} = key, clauses} when is_list(clauses) -> {:ok, key, clauses}
      {:do, clauses} when is_list(clauses) -> {:ok, :do, clauses}
      _ -> nil
    end)
  end

  defp extract_do_block_text({_, _, [_when, [{do_kw, body_ast}]]}, source),
    do: {do_keyword_kind(do_kw), body_text(body_ast, source)}

  defp extract_length_conjunct(guard), do: do_extract(guard)
  defp fallback_sizes(:>, n), do: 0..n
  defp fallback_sizes(:>=, n), do: 0..(n - 1)

  defp find_clause_list_catch_all(clauses) do
    clauses
    |> Enum.find_value(fn
      {:->, _, [[pat], body_ast]} ->
        if bare_or_underscore?(pat), do: body_ast, else: nil

      _ ->
        nil
    end)
  end

  defp find_def_catch_all(clauses) do
    clauses
    |> Enum.find_value(fn
      {def_kind, _, [{name, _, args}, [{do_kw, body_ast}]]}
      when def_kind?(def_kind) and is_atom(name) and is_list(args) ->
        if args |> Enum.all?(&bare_or_underscore?/1) do
          {do_keyword_kind(do_kw), body_ast}
        else
          nil
        end

      _ ->
        nil
    end)
  end

  defp find_var_arg(fn_args, var) do
    indexed = fn_args |> Enum.with_index()

    indexed
    |> Enum.find_value(:skip, fn
      {{name, _, ctx}, idx} when is_atom(name) and is_atom(ctx) ->
        if name == var, do: {:ok, idx}, else: nil

      _ ->
        nil
    end)
  end

  defp find_var_in_pattern({name, _, ctx}, var) when is_atom(name) and is_atom(ctx) do
    if name == var, do: {:ok, :bare}, else: :skip
  end

  defp find_var_in_pattern({:%{}, _, pairs}, var) do
    pairs
    |> Enum.find_value(:skip, fn
      {key_ast, {name, _, ctx}} when is_atom(name) and is_atom(ctx) ->
        if name == var do
          case map_key_atom(key_ast) do
            {:ok, atom} -> {:ok, {:map_key, atom}}
            :skip -> :skip
          end
        else
          nil
        end

      _ ->
        nil
    end)
  end

  defp find_var_in_pattern({:=, _, [lhs, rhs]}, var),
    do: find_var_in_pattern(lhs, var) |> find_var_or_recurse_rhs(rhs, var)

  defp find_var_in_pattern(_, _), do: :skip

  defp fn_clause_list_patches({:fn, _meta, clauses}, source),
    do: clauses |> clause_list_patches(source)

  defp indent(text) do
    String.split(text, "\n")
    |> Enum.map_join(
      "\n",
      &if &1 == "" do
        ""
      else
        "  " <> &1
      end
    )
  end

  defp list_pattern_ast(0), do: {:__block__, [], [[]]}

  defp list_pattern_ast(n) when n > 0 do
    underscores = List.duplicate({:_, [], nil}, n)
    {:__block__, [], [underscores]}
  end

  defp list_pattern_ast_lower_bound(n) when n >= 1 do
    # The bracket-list cons syntax in Elixir AST: `[a, b | tail]` is
    # `[a, b, {:|, _, [c, tail]}]` — the LAST element is a `:|` 2-tuple
    # whose first slot is the (n-th) trailing element and whose second
    # slot is the rest-tail. So we need `n - 1` leading `_` plus a
    # cons whose head is the n-th `_`.
    leading = List.duplicate({:_, [], nil}, n - 1)
    cons = {:|, [], [{:_, [], nil}, {:_, [], nil}]}
    {:__block__, [], [leading ++ [cons]]}
  end

  defp list_pattern_text(0), do: "[]"

  defp list_pattern_text(n) do
    underscores = List.duplicate("_", n)
    "[" <> Enum.join(underscores, ", ") <> "]"
  end

  defp list_pattern_text_lower_bound(n) when n >= 1 do
    underscores = List.duplicate("_", n)
    "[" <> Enum.join(underscores, ", ") <> " | _]"
  end

  defp lower_bound(:>, n), do: n + 1
  defp lower_bound(:>=, n), do: n
  defp map_key_atom({:__block__, _, [atom]}) when is_atom(atom), do: {:ok, atom}
  defp map_key_atom(atom) when is_atom(atom), do: {:ok, atom}
  defp map_key_atom(_), do: :skip

  defp maybe_arm_patch(
         {:->, _, [[{:when, _, [head_pat, guard]}], _body]} = arm_node,
         catch_all_body_ast,
         source
       ),
       do:
         classify_guard_arm(head_pat, guard)
         |> arm_patch_or_nil(arm_node, catch_all_body_ast, head_pat, source)

  defp maybe_arm_patch(_, _, _), do: nil

  defp maybe_def_clause_patch(
         {def_kind, _,
          [
            {:when, _, [{name, _, fn_args}, guard]},
            [{do_kw, _body_ast}]
          ]} = node,
         def_kind,
         name,
         arity,
         {catch_all_kind, catch_all_body_ast},
         source
       )
       when length(fn_args) == arity do
    classify_guard(fn_args, guard)
    |> def_clause_patch_or_nil(
      catch_all_body_ast,
      catch_all_kind,
      def_kind,
      do_kw,
      fn_args,
      name,
      node,
      source
    )
  end

  defp maybe_def_clause_patch(_, _, _, _, _, _), do: nil

  defp module_def_patches(exprs, source) do
    grouped = exprs |> Enum.group_by(&def_signature/1)

    grouped
    |> Enum.flat_map(fn
      {nil, _} ->
        []

      {{def_kind, name, arity}, clauses} ->
        process_def_group(clauses, def_kind, name, arity, source)
    end)
  end

  defp node_patches({:defmodule, _, [_name, [{_do_kw, body}]]}, source) do
    toed_expr = body_to_exprs(body)
    module_def_patches(toed_expr, source)
  end

  defp node_patches({tag, _, args} = node, source)
       when tag in [:case, :with, :receive, :try] and is_list(args) do
    case_clause_list_patches(node, source)
  end

  defp node_patches({:fn, _, _} = node, source), do: fn_clause_list_patches(node, source)
  defp node_patches(_, _), do: []

  defp process_def_group(clauses, def_kind, name, arity, source) do
    catch_all = find_def_catch_all(clauses)

    if catch_all do
      clauses
      |> Enum.flat_map(
        &case maybe_def_clause_patch(&1, def_kind, name, arity, catch_all, source) do
          nil -> []
          patch -> [patch]
        end
      )
    else
      []
    end
  end

  defp render_arg(arg, source), do: slice_node(source, arg) |> arg_text_or_fallback(arg)

  defp render_arm_split(arm_node, head_pat, var_path, sizes, catch_all_body_ast,
         op: op,
         n: n,
         remaining_guard: remaining_guard,
         source: source
       ) do
    {:->, _, [[{:when, _, _}], orig_body_ast]} = arm_node

    catch_all_body_text = body_text(catch_all_body_ast, source)
    orig_body_text = body_text(orig_body_ast, source)

    fallback_arms =
      sizes
      |> Enum.map(fn size ->
        new_pat = replace_var_in_pattern(head_pat, var_path, list_pattern_ast(size))
        pat_text = Sourceror.to_string(new_pat)
        "#{pat_text} ->\n#{indent(catch_all_body_text)}"
      end)

    bound = lower_bound(op, n)
    bound_shape = list_pattern_ast_lower_bound(bound)
    constrained_pat = replace_var_in_pattern_keep_binding(head_pat, var_path, bound_shape)
    constrained_pat_text = Sourceror.to_string(constrained_pat)

    original_head =
      case remaining_guard do
        nil -> constrained_pat_text
        g -> "#{constrained_pat_text} when #{Sourceror.to_string(g)}"
      end

    original_arm = "#{original_head} ->\n#{indent(orig_body_text)}"

    (fallback_arms ++ [original_arm]) |> Enum.join("\n\n")
  end

  defp render_constrained_original_def(orig_node, def_kind, name, fn_args, var_index,
         op: op,
         n: n,
         remaining_guard: remaining_guard,
         source: source
       ) do
    var_node = fn_args |> Enum.at(var_index)
    bound = lower_bound(op, n)
    constrained_arg_text = "#{list_pattern_text_lower_bound(bound)} = #{var_node_text(var_node)}"
    indexed_args = fn_args |> Enum.with_index()

    args_text =
      indexed_args
      |> Enum.map_join(", ", fn
        {_, ^var_index} -> constrained_arg_text
        {arg, _} -> render_arg(arg, source)
      end)

    {do_kind, body_text} = extract_do_block_text(orig_node, source)
    head_text = "#{def_kind} #{name}(#{args_text})"

    head_with_guard =
      case remaining_guard do
        nil -> head_text
        g -> "#{head_text} when #{Sourceror.to_string(g)}"
      end

    render_with_body(head_with_guard, do_kind, body_text)
  end

  defp render_def_fallback_args(arity, var_index, shape_text) do
    indices = 0..(arity - 1)

    parts =
      indices |> Enum.map(&if(&1 == var_index, do: shape_text, else: "_"))

    parts |> Enum.join(", ")
  end

  defp render_def_split(orig_node, def_kind, name, fn_args, var_index, sizes,
         op: op,
         n: n,
         remaining_guard: remaining_guard,
         catch_all_kind: catch_all_kind,
         catch_all_body_ast: catch_all_body_ast,
         do_kw: _do_kw,
         source: source
       ) do
    arity = length(fn_args)
    catch_all_body_text = body_text(catch_all_body_ast, source)

    fallback_clauses =
      sizes
      |> Enum.map(fn size ->
        shape_text = list_pattern_text(size)
        args_text = render_def_fallback_args(arity, var_index, shape_text)
        head_text = "#{def_kind} #{name}(#{args_text})"
        render_with_body(head_text, catch_all_kind, catch_all_body_text)
      end)

    original =
      render_constrained_original_def(orig_node, def_kind, name, fn_args, var_index,
        op: op,
        n: n,
        remaining_guard: remaining_guard,
        source: source
      )

    (fallback_clauses ++ [original]) |> Enum.join("\n\n")
  end

  defp render_with_body(head_text, :keyword, body_text), do: "#{head_text}, do: #{body_text}"

  defp render_with_body(head_text, :block, body_text),
    do: "#{head_text} do\n#{indent(body_text)}\nend"

  defp replace_pair_value({key_ast, {var_name, _, ctx}} = pair, target_atom, shape)
       when is_atom(var_name) and is_atom(ctx) do
    map_key_atom(key_ast) |> handle_map_key_atom(key_ast, pair, shape, target_atom)
  end

  defp replace_pair_value(other, _, _), do: other

  defp replace_pair_value_keep_binding(
         {key_ast, {_var_name, _, ctx} = var_node} = pair,
         target_atom,
         shape
       )
       when is_atom(ctx) do
    map_key_atom(key_ast) |> handle_map_key_atom_2(key_ast, pair, shape, target_atom, var_node)
  end

  defp replace_pair_value_keep_binding(other, _, _), do: other
  defp replace_var_in_pattern({_name, _meta, _ctx}, :bare, shape), do: shape

  defp replace_var_in_pattern({:%{}, meta, pairs}, {:map_key, target_atom}, shape) do
    new_pairs = pairs |> Enum.map(&replace_pair_value(&1, target_atom, shape))
    {:%{}, meta, new_pairs}
  end

  defp replace_var_in_pattern({:=, meta, [lhs, rhs]}, var_path, shape),
    do: {:=, meta, [replace_var_in_pattern(lhs, var_path, shape), rhs]}

  defp replace_var_in_pattern(other, _, _), do: other

  defp replace_var_in_pattern_keep_binding({name, _, ctx} = var_node, :bare, shape)
       when is_atom(name) and is_atom(ctx) do
    {:=, [], [shape, var_node]}
  end

  defp replace_var_in_pattern_keep_binding({:%{}, meta, pairs}, {:map_key, target_atom}, shape) do
    new_pairs =
      pairs |> Enum.map(&replace_pair_value_keep_binding(&1, target_atom, shape))

    {:%{}, meta, new_pairs}
  end

  defp replace_var_in_pattern_keep_binding({:=, meta, [lhs, rhs]}, var_path, shape),
    do: {:=, meta, [replace_var_in_pattern_keep_binding(lhs, var_path, shape), rhs]}

  defp replace_var_in_pattern_keep_binding(other, _, _), do: other
  defp rhs_int(n) when is_integer(n), do: {:ok, n}
  defp rhs_int({:__block__, _, [n]}) when is_integer(n), do: {:ok, n}
  defp rhs_int(_), do: :skip

  defp supported?(:>, n) when n >= 0 and n <= @max_n - 1, do: true
  defp supported?(:>=, n) when n >= 1 and n <= @max_n, do: true
  defp supported?(_, _), do: false

  defp var_node_text({name, _, ctx}) when is_atom(name) and is_atom(ctx),
    do: Atom.to_string(name)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> handle_build_patches(source)

  defp apply_patches({:error, _}, source), do: source

  defp body_text_or_fallback({:ok, text}, _body_ast), do: text

  defp body_text_or_fallback(:error, body_ast), do: body_ast |> Sourceror.to_string()

  defp clause_list_patches_or_skip(:no, _source), do: []

  defp clause_list_patches_or_skip({:ok, _do_arg, clauses}, source),
    do: clauses |> clause_list_patches(source)

  defp classify_def_guard_with_conjunct(:skip, _fn_args), do: :skip

  defp classify_def_guard_with_conjunct({:ok, var, op, n, remaining_guard}, fn_args) do
    with {:ok, idx} <- find_var_arg(fn_args, var),
         true <- supported?(op, n) do
      {:ok, idx, op, n, remaining_guard}
    else
      _ -> :skip
    end
  end

  defp classify_arm_guard_with_conjunct(:skip, _head_pat), do: :skip

  defp classify_arm_guard_with_conjunct(
         {:ok, var, op, n, remaining_guard},
         head_pat
       ) do
    with {:ok, path} <- find_var_in_pattern(head_pat, var),
         true <- supported?(op, n) do
      {:ok, path, op, n, remaining_guard}
    else
      _ -> :skip
    end
  end

  defp combine_lhs_extract({:ok, var, op, n, nil}, _lhs, rhs), do: {:ok, var, op, n, rhs}

  defp combine_lhs_extract({:ok, var, op, n, lhs_rest}, _lhs, rhs),
    do: {:ok, var, op, n, {:and, [], [lhs_rest, rhs]}}

  defp combine_lhs_extract(:skip, lhs, rhs), do: do_extract(rhs) |> handle_do_extract(lhs)

  defp wrap_extract_with_int({:ok, n}, op, var), do: {:ok, var, op, n, nil}

  defp wrap_extract_with_int(:skip, _op, _var), do: :skip

  defp find_var_or_recurse_rhs({:ok, _} = ok, _rhs, _var), do: ok

  defp find_var_or_recurse_rhs(:skip, rhs, var), do: rhs |> find_var_in_pattern(var)

  defp arm_patch_or_nil(
         :skip,
         _arm_node,
         _catch_all_body_ast,
         _head_pat,
         _source
       ),
       do: nil

  defp arm_patch_or_nil(
         {:ok, var_path, op, n, remaining_guard},
         arm_node,
         catch_all_body_ast,
         head_pat,
         source
       ) do
    sizes = fallback_sizes(op, n) |> Enum.to_list()

    rendered =
      render_arm_split(arm_node, head_pat, var_path, sizes, catch_all_body_ast,
        op: op,
        n: n,
        remaining_guard: remaining_guard,
        source: source
      )

    Patch.replace(arm_node, rendered)
  end

  defp def_clause_patch_or_nil(
         :skip,
         _catch_all_body_ast,
         _catch_all_kind,
         _def_kind,
         _do_kw,
         _fn_args,
         _name,
         _node,
         _source
       ),
       do: nil

  defp def_clause_patch_or_nil(
         {:ok, var_index, op, n, remaining_guard},
         catch_all_body_ast,
         catch_all_kind,
         def_kind,
         do_kw,
         fn_args,
         name,
         node,
         source
       ) do
    sizes = fallback_sizes(op, n) |> Enum.to_list()

    rendered =
      render_def_split(node, def_kind, name, fn_args, var_index, sizes,
        op: op,
        n: n,
        remaining_guard: remaining_guard,
        catch_all_kind: catch_all_kind,
        catch_all_body_ast: catch_all_body_ast,
        do_kw: do_kw,
        source: source
      )

    Patch.replace(node, rendered)
  end

  defp arg_text_or_fallback({:ok, text}, _arg), do: text

  defp arg_text_or_fallback(:error, arg), do: arg |> Sourceror.to_string()

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_map_key_atom({:ok, atom}, key_ast, _pair, shape, target_atom)
       when atom == target_atom do
    {key_ast, shape}
  end

  defp handle_map_key_atom(_, _key_ast, pair, _shape, _target_atom), do: pair

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_map_key_atom_2({:ok, atom}, key_ast, _pair, shape, target_atom, var_node)
       when atom == target_atom do
    {key_ast, {:=, [], [shape, var_node]}}
  end

  defp handle_map_key_atom_2(_, _key_ast, pair, _shape, _target_atom, _var_node), do: pair

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_build_patches([], source), do: source

  defp handle_build_patches(patches, source), do: source |> Sourceror.patch_string(patches)

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_do_extract({:ok, var, op, n, nil}, lhs), do: {:ok, var, op, n, lhs}

  defp handle_do_extract({:ok, var, op, n, rhs_rest}, lhs),
    do: {:ok, var, op, n, {:and, [], [lhs, rhs_rest]}}

  defp handle_do_extract(:skip, _lhs), do: :skip
end
