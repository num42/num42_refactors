defmodule Number42.Refactors.Ex.ProposeSharedHeexComponent do
  @moduledoc """
  Cross-file HEEx **motif** dedup: detect a recurring subtree *shape*
  that appears in many templates with different assign names and text,
  and propose a single shared function component for it — rewriting each
  occurrence into a call that passes its own values as attrs.

  This is the structural analogue of `ExtractHeexExactClone`, but a
  level higher. Exact-clone dedup only fuses byte-identical markup. The
  bigger lever — the one that finds a *missing abstraction* rather than a
  copy/paste — is the **motif**: a `data_table`, a `select_field`, a
  card that recurs across the codebase in the same shape but with
  per-page assigns and labels. Those differences are not noise to ignore;
  they are exactly the *parameters* of the component that should exist.

  ## Motif fingerprint (`Heex.Motif`)

  A motif key abstracts away assign names, EEx expression bodies,
  attribute *values*, and literal text, keeping the tag tree, the set of
  attribute *names* per element, and the dynamic-vs-static topology of
  every leaf. Two subtrees with the same motif key have identical
  structure and identical slot positions; they differ only in slot
  contents and attribute values — the per-occurrence inputs a shared
  component would take. Their slot lists (`Heex.Motif.slots/1`) line up
  positionally, so slot *i* of every occurrence is the same parameter.

  ## Recurrence threshold

  A motif is a candidate only when it recurs at least
  `#{3}` times (`:min_occurrences`) across at least `#{2}` distinct files
  (`:min_files`), and its representative subtree meets `:min_mass`
  (`#{8}` nodes). Single-file recurrence is left to the single-file
  seam/clone refactors; the cross-file bar is what makes this a
  codebase-level abstraction.

  ## Parameterisation and skip conditions (conservative by design)

  Cross-file rewrites are high-risk, so a candidate is **skipped** unless
  every occurrence can be parameterised cleanly:

    * **free non-assign variable** — if any occurrence reads a variable
      bound *outside* the subtree (a `for` generator, a `:let` slot, a
      local), the lifted component would not compile standalone. Skip.
    * **block slot** (`<%= for … %>` / `<%= if … %>`) — the binding
      names differ across occurrences and a loop is unsafe to flatten
      into one attr. A motif containing a block slot is skipped.
    * **bare component / whole sigil** — nothing is gained (mirrors
      `ExtractHeexComponentBySeam`).

  Each surviving dynamic `{…}` slot becomes exactly one `attr`. A slot
  whose expression is byte-identical across *all* occurrences stays
  literal in the shared component (it is part of the shape, not a
  parameter); a slot that varies becomes a parameter, named after the
  single assign it reads when every occurrence reads one same-shaped
  assign, else positionally (`arg_1`, `arg_2`, …).

  ## Default-OFF (report first, rewrite behind a flag)

  Auto-generating a shared component and rewriting N call sites across
  the codebase is the most invasive thing this engine does. So the
  refactor is **opt-in**: `transform/2` is a no-op unless the module's
  opts carry `enabled: true`. `build_plan/2` is always available for
  `--dry-run` reporting — measure precision on a real corpus before
  enabling any rewrite. The shared component is planted in the project's
  configured `CoreComponents` module (`.refactor.exs` →
  `%{heex: %{core_components_module: "MyAppWeb.CoreComponents"}}`);
  without that key the rewrite is a no-op.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Heex.Fingerprint
  alias Number42.Refactors.Heex.Motif
  alias Number42.Refactors.Heex.Scope
  alias Number42.Refactors.Heex.Tree

  @default_min_mass 8
  @default_min_occurrences 3
  @default_min_files 2

  @type param :: %{name: atom(), exprs: [String.t()]}

  @type occurrence :: %{
          file: String.t(),
          line: pos_integer(),
          node: Tree.node_t(),
          # the per-occurrence expression each varying slot forwards
          call_args: [String.t()]
        }

  @type plan :: %{
          name: atom(),
          key: binary(),
          mass: pos_integer(),
          params: [param()],
          body: String.t(),
          occurrences: [occurrence()]
        }

  @impl Number42.Refactors.Refactor
  def description,
    do: "Propose a shared CoreComponents function for a HEEx motif recurring across files"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A HEEx subtree shape that recurs across many templates — the same card,
    table, or field with different assigns and labels — is a missing shared
    component, not a copy/paste. We fingerprint subtrees modulo assign names
    and text (`Heex.Motif`), cluster motifs that recur across the codebase,
    and lift the recurring shape into a single function component whose
    varying leaves become attrs. Each occurrence is rewritten to a call that
    passes its own values. Detection is deliberately conservative: a motif is
    skipped unless every occurrence parameterises cleanly (no free non-assign
    variable, no loop slot), so the generated component compiles and renders
    identically. The result is one source of truth for a shape the codebase
    was already repeating.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def priority, do: 10

  @doc """
  Corpus pass: cluster motifs across `sources` (`%{path => source}`) and
  return one plan entry per motif that crosses the recurrence threshold
  and parameterises cleanly.

  Options: `:min_mass` (#{@default_min_mass}), `:min_occurrences`
  (#{@default_min_occurrences}), `:min_files` (#{@default_min_files}).
  """
  @spec build_plan(%{String.t() => String.t()}, keyword()) :: [plan()]
  def build_plan(sources, opts \\ []) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)
    min_occ = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
    min_files = Keyword.get(opts, :min_files, @default_min_files)

    sources
    |> Enum.flat_map(fn {path, source} -> motif_fragments(source, path, min_mass) end)
    |> Enum.group_by(& &1.key)
    |> Enum.flat_map(fn {key, frags} -> cluster_to_plan(key, frags, min_occ, min_files) end)
    |> drop_subset_plans()
    |> Enum.sort_by(&{-&1.mass, -length(&1.occurrences)})
    |> name_plans()
  end

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
         module when is_binary(module) <- core_components_module(opts),
         %{plans: plans} = prepared when plans != [] <- opts[:prepared] do
      rewrite(source, plans, module, opts, prepared)
    else
      _ -> source
    end
  end

  # ---- corpus pass ---------------------------------------------------------

  defp prepared_for_paths(paths, opts) do
    sources =
      paths
      |> Enum.flat_map(fn p ->
        case File.read(p) do
          {:ok, src} -> [{p, src}]
          _ -> []
        end
      end)
      |> Map.new()

    plans = build_plan(sources, opts)
    source_to_file = Map.new(sources, fn {path, src} -> {src, path} end)
    {:ok, %{plans: plans, source_to_file: source_to_file}}
  end

  # Every motif-bearing subtree of a source, with its motif key, mass,
  # slots, and absolute file line.
  defp motif_fragments(source, path, min_mass) do
    case Tree.from_source(source) do
      {:ok, sigils} -> Enum.flat_map(sigils, &fragments_in_sigil(&1, path, min_mass))
      :error -> []
    end
  end

  defp fragments_in_sigil(sigil, path, min_mass) do
    sigil.tree
    |> subtrees()
    |> Enum.filter(fn node -> Fingerprint.mass(node) >= min_mass end)
    |> Enum.flat_map(fn node -> fragment_or_skip(node, sigil, path) end)
  end

  defp fragment_or_skip(node, sigil, path) do
    if liftable?(node) do
      [
        %{
          key: Motif.key(node),
          mass: Fingerprint.mass(node),
          node: node,
          slots: Motif.slots(node),
          file: path,
          line: line_of(node, sigil)
        }
      ]
    else
      []
    end
  end

  # element/eex_block subtrees, in document order
  defp subtrees(tree) do
    Tree.walk(tree, [], fn
      {:element, _, _, _, _} = n, acc -> [n | acc]
      {:eex_block, _, _, _} = n, acc -> [n | acc]
      _other, acc -> acc
    end)
    |> Enum.reverse()
  end

  # A subtree is liftable iff it is self-contained: no free non-assign var,
  # not a bare component call, and no loop/cond block slot (the binding names
  # differ across occurrences — unsafe to parameterise). Unlike the single-file
  # seam refactor we do *not* decline a whole-sigil motif: a card that is the
  # entire render of three pages is still a real cross-file abstraction.
  defp liftable?(node) do
    MapSet.size(Scope.free_nonassign_vars(node)) == 0 and
      not bare_component?(node) and
      not has_block_slot?(node)
  end

  defp has_block_slot?(node) do
    node |> Motif.slots() |> Enum.any?(&(&1.kind == :block))
  end

  defp bare_component?({:element, tag, _attrs, children, _}) do
    component_tag?(tag) and
      Enum.all?(children, fn
        {:element, _, _, _, _} -> false
        _ -> true
      end)
  end

  defp bare_component?(_), do: false

  defp component_tag?(tag), do: String.starts_with?(tag, ".") or tag =~ ~r/^[A-Z]/

  defp line_of(node, sigil) do
    {s, _e} = Tree.node_byte_range(node, sigil.body)
    prefix = binary_part(sigil.body, 0, s)
    sigil.file_line + (prefix |> :binary.matches("\n") |> length()) + 1
  end

  # ---- clustering + parameterisation ---------------------------------------

  defp cluster_to_plan(key, frags, min_occ, min_files) do
    files = frags |> Enum.map(& &1.file) |> Enum.uniq()

    with true <- length(frags) >= min_occ,
         true <- length(files) >= min_files,
         {:ok, params, rep} <- parameterise(frags) do
      [build_plan_entry(key, frags, params, rep)]
    else
      _ -> []
    end
  end

  # Align slots positionally across occurrences. The motif key guarantees
  # identical slot counts; verify and classify each position as a fixed
  # literal (identical expr everywhere) or a parameter (it varies).
  defp parameterise(frags) do
    rep = Enum.min_by(frags, & &1.file)
    slot_count = length(rep.slots)

    if Enum.all?(frags, &(length(&1.slots) == slot_count)) do
      params =
        0..(slot_count - 1)//1
        |> Enum.flat_map(fn i -> param_at(i, frags) end)

      {:ok, params, rep}
    else
      :error
    end
  end

  # Slot i across all occurrences: parameter iff its expression varies.
  defp param_at(_i, frags) when frags == [], do: []

  defp param_at(i, frags) do
    exprs = Enum.map(frags, fn f -> Enum.at(f.slots, i).code end)

    if Enum.uniq(exprs) == [hd(exprs)] do
      # identical everywhere — stays literal in the shared body
      []
    else
      [%{index: i, exprs: exprs}]
    end
  end

  defp build_plan_entry(key, frags, params, rep) do
    %{
      key: key,
      mass: rep.mass,
      params: params,
      occurrences:
        frags
        |> Enum.map(fn f ->
          %{
            file: f.file,
            line: f.line,
            node: f.node,
            call_args: Enum.map(params, fn p -> Enum.at(f.slots, p.index).code end)
          }
        end)
        |> Enum.sort_by(&{&1.file, &1.line}),
      rep_node: rep.node,
      rep_slots: rep.slots
    }
  end

  # Drop a motif whose every occurrence sits inside a larger motif that also
  # clusters — keep the largest matching unit, like `Clones`.
  defp drop_subset_plans(plans) do
    sorted = Enum.sort_by(plans, & &1.mass, :desc)

    Enum.reject(sorted, fn small ->
      Enum.any?(sorted, fn big ->
        big.key != small.key and big.mass > small.mass and
          length(big.occurrences) >= length(small.occurrences) and
          contains_all?(big, small)
      end)
    end)
  end

  defp contains_all?(big, small) do
    big_ranges = Enum.map(big.occurrences, fn o -> {o.file, o.node} end)

    Enum.all?(small.occurrences, fn s ->
      Enum.any?(big_ranges, fn {f, n} -> f == s.file and subtree_member?(n, s.node) end)
    end)
  end

  defp subtree_member?(node, target) do
    Tree.walk(node, false, fn n, acc -> acc or n == target end)
  end

  # Name each surviving plan deterministically, threading taken names so two
  # motifs never collide.
  defp name_plans(plans) do
    {named, _taken} =
      Enum.reduce(plans, {[], MapSet.new()}, fn plan, {acc, taken} ->
        name = motif_name(plan, taken)

        {params, _param_taken} =
          plan.params
          |> Enum.with_index()
          |> Enum.reduce({[], MapSet.new()}, fn {p, idx}, {acc, param_taken} ->
            pname = param_name(p, idx, param_taken)
            param = %{name: pname, exprs: p.exprs, index: p.index}
            {[param | acc], MapSet.put(param_taken, pname)}
          end)

        params = Enum.reverse(params)

        finished =
          plan
          |> Map.put(:name, name)
          |> Map.put(:params, params)
          |> Map.put(:body, render_body(plan.rep_node, plan.rep_slots, params))
          |> Map.drop([:rep_node, :rep_slots])

        {[finished | acc], MapSet.put(taken, name)}
      end)

    Enum.reverse(named)
  end

  # Name from the dominant assign read across the motif's parameter slots,
  # else a stable hash suffix. Disambiguated against already-taken names.
  defp motif_name(plan, taken) do
    base =
      plan.params
      |> Enum.flat_map(fn p -> Enum.flat_map(p.exprs, &assigns_in/1) end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {name, count} -> {-count, name} end)
      |> List.first()
      |> case do
        {assign, _} -> :"shared_#{assign}"
        nil -> :"shared_motif_#{hash8(plan.key)}"
      end

    disambiguate(base, taken)
  end

  defp disambiguate(base, taken) do
    if MapSet.member?(taken, base) do
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(&suffixed_if_free(base, &1, taken))
    else
      base
    end
  end

  defp suffixed_if_free(base, n, taken) do
    cand = :"#{base}_#{n}"
    if MapSet.member?(taken, cand), do: false, else: cand
  end

  # Name a param after the **representative occurrence's** single bare assign
  # (`@title` → `:title`) — the param is the component's *local* name, so it
  # reads cleanly even when other call sites pass `@heading`/`@name` into it.
  # A slot that is not a single bare assign (a compound expression) is named
  # positionally. `taken` disambiguates params against each other within the
  # same component.
  defp param_name(%{exprs: [rep | _]}, idx, taken) do
    base =
      case assigns_in(rep) do
        [single] -> String.to_atom(single)
        _ -> :"arg_#{idx + 1}"
      end

    disambiguate(base, taken)
  end

  defp hash8(<<a, b, c, d, _::binary>>),
    do: Base.encode16(<<a, b, c, d>>, case: :lower)

  # ---- rendering -----------------------------------------------------------

  # Render the shared component body from the representative node, replacing
  # each parameter slot's expression with `@<param>` and leaving fixed slots
  # literal. `slot_params` maps slot index → param name.
  defp render_body(node, slots, params) do
    slot_params = Map.new(params, fn p -> {p.index, p.name} end)
    {rendered, _idx} = render(node, slots, slot_params, 0)
    rendered
  end

  defp render({:element, tag, attrs, children, _meta}, slots, sp, idx) do
    {rendered_attrs, idx} = render_attrs(attrs, slots, sp, idx)
    {rendered_children, idx} = render_children(children, slots, sp, idx)

    rendered =
      case children do
        [] -> "<#{tag}#{rendered_attrs} />"
        _ -> "<#{tag}#{rendered_attrs}>#{rendered_children}</#{tag}>"
      end

    {rendered, idx}
  end

  defp render({:eex_expr, code, _meta}, _slots, sp, idx) do
    {"{#{render_slot(code, sp, idx)}}", idx + 1}
  end

  defp render({:text, text, _meta}, _slots, _sp, idx), do: {text, idx}

  defp render_children(children, slots, sp, idx) do
    Enum.reduce(children, {"", idx}, fn child, {acc, i} ->
      {rendered, i} = render(child, slots, sp, i)
      {acc <> rendered, i}
    end)
  end

  defp render_attrs(attrs, _slots, sp, idx) do
    Enum.reduce(attrs, {"", idx}, fn
      {name, {:string, value}}, {acc, i} ->
        {acc <> ~s( #{name}="#{value}"), i}

      {name, {:expr, code}}, {acc, i} ->
        {acc <> " #{name}={#{render_slot(code, sp, i)}}", i + 1}
    end)
  end

  defp render_slot(code, slot_params, idx) do
    case Map.get(slot_params, idx) do
      nil -> code
      param -> "@#{param}"
    end
  end

  # ---- rewrite (enabled) ---------------------------------------------------

  defp rewrite(source, plans, module, opts, prepared) do
    cond do
      core_components_source?(source, module) ->
        append_components(source, plans)

      target = resolve_target_file(source, opts, prepared) ->
        rewrite_occurrences(source, plans, target)

      true ->
        source
    end
  end

  defp append_components(source, plans) do
    new_plans = Enum.reject(plans, &component_present?(source, &1))

    case {new_plans, module_end_line(source)} do
      {[], _} ->
        source

      {_, nil} ->
        source

      {_, end_line} ->
        defs = Enum.map_join(new_plans, "\n", &render_component_def/1)
        insert_before_line(source, end_line, defs)
    end
  end

  defp rewrite_occurrences(source, plans, file) do
    occs =
      Enum.flat_map(plans, fn plan ->
        plan.occurrences
        |> Enum.filter(&(&1.file == file))
        |> Enum.map(&{plan, &1})
      end)

    case occs do
      [] -> source
      _ -> rewrite_sigils(source, occs)
    end
  end

  defp rewrite_sigils(source, occs) do
    sigils = collect_sigils(source)

    occs
    |> Enum.flat_map(&match_to_sigil(&1, sigils))
    |> Enum.group_by(fn {sigil, _occ, _plan} -> sigil end, fn {_sigil, occ, plan} ->
      {occ, plan}
    end)
    |> Enum.map(fn {sigil, op} -> build_sigil_patch(sigil, op) end)
    |> patch_or_passthrough(source)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp match_to_sigil({plan, occ}, sigils) do
    case Enum.find(sigils, &sigil_contains_line?(&1, occ.line)) do
      nil -> []
      sigil -> [{sigil, occ, plan}]
    end
  end

  defp sigil_contains_line?(sigil, line) do
    body_lines = sigil.body |> :binary.matches("\n") |> length()
    sigil.file_line < line and line <= sigil.file_line + body_lines + 1
  end

  defp build_sigil_patch(sigil, occ_plans) do
    new_body = splice_calls(sigil.body, occ_plans)
    range = Sourceror.get_range(sigil.sigil_node)
    indent = String.duplicate(" ", range.start[:column] - 1)
    rendered = render_sigil(new_body, indent)
    Sourceror.Patch.new(%{end: range.end, start: range.start}, rendered, false)
  end

  defp splice_calls(body, occ_plans) do
    occ_plans
    |> Enum.map(fn {occ, plan} ->
      {Tree.node_byte_range(occ.node, body), render_call(plan, occ)}
    end)
    |> Enum.sort_by(fn {{start, _end}, _call} -> -start end)
    |> Enum.reduce(body, fn {{start, stop}, call}, acc ->
      binary_part(acc, 0, start) <> call <> binary_part(acc, stop, byte_size(acc) - stop)
    end)
  end

  defp render_call(plan, occ) do
    attrs =
      plan.params
      |> Enum.zip(occ.call_args)
      |> Enum.map_join(" ", fn {param, expr} -> "#{param.name}={#{expr}}" end)

    case attrs do
      "" -> "<.#{plan.name} />"
      _ -> "<.#{plan.name} #{attrs} />"
    end
  end

  defp render_component_def(plan) do
    attrs = Enum.map_join(plan.params, "\n  ", fn p -> "attr :#{p.name}, :any" end)
    indented = indent(plan.body, "    ")

    """

      #{attrs}
      defp #{plan.name}(assigns) do
        ~H\"\"\"
    #{indented}
        \"\"\"
      end
    """
  end

  defp render_sigil(new_body, indent) do
    indented =
      new_body
      |> String.split("\n", trim: false)
      |> Enum.map_join("\n", fn
        "" -> ""
        line -> indent <> line
      end)

    "~H\"\"\"\n" <> indented <> indent <> "\"\"\""
  end

  # ---- source helpers ------------------------------------------------------

  defp collect_sigils(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> ast |> Macro.prewalker() |> Enum.flat_map(&sigil_or_empty/1)
      _ -> []
    end
  end

  defp sigil_or_empty({:sigil_H, _meta, [{:<<>>, body_meta, [body]}, _mods]} = node)
       when is_binary(body),
       do: [%{body: body, file_line: Keyword.get(body_meta, :line, 1), sigil_node: node}]

  defp sigil_or_empty(_), do: []

  defp component_present?(source, plan),
    do: String.contains?(source, "defp #{plan.name}(assigns)")

  defp core_components_module(opts) do
    opts
    |> Keyword.get(:project_config, %{})
    |> Map.get(:heex, %{})
    |> Map.get(:core_components_module)
  end

  defp core_components_source?(source, module),
    do: Regex.match?(~r/^defmodule\s+#{Regex.escape(module)}\b/m, source)

  defp resolve_target_file(source, opts, prepared) do
    case opts[:file] do
      file when is_binary(file) -> file
      _ -> prepared |> Map.get(:source_to_file, %{}) |> Map.get(source)
    end
  end

  defp module_end_line(source) do
    source
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.find_value(fn
      {"end", line} -> line
      _ -> nil
    end)
  end

  defp insert_before_line(source, line, text) do
    lines = String.split(source, "\n", trim: false)
    {head, tail} = Enum.split(lines, line - 1)
    (head ++ [text | tail]) |> Enum.join("\n")
  end

  defp indent(text, prefix) do
    text
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end

  defp assigns_in(code) when is_binary(code) do
    ~r/@([a-z_][a-zA-Z0-9_]*)/
    |> Regex.scan(code)
    |> Enum.map(fn [_, n] -> n end)
  end
end
