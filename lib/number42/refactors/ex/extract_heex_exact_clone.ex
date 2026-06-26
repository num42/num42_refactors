defmodule Number42.Refactors.Ex.ExtractHeexExactClone do
  @moduledoc """
  Cross-file refactor: every `:exact` HEEx clone with ≥2 occurrences
  is lifted into a generated function-component in the user's
  CoreComponents module, and each occurrence is replaced with a call
  to that component. Free `@assigns` and outer loop bindings
  referenced inside the clone are forwarded 1:1 as attrs.

  ## Configuration

  The target CoreComponents module name is read from `.refactor.exs`
  in the project root:

      %{heex: %{core_components_module: "MyAppWeb.CoreComponents"}}

  Without that key the refactor is a no-op.
  """
  use Number42.Refactors.Refactor

  alias Number42.Refactors.Heex.Clones
  alias Number42.Refactors.Heex.Tree

  @default_min_mass 8

  @doc """
  Walk every source in `sources` (`%{path => source}`), cluster
  `:exact` HEEx clones, and return one plan entry per cluster.

  Plan entry shape:

      %{
        name: :shared_a_article_abcdef12,
        assigns: [:body, :title],     # assigns the lifted component takes
        locals: [],                   # loop-bindings the lifted component takes
        root_tag: "article",
        body: "<article …>…</article>",  # rendered HEEx for the component
        hash: <<…>>,
        mass: 7,
        occurrences: [
          %{file: "lib/a.ex", line: 4, node: tree_node, mass: 7},
          %{file: "lib/b.ex", line: 4, node: tree_node, mass: 7}
        ]
      }
  """
  @spec build_plan(%{String.t() => String.t()}, keyword()) :: [map()]
  def build_plan(sources, opts \\ []) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)
    pairs = sources |> Enum.map(fn {path, source} -> {path, source} end)

    %{exact: clusters} =
      Clones.from_sources(pairs, modes: [:exact], min_mass: min_mass)

    clusters |> Enum.map(&cluster_to_plan/1)
  end

  @doc """
  Generate a deterministic Phoenix-component name for a clone:
  `:"shared_<file_stem>_<root_tag>_<hash8>"`. The file stem comes
  from the alphabetically-first occurrence's path so the same
  cluster always picks the same name across runs.
  """
  @spec component_name(String.t(), String.t(), binary()) :: atom()
  def component_name(rep_file, root_tag, <<hash::binary-size(4), _::binary>>) do
    stem =
      rep_file
      |> Path.basename(".ex")
      |> Path.basename(".exs")

    tag = root_tag |> String.trim_leading(".") |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    hex = Base.encode16(hash, case: :lower)

    :"shared_#{stem}_#{tag}_#{hex}"
  end

  @impl Number42.Refactors.Refactor
  def description,
    do: "Extract `:exact` HEEx clones into the configured CoreComponents module"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Duplicated HEEx markup is one of the most expensive forms of clone:
    every copy has to be kept visually identical by humans, and any drift
    silently becomes a UX inconsistency. We detect byte-for-byte identical
    HEEx subtrees that appear in two or more templates, lift them into a
    single function component in the configured CoreComponents module, and
    replace every occurrence with a call to that component. Free `@assigns`
    and outer `for`-loop bindings referenced inside the clone are forwarded
    as attrs, so the lifted component is self-contained. The result is
    fewer lines of HEEx, one source of truth per shared markup block, and
    a real component boundary where there used to be only copy/paste.
    """
  end

  @doc """
  Walk a HEEx subtree and return `%{assigns: [atom], locals: [atom]}`:
  the names referenced inside the tree that the **caller** must pass
  in. Loop bindings introduced *within* the subtree are stripped
  from the assigns set and surfaced under `locals`.
  """
  @spec find_free_vars([Tree.node_t()] | Tree.node_t()) ::
          %{assigns: [atom()], locals: [atom()]}
  def find_free_vars(nodes) do
    {assigns, locals} = scan(List.wrap(nodes), MapSet.new(), MapSet.new(), MapSet.new())

    %{
      assigns: assigns |> MapSet.difference(locals) |> MapSet.to_list() |> Enum.sort(),
      locals: locals |> MapSet.to_list() |> Enum.sort()
    }
  end

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    paths = Keyword.get(opts, :paths, [])

    if paths == [] do
      :no_cache
    else
      prepare_from_paths(paths, opts)
    end
  end

  defp prepare_from_paths(paths, opts) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)

    sources =
      paths
      |> Enum.flat_map(fn p ->
        case File.read(p) do
          {:ok, src} -> [{p, src}]
          _ -> []
        end
      end)
      |> Map.new()

    plans = build_plan(sources, min_mass: min_mass)

    source_to_file =
      for {path, src} <- sources do
        {src, path}
      end
      |> Map.new()

    {:ok, %{plans: plans, source_to_file: source_to_file}}
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @doc """
  Render a parsed HEEx subtree back into source. `locals` is the list
  of loop-binding names; references to those names inside `{...}`
  expressions are rewritten to `@<name>` so the lifted component can
  receive them as attrs.
  """
  @spec render_subtree(Tree.node_t() | [Tree.node_t()], [atom()]) :: String.t()
  def render_subtree(nodes, locals) when is_list(nodes),
    do: nodes |> Enum.map_join(&render_subtree(&1, locals))

  def render_subtree({:element, tag, attrs, children, _meta}, locals) do
    rendered_attrs = attrs |> Enum.map_join("", &render_attr(&1, locals))

    case children do
      [] ->
        "<#{tag}#{rendered_attrs} />"

      _ ->
        body = children |> Enum.map_join(&render_subtree(&1, locals))
        "<#{tag}#{rendered_attrs}>#{body}</#{tag}>"
    end
  end

  def render_subtree({:eex_block, header, children, _meta}, locals) do
    body = children |> Enum.map_join(&render_subtree(&1, locals))
    "<%= #{rewrite_locals(header, locals)} %>#{body}<% end %>"
  end

  def render_subtree({:eex_expr, code, _meta}, locals), do: "{#{rewrite_locals(code, locals)}}"
  def render_subtree({:text, text, _meta}, _locals), do: text
  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    with module when is_binary(module) <- core_components_module(opts),
         %{plans: plan} = prepared <- opts[:prepared] do
      cond do
        # CoreComponents file: append generated `defp` components.
        # Detected via `defmodule <configured module>` anchor — keeps
        # the refactor independent of the engine's per-file path
        # plumbing.
        plan != [] and core_components_source?(source, module) ->
          append_components(source, plan)

        target_file = resolve_target_file(source, opts, prepared) ->
          apply_plans_to_file(source, plan, target_file)

        true ->
          source
      end
    else
      _ -> source
    end
  end

  defp append_components(source, plans) do
    # Idempotence: append only the components that aren't already
    # present in the file. If a plan's `defp <name>(assigns)` is
    # already there, the engine's fixpoint loop has already run us.
    new_plans = plans |> Enum.reject(&component_present?(source, &1))

    case {new_plans, find_module_end_line(source)} do
      {[], _} ->
        source

      {_, nil} ->
        source

      {_, end_line} ->
        components = new_plans |> Enum.map_join("\n", &render_component_def/1)
        insert_before_line(source, end_line, components)
    end
  end

  defp apply_plans_to_file(source, plans, file) do
    occs_in_file =
      plans
      |> Enum.flat_map(fn plan ->
        plan.occurrences
        |> Enum.filter(&(&1.file == file))
        |> Enum.map(&{plan, &1})
      end)

    case occs_in_file do
      [] -> source
      _ -> rewrite_sigils(source, occs_in_file)
    end
  end

  # Re-emit whole `~H` sigils via `Sourceror.patch_string` instead of
  # splicing the source directly. The clone tree's byte ranges live in
  # the *dedented* sigil body (Sourceror strips the heredoc indentation),
  # so we splice the component call into that dedented body and let
  # `reformat_after?: true` restore the indentation. Mixing the two
  # offset spaces — source bytes vs. dedented-body bytes — would
  # misalign the splice for any indented multi-line clone.
  defp rewrite_sigils(source, occs_in_file) do
    sigils = collect_sigils_with_nodes(source)

    occs_in_file
    |> Enum.flat_map(&match_occurrence_to_sigil(&1, sigils))
    |> Enum.group_by(fn {sigil, _occ, _plan} -> sigil end, fn {_sigil, occ, plan} ->
      {occ, plan}
    end)
    |> Enum.map(fn {sigil, occ_plans} -> build_sigil_patch(sigil, occ_plans) end)
    |> patch_or_passthrough(source)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp match_occurrence_to_sigil({plan, occ}, sigils) do
    case Enum.find(sigils, &sigil_contains_line?(&1, occ.line)) do
      nil -> []
      sigil -> [{sigil, occ, plan}]
    end
  end

  defp sigil_contains_line?(sigil, file_line) do
    body_lines = count_lines(sigil.body)
    sigil.file_line < file_line and file_line <= sigil.file_line + body_lines + 1
  end

  defp build_sigil_patch(sigil, occ_plans) do
    new_body = splice_calls_in_body(sigil.body, occ_plans)
    range = Sourceror.get_range(sigil.sigil_node)
    indent = String.duplicate(" ", range.start[:column] - 1)
    rendered = render_sigil(new_body, indent)
    Sourceror.Patch.new(%{end: range.end, start: range.start}, rendered, false)
  end

  # Splice every component call into the dedented body, back-to-front so
  # earlier byte ranges aren't shifted by later splices.
  defp splice_calls_in_body(body, occ_plans) do
    occ_plans
    |> Enum.map(fn {occ, plan} ->
      {Tree.node_byte_range(occ.node, body), render_call(plan)}
    end)
    |> Enum.sort_by(fn {{start, _end}, _call} -> -start end)
    |> Enum.reduce(body, fn {{start, stop}, call}, acc ->
      binary_part(acc, 0, start) <>
        call <> binary_part(acc, stop, byte_size(acc) - stop)
    end)
  end

  defp render_sigil(new_body, indent) do
    indented_body =
      new_body
      |> String.split("\n", trim: false)
      |> Enum.map_join("\n", fn
        "" -> ""
        line -> indent <> line
      end)

    "~H\"\"\"\n" <> indented_body <> indent <> "\"\"\""
  end

  defp collect_sigils_with_nodes(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.flat_map(&sigil_node_or_empty/1)

      _ ->
        []
    end
  end

  defp sigil_node_or_empty({:sigil_H, _meta, [{:<<>>, body_meta, [body]}, _modifiers]} = node)
       when is_binary(body),
       do: [%{body: body, file_line: Keyword.get(body_meta, :line, 1), sigil_node: node}]

  defp sigil_node_or_empty(_), do: []

  defp assign_names(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:@, _, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) -> [name]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp cluster_to_plan(%{hash: hash, occurrences: occs} = cluster) do
    rep_node = hd(occs).node
    %{assigns: assigns, locals: locals} = find_free_vars(rep_node)
    root = root_tag(rep_node)
    rep_file = occs |> Enum.map(& &1.file) |> Enum.min()
    name = component_name(rep_file, root, hash)
    body = render_subtree(rep_node, locals)

    %{
      assigns: assigns,
      body: body,
      hash: hash,
      locals: locals,
      mass: cluster.mass,
      name: name,
      occurrences: occs,
      root_tag: root
    }
  end

  defp component_present?(source, plan),
    do: source |> String.contains?("defp #{plan.name}(assigns)")

  defp core_components_module(opts),
    do:
      opts
      |> Keyword.get(:project_config, %{})
      |> heex_map()
      |> Map.get(:core_components_module)

  # `:heex` is documented as a map (`%{core_components_module: "…"}`); a
  # keyword list is an easy misconfig that must degrade to "no heex config"
  # rather than crash the whole run with a BadMapError.
  defp heex_map(config) do
    case Map.get(config, :heex, %{}) do
      %{} = map -> map
      _ -> %{}
    end
  end

  defp core_components_source?(source, module),
    do:
      ~r/^defmodule\s+#{Regex.escape(module)}\b/m
      |> Regex.match?(source)

  defp count_lines(s), do: s |> :binary.matches("\n") |> length()

  defp find_module_end_line(source) do
    source
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.find_value(fn
      {"end", line} -> line
      _ -> nil
    end)
  end

  defp indent(text, prefix) do
    text
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end

  defp insert_before_line(source, line, insert_text) do
    lines = String.split(source, "\n", trim: false)
    {head, tail} = lines |> Enum.split(line - 1)
    (head ++ [insert_text | tail]) |> Enum.join("\n")
  end

  defp parse_for_pattern(header) do
    trimmed = header |> String.trim() |> String.trim_trailing("do") |> String.trim()

    case trimmed do
      "for " <> rest ->
        parse_for_comprehension(rest)

      _ ->
        :error
    end
  end

  defp parse_for_comprehension(rest) do
    case Code.string_to_quoted("for " <> rest <> " do :ok end") do
      {:ok, {:for, _, args}} ->
        generators = args |> Enum.filter(&match?({:<-, _, _}, &1))

        case generators do
          [{:<-, _, [pattern, coll]}] ->
            {:ok, pattern_var_names(pattern), assign_names(coll)}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp render_attr({name, {:string, value}}, _locals),
    do: ~s( #{name}="#{value}")

  defp render_attr({name, {:expr, code}}, locals),
    do: " #{name}={#{rewrite_locals(code, locals)}}"

  defp render_call(plan) do
    attrs =
      Enum.map(plan.assigns, &~s(#{&1}={@#{&1}})) ++
        Enum.map(plan.locals, &~s(#{&1}={#{&1}}))

    case attrs do
      [] -> "<.#{plan.name} />"
      _ -> "<.#{plan.name} #{attrs |> Enum.join(" ")} />"
    end
  end

  defp render_component_def(plan) do
    attrs =
      (plan.assigns ++ plan.locals)
      |> Enum.map_join("\n  ", fn name -> "attr :#{name}, :any" end)

    indented_body = indent(plan.body, "    ")

    """

      #{attrs}
      defp #{plan.name}(assigns) do
        ~H\"\"\"
    #{indented_body}
        \"\"\"
      end
    """
  end

  defp resolve_target_file(source, opts, prepared) do
    case opts[:file] do
      file when is_binary(file) ->
        file

      _ ->
        case prepared do
          %{source_to_file: map} -> Map.get(map, source)
          _ -> nil
        end
    end
  end

  defp rewrite_locals(code, []), do: code

  defp rewrite_locals(code, locals) do
    locals
    |> Enum.reduce(code, fn name, acc ->
      pattern = ~r/(?<![@\w])#{Regex.escape(Atom.to_string(name))}(?!\w)/
      Regex.replace(pattern, acc, "@#{name}")
    end)
  end

  defp root_tag({:element, tag, _, _, _}), do: tag
  defp root_tag({:eex_block, _, _, _}), do: "eex_block"
  defp root_tag({:eex_expr, _, _}), do: "eex_expr"
  defp root_tag({:text, _, _}), do: "text"
  defp scan([], assigns, locals, _bound), do: {assigns, locals}

  defp scan([{:element, _tag, attrs, children, _meta} | rest], a, l, b) do
    {a, l} = scan_attrs(attrs, a, l, b)
    {a, l} = scan(children, a, l, b)
    scan(rest, a, l, b)
  end

  defp scan([{:eex_block, header, children, _meta} | rest], a, l, b),
    do: parse_for_pattern(header) |> scan_eex_block_branch(a, b, children, header, l, rest)

  defp scan([{:eex_expr, code, _meta} | rest], a, l, b) do
    {a, l} = scan_eex_code(code, a, l, b)
    scan(rest, a, l, b)
  end

  defp scan([{:text, _text, _meta} | rest], a, l, b), do: scan(rest, a, l, b)
  defp scan_attrs([], a, l, _b), do: {a, l}

  defp scan_attrs([{_name, {:string, _}} | rest], a, l, b),
    do: scan_attrs(rest, a, l, b)

  defp scan_attrs([{_name, {:expr, code}} | rest], a, l, b) do
    {a, l} = scan_eex_code(code, a, l, b)
    scan_attrs(rest, a, l, b)
  end

  defp scan_eex_block_branch(
         {:ok, pattern_vars, coll_assigns},
         a,
         b,
         children,
         _header,
         l,
         rest
       ) do
    a = coll_assigns |> Enum.reduce(a, &MapSet.put(&2, &1))
    new_b = pattern_vars |> Enum.reduce(b, &MapSet.put(&2, &1))
    l = pattern_vars |> Enum.reduce(l, &MapSet.put(&2, &1))
    {a, l} = scan(children, a, l, new_b)
    scan(rest, a, l, b)
  end

  defp scan_eex_block_branch(:error, a, b, children, header, l, rest) do
    {a, l} = scan_eex_code(header, a, l, b)
    {a, l} = scan(children, a, l, b)
    scan(rest, a, l, b)
  end

  defp scan_eex_code(code, a, l, b),
    do: Code.string_to_quoted(code) |> walk_eex_ast_branch(a, b, l)

  defp walk_ast(ast, a, l, b) do
    {_, {a, l}} =
      Macro.prewalk(ast, {a, l}, fn
        {:@, _, [{name, _, ctx}]} = node, {a, l} when is_atom(name) and is_atom(ctx) ->
          classify_assign(node, name, a, l, b)

        {name, _, ctx} = node, {a, l} when is_atom(name) and is_atom(ctx) ->
          classify_var(node, name, a, l, b)

        node, acc ->
          {node, acc}
      end)

    {a, l}
  end

  defp classify_assign(node, name, a, l, b) do
    if MapSet.member?(b, name) do
      {node, {a, MapSet.put(l, name)}}
    else
      {node, {MapSet.put(a, name), l}}
    end
  end

  defp classify_var(node, name, a, l, b) do
    string = Atom.to_string(name)

    cond do
      String.starts_with?(string, "_") -> {node, {a, l}}
      name in [:when, :=, :|, :"::"] -> {node, {a, l}}
      MapSet.member?(b, name) -> {node, {a, MapSet.put(l, name)}}
      true -> {node, {a, l}}
    end
  end

  defp walk_eex_ast_branch({:ok, ast}, a, b, l), do: ast |> walk_ast(a, l, b)
  defp walk_eex_ast_branch({:error, _}, a, _b, l), do: {a, l}
end
