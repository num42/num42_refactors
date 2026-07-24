defmodule Number42.Refactors.Ex.ExtractHeexComponentBySeam do
  @moduledoc """
  Force an under-componentised `~H` template toward good structure by
  extracting a large, cohesive subtree into a private `attr`-declared
  function-component in the same module, replacing the subtree with a
  `<.name .../>` call.

  This is the template-level analogue of `SplitLowCohesionModule`:
  **detection is the whole problem; the rewrite is mechanical.** A wrong
  cut produces a still-compiling but structurally-wrong template, which
  is worse than no cut — so it declines aggressively.

  ## Why a clean assign seam, not a semantic tag

  Measured across well- and badly-factored codebases, messy templates
  hide component boundaries behind generic `<div>` (only ~2% of large
  cuts sit on a semantic element vs. ~18% in a well-factored app). A
  semantic-tag gate would miss exactly the templates that need help. The
  discriminating, codebase-adaptive signal is a **clean assign seam**: a
  subtree reads a set of `@assign`s that are mostly *not* used elsewhere
  in the same sigil. Such a subtree is a self-contained renderable unit.

  ## Detection

  A candidate is an `:element` or `:eex_block` subtree of a `~H` sigil with:

    * size: at least `#{6}` nodes and `#{12}` lines;
    * reads at least one `@assign`;
    * **assign leak ≤ `#{0.25}`** — of the assigns it reads, at most this
      fraction are also referenced outside the subtree (measured against
      tree siblings via byte-range containment);
    * **no free non-assign variable** (`Number42.Refactors.Analysis.Heex.Scope`) —
      a variable bound outside the cut (a `for` generator, a `:let` slot,
      a local assignment) would break the standalone component.

  Decline if the subtree is itself a single `<.component>` call (nothing
  gained) or is the entire sigil body (no reduction).

  ## Default-OFF (opt-in only)

  `transform/2` is a no-op unless the module's opts carry `enabled: true`.
  `find_candidates/1` is always available for `--dry-run`/diagnostics.

      {Number42.Refactors.Ex.ExtractHeexComponentBySeam, enabled: true}
  """

  @behaviour Number42.Refactors.Refactor

  alias Number42.Refactors.Analysis.Heex.{AttrType, ComponentNaming, Scope, Tree}

  @min_nodes 6
  @min_lines 12
  @max_leak 0.25

  @type candidate :: %{
          kind: :element | :eex_block,
          tag: String.t(),
          nodes: non_neg_integer(),
          lines: non_neg_integer(),
          assigns: [String.t()],
          leak: float(),
          free_vars: [String.t()],
          accepted: boolean(),
          decline: String.t() | nil,
          enclosing_fn: atom() | nil
        }

  @impl Number42.Refactors.Refactor
  def description,
    do:
      "Extract a cohesive ~H subtree into a private function-component along a clean assign seam"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    An under-componentised LiveView render function hides renderable units
    (a card, a panel, a list) inside one big template. Where a subtree reads
    a set of assigns that are not used elsewhere in the sigil — a clean
    assign seam — it is a self-contained component waiting to be named.
    Lifting it into a private `attr`-declared function-component makes the
    unit explicit, gives it a grep-able name, and lets the diff engine reason
    about it independently. Detection insists the cut be safe (no variable
    bound outside it leaks in), so the extracted component compiles and
    renders identically.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def priority, do: 10

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      rewrite(source)
    else
      source
    end
  end

  # Extract one component per sigil (the highest-scoring accepted candidate),
  # planting the private component before the module's final `end` and
  # replacing the inline markup with a `<.name .../>` call. One cut/sigil keeps
  # byte offsets stable within a pass; multiple/nested cuts are Slice 5.
  #
  # The sigil body that `Tree` exposes is dedented (LiveView strips the common
  # leading indentation), so we cannot string-replace the cut fragment back into
  # the raw source. Instead we rewrite the body in body-space, then replace the
  # whole sigil via its real source range (from Sourceror), re-indented to the
  # sigil's column. This mirrors `ExtractHeexFor`.
  defp rewrite(source) do
    with {:ok, sigils} <- Tree.from_source(source),
         {:ok, ast} <- Sourceror.parse_string(source) do
      ranges = sigil_ranges(ast)
      taken = module_taken_names(source)
      gates = production_gates(source)

      # thread `taken` through every cut (across sigils) so no two extracted
      # components collide on a name
      {plans, _taken} =
        sigils
        |> Enum.zip(ranges)
        |> Enum.reduce({[], taken}, fn {sigil, range}, {plans, taken} ->
          {plan, taken} = plan_for_sigil(sigil, range, gates, taken)
          if plan, do: {[plan | plans], taken}, else: {plans, taken}
        end)

      apply_plans(source, Enum.reverse(plans))
    else
      _ -> source
    end
  end

  defp production_gates(source) do
    %{
      min_nodes: @min_nodes,
      min_lines: @min_lines,
      max_leak: @max_leak,
      live_component?: live_component?(source)
    }
  end

  # A `Phoenix.LiveComponent`'s `render/1` must keep a single STATIC HTML tag at
  # its root; a function component has no such rule. Detecting the `use` lets the
  # stateful-root guard (#294 Bug C) apply only where it can actually break.
  defp live_component?(source) do
    source =~ ~r/use\s+Phoenix\.LiveComponent\b/ or
      source =~ ~r/use\s+[\w.]+,\s*:live_component\b/
  end

  # Names already bound in the module that a new `defp <name>(assigns)` would
  # shadow: module-local `def`/`defp` heads, and components invoked as `<.foo>`
  # (which must be imported, so the import would clash). The `Phoenix.Component`
  # builtins and `CoreComponents` generator defaults are reserved inside
  # `ComponentNaming` itself, so they need not be repeated here.
  defp module_taken_names(source) do
    locals =
      ~r/^\s*defp?\s+([a-z_][a-zA-Z0-9_]*)\s*[(\s]/m
      |> Regex.scan(source)
      |> Enum.map(fn [_, n] -> String.to_atom(n) end)

    invoked =
      ~r/<\.([a-z_][a-zA-Z0-9_]*)/
      |> Regex.scan(source)
      |> Enum.map(fn [_, n] -> String.to_atom(n) end)

    Enum.uniq(locals ++ invoked)
  end

  # `{:sigil_H, ...}` nodes in document order with their source ranges.
  defp sigil_ranges(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:sigil_H, _, _} = node, acc -> {node, [Sourceror.get_range(node) | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(acc)
  end

  # A sigil plan carries every disjoint cut to make. Returns the updated `taken`
  # set so names stay unique across sigils.
  defp plan_for_sigil(sigil, range, gates, taken) do
    accepted =
      sigil.tree
      |> all_subtrees()
      |> Enum.uniq_by(fn node -> Tree.node_byte_range(node, sigil.body) end)
      |> Enum.map(fn node -> {node, analyze(node, sigil, gates)} end)
      |> Enum.filter(fn {_node, c} -> c != nil and c.accepted end)

    case max_disjoint_cuts(accepted, sigil.body) do
      [] ->
        {nil, taken}

      chosen ->
        # name each cut, threading `taken` so siblings stay distinct; keep them
        # in document order (ascending start byte) for a stable, readable rewrite
        {cuts, taken} =
          chosen
          |> Enum.sort_by(fn {_node, _c, {s, _e}} -> s end)
          |> Enum.reduce({[], taken}, fn {node, c, {s, e}}, {cuts, taken} ->
            name = ComponentNaming.derive(node, taken)
            markup = binary_part(sigil.body, s, e - s)
            cut = %{range: {s, e}, markup: markup, name: name, assigns: c.assigns, node: node}
            {[cut | cuts], [name | taken]}
          end)

        {%{sigil: sigil, range: range, cuts: Enum.reverse(cuts)}, taken}
    end
  end

  # Greedy maximum disjoint set: take the largest accepted cut, then the next
  # largest that overlaps none already taken, and so on. Overlapping cuts (an
  # outer subtree and one nested in it) would corrupt each other's byte slices,
  # so only mutually disjoint ranges are ever applied to one sigil.
  defp max_disjoint_cuts(accepted, body) do
    accepted
    |> Enum.map(fn {node, c} -> {node, c, Tree.node_byte_range(node, body)} end)
    |> Enum.sort_by(fn {_node, c, _r} -> -c.nodes end)
    |> Enum.reduce([], fn {_node, _c, {s, e}} = cand, chosen ->
      overlaps? =
        Enum.any?(chosen, fn {_n2, _c2, {s2, e2}} -> not (e <= s2 or s >= e2) end)

      if overlaps?, do: chosen, else: [cand | chosen]
    end)
  end

  defp apply_plans(source, []), do: source

  defp apply_plans(source, plans) do
    patches = Enum.map(plans, &sigil_patch/1)
    components = Enum.map_join(plans, "\n", &render_plan_components/1)

    source
    |> Sourceror.patch_string(patches)
    |> insert_before_module_end(components)
  end

  # Replace the sigil's source range with a re-indented sigil whose body has each
  # disjoint cut fragment swapped for its component invocation. Cuts are spliced
  # right-to-left so earlier byte offsets stay valid while later ones are edited.
  defp sigil_patch(plan) do
    indent = String.duplicate(" ", plan.range.start[:column] - 1)

    new_body =
      plan.cuts
      |> Enum.sort_by(fn cut -> -elem(cut.range, 0) end)
      |> Enum.reduce(plan.sigil.body, fn cut, body ->
        {s, e} = cut.range
        replace_range_with(body, s, e, render_invocation(cut))
      end)

    rendered = render_sigil(new_body, indent)
    Sourceror.Patch.new(%{start: plan.range.start, end: plan.range.end}, rendered, false)
  end

  defp render_plan_components(plan), do: Enum.map_join(plan.cuts, "\n", &render_component/1)

  defp render_component(cut) do
    markup = String.trim_trailing(cut.markup)

    attrs =
      Enum.map_join(cut.assigns, "\n", fn a ->
        "  attr #{inspect(String.to_atom(a))}, #{inspect(AttrType.infer(a, cut.node))}"
      end)

    """

    #{attrs}
      defp #{cut.name}(assigns) do
        ~H\"\"\"
    #{indent(markup, "    ")}
        \"\"\"
      end
    """
  end

  defp replace_range_with(body, s, e, replacement) do
    binary_part(body, 0, s) <> replacement <> binary_part(body, e, byte_size(body) - e)
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

  defp render_invocation(cut) do
    attrs = Enum.map_join(cut.assigns, " ", fn a -> "#{a}={@#{a}}" end)

    case attrs do
      "" -> "<.#{cut.name} />"
      _ -> "<.#{cut.name} #{attrs} />"
    end
  end

  defp indent(text, pad) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> pad <> line
    end)
  end

  # Splice the component defs in just before the module's final top-level `end`.
  defp insert_before_module_end(source, components) do
    lines = String.split(source, "\n", trim: false)

    end_index =
      lines
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {line, idx} -> if String.trim(line) == "end", do: idx end)

    case end_index do
      nil ->
        source

      idx ->
        {before, rest} = Enum.split(lines, idx)
        Enum.join(before ++ [components | rest], "\n")
    end
  end

  @doc """
  Diagnostic: every candidate subtree in `source`, each annotated with its
  size, assign seam, leak, free variables, and whether it is `accepted` or
  the reason it was `decline`d. Read-only.

  Thresholds are configurable (defaults are the production values from the
  cross-codebase calibration): `:min_nodes` (#{@min_nodes}), `:min_lines`
  (#{@min_lines}), `:max_leak` (#{@max_leak}).
  """
  @spec find_candidates(String.t(), keyword()) :: [candidate]
  def find_candidates(source, opts \\ []) do
    gates = %{
      min_nodes: Keyword.get(opts, :min_nodes, @min_nodes),
      min_lines: Keyword.get(opts, :min_lines, @min_lines),
      max_leak: Keyword.get(opts, :max_leak, @max_leak),
      live_component?: live_component?(source)
    }

    case Tree.from_source(source) do
      {:ok, sigils} -> Enum.flat_map(sigils, &candidates_in_sigil(&1, gates))
      :error -> []
    end
  end

  defp candidates_in_sigil(sigil, gates) do
    sigil.tree
    |> all_subtrees()
    |> Enum.uniq_by(fn node -> Tree.node_byte_range(node, sigil.body) end)
    |> Enum.map(&analyze(&1, sigil, gates))
    |> Enum.reject(&is_nil/1)
  end

  # every element/block node anywhere in the tree
  defp all_subtrees(tree) do
    Tree.walk(tree, [], fn
      {:element, _, _, _, _} = n, acc -> [n | acc]
      {:eex_block, _, _, _} = n, acc -> [n | acc]
      _other, acc -> acc
    end)
  end

  defp analyze(node, sigil, gates) do
    nodes = node_count(node)
    lines = lines_of(node, sigil.body)

    if nodes < gates.min_nodes or lines < gates.min_lines do
      nil
    else
      own = assigns_in(node)
      range = Tree.node_byte_range(node, sigil.body)
      outside = assigns_outside(sigil.tree, sigil.body, range)
      leak = leak_ratio(own, outside)
      free = Scope.free_nonassign_vars(node) |> MapSet.to_list() |> Enum.sort()

      {kind, tag} = kind_and_tag(node)
      decline = decline_reason(node, sigil, own, leak, free, kind, gates)

      %{
        kind: kind,
        tag: tag,
        nodes: nodes,
        lines: lines,
        assigns: MapSet.to_list(own) |> Enum.sort(),
        leak: Float.round(leak, 2),
        free_vars: free,
        accepted: is_nil(decline),
        decline: decline,
        enclosing_fn: sigil.enclosing_fn
      }
    end
  end

  # The first failing safety check names the decline; `nil` means the cut is
  # accepted. Each predicate is a thunk so they short-circuit in order — cheap
  # checks (size, slot membership) gate the AST-walking ones.
  defp decline_reason(node, sigil, own, leak, free, kind, gates) do
    [
      {fn -> MapSet.size(own) == 0 end, "reads no assigns"},
      {fn -> framework_assign(own) != nil end,
       "reads framework-managed @#{framework_assign(own)} (not a plain attr)"},
      {fn -> leak > gates.max_leak end,
       "assign leak #{Float.round(leak, 2)} > #{gates.max_leak}"},
      {fn -> free != [] end, "free non-assign vars: #{Enum.join(free, ", ")}"},
      {fn -> orphan_slot?(node) end, "carries a slot entry away from its parent component"},
      {fn -> kind == :element and component_invocation?(node) end,
       "subtree is itself a component call"},
      {fn -> whole_sigil?(node, sigil) end, "subtree is the entire sigil body"},
      {fn -> collapses_stateful_root?(node, sigil, gates) end,
       "would leave a non-static stateful root"}
    ]
    |> Enum.find_value(fn {predicate, reason} -> if predicate.(), do: reason end)
  end

  # Phoenix/LiveView populates these assigns on the socket itself; they are not
  # plain values an extracted component can take as an `attr` (`@uploads` from
  # `allow_upload/3`, `@inner_block` the default slot, `@streams` the stream
  # registry, `@flash`/`@socket`/`@myself` connection state). A cut reading any
  # of them cannot be lifted to a standalone attr-only component (#294).
  @framework_assigns ~w(inner_block uploads streams flash socket myself)
  defp framework_assign(own) do
    Enum.find(@framework_assigns, &MapSet.member?(own, &1))
  end

  # ---- #294 Bug C: stateful single-static-root invariant -------------------

  # A `Phoenix.LiveComponent`'s `render/1` must keep a single static HTML tag at
  # the root. The seam replaces the cut subtree with a `<.name .../>` call. If
  # the cut is the render body's *sole top-level element* (any surrounding nodes
  # are only whitespace text), that call becomes the new single root — a
  # non-static component invocation — and render raises `ArgumentError`. The
  # existing `whole_sigil?` guard only catches a literally single-node tree
  # (`[element]`); it misses a tree of `[text, element, text]` where the element
  # is still the lone root. Decline that, for live_components only.
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

  # A slot entry `<:name>` must stay a direct child of its component. The cut is
  # unsafe if it contains a slot-entry element whose enclosing component is not
  # itself inside the cut — lifting it would orphan the slot. We descend from
  # the candidate root: a slot entry is safe only when reached through a
  # component element on the way down (which is then also extracted with it).
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

  # ---- node measures -------------------------------------------------------

  defp node_count(node), do: Tree.walk(node, 0, fn _n, acc -> acc + 1 end)

  defp lines_of(node, body) do
    {s, e} = Tree.node_byte_range(node, body)
    binary_part(body, s, e - s) |> String.split("\n") |> length()
  end

  defp kind_and_tag({:element, tag, _, _, _}), do: {:element, tag}
  defp kind_and_tag({:eex_block, _, _, _}), do: {:eex_block, "eex_block"}

  # a single `<.foo ... />` / `<Mod.foo ... />` with no element children
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

  # ---- assign seam ---------------------------------------------------------

  defp assigns_in(node) do
    Tree.walk(node, MapSet.new(), fn
      {:eex_expr, code, _}, acc -> MapSet.union(acc, assigns_from_code(code))
      {:eex_block, code, _, _}, acc -> MapSet.union(acc, assigns_from_code(code))
      {:element, _t, attrs, _ch, _}, acc -> MapSet.union(acc, attr_assigns(attrs))
      _o, acc -> acc
    end)
  end

  defp assigns_outside(tree, body, {cs, ce}) do
    Tree.walk(tree, MapSet.new(), fn node, acc ->
      {ns, _ne} = Tree.node_byte_range(node, body)

      if ns >= cs and ns < ce do
        acc
      else
        MapSet.union(acc, node_own_assigns(node))
      end
    end)
  end

  defp node_own_assigns({:eex_expr, code, _}), do: assigns_from_code(code)
  defp node_own_assigns({:eex_block, code, _, _}), do: assigns_from_code(code)
  defp node_own_assigns({:element, _t, attrs, _ch, _}), do: attr_assigns(attrs)
  defp node_own_assigns(_), do: MapSet.new()

  defp attr_assigns(attrs) do
    Enum.reduce(attrs, MapSet.new(), fn
      {_n, {:expr, code}}, acc -> MapSet.union(acc, assigns_from_code(code))
      _, acc -> acc
    end)
  end

  # `@name` reads and bare `assigns.<field>` reads both become attrs/call-site
  # args. Elixir var/assign names may end in a single `?`/`!`, so the charset
  # keeps that trailing char — truncating it (`@dev_entra_available?` ->
  # `dev_entra_available`) mismatches the spliced body against the generated
  # attr/call-site name (#294 Bug B).
  @assign_name "[a-z_][a-zA-Z0-9_]*[?!]?"

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

  defp leak_ratio(own, outside) do
    if MapSet.size(own) == 0 do
      1.0
    else
      MapSet.size(MapSet.intersection(own, outside)) / MapSet.size(own)
    end
  end
end
