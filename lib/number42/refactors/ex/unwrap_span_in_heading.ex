defmodule Number42.Refactors.Ex.UnwrapSpanInHeading do
  @moduledoc """
  Unwrap styling-only `<span>` wrappers nested inside heading
  (`<h1>`–`<h6>`) or `<header>` elements in `~H` templates.

      # before
      def title(assigns) do
        ~H\"\"\"
        <h1><span class="title">Dashboard</span></h1>
        <header><span>Welcome</span></header>
        \"\"\"
      end

      # after
      def title(assigns) do
        ~H\"\"\"
        <h1 class="title">Dashboard</h1>
        <header>Welcome</header>
        \"\"\"
      end

  A `<span>` inside `<h1>`–`<h6>`/`<header>` is almost always a
  layout-only hook with no semantic meaning. Heading text should be the
  heading's direct content; styling belongs on the heading element
  itself or on its classes. Removing the wrapper trims the markup and
  matches the semantic-HTML guidance.

  ## Enabled by default

  Every rewrite is conservative: a bare attribute-less `<span>` is pure
  layout and dropping it changes nothing observable, and the class-hoist
  branch fires only when the span is the heading's sole child with a lone
  static class and the heading has no class to collide with. The heading
  / `<header>` landmark itself is always kept — only the styling-only
  span inside it is removed.

  ## Detection

  Each `~H` sigil is parsed with `Number42.Refactors.Analysis.Heex.Tree`. Inside
  every `<h1>`–`<h6>`/`<header>` element we look for descendant
  `<span>` elements (direct or nested) and rewrite the ones that are
  provably safe to unwrap. Spans outside a heading/header are never
  touched.

  ## Two rewrites, both conservative

  - **Bare unwrap.** A `<span>` with *no attributes* anywhere under a
    heading/header is replaced by its inner content (the `<span>`/
    `</span>` shell is dropped).
  - **Class hoist.** A `<span class="...">` whose only attribute is a
    *static* class, that is the *sole child* of the heading/header, and
    whose parent carries *no* `class` of its own, is unwrapped and its
    class moved onto the parent's open tag.

  ## Skip list (source left unchanged when any holds)

  - **Span outside a heading/header.** Nothing to do.
  - **Span with a meaning-bearing attribute** (`id`, `aria-*`, `data-*`,
    event bindings, `style`, …) — anything other than a lone static
    `class`. Those attributes may carry behaviour or semantics, so the
    span stays.
  - **Dynamic class** (`class={expr}`). No literal string to hoist.
  - **Classed span that is not the sole child** of the heading, or whose
    parent already has a `class`. Hoisting would drop or collide with
    existing markup, so we leave it for a human.

  ## Idempotence

  After a rewrite the span is gone; a second pass finds no span under a
  heading and is a no-op.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Analysis.Heex.Tree
  alias Sourceror.Patch

  @heading_tags ~w(h1 h2 h3 h4 h5 h6 header)

  @impl Number42.Refactors.Refactor
  def description,
    do: "Unwrap styling-only <span> nested inside <h1>-<h6>/<header>"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A `<span>` inside `<h1>`-`<h6>` or `<header>` is almost always a
    styling-only wrapper with no semantic meaning — exactly the layout-
    hook misuse the semantic-HTML guidance discourages. For each such
    span this either drops the bare `<span>` shell (keeping its inner
    content) or, when the span's sole attribute is a static `class`, it
    is the heading's only child, and the heading has no class of its
    own, hoists that class onto the heading and unwraps. Spans carrying
    id/aria/data/event/style attributes, dynamic classes, non-sole-child
    classed spans, and spans outside a heading/header are left untouched.
    Idempotent: once unwrapped there is no span to rewrite on a re-run.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts) do
    Sourceror.parse_string(source) |> rewrite(source)
  end

  defp rewrite({:ok, ast}, source) do
    ast
    |> collect_h_sigils()
    |> Enum.reduce(source, &rewrite_sigil/2)
  end

  defp rewrite({:error, _}, source), do: source

  defp rewrite_sigil(sigil, source) do
    case edits_for_sigil(sigil) do
      [] -> source
      edits -> source |> Sourceror.patch_string([sigil_patch(sigil, edits)])
    end
  end

  # --- edit collection -----------------------------------------------
  #
  # We locate elements by a self-contained structural scan of the sigil
  # body rather than `Tree.node_byte_range/2`: the latter resolves a
  # node by line plus the first marker on that line, so a `<span>` that
  # shares a line with its enclosing heading (the common case here)
  # cannot be located. The scan below tracks open/close boundaries with
  # full nesting, so it works regardless of line layout. The parsed
  # `tree` is kept only as a validity gate (malformed sigils are
  # skipped before we ever scan).

  # Every edit is `{byte_start, byte_end, replacement}` against the
  # dedented sigil body. We splice them back-to-front so earlier offsets
  # stay valid while later ones are applied.
  defp edits_for_sigil(%{body: body}) do
    body
    |> heading_regions()
    |> Enum.flat_map(&edits_for_heading(&1, body))
    |> Enum.sort_by(fn {s, _e, _r} -> -s end)
  end

  # `{tag, open_start, open_end, content_end}` for every heading/header
  # element in the body. `open_start` is the `<`; `open_end` is just
  # past the open tag's `>`; `content_end` is the `<` of `</tag>`.
  defp heading_regions(body), do: scan_tags(body, 0, [], @heading_tags)

  defp scan_tags(body, pos, acc, tags) do
    case :binary.match(body, "<", scope: {pos, byte_size(body) - pos}) do
      :nomatch ->
        Enum.reverse(acc)

      {lt, _} ->
        scan_tag_at(body, lt, acc, tags)
    end
  end

  defp scan_tag_at(body, lt, acc, tags) do
    {name, after_name} = read_tag_name(body, lt + 1)

    cond do
      name in tags ->
        open_end = open_tag_end(body, lt)
        content_end = matching_close(body, open_end, name, 1)
        region = {name, lt, open_end, content_end}
        scan_tags(body, content_end, [region | acc], tags)

      name == "" ->
        scan_tags(body, lt + 1, acc, tags)

      true ->
        scan_tags(body, after_name, acc, tags)
    end
  end

  defp edits_for_heading({_tag, _open_start, _open_end, content_end} = heading, body) do
    spans = span_regions(body, open_end(heading), content_end)

    case sole_classed_span(spans, heading, body) do
      {:ok, span} -> [hoist_class_edit(heading, span, body)]
      :none -> spans |> Enum.filter(&bare_span?(&1, body)) |> Enum.map(&unwrap_edit(&1, body))
    end
  end

  defp open_end({_tag, _open_start, open_end, _content_end}), do: open_end

  # `{open_start, open_end, content_end}` for every `<span>` inside the
  # `[from, content_end)` region (nested at any depth).
  defp span_regions(body, from, content_end),
    do: scan_spans(body, from, content_end, [])

  defp scan_spans(body, pos, limit, acc) when pos < limit do
    case :binary.match(body, "<span", scope: {pos, limit - pos}) do
      :nomatch ->
        Enum.reverse(acc)

      {lt, _} ->
        if span_boundary?(body, lt + byte_size("<span")) do
          open_end = open_tag_end(body, lt)
          content_close = matching_close(body, open_end, "span", 1)
          scan_spans(body, content_close, limit, [{lt, open_end, content_close} | acc])
        else
          scan_spans(body, lt + 1, limit, acc)
        end
    end
  end

  defp scan_spans(_body, _pos, _limit, acc), do: Enum.reverse(acc)

  # `<span` must be followed by a tag boundary so `<spanner>` doesn't match.
  defp span_boundary?(body, pos), do: byte_at(body, pos) in [">", "/", " ", "\t", "\n", "\r", ""]

  # --- class hoist ----------------------------------------------------

  # The single eligible class-hoist span: the heading's *sole* child is a
  # `<span class="...">` (static class, no other attribute) and the
  # heading itself carries no `class`.
  defp sole_classed_span([span], {_tag, h_start, h_open_end, content_end} = _heading, body) do
    {s_start, s_open_end, s_content_end} = span

    with false <- heading_has_class?(body, h_start, h_open_end),
         true <- only_whitespace?(body, h_open_end, s_start),
         true <- only_whitespace?(body, s_content_end + byte_size("</span>"), content_end),
         {:ok, _class} <- lone_static_class(body, s_start, s_open_end) do
      {:ok, span}
    else
      _ -> :none
    end
  end

  defp sole_classed_span(_spans, _heading, _body), do: :none

  defp heading_has_class?(body, h_start, h_open_end) do
    body
    |> binary_part(h_start, h_open_end - h_start)
    |> String.match?(~r/\sclass\s*=/)
  end

  # Replace the heading region: append `class="..."` to the heading open
  # tag (only reached when the heading has no class) and drop the span shell.
  defp hoist_class_edit({_tag, h_start, h_open_end, content_end}, span, body) do
    {s_start, s_open_end, s_content_end} = span
    {:ok, class} = lone_static_class(body, s_start, s_open_end)

    close_len = close_tag_len(body, content_end)
    inner = binary_part(body, s_open_end, s_content_end - s_open_end)
    before_span = binary_part(body, h_open_end, s_start - h_open_end)
    after_span = binary_part(body, s_content_end + byte_size("</span>"), close_len)
    new_open = binary_part(body, h_start, h_open_end - h_start - 1) <> ~s( class="#{class}">)

    h_end = content_end + close_len
    {h_start, h_end, new_open <> before_span <> inner <> after_span}
  end

  # Length of the heading's `</tag>` close that ends at end-of-content.
  defp close_tag_len(body, content_end), do: skip_until_gt(body, content_end) - content_end

  # --- bare unwrap ----------------------------------------------------

  # A `<span>` with no attributes: open tag is exactly `<span>`.
  defp bare_span?({s_start, s_open_end, _content_end}, body),
    do: binary_part(body, s_start, s_open_end - s_start) == "<span>"

  defp unwrap_edit({s_start, s_open_end, s_content_end}, body) do
    inner = binary_part(body, s_open_end, s_content_end - s_open_end)
    {s_start, s_content_end + byte_size("</span>"), inner}
  end

  # --- attribute / region helpers ------------------------------------

  # `{:ok, class}` iff the span's only attribute is a static
  # `class="..."` (double- or single-quoted); `:error` otherwise
  # (no attrs, dynamic `class={...}`, or any extra attribute).
  defp lone_static_class(body, s_start, s_open_end) do
    body
    |> binary_part(s_start, s_open_end - s_start)
    |> match_lone_class()
  end

  @lone_class_double ~r/\A<span\s+class="([^"]*)"\s*>\z/
  @lone_class_single ~r/\A<span\s+class='([^']*)'\s*>\z/

  defp match_lone_class(open_tag) do
    cond do
      m = Regex.run(@lone_class_double, open_tag) -> {:ok, Enum.at(m, 1)}
      m = Regex.run(@lone_class_single, open_tag) -> {:ok, Enum.at(m, 1)}
      true -> :error
    end
  end

  defp only_whitespace?(_body, from, to) when from >= to, do: true

  defp only_whitespace?(body, from, to),
    do: body |> binary_part(from, to - from) |> String.trim() == ""

  defp read_tag_name(body, pos), do: read_tag_name(body, pos, [])

  defp read_tag_name(body, pos, acc) do
    case byte_at(body, pos) do
      <<c::utf8>> = ch
      when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?-, ?_, ?., ?:, ?/] ->
        read_tag_name(body, pos + 1, [ch | acc])

      _ ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), pos}
    end
  end

  # Find the `<` of the matching `</tag>`, balancing nested same-name
  # opens. `pos` starts just past an open tag's `>`. Self-closing same-
  # name opens (`<tag .../>`) don't increase depth.
  defp matching_close(body, pos, tag, depth) do
    case :binary.match(body, "<", scope: {pos, byte_size(body) - pos}) do
      :nomatch ->
        byte_size(body)

      {lt, _} ->
        classify_tag(body, lt, tag, depth)
    end
  end

  defp classify_tag(body, lt, tag, depth) do
    close = "</" <> tag
    open = "<" <> tag

    cond do
      starts_with_boundary?(body, lt, close) ->
        if depth == 1, do: lt, else: matching_close(body, skip_until_gt(body, lt), tag, depth - 1)

      starts_with_boundary?(body, lt, open) ->
        descend_open(body, lt, tag, depth)

      true ->
        matching_close(body, lt + 1, tag, depth)
    end
  end

  defp descend_open(body, lt, tag, depth) do
    case find_open_tag_end(body, lt) do
      {:self, after_self} -> matching_close(body, after_self, tag, depth)
      {:open, after_open} -> matching_close(body, after_open, tag, depth + 1)
    end
  end

  defp starts_with_boundary?(body, lt, prefix) do
    plen = byte_size(prefix)

    binary_part_safe(body, lt, plen) == prefix and
      byte_at(body, lt + plen) in [">", "/", " ", "\t", "\n", "\r", ""]
  end

  defp binary_part_safe(bin, pos, len) when pos >= 0 and pos + len <= byte_size(bin),
    do: binary_part(bin, pos, len)

  defp binary_part_safe(_bin, _pos, _len), do: ""

  # Distinguish a self-closing open from a normal one, returning the byte
  # just past the open tag in either case.
  defp find_open_tag_end(body, lt) do
    open_end = open_tag_end(body, lt)
    if byte_at(body, open_end - 2) == "/", do: {:self, open_end}, else: {:open, open_end}
  end

  defp skip_until_gt(body, pos) do
    case :binary.match(body, ">", scope: {pos, byte_size(body) - pos}) do
      {p, _} -> p + 1
      :nomatch -> byte_size(body)
    end
  end

  # Scan from `<` past attributes to the matching `>` that ends the open
  # tag, respecting quotes and `{...}` expression nesting.
  defp open_tag_end(body, start), do: scan_open(body, start + 1, false, 0)

  defp scan_open(body, pos, false, 0) do
    case byte_at(body, pos) do
      ">" -> pos + 1
      "\"" -> scan_open(body, pos + 1, :double, 0)
      "'" -> scan_open(body, pos + 1, :single, 0)
      "{" -> scan_open(body, pos + 1, false, 1)
      "" -> pos
      _ -> scan_open(body, pos + 1, false, 0)
    end
  end

  defp scan_open(body, pos, false, depth) when depth > 0 do
    case byte_at(body, pos) do
      "{" -> scan_open(body, pos + 1, false, depth + 1)
      "}" -> scan_open(body, pos + 1, false, depth - 1)
      "" -> pos
      _ -> scan_open(body, pos + 1, false, depth)
    end
  end

  defp scan_open(body, pos, quote, depth) do
    case {byte_at(body, pos), quote} do
      {"\"", :double} -> scan_open(body, pos + 1, false, depth)
      {"'", :single} -> scan_open(body, pos + 1, false, depth)
      {"", _} -> pos
      _ -> scan_open(body, pos + 1, quote, depth)
    end
  end

  defp byte_at(bin, pos) when pos >= 0 and pos < byte_size(bin), do: binary_part(bin, pos, 1)
  defp byte_at(_bin, _pos), do: ""

  # --- sigil patch ----------------------------------------------------

  defp sigil_patch(sigil, edits) do
    new_body = Enum.reduce(edits, sigil.body, &splice/2)
    range = Sourceror.get_range(sigil.sigil_node)
    indent = String.duplicate(" ", range.start[:column] - 1)
    Patch.new(%{end: range.end, start: range.start}, render_sigil(new_body, indent), false)
  end

  defp splice({s, e, replacement}, body),
    do: binary_part(body, 0, s) <> replacement <> binary_part(body, e, byte_size(body) - e)

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
