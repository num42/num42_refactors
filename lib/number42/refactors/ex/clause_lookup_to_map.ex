defmodule Number42.Refactors.Ex.ClauseLookupToMap do
  @moduledoc """
  Collapses N clauses of one arity-1 function — each mapping a single
  literal head to a single constant body — into a `@<plural_name>`
  lookup-map attribute plus one passthrough clause.

      defp icon(:success), do: "✓ green"
      defp icon(:warning), do: "! yellow"
      defp icon(:error),   do: "✗ red"
      ↓
      @icons %{success: "✓ green", warning: "! yellow", error: "✗ red"}
      defp icon(status), do: @icons[status]

  ## What collapses

    * **>= 3** clauses of one `{visibility, name, 1}` function, each head a
      single literal (atom / integer / string / boolean), each body a
      single **constant** expression — a literal, a literal collection
      (list / tuple / map), a binary, or a module-attribute / alias
      reference. No call, no operator, no reference to the head variable.
    * Clause order is preserved in the map. Duplicate heads keep the first
      entry — same as clause-dispatch (the first matching clause wins).

  ## Catch-all

  A trailing catch-all clause (`icon(_), do: "default"`) whose body is a
  constant becomes the default of a `Map.get/3` lookup:

      defp icon(:ok),  do: "green"
      defp icon(:err), do: "red"
      defp icon(_),    do: "grey"
      ↓
      @icons %{ok: "green", err: "red"}
      defp icon(status), do: Map.get(@icons, status, "grey")

  Without a catch-all the passthrough is a bare index: `@icons[status]`
  (a miss yields `nil`, matching the original `FunctionClauseError`-free
  expectation only when the caller covered every key — index access is
  the faithful translation of "no clause, no match").

  ## What it skips

    * Fewer than 3 literal-dispatch clauses — below threshold.
    * A guard on **any** clause (`icon(s) when ...`) — not a pure literal
      dispatch.
    * A clause whose head is not a single bare literal — a destructured
      pattern, a variable, more than one argument.
    * A clause whose body references the head variable, calls a function,
      or is otherwise non-constant (side effects, computed values).
    * A catch-all that is not the **last** clause, or whose body is
      non-constant.
    * Any extra (non-catch-all) clause whose head is a bare variable
      sitting among the literal clauses — ambiguous dispatch, left alone.

  ## Boundaries

  `RepeatedPatternToMacro` (#82) synthesises bodies that *call functions*
  via a macro. This refactor is pure constant data → a plain map
  attribute, no macro. `ConsolidateParallelClauseFunctions` (#45)
  collapses two distinct functions; this collapses N clauses of one.

  ## Idempotence

  After the rewrite the function is one passthrough clause indexing an
  attribute — no literal-dispatch clause group remains, so a second pass
  finds no match.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @min_clauses 3

  @impl Number42.Refactors.Refactor
  def description, do: "Collapse N literal->const clauses into a @attr lookup map + passthrough"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    N clauses that each map a literal head to a constant body are a lookup
    table written as control flow. Lifting the pairs into a `@<plural>`
    map attribute and replacing the clauses with one passthrough that
    indexes the map names the table, gathers the data in one place, and
    removes N-1 dispatch clauses. A trailing catch-all becomes the
    `Map.get/3` default. Only pure literal→constant dispatch qualifies:
    guards, non-literal heads, and non-constant bodies are left alone.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
  defp apply_patches({:error, _}, source), do: source

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp build_patches(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, _} = mod -> module_patches(mod)
      _ -> []
    end)
  end

  # ---------------------------------------------------------------
  # Per-module — gather contiguous arity-1 def groups, rewrite the
  # eligible ones.
  # ---------------------------------------------------------------

  defp module_patches(mod) do
    mod
    |> module_body_exprs()
    |> List.wrap()
    |> existing_def_groups()
    |> Enum.flat_map(&group_patches/1)
  end

  # `{kind, name}` => clause nodes (arity-1 only), grouped so a function
  # interrupted by another def is still seen as one group.
  defp existing_def_groups(exprs) do
    exprs
    |> Enum.flat_map(fn
      {kind, _, [head, body_kw]} = node when def_kind?(kind) and is_list(body_kw) ->
        case extract_fn_signature(head) do
          {name, [_one]} -> [{{kind, name}, node}]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.group_by(fn {key, _node} -> key end, fn {_key, node} -> node end)
    |> Map.to_list()
  end

  defp group_patches({{kind, name}, clauses}) when length(clauses) >= @min_clauses do
    with false <- Enum.any?(clauses, &guarded?/1),
         {literal_clauses, catch_all} <- split_catch_all(clauses),
         true <- length(literal_clauses) >= @min_clauses,
         {:ok, entries} <- literal_entries(literal_clauses),
         {:ok, default} <- catch_all_default(catch_all) do
      emit(kind, name, clauses, entries, default)
    else
      _ -> []
    end
  end

  defp group_patches(_), do: []

  # ---------------------------------------------------------------
  # Clause classification.
  # ---------------------------------------------------------------

  defp guarded?({_kind, _, [{:when, _, _} | _]}), do: true
  defp guarded?(_), do: false

  # A trailing `name(_)` catch-all is split off; anything earlier in the
  # list that is a catch-all (bare var / `_`) makes the group ineligible
  # (it would already shadow later literal clauses → not a clean table).
  defp split_catch_all(clauses) do
    {init, [last]} = Enum.split(clauses, -1)

    cond do
      Enum.any?(init, &catch_all_head?/1) -> :ambiguous
      catch_all_head?(last) -> {init, last}
      true -> {clauses, nil}
    end
  end

  defp catch_all_head?({_kind, _, [head, _body]}) do
    case extract_fn_signature(head) do
      {_name, [arg]} -> bare_var_arg?(arg)
      _ -> false
    end
  end

  defp bare_var_arg?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp bare_var_arg?(_), do: false

  # Each literal clause → `{key_atom_or_value, body_ast}`. Bails to
  # `:error` if any clause is not literal-head + constant-body. The key is
  # kept as the raw literal value so first-wins de-duplication is exact.
  defp literal_entries(clauses) do
    clauses
    |> Enum.reduce_while({:ok, []}, fn clause, {:ok, acc} ->
      case literal_entry(clause) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, dedupe_first_wins(Enum.reverse(rev))}
      :error -> :error
    end
  end

  defp literal_entry({_kind, _, [head, body_kw]}) do
    with {_name, [arg]} <- extract_fn_signature(head),
         {:ok, key} <- literal_value(arg),
         {:ok, body} <- single_do_body(body_kw),
         true <- constant?(body) do
      {:ok, {key, body}}
    else
      _ -> :error
    end
  end

  defp dedupe_first_wins(entries) do
    entries
    |> Enum.reduce({[], MapSet.new()}, fn {key, body}, {acc, seen} ->
      if MapSet.member?(seen, key),
        do: {acc, seen},
        else: {[{key, body} | acc], MapSet.put(seen, key)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp catch_all_default(nil), do: {:ok, nil}

  defp catch_all_default({_kind, _, [_head, body_kw]}) do
    with {:ok, body} <- single_do_body(body_kw),
         true <- constant?(body) do
      {:ok, body}
    else
      _ -> :error
    end
  end

  # ---------------------------------------------------------------
  # Literal head + constant body predicates.
  # ---------------------------------------------------------------

  defp literal_value(atom) when is_atom(atom), do: {:ok, atom}
  defp literal_value(n) when is_integer(n) or is_float(n), do: {:ok, n}
  defp literal_value(s) when is_binary(s), do: {:ok, s}

  defp literal_value({:__block__, _, [lit]})
       when is_atom(lit) or is_integer(lit) or is_float(lit) or is_binary(lit),
       do: {:ok, lit}

  defp literal_value(_), do: :error

  # A constant body: literals, literal collections, binaries, and
  # `@attr`/alias references. No call, operator, or variable.
  defp constant?(atom) when is_atom(atom), do: true
  defp constant?(n) when is_integer(n) or is_float(n), do: true
  defp constant?(s) when is_binary(s), do: true
  defp constant?({:__block__, _, [single]}), do: constant?(single)
  defp constant?({:__block__, _, _}), do: false
  defp constant?(list) when is_list(list), do: Enum.all?(list, &constant?/1)
  defp constant?({a, b}), do: constant?(a) and constant?(b)

  # Module-attribute reference: `@foo`.
  defp constant?({:@, _, [{name, _, ctx}]}) when is_atom(name) and is_atom(ctx), do: true

  # Module alias: `MyApp.Const`.
  defp constant?({:__aliases__, _, _}), do: true

  # `{a, b, c}` tuples (3+ elements) and `%{}` maps build as 3-tuples.
  defp constant?({:{}, _, elems}) when is_list(elems), do: Enum.all?(elems, &constant?/1)
  defp constant?({:%{}, _, pairs}) when is_list(pairs), do: Enum.all?(pairs, &constant?/1)

  # Binary literal `<<...>>` of constants.
  defp constant?({:<<>>, _, parts}) when is_list(parts), do: Enum.all?(parts, &constant?/1)

  defp constant?(_), do: false

  defp single_do_body(body_kw) do
    body_kw
    |> Enum.reduce({nil, 0}, fn
      {{:__block__, _, [:do]}, value}, {_, n} -> {value, n + 1}
      {:do, value}, {_, n} -> {value, n + 1}
      _, {v, n} -> {v, n + 1}
    end)
    |> case do
      {body, 1} -> single_expr_of(body)
      _ -> :error
    end
  end

  defp single_expr_of({:__block__, _, [single]}), do: {:ok, single}
  defp single_expr_of({:__block__, _, _}), do: :error
  defp single_expr_of(other), do: {:ok, other}

  # ---------------------------------------------------------------
  # Emit — one attribute insert + replace the first clause with the
  # passthrough + delete the remaining clauses.
  # ---------------------------------------------------------------

  defp emit(kind, name, [first | rest], entries, default) do
    attr = attr_name(name)
    map_text = render_map(entries)
    passthrough = render_passthrough(kind, name, attr, default)

    replacement = "@#{attr} #{map_text}\n  #{passthrough}"

    [Patch.replace(first, replacement) | Enum.map(rest, &delete_patch/1)]
  end

  # `icon` → `icons`; a name that is already plural (ends in `s`) is kept
  # verbatim so we don't emit `@limitses`.
  defp attr_name(name) do
    string = Atom.to_string(name)
    if String.ends_with?(string, "s"), do: string, else: pluralize_compound(string)
  end

  # Replace a redundant clause with empty text; Sourceror's range covers
  # the whole clause, so this removes it. The trailing newline is left to
  # the reformat pass.
  defp delete_patch(clause) do
    %{start: start_pos, end: end_pos} = Sourceror.get_range(clause)
    Patch.new(%{start: start_pos, end: end_pos}, "", false)
  end

  defp render_passthrough(kind, name, attr, nil),
    do: "#{kind} #{name}(key), do: @#{attr}[key]"

  defp render_passthrough(kind, name, attr, default),
    do: "#{kind} #{name}(key), do: Map.get(@#{attr}, key, #{render_const(default)})"

  defp render_map(entries) do
    pairs = Enum.map_join(entries, ", ", &render_pair/1)
    "%{#{pairs}}"
  end

  # Atom keys render in the `key: value` shorthand; other literal keys use
  # the explicit `key => value` arrow form.
  defp render_pair({key, body}) when is_atom(key) and not is_boolean(key) and not is_nil(key),
    do: "#{key}: #{render_const(body)}"

  defp render_pair({key, body}),
    do: "#{render_const(key)} => #{render_const(body)}"

  defp render_const(node), do: slice_node_string(node)

  defp slice_node_string(node) do
    case node do
      atom when is_atom(atom) -> render_literal_atom(atom)
      n when is_integer(n) -> Integer.to_string(n)
      n when is_float(n) -> Float.to_string(n)
      s when is_binary(s) -> inspect(s)
      {:__block__, _, [single]} -> slice_node_string(single)
      other -> Sourceror.to_string(other)
    end
  end

  defp render_literal_atom(nil), do: "nil"
  defp render_literal_atom(true), do: "true"
  defp render_literal_atom(false), do: "false"
  defp render_literal_atom(atom), do: inspect(atom)
end
