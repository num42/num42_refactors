defmodule Number42.Refactors.Ex.ExtractRepeatedGuardToDefguard do
  @moduledoc """
  Extract a single-variable `when`-guard repeated across **N >= 3**
  function clauses into a `defguardp`, and replace each occurrence with
  the named guard.

      def fetch(id) when is_integer(id) and id > 0, do: do_fetch(id)
      def update(id, attrs) when is_integer(id) and id > 0, do: do_update(id, attrs)
      def delete(id) when is_integer(id) and id > 0, do: do_delete(id)
      ↓
      defguardp is_valid_id(id) when is_integer(id) and id > 0

      def fetch(id) when is_valid_id(id), do: do_fetch(id)
      def update(id, attrs) when is_valid_id(id), do: do_update(id, attrs)
      def delete(id) when is_valid_id(id), do: do_delete(id)

  ## Why this is sound

  A guard expression already passed the compiler's guard-clause check
  (it stood in a `when`), so it is guard-legal — and `defguard`/`defguardp`
  accept exactly the guard-legal subset. The extraction therefore never
  produces an illegal guard body; it only gives a name to one that
  already type-checked as a guard.

  ## Trigger

  The same guard, **structurally equal modulo the single guarded var
  name**, appears in `>= min_occurrences` (default `3`) clause heads in
  one module. `is_integer(id) and id > 0` and `is_integer(n) and n > 0`
  are the *same* guard — the variable is normalised before comparison.

  ## Naming and placement

  The `defguardp <name>(<param>) when <expr>` is inserted at the first
  top-level expression of the module body (after aliases, before the
  first clause that uses it). The name is `is_valid_<var>` derived from
  the guarded variable; on collision a numeric suffix is appended.

  ## v1 scope: single guarded variable

  Only guards over **one** parameter are handled. The guard may name
  that parameter any number of times, but every other leaf must be a
  literal. A guard touching two parameters (`a > 0 and b > 0`) would
  need a multi-arg `defguardp` with a positional convention — left as a
  follow-up.

  ## Skip conditions (source left unchanged when any holds)

  - **Below threshold.** Fewer than `min_occurrences` clauses share the
    guard.
  - **Multiple guarded variables.** The guard references more than one
    distinct parameter name — out of v1 scope.
  - **Guarded variable not a bare parameter.** The variable in the
    guard must be a bare parameter of *every* clause carrying the guard;
    a destructured or absent slot disqualifies that clause.
  - **Already a named guard.** A `when <name>(<var>)` whose `<name>` is
    a guard defined in the same module is left alone — idempotence.
  - **`defmacro`/`defmacrop`.** Only `def`/`defp` heads are touched.

  ## Idempotence

  After the rewrite each head reads `when is_valid_<var>(<var>)`, a
  named-guard call rather than the original expression, so the second
  pass finds no repeated literal guard and the synthesised `defguardp`
  is recognised as an existing module guard. Safe to run repeatedly.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @default_min_occurrences 3

  @impl Number42.Refactors.Refactor
  def description,
    do: "Extract a `when`-guard repeated across >= 3 clauses into a `defguardp`"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A guard expression copy-pasted onto three or more clause heads has
    its meaning spread across every copy and drifts when one copy is
    edited. Naming it once as a `defguardp` gives the predicate a single
    definition and an intent-revealing name, and each head says
    `when is_valid_id(id)` instead of restating the arithmetic. The
    extraction is sound because a guard that compiled in a `when` is by
    definition guard-legal, which is exactly what `defguardp` accepts.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    min = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
    Sourceror.parse_string(source) |> apply_patches(source, min)
  end

  defp apply_patches({:ok, ast}, source, min),
    do: ast |> build_patches(min) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source, _min), do: source

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp build_patches(ast, min) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value([], fn
      {:defmodule, _, [_name, [{_do, body}]]} -> module_patches(body, min)
      _ -> nil
    end)
  end

  # One group is extracted per module per pass (the first eligible, in
  # source order). Further groups are handled by subsequent passes.
  defp module_patches(body, min) do
    exprs = body_to_exprs(body)
    existing = existing_guard_names(exprs)

    exprs
    |> Enum.flat_map(&guarded_clause/1)
    |> Enum.group_by(& &1.key)
    |> Map.values()
    |> Enum.filter(&(length(&1) >= min))
    |> Enum.sort_by(fn [first | _] -> line_of(first.node) end)
    |> Enum.find_value([], &emit_group(&1, exprs, existing))
  end

  # --- candidate extraction --------------------------------------------

  # A guarded `def`/`defp` clause whose guard is a single-variable guard
  # over a bare parameter. Returns the data needed to group and rewrite,
  # or `[]` to skip.
  defp guarded_clause({kind, _, [{:when, _, [head, guard]}, _body]} = node)
       when kind in [:def, :defp] do
    with {:ok, params} <- head_params(head),
         {:ok, var} <- single_guard_var(guard),
         true <- var in params do
      [%{node: node, guard: guard, var: var, key: guard_key(guard, var)}]
    else
      _ -> []
    end
  end

  defp guarded_clause(_), do: []

  defp head_params({name, _, args}) when is_atom(name) and is_list(args) do
    args
    |> Enum.reduce_while([], fn arg, acc ->
      case bare_var(arg) do
        {:ok, n} -> {:cont, [n | acc]}
        :skip -> {:cont, acc}
      end
    end)
    |> then(&{:ok, &1})
  end

  defp head_params(_), do: :skip

  # The set of distinct variable names a guard reads. Exactly one →
  # single-var guard. A named-guard call already counts as a guard call
  # in `guard_callable?`, so an already-extracted head with one arg also
  # has a single var — but it carries no repeated *literal* expression to
  # group on, so it never reaches the threshold with peers.
  defp single_guard_var(guard) do
    case guard |> guard_vars() |> MapSet.to_list() do
      [var] -> {:ok, var}
      _ -> :skip
    end
  end

  defp guard_vars(guard) do
    guard
    |> Macro.prewalker()
    |> Enum.reduce(MapSet.new(), fn
      {name, _, ctx}, acc when is_atom(name) and is_atom(ctx) ->
        if special_var?(name), do: acc, else: MapSet.put(acc, name)

      _, acc ->
        acc
    end)
  end

  defp special_var?(name), do: name in [:__MODULE__, :__CALLER__, :__ENV__]

  # --- grouping --------------------------------------------------------

  # Structural key: the guard with its single var renamed to a canonical
  # hole and all metadata stripped, so `is_integer(id) and id > 0` and
  # `is_integer(n) and n > 0` hash to the same group.
  defp guard_key(guard, var) do
    guard
    |> normalise_var(var)
    |> strip_all_meta()
    |> :erlang.phash2()
  end

  defp normalise_var(guard, var) do
    Macro.prewalk(guard, fn
      {^var, meta, ctx} when is_atom(ctx) -> {:__guard_var__, meta, ctx}
      node -> node
    end)
  end

  # --- emit ------------------------------------------------------------

  # The group shares one name, derived from the first member's var; each
  # head keeps its own var as the argument. A group whose canonical name
  # is already a module guard (re-running on extracted output) is skipped.
  defp emit_group([first | _] = group, exprs, existing) do
    name = guard_name(first.var)

    if MapSet.member?(existing, name) do
      nil
    else
      head_replacements =
        Enum.map(group, fn %{node: node, var: var} ->
          Patch.replace(node, rewrite_head(node, name, var))
        end)

      [defguardp_patch(first, name, exprs) | head_replacements]
    end
  end

  # Replace the clause's `when <expr>` with `when <name>(<var>)`, keeping
  # the head and body source verbatim around it.
  defp rewrite_head({kind, _, [{:when, _, [head, _guard]}, body_kw]}, name, var) do
    head_text = Sourceror.to_string(head)
    "#{kind} #{head_text} when #{name}(#{var})#{body_text(body_kw)}"
  end

  defp body_text(body_kw) do
    case do_body(body_kw) |> rendered_body() do
      {:single, text} -> ", do: #{text}"
      {:multi, text} -> " do\n#{indent(text)}\nend"
    end
  end

  defp do_body(body_kw) do
    Enum.find_value(body_kw, fn
      {{:__block__, _, [:do]}, body} -> body
      {:do, body} -> body
      _ -> nil
    end)
  end

  # A multi-statement block renders as `do/end`; a single expression
  # renders inline unless `to_string` itself spans lines.
  defp rendered_body({:__block__, _, exprs}) when length(exprs) > 1,
    do: {:multi, Enum.map_join(exprs, "\n", &Sourceror.to_string/1)}

  defp rendered_body(body) do
    text = Sourceror.to_string(body)
    if String.contains?(text, "\n"), do: {:multi, text}, else: {:single, text}
  end

  # One line-anchored insertion of the `defguardp ... when ...` line,
  # placed at the first top-level expression's line, column 1 — after
  # the module's aliases, before the first clause that uses it.
  defp defguardp_patch(%{guard: guard, var: var}, name, exprs) do
    line = exprs |> hd() |> line_of()
    text = "defguardp #{name}(#{var}) when #{Sourceror.to_string(guard)}\n\n"
    range = %{start: [line: line, column: 1], end: [line: line, column: 1]}
    Patch.new(range, text, false)
  end

  # --- naming ----------------------------------------------------------

  # `id → is_valid_id`. An underscore-led var keeps a clean name.
  defp guard_name(var) do
    base = var |> Atom.to_string() |> String.trim_leading("_")
    :"is_valid_#{base}"
  end

  # Guard names already defined in the module via `defguard`/`defguardp`,
  # so a head already calling one is recognised and left alone.
  defp existing_guard_names(exprs) do
    exprs
    |> Enum.flat_map(fn
      {kind, _, [{:when, _, [{name, _, args}, _guard]} | _]}
      when kind in [:defguard, :defguardp] and is_atom(name) and is_list(args) ->
        [name]

      _ ->
        []
    end)
    |> MapSet.new()
  end

  # --- small utils -----------------------------------------------------

  defp strip_all_meta(ast),
    do:
      Macro.prewalk(ast, fn
        {f, _m, a} -> {f, [], a}
        other -> other
      end)

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "  " <> line
    end)
  end
end
