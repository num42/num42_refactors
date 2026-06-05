defmodule Number42.Refactors.Ex.ConsolidateParallelClauseFunctions do
  @moduledoc """
  Higher-order consolidation of two functions whose bodies share an
  identical AST skeleton differing in **exactly one function reference**
  (a `&name/arity` / `&Mod.name/arity` capture) at the **same**
  structural position.

      # before
      defmodule MyApp.Stats do
        def sum_active(xs), do: Enum.filter(xs, &active?/1) |> Enum.sum()
        def sum_pending(xs), do: Enum.filter(xs, &pending?/1) |> Enum.sum()
      end

      # after
      defmodule MyApp.Stats do
        defp sum_by(xs, pred), do: Enum.filter(xs, pred) |> Enum.sum()
        def sum_active(xs), do: sum_by(xs, &active?/1)
        def sum_pending(xs), do: sum_by(xs, &pending?/1)
      end

  This is the function-reference analogue of `ExtractParametricClone`,
  which parametrises on differing **literals**. Here the divergent
  subterm is a capture, so the synthesised helper takes the captured
  function as an extra `pred` parameter and the originals become thin
  wrappers passing their own capture.

  ## Public-wrapper rule

  Public (`def`) originals MUST stay as public wrappers calling the new
  helper — removing the public API would be a cross-module break. The
  synthesised helper is always `defp` (an internal detail). `defp`
  originals also keep wrappers: the uniform "helper + two wrappers"
  shape is the safe, idempotent choice regardless of visibility.

  ## Skip list (source left unchanged when any holds)

  - **Not exactly one differing capture.** The two bodies must be
    AST-equal except for one position, and that position must hold a
    bare capture (`&name/arity` or `&Mod.name/arity`) in *both*
    functions. Differ in more than one position, or in a non-capture
    subterm (a literal, a different call shape) → skip. Literal-only
    divergence is `ExtractParametricClone`'s job, not this one.
  - **Partial-application captures.** Only bare `&name/arity` /
    `&Mod.name/arity` are handled. `&active?(&1, ctx)` and friends are
    skipped: their free vars (`ctx`) would need co-parameterisation,
    which v1 does not attempt.
  - **Head shape.** Both functions must be single-clause, guard-free,
    same arity, with identical bare-variable parameter lists (so the
    shared helper can take the same params plus the pred). Multi-clause,
    guarded, pattern/default params, or `defmacro`/`defmacrop` → skip.
  - **Helper-name collision.** The synthesised helper name (a common
    prefix of the two function names, else `<name>_by`) must not clash
    with any existing function in the module; a fresh, non-colliding
    `pred` parameter name is likewise chosen. If a clean name can't be
    found → skip.
  - **Already consolidated.** If the two bodies are *already* a single
    call to a same-arity local helper differing only in the capture arg
    (i.e. the output of this refactor), they are left alone — there is
    no shared structure left to lift. This keeps the pass idempotent:
    the emitted wrappers are never re-consolidated into another layer.

  ## v1 scope

  Only a single matching **pair** is consolidated per module per pass.
  Three or more parallel functions are handled across successive passes
  is *not* attempted — exactly the first eligible pair (in source order)
  is consolidated; the rest are left for a future pass / version.
  """

  use Number42.Refactors.Refactor

  @impl Number42.Refactors.Refactor
  def description,
    do: "Consolidate two functions differing in one captured function reference into a helper"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Find two single-clause, guard-free, same-arity functions whose
    bodies are identical except for exactly one `&name/arity` capture at
    the same position. Synthesise a `defp` helper taking the original
    params plus a fresh `pred` param (the capture position replaced by
    that param) and rewrite both originals into thin wrappers that pass
    their own capture. Public defs stay public wrappers. Skips partial
    applications, differing arities, multi-clause/guarded/pattern heads,
    macros, and name collisions.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts),
    do: Sourceror.parse_string(source) |> apply_to_parse_result(source)

  defp apply_to_parse_result({:ok, ast}, source), do: apply_to_ast(ast, source)
  defp apply_to_parse_result({:error, _}, source), do: source

  defp apply_to_ast(ast, source) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value(:no_match, fn
      {:defmodule, _, [_name, [{_do, body}]]} = mod_node ->
        body |> body_to_exprs() |> patches_for_module(mod_node)

      _ ->
        nil
    end)
    |> patch_or_passthrough(source)
  end

  defp patch_or_passthrough(:no_match, source), do: source
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  # Returns the patch list for the first eligible pair, `nil` to keep
  # scanning further modules, or `[]` to stop with no rewrite.
  defp patches_for_module(body_exprs, mod_node) do
    existing_names = existing_def_names(body_exprs)
    multi_clause = multi_clause_names(body_exprs)

    candidates =
      body_exprs
      |> Enum.filter(&eligible_def?/1)
      |> Enum.reject(&MapSet.member?(multi_clause, def_name(&1)))

    candidates
    |> pairs()
    |> Enum.find_value(fn {a, b} ->
      consolidate_pair(a, b, mod_node, existing_names)
    end)
  end

  defp consolidate_pair(a, b, mod_node, existing_names) do
    with {name_a, args_a} <- def_signature(a),
         {name_b, args_b} <- def_signature(b),
         true <- same_param_shape?(args_a, args_b),
         body_a when not is_nil(body_a) <- def_body(a),
         body_b when not is_nil(body_b) <- def_body(b),
         {:ok, path} <- single_differing_capture_path(body_a, body_b),
         false <- already_consolidated?(body_a, body_b, path, existing_names),
         {:ok, helper_name} <- synth_helper_name(name_a, name_b, existing_names),
         param_names = bare_arg_names(args_a),
         {:ok, pred_name} <- fresh_pred_name(param_names, body_a) do
      emit({a, b}, {body_a, body_b}, path, args_a, {helper_name, pred_name}, mod_node)
    else
      _ -> nil
    end
  end

  defp emit({a, b}, {body_a, body_b}, path, args_a, {helper_name, pred_name}, mod_node) do
    helper_body = replace_at_path(body_a, path, {pred_name, [], nil})
    helper_args = args_a ++ [{pred_name, [], nil}]
    arg_refs = bare_arg_names(args_a) |> Enum.map(&{&1, [], nil})

    [
      helper_insert_patch(mod_node, helper_name, helper_args, helper_body),
      wrapper_patch(a, helper_name, arg_refs, at_path(body_a, path)),
      wrapper_patch(b, helper_name, arg_refs, at_path(body_b, path))
    ]
  end

  # --- eligibility -----------------------------------------------------

  defp eligible_def?({kind, _, [head, body_kw]})
       when kind in [:def, :defp] and is_list(body_kw) do
    not guarded?(head) and bare_var_head?(head)
  end

  defp eligible_def?(_), do: false

  defp guarded?({:when, _, _}), do: true
  defp guarded?(_), do: false

  defp bare_var_head?({name, _, args}) when is_atom(name) and is_list(args),
    do: Enum.all?(args, &bare_param?/1)

  defp bare_var_head?({name, _, nil}) when is_atom(name), do: true
  defp bare_var_head?(_), do: false

  defp bare_param?({:\\, _, _}), do: false

  defp bare_param?({name, _, ctx}) when is_atom(name) and is_atom(ctx),
    do: not underscore?(name)

  defp bare_param?(_), do: false

  # `eligible_def?` already filtered out multi-clause sets by name —
  # done here so a function whose name appears twice (multi-clause) is
  # never a candidate.
  defp existing_def_names(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {kind, _, [head | _]} when kind in [:def, :defp] ->
        case extract_fn_signature(strip_when(head)) do
          {name, _args} -> [name]
          :error -> []
        end

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp multi_clause_names(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {kind, _, [head | _]} when kind in [:def, :defp] ->
        case extract_fn_signature(strip_when(head)) do
          {name, args} when is_list(args) -> [{name, length(args)}]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {{name, _arity}, count} when count > 1 -> [name]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp def_name({_kind, _, [head | _]}) do
    case extract_fn_signature(strip_when(head)) do
      {name, _args} -> name
      :error -> nil
    end
  end

  defp def_signature({_kind, _, [head, _body]}) do
    case extract_fn_signature(head) do
      {name, args} when is_list(args) -> {name, args}
      _ -> :error
    end
  end

  defp def_body({_kind, _, [_head, body_kw]}) do
    body_kw
    |> Enum.find_value(nil, fn
      {{:__block__, _, [:do]}, value} -> value
      {:do, value} -> value
      _ -> nil
    end)
  end

  defp same_param_shape?(args_a, args_b) do
    length(args_a) == length(args_b) and
      bare_arg_names(args_a) == bare_arg_names(args_b)
  end

  defp bare_arg_names(args) do
    args
    |> Enum.map(fn {name, _, ctx} when is_atom(name) and is_atom(ctx) -> name end)
  end

  # --- single differing capture ---------------------------------------

  # Returns `{:ok, path}` when `a` and `b` are AST-equal everywhere
  # except a single position, and that position holds a bare
  # `&name/arity` / `&Mod.name/arity` capture in BOTH trees. Otherwise
  # `:error`.
  defp single_differing_capture_path(a, b) do
    case diff_paths(strip_meta(a), strip_meta(b), []) do
      {:ok, [path]} ->
        if capture_at?(a, path) and capture_at?(b, path), do: {:ok, path}, else: :error

      _ ->
        :error
    end
  end

  # Walk both trees in lockstep collecting the paths where they diverge.
  # Bails to `:error` the moment the structural shape itself differs
  # (different node arity / different non-tuple leaf shape under matching
  # parents) so we never produce a meaningless path.
  defp diff_paths(x, x, _path), do: {:ok, []}

  # A capture node is atomic: never recurse into `&...`. Equal captures
  # are no divergence; differing captures diverge AT this `&` path, so
  # the reported path points at the whole capture (what `capture_at?`
  # expects), not at the inner name atom.
  defp diff_paths({:&, _, _} = x, {:&, _, _} = y, path) do
    if x == y, do: {:ok, []}, else: {:ok, [Enum.reverse(path)]}
  end

  defp diff_paths({f, _, args_x}, {f, _, args_y}, path)
       when is_list(args_x) and is_list(args_y) and length(args_x) == length(args_y) do
    diff_children(args_x, args_y, path, 0, [])
  end

  defp diff_paths(xs, ys, path) when is_list(xs) and is_list(ys) and length(xs) == length(ys) do
    diff_children(xs, ys, path, 0, [])
  end

  defp diff_paths({xa, xb}, {ya, yb}, path) do
    diff_children([xa, xb], [ya, yb], path, 0, [])
  end

  # Same structural slot, different subtree: record THIS path as the
  # divergence point (don't recurse — the whole subterm differs).
  defp diff_paths(x, y, path) do
    if same_shape?(x, y), do: :error, else: {:ok, [Enum.reverse(path)]}
  end

  # `acc` accumulates lists-of-paths (each path is itself a list of
  # indices); concat them — never `List.flatten`, which would merge a
  # single path's indices into the outer collection and lose its shape.
  defp diff_children([], [], _path, _idx, acc),
    do: {:ok, acc |> Enum.reverse() |> Enum.concat()}

  defp diff_children([x | xs], [y | ys], path, idx, acc) do
    case diff_paths(x, y, [idx | path]) do
      {:ok, paths} -> diff_children(xs, ys, path, idx + 1, [paths | acc])
      :error -> :error
    end
  end

  # Two leaves whose top shapes match enough that the divergence is a
  # value-swap at this slot (so it's a legit single-path divergence)
  # rather than a structural mismatch we must reject. We accept any two
  # leaves here: the caller only treats a single-path divergence as a
  # match when BOTH sides are captures, so over-accepting structural
  # leaf-swaps is harmless — they fail the `capture_at?` gate.
  defp same_shape?(_x, _y), do: false

  defp capture_at?(ast, path), do: ast |> at_path(path) |> bare_capture?()

  # `&name/arity`
  defp bare_capture?({:&, _, [{:/, _, [{name, _, ctx}, arity]}]})
       when is_atom(name) and is_atom(ctx),
       do: integer_arity?(arity)

  # `&Mod.name/arity`
  defp bare_capture?({:&, _, [{:/, _, [{{:., _, [_mod, name]}, _, []}, arity]}]})
       when is_atom(name),
       do: integer_arity?(arity)

  defp bare_capture?(_), do: false

  defp integer_arity?(n) when is_integer(n), do: true
  defp integer_arity?({:__block__, _, [n]}) when is_integer(n), do: true
  defp integer_arity?(_), do: false

  # --- already-consolidated guard -------------------------------------

  # The output shape of this refactor is `helper(args, &cap)`: a single
  # local call whose only divergent arg is the capture. If both bodies
  # already look like that AND call the same existing local function,
  # consolidating again would just wrap a wrapper. Skip.
  defp already_consolidated?(body_a, body_b, path, existing_names) do
    with {:ok, name_a} <- local_call_name(body_a),
         {:ok, name_b} <- local_call_name(body_b),
         true <- name_a == name_b,
         true <- MapSet.member?(existing_names, name_a),
         true <- capture_is_only_call_arg?(body_a, path) do
      true
    else
      _ -> false
    end
  end

  defp local_call_name({name, _, args}) when is_atom(name) and is_list(args), do: {:ok, name}
  defp local_call_name(_), do: :error

  # The differing capture sits directly in the argument list of the
  # top-level local call (path = [arg_index]).
  defp capture_is_only_call_arg?({name, _, args}, [idx]) when is_atom(name) and is_list(args),
    do: idx >= 0 and idx < length(args)

  defp capture_is_only_call_arg?(_, _), do: false

  # --- naming ----------------------------------------------------------

  defp synth_helper_name(name_a, name_b, existing_names) do
    base = helper_base_name(name_a, name_b)

    [base | Enum.map(2..9, &"#{base}_#{&1}")]
    |> Enum.map(&String.to_atom/1)
    |> Enum.find(fn cand -> not MapSet.member?(existing_names, cand) end)
    |> case do
      nil -> :error
      name -> {:ok, name}
    end
  end

  defp helper_base_name(name_a, name_b) do
    case common_prefix(Atom.to_string(name_a), Atom.to_string(name_b)) do
      "" -> Atom.to_string(name_a) <> "_by"
      prefix -> String.trim_trailing(prefix, "_") <> "_by"
    end
  end

  defp common_prefix(a, b) do
    a
    |> String.graphemes()
    |> Enum.zip(String.graphemes(b))
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> Enum.map_join("", fn {x, _} -> x end)
  end

  @pred_candidates [:pred, :fun, :fun0, :fun1, :f]

  defp fresh_pred_name(param_names, body) do
    taken = MapSet.new(param_names) |> MapSet.union(used_var_names(body))

    @pred_candidates
    |> Enum.find(fn cand -> not MapSet.member?(taken, cand) end)
    |> case do
      nil -> :error
      name -> {:ok, name}
    end
  end

  # --- path read / write ----------------------------------------------

  defp at_path(node, []), do: node

  defp at_path({_f, _, args}, [idx | rest]) when is_list(args),
    do: args |> Enum.at(idx) |> at_path(rest)

  defp at_path(list, [idx | rest]) when is_list(list),
    do: list |> Enum.at(idx) |> at_path(rest)

  defp at_path({a, b}, [idx | rest]),
    do: [a, b] |> Enum.at(idx) |> at_path(rest)

  defp replace_at_path(_node, [], replacement), do: replacement

  defp replace_at_path({f, meta, args}, [idx | rest], replacement) when is_list(args),
    do: {f, meta, List.update_at(args, idx, &replace_at_path(&1, rest, replacement))}

  defp replace_at_path(list, [idx | rest], replacement) when is_list(list),
    do: List.update_at(list, idx, &replace_at_path(&1, rest, replacement))

  defp replace_at_path({a, b}, [idx | rest], replacement),
    do: [a, b] |> List.update_at(idx, &replace_at_path(&1, rest, replacement)) |> List.to_tuple()

  # --- patch rendering -------------------------------------------------

  defp helper_insert_patch({:defmodule, _, _} = mod_node, name, args, body_ast) do
    rendered = render_helper(:defp, name, args, body_ast)

    %{end: end_pos} = Sourceror.get_range(mod_node)
    insert_pos = [line: end_pos[:line], column: 1]
    %{change: "  " <> rendered <> "\n\n", range: %{end: insert_pos, start: insert_pos}}
  end

  defp wrapper_patch({kind, _, [head, _body]} = clause, helper_name, arg_refs, capture) do
    head_str = head |> strip_comments() |> Sourceror.to_string()
    call = render_call(helper_name, arg_refs ++ [capture])
    rendered = "#{kind} #{head_str}, do: #{call}"

    %{end: end_pos, start: start_pos} = Sourceror.get_range(clause)
    %{change: rendered, range: %{end: end_pos, start: start_pos}}
  end

  defp render_helper(kind, name, args, body_ast) do
    arg_list = args |> Enum.map_join(", ", &render_node/1)
    body_str = body_ast |> strip_comments() |> Sourceror.to_string()

    if String.contains?(body_str, "\n") do
      indented = indent(body_str, "  ")
      "#{kind} #{name}(#{arg_list}) do\n#{indented}\nend"
    else
      "#{kind} #{name}(#{arg_list}), do: #{body_str}"
    end
  end

  defp render_call(name, args) do
    arg_list = args |> Enum.map_join(", ", &render_node/1)
    "#{name}(#{arg_list})"
  end

  defp render_node({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: Atom.to_string(name)
  defp render_node(node), do: node |> strip_comments() |> Sourceror.to_string()

  defp indent(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end

  # --- small utils -----------------------------------------------------

  defp pairs(list) do
    for {a, i} <- Enum.with_index(list),
        {b, j} <- Enum.with_index(list),
        i < j,
        do: {a, b}
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp strip_comments(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        meta =
          meta
          |> Keyword.put(:leading_comments, [])
          |> Keyword.put(:trailing_comments, [])

        {form, meta, args}

      other ->
        other
    end)
  end
end
