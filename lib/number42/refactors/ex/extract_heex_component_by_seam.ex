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

  alias Number42.Refactors.Heex.{Scope, Tree}

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
  # Slice 4 wires the rewrite (gated on `enabled: true`). Until then this is a
  # strict no-op so the refactor is safe to register while detection is validated.
  def transform(source, _opts), do: source

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
      leak > max_leak -> "assign leak #{Float.round(leak, 2)} > #{max_leak}"
      free != [] -> "free non-assign vars: #{Enum.join(free, ", ")}"
      kind == :element and component_invocation?(node) -> "subtree is itself a component call"
      whole_sigil?(node, sigil) -> "subtree is the entire sigil body"
      true -> nil
    end
  end

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
