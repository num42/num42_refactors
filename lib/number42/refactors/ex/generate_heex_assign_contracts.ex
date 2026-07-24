defmodule Number42.Refactors.Ex.GenerateHeexAssignContracts do
  @moduledoc """
  Infers missing Phoenix `attr`/`slot` declarations from the `~H` usage
  of a function-component and inserts them above the component:

      def greeting(assigns) do
        ~H\"\"\"
        <p>Hello {@name}, you are {@role}.</p>
        \"\"\"
      end

      ↓

      attr :name, :any, required: true
      attr :role, :any, required: true

      def greeting(assigns) do
        ~H\"\"\"
        <p>Hello {@name}, you are {@role}.</p>
        \"\"\"
      end

  ## Default-OFF (opt-in only)

  Attribute contracts are a design decision: the inferred types are a
  conservative guess, `required: true` may be wrong when the caller
  always passes the assign through `assign_new`, and a team may prefer
  to hand-author its component API. So this refactor only fires with
  `enabled: true` — the in-`transform/2` gate *is* the default-off
  convention (same as `RangeLiteralToRangeNew`). Run it once on a new
  component, then tune the generated declarations by hand.

  ## Detection

  A *function-component* here is a top-level `def`/`defp` whose head is
  `name(assigns)` (exactly one parameter, literally named `assigns`)
  and whose body contains at least one `~H` sigil. The sigils are
  parsed with `Number42.Refactors.Analysis.Heex.Tree`; every `@assign` read in

  - inline `{...}` / `<%= ... %>` expressions,
  - `attr={...}` attribute braces, and
  - `<%= if/for/... %>` block headers

  is collected. Declarations already present at module level
  (`attr :x, ...` / `slot :x, ...`) are subtracted, as are the
  LiveView-provided special assigns (`@socket`, `@flash`, `@myself`,
  `@inner_block` is the one exception — it maps to a `slot`).

  ## Type inference policy (conservative)

  - `@inner_block`                         -> `slot`
  - `class`/`id`/`name`/`title`/`href`     -> `:string`
  - assign used as a boolean HTML attr     -> `:boolean`
  - field access (`@user.name`) only       -> `:map`
  - anything weaker                         -> `:any`

  Generated `attr`/`slot` are always `required: true`: the template
  reads the assign unconditionally, so the safe contract is "must be
  passed". Loosen to `default:` by hand where `assign_new` or a
  fallback applies. We never touch or re-type a declaration that is
  already present.

  ## Idempotence

  A second pass re-reads the now-present declarations, subtracts them
  from the used set, finds nothing missing, and is a no-op.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Analysis.Heex.Tree

  # LiveView-provided assigns that are never declared with `attr`.
  # `inner_block` is intentionally absent — it maps to a `slot`.
  @special_assigns ~w(socket flash myself live_action uploads streams conn __changed__)a

  @string_attrs ~w(class id name title href)

  # HTML attributes whose presence/absence is the value — an assign
  # bound to one of these is almost always a boolean.
  @boolean_attrs ~w(disabled checked selected readonly required open hidden
                    multiple autofocus novalidate)

  @impl Number42.Refactors.Refactor
  def description,
    do: "Infer missing Phoenix attr/slot declarations from ~H usage (opinionated, default-off)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    OPINIONATED / OPT-IN (default-off, runs only with `enabled: true`).
    For a function-component `def name(assigns)` that returns `~H`, this
    collects every `@assign` read in the template, subtracts the attrs
    already declared and the LiveView special assigns, and inserts an
    `attr`/`slot` declaration for each one that is missing. Types are a
    conservative guess (`:string` for class/id/href/..., `:boolean` for
    boolean HTML attrs, `:slot` for `@inner_block`, `:map` for bare
    field access, `:any` otherwise) and declarations are `required: true`
    because the template reads them unconditionally. Hand-tune the
    result; existing declarations are never modified.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      Sourceror.parse_string(source) |> apply_or_passthrough(source)
    else
      source
    end
  end

  defp apply_or_passthrough({:ok, ast}, source),
    do: ast |> components_with_missing(source) |> insert_all(source)

  defp apply_or_passthrough({:error, _}, source), do: source

  # For each function-component, the list of missing declarations and
  # the source line its `def`/`defp` starts on (the insertion anchor).
  #
  # A multi-clause component shares one `attr`/`slot` block: Phoenix
  # requires every declaration to precede the FIRST clause of the
  # `{name, arity}` group, and rejects an `attr` sitting before a later
  # clause. So clauses are grouped by component name, the missing-assign
  # analysis is unioned across the whole group (`used_assigns/2` already
  # scans every sigil enclosed by that name), and the block is anchored
  # at the earliest clause's line — across *all* clauses of that name,
  # including a leading dispatcher clause with no `~H` sigil of its own.
  defp components_with_missing(ast, source) do
    declared = declared_names(ast)
    first_lines = first_clause_lines(ast)

    ast
    |> component_defs()
    |> Enum.group_by(fn {_def_node, fn_name} -> fn_name end)
    |> Enum.flat_map(fn {fn_name, clauses} ->
      derived = clauses |> Enum.flat_map(&assigned_in_def/1) |> MapSet.new()
      missing_for_component(fn_name, first_lines, declared, derived, source)
    end)
  end

  defp missing_for_component(fn_name, first_lines, declared, derived, source) do
    used = used_assigns(fn_name, source)

    missing =
      used
      |> Enum.reject(fn {name, _type} ->
        MapSet.member?(declared, name) or MapSet.member?(derived, name)
      end)
      |> Enum.sort_by(fn {name, _type} -> name end)

    case missing do
      [] -> []
      decls -> [%{anchor_line: Map.fetch!(first_lines, fn_name), decls: decls}]
    end
  end

  # Assigns the component computes for *itself* in its body via
  # `assign/2,3` / `assign_new/2,3` are NOT caller inputs — declaring an
  # `attr :x, required: true` for them is wrong: the caller must not pass
  # `x`; the body derives it from another assign (e.g.
  # `assign(:pdf_url, MediaUrl.download_original_url(assigns.asset))`). Such
  # names are subtracted, per clause, from the generated contract.
  #
  # `clauses` are `{def_node, fn_name}` tuples from `component_defs/1`.
  defp assigned_in_def({def_node, _fn_name}) do
    def_node |> Macro.prewalker() |> Enum.flat_map(&assign_targets/1)
  end

  # The assign key(s) set by one `assign`/`assign_new` call node, in any
  # shape. A pipe `x |> assign(:k, v)` keeps the call as the `|>` RHS with
  # the subject DROPPED (`{:assign, _, [:k, v]}`), so the explicit args are
  # one fewer than the direct form — both arities are handled here.
  #
  #   direct: assign(x, :k, v)        rhs:  assign(:k, v)
  #   direct: assign(x, k: v, ...)    rhs:  assign(k: v, ...)
  #   direct: assign_new(x, :k, fn)   rhs:  assign_new(:k, fn)
  #
  # A non-literal key (`assign(x, key, v)` with `key` a var) yields nothing.
  defp assign_targets({:|>, _, [_lhs, {fun, _, args}]})
       when fun in [:assign, :assign_new] and is_list(args),
       do: piped_assign_keys(args)

  defp assign_targets({fun, _, args}) when fun in [:assign, :assign_new] and is_list(args) do
    case args do
      [_subject | rest] -> piped_assign_keys(rest)
      _ -> []
    end
  end

  defp assign_targets(_), do: []

  # Keys from the subject-less argument list (the `|>`-RHS form, or the
  # tail of a direct call after dropping the subject): `[kw]` or `[key, val]`.
  defp piped_assign_keys([kw]) when is_list(kw), do: keyword_keys(kw)
  defp piped_assign_keys([key, _value]), do: List.wrap(literal_key(key))
  defp piped_assign_keys(_), do: []

  defp keyword_keys(kw) do
    kw
    |> Enum.flat_map(fn
      {key, _value} -> List.wrap(literal_key(key))
      _ -> []
    end)
  end

  defp literal_key({:__block__, _, [key]}) when is_atom(key), do: key
  defp literal_key(key) when is_atom(key), do: key
  defp literal_key(_), do: nil

  # `fn_name => line of its earliest clause`, over every arity-1 `def`/`defp`
  # in the module. The anchor must precede the FIRST clause of the component's
  # clause group; a leading clause may transform assigns and delegate without
  # an `~H` sigil of its own (so `component_defs/1`, which requires a sigil,
  # never sees it) yet Phoenix still demands the `attr` block sit before it.
  defp first_clause_lines(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {def_kind, _, [head, [{_do, _body}]]} = node when def_kind in [:def, :defp] ->
        case arity_one_name(head) do
          {:ok, name} -> [{name, Sourceror.get_range(node).start[:line]}]
          :error -> []
        end

      _ ->
        []
    end)
    |> Enum.reduce(%{}, fn {name, line}, acc -> Map.update(acc, name, line, &min(&1, line)) end)
  end

  # The function name of an arity-1 `def`/`defp` head, regardless of how the
  # single parameter is shaped. Used only to find the earliest clause line.
  defp arity_one_name({:when, _, [inner | _]}), do: arity_one_name(inner)
  defp arity_one_name({name, _, [_arg]}) when is_atom(name), do: {:ok, name}
  defp arity_one_name(_), do: :error

  # Insert generated declarations above each component, bottom-up so
  # earlier insertions don't shift the line numbers of later anchors.
  defp insert_all([], source), do: source

  defp insert_all(components, source) do
    components
    |> Enum.sort_by(& &1.anchor_line, :desc)
    |> Enum.reduce(source, fn %{anchor_line: line, decls: decls}, acc ->
      insert_before_line(acc, line, render_decls(decls, anchor_indent(acc, line)))
    end)
  end

  defp render_decls(decls, indent) do
    body = decls |> Enum.map_join("\n", &(indent <> render_decl(&1)))
    body <> "\n"
  end

  defp render_decl({name, :slot}), do: "slot :#{name}, required: true"
  defp render_decl({name, type}), do: "attr :#{name}, :#{type}, required: true"

  defp anchor_indent(source, line) do
    source
    |> String.split("\n", trim: false)
    |> Enum.at(line - 1, "")
    |> leading_whitespace()
  end

  defp leading_whitespace(line) do
    case Regex.run(~r/\A[ \t]*/, line) do
      [ws] -> ws
      _ -> ""
    end
  end

  defp insert_before_line(source, line, insert_text) do
    lines = String.split(source, "\n", trim: false)
    {head, tail} = Enum.split(lines, line - 1)
    Enum.join(head ++ [insert_text | tail], "\n")
  end

  # --- declared names (existing attr/slot at module level) ---

  defp declared_names(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {decl, _, [first | _]} when decl in [:attr, :slot] -> List.wrap(decl_name(first))
      _ -> []
    end)
    |> MapSet.new()
  end

  defp decl_name({:__block__, _, [name]}) when is_atom(name), do: name
  defp decl_name(name) when is_atom(name), do: name
  defp decl_name(_), do: nil

  # --- component detection ---

  defp component_defs(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {def_kind, _, [head, [{_do, _body}]]} = node when def_kind in [:def, :defp] ->
        component_or_skip(node, head)

      _ ->
        []
    end)
  end

  defp component_or_skip(node, head) do
    case assigns_component_name(head) do
      {:ok, fn_name} -> if has_h_sigil?(node), do: [{node, fn_name}], else: []
      :error -> []
    end
  end

  # Head must be `name(<arg>)` where the single arg binds `assigns` — bare
  # (`name(assigns)`) or pattern-matched (`name(%{type: t} = assigns)`).
  # A multi-clause component routinely pattern-matches in the head, so a
  # bare-only check misses every clause but the catch-all and anchors the
  # `attr` block before a later clause (Phoenix compile error, #371).
  defp assigns_component_name({:when, _, [inner | _]}), do: assigns_component_name(inner)

  defp assigns_component_name({name, _, [arg]}) when is_atom(name) do
    if binds_assigns?(arg), do: {:ok, name}, else: :error
  end

  defp assigns_component_name(_), do: :error

  defp binds_assigns?({:assigns, _, ctx}) when is_atom(ctx), do: true
  defp binds_assigns?({:=, _, [lhs, rhs]}), do: binds_assigns?(lhs) or binds_assigns?(rhs)
  defp binds_assigns?(_), do: false

  defp has_h_sigil?(node) do
    node
    |> Macro.prewalker()
    |> Enum.any?(&match?({:sigil_H, _, _}, &1))
  end

  # --- assign collection from the ~H tree ---

  defp used_assigns(fn_name, source) do
    source
    |> sigils_for(fn_name)
    |> Enum.reduce(%{}, fn sigil, acc -> collect_from_tree(sigil.tree, acc) end)
    |> Enum.reject(fn {name, _type} -> name in @special_assigns end)
  end

  defp sigils_for(source, fn_name) do
    case Tree.from_source(source) do
      {:ok, sigils} -> Enum.filter(sigils, &(&1.enclosing_fn == fn_name))
      :error -> []
    end
  end

  # Walk the HEEx tree, recording the strongest type signal per assign.
  defp collect_from_tree(nodes, acc) do
    Tree.walk(nodes, acc, &record_node/2)
  end

  defp record_node({:element, _tag, attrs, _children, _meta}, acc),
    do: Enum.reduce(attrs, acc, &record_attr/2)

  defp record_node({:eex_expr, code, _meta}, acc), do: scan_code(code, :any, acc)
  defp record_node({:eex_block, header, _children, _meta}, acc), do: scan_code(header, :any, acc)
  defp record_node({:text, _text, _meta}, acc), do: acc

  defp record_attr({attr_name, {:expr, code}}, acc),
    do: scan_code(code, attr_type_signal(attr_name), acc)

  defp record_attr({_attr_name, {:string, _}}, acc), do: acc

  defp attr_type_signal(attr_name) do
    cond do
      attr_name in @boolean_attrs -> :boolean
      attr_name in @string_attrs -> :string
      true -> :any
    end
  end

  # Parse the snippet, find `@name` reads, and merge their type signal.
  # A bare `@name` followed by `.field` upgrades the signal to `:map`
  # unless the attr context already supplied something stronger.
  defp scan_code(code, attr_signal, acc) do
    case Code.string_to_quoted(code) do
      {:ok, quoted} -> merge_assigns(quoted, attr_signal, acc)
      {:error, _} -> acc
    end
  end

  defp merge_assigns(quoted, attr_signal, acc) do
    quoted
    |> assign_signals(attr_signal)
    |> Enum.reduce(acc, fn {name, signal}, inner ->
      Map.update(inner, name, signal, &stronger(&1, signal))
    end)
  end

  # Returns `[{assign_name, signal}]` for every `@assign` in the snippet.
  # `@user.name` -> `{:user, :map}`; bare `@user` -> `{:user, attr_signal}`.
  defp assign_signals(quoted, attr_signal) do
    quoted
    |> Macro.prewalker()
    |> Enum.flat_map(&assign_from_node(&1, attr_signal))
  end

  # Field access on an assign: `@user.name` -> :map signal.
  defp assign_from_node({{:., _, [{:@, _, [{name, _, ctx}]}, field]}, _, []}, _attr_signal)
       when is_atom(name) and is_atom(ctx) and is_atom(field),
       do: [assign_signal(name, :map)]

  defp assign_from_node({:@, _, [{name, _, ctx}]}, attr_signal)
       when is_atom(name) and is_atom(ctx),
       do: [assign_signal(name, attr_signal)]

  defp assign_from_node(_, _), do: []

  defp assign_signal(:inner_block, _signal), do: {:inner_block, :slot}
  defp assign_signal(name, signal), do: {name, signal}

  # Signal precedence (strongest wins): slot > string|boolean > map > any.
  defp stronger(:slot, _), do: :slot
  defp stronger(_, :slot), do: :slot
  defp stronger(:string, _), do: :string
  defp stronger(_, :string), do: :string
  defp stronger(:boolean, _), do: :boolean
  defp stronger(_, :boolean), do: :boolean
  defp stronger(:map, _), do: :map
  defp stronger(_, :map), do: :map
  defp stronger(a, _), do: a
end
