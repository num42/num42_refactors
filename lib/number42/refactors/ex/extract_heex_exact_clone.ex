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
      # Patches must be applied back-to-front, otherwise earlier
      # patches shift the byte offsets of later ones.
      |> Enum.sort_by(fn {_plan, occ} -> -occ.line end)

    occs_in_file
    |> Enum.reduce(source, fn {plan, occ}, acc ->
      replace_occurrence(acc, plan, occ)
    end)
  end

  defp assign_names(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:@, _, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) -> [name]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp byte_offset_of_line(source, line) do
    source
    |> String.split("\n", trim: false)
    |> Enum.take(line - 1)
    |> Enum.reduce(0, fn part, acc -> acc + byte_size(part) + 1 end)
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
      |> Map.get(:heex, %{})
      |> Map.get(:core_components_module)

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

  defp locate_sigil_containing({:ok, sigils}, file_line, source) do
    sigils
    |> Enum.find(fn s ->
      body_lines = count_lines(s.body)
      s.file_line < file_line and file_line <= s.file_line + body_lines + 1
    end)
    |> case do
      nil ->
        nil

      sigil ->
        body_start_byte = byte_offset_of_line(source, sigil.file_line + 1)
        {sigil.body, body_start_byte}
    end
  end

  defp locate_sigil_containing(:error, _file_line, _source), do: nil

  defp locate_sigil_for_line(source, file_line),
    do: Tree.from_source(source) |> locate_sigil_containing(file_line, source)

  defp parse_for_pattern(header) do
    trimmed = header |> String.trim() |> String.trim_trailing("do") |> String.trim()

    case trimmed do
      "for " <> rest ->
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

  defp replace_occurrence(source, plan, occurrence),
    do:
      locate_sigil_for_line(source, occurrence.line)
      |> splice_call_at_sigil(occurrence, plan, source)

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

  defp splice_call_at_sigil(nil, _occurrence, _plan, source), do: source

  defp splice_call_at_sigil({sigil_body, sigil_body_start_byte}, occurrence, plan, source) do
    {body_start, body_end} = Tree.node_byte_range(occurrence.node, sigil_body)
    abs_start = sigil_body_start_byte + body_start
    abs_end = sigil_body_start_byte + body_end
    call = render_call(plan)

    binary_part(source, 0, abs_start) <>
      call <> binary_part(source, abs_end, byte_size(source) - abs_end)
  end

  defp walk_ast(ast, a, l, b) do
    {_, {a, l}} =
      Macro.prewalk(ast, {a, l}, fn
        {:@, _, [{name, _, ctx}]} = node, {a, l} when is_atom(name) and is_atom(ctx) ->
          if MapSet.member?(b, name) do
            {node, {a, MapSet.put(l, name)}}
          else
            {node, {MapSet.put(a, name), l}}
          end

        {name, _, ctx} = node, {a, l} when is_atom(name) and is_atom(ctx) ->
          string = Atom.to_string(name)

          cond do
            String.starts_with?(string, "_") -> {node, {a, l}}
            name in [:when, :=, :|, :"::"] -> {node, {a, l}}
            MapSet.member?(b, name) -> {node, {a, MapSet.put(l, name)}}
            true -> {node, {a, l}}
          end

        node, acc ->
          {node, acc}
      end)

    {a, l}
  end

  defp walk_eex_ast_branch({:ok, ast}, a, b, l), do: ast |> walk_ast(a, l, b)
  defp walk_eex_ast_branch({:error, _}, a, _b, l), do: {a, l}
end
