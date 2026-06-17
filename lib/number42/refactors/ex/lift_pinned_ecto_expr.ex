defmodule Number42.Refactors.Ex.LiftPinnedEctoExpr do
  @moduledoc """
  Lifts a non-trivial pinned expression inside an `Ecto.Query` macro
  call into a local binding placed immediately before the enclosing
  statement, in the innermost block that hosts that statement.

  ## Why

  Ecto allows any expression after `^`, but only a bare variable lets
  Ecto cache the compiled query — anything else (a function call, a
  module-attribute access, a struct-field read) forces a recompile per
  call. It also makes the pinned value invisible in the source: a
  reader has to mentally evaluate `^Enum.map(tokens, & &1.id)` to
  know what gets bound. Naming the value at the call site fixes both:
  the query gets a stable shape, and the binding name documents the
  intent.

  ## What fires

      def expire(tokens_to_expire) do
        Repo.delete_all(
          from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id))
        )
      end

  becomes

      def expire(tokens_to_expire) do
        map_tokens_to_expire_binding = Enum.map(tokens_to_expire, & &1.id)

        Repo.delete_all(
          from(t in UserToken, where: t.id in ^map_tokens_to_expire_binding)
        )
      end

  ## Trigger

  - The pin sits inside a known Ecto-query macro call: `from`,
    `where`, `select`, `update`, `order_by`, `having`, `group_by`,
    `join`, `on`, `select_merge`, `distinct`, `lock`, `or_where`,
    `or_having`, `preload`, `subquery`, `dynamic`. Locally-called
    (`from(...)`) and remote (`Ecto.Query.from(...)`) shapes both
    match. This is the cheapest reliable way to distinguish "Ecto pin"
    from "pattern-match pin" (`case x do ^foo -> ...`) and "bitstring
    size pin" without a full type check.
  - The pinned expression is **not** a bare local variable. `^foo`
    stays. `^foo.bar`, `^@attr`, `^Mod.f(...)`, `^do_x()` get lifted.
  - The pin sits inside an enclosing statement that lives in some
    block (`def`/`defp` body, `do`/`else` block, `with` `do`/`else`,
    `case`/`cond`/`if`/`fn` clause body, `try` `do`/`rescue`/`catch`/
    `after`/`else`). Pins outside any block (e.g. inside `quote`,
    inside macro DSL bodies that don't expand to standard blocks) get
    skipped.

  ## One pin per pass

  We extract one pin per `Engine` pass and let the fixpoint loop re-run.
  Keeps each diff a single, reviewable lift; avoids the bookkeeping of
  overlapping patches when multiple pins share a statement.

  ## Why procedural

  Two-node surgery: replace the pinned expression in place, AND insert
  a new binding statement before the enclosing block-member statement.
  Not expressible as a single 1:1 declarative pattern.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @ecto_macros ~w(
    from where select select_merge update order_by having group_by
    join on distinct lock or_where or_having preload subquery dynamic
  )a

  @impl Number42.Refactors.Refactor
  def description,
    do: "Pinned non-var expr in Ecto query -> hoist to a named binding"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Ecto compiles and caches each query by its AST shape — a pinned
    expression that isn't a bare variable forces a fresh compile every
    time the query runs. Lifting the expression to a `name = expr`
    binding before the query both restores the cache hit and gives the
    runtime value a name in the source.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 120
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  def synth_binding_name(expr), do: name_from_expr(expr)

  defp name_from_expr({{:., _, [{:__aliases__, _, _}, fname]}, _, args}) when is_atom(fname),
    do: compose(Atom.to_string(fname), first_var_arg(args))

  # Defensive: only really a call if `liftable_call?` passed.
  # `:__block__` is a Sourceror wrapper, not a name; we shouldn't
  # see it here given the lift gate, but fall through cleanly.
  defp name_from_expr({:__block__, _, _}), do: "pinned_binding"

  defp name_from_expr({fname, _, args}) when is_atom(fname) and is_list(args),
    do: compose(Atom.to_string(fname), first_var_arg(args))

  defp name_from_expr({{:., _, [{base_name, _, base_ctx}, field]}, _, []})
       when is_atom(base_name) and is_atom(base_ctx) and is_atom(field),
       do: "#{base_name}_#{field}_binding"

  defp name_from_expr({:@, _, [{attr_name, _, _}]}) when is_atom(attr_name),
    do: "#{attr_name}_binding"

  defp name_from_expr(_), do: "pinned_binding"

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  @impl Number42.Refactors.Refactor
  def patches(ast, source, _opts), do: build_patches(ast, source)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp block_groups_from_keyword(keyword) do
    keyword
    |> Enum.flat_map(fn
      {{:__block__, _, [k]}, body} when k in [:do, :else, :rescue, :catch, :after] ->
        [{:block, body_to_exprs(body)}]

      {k, body} when k in [:do, :else, :rescue, :catch, :after] ->
        [{:block, body_to_exprs(body)}]

      _ ->
        []
    end)
  end

  defp build_patches(ast, source),
    do:
      ast
      |> collect_extractions([], false)
      |> Enum.take(1)
      |> Enum.flat_map(&emit_patches(&1, source))

  defp child_groups_for({:defmodule, _, [_name, [{_do, body}]]}, in_ecto?),
    do: {[{:block, body_to_exprs(body)}], in_ecto?}

  defp child_groups_for({def_kind, _, [_head, [{_do, body}]]}, in_ecto?)
       when def_kind?(def_kind) do
    {[{:block, body_to_exprs(body)}], in_ecto?}
  end

  defp child_groups_for({:with, _, args}, in_ecto?) when is_list(args) and args != [] do
    {clauses, kw} =
      case split_do_block_keyword(args) do
        {head, kw} -> {head, kw}
        :no_kw -> {args, []}
      end

    {[{:with_clauses, clauses} | block_groups_from_keyword(kw)], in_ecto?}
  end

  defp child_groups_for({:->, _, [args, body]}, in_ecto?),
    do: {[{:transparent, args}, {:block, body_to_exprs(body)}], in_ecto?}

  defp child_groups_for({:fn, _, clauses}, in_ecto?), do: {[{:transparent, clauses}], in_ecto?}

  defp child_groups_for({{:., _, _} = dot, _, args}, in_ecto?),
    do:
      split_do_block_keyword(args)
      |> child_groups_with_or_without_blocks(args, dot, in_ecto?)

  defp child_groups_for({_call, _, args}, in_ecto?) when is_list(args) do
    split_do_block_keyword(args) |> child_groups_with_or_without_blocks(args, in_ecto?)
  end

  defp child_groups_for(_, in_ecto?), do: {[], in_ecto?}

  defp child_groups_with_or_without_blocks({head, kw}, _args, in_ecto?),
    do: {[{:transparent, head} | block_groups_from_keyword(kw)], in_ecto?}

  defp child_groups_with_or_without_blocks(:no_kw, args, in_ecto?),
    do: {[{:transparent, args}], in_ecto?}

  defp child_groups_with_or_without_blocks({head, kw}, _args, dot, in_ecto?),
    do: {[{:transparent, [dot | head]} | block_groups_from_keyword(kw)], in_ecto?}

  defp child_groups_with_or_without_blocks(:no_kw, args, dot, in_ecto?),
    do: {[{:transparent, [dot | args]}], in_ecto?}

  defp collect_extractions(node, host_stack, in_ecto?) do
    if pinned_ecto_expr_to_lift?(node) and in_ecto? and host_stack != [] do
      {kind, stmt} = hd(host_stack)
      [%{host_kind: kind, host_stmt: stmt, pin_node: node}]
    else
      descend(node, host_stack, in_ecto?)
    end
  end

  defp compose(callee, nil), do: "#{callee}_binding"
  defp compose(callee, var), do: "#{callee}_#{var}_binding"

  defp descend({_, _, _} = node, host_stack, in_ecto?) do
    new_in_ecto = in_ecto? or ecto_macro_call?(node)
    {child_groups, child_in_ecto} = child_groups_for(node, new_in_ecto)

    child_groups
    |> Enum.flat_map(fn {context, exprs} ->
      walk_children(exprs, context, host_stack, child_in_ecto)
    end)
  end

  defp descend(list, host_stack, in_ecto?) when is_list(list) do
    list |> Enum.flat_map(&collect_extractions(&1, host_stack, in_ecto?))
  end

  defp descend({left, right}, host_stack, in_ecto?),
    do:
      collect_extractions(left, host_stack, in_ecto?) ++
        collect_extractions(right, host_stack, in_ecto?)

  defp descend(_leaf, _host_stack, _in_ecto?), do: []

  defp do_block_kw?(kw) when is_list(kw) do
    kw
    |> Enum.any?(fn
      {{:__block__, _, [k]}, _} when k in [:do, :else, :rescue, :catch, :after] -> true
      {k, _} when k in [:do, :else, :rescue, :catch, :after] -> true
      _ -> false
    end)
  end

  defp do_block_kw?(_), do: false

  defp ecto_macro_call?({name, _, args}) when is_atom(name) and is_list(args) do
    name in @ecto_macros
  end

  defp ecto_macro_call?({{:., _, [{:__aliases__, _, mod_segments}, fname]}, _, args})
       when is_atom(fname) and is_list(args) do
    fname in @ecto_macros and List.last(mod_segments) == :Query
  end

  defp ecto_macro_call?(_), do: false

  defp emit_patches(%{host_kind: host_kind, host_stmt: host_stmt, pin_node: pin_node}, source) do
    {:^, _, [pinned_expr]} = pin_node

    base = synth_binding_name(pinned_expr)
    binding_name = uniquify(base, host_stmt)

    slice_node(source, pinned_expr)
    |> replace_and_insert_patches_or_skip(binding_name, host_kind, host_stmt, pin_node)
  end

  defp first_var_arg(args) do
    args
    |> Enum.find_value(fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
        string = Atom.to_string(name)
        if String.starts_with?(string, "_"), do: nil, else: name

      _ ->
        nil
    end)
  end

  defp liftable_call?({fname, _, args})
       when is_atom(fname) and is_list(args) do
    fname not in [
      :__block__,
      :<<>>,
      :{},
      :%{},
      :%,
      :|>,
      :@,
      :+,
      :-,
      :*,
      :/,
      :==,
      :!=,
      :===,
      :!==,
      :<,
      :>,
      :<=,
      :>=,
      :and,
      :or,
      :not,
      :&&,
      :||,
      :!,
      :in,
      :++,
      :<>,
      :|,
      :"::",
      :<-
    ]
  end

  defp liftable_call?({{:., _, [{:__aliases__, _, _}, fname]}, _, args})
       when is_atom(fname) and is_list(args),
       do: true

  defp liftable_call?(_), do: false
  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
  defp pinned_ecto_expr_to_lift?({:^, _, [arg]}), do: liftable_call?(arg)
  defp pinned_ecto_expr_to_lift?(_), do: false

  defp replace_and_insert_patches_or_skip(
         {:ok, expr_text},
         binding_name,
         host_kind,
         host_stmt,
         pin_node
       ) do
    pin_range = Sourceror.get_range(pin_node)
    replacement_text = "^" <> binding_name
    replace_patch = Patch.new(replacement_range(pin_range), replacement_text, false)

    stmt_range = Sourceror.get_range(host_stmt)
    line = stmt_range.start[:line]
    col = stmt_range.start[:column]
    indent = String.duplicate(" ", col - 1)

    binding_text =
      case host_kind do
        :block_stmt ->
          "#{binding_name} = #{expr_text}\n\n#{indent}"

        # In `with`, clauses are comma-separated. Insert
        # `name = expr,\n<indent>` before the clause that hosts the
        # pin. Legal `with` syntax: `name = expr` between `<-` clauses.
        :with_clause ->
          "#{binding_name} = #{expr_text},\n#{indent}"
      end

    insert_range = %{
      end: [line: line, column: col],
      start: [line: line, column: col]
    }

    insert_patch = Patch.new(insert_range, binding_text, false)

    [replace_patch, insert_patch]
  end

  defp replace_and_insert_patches_or_skip(
         :error,
         _binding_name,
         _host_kind,
         _host_stmt,
         _pin_node
       ),
       do: []

  defp replacement_range(range),
    do: %{
      end: [line: range.end[:line], column: range.end[:column]],
      start: [line: range.start[:line], column: range.start[:column]]
    }

  defp split_do_block_keyword([]), do: :no_kw

  defp split_do_block_keyword(args) do
    {head, [last]} = args |> Enum.split(length(args) - 1)
    if do_block_kw?(last), do: {head, last}, else: :no_kw
  end

  defp uniquify(base, host_stmt) do
    used =
      host_stmt
      |> Macro.prewalker()
      |> Enum.flat_map(fn
        {name, _, ctx} when is_atom(name) and is_atom(ctx) -> [Atom.to_string(name)]
        _ -> []
      end)
      |> MapSet.new()

    if MapSet.member?(used, base), do: next_free_name(base, used), else: base
  end

  defp next_free_name(base, used) do
    2
    |> Stream.iterate(&(&1 + 1))
    |> Enum.find_value(fn n ->
      candidate = "#{base}_#{n}"
      if MapSet.member?(used, candidate), do: nil, else: candidate
    end)
  end

  defp walk_children(exprs, :block, host_stack, in_ecto?),
    do:
      exprs |> Enum.flat_map(&collect_extractions(&1, [{:block_stmt, &1} | host_stack], in_ecto?))

  defp walk_children(clauses, :with_clauses, host_stack, in_ecto?),
    do:
      clauses
      |> Enum.flat_map(&collect_extractions(&1, [{:with_clause, &1} | host_stack], in_ecto?))

  defp walk_children(exprs, :transparent, host_stack, in_ecto?),
    do: exprs |> Enum.flat_map(&collect_extractions(&1, host_stack, in_ecto?))
end
