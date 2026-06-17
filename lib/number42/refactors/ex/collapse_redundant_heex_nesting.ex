defmodule Number42.Refactors.Ex.CollapseRedundantHeexNesting do
  @moduledoc """
  Collapse a redundant HEEx wrapper by **pulling the only child's
  styling up** into a transparent, attribute-less container.

      # before
      def render(assigns) do
        ~H\"\"\"
        <div>
          <div class="card">{@body}</div>
        </div>
        \"\"\"
      end

      # after
      def render(assigns) do
        ~H\"\"\"
        <div class="card">{@body}</div>
        \"\"\"
      end

  The outer element contributes nothing but nesting: it is a transparent
  container, carries no attributes, and wraps a single child element with
  no other content. The child is itself a transparent container whose
  only attribute is `class`. The two levels collapse into one: the outer
  tag stays, adopts the child's `class`, and the child dissolves —
  promoting its inner content to the outer.

  This is "Case B" of the nesting catalogue (styling up). The mirror
  case — an attribute-bearing wrapper around a styleless transparent
  child (styling down) — is out of scope here.

  ## Default-OFF (opt-in only)

  Disabled by default until its guards are trusted. Enable per project
  via `.refactor.exs`:

      configured_modules: [
        {Number42.Refactors.Ex.CollapseRedundantHeexNesting, enabled: true}
      ]

  Without `enabled: true`, `transform/2` is a no-op.

  ## Trigger (all must hold)

  - **Outer** is a transparent container
    (`div span section article main aside nav header footer`) with
    **exactly zero attributes**.
  - **Outer** has **exactly one child element** and **no non-whitespace
    text** and **no `{...}` expression** siblings of that child. A
    leading/trailing text or interpolation sibling means the wrapper
    carries content of its own and is not redundant.
  - **Child** is a plain transparent-container *element* — not a
    component (`<.x>`), not a slot entry (`<:x>`), not an `<%= … %>`
    block — whose **only attribute is `class`**. Any other attribute
    (`id`, `phx-*`, `:for`, event listeners, …) vetoes: it would be
    silently dropped or would change semantics if hoisted blindly.

  ## Content-model gate (fail-safe toward not collapsing)

  HTML has parent/child content models that the parser is permissive
  about but the browser is not: a `<tr>` must live directly under a
  table section, an `<li>` under a list, an `<option>` under a `select`
  or `optgroup`. Collapsing across such a boundary would move a child
  out from under its required parent (or fuse a required wrapper away).

  We **never** collapse when either the outer or the inner tag is one of
  `table thead tbody tfoot tr ul ol dl select optgroup figure`. The
  outer can't be one anyway (not in the transparent-container allow
  list), but the inner could be — so the gate is enforced on the child
  tag explicitly.

  ## Idempotence

  After a collapse the surviving element carries a `class` attribute, so
  it no longer satisfies the zero-attribute outer requirement — a second
  pass is a no-op. Already-flat markup never matches.

  ## v1 scope

  Non-overlapping outermost matches are collapsed in one pass; a match
  nested inside another match's range is left for the next pass so byte
  splicing never operates on overlapping ranges.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Heex.Tree
  alias Sourceror.Patch

  @transparent_containers ~w(div span section article main aside nav header footer)

  # Tags whose content model forbids reparenting their children or
  # fusing them away. The gate is enforced on the inner tag.
  @content_model_tags ~w(table thead tbody tfoot tr ul ol dl select optgroup figure)

  @impl Number42.Refactors.Refactor
  def description,
    do: "Collapse a redundant transparent HEEx wrapper, pulling the only child's class up"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A transparent, attribute-less container that wraps exactly one
    transparent child element — whose only attribute is `class` — adds a
    level of nesting and nothing else. We collapse the two into one: the
    outer tag stays, adopts the child's `class`, and the child dissolves,
    promoting its inner content. Only `div span section article main
    aside nav header footer` qualify as transparent containers, and we
    never collapse across a content-model boundary (`table`, `tr`, `ul`,
    `select`, `figure`, …). The child must carry `class` and nothing
    else — any `id`, `phx-*`, `:for` or listener vetoes the rewrite.
    Opt-in (default-off) and idempotent: the merged element keeps a
    `class`, so it can't match again.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 100

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      Sourceror.parse_string(source) |> rewrite(source)
    else
      source
    end
  end

  defp rewrite({:ok, ast}, source), do: ast |> collect_h_sigils() |> apply_sigils(source)
  defp rewrite({:error, _}, source), do: source

  defp apply_sigils(sigils, source) do
    patches = Enum.flat_map(sigils, &sigil_patch_or_empty/1)

    case patches do
      [] -> source
      _ -> Sourceror.patch_string(source, patches)
    end
  end

  defp sigil_patch_or_empty(%{body: body, tree: tree, sigil_node: node}) do
    case collapse_sites(tree, body) do
      [] ->
        []

      sites ->
        new_body = rewrite_body(body, sites)
        range = Sourceror.get_range(node)
        indent = String.duplicate(" ", range.start[:column] - 1)
        [Patch.new(%{end: range.end, start: range.start}, render_sigil(new_body, indent), false)]
    end
  end

  # --- site detection -------------------------------------------------

  # A site is `{outer_node, inner_node}`. We collect every matching
  # outer element, then drop any whose byte range is contained in
  # another match's range so right-to-left splicing never overlaps.
  defp collapse_sites(tree, body) do
    Tree.walk(tree, [], fn node, acc -> collect_site(node, acc) end)
    |> Enum.reverse()
    |> drop_nested(body)
  end

  defp collect_site({:element, _, _, _, _} = node, acc) do
    case redundant_wrapper(node) do
      {kind, inner} -> [{kind, node, inner} | acc]
      :no -> acc
    end
  end

  defp collect_site(_node, acc), do: acc

  # Two dissolutions share one wrapper shape — an attribute-less transparent
  # outer with a single child element and no content siblings:
  #
  #   Case B (:hoist_class): inner is itself a transparent container whose only
  #     attribute is `class`. The outer adopts the class, the inner dissolves.
  #   Case A (:dissolve_wrapper): inner is any single element OR component. The
  #     outer tag is removed and the inner is promoted verbatim (the outer was
  #     pure nesting around `<.card/>` / `<section>…`).
  #
  # B is preferred: when both apply (outer empty, inner a class-only transparent
  # container) they yield the same flat markup, so B's class-merge path is canonical.
  # Only ever called with an `:element` node — `collect_site/2` matches the
  # node shape before delegating, so a non-element catch-all clause is dead
  # code (Dialyzer `pattern_match_cov`). The `with/else` keeps it total over
  # every `:element`.
  defp redundant_wrapper({:element, tag, attrs, children, _meta}) do
    with true <- tag in @transparent_containers,
         [] <- attrs,
         {:ok, inner} <- sole_child_element(children) do
      classify_inner(inner)
    else
      _ -> :no
    end
  end

  # Case B: inner is a transparent container carrying ONLY a class.
  defp classify_inner({:element, inner_tag, [{"class", _}], _, _} = inner)
       when inner_tag in @transparent_containers and inner_tag not in @content_model_tags,
       do: {:hoist_class, inner}

  # Case A: dissolve the outer wrapper. Only SAFE shapes qualify — dissolving an
  # inner element promotes its *content* into the outer tag, so any attribute on
  # an inner ELEMENT would be silently dropped (a `phx-click`, `:for`, `id`, …).
  # Therefore:
  #   - inner COMPONENT (`<.card …/>`) → safe: kept verbatim, attributes intact;
  #   - inner attribute-less plain ELEMENT → safe: nothing to lose;
  #   - inner element WITH attributes → SKIP (Case B already handles the
  #     class-only sub-case; anything else would lose data).
  defp classify_inner(inner), do: dissolve(inner)

  # slot entry — belongs to its parent component, never a wrapper child
  defp dissolve({:element, ":" <> _slot, _, _, _}), do: :no

  # content-model child — must keep its required parent
  defp dissolve({:element, tag, _, _, _}) when tag in @content_model_tags, do: :no

  # component child — dissolve the wrapper, keep the component verbatim
  defp dissolve({:element, "." <> _, _, _, _} = inner), do: {:dissolve_wrapper, inner}

  defp dissolve({:element, <<u, _::binary>>, _, _, _} = inner) when u in ?A..?Z,
    do: {:dissolve_wrapper, inner}

  # plain element with ZERO attributes — safe to promote its content
  defp dissolve({:element, _tag, [], _, _} = inner), do: {:dissolve_wrapper, inner}

  # plain element WITH attributes — content promotion would drop them; SKIP
  defp dissolve(_), do: :no

  # The outer's children must be exactly one element node with no
  # non-whitespace text and no `{...}`/`<%= %>` expression siblings.
  defp sole_child_element(children) do
    {elements, others} =
      Enum.split_with(children, fn
        {:element, _, _, _, _} -> true
        _ -> false
      end)

    cond do
      elements == [] -> :none
      tl(elements) != [] -> :none
      not Enum.all?(others, &whitespace_text?/1) -> :none
      true -> {:ok, hd(elements)}
    end
  end

  # The tree drops whitespace-only text, so any surviving non-element
  # sibling is meaningful content (text or interpolation) and vetoes.
  defp whitespace_text?({:text, str, _}), do: String.trim(str) == ""
  defp whitespace_text?(_), do: false

  # Keep only outermost matches: drop any whose range sits inside
  # another match's range.
  defp drop_nested(sites, body) do
    ranges =
      Enum.map(sites, fn {_kind, outer, _} = site -> {site, Tree.node_byte_range(outer, body)} end)

    ranges
    |> Enum.reject(fn {_site, {s, e}} ->
      Enum.any?(ranges, fn {_other, {os, oe}} ->
        {os, oe} != {s, e} and os <= s and e <= oe
      end)
    end)
    |> Enum.map(fn {site, _range} -> site end)
  end

  # --- body rewrite ---------------------------------------------------

  defp rewrite_body(body, sites) do
    sites
    |> Enum.map(fn {kind, outer, inner} ->
      {kind, outer, inner, Tree.node_byte_range(outer, body)}
    end)
    |> Enum.sort_by(fn {_kind, _outer, _inner, {s, _e}} -> -s end)
    |> Enum.reduce(body, fn {kind, outer, inner, range}, acc ->
      splice_collapse(kind, acc, outer, inner, range)
    end)
  end

  # Case B: outer keeps its tag and adopts the inner's class; inner dissolves.
  defp splice_collapse(:hoist_class, body, {:element, outer_tag, _, _, _}, inner, {s, e}) do
    {:element, _inner_tag, [{"class", value}], _, _} = inner
    inner_html = inner_content(inner, body)
    merged = "<#{outer_tag} class=#{render_class(value)}>#{inner_html}</#{outer_tag}>"
    binary_part(body, 0, s) <> merged <> binary_part(body, e, byte_size(body) - e)
  end

  # Case A: the outer tag WINS (keeps its position/role in the surrounding tree).
  # For an inner plain ELEMENT the outer tag is kept and the inner element's
  # CONTENT is promoted into it (`<article><section>X</section></article>` →
  # `<article>X</article>`). For an inner COMPONENT (`<.card/>`) there is no
  # "content to promote into the outer" — the component IS the content, so the
  # redundant outer wrapper is dropped and the component kept verbatim.
  defp splice_collapse(:dissolve_wrapper, body, outer, inner, {s, e}) do
    replacement = dissolve_replacement(outer, inner, body)
    binary_part(body, 0, s) <> replacement <> binary_part(body, e, byte_size(body) - e)
  end

  # inner is a plain HTML element → keep the outer tag, promote inner's content
  defp dissolve_replacement(
         {:element, outer_tag, _, _, _} = outer,
         {:element, inner_tag, _, _, _} = inner,
         body
       )
       when inner_tag != "" do
    if component_tag?(inner_tag) do
      # promoting the component up one level: shift its continuation lines left
      # by the indent the wrapper added, so multi-line components stay aligned
      verbatim(inner, body) |> reindent(outer, inner, body)
    else
      "<#{outer_tag}>#{inner_content(inner, body)}</#{outer_tag}>"
    end
  end

  defp verbatim(node, body) do
    {s, e} = Tree.node_byte_range(node, body)
    binary_part(body, s, e - s)
  end

  # The wrapper nested the inner one level deeper. After collapse the inner sits
  # where the outer was, so every continuation line of the (verbatim) inner is
  # over-indented by `inner_col - outer_col`. Strip that many leading spaces from
  # each line after the first. The first line needs no change — it replaces the
  # outer's open tag at the outer's column.
  defp reindent(text, outer, inner, body) do
    shift = max(line_col(outer, body) |> indent_delta(line_col(inner, body)), 0)

    case String.split(text, "\n") do
      [single] ->
        single

      [first | rest] ->
        Enum.join([first | Enum.map(rest, &strip_leading(&1, shift))], "\n")
    end
  end

  defp indent_delta(outer_col, inner_col), do: inner_col - outer_col

  # 0-based column where the node's start byte sits on its line (= bytes since the
  # preceding newline). Both nodes start right after their leading whitespace, so
  # the column difference is exactly the extra indentation the wrapper added.
  defp line_col({:element, _, _, _, _} = node, body) do
    {s, _e} = Tree.node_byte_range(node, body)
    prefix = binary_part(body, 0, s)

    case :binary.matches(prefix, "\n") do
      [] -> s
      matches -> s - (matches |> List.last() |> elem(0)) - 1
    end
  end

  defp strip_leading(line, 0), do: line

  defp strip_leading(line, n) do
    {ws, rest} = String.split_at(line, leading_count(line))
    kept = max(String.length(ws) - n, 0)
    String.duplicate(" ", kept) <> rest
  end

  defp leading_count(line),
    do: line |> String.graphemes() |> Enum.take_while(&(&1 in [" ", "\t"])) |> length()

  defp component_tag?("." <> _), do: true
  defp component_tag?(<<u, _::binary>>) when u in ?A..?Z, do: true
  defp component_tag?(_), do: false

  defp render_class({:string, value}), do: ~s("#{value}")
  defp render_class({:expr, code}), do: "{#{code}}"

  # The child's inner content: bytes between its open tag's `>` and its
  # `</tag>`, sliced verbatim from the body.
  defp inner_content({:element, tag, _attrs, _children, _meta} = node, body) do
    {s, e} = Tree.node_byte_range(node, body)
    open_end = open_tag_end(body, s)
    close_len = byte_size("</" <> tag <> ">")
    inner_len = e - close_len - open_end

    if inner_len > 0, do: binary_part(body, open_end, inner_len), else: ""
  end

  # Scan from `<` past attributes to the matching `>` that ends the open
  # tag, respecting quotes and `{...}` expression nesting.
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
