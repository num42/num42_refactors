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
    * **no free non-assign variable** (`Number42.Refactors.Heex.Scope`) —
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

  alias Number42.Refactors.Heex.{ComponentNaming, Scope, Tree}

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

      # thread `taken` through the sigils so two cuts never collide on a name
      {plans, _taken} =
        sigils
        |> Enum.zip(ranges)
        |> Enum.reduce({[], taken}, fn {sigil, range}, {plans, taken} ->
          case plan_for_sigil(sigil, range, taken) do
            nil -> {plans, taken}
            plan -> {[plan | plans], [plan.name | taken]}
          end
        end)

      apply_plans(source, Enum.reverse(plans))
    else
      _ -> source
    end
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

  defp plan_for_sigil(sigil, range, taken) do
    gates = %{min_nodes: @min_nodes, min_lines: @min_lines, max_leak: @max_leak}

    sigil.tree
    |> all_subtrees()
    |> Enum.uniq_by(fn node -> Tree.node_byte_range(node, sigil.body) end)
    |> Enum.map(fn node -> {node, analyze(node, sigil, gates)} end)
    |> Enum.filter(fn {_node, c} -> c != nil and c.accepted end)
    # largest accepted cut first — most markup removed from the render body
    |> Enum.max_by(fn {_node, c} -> c.nodes end, fn -> nil end)
    |> case do
      nil ->
        nil

      {node, c} ->
        {s, e} = Tree.node_byte_range(node, sigil.body)
        markup = binary_part(sigil.body, s, e - s)

        %{
          sigil: sigil,
          range: range,
          markup: markup,
          new_body: replace_range(sigil.body, s, e),
          name: ComponentNaming.derive(node, taken),
          assigns: c.assigns
        }
    end
  end

  defp apply_plans(source, []), do: source

  defp apply_plans(source, plans) do
    patches = Enum.map(plans, &sigil_patch/1)
    components = Enum.map_join(plans, "\n", &render_component/1)

    source
    |> Sourceror.patch_string(patches)
    |> insert_before_module_end(components)
  end

  # Replace the sigil's source range with a re-indented sigil whose body has the
  # cut fragment swapped for the component invocation.
  defp sigil_patch(plan) do
    indent = String.duplicate(" ", plan.range.start[:column] - 1)
    body_with_call = put_invocation(plan.new_body, plan)
    rendered = render_sigil(body_with_call, indent)
    Sourceror.Patch.new(%{start: plan.range.start, end: plan.range.end}, rendered, false)
  end

  # the dedented body, with the cut fragment already removed, re-spliced with the
  # invocation at the cut point (placeholder marker stitched in replace_range/3)
  defp put_invocation(new_body, plan) do
    String.replace(new_body, cut_marker(), render_invocation(plan), global: false)
  end

  defp render_component(plan) do
    markup = String.trim_trailing(plan.markup)

    attrs =
      Enum.map_join(plan.assigns, "\n", fn a -> "  attr #{inspect(String.to_atom(a))}, :any" end)

    """

    #{attrs}
      defp #{plan.name}(assigns) do
        ~H\"\"\"
    #{indent(markup, "    ")}
        \"\"\"
      end
    """
  end

  # leave a unique marker where the cut was, so put_invocation can place the call
  defp cut_marker, do: "\x00CUT\x00"

  defp replace_range(body, s, e) do
    binary_part(body, 0, s) <> cut_marker() <> binary_part(body, e, byte_size(body) - e)
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

  defp render_invocation(plan) do
    attrs = Enum.map_join(plan.assigns, " ", fn a -> "#{a}={@#{a}}" end)

    case attrs do
      "" -> "<.#{plan.name} />"
      _ -> "<.#{plan.name} #{attrs} />"
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
      max_leak: Keyword.get(opts, :max_leak, @max_leak)
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
      decline = decline_reason(node, sigil, own, leak, free, kind, gates.max_leak)

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

  defp decline_reason(node, sigil, own, leak, free, kind, max_leak) do
    cond do
      MapSet.size(own) == 0 -> "reads no assigns"
      MapSet.member?(own, "inner_block") -> "reads @inner_block (the implicit default slot)"
      leak > max_leak -> "assign leak #{Float.round(leak, 2)} > #{max_leak}"
      free != [] -> "free non-assign vars: #{Enum.join(free, ", ")}"
      orphan_slot?(node) -> "carries a slot entry away from its parent component"
      kind == :element and component_invocation?(node) -> "subtree is itself a component call"
      whole_sigil?(node, sigil) -> "subtree is the entire sigil body"
      true -> nil
    end
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

  defp assigns_from_code(code) when is_binary(code) do
    ~r/@([a-z_][a-zA-Z0-9_]*)/
    |> Regex.scan(code)
    |> Enum.map(fn [_, n] -> n end)
    |> MapSet.new()
  end

  defp assigns_from_code(_), do: MapSet.new()

  defp leak_ratio(own, outside) do
    if MapSet.size(own) == 0 do
      1.0
    else
      MapSet.size(MapSet.intersection(own, outside)) / MapSet.size(own)
    end
  end
end
