defmodule Number42.Refactors.Heex.Tree do
  @moduledoc """
  Parse `~H` sigils in an Elixir source string into a structural tree
  of HEEx nodes that downstream tooling (normalizer, fingerprint,
  clone detector) can walk.

  ## Why a custom tree

  `Phoenix.LiveView.HTMLTokenizer` is internal API and ties us to a
  specific LiveView version. EEx token streams alone are flat and lose
  the parent/child structure we need for Mass-based hashing. So we
  walk the EEx token stream once and build a small explicit tree:

      Element  — `<tag attrs="...">…</tag>` (and self-closing `<.foo />`)
      EExBlock — `<%= for/if/cond/case … do %>…<% end %>`
      EExExpr  — inline `<%= … %>`
      Text     — literal text between markers (trimmed of pure whitespace)

  Attributes are kept as `{name, value}` pairs where `value` is either
  the literal string or `{:expr, code}` for `attr={code}` and
  `attr="..."` interpolations.

  ## Scope / non-goals

  - We don't validate HEEx syntax; malformed sigils return `:error`.
  - We don't expand component invocations into their referenced
    function bodies. Each `<.foo … />` is one Element node; the caller
    decides whether to compare those nodes structurally.
  - We don't track whitespace beyond preserving non-empty Text nodes.
    Empty/whitespace-only Text between elements is dropped so it
    doesn't influence Mass and hash.
  """

  @type attr_value :: {:string, String.t()} | {:expr, String.t()}

  @type node_t ::
          {:element, String.t(), [{String.t(), attr_value}], [node_t], meta}
          | {:eex_block, String.t(), [node_t], meta}
          | {:eex_expr, String.t(), meta}
          | {:text, String.t(), meta}

  @type meta :: %{line: pos_integer()}

  @type sigil :: %{
          body: String.t(),
          enclosing_fn: atom() | nil,
          file_line: pos_integer(),
          tree: [node_t]
        }

  @doc """
  Collect every `~H` sigil in `source` and parse each one into a tree.

  Returns `{:ok, sigils}` on success. Sigils whose body fails to
  tokenize are silently dropped — partial coverage of a file is more
  useful than an error.
  """
  @spec from_source(String.t()) :: {:ok, [sigil]} | :error
  def from_source(source) when is_binary(source) do
    Sourceror.parse_string(source) |> collect_sigils_or_error()
  end

  @doc """
  Compute the `{start_byte, end_byte}` of `node` within `body`, where
  `body` is the original sigil body string the tree was parsed from.

  For `:element` nodes (open/close pair or self-closing) the range
  spans the leading `<` through the matching `>` (or `/>`). For
  `:eex_expr` it spans `{` through the matching `}`. For `:eex_block`
  it spans the opening `<%=` through the closing `<% end %>`. For
  `:text` it spans the literal characters.
  """
  @spec node_byte_range(node_t(), String.t()) ::
          {non_neg_integer(), non_neg_integer()}
  def node_byte_range(node, body) do
    line = node_line(node)
    line_offset = byte_offset_of_line(body, line)
    start_byte = line_offset + leading_offset_to_marker(node, body, line_offset)
    end_byte = scan_node_end(node, body, start_byte)
    {start_byte, end_byte}
  end

  @doc """
  Parse a HEEx body string into a list of top-level nodes.
  Public for testing without going through the sigil collector.
  """
  @spec parse_body(String.t()) :: {:ok, [node_t]} | :error
  def parse_body(body) when is_binary(body) do
    EEx.tokenize(body, line: 1, column: 1, trim: false, indentation: 0)
    |> parse_tokens_or_error()
  end

  @doc """
  Walk a parsed tree, calling `fun` on every node (pre-order).
  Useful for fingerprinting subtrees.
  """
  @spec walk([node_t] | node_t, term(), (node_t, term() -> term())) :: term()
  def walk(nodes, acc, fun) when is_list(nodes) do
    nodes |> Enum.reduce(acc, &walk(&1, &2, fun))
  end

  def walk({:element, _, _attrs, children, _meta} = node, acc, fun) do
    acc = fun.(node, acc)
    walk(children, acc, fun)
  end

  def walk({:eex_block, _, children, _meta} = node, acc, fun) do
    acc = fun.(node, acc)
    walk(children, acc, fun)
  end

  def walk({:eex_expr, _, _meta} = node, acc, fun), do: fun.(node, acc)
  def walk({:text, _, _meta} = node, acc, fun), do: fun.(node, acc)
  defp attach_tree_or_skip({:ok, tree}, sigil), do: [Map.put(sigil, :tree, tree)]
  defp attach_tree_or_skip(:error, _sigil), do: []

  defp balance_curlies(body, pos, depth),
    do: binary_part_safe(body, pos, 1) |> balance_curlies_step(body, depth, pos)

  defp balance_curlies_step("", _body, _depth, pos), do: pos

  defp balance_curlies_step("{", body, depth, pos),
    do: body |> balance_curlies(pos + 1, depth + 1)

  defp balance_curlies_step("}", _body, depth, pos) when depth == 1 do
    pos + 1
  end

  defp balance_curlies_step("}", body, depth, pos),
    do: body |> balance_curlies(pos + 1, depth - 1)

  defp balance_curlies_step(_, body, depth, pos), do: body |> balance_curlies(pos + 1, depth)

  defp balance_eex_block(body, pos, _depth) do
    # Find the end of the opening `<%= ... do %>` first.
    after_open = find_eex_close(body, pos)
    do_balance_eex(body, after_open, 1)
  end

  defp binary_part_safe(bin, pos, len) do
    cond do
      pos < 0 -> ""
      pos >= byte_size(bin) -> ""
      pos + len > byte_size(bin) -> binary_part(bin, pos, byte_size(bin) - pos)
      true -> binary_part(bin, pos, len)
    end
  end

  defp body_to_exprs({:__block__, _, exprs}), do: exprs
  defp body_to_exprs(single), do: [single]

  defp byte_offset_of_line(body, line) when line >= 1 do
    body
    |> String.split("\n", trim: false)
    |> Enum.take(line - 1)
    |> Enum.reduce(0, fn part, acc -> acc + byte_size(part) + 1 end)
  end

  defp classify_eex_marker(marker) do
    inner =
      marker
      |> String.trim_leading("<%=")
      |> String.trim_leading("<%")
      |> String.trim_trailing("%>")
      |> String.trim()

    cond do
      inner == "end" -> :end
      String.ends_with?(inner, "do") or String.ends_with?(inner, "->") -> :open
      true -> :inline
    end
  end

  defp close_eex_block(acc, stack) do
    case stack do
      [{:eex_block_frame, header, parent_acc, meta} | rest] ->
        node = {:eex_block, header, acc |> Enum.reverse(), %{line: meta.line}}
        {[node | parent_acc], rest}

      [{:opaque_frame} | rest] ->
        {acc, rest}

      _ ->
        # End without matching open — drop.
        {acc, stack}
    end
  end

  defp close_element(name, acc, stack) do
    case stack
         |> Enum.split_while(fn
           {:elem_frame, n, _, _, _} -> n != name
           _ -> true
         end) do
      {_discarded, []} ->
        # No matching open anywhere on the stack: ignore stray close.
        {acc, stack}

      {discarded, [{:elem_frame, open_name, attrs, parent_acc, meta} | rest]} ->
        # Promote any frames between the close target and the running
        # accumulator into nodes of their own so structure isn't lost.
        # Most common cause: HTML fragmented across EEx branches.
        children = acc |> Enum.reverse()

        children =
          discarded
          |> Enum.reverse()
          |> Enum.reduce(children, fn
            {:elem_frame, dn, dattrs, _dparent, dmeta}, kids ->
              [{:element, dn, dattrs, kids, %{line: dmeta.line}}]

            {:eex_block_frame, dheader, _dparent, dmeta}, kids ->
              [{:eex_block, dheader, kids, %{line: dmeta.line}}]

            {:opaque_frame}, kids ->
              kids
          end)

        node = {:element, open_name, attrs, children, %{line: meta.line}}
        {[node | parent_acc], rest}
    end
  end

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

  defp collect_sigils_or_error({:ok, ast}), do: {:ok, collect_h_sigils(ast)}
  defp collect_sigils_or_error({:error, _}), do: :error
  defp count_newlines(bin), do: bin |> :binary.matches("\n") |> length()
  defp do_balance_eex(_body, pos, 0), do: pos

  defp do_balance_eex(body, pos, depth) do
    case :binary.match(body, "<%", scope: {pos, byte_size(body) - pos}) do
      :nomatch ->
        byte_size(body)

      {lt_pos, _} ->
        # Determine if it's an opener (`<%= ... do %>` or `<% ... do %>`),
        # an end (`<% end %>`), a middle (`<% else %>`), or an inline
        # `<%= ... %>`. We handle by inspecting up to the next `%>`.
        close_pos = find_eex_close(body, lt_pos)
        between = binary_part(body, lt_pos, close_pos - lt_pos)
        kind = classify_eex_marker(between)

        case kind do
          :open -> do_balance_eex(body, close_pos, depth + 1)
          :end -> do_balance_eex(body, close_pos, depth - 1)
          _ -> do_balance_eex(body, close_pos, depth)
        end
    end
  end

  defp do_find_tag_end(body, pos, in_quote, depth),
    do: binary_part_safe(body, pos, 1) |> tokenize_char(body, depth, in_quote, pos)

  defp extract_def_name({:when, _, [head | _]}), do: extract_def_name(head)
  defp extract_def_name({name, _, _}) when is_atom(name), do: name
  defp extract_def_name(_), do: nil
  defp find_eex_close(body, from), do: find_eex_close_shared(body, "%>", from, 2)

  defp find_eex_close_shared(body, param_0, pos, param_2) do
    case :binary.match(body, param_0, scope: {pos, byte_size(body) - pos}) do
      {p, _} -> p + param_2
      :nomatch -> byte_size(body)
    end
  end

  defp find_matching_close(body, pos, tag, depth) do
    case :binary.match(body, "<", scope: {pos, byte_size(body) - pos}) do
      :nomatch ->
        byte_size(body)

      {lt_pos, _} ->
        cond do
          starts_with_at?(body, lt_pos, "</" <> tag) and
              tag_close_boundary?(body, lt_pos + byte_size("</" <> tag)) ->
            close_end = skip_until_gt(body, lt_pos)

            if depth == 1,
              do: close_end,
              else: find_matching_close(body, close_end, tag, depth - 1)

          starts_with_at?(body, lt_pos, "<" <> tag) and
              tag_open_boundary?(body, lt_pos + byte_size("<" <> tag)) ->
            case find_tag_end(body, lt_pos + 1) do
              {:self, after_self} ->
                find_matching_close(body, after_self, tag, depth)

              {:open, after_open} ->
                find_matching_close(body, after_open, tag, depth + 1)
            end

          true ->
            find_matching_close(body, lt_pos + 1, tag, depth)
        end
    end
  end

  defp find_offset_from(body, from, marker) do
    case :binary.match(body, marker, scope: {from, byte_size(body) - from}) do
      {pos, _} -> pos - from
      :nomatch -> 0
    end
  end

  defp find_tag_end(body, from), do: body |> do_find_tag_end(from, false, 0)
  defp html_tokens(text, meta), do: scan_html(text, meta.line, [])

  defp leading_offset_to_marker({:element, _, _, _, _}, body, line_offset),
    do: find_offset_from(body, line_offset, "<")

  defp leading_offset_to_marker({:eex_expr, _, _}, body, line_offset),
    do: find_offset_from(body, line_offset, "{")

  defp leading_offset_to_marker({:eex_block, _, _, _}, body, line_offset),
    do: find_offset_from(body, line_offset, "<%")

  defp leading_offset_to_marker({:text, _, _}, _body, _line_offset), do: 0

  defp nest_elements(events) do
    {nodes, _stack} =
      events
      |> Enum.reduce({[], []}, fn
        {:text, "", _}, acc ->
          acc

        {:text, raw, meta}, {acc, stack} ->
          {split_text_with_curlies(raw, meta) ++ acc, stack}

        {:self, name, attrs, meta}, {acc, stack} ->
          {[{:element, name, normalize_attrs(attrs), [], %{line: meta.line}} | acc], stack}

        {:open, name, attrs, meta}, {acc, stack} ->
          {[], [{:elem_frame, name, normalize_attrs(attrs), acc, meta} | stack]}

        {:close, name, _meta}, {acc, stack} ->
          close_element(name, acc, stack)

        {:eex_expr_evt, code, meta}, {acc, stack} ->
          {[{:eex_expr, code, %{line: meta.line}} | acc], stack}

        {:eex_block_open, header, meta}, {acc, stack} ->
          {[], [{:eex_block_frame, header, acc, meta} | stack]}

        {:eex_block_close, _meta}, {acc, stack} ->
          close_eex_block(acc, stack)

        {:eex_opaque_open, _meta}, {acc, stack} ->
          {acc, [{:opaque_frame} | stack]}
      end)

    nodes |> Enum.reverse()
  end

  defp node_line({:element, _, _, _, %{line: l}}), do: l
  defp node_line({:eex_block, _, _, %{line: l}}), do: l
  defp node_line({:eex_expr, _, %{line: l}}), do: l
  defp node_line({:text, _, %{line: l}}), do: l

  defp normalize_attrs(normalized_attrs) do
    normalized_attrs |> Enum.map(fn {name, value} -> {name, value} end)
  end

  defp parse_html_or_error(events) do
    try do
      {:ok, nest_elements(events)}
    rescue
      _ -> :error
    end
  end

  defp parse_sigil_or_skip(%{body: body} = sigil),
    do: parse_body(body) |> attach_tree_or_skip(sigil)

  defp parse_tokens_or_error({:ok, tokens}),
    do: tokens_to_html(tokens) |> parse_html_or_error()

  defp parse_tokens_or_error(_), do: :error

  defp push_text(piece, _line, [{:text, prev, t_meta} | rest]),
    do: [{:text, prev <> piece, t_meta} | rest]

  defp push_text(piece, line, acc), do: [{:text, piece, %{line: line}} | acc]
  defp read_attr_name(bin), do: read_attr_name(bin, [])

  defp read_attr_name(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?-, ?_, ?:, ?., ?@] do
    read_attr_name(rest, [<<c>> | acc])
  end

  defp read_attr_name(rest, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp read_attr_value("\"" <> rest, line), do: read_quoted(rest, ?", [], line)
  defp read_attr_value("'" <> rest, line), do: read_quoted(rest, ?', [], line)
  defp read_attr_value("{" <> rest, line), do: read_curly(rest, 1, [], line)

  defp read_attr_value(bin, line) do
    {raw, rest, line} = read_unquoted(bin, [], line)
    {{:string, raw}, rest, line}
  end

  defp read_attrs(bin, line) do
    {bin, line} = skip_ws_nl(bin, line)
    read_attrs_loop(bin, line, [])
  end

  defp read_attrs_loop("/>" <> rest, line, acc), do: {acc |> Enum.reverse(), true, rest, line}
  defp read_attrs_loop(">" <> rest, line, acc), do: {acc |> Enum.reverse(), false, rest, line}
  defp read_attrs_loop("", line, acc), do: {acc |> Enum.reverse(), false, "", line}

  defp read_attrs_loop(bin, line, acc) do
    {name, after_name} = read_attr_name(bin)

    if name == "" do
      # No more attrs — but no closing > either; bail to caller.
      {acc |> Enum.reverse(), false, bin, line}
    else
      {after_name, line} = skip_ws_nl(after_name, line)

      case after_name do
        "=" <> rest ->
          {rest, line} = skip_ws_nl(rest, line)
          {value, after_value, line} = read_attr_value(rest, line)
          {after_value, line} = skip_ws_nl(after_value, line)
          read_attrs_loop(after_value, line, [{name, value} | acc])

        _ ->
          {after_name, line} = skip_ws_nl(after_name, line)
          read_attrs_loop(after_name, line, [{name, {:string, ""}} | acc])
      end
    end
  end

  defp read_curly("", _depth, acc, line),
    do: {{:expr, IO.iodata_to_binary(acc |> Enum.reverse())}, "", line}

  defp read_curly("}" <> rest, 1, acc, line),
    do: {{:expr, IO.iodata_to_binary(acc |> Enum.reverse())}, rest, line}

  defp read_curly("}" <> rest, depth, acc, line) when depth > 1,
    do: read_curly(rest, depth - 1, ["}" | acc], line)

  defp read_curly("{" <> rest, depth, acc, line),
    do: read_curly(rest, depth + 1, ["{" | acc], line)

  defp read_curly(<<?\n, rest::binary>>, depth, acc, line),
    do: read_curly(rest, depth, ["\n" | acc], line + 1)

  defp read_curly(<<c, rest::binary>>, depth, acc, line),
    do: read_curly(rest, depth, [<<c>> | acc], line)

  defp read_quoted("", _q, acc, line),
    do: {{:string, IO.iodata_to_binary(acc |> Enum.reverse())}, "", line}

  defp read_quoted(<<q, rest::binary>>, q, acc, line),
    do: {{:string, IO.iodata_to_binary(acc |> Enum.reverse())}, rest, line}

  defp read_quoted(<<?\n, rest::binary>>, q, acc, line),
    do: read_quoted(rest, q, ["\n" | acc], line + 1)

  defp read_quoted(<<c, rest::binary>>, q, acc, line),
    do: read_quoted(rest, q, [<<c>> | acc], line)

  defp read_tag_name(bin), do: read_tag_name(bin, [])

  defp read_tag_name(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?-, ?_, ?., ?:, ?/] do
    read_tag_name(rest, [<<c>> | acc])
  end

  defp read_tag_name(rest, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp read_unquoted(<<c, _::binary>> = bin, acc, line)
       when c in [?\s, ?\t, ?\n, ?\r, ?>, ?/] do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), bin, line}
  end

  defp read_unquoted(<<c, rest::binary>>, acc, line),
    do: read_unquoted(rest, [<<c>> | acc], line)

  defp read_unquoted("", acc, line),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), "", line}

  defp scan_curlies(<<>>, _depth, buf, _cur_line, chunk_line, acc) do
    lit = IO.iodata_to_binary(buf |> Enum.reverse())
    [{:lit, lit, chunk_line} | acc] |> Enum.reverse()
  end

  defp scan_curlies("{" <> rest, 0, buf, cur_line, chunk_line, acc) do
    lit = IO.iodata_to_binary(buf |> Enum.reverse())
    scan_curlies(rest, 1, [], cur_line, cur_line, [{:lit, lit, chunk_line} | acc])
  end

  defp scan_curlies("{" <> rest, depth, buf, cur_line, chunk_line, acc),
    do: scan_curlies(rest, depth + 1, ["{" | buf], cur_line, chunk_line, acc)

  defp scan_curlies("}" <> rest, 1, buf, cur_line, chunk_line, acc) do
    code = IO.iodata_to_binary(buf |> Enum.reverse())
    scan_curlies(rest, 0, [], cur_line, cur_line, [{:expr, code, chunk_line} | acc])
  end

  defp scan_curlies("}" <> rest, depth, buf, cur_line, chunk_line, acc) when depth > 1,
    do: scan_curlies(rest, depth - 1, ["}" | buf], cur_line, chunk_line, acc)

  defp scan_curlies(<<?\n, rest::binary>>, depth, buf, cur_line, chunk_line, acc),
    do: scan_curlies(rest, depth, ["\n" | buf], cur_line + 1, chunk_line, acc)

  defp scan_curlies(<<c, rest::binary>>, depth, buf, cur_line, chunk_line, acc),
    do: scan_curlies(rest, depth, [<<c>> | buf], cur_line, chunk_line, acc)

  defp scan_html("", _line, acc), do: acc |> Enum.reverse()

  defp scan_html("<!--" <> rest, line, acc) do
    case :binary.match(rest, "-->") do
      {pos, _} ->
        consumed = binary_part(rest, 0, pos + 3)
        after_comment = binary_part(rest, pos + 3, byte_size(rest) - pos - 3)
        scan_html(after_comment, line + count_newlines(consumed), acc)

      :nomatch ->
        acc |> Enum.reverse()
    end
  end

  defp scan_html("</" <> rest, line, acc) do
    {name, after_tag} = read_tag_name(rest)
    {after_close, line} = skip_until_nl(after_tag, ">", line)
    scan_html(after_close, line, [{:close, name, %{line: line}} | acc])
  end

  defp scan_html("<" <> rest, line, acc) do
    {name, after_tag} = read_tag_name(rest)

    if name == "" do
      scan_html(rest, line, push_text("<", line, acc))
    else
      {attrs, self_close?, after_attrs, line_after} = read_attrs(after_tag, line)

      if self_close? do
        scan_html(after_attrs, line_after, [{:self, name, attrs, %{line: line}} | acc])
      else
        scan_html(after_attrs, line_after, [{:open, name, attrs, %{line: line}} | acc])
      end
    end
  end

  defp scan_html(<<?\n, rest::binary>>, line, acc),
    do: rest |> scan_html(line + 1, push_text("\n", line, acc))

  defp scan_html(<<c, rest::binary>>, line, acc),
    do: rest |> scan_html(line, push_text(<<c>>, line, acc))

  defp scan_node_end({:element, tag, _attrs, _children, _meta}, body, start_byte) do
    # Walk from start_byte: read the open-tag's `>` or `/>`, then
    # balance nested opens of the same tag until we hit the matching
    # close. Component tags (`<.foo`) and HTML tags handled identically.
    after_open =
      find_tag_end(body, start_byte)

    case after_open do
      {:self, end_pos} ->
        end_pos

      {:open, end_pos} ->
        find_matching_close(body, end_pos, tag, 1)
    end
  end

  defp scan_node_end({:eex_expr, _code, _meta}, body, start_byte),
    do:
      body
      # `{...}` — balance curlies starting at depth 1 just past `{`.
      |> balance_curlies(start_byte + 1, 1)

  defp scan_node_end({:eex_block, _header, _children, _meta}, body, start_byte),
    do:
      body
      # Walk forward from `<%=`, count nested `<%[=]?…do …%>` opens vs.
      # `<% end %>` closes, return position just past the matching end.
      |> balance_eex_block(start_byte, 0)

  defp scan_node_end({:text, text, _meta}, _body, start_byte), do: start_byte + byte_size(text)

  defp sigil_in_node(
         {:sigil_H, _meta, [{:<<>>, body_meta, [body]}, _modifiers]},
         enclosing_fn
       )
       when is_binary(body) do
    [
      %{
        body: body,
        enclosing_fn: enclosing_fn,
        file_line: Keyword.get(body_meta, :line, 1)
      }
    ]
  end

  defp sigil_in_node(_, _), do: []

  defp sigils_in_top_expr({def_kind, _, [head | _]} = node)
       when def_kind in [:def, :defp, :defmacro, :defmacrop] do
    fn_name = extract_def_name(head)

    node
    |> Macro.prewalker()
    |> Enum.flat_map(&sigil_in_node(&1, fn_name))
  end

  defp sigils_in_top_expr(node),
    do:
      node
      |> Macro.prewalker()
      |> Enum.flat_map(&sigil_in_node(&1, nil))

  defp skip_until_gt(body, pos), do: find_eex_close_shared(body, ">", pos, 1)
  defp skip_until_nl("", _stop, line), do: {"", line}

  defp skip_until_nl(bin, stop, line) do
    case :binary.match(bin, stop) do
      {pos, len} ->
        consumed = binary_part(bin, 0, pos + len)
        rest = binary_part(bin, pos + len, byte_size(bin) - pos - len)
        {rest, line + count_newlines(consumed)}

      :nomatch ->
        {"", line + count_newlines(bin)}
    end
  end

  defp skip_ws_nl(<<?\n, rest::binary>>, line), do: skip_ws_nl(rest, line + 1)
  defp skip_ws_nl(<<c, rest::binary>>, line) when c in [?\s, ?\t, ?\r], do: skip_ws_nl(rest, line)
  defp skip_ws_nl(bin, line), do: {bin, line}
  defp slash_close_step(">", _body, _depth, _in_quote, pos), do: {:self, pos + 2}

  defp slash_close_step(_, body, depth, in_quote, pos),
    do: body |> do_find_tag_end(pos + 1, in_quote, depth)

  defp split_text_with_curlies(raw, meta) do
    raw
    |> scan_curlies(0, [], meta.line, meta.line, [])
    |> Enum.flat_map(fn
      {:lit, "", _} ->
        []

      {:lit, str, line} ->
        trimmed = String.trim(str)
        if trimmed == "", do: [], else: [{:text, trimmed, %{line: line}}]

      {:expr, code, line} ->
        [{:eex_expr, String.trim(code), %{line: line}}]
    end)
    |> Enum.reverse()
  end

  defp starts_with_at?(body, pos, prefix) do
    plen = byte_size(prefix)
    binary_part_safe(body, pos, plen) == prefix
  end

  defp tag_close_boundary?(body, pos),
    do: binary_part_safe(body, pos, 1) |> tag_close_lookahead?()

  defp tag_close_lookahead?(">"), do: true
  defp tag_close_lookahead?(""), do: false
  defp tag_close_lookahead?(c), do: c in [" ", "\t", "\n", "\r"]

  defp tag_open_boundary?(body, pos),
    do: binary_part_safe(body, pos, 1) |> tag_open_lookahead?()

  defp tag_open_lookahead?(">"), do: true
  defp tag_open_lookahead?("/"), do: true
  defp tag_open_lookahead?(""), do: false
  defp tag_open_lookahead?(c), do: c in [" ", "\t", "\n", "\r"]
  defp tokenize_char("", _body, _depth, _in_quote, pos), do: {:open, pos}

  defp tokenize_char("\"", body, depth, in_quote, pos) when not in_quote do
    do_find_tag_end(body, pos + 1, :double, depth)
  end

  defp tokenize_char("\"", body, depth, in_quote, pos) when in_quote == :double do
    do_find_tag_end(body, pos + 1, false, depth)
  end

  defp tokenize_char("'", body, depth, in_quote, pos) when not in_quote do
    do_find_tag_end(body, pos + 1, :single, depth)
  end

  defp tokenize_char("'", body, depth, in_quote, pos) when in_quote == :single do
    do_find_tag_end(body, pos + 1, false, depth)
  end

  defp tokenize_char("{", body, depth, in_quote, pos) when in_quote == false do
    do_find_tag_end(body, pos + 1, false, depth + 1)
  end

  defp tokenize_char("}", body, depth, in_quote, pos)
       when in_quote == false and depth > 0 do
    do_find_tag_end(body, pos + 1, false, depth - 1)
  end

  defp tokenize_char("/", body, depth, in_quote, pos)
       when in_quote == false and depth == 0 do
    binary_part_safe(body, pos + 1, 1) |> slash_close_step(body, depth, in_quote, pos)
  end

  defp tokenize_char(">", _body, depth, in_quote, pos)
       when in_quote == false and depth == 0 do
    {:open, pos + 1}
  end

  defp tokenize_char(_, body, depth, in_quote, pos),
    do: body |> do_find_tag_end(pos + 1, in_quote, depth)

  defp tokens_to_html(tokens) do
    # Convert each EEx token into one or more uniform stream events and
    # interleave them with HTML tokens scanned out of `:text` chunks.
    # The single combined stream is then fed to one reducer in
    # `nest_elements/1`, so HTML elements that span an EEx block (e.g.
    # `<ul>` opens before `<%= for %>` and closes after `<% end %>`)
    # see one continuous parser stack.
    tokens
    |> Enum.flat_map(fn
      {:text, chars, meta} ->
        html_tokens(to_string(chars), meta)

      {:expr, ~c"=", code, meta} ->
        [{:eex_expr_evt, to_string(code), meta}]

      {:expr, ~c"", _code, _meta} ->
        []

      {:start_expr, ~c"=", code, meta} ->
        [{:eex_block_open, to_string(code), meta}]

      {:start_expr, ~c"", _code, meta} ->
        [{:eex_opaque_open, meta}]

      {:middle_expr, _, _code, _meta} ->
        []

      {:end_expr, _, _code, meta} ->
        [{:eex_block_close, meta}]

      {:eof, _meta} ->
        []

      _ ->
        []
    end)
  end
end
