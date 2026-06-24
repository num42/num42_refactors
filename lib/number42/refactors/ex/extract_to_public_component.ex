defmodule Number42.Refactors.Ex.ExtractToPublicComponent do
  @moduledoc """
  Lift a recurring/cohesive `~H` subtree into its **own public file component
  module** — a new `lib/<app>_web/components/<name>.ex` other modules can call —
  even when the subtree appears only once and so never crosses the cross-file
  recurrence threshold of `ProposeSharedHeexComponent`.

  This is the public-home analogue of `ExtractHeexComponentBySeam` (which carves
  a cohesive subtree into a **private** `defp` in the *same* module). The two are
  independent and both default-OFF; enabling both can let each claim the same
  subtree — by design, the operator opts into that.

  ## Why a structural motif, not an assign seam

  A **public** component needs a stronger signal than self-containment — that the
  block is a **reusable UI primitive** other modules will want. Measured across a
  real codebase, the recurring plural skeletons map to a small set of recognised
  types (`data_table`, `select_field`, `card_grid`, ...; `Heex.StructureMotif`).
  A named motif IS the reuse signal. So detection fires only when
  `StructureMotif.classify/1` returns a recognised motif (`:unknown` → no
  candidate). Detection is the whole problem; the rewrite is mechanical.

  ## Stateless vs stateful

  Only **purely presentational** motifs are lifted — to a stateless `:html`
  function component (`def name(assigns)`, called `<Mod.name …/>`). A motif
  whose body carries a `phx-` event binding is *recognised* as stateful but
  **declined**: auto-generating a public `:live_component` is unsafe, because
  Phoenix requires it to have a single static root element, a guaranteed-unique
  `id` per instance, and a correct `update/2` assign flow — none of which a
  motif cut can synthesize. A dogfood run produced live_components with
  conditional (`:if`) roots and duplicated static `id`s that raised at render
  (#374), so stateful motifs stay where they are.

  ## Reusability safety: no literal `id=`

  A motif whose body carries a **literal** `id="…"` attribute is declined: a
  reusable component invoked more than once would render that hardcoded DOM id
  twice (LiveView "Duplicate id found", #374). A dynamic `id={@x}` is fine — its
  value varies per call site.

  ## Compile-safety: carry the caller's imports

  A lifted body often calls sub-components (`<.input>`, a project `<.fixating>`)
  or uses `~p` verified routes — resolved against the *caller's* imports. The new
  module reproduces the caller's `use <App>Web, :html|:live_component` plus its
  `import`/`alias` lines, so those references still resolve. A body whose imports
  cannot be reproduced (the caller has no `use <App>Web, …`) is declined.

  ## Never lift from the configured CoreComponents

  CoreComponents is assumed correctly built and scoped by the project; it is the
  *home* of primitives, not a source to carve up. The configured
  `core_components_module` is excluded as a source.

  ## Default-OFF + configured destination

  `transform/2` is a no-op unless the module's opts carry `enabled: true`. The
  project configures where new component files land and which module to skip:

      %{heex: %{
        components_namespace: "MyAppWeb.Components",   # new modules' parent
        core_components_module: "MyAppWeb.CoreComponents"  # excluded source
      }}

  `find_candidates/2` is always available for `--dry-run`/diagnostics.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.AstHelpers
  alias Number42.Refactors.Heex.{AttrType, ComponentNaming, Motif, Scope, StructureMotif, Tree}

  @min_nodes 6
  @min_lines 12

  @framework_assigns ~w(inner_block uploads streams flash socket myself)
  @assign_name "[a-z_][a-zA-Z0-9_]*[?!]?"
  @phx_event_attrs ~w(phx-click phx-submit phx-change phx-keyup phx-keydown
                      phx-blur phx-focus phx-window-keydown phx-window-keyup)

  @type kind :: :function | :live_component

  @type candidate :: %{
          motif: StructureMotif.motif() | nil,
          tag: String.t(),
          nodes: non_neg_integer(),
          lines: non_neg_integer(),
          assigns: [String.t()],
          free_vars: [String.t()],
          component_kind: kind(),
          accepted: boolean(),
          decline: String.t() | nil,
          file: String.t() | nil,
          line: pos_integer() | nil
        }

  @type plan :: %{
          name: atom(),
          module: String.t(),
          component_kind: kind(),
          motif: StructureMotif.motif(),
          assigns: [String.t()],
          body: String.t(),
          node: Tree.node_t(),
          file: String.t(),
          range: {non_neg_integer(), non_neg_integer()},
          web_prefix: String.t(),
          context: %{use_arg: String.t() | nil, imports: [String.t()], aliases: [String.t()]}
        }

  @impl Number42.Refactors.Refactor
  def description,
    do: "Lift a motif-classified ~H subtree into its own public file component module"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A recurring HEEx shape — a data table, a select field, a card grid — is a
    reusable UI primitive, not a one-off block. Where a cohesive subtree
    classifies to a recognised structural motif (`Heex.StructureMotif`), it
    deserves its own public file component other modules can call. We lift it
    into a new `<App>Web.Components.<Name>` module — a stateless `:html`
    function component, or a `:live_component` when the body reacts to events —
    carrying the caller's imports so its sub-component/`~p` references still
    resolve, and rewrite the occurrence to a call. Detection insists the cut be
    safe (no variable bound outside it, no framework-managed assign, no orphaned
    slot, reproducible imports), so the component compiles and renders
    identically. CoreComponents is assumed correct and is never a source.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def priority, do: 10

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    case Keyword.get(opts, :source_files) do
      files when is_list(files) and files != [] -> prepared_for_paths(files, opts)
      _ -> :no_cache
    end
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    with true <- Keyword.get(opts, :enabled, false),
         %{plans: plans} = prepared when plans != [] <- opts[:prepared] do
      rewrite(source, plans, opts, prepared)
    else
      _ -> source
    end
  end

  # ---- detection -----------------------------------------------------------

  @doc """
  Diagnostic: every candidate subtree in `source`, each annotated with its
  motif, component kind, size, assign set, free variables, and whether it is
  `accepted` or the reason it was `decline`d. Read-only.

  Thresholds are configurable: `:min_nodes` (#{@min_nodes}), `:min_lines`
  (#{@min_lines}).
  """
  @spec find_candidates(String.t(), keyword()) :: [candidate()]
  def find_candidates(source, opts \\ []) do
    gates = %{
      min_nodes: Keyword.get(opts, :min_nodes, @min_nodes),
      min_lines: Keyword.get(opts, :min_lines, @min_lines),
      live_component?: live_component?(source),
      context: caller_context(source)
    }

    case Tree.from_source(source) do
      {:ok, sigils} -> Enum.flat_map(sigils, &candidates_in_sigil(&1, gates, nil))
      :error -> []
    end
  end

  defp candidates_in_sigil(sigil, gates, file) do
    sigil.tree
    |> all_subtrees()
    |> Enum.uniq_by(fn node -> Tree.node_byte_range(node, sigil.body) end)
    |> Enum.map(&analyze(&1, sigil, gates, file))
    |> Enum.reject(&is_nil/1)
  end

  defp all_subtrees(tree) do
    Tree.walk(tree, [], fn
      {:element, _, _, _, _} = n, acc -> [n | acc]
      {:eex_block, _, _, _} = n, acc -> [n | acc]
      _other, acc -> acc
    end)
  end

  defp analyze(node, sigil, gates, file) do
    nodes = node_count(node)
    lines = lines_of(node, sigil.body)

    if nodes < gates.min_nodes or lines < gates.min_lines do
      nil
    else
      motif = classify(node)
      own = assigns_in(node)
      free = Scope.free_nonassign_vars(node) |> MapSet.to_list() |> Enum.sort()
      {kind, tag} = kind_and_tag(node)
      component_kind = component_kind(node)
      decline = decline_reason(node, sigil, motif, own, free, kind, gates)

      %{
        motif: motif,
        tag: tag,
        nodes: nodes,
        lines: lines,
        assigns: MapSet.to_list(own) |> Enum.sort(),
        free_vars: free,
        component_kind: component_kind,
        accepted: is_nil(decline),
        decline: decline,
        file: file,
        line: line_of(node, sigil)
      }
    end
  end

  defp classify(node) do
    case StructureMotif.classify(node) do
      {:ok, motif} -> motif
      :unknown -> nil
    end
  end

  # A body carrying a phx- event binding reacts to interaction → stateful
  # live_component; otherwise a stateless function component.
  defp component_kind(node) do
    if has_phx_event?(node), do: :live_component, else: :function
  end

  defp has_phx_event?(node) do
    Tree.walk(node, false, fn
      {:element, _tag, attrs, _ch, _}, acc -> acc or Enum.any?(attrs, &phx_event_attr?/1)
      _o, acc -> acc
    end)
  end

  defp phx_event_attr?({name, _value}), do: name in @phx_event_attrs

  # The first failing safety check names the decline; `nil` means accepted.
  defp decline_reason(node, sigil, motif, own, free, kind, gates) do
    [
      {fn -> is_nil(motif) end, "no recognised structural motif"},
      {fn -> MapSet.size(own) == 0 end, "reads no assigns"},
      {fn -> framework_assign(own) != nil end,
       "reads framework-managed @#{framework_assign(own)} (not a plain attr)"},
      {fn -> free != [] end, "free non-assign vars: #{Enum.join(free, ", ")}"},
      {fn -> orphan_slot?(node) end, "carries a slot entry away from its parent component"},
      {fn -> kind == :element and component_invocation?(node) end,
       "subtree is itself a component call"},
      {fn -> whole_sigil?(node, sigil) end, "subtree is the entire sigil body"},
      {fn -> is_nil(gates.context.use_arg) end,
       "caller has no `use <App>Web` to reproduce in the lifted module"},
      {fn -> called_local(node, gates.context.locals) != nil end,
       "body calls caller-local function #{called_local(node, gates.context.locals)}/n"},
      {fn -> collapses_stateful_root?(node, sigil, gates) end,
       "would leave a non-static stateful root"},
      {fn -> component_kind(node) == :live_component end,
       "stateful (phx-event) motif — a lifted live_component can't be auto-generated safely"},
      {fn -> static_id?(node) end,
       "body carries a literal id= — a reusable component called more than once would duplicate it"}
    ]
    |> Enum.find_value(fn {predicate, reason} -> if predicate.(), do: reason end)
  end

  # A body carrying a *literal* `id="…"` attribute can't be lifted into a
  # reusable component: a component invoked more than once would render the
  # same hardcoded DOM id twice (LiveView "Duplicate id found", #374). We
  # can't tell at lift time whether the new component is called once or in a
  # `:for`, so a static id is declined wholesale. A dynamic `id={@x}` /
  # `id={expr}` is fine — its value varies per call site.
  defp static_id?(node) do
    Tree.walk(node, false, fn
      {:element, _tag, attrs, _ch, _}, acc ->
        acc or Enum.any?(attrs, &match?({"id", {:string, _}}, &1))

      _o, acc ->
        acc
    end)
  end

  # The first caller-local function the body invokes, or nil. A bare call
  # `name(args)` in any EEx slot whose `name` is one of the caller's own
  # `def`/`defp`s cannot resolve once the body moves to its own module.
  defp called_local(node, locals) do
    node
    |> body_call_names()
    |> Enum.find(&MapSet.member?(locals, &1))
  end

  # Every bare local function name the body invokes: function calls in EEx code
  # slots (`{group_path(x)}`, `<%= helper(y) %>`, attr exprs) AND local
  # component tags (`<.backdrop ... />` → `backdrop`). `Mod.fun(...)` qualified
  # calls, `<Mod.foo>` qualified component tags, and bare variables are
  # excluded — only a *bare local* name can collide with a caller `def`/`defp`.
  defp body_call_names(node) do
    Tree.walk(node, MapSet.new(), fn
      {:eex_expr, code, _}, acc ->
        MapSet.union(acc, local_calls_in(code))

      {:eex_block, code, _, _}, acc ->
        MapSet.union(acc, local_calls_in(code))

      {:element, tag, attrs, _ch, _}, acc ->
        acc
        |> MapSet.union(attr_call_names(attrs))
        |> maybe_put_local_component(tag)

      _o, acc ->
        acc
    end)
  end

  # `<.name>` is a local component (`name` a bare atom); `<Mod.name>` is
  # qualified and resolves on its own. Only the bare `.name` form can hit a
  # caller-local `defp name(assigns)`.
  defp maybe_put_local_component(acc, "." <> rest) do
    if rest =~ ~r/^[a-z_][a-zA-Z0-9_]*$/, do: MapSet.put(acc, String.to_atom(rest)), else: acc
  end

  defp maybe_put_local_component(acc, _tag), do: acc

  defp attr_call_names(attrs) do
    Enum.reduce(attrs, MapSet.new(), fn
      {_n, {:expr, code}}, acc -> MapSet.union(acc, local_calls_in(code))
      _, acc -> acc
    end)
  end

  defp local_calls_in(code) when is_binary(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> collect_local_calls(ast)
      _ -> MapSet.new()
    end
  end

  defp local_calls_in(_), do: MapSet.new()

  defp collect_local_calls(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, MapSet.new(), fn
        {name, _meta, args} = n, acc when is_atom(name) and is_list(args) ->
          {n, MapSet.put(acc, name)}

        n, acc ->
          {n, acc}
      end)

    acc
  end

  # ---- caller context (imports to reproduce in the lifted module) ----------

  # The `use <App>Web, :html|:live_component` arg, plus the caller's `import`
  # and `alias` directives — reproduced verbatim in the new module so a lifted
  # body calling `<.fixating>` / using `~p` still resolves (#299 compile-safety).
  # Extracted from the AST (not line-greps) so multi-line `import Foo, only: …`
  # directives survive intact.
  defp caller_context(source) do
    directives = top_level_directives(source)

    %{
      use_arg: use_web_arg(source),
      imports: Map.get(directives, :import, []),
      aliases: Map.get(directives, :alias, []),
      locals: local_function_names(source)
    }
  end

  # Names of the caller's own `def`/`defp` functions. A lifted body calling one
  # of them (`{group_path(@x)}`) would be `undefined` in the new module — those
  # functions stay in the caller and are not importable. Such a body is declined.
  defp local_function_names(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        {_ast, acc} =
          Macro.prewalk(ast, MapSet.new(), fn
            {def_kind, _meta, [{name, _, _args} | _]} = node, acc
            when def_kind in [:def, :defp] and is_atom(name) ->
              {node, MapSet.put(acc, name)}

            node, acc ->
              {node, acc}
          end)

        acc

      _ ->
        MapSet.new()
    end
  end

  # All `import`/`alias` directives in the module body, rendered back to source
  # via `Macro.to_string` (so options and multi-line forms round-trip), grouped
  # by directive. `use`/`require` are intentionally excluded — `use` is handled
  # separately and `require` rarely matters for a HEEx body.
  defp top_level_directives(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        {_ast, acc} =
          Macro.prewalk(ast, [], fn
            {directive, _meta, [{:__aliases__, _, _} | _]} = node, acc
            when directive in [:import, :alias] ->
              {node, [{directive, render_directive(node)} | acc]}

            node, acc ->
              {node, acc}
          end)

        acc
        |> Enum.reverse()
        |> Enum.uniq()
        |> Enum.group_by(fn {d, _} -> d end, fn {_, line} -> line end)

      _ ->
        %{}
    end
  end

  defp render_directive(node), do: node |> Macro.to_string() |> String.trim()

  # the module passed to `use <App>Web` — e.g. "PositionDbWeb" from
  # `use PositionDbWeb, :live_view`. nil when no such use is present.
  defp use_web_arg(source) do
    case Regex.run(~r/^\s*use\s+([A-Z][\w.]*Web)\s*,/m, source) do
      [_, web] -> web
      _ -> nil
    end
  end

  # ---- cross-file plan (prepare) -------------------------------------------

  defp prepared_for_paths(paths, opts) do
    excluded = core_components_module(opts)

    sources =
      paths
      |> Enum.flat_map(fn p ->
        case File.read(p) do
          {:ok, src} -> [{p, src}]
          _ -> []
        end
      end)
      |> Enum.reject(fn {_p, src} -> excluded_source?(src, excluded) end)
      |> Map.new()

    plans = build_plan(sources, opts)
    source_to_file = Map.new(sources, fn {path, src} -> {src, path} end)
    {:ok, %{plans: plans, source_to_file: source_to_file}}
  end

  @doc """
  Corpus pass: one plan entry per accepted candidate across `sources`
  (`%{path => source}`). Names are threaded so two **distinct** components never
  collide, and **structurally identical** subtrees reading the same assigns
  converge on one shared component.
  """
  @spec build_plan(%{String.t() => String.t()}, keyword()) :: [plan()]
  def build_plan(sources, opts \\ []) do
    namespace = components_namespace(opts)

    {plans, _ctx} =
      sources
      |> Enum.sort_by(fn {path, _src} -> path end)
      |> Enum.reduce({[], naming_ctx()}, fn {path, source}, {acc, ctx} ->
        {file_plans, ctx} = plans_for_file(source, path, namespace, ctx)
        {acc ++ file_plans, ctx}
      end)

    plans
  end

  defp naming_ctx, do: %{taken: MapSet.new(), cache: %{}}

  defp plans_for_file(source, path, namespace, ctx) do
    gates = %{
      min_nodes: @min_nodes,
      min_lines: @min_lines,
      live_component?: live_component?(source),
      context: caller_context(source)
    }

    case Tree.from_source(source) do
      {:ok, sigils} -> accepted_plans(sigils, source, path, namespace, gates, ctx)
      :error -> {[], ctx}
    end
  end

  defp accepted_plans(sigils, source, path, namespace, gates, ctx) do
    ranges = sigil_ranges(source)

    sigils
    |> Enum.zip(ranges)
    |> Enum.reduce({[], ctx}, fn {sigil, _range}, {acc, ctx} ->
      {cuts, ctx} = plan_cuts_for_sigil(sigil, path, namespace, gates, ctx)
      {acc ++ cuts, ctx}
    end)
  end

  defp plan_cuts_for_sigil(sigil, path, namespace, gates, ctx) do
    accepted =
      sigil.tree
      |> all_subtrees()
      |> Enum.uniq_by(fn node -> Tree.node_byte_range(node, sigil.body) end)
      |> Enum.map(fn node -> {node, analyze(node, sigil, gates, path)} end)
      |> Enum.filter(fn {_node, c} -> c != nil and c.accepted end)

    chosen = max_disjoint_cuts(accepted, sigil.body)

    chosen
    |> Enum.sort_by(fn {_node, _c, {s, _e}} -> s end)
    |> Enum.reduce({[], ctx}, fn {node, c, {s, e}}, {cuts, ctx} ->
      dedup_key = {Motif.key(node), c.assigns}

      {name, cache} =
        ComponentNaming.derive_shared(node, MapSet.to_list(ctx.taken), ctx.cache,
          dedup_key: dedup_key
        )

      web_prefix = gates.context.use_arg
      markup = binary_part(sigil.body, s, e - s)

      plan = %{
        name: name,
        module: module_name(namespace, web_prefix, name),
        component_kind: c.component_kind,
        motif: c.motif,
        assigns: c.assigns,
        body: markup,
        node: node,
        file: path,
        range: {s, e},
        web_prefix: web_prefix,
        context: gates.context
      }

      ctx = %{taken: MapSet.put(ctx.taken, name), cache: cache}
      {cuts ++ [plan], ctx}
    end)
  end

  # the new module's fully-qualified name: configured namespace if any, else
  # `<App>Web.Components`, plus the camelised component name.
  defp module_name(namespace, web_prefix, name) do
    parent = namespace || default_namespace(web_prefix)
    "#{parent}.#{Macro.camelize(Atom.to_string(name))}"
  end

  defp default_namespace(nil), do: "Components"
  defp default_namespace(web_prefix), do: "#{web_prefix}.Components"

  # Greedy maximum disjoint set: largest accepted cut first, then the next
  # largest overlapping none already taken (overlapping cuts corrupt byte slices).
  defp max_disjoint_cuts(accepted, body) do
    accepted
    |> Enum.map(fn {node, c} -> {node, c, Tree.node_byte_range(node, body)} end)
    |> Enum.sort_by(fn {_node, c, _r} -> -c.nodes end)
    |> Enum.reduce([], fn {_node, _c, {s, e}} = cand, chosen ->
      overlaps? = Enum.any?(chosen, fn {_n2, _c2, {s2, e2}} -> not (e <= s2 or s >= e2) end)
      if overlaps?, do: chosen, else: [cand | chosen]
    end)
  end

  # ---- rewrite (enabled) ---------------------------------------------------

  defp rewrite(source, plans, opts, prepared) do
    write_root = Keyword.get(opts, :write_root, File.cwd!())
    dry_run? = Keyword.get(opts, :dry_run, false)

    unless dry_run?, do: write_component_files(plans, write_root)

    case resolve_target_file(source, opts, prepared) do
      file when is_binary(file) -> rewrite_occurrences(source, plans, file)
      _ -> source
    end
  end

  # Each distinct component → its own file. The component body + caller context
  # are taken from the plan's representative occurrence.
  defp write_component_files(plans, write_root) do
    plans
    |> Enum.uniq_by(& &1.module)
    |> Enum.each(fn plan ->
      module = String.to_atom("Elixir." <> plan.module)
      path = AstHelpers.shared_module_path(module, write_root, [plan.file])

      unless File.exists?(path) do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, render_module(plan))
      end
    end)
  end

  defp rewrite_occurrences(source, plans, file) do
    file_plans = Enum.filter(plans, &(&1.file == file))

    case file_plans do
      [] -> source
      _ -> source |> rewrite_sigils(file_plans) |> ensure_aliases(file_plans)
    end
  end

  defp rewrite_sigils(source, file_plans) do
    sigils = collect_sigils(source)
    ranges = sigil_ranges(source)

    sigils
    |> Enum.zip(ranges)
    |> Enum.flat_map(fn {sigil, range} -> sigil_patch(sigil, range, file_plans) end)
    |> patch_or_passthrough(source)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp sigil_patch(sigil, range, file_plans) do
    cuts = plans_in_sigil(file_plans, sigil)

    case cuts do
      [] ->
        []

      _ ->
        indent = String.duplicate(" ", range.start[:column] - 1)

        new_body =
          cuts
          |> Enum.sort_by(fn p -> -elem(p.range, 0) end)
          |> Enum.reduce(sigil.body, fn p, body ->
            {s, e} = p.range
            replace_range_with(body, s, e, render_invocation(p))
          end)

        rendered = render_sigil(new_body, indent)
        [Sourceror.Patch.new(%{start: range.start, end: range.end}, rendered, false)]
    end
  end

  defp plans_in_sigil(file_plans, sigil) do
    Enum.filter(file_plans, fn p ->
      {s, e} = p.range
      e <= byte_size(sigil.body) and binary_part(sigil.body, s, e - s) == p.body
    end)
  end

  # ---- module rendering ----------------------------------------------------

  defp render_module(%{component_kind: :live_component} = plan),
    do: render_live_component_module(plan)

  defp render_module(%{component_kind: :function} = plan),
    do: render_function_module(plan)

  defp render_function_module(plan) do
    """
    defmodule #{plan.module} do
    #{module_header(plan, ":html")}
    #{attr_decls(plan)}
      def #{plan.name}(assigns) do
        ~H\"\"\"
    #{indent(String.trim_trailing(plan.body), "    ")}
        \"\"\"
      end
    end
    """
  end

  # A `:live_component` carries NO `attr` declarations: `attr` binds to the next
  # function clause, which is `update/2` (arity 2) here — Phoenix rejects that
  # ("cannot declare attributes for function update/2"). The live_component's
  # assigns flow in through `update/2` and are validated at the call site, not
  # by `attr`. The read assigns are recorded as a `@moduledoc` note instead.
  defp render_live_component_module(plan) do
    """
    defmodule #{plan.module} do
    #{module_header(plan, ":live_component")}

      @doc \"\"\"
      Stateful component lifted from #{Path.basename(plan.file)}.
      Expects assigns: #{plan.assigns |> Enum.map_join(", ", &"`:#{&1}`")}.
      \"\"\"
      @impl true
      def update(assigns, socket) do
        {:ok, assign(socket, assigns)}
      end

      @impl true
      def render(assigns) do
        ~H\"\"\"
    #{indent(String.trim_trailing(plan.body), "    ")}
        \"\"\"
      end
    end
    """
  end

  # `use <App>Web, :html|:live_component` (reproducing the caller's web prefix)
  # plus the caller's import/alias lines so sub-component/`~p` refs resolve.
  defp module_header(plan, use_arg) do
    use_line =
      case plan.web_prefix do
        nil ->
          "  use Phoenix.#{if use_arg == ":live_component", do: "LiveComponent", else: "Component"}"

        web ->
          "  use #{web}, #{use_arg}"
      end

    # aliases first, then imports: an `import Foo.Bar` written alias-relative in
    # the caller (`import Bar` after `alias Foo.Bar`) only resolves if the alias
    # is established first. Keep only directives the body actually references —
    # carrying the caller's whole import block would litter the module with
    # unused-alias/import warnings.
    body_tokens = body_tokens(plan.body)
    # local component tags in the body (`<.item_row>` → "item_row"). A plain
    # `import Foo.Bar` is kept only when the body calls `<.bar>` (snake_case of
    # the module's last segment, the Phoenix convention) — so a body using
    # `<.item_row>` does not drag in every sibling component import.
    local_components = local_component_tags(plan.node)

    ctx_lines =
      (plan.context.aliases ++ plan.context.imports)
      |> Enum.filter(&directive_used?(&1, body_tokens, local_components))
      |> Enum.map(&indent(&1, "  "))

    Enum.join([use_line | ctx_lines], "\n")
  end

  defp local_component_tags(node) do
    Tree.walk(node, MapSet.new(), fn
      {:element, "." <> rest, _attrs, _ch, _}, acc ->
        if rest =~ ~r/^[a-z_][a-zA-Z0-9_]*$/, do: MapSet.put(acc, rest), else: acc

      _o, acc ->
        acc
    end)
  end

  # the set of identifier tokens appearing in the lifted body
  defp body_tokens(body) do
    ~r/[A-Za-z_][A-Za-z0-9_]*/
    |> Regex.scan(body)
    |> List.flatten()
    |> MapSet.new()
  end

  # An `alias`/`import` directive is kept iff a name it introduces appears in the
  # body. We can only enumerate the introduced names for an `alias` (its bound
  # name — `alias Foo.Bar, as: Baz` → `Baz`, else `Bar`) and an
  # `import …, only: [f: n]` (the function names). A **plain `import Module`**
  # exposes that module's functions in snake_case (`<.asset_preview>` from
  # `import …AssetPreview`) which the module name does not echo — so a plain
  # import is always kept (conservative: an unused-import warning beats an
  # undefined-function compile error).
  defp directive_used?(directive, tokens, local_components) do
    case directive_names(directive) do
      :plain_import -> plain_import_used?(directive, local_components)
      names -> Enum.any?(names, &MapSet.member?(tokens, &1))
    end
  end

  # Keep a plain `import Foo.Bar` when the body uses a local `<.xxx>` it could
  # plausibly provide. A **single-component** module (`ItemRow`) provides
  # `<.item_row>` by Phoenix convention → keep iff that exact tag is present. A
  # **collection** module (`*Components`/`*Layouts`) exports many arbitrarily
  # named components → we cannot map names statically, so keep it whenever the
  # body has any local component tag (conservative: an unused-import warning
  # beats dropping a needed import and breaking compile).
  defp plain_import_used?(directive, local_components) do
    seg = last_segment(directive)

    cond do
      not is_binary(seg) -> false
      MapSet.member?(local_components, Macro.underscore(seg)) -> true
      collection_module_segment?(seg) -> MapSet.size(local_components) > 0
      true -> false
    end
  end

  defp collection_module_segment?(seg),
    do: String.ends_with?(seg, "Components") or String.ends_with?(seg, "Layouts")

  defp directive_names(directive) do
    cond do
      names = import_only_names(directive) -> names
      as_name = alias_as_name(directive) -> [as_name]
      plain_import?(directive) -> :plain_import
      true -> [last_segment(directive)]
    end
  end

  defp plain_import?(directive), do: directive =~ ~r/^\s*import\b/

  defp import_only_names(directive) do
    case Regex.run(~r/only:\s*\[(.+)\]/, directive) do
      [_, inner] ->
        Regex.scan(~r/([a-z_][a-zA-Z0-9_]*):/, inner) |> Enum.map(fn [_, n] -> n end)

      _ ->
        nil
    end
  end

  defp alias_as_name(directive) do
    case Regex.run(~r/\bas:\s*([A-Z][A-Za-z0-9_]*)/, directive) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp last_segment(directive) do
    case Regex.run(~r/(?:alias|import)\s+([A-Z][\w.]*)/, directive) do
      [_, mod] -> mod |> String.split(".") |> List.last()
      _ -> directive
    end
  end

  defp attr_decls(plan) do
    plan.assigns
    |> Enum.map_join("\n", fn a ->
      "  attr #{inspect(String.to_atom(a))}, #{inspect(AttrType.infer(a, plan.node))}"
    end)
  end

  defp render_invocation(%{component_kind: :live_component} = plan) do
    attrs = Enum.map_join(plan.assigns, " ", fn a -> "#{a}={@#{a}}" end)
    id = "\"#{plan.name}\""
    base = "<.live_component module={#{plan.module}} id={#{id}}"
    if attrs == "", do: base <> " />", else: base <> " " <> attrs <> " />"
  end

  defp render_invocation(%{component_kind: :function} = plan) do
    local = local_alias(plan.module)
    attrs = Enum.map_join(plan.assigns, " ", fn a -> "#{a}={@#{a}}" end)
    base = "<#{local}.#{plan.name}"
    if attrs == "", do: base <> " />", else: base <> " " <> attrs <> " />"
  end

  # the last module segment, used as the call-site alias: `MyApp.Components.Foo`
  # → `<Foo.foo .../>` after `alias MyApp.Components.Foo`.
  defp local_alias(module), do: module |> String.split(".") |> List.last()

  # Add `alias <Module>` for every function-component plan, just after the
  # module's `use` line, unless already present.
  defp ensure_aliases(source, file_plans) do
    aliases =
      file_plans
      |> Enum.filter(&(&1.component_kind == :function))
      |> Enum.map(&"  alias #{&1.module}")
      |> Enum.uniq()
      |> Enum.reject(&String.contains?(source, String.trim(&1)))

    case aliases do
      [] -> source
      _ -> insert_after_use(source, Enum.join(aliases, "\n"))
    end
  end

  defp insert_after_use(source, text) do
    lines = String.split(source, "\n", trim: false)

    idx =
      Enum.find_index(lines, fn line -> Regex.match?(~r/^\s*use\s+[A-Z][\w.]*/, line) end)

    case idx do
      nil -> source
      i -> lines |> List.insert_at(i + 1, text) |> Enum.join("\n")
    end
  end

  defp render_sigil(body, indent) do
    indented =
      body
      |> String.split("\n", trim: false)
      |> Enum.map_join("\n", fn
        "" -> ""
        line -> indent <> line
      end)

    "~H\"\"\"\n" <> indented <> indent <> "\"\"\""
  end

  defp replace_range_with(body, s, e, replacement) do
    binary_part(body, 0, s) <> replacement <> binary_part(body, e, byte_size(body) - e)
  end

  defp indent(text, pad) do
    text
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> pad <> line
    end)
  end

  # ---- source helpers ------------------------------------------------------

  defp collect_sigils(source) do
    case Tree.from_source(source) do
      {:ok, sigils} -> sigils
      :error -> []
    end
  end

  defp sigil_ranges(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        {_ast, acc} =
          Macro.prewalk(ast, [], fn
            {:sigil_H, _, _} = node, acc -> {node, [Sourceror.get_range(node) | acc]}
            node, acc -> {node, acc}
          end)

        Enum.reverse(acc)

      _ ->
        []
    end
  end

  defp resolve_target_file(source, opts, prepared) do
    case opts[:file] do
      file when is_binary(file) -> file
      _ -> prepared |> Map.get(:source_to_file, %{}) |> Map.get(source)
    end
  end

  defp components_namespace(opts), do: heex_config(opts, :components_namespace)
  defp core_components_module(opts), do: heex_config(opts, :core_components_module)

  defp heex_config(opts, key) do
    opts
    |> Keyword.get(:project_config, %{})
    |> Map.get(:heex, %{})
    |> Map.get(key)
  end

  defp excluded_source?(_src, nil), do: false

  defp excluded_source?(src, module),
    do: Regex.match?(~r/^defmodule\s+#{Regex.escape(module)}\b/m, src)

  # ---- shared measures + safety (mirrors ExtractHeexComponentBySeam) --------

  defp live_component?(source) do
    source =~ ~r/use\s+Phoenix\.LiveComponent\b/ or
      source =~ ~r/use\s+[\w.]+,\s*:live_component\b/
  end

  defp framework_assign(own), do: Enum.find(@framework_assigns, &MapSet.member?(own, &1))

  defp collapses_stateful_root?(_node, _sigil, %{live_component?: false}), do: false

  defp collapses_stateful_root?(node, sigil, _gates) do
    case top_level_elements(sigil.tree) do
      [^node] -> true
      _ -> false
    end
  end

  defp top_level_elements(tree) do
    Enum.filter(tree, fn
      {:element, _, _, _, _} -> true
      {:eex_block, _, _, _} -> true
      _ -> false
    end)
  end

  defp orphan_slot?(node), do: orphan_slot?(node, false)

  defp orphan_slot?({:element, tag, _attrs, children, _}, in_component?) do
    cond do
      slot_entry?(tag) and not in_component? -> true
      true -> Enum.any?(children, &orphan_slot?(&1, in_component? or component_tag?(tag)))
    end
  end

  defp orphan_slot?({:eex_block, _code, children, _}, in_component?),
    do: Enum.any?(children, &orphan_slot?(&1, in_component?))

  defp orphan_slot?(_other, _in_component?), do: false

  defp slot_entry?(tag), do: String.starts_with?(tag, ":")
  defp component_tag?(tag), do: String.starts_with?(tag, ".") or tag =~ ~r/^[A-Z]/

  defp node_count(node), do: Tree.walk(node, 0, fn _n, acc -> acc + 1 end)

  defp lines_of(node, body) do
    {s, e} = Tree.node_byte_range(node, body)
    binary_part(body, s, e - s) |> String.split("\n") |> length()
  end

  defp line_of(node, sigil) do
    {s, _e} = Tree.node_byte_range(node, sigil.body)
    prefix = binary_part(sigil.body, 0, s)
    sigil.file_line + (prefix |> :binary.matches("\n") |> length()) + 1
  end

  defp kind_and_tag({:element, tag, _, _, _}), do: {:element, tag}
  defp kind_and_tag({:eex_block, _, _, _}), do: {:eex_block, "eex_block"}

  defp component_invocation?({:element, tag, _attrs, children, _}) do
    (String.starts_with?(tag, ".") or tag =~ ~r/^[A-Z]/) and
      Enum.all?(children, fn
        {:element, _, _, _, _} -> false
        _ -> true
      end)
  end

  defp whole_sigil?(node, sigil) do
    case sigil.tree do
      [single] -> single == node
      _ -> false
    end
  end

  defp assigns_in(node) do
    Tree.walk(node, MapSet.new(), fn
      {:eex_expr, code, _}, acc -> MapSet.union(acc, assigns_from_code(code))
      {:eex_block, code, _, _}, acc -> MapSet.union(acc, assigns_from_code(code))
      {:element, _t, attrs, _ch, _}, acc -> MapSet.union(acc, attr_assigns(attrs))
      _o, acc -> acc
    end)
  end

  defp attr_assigns(attrs) do
    Enum.reduce(attrs, MapSet.new(), fn
      {_n, {:expr, code}}, acc -> MapSet.union(acc, assigns_from_code(code))
      _, acc -> acc
    end)
  end

  defp assigns_from_code(code) when is_binary(code) do
    at_form = scan_assign_names(~r/@(#{@assign_name})/, code)
    fields = scan_assign_names(~r/assigns\.(#{@assign_name})/, code)
    MapSet.union(at_form, fields)
  end

  defp assigns_from_code(_), do: MapSet.new()

  defp scan_assign_names(regex, code) do
    regex
    |> Regex.scan(code)
    |> Enum.map(fn [_, n] -> n end)
    |> MapSet.new()
  end
end
