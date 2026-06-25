defmodule Number42.Refactors.Ex.MergeNearCloneComponents do
  @moduledoc """
  Merge two (or more) **sibling function components** that are *near*-clones into
  one parametrised component, and rewrite every call site to the survivor.

      def brand_item_assets_container(assigns) do
        ~H"<div class=\"py-3\"><h2>Dokumentationsbilder</h2>…</div>"
      end
      def brand_item_assets_container_2(assigns) do
        ~H"<section class=\"px-2 py-2\"><h2>Bilder</h2>…</section>"
      end
      ↓
      attr :label, :string, default: "Dokumentationsbilder"
      def brand_item_assets_container(assigns) do
        ~H"<div class=\"py-3\"><h2>{@label}</h2>…</div>"
      end
      # both call sites now call brand_item_assets_container, passing their label.

  Exact-hash clustering (`Heex.Clones`) cannot see these as one component — the
  root tag and a heading text differ, so they share no hash. `Heex.TreeDiff`
  measures the small structural distance and reports *which* nodes diverge; this
  refactor reconciles the handled divergence kinds into one parametrised `def`.

  ## What it merges

  Two or more `def name(assigns) do ~H\"\"\"…\"\"\" end` function components in the
  same module whose bodies are near-clones (`TreeDiff` similarity ≥ threshold)
  and whose only divergences are of the **handled kinds**:

    * **tag** — root/any element tag differs → normalise to the base tree's tag
      (the base is the LARGER tree; equal mass → the first by source order).
    * **class** — a `class` attr value differs → unify, the **longer** class set
      wins, but only when one set is a subset of the other (a safe superset).
    * **text** — a pure text node differs → lift to `attr :label` (the first
      occurrence's text becomes the default), each call site passes its own.

  ## Derive-or-decline (default-OFF)

  Opinionated and cross-file → default-OFF, opt-in per module:

      {Number42.Refactors.Ex.MergeNearCloneComponents, enabled: true}

  Declines (leaves the source untouched) when soundness can't be proven:

    * No near-clone twin (a lone component, or all defs structurally distinct).
    * A `:structural` divergence (an extra/missing child subtree, a differing
      `:if`/`:for`/eex header, a kind change, divergent child *markup* under a
      heading) — not mechanically parametrisable here.
    * More than one differing text node, or a differing attr other than `class`.
    * Two `class` sets not in a subset relation (each has a class the other
      lacks) — unifying would either drop styling or guess; decline instead.

  ## Idempotence

  A single already-parametrised component has no twin to merge → no-op. The
  cluster needs ≥ 2 occurrences.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Heex.{Normalizer, TreeDiff}

  @default_threshold 0.85
  @label_attr "label"

  @impl Number42.Refactors.Refactor
  def description,
    do: "Merge near-clone sibling function components into one parametrised component"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Two function components hand-written from the same template — one with a
    `<div>` root, one a `<section>`, a heading reworded, a class string drifted —
    are one component duplicated. Exact-hash clone detection misses them because
    the tag and a text node differ. Tree-edit-distance sees the small distance
    and reports the divergent nodes; where every divergence is a tag, a `class`
    value, or a pure text node, we collapse the duplicates into one parametrised
    `def` (text → `attr :label`, tag normalised to the larger tree's, classes
    unified as a checked superset) and rewrite each call site to the survivor.
    Default-OFF and conservative: any structural difference, a second differing
    text, a non-`class` attr, or non-subset classes declines the merge.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  # Corpus caller index: `%{component_name => MapSet of files}` over `<.name …>`
  # and `<Mod.name …>` tags, plus `source => file`, so a merge can rewrite every
  # call site of a dropped clone — not just the same-file ones.
  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    case Keyword.get(opts, :source_files) do
      files when is_list(files) and files != [] -> {:ok, build_caller_index(files)}
      _ -> :no_cache
    end
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      threshold = Keyword.get(opts, :threshold, @default_threshold)
      Sourceror.parse_string(source) |> merge_or_passthrough(source, threshold, opts[:prepared])
    else
      source
    end
  end

  defp merge_or_passthrough({:ok, ast}, source, threshold, prepared) do
    with {:ok, components} <- function_components(ast),
         {:ok, cluster} <- near_clone_cluster(components, threshold),
         {:ok, plan} <- build_merge_plan(cluster),
         :ok <- no_cross_file_callers?(plan, source, prepared) do
      apply_merge(plan, source)
    else
      _ -> source
    end
  end

  defp merge_or_passthrough({:error, _}, source, _threshold, _prepared), do: source

  # Decline when any dropped clone is called from a file other than this one.
  # The merge deletes that clone's `def`; a `<.dropped …>` in another file would
  # then fail to compile. Rewriting cross-file callers needs the engine to touch
  # other files — out of `transform/2`'s single-source contract — so it is a
  # follow-up. Without a corpus index (no `source_files`), only same-file callers
  # exist by construction, so the gate passes.
  defp no_cross_file_callers?(_plan, _source, nil), do: :ok

  defp no_cross_file_callers?(plan, source, %{callers: callers, source_to_file: s2f}) do
    own_file = Map.get(s2f, source)

    cross_file? =
      Enum.any?(plan.dropped, fn name ->
        caller_files = Map.get(callers, Atom.to_string(name), MapSet.new())
        not MapSet.subset?(caller_files, own_files(own_file))
      end)

    if cross_file?, do: :error, else: :ok
  end

  defp own_files(nil), do: MapSet.new()
  defp own_files(file), do: MapSet.new([file])

  # ---- detection: function components in the module ------------------------

  @type component :: %{
          name: atom(),
          arg: term(),
          body: String.t(),
          tree: [Number42.Refactors.Heex.Tree.node_t()],
          mass: pos_integer()
        }

  # Every `def name(assigns) do ~H\"\"\"…\"\"\" end` in the single module, parsed to
  # a HEEx tree. A def whose body is not a lone `~H` sigil is skipped (not a
  # function component we can merge).
  defp function_components(ast) do
    case single_module(ast) do
      {:ok, body} -> {:ok, body |> body_to_exprs() |> Enum.flat_map(&as_component/1)}
      :error -> :error
    end
  end

  defp single_module(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.filter(&match?({:defmodule, _, [_, [{_, _}]]}, &1))
    |> case do
      [{:defmodule, _, [_name, [{_do, body}]]}] -> {:ok, body}
      _ -> :error
    end
  end

  defp as_component({:def, _, [head, kw]}) do
    with {name, [arg]} <- def_name_and_args(head),
         {:ok, sigil_body} <- lone_sigil_body(do_value(kw)),
         {:ok, [_single] = tree} <- Number42.Refactors.Heex.Tree.parse_body(sigil_body) do
      # Only single-root bodies are merge candidates: a multi-root body (e.g. a
      # page emitting several components) has no single tag/class/text seam to
      # parametrise, and its mass is ambiguous to compare.
      [%{name: name, arg: arg, body: sigil_body, tree: tree, mass: tree_mass(tree)}]
    else
      _ -> []
    end
  end

  defp as_component(_), do: []

  defp def_name_and_args({:when, _, [head | _]}), do: def_name_and_args(head)
  defp def_name_and_args({name, _, args}) when is_atom(name) and is_list(args), do: {name, args}
  defp def_name_and_args(_), do: nil

  # The def body must be exactly one `~H` sigil; returns its raw body string.
  defp lone_sigil_body({:sigil_H, _meta, [{:<<>>, _, [body]}, _mods]}) when is_binary(body),
    do: {:ok, body}

  defp lone_sigil_body(_), do: :error

  defp do_value(kw) when is_list(kw) do
    Enum.find_value(kw, fn
      {{:__block__, _, [:do]}, v} -> v
      {:do, v} -> v
      _ -> nil
    end)
  end

  defp do_value(_), do: nil

  defp tree_mass(tree), do: tree |> Enum.map(&node_mass/1) |> Enum.sum()
  defp node_mass({:element, _, _, ch, _}), do: 1 + tree_mass(ch)
  defp node_mass({:eex_block, _, ch, _}), do: 1 + tree_mass(ch)
  defp node_mass({:eex_expr, _, _}), do: 1
  defp node_mass({:text, _, _}), do: 1

  # ---- detection: the near-clone cluster among the components --------------

  # Find the largest set of components that are pairwise near-clones of a common
  # base. Simplest sound form for sibling defs: pick the base (largest mass), and
  # gather every OTHER component whose body is similar enough to the base and
  # whose divergence vs the base is mechanically reconcilable. ≥ 2 → a cluster.
  defp near_clone_cluster(components, _threshold) when length(components) < 2, do: :error

  defp near_clone_cluster(components, threshold) do
    base = Enum.max_by(components, fn c -> {c.mass, -position(components, c)} end)
    base_norm = normalize_tree(base.tree)

    members =
      components
      |> Enum.reject(&(&1.name == base.name))
      |> Enum.filter(fn c ->
        TreeDiff.similarity(base_norm, normalize_tree(c.tree)) >= threshold
      end)

    case members do
      [] -> :error
      _ -> {:ok, %{base: base, base_norm: base_norm, members: members}}
    end
  end

  defp position(components, c), do: Enum.find_index(components, &(&1.name == c.name))

  # Candidate bodies are guaranteed single-root (see `as_component/1`), so the
  # comparison currency is the one normalized root node.
  defp normalize_tree([single]), do: Normalizer.normalize(single, :exact)

  # ---- merge plan: reconcile divergences or decline ------------------------

  @type merge_plan :: %{
          survivor: atom(),
          dropped: [atom()],
          arg: term(),
          merged_body: String.t(),
          label_default: String.t(),
          labels: %{atom() => String.t()}
        }

  defp build_merge_plan(%{base: base, base_norm: base_norm, members: members}) do
    [base_root] = base.tree

    with {:ok, per_member} <- reconcile_all(base_norm, members),
         {:ok, label_node_path} <- single_text_divergence(per_member) do
      assemble_plan(base, base_root, members, per_member, label_node_path)
    else
      _ -> :error
    end
  end

  # For every member, diff vs the base and require all divergences be handled
  # kinds (tag / class attr_value / text). Any :structural or non-class attr
  # divergence → decline. Returns `%{member_name => diffs}`.
  defp reconcile_all(base_norm, members) do
    results =
      Enum.map(members, fn m ->
        diffs = TreeDiff.diff(base_norm, normalize_tree(m.tree))
        {m.name, diffs, Enum.all?(diffs, &handled_kind?/1)}
      end)

    if Enum.all?(results, fn {_, _, ok?} -> ok? end) do
      {:ok, Map.new(results, fn {name, diffs, _} -> {name, diffs} end)}
    else
      :error
    end
  end

  defp handled_kind?({:tag, _path, _from, _to}), do: true
  defp handled_kind?({:text, _path, _from, _to}), do: true
  defp handled_kind?({:attr_value, _path, "class", from, to}), do: class_subset?(from, to)
  defp handled_kind?(_), do: false

  # "longer wins" is only safe when one class set is a subset of the other. Each
  # value is `{:string, "a b c"}`; split on whitespace and compare as sets. A
  # missing side (nil) is the empty set (subset of anything).
  defp class_subset?(from, to) do
    sa = class_set(from)
    sb = class_set(to)
    MapSet.subset?(sa, sb) or MapSet.subset?(sb, sa)
  end

  defp class_set(nil), do: MapSet.new()
  defp class_set({:string, s}), do: s |> String.split(~r/\s+/, trim: true) |> MapSet.new()
  defp class_set(_), do: MapSet.new()

  # Across all members there must be exactly ONE text-node path that ever
  # diverges — that is the node we parametrise as `@label`. Zero text
  # divergences means the components differ only in tag/class (no label needed,
  # but then they should have hashed equal under class_stripped — still mergeable
  # with no attr). More than one differing text path needs multiple attrs/slots
  # → decline (out of scope here).
  defp single_text_divergence(per_member) do
    paths =
      per_member
      |> Map.values()
      |> Enum.flat_map(fn diffs ->
        for {:text, path, _from, _to} <- diffs, do: path
      end)
      |> Enum.uniq()

    case paths do
      [] -> {:ok, :none}
      [path] -> {:ok, path}
      _ -> :error
    end
  end

  defp assemble_plan(base, base_root, members, per_member, label_path) do
    base_text = if label_path == :none, do: nil, else: text_at(base_root, label_path)

    merged_body =
      base.body
      |> maybe_parametrise_text(base, label_path)
      |> apply_class_unification(base, per_member, label_path)

    labels =
      Map.new(members, fn m ->
        {m.name, member_label(m, label_path) || base_text || ""}
      end)

    {:ok,
     %{
       survivor: base.name,
       dropped: Enum.map(members, & &1.name),
       arg: base.arg,
       merged_body: merged_body,
       label_default: base_text,
       labels: labels
     }}
  end

  # The text a given member carries at the label path (its own heading), used as
  # that call site's `label=` value.
  defp member_label(_member, :none), do: nil

  defp member_label(member, path) do
    case member.tree do
      [root] -> text_at(root, path)
      _ -> nil
    end
  end

  # Read the text content of the node at `path` (a pure text node).
  defp text_at(node, path), do: node_at(node, path) |> text_of()

  defp node_at(node, []), do: node

  defp node_at(node, [i | rest]) do
    case children_of(node) |> Enum.at(i) do
      nil -> nil
      child -> node_at(child, rest)
    end
  end

  defp children_of({:element, _, _, ch, _}), do: ch
  defp children_of({:eex_block, _, ch, _}), do: ch
  defp children_of(_), do: []

  defp text_of({:text, t, _}), do: t
  defp text_of(_), do: nil

  # ---- body rewriting (string-level on the sigil body) ---------------------

  # Replace the divergent text node's content with `{@label}` in the base body.
  defp maybe_parametrise_text(body, _base, :none), do: body

  defp maybe_parametrise_text(body, base, path) do
    [root] = base.tree

    case node_at(root, path) do
      {:text, text, _meta} -> replace_first_text(body, text, "{@#{@label_attr}}")
      _ -> body
    end
  end

  # Replace the FIRST literal occurrence of `text` (trimmed) in the body with the
  # replacement. The tree text is already trimmed, so locate the trimmed token.
  defp replace_first_text(body, text, replacement) do
    trimmed = String.trim(text)

    case :binary.match(body, trimmed) do
      {pos, len} ->
        binary_part(body, 0, pos) <>
          replacement <> binary_part(body, pos + len, byte_size(body) - pos - len)

      :nomatch ->
        body
    end
  end

  # Where a member's class set is a strict superset of the base's at some path,
  # the unified body should carry the longer set. We rewrite the base body's
  # class value at each such path to the longest class set seen across members.
  defp apply_class_unification(body, base, per_member, _label_path) do
    [root] = base.tree

    class_divergences(per_member)
    |> Enum.reduce(body, fn {path, _name}, acc ->
      case node_at(root, path) do
        {:element, _tag, attrs, _ch, _} ->
          base_class = class_value(attrs)
          longest = longest_class_at(path, base, per_member)

          if longest && longest != base_class,
            do: replace_first_class(acc, base_class, longest),
            else: acc

        _ ->
          acc
      end
    end)
  end

  defp class_divergences(per_member) do
    per_member
    |> Enum.flat_map(fn {name, diffs} ->
      for {:attr_value, path, "class", _from, _to} <- diffs, do: {path, name}
    end)
    |> Enum.uniq()
  end

  # The longest class string seen at `path` across the base and every member.
  defp longest_class_at(path, base, per_member) do
    [base_root] = base.tree
    base_class = base_root |> node_at(path) |> element_class()

    member_classes =
      per_member
      |> Enum.flat_map(fn {_name, diffs} ->
        for {:attr_value, ^path, "class", _from, {:string, v}} <- diffs, do: v
      end)

    [base_class | member_classes]
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  defp element_class({:element, _tag, attrs, _ch, _}), do: class_value(attrs)
  defp element_class(_), do: nil

  defp class_value(attrs) do
    Enum.find_value(attrs, fn
      {"class", {:string, v}} -> v
      _ -> nil
    end)
  end

  defp replace_first_class(body, nil, _new), do: body

  defp replace_first_class(body, old, new) do
    case :binary.match(body, "\"#{old}\"") do
      {pos, len} ->
        binary_part(body, 0, pos) <>
          "\"#{new}\"" <> binary_part(body, pos + len, byte_size(body) - pos - len)

      :nomatch ->
        body
    end
  end

  # ---- apply: rewrite the module + call sites ------------------------------

  defp apply_merge(plan, source) do
    source
    |> rewrite_survivor_def(plan)
    |> drop_dropped_defs(plan)
    |> ensure_label_attr(plan)
    |> rewrite_call_sites(plan)
  end

  # Replace the survivor def's sigil body with the merged (parametrised) body.
  defp rewrite_survivor_def(source, plan) do
    replace_def_body(source, plan.survivor, plan.merged_body)
  end

  # Rewrite the named def's `~H\"\"\"…\"\"\"` body in place via a Sourceror map-patch.
  defp replace_def_body(source, name, new_body) do
    case sigil_range_of_def(source, name) do
      nil ->
        source

      range ->
        Sourceror.patch_string(source, [%{range: range, change: render_sigil(new_body)}])
    end
  end

  # The Sourceror range of the `~H` sigil inside `def name(...)`.
  defp sigil_range_of_def(source, name) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.find_value(fn
          {:def, _, [head, kw]} ->
            with {^name, _args} <- def_name_and_args(head),
                 {:sigil_H, _, _} = sigil <- do_value(kw) do
              Sourceror.get_range(sigil)
            else
              _ -> nil
            end

          _ ->
            nil
        end)

      _ ->
        nil
    end
  end

  # The merged body keeps the base sigil's original indentation verbatim (only
  # tag/class/text tokens were substituted in place). Re-emit it unchanged
  # between the delimiters, the closing `\"\"\"` aligned to the body's own
  # content indent (HEEx convention), which the sigil opened at.
  defp render_sigil(body) do
    indent = String.duplicate(" ", body_content_indent(body))
    "~H\"\"\"\n" <> String.trim_trailing(body, "\n") <> "\n" <> indent <> "\"\"\""
  end

  # Leading-space count of the first non-blank body line.
  defp body_content_indent(body) do
    body
    |> String.split("\n", trim: false)
    |> Enum.find(fn line -> String.trim(line) != "" end)
    |> case do
      nil -> 0
      line -> byte_size(line) - byte_size(String.trim_leading(line))
    end
  end

  # Remove each dropped def (the whole `def …(assigns) do … end` block) from the
  # source via line removal between the def's start and end lines.
  defp drop_dropped_defs(source, plan) do
    Enum.reduce(plan.dropped, source, fn name, acc -> drop_def(acc, name) end)
  end

  defp drop_def(source, name) do
    case def_line_range(source, name) do
      {start_line, end_line} -> drop_lines(source, start_line..end_line)
      nil -> source
    end
  end

  defp def_line_range(source, name) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.find_value(fn
          {:def, _, [head, _]} = node ->
            case def_name_and_args(head) do
              {^name, _} ->
                range = Sourceror.get_range(node)
                {range.start[:line], range.end[:line]}

              _ ->
                nil
            end

          _ ->
            nil
        end)

      _ ->
        nil
    end
  end

  defp drop_lines(source, line_range) do
    drop = MapSet.new(line_range)

    source
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.reject(fn {_line, idx} -> MapSet.member?(drop, idx) end)
    |> Enum.map_join("\n", fn {line, _idx} -> line end)
    |> collapse_blank_runs()
  end

  # Removing a def can leave a double blank line where it sat; collapse runs of
  # 3+ newlines to 2 so the module stays tidy.
  defp collapse_blank_runs(source), do: String.replace(source, ~r/\n{3,}/, "\n\n")

  # Add `attr :label, :string, default: "…"` just before the survivor def, unless
  # one is already present. Skipped when no text was parametrised.
  defp ensure_label_attr(source, %{label_default: nil}), do: source

  defp ensure_label_attr(source, plan) do
    if source =~ ~r/attr\s+:#{@label_attr}\b/ do
      source
    else
      insert_attr_before_def(source, plan.survivor, attr_line(plan.label_default))
    end
  end

  defp attr_line(default) do
    "  attr :#{@label_attr}, :string, default: #{inspect(default)}"
  end

  # Insert the `attr` line directly above its `def` (idiomatic pairing), with a
  # blank line above the attr so it doesn't glue to the preceding `use`/`def`.
  defp insert_attr_before_def(source, name, attr) do
    lines = String.split(source, "\n", trim: false)

    case Enum.find_index(lines, &def_header_line?(&1, name)) do
      nil ->
        source

      i ->
        insert =
          if i > 0 and String.trim(Enum.at(lines, i - 1)) == "", do: [attr], else: ["", attr]

        lines |> List.insert_at(i, Enum.join(insert, "\n")) |> Enum.join("\n")
    end
  end

  defp def_header_line?(line, name) do
    Regex.match?(~r/^\s*def\s+#{name}\s*\(/, line)
  end

  # Rewrite every `<.dropped …>` (and `<Mod.dropped …>`) call site to the
  # survivor, injecting `label="<that clone's text>"` so it renders the same
  # heading it did before. Same-file only in this pass — cross-file callers are
  # handled when the corpus index is present (prepare/source_files).
  defp rewrite_call_sites(source, plan) do
    Enum.reduce(plan.dropped, source, fn dropped, acc ->
      label = Map.get(plan.labels, dropped, "")
      survivor = plan.survivor
      rewrite_one_call_site(acc, dropped, survivor, label, plan.label_default)
    end)
  end

  # `<.dropped attrs />` → `<.survivor attrs label="…" />`. Both self-closing and
  # open/close forms; local `.name` and qualified `Mod.name`. The label is added
  # only when the clone's own heading differs from the survivor's default; the
  # attrs and closer keep one separating space so the tag stays well-formed.
  defp rewrite_one_call_site(source, dropped, survivor, label, label_default) do
    inject = label && label != label_default && label != ""

    re =
      ~r/<(?<prefix>\.|[A-Z][\w.]*\.)#{dropped}(?<attrs>(?:\{[^}]*\}|"[^"]*"|[^>])*?)\s*(?<close>\/?>)/

    Regex.replace(re, source, fn _full, prefix, attrs, close ->
      attrs = String.trim_trailing(attrs)
      label_attr = if inject, do: ~s( #{@label_attr}="#{label}"), else: ""
      closer = if close == "/>", do: " />", else: ">"
      "<#{prefix}#{survivor}#{attrs}#{label_attr}#{closer}"
    end)
  end

  # ---- corpus caller index (cross-file rewrite) ----------------------------

  defp build_caller_index(files) do
    files
    |> Enum.reduce(%{callers: %{}, source_to_file: %{}}, fn file, acc ->
      case File.read(file) do
        {:ok, content} ->
          acc
          |> put_in([:source_to_file, content], file)
          |> Map.update!(:callers, &index_callers(&1, content, file))

        _ ->
          acc
      end
    end)
  end

  defp index_callers(callers, content, file) do
    ~r/<\.?[A-Za-z0-9_.]*\.?([a-z_][a-z0-9_]*)\s/
    |> Regex.scan(content)
    |> Enum.reduce(callers, fn [_, name], acc ->
      Map.update(acc, name, MapSet.new([file]), &MapSet.put(&1, file))
    end)
  end
end
