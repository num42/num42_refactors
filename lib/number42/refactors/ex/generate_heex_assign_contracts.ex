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

  ## The contract must cover the callers, not just the body

  Declaring a single `attr` switches Phoenix from "no validation" to
  "this list is exhaustive", so a contract inferred from the template
  alone turns every attribute a caller passes but the body never reads
  into an `undefined attribute` warning. `prepare/1` therefore indexes
  every `<.component …>` / `<Mod.component …>` call site in the corpus
  — the configured sources plus the `.heex` templates beside them — and
  the generated contract is the union of what the body reads and what
  the callers pass.

  `required: true` is likewise only emitted for an attribute that
  *every* observed call site passes; one call site leaving it out would
  make `required` a `missing required attribute` warning. With no call
  site anywhere in the corpus there is no caller to contradict, and the
  body's reads are taken as the contract.

  A call site that spreads (`<.card {@rest}>`) hides its attribute
  names, so the component is left alone entirely. A call site passing a
  global attribute (`phx-click`, `data-*`) contributes `attr :rest,
  :global` rather than a declaration per name.

  We never touch or re-type a declaration that is already present.

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
  def prepare(opts) do
    case Keyword.get(opts, :source_files) do
      files when is_list(files) and files != [] -> {:ok, build_call_index(files)}
      _ -> :no_cache
    end
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      Sourceror.parse_string(source)
      |> apply_or_passthrough(source, Keyword.get(opts, :prepared))
    else
      source
    end
  end

  defp apply_or_passthrough({:ok, ast}, source, index),
    do: ast |> components_with_missing(source, index) |> insert_all(source)

  defp apply_or_passthrough({:error, _}, source, _index), do: source

  @doc """
  The call-site index built by `prepare/1`, exposed for testing.

  Maps a component's bare function name to what its callers pass:
  `:attrs` is the union over all sites, `:always` the intersection,
  `:opaque?` records a spread that hides the names.
  """
  @spec build_call_index([String.t()]) :: %{String.t() => map()}
  def build_call_index(files) do
    files
    |> corpus_files()
    |> Enum.reduce(%{}, fn path, acc ->
      case File.read(path) do
        {:ok, source} -> source |> call_sites(path) |> Enum.reduce(acc, &merge_site/2)
        {:error, _} -> acc
      end
    end)
  end

  # A component is just as often called from the `.heex` beside its module as
  # from another `~H` sigil, and those templates are not in `inputs`.
  defp corpus_files(files) do
    templates =
      files
      |> Enum.map(&Path.dirname/1)
      |> Enum.uniq()
      |> Enum.flat_map(
        &(Path.wildcard(Path.join(&1, "*.heex")) ++ Path.wildcard(Path.join(&1, "*/*.heex")))
      )

    Enum.uniq(files ++ templates)
  end

  defp call_sites(source, path) do
    source |> trees_in(path) |> Enum.flat_map(&sites_in_tree/1)
  end

  defp trees_in(source, path) do
    if String.ends_with?(path, ".heex") do
      case Tree.parse_body(source) do
        {:ok, tree} -> [tree]
        :error -> []
      end
    else
      case Tree.from_source(source) do
        {:ok, sigils} -> Enum.map(sigils, & &1.tree)
        :error -> []
      end
    end
  end

  defp sites_in_tree(tree) do
    Tree.walk(tree, [], fn
      {:element, tag, attrs, children, _meta}, acc ->
        case component_name(tag) do
          nil -> acc
          name -> [{name, site_facts(attrs, children)} | acc]
        end

      _node, acc ->
        acc
    end)
  end

  # `<.local />` and `<Some.Remote.fun />` are component calls; a plain HTML
  # tag is not.
  defp component_name("." <> rest), do: last_segment(rest)

  defp component_name(tag) do
    if Regex.match?(~r/\A[A-Z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)*\.[a-z_][A-Za-z0-9_]*[?!]?\z/, tag),
      do: last_segment(tag),
      else: nil
  end

  defp last_segment(tag), do: tag |> String.split(".") |> List.last()

  defp site_facts(attrs, children) do
    names = Enum.map(attrs, fn {name, _value} -> name end)
    {slots, content} = Enum.split_with(children, &slot_entry?/1)

    %{
      opaque?: "" in names,
      global?: Enum.any?(names, &global_attr?/1),
      attrs: names |> Enum.reject(&ignored_attr?/1) |> MapSet.new(),
      exprs: expr_attr_names(attrs),
      slots: MapSet.new(slots, fn {:element, ":" <> name, _, _, _} -> name end),
      children?: content != []
    }
  end

  defp expr_attr_names(attrs) do
    for {name, {:expr, _code}} <- attrs, not ignored_attr?(name), into: MapSet.new(), do: name
  end

  # `<:back>…</:back>` fills a named slot: it is a child of the call, never an
  # attribute of it, and it is not `inner_block` content either.
  defp slot_entry?({:element, ":" <> _name, _attrs, _children, _meta}), do: true
  defp slot_entry?(_node), do: false

  # `:let`/`:if`/`:for` are HEEx directives, not attributes of the component.
  defp ignored_attr?(name),
    do: name == "" or String.starts_with?(name, ":") or global_attr?(name)

  defp global_attr?(name), do: String.contains?(name, "-")

  defp merge_site({name, facts}, index) do
    Map.update(index, name, first_site(facts), &fold_site(&1, facts))
  end

  defp first_site(facts) do
    %{
      attrs: facts.attrs,
      always: facts.attrs,
      exprs: facts.exprs,
      slots: facts.slots,
      slots_always: facts.slots,
      opaque?: facts.opaque?,
      global?: facts.global?,
      children_always?: facts.children?
    }
  end

  defp fold_site(acc, facts) do
    %{
      attrs: MapSet.union(acc.attrs, facts.attrs),
      always: MapSet.intersection(acc.always, facts.attrs),
      exprs: MapSet.union(acc.exprs, facts.exprs),
      slots: MapSet.union(acc.slots, facts.slots),
      slots_always: MapSet.intersection(acc.slots_always, facts.slots),
      opaque?: acc.opaque? or facts.opaque?,
      global?: acc.global? or facts.global?,
      children_always?: acc.children_always? and facts.children?
    }
  end

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
  defp components_with_missing(ast, source, index) do
    declared = declared_by_component(ast)
    first_lines = first_clause_lines(ast)

    ast
    |> component_defs()
    |> Enum.group_by(fn {_def_node, fn_name} -> fn_name end)
    |> Enum.flat_map(fn {fn_name, clauses} ->
      derived = clauses |> Enum.flat_map(&assigned_in_def/1) |> MapSet.new()
      own = Map.get(declared, fn_name, MapSet.new())
      missing_for_component(fn_name, first_lines, own, derived, source, index)
    end)
  end

  defp missing_for_component(fn_name, first_lines, declared, derived, source, index) do
    case call_facts(index, fn_name) do
      :opaque -> []
      facts -> emit_for_component(fn_name, first_lines, declared, derived, source, facts)
    end
  end

  defp emit_for_component(fn_name, first_lines, declared, derived, source, facts) do
    declared = MapSet.new(declared, &Atom.to_string/1)
    derived = MapSet.new(derived, &Atom.to_string/1)

    missing =
      fn_name
      |> used_assigns(source)
      |> contract(facts)
      |> Enum.reject(&skip_decl?(&1, declared, derived))
      |> Enum.sort_by(& &1.name)

    case missing do
      [] -> []
      decls -> [%{anchor_line: Map.fetch!(first_lines, fn_name), decls: decls}]
    end
  end

  # An assign the body derives itself is not a caller input — unless a caller
  # does pass it, in which case the contract has to admit it anyway.
  defp skip_decl?(%{name: name, from_caller?: from_caller?}, declared, derived),
    do: MapSet.member?(declared, name) or (MapSet.member?(derived, name) and not from_caller?)

  # No observed caller: nothing can contradict the body, so the reads are the
  # contract — the original single-file behaviour.
  defp contract(used, :none) do
    Enum.map(used, fn {name, type} ->
      %{name: Atom.to_string(name), type: type, required?: true, from_caller?: false}
    end)
  end

  defp contract(used, facts) do
    read = Map.new(used, fn {name, type} -> {Atom.to_string(name), type} end)

    read
    |> Map.keys()
    |> Enum.concat(MapSet.to_list(facts.attrs))
    |> Enum.concat(MapSet.to_list(facts.slots))
    |> Enum.uniq()
    |> Enum.map(&declaration(&1, read, facts))
    |> Enum.concat(global_decl(facts))
  end

  defp declaration(name, read, facts) do
    type = declared_type(name, read, facts)

    %{
      name: name,
      type: type,
      required?: required?(name, type, facts),
      from_caller?: MapSet.member?(facts.attrs, name) or MapSet.member?(facts.slots, name)
    }
  end

  # What the call sites do outranks what the body looks like: `render_slot/1`
  # also accepts a slot entry handed over as an ordinary attribute, and a
  # `:string` guess is wrong the moment one caller passes a class list.
  defp declared_type(name, read, facts) do
    cond do
      MapSet.member?(facts.slots, name) -> :slot
      MapSet.member?(facts.exprs, name) -> :any
      MapSet.member?(facts.attrs, name) -> attr_type_signal(name)
      true -> Map.get_lazy(read, name, fn -> attr_type_signal(name) end)
    end
  end

  # `inner_block` is filled by the call's own children, a named slot by its
  # `<:name>` entry — neither ever arrives as an attribute.
  defp required?("inner_block", :slot, facts), do: facts.children_always?
  defp required?(name, :slot, facts), do: MapSet.member?(facts.slots_always, name)
  defp required?(name, _type, facts), do: MapSet.member?(facts.always, name)

  # A caller passing `phx-click` or `data-*` needs somewhere for those to land,
  # and that is one `:global` attr rather than a declaration per name.
  defp global_decl(%{global?: true}),
    do: [%{name: "rest", type: :global, required?: false, from_caller?: true}]

  defp global_decl(_facts), do: []

  defp call_facts(nil, _fn_name), do: :none

  defp call_facts(index, fn_name) do
    case Map.get(index, Atom.to_string(fn_name)) do
      nil -> :none
      %{opaque?: true} -> :opaque
      facts -> facts
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

  defp render_decl(%{name: name, type: :global}), do: "attr :#{name}, :global"
  defp render_decl(%{name: name, type: :slot} = decl), do: "slot :#{name}#{suffix(decl)}"
  defp render_decl(%{name: name, type: type} = decl), do: "attr :#{name}, :#{type}#{suffix(decl)}"

  defp suffix(%{required?: true}), do: ", required: true"
  defp suffix(_decl), do: ""

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

  # An `attr`/`slot` binds to the next function definition only, so a
  # module-wide set would let one component's declaration silence a missing
  # declaration on another.
  defp declared_by_component(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [_name, [{_do, body}]]} -> [body]
      _ -> []
    end)
    |> Enum.reduce(%{}, fn body, acc -> body |> body_exprs() |> attach_declarations(acc) end)
  end

  defp body_exprs({:__block__, _, exprs}), do: exprs
  defp body_exprs(expr), do: [expr]

  defp attach_declarations(exprs, acc) do
    {index, _pending} = Enum.reduce(exprs, {acc, []}, &attach_expr/2)
    index
  end

  defp attach_expr({decl, _, [first | _]}, {index, pending}) when decl in [:attr, :slot],
    do: {index, pending ++ List.wrap(decl_name(first))}

  defp attach_expr({def_kind, _, [head, [{_do, _body}]]}, {index, pending})
       when def_kind in [:def, :defp] do
    case arity_one_name(head) do
      {:ok, name} -> {claim(index, name, pending), []}
      :error -> {index, []}
    end
  end

  defp attach_expr(_expr, state), do: state

  defp claim(index, name, pending),
    do: Map.update(index, name, MapSet.new(pending), &MapSet.union(&1, MapSet.new(pending)))

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

  # `render_slot(@back)` names a slot, not an attribute — the only signal the
  # body gives for a named slot.
  defp assign_from_node({:render_slot, _, [{:@, _, [{name, _, ctx}]} | _]}, _attr_signal)
       when is_atom(name) and is_atom(ctx),
       do: [{name, :slot}]

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
