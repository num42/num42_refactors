defmodule Number42.Refactors.Ex.MergeNearCloneComponents do
  @moduledoc """
  Merge two (or more) function components that are *near*-clones into one
  parametrised component, and rewrite every call site to the survivor.

      # BrandItemAssetsImages          # BrandItemAssetsImages2
      def brand_item_assets_images(…)   def brand_item_assets_images_2(…)
        ~H"<div class=\"py-3\">           ~H"<section class=\"px-2 py-2\">
             <h2>Dokumentationsbilder>        <h2>Bilder>…</section>"
             …</div>"
      ↓ (the two collapse into the survivor)
      attr :label, :string, default: "Dokumentationsbilder"
      def brand_item_assets_images(assigns) do
        ~H"<div class=\"py-3 px-2 py-2\"><h2>{@label}</h2>…</div>"
      end
      # the Images2 file is deleted; its caller now calls
      # `<BrandItemAssetsImages.brand_item_assets_images … label=\"Bilder\" />`.

  Exact-hash clustering (`Heex.Clones`) cannot see these as one component — the
  root tag and a heading text differ, so they share no hash. `Heex.TreeDiff`
  measures the small structural distance and reports *which* nodes diverge; this
  refactor reconciles the handled divergence kinds into one parametrised `def`.

  ## Two modes

    * **sibling defs** — two or more `def name(assigns) do ~H… end` in the *same*
      module. The dropped clones' defs are removed in place and same-file call
      sites rewritten.
    * **cross-file component modules** — single-`def` component modules in their
      *own* files (what `ExtractToPublicComponent` emits). The survivor's file is
      rewritten, each clone's file is **deleted**, and the clones' call sites —
      `alias` + `<Mod.fn …>` tag — are rewritten across the corpus (resolved via
      `prepare/source_files`). This is the #380 target shape.

  ## What it merges (handled divergence kinds)

    * **tag** — an element tag differs → normalise to the base tree's tag (base =
      the LARGER tree; mass tie → the canonical name, the `foo` of a `foo`/`foo_2`
      pair).
    * **class** — a `class` attr value differs → the **survivor keeps its own
      class verbatim**; the clone's differing classes are dropped with the clone.
      No union, no guessing — one component's styling wins.
    * **text** — a pure text node differs → lift to `attr :label` (the base's text
      is the default); each call site passes its own via `label="…"`.

  ## Derive-or-decline (default-OFF)

  Opinionated and cross-file → default-OFF, opt-in:

      {MergeNearCloneComponents, enabled: true, threshold: 0.85, min_mass: 12}

  Declines (leaves everything untouched) when soundness can't be proven:

    * No near-clone twin (a lone component, or all components structurally distinct).
    * A `:structural` divergence (an extra/missing child subtree, a differing
      `:if`/`:for`/eex header, a kind change, divergent child *markup* under a
      heading) — not mechanically parametrisable here.
    * More than one differing text node, or a differing attr other than `class`.
    * A dropped clone with a caller *outside* the readable corpus — it could not
      be rewritten, so deleting the clone would break it.

  `:threshold` (default 0.85) and `:min_mass` (default 12) tune the candidate
  set; the divergence-kind gate above — not the threshold — is the soundness
  boundary, so a lower threshold only widens candidates, never licences an
  unsafe merge.

  ## Idempotence

  After a merge the survivor has no twin (and a dropped clone's file is gone), so
  a second run is a no-op. A single already-parametrised component never merges.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Heex.{Normalizer, TreeDiff}

  @default_threshold 0.85
  @default_min_mass 12
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
    `def` (text → `attr :label`, tag normalised to the larger tree's, the
    survivor's own classes kept and the clone's dropped) and rewrite each call
    site to the survivor. Default-OFF and conservative: any structural
    difference, a second differing text, or a non-`class` attr declines the merge.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  # Corpus merge plan: scan every source for single-`def` function-component
  # modules, cluster near-clones across files, and resolve each dropped clone's
  # call sites. Keyed by survivor file path so the per-file `transform/2` knows
  # its role (survivor / dropped clone / caller) in O(1). See `build_corpus_plan/3`.
  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    case Keyword.get(opts, :source_files) do
      files when is_list(files) and files != [] ->
        threshold = Keyword.get(opts, :threshold, @default_threshold)
        min_mass = Keyword.get(opts, :min_mass, @default_min_mass)
        {:ok, build_corpus_plan(files, threshold, min_mass)}

      _ ->
        :no_cache
    end
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      dispatch(source, opts)
    else
      source
    end
  end

  # With a corpus plan, dispatch on this file's role (survivor / dropped clone /
  # caller). Without one (no `source_files`, or a one-off `mix refactor foo.ex`),
  # fall back to the same-module sibling-def merge.
  defp dispatch(source, opts) do
    with %{} = prepared <- opts[:prepared],
         file when is_binary(file) <- Map.get(prepared.source_to_file, source) do
      role_dispatch(file, source, prepared, opts)
    else
      _ -> fallback_same_module(source, opts)
    end
  end

  defp role_dispatch(file, source, prepared, opts) do
    merges = Map.get(prepared, :merges, %{})

    case Map.get(merges, file) do
      %{} = merge -> apply_survivor(source, merge, opts)
      _ -> source
    end
  end

  defp fallback_same_module(source, opts) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    Sourceror.parse_string(source) |> merge_or_passthrough(source, threshold)
  end

  defp merge_or_passthrough({:ok, ast}, source, threshold) do
    with {:ok, components} <- function_components(ast),
         {:ok, cluster} <- near_clone_cluster(components, threshold),
         {:ok, plan} <- build_merge_plan(cluster) do
      apply_merge(plan, source)
    else
      _ -> source
    end
  end

  defp merge_or_passthrough({:error, _}, source, _threshold), do: source

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
      assemble_plan(base, base_root, members, label_node_path)
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
  # A `class` divergence is always reconcilable by keeping the survivor's class
  # verbatim and dropping the clone's (the clone's def/file is removed anyway).
  # No union, no guessing — one component's styling wins.
  defp handled_kind?({:attr_value, _path, "class", _from, _to}), do: true
  defp handled_kind?(_), do: false

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

  defp assemble_plan(base, base_root, members, label_path) do
    base_text = if label_path == :none, do: nil, else: text_at(base_root, label_path)

    # The survivor keeps its own classes verbatim; a clone's divergent classes
    # are dropped with the clone. Only the text node is parametrised.
    merged_body = maybe_parametrise_text(base.body, base, label_path)

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

  # Insert the `attr :label` line into the survivor's attr block. If the def is
  # already preceded by one or more `attr` lines, append directly after the last
  # of them (attrs stay grouped, no blank between them). Otherwise place it just
  # above the `def`, with a blank above so it doesn't glue to a preceding `use`.
  defp insert_attr_before_def(source, name, attr) do
    lines = String.split(source, "\n", trim: false)

    case Enum.find_index(lines, &def_header_line?(&1, name)) do
      nil ->
        source

      def_i ->
        case last_attr_before(lines, def_i) do
          nil ->
            insert = if blank_above?(lines, def_i), do: [attr], else: ["", attr]
            lines |> List.insert_at(def_i, Enum.join(insert, "\n")) |> Enum.join("\n")

          attr_i ->
            lines |> List.insert_at(attr_i + 1, attr) |> Enum.join("\n")
        end
    end
  end

  # The index of the last `attr …` line in the contiguous run directly above the
  # def (skipping blank lines), or nil if there is none.
  defp last_attr_before(lines, def_i) do
    def_i
    |> Kernel.-(1)
    |> Stream.iterate(&(&1 - 1))
    |> Stream.take_while(&(&1 >= 0))
    |> Enum.reduce_while(nil, fn i, _acc ->
      line = Enum.at(lines, i)

      cond do
        String.trim(line) == "" -> {:cont, nil}
        Regex.match?(~r/^\s*attr\s+/, line) -> {:halt, i}
        true -> {:halt, nil}
      end
    end)
  end

  defp blank_above?(lines, i), do: i > 0 and String.trim(Enum.at(lines, i - 1)) == ""

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

  # ---- corpus plan (cross-file detection) ----------------------------------

  # Read every corpus file, find single-`def` function-component modules, cluster
  # near-clones across files, and produce a plan keyed by survivor file path.
  defp build_corpus_plan(files, threshold, min_mass) do
    contents =
      files
      |> Enum.flat_map(fn f ->
        case File.read(f) do
          {:ok, src} -> [{f, src}]
          _ -> []
        end
      end)

    source_to_file = Map.new(contents, fn {f, src} -> {src, f} end)
    components = Enum.flat_map(contents, fn {f, src} -> corpus_components(f, src) end)
    caller_index = build_caller_index(contents)

    merges =
      components
      |> cross_file_clusters(threshold, min_mass)
      |> Enum.flat_map(&cluster_to_merge(&1, caller_index, source_to_file))
      |> Map.new(fn merge -> {merge.survivor_file, merge} end)

    drop_files =
      merges
      |> Map.values()
      |> Enum.flat_map(fn m -> Enum.map(m.drops, & &1.file) end)
      |> MapSet.new()

    %{source_to_file: source_to_file, merges: merges, drop_files: drop_files}
  end

  # Single-`def` function-component modules in one file: a `defmodule` whose body
  # has exactly one `def name(assigns) do ~H… end`. Multi-def modules are left to
  # the same-module fallback path.
  defp corpus_components(file, source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.flat_map(&module_component(&1, file))

      _ ->
        []
    end
  end

  defp module_component({:defmodule, _, [name, [{_do, body}]]}, file) do
    module = module_string(name)

    case body |> body_to_exprs() |> Enum.flat_map(&as_component/1) do
      [c] -> [Map.merge(c, %{file: file, module: module})]
      _ -> []
    end
  end

  defp module_component(_, _file), do: []

  defp module_string({:__aliases__, _, parts}), do: Enum.map_join(parts, ".", &Atom.to_string/1)
  defp module_string(other), do: Macro.to_string(other)

  # Group corpus components into near-clone clusters: base = the larger tree;
  # on a mass tie prefer the *canonical* name — one without a trailing `_<n>`
  # suffix (the `foo` of a `foo` / `foo_2` pair), then lexicographic name, then
  # file for full determinism. Members clear the threshold and the mass band.
  # Each component lands in at most one cluster (greedy, base-anchored).
  defp cross_file_clusters(components, threshold, min_mass) do
    components
    |> Enum.filter(&(&1.mass >= min_mass))
    |> Enum.sort_by(fn c -> {-c.mass, suffix_rank(c.name), Atom.to_string(c.name), c.file} end)
    |> form_clusters(threshold, [])
  end

  # 0 for a plain name, 1 for a `_<digit>`-suffixed one — so `foo` outranks
  # `foo_2` as the survivor on a mass tie.
  defp suffix_rank(name) do
    if Atom.to_string(name) =~ ~r/_\d+$/, do: 1, else: 0
  end

  defp form_clusters([], _threshold, acc), do: Enum.reverse(acc)

  defp form_clusters([base | rest], threshold, acc) do
    base_norm = normalize_tree(base.tree)

    {members, leftover} =
      Enum.split_with(rest, fn c ->
        TreeDiff.similarity(base_norm, normalize_tree(c.tree)) >= threshold
      end)

    case members do
      [] -> form_clusters(rest, threshold, acc)
      _ -> form_clusters(leftover, threshold, [%{base: base, members: members} | acc])
    end
  end

  # Turn a cross-file cluster into a merge, or skip it ([]). Reconcile every
  # member against the base (handled kinds only); decline the whole cluster on
  # any structural / multi-text divergence. Each member becomes a drop with its
  # own callers and label.
  defp cluster_to_merge(%{base: base, members: members}, caller_index, source_to_file) do
    base_norm = normalize_tree(base.tree)

    with {:ok, per_member} <- reconcile_all(base_norm, members),
         {:ok, label_path} <- single_text_divergence(per_member),
         {:ok, drops} <-
           resolve_drops(members, per_member, label_path, caller_index, source_to_file) do
      [build_cross_file_merge(base, members, per_member, label_path, drops)]
    else
      _ -> []
    end
  end

  # Each member → a drop with its caller sites. Decline (→ :error) when a member
  # is called from a file NOT in the readable corpus: we could not rewrite that
  # caller, so deleting the clone would break it.
  defp resolve_drops(members, _per_member, label_path, caller_index, source_to_file) do
    corpus_files = source_to_file |> Map.values() |> MapSet.new()

    drops =
      Enum.map(members, fn m ->
        caller_files = Map.get(caller_index, m.name, MapSet.new())

        %{
          file: m.file,
          module: m.module,
          fn_name: m.name,
          label: member_label(m, label_path),
          callers: caller_sites(caller_files, m)
        }
      end)

    if Enum.all?(drops, &drop_callers_all_readable?(&1, caller_index, corpus_files)),
      do: {:ok, drops},
      else: :error
  end

  # Every file that calls the dropped clone must be in the readable corpus — else
  # we cannot rewrite it and deleting the clone would break it.
  defp drop_callers_all_readable?(drop, caller_index, corpus_files) do
    caller_index
    |> Map.get(drop.fn_name, MapSet.new())
    |> Enum.all?(&MapSet.member?(corpus_files, &1))
  end

  # The caller files of a dropped clone, excluding the clone's own file (the
  # def-site, not a call site).
  defp caller_sites(caller_files, member) do
    caller_files
    |> Enum.reject(&(&1 == member.file))
    |> Enum.map(fn f -> %{file: f, tag_fn: member.name, dropped_module: member.module} end)
  end

  defp build_cross_file_merge(base, _members, _per_member, label_path, drops) do
    [base_root] = base.tree

    # Survivor keeps its own classes verbatim; only the divergent text node is
    # lifted to `@label`.
    merged_body = maybe_parametrise_text(base.body, base, label_path)

    %{
      survivor_file: base.file,
      survivor_module: base.module,
      survivor_fn: base.name,
      arg: base.arg,
      merged_body: merged_body,
      label_default: if(label_path == :none, do: nil, else: text_at(base_root, label_path)),
      drops: drops
    }
  end

  # ---- corpus plan (cross-file apply, survivor-owned side-effects) ----------

  # The survivor's pass owns ALL cross-file effects: delete each clone file,
  # rewrite each clone's callers. Then return its own rewritten source. Gated on
  # `dry_run` (the engine never writes/deletes other files for us).
  defp apply_survivor(source, merge, opts) do
    unless Keyword.get(opts, :dry_run, false) do
      drop_clone_files(merge)
      rewrite_caller_files(merge)
    end

    source
    |> replace_def_body(merge.survivor_fn, merge.merged_body)
    |> ensure_label_attr(%{survivor: merge.survivor_fn, label_default: merge.label_default})
  end

  defp drop_clone_files(merge) do
    Enum.each(merge.drops, fn %{file: f} -> File.exists?(f) && File.rm(f) end)
  end

  # For each caller file of a dropped clone, swap the alias to the survivor and
  # rewrite the `<DroppedMod.fn …>` tag to `<SurvivorMod.fn … label="…">`. Only
  # written when the dropped tag is still present (idempotent re-run guard).
  defp rewrite_caller_files(merge) do
    survivor_alias = merge.survivor_module |> String.split(".") |> List.last()

    merge.drops
    |> Enum.flat_map(fn d -> Enum.map(d.callers, &Map.put(&1, :label, d.label)) end)
    |> Enum.group_by(& &1.file)
    |> Enum.each(fn {caller_file, hits} ->
      rewrite_caller_file(caller_file, hits, merge, survivor_alias)
    end)
  end

  defp rewrite_caller_file(caller_file, hits, merge, survivor_alias) do
    case File.read(caller_file) do
      {:ok, content} ->
        new =
          Enum.reduce(hits, content, fn hit, acc ->
            if String.contains?(acc, Atom.to_string(hit.tag_fn)) do
              acc
              |> rewrite_qualified_call(hit, merge, survivor_alias)
              |> swap_alias(hit.dropped_module, merge.survivor_module)
            else
              acc
            end
          end)

        if new != content, do: File.write!(caller_file, new)

      _ ->
        :ok
    end
  end

  # `<DroppedAlias.dropped_fn …>` → `<SurvivorAlias.survivor_fn … label="…">`.
  defp rewrite_qualified_call(content, hit, merge, survivor_alias) do
    dropped_alias = hit.dropped_module |> String.split(".") |> List.last()
    label = hit.label

    re =
      ~r/<#{dropped_alias}\.#{hit.tag_fn}(?<attrs>(?:\{[^}]*\}|"[^"]*"|[^>])*?)\s*(?<close>\/?>)/

    Regex.replace(re, content, fn _full, attrs, close ->
      attrs = String.trim_trailing(attrs)
      label_attr = label_attr_for(label, merge.label_default)
      closer = if close == "/>", do: " />", else: ">"
      "<#{survivor_alias}.#{merge.survivor_fn}#{attrs}#{label_attr}#{closer}"
    end)
  end

  defp label_attr_for(label, label_default) do
    if label && label != label_default && label != "",
      do: ~s( #{@label_attr}="#{label}"),
      else: ""
  end

  # Replace the dropped module's `alias` line with the survivor's (or drop it if
  # the survivor is already aliased in this file).
  defp swap_alias(content, dropped_module, survivor_module) do
    dropped_alias = dropped_module |> String.split(".") |> List.last()

    cond do
      String.contains?(content, "alias #{survivor_module}\n") ->
        # survivor already aliased → drop the dropped alias line
        String.replace(content, ~r/^\s*alias\s+\S*#{dropped_alias}\b.*\n/m, "")

      true ->
        String.replace(
          content,
          ~r/alias\s+\S*#{dropped_alias}\b[^\n]*/,
          "alias #{survivor_module}"
        )
    end
  end

  # Caller index over the corpus: `%{fn_name (atom) => MapSet of files}` for every
  # `<Mod.fn …>` / `<.fn …>` component tag. Used to find a dropped clone's callers.
  defp build_caller_index(contents) do
    Enum.reduce(contents, %{}, fn {file, content}, acc ->
      index_callers(acc, content, file)
    end)
  end

  # Match a component tag in either form and capture the FULL function name:
  #   `<.fn …>`        — local component (leading dot, no module)
  #   `<Mod.Sub.fn …>` — qualified (capital-led dotted module, then `.fn`)
  # A single greedy `[\w.]*` before the capture would swallow the function name
  # into the module segment (capturing only a trailing `_2`), so the two forms
  # are matched as explicit alternatives.
  @caller_tag ~r/<(?:\.|[A-Z][\w.]*\.)([a-z_][a-z0-9_]*)[\s\/>]/

  defp index_callers(callers, content, file) do
    @caller_tag
    |> Regex.scan(content)
    |> Enum.reduce(callers, fn [_, name], acc ->
      key = String.to_atom(name)
      Map.update(acc, key, MapSet.new([file]), &MapSet.put(&1, file))
    end)
  end
end
