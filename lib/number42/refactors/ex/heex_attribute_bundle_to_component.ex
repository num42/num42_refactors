defmodule Number42.Refactors.Ex.HeexAttributeBundleToComponent do
  @moduledoc """
  Collapse a repeated HEEx **tag shell** — the same tag name with the
  same attribute bundle, wrapping *different* inner content — into a
  single private slot-component, and replace each occurrence with a
  call that carries its original body as the inner block.

      # before
      def render(assigns) do
        ~H\"\"\"
        <div class="danger_panel">
          <p>{@first}</p>
        </div>
        <div class="danger_panel">
          <strong>{@second}</strong>
        </div>
        \"\"\"
      end

      # after
      def render(assigns) do
        ~H\"\"\"
        <.danger_panel>
          <p>{@first}</p>
        </.danger_panel>
        <.danger_panel>
          <strong>{@second}</strong>
        </.danger_panel>
        \"\"\"
      end

      slot :inner_block
      defp danger_panel(assigns) do
        ~H\"\"\"
        <div class="danger_panel">
          {render_slot(@inner_block)}
        </div>
        \"\"\"
      end

  The shell (tag + attributes) is the recurring mass; the body is the
  varying hole. Lifting the shell gives the wrapper a name, one source
  of truth for its attributes, and a real slot boundary in place of
  copy/pasted markup.

  ## Default-OFF (opt-in only)

  This refactor is **disabled by default** until its naming and
  accessibility guards are trusted. Enable it deliberately, per
  project, via `.refactor.exs`:

      configured_modules: [
        {Number42.Refactors.Ex.HeexAttributeBundleToComponent,
         enabled: true, min_occurrences: 2}
      ]

  Without `enabled: true` in its own opts, `transform/2` is a no-op.

  ## Detection

  Within each `~H` sigil, element nodes are fingerprinted by
  `{tag, attrs}` (children excluded). Shells sharing a fingerprint
  with at least `:min_occurrences` (default `2`) members form a group.
  Static attributes are baked into the generated component; dynamic
  `attr={expr}` attributes are forwarded — the call site passes the
  original expression, the component declares `attr :name, :any` and
  re-emits `name={@name}`.

  ## Naming

  The component name is the first identifier-shaped token of the
  shell's static `class` attribute (`"danger_panel highlight"` →
  `danger_panel`). Class tokens are the human-meaningful label for a
  wrapper; deriving from them keeps the generated name greppable. A
  shell with no static class token is skipped — auto-naming a
  `<div data-role=…>` wrapper produces noise, so we defer to the human.

  ## Skip list (source left unchanged when any holds)

  - **Not opted in.** No `enabled: true` → no-op.
  - **Fewer than `min_occurrences` shells** sharing a fingerprint.
  - **Component tags** (`<.foo …>`). Already a component; nothing to lift.
  - **Form/input/semantic elements.** `form`, `input`, `select`,
    `textarea`, `button`, `label`, `fieldset`, `nav`, `main`, `header`,
    `footer`, `dialog` and friends carry accessibility/landmark
    semantics that wrapping in a generic slot component can obscure.
    Skipped unless the catalogue grows guards for them.
  - **Body with EEx control flow.** A `<%= for/if/… do %>` block in the
    body introduces local bindings; lifting the body into a slot moves
    it verbatim but the control-flow scope is fragile to reason about
    mechanically, so we skip rather than risk a binding that can't
    become slot content safely.
  - **Dynamic class.** `class={…}` gives no static token to name from.
  - **Name collision.** The derived name already exists as a function
    in the module — emitting `defp name(assigns)` would clash.
  - **Already a component call.** `<.name>…</.name>` shells are not
    HTML elements, so they never enter a group (idempotence).

  ## v1 scope

  One group is collapsed per module per pass (the first eligible, in
  source order). Further groups are handled by subsequent passes. Only
  shells inside a single sigil are grouped; cross-sigil and cross-file
  shells are out of scope (see `ExtractHeexExactClone` for the exact
  cross-file clone case).
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Heex.Tree
  alias Sourceror.Patch

  @default_min_occurrences 2

  # Tags whose semantics make a generic slot wrapper risky. Forms,
  # inputs and landmark/interactive elements carry accessibility
  # meaning that hiding behind a synthesised component can obscure.
  @unsafe_tags ~w(
    form input select textarea button label fieldset legend output
    nav main header footer aside dialog table thead tbody tr th td
    ol ul li dl dt dd figure figcaption details summary
  )

  @impl Number42.Refactors.Refactor
  def description,
    do: "Extract a repeated HEEx tag/attribute shell into a private slot component"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Repeated wrapper markup — the same tag with the same attribute
    bundle, wrapping different inner content — is a clone whose body is
    the only varying part. We fingerprint element shells by tag plus
    attributes (children excluded), and when a shell recurs at least
    `min_occurrences` times in a `~H` sigil, lift it into a private
    `defp` component with an `inner_block` slot. Static attributes are
    baked in; dynamic `attr={expr}` attributes are forwarded as assigns.
    Each occurrence becomes a `<.name>…</.name>` call carrying its
    original body. The component is named from the shell's class token
    (`danger_panel`, `primary_button`). Opt-in and threshold-gated;
    skips form/input/landmark elements, dynamic-class shells, bodies
    with EEx control flow, and name collisions. Idempotent: component
    calls are not HTML elements, so they never re-enter a group.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 100

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      min = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
      Sourceror.parse_string(source) |> rewrite(source, min)
    else
      source
    end
  end

  defp rewrite({:ok, ast}, source, min) do
    existing = existing_function_names(ast)

    ast
    |> collect_h_sigils()
    |> Enum.find_value(:none, &eligible_group_in_sigil(&1, min, existing))
    |> apply_group_or_passthrough(source)
  end

  defp rewrite({:error, _}, source, _min), do: source

  defp apply_group_or_passthrough(:none, source), do: source

  defp apply_group_or_passthrough(group, source) do
    patch = build_sigil_patch(group)

    source
    |> Sourceror.patch_string([patch])
    |> append_component(group)
  end

  # --- group detection ------------------------------------------------

  defp eligible_group_in_sigil(sigil, min, existing) do
    sigil
    |> candidate_groups(min)
    |> Enum.find_value(fn group -> eligible_group(group, sigil, existing) end)
  end

  defp candidate_groups(%{tree: tree} = sigil, min) do
    tree
    |> collect_elements()
    |> Enum.group_by(&shell_fingerprint/1)
    |> Enum.filter(fn {_fp, nodes} -> length(nodes) >= min end)
    |> Enum.map(fn {_fp, nodes} -> %{nodes: nodes, sigil: sigil} end)
    # Largest shell first — most worth extracting.
    |> Enum.sort_by(fn %{nodes: [n | _]} -> -attr_count(n) end)
  end

  defp eligible_group(%{nodes: [rep | _] = nodes} = group, sigil, existing) do
    with {:element, tag, attrs, _children, _meta} <- rep,
         true <- safe_tag?(tag),
         true <- Enum.all?(nodes, &safe_body?/1),
         {:ok, name} <- shell_name(attrs),
         false <- MapSet.member?(existing, name) do
      Map.merge(group, %{name: name, tag: tag, attrs: attrs, sigil: sigil})
    else
      _ -> nil
    end
  end

  defp collect_elements(tree) do
    Tree.walk(tree, [], fn
      {:element, _, _, _, _} = node, acc -> [node | acc]
      _node, acc -> acc
    end)
    |> Enum.reverse()
  end

  # Shell identity: tag + the full attribute list (names + values,
  # static or dynamic). Children are excluded — they are the hole.
  defp shell_fingerprint({:element, tag, attrs, _children, _meta}), do: {tag, attrs}

  defp attr_count({:element, _, attrs, _, _}), do: length(attrs)

  # --- guards ---------------------------------------------------------

  defp safe_tag?("." <> _), do: false
  defp safe_tag?(tag), do: not String.contains?(tag, "/") and tag not in @unsafe_tags

  # The body must not introduce local bindings via EEx control flow:
  # those can't become slot content without scope reasoning we don't
  # attempt in v1.
  defp safe_body?({:element, _, _, children, _}) do
    Tree.walk(children, true, fn
      {:eex_block, _, _, _}, _acc -> false
      _node, acc -> acc
    end)
  end

  # --- naming ---------------------------------------------------------

  defp shell_name(attrs) do
    with {:string, class} <- attr_value(attrs, "class"),
         token when is_binary(token) <- first_class_token(class) do
      {:ok, String.to_atom(token)}
    else
      _ -> :error
    end
  end

  defp first_class_token(class) do
    class
    |> String.split(~r/\s+/, trim: true)
    |> Enum.find(&identifier_token?/1)
  end

  defp identifier_token?(token), do: Regex.match?(~r/^[a-z][a-z0-9_]*$/, token)

  defp attr_value(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp existing_function_names(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&def_name_or_empty/1)
    |> MapSet.new()
  end

  defp def_name_or_empty({def_kind, _, [head | _]}) when def_kind?(def_kind),
    do: head |> extract_def_name() |> List.wrap()

  defp def_name_or_empty(_), do: []

  defp extract_def_name({:when, _, [head | _]}), do: extract_def_name(head)
  defp extract_def_name({name, _, _}) when is_atom(name), do: name
  defp extract_def_name(_), do: nil

  # --- sigil rewrite (operate on the dedented body) -------------------

  defp build_sigil_patch(%{sigil: sigil} = group) do
    new_body = rewrite_body(sigil.body, group)
    range = Sourceror.get_range(sigil.sigil_node)
    indent = String.duplicate(" ", range.start[:column] - 1)
    Patch.new(%{end: range.end, start: range.start}, render_sigil(new_body, indent), false)
  end

  defp rewrite_body(body, %{nodes: nodes, name: name, attrs: attrs}) do
    forwarded = forwarded_attrs(attrs)

    # Replace each occurrence back-to-front so earlier byte offsets stay
    # valid while later ones are spliced.
    nodes
    |> Enum.map(fn node -> {node, Tree.node_byte_range(node, body)} end)
    |> Enum.sort_by(fn {_node, {s, _e}} -> -s end)
    |> Enum.reduce(body, fn {node, range}, acc ->
      splice_call(acc, node, range, name, forwarded)
    end)
  end

  defp splice_call(body, node, {s, e}, name, forwarded) do
    inner = inner_content(node, body, s, e)
    call = render_call(name, forwarded, inner)
    binary_part(body, 0, s) <> call <> binary_part(body, e, byte_size(body) - e)
  end

  # The original inner content (between the open tag's `>` and the
  # closing `</tag>`), sliced verbatim from the body.
  defp inner_content({:element, tag, _attrs, _children, _meta}, body, s, e) do
    open_end = open_tag_end(body, s)
    close_len = byte_size("</" <> tag <> ">")
    inner_len = e - close_len - open_end

    if inner_len > 0, do: binary_part(body, open_end, inner_len), else: ""
  end

  # Scan from `<` past attributes to the matching `>` that ends the
  # open tag, respecting quotes and `{...}` expression nesting.
  defp open_tag_end(body, start), do: scan_open(body, start + 1, false, 0)

  defp scan_open(body, pos, false, 0) do
    case binary_part_at(body, pos) do
      ">" -> pos + 1
      "\"" -> scan_open(body, pos + 1, :double, 0)
      "'" -> scan_open(body, pos + 1, :single, 0)
      "{" -> scan_open(body, pos + 1, false, 1)
      "" -> pos
      _ -> scan_open(body, pos + 1, false, 0)
    end
  end

  defp scan_open(body, pos, false, depth) when depth > 0 do
    case binary_part_at(body, pos) do
      "{" -> scan_open(body, pos + 1, false, depth + 1)
      "}" -> scan_open(body, pos + 1, false, depth - 1)
      "" -> pos
      _ -> scan_open(body, pos + 1, false, depth)
    end
  end

  defp scan_open(body, pos, quote, depth) do
    case {binary_part_at(body, pos), quote} do
      {"\"", :double} -> scan_open(body, pos + 1, false, depth)
      {"'", :single} -> scan_open(body, pos + 1, false, depth)
      {"", _} -> pos
      _ -> scan_open(body, pos + 1, quote, depth)
    end
  end

  defp binary_part_at(bin, pos) when pos >= 0 and pos < byte_size(bin),
    do: binary_part(bin, pos, 1)

  defp binary_part_at(_bin, _pos), do: ""

  # --- rendering ------------------------------------------------------

  # Dynamic `attr={expr}` attributes become forwarded assigns; static
  # attributes stay baked into the component.
  defp forwarded_attrs(attrs) do
    Enum.flat_map(attrs, fn
      {name, {:expr, code}} -> [{name, code}]
      {_name, {:string, _}} -> []
    end)
  end

  defp render_call(name, forwarded, inner) do
    attrs = Enum.map_join(forwarded, "", fn {n, code} -> " #{n}={#{code}}" end)
    "<.#{name}#{attrs}>#{inner}</.#{name}>"
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

  # --- component definition -------------------------------------------

  defp append_component(source, group) do
    case find_module_end_line(source) do
      nil -> source
      end_line -> insert_before_line(source, end_line, render_component(group))
    end
  end

  defp render_component(%{tag: tag, attrs: attrs, name: name}) do
    forwarded = forwarded_attrs(attrs)
    shell_open = render_shell_open(tag, attrs)

    """

      slot :inner_block
    #{render_attr_decls(forwarded)}  defp #{name}(assigns) do
        ~H\"\"\"
        #{shell_open}{render_slot(@inner_block)}</#{tag}>
        \"\"\"
      end
    """
  end

  defp render_shell_open(tag, attrs) do
    rendered = Enum.map_join(attrs, "", &render_attr/1)
    "<#{tag}#{rendered}>"
  end

  defp render_attr({name, {:string, value}}), do: ~s( #{name}="#{value}")
  defp render_attr({name, {:expr, _code}}), do: " #{name}={@#{name}}"

  defp render_attr_decls([]), do: ""

  defp render_attr_decls(forwarded),
    do: Enum.map_join(forwarded, "", fn {name, _} -> "  attr :#{name}, :any\n" end)

  # --- source surgery -------------------------------------------------

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

  defp insert_before_line(source, line, insert_text) do
    lines = String.split(source, "\n", trim: false)
    {head, tail} = Enum.split(lines, line - 1)
    Enum.join(head ++ [insert_text | tail], "\n")
  end

  # --- sigil collection (retains the AST node for Sourceror.get_range) -

  defp collect_h_sigils(ast) do
    case ast do
      {:defmodule, _, [_name, [{_do, body}]]} ->
        body
        |> body_to_exprs()
        |> Enum.flat_map(&sigils_in_top_expr/1)
        |> Enum.flat_map(&parse_sigil_or_skip/1)

      _ ->
        []
    end
  end

  defp sigils_in_top_expr(node) do
    node
    |> Macro.prewalker()
    |> Enum.flat_map(&sigil_in_node/1)
  end

  defp sigil_in_node({:sigil_H, _meta, [{:<<>>, body_meta, [body]}, _modifiers]} = node)
       when is_binary(body) do
    [%{body: body, file_line: Keyword.get(body_meta, :line, 1), sigil_node: node}]
  end

  defp sigil_in_node(_), do: []

  defp parse_sigil_or_skip(%{body: body} = sigil) do
    case Tree.parse_body(body) do
      {:ok, tree} -> [Map.put(sigil, :tree, tree)]
      :error -> []
    end
  end
end
