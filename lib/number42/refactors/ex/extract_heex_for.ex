defmodule Number42.Refactors.Ex.ExtractHeexFor do
  alias Sourceror.Patch

  @moduledoc """
  Extracts the body of every `<%= for x <- coll do %>...<% end %>`
  comprehension found inside a `~H` sigil into its own private
  function-component:

      def render(assigns) do
        ~H\"\"\"
        <ul>
          <%= for house <- @houses do %>
            <li>{house.name}</li>
          <% end %>
        </ul>
        \"\"\"
      end

      ↓

      def render(assigns) do
        ~H\"\"\"
        <ul>
          <%= for house <- @houses do %><.render_house_component house={house} /><% end %>
        </ul>
        \"\"\"
      end

      defp render_house_component(assigns) do
        ~H\"\"\"
        <li>{@house.name}</li>
        \"\"\"
      end

  ## Scope

  We extract only `for` blocks that are safe to lift mechanically:

  - Body has only `:text` and inline `:expr` (`<%= ... %>`) tokens.
    Nested EEx control flow (`<%= if %>`, `<%= for %>`,
    `<% binding = ... %>`) is rejected — local bindings would become
    free vars at the call site, and lifting nested control flow
    needs cross-block coordination we don't attempt.
  - Loop-pattern bindings must not shadow any `@assign` referenced
    in the body — auto-renaming either side is a judgment call we
    leave to the human.
  - The body's content must be more than a single component
    invocation, so a second pass over already-extracted code is a
    no-op (idempotence guard).

  ## Naming

  Generated components are named `<enclosing_fn>_<loop_var>_component`,
  with `loop_var` taken as the first non-underscore name in the
  loop pattern (`for {breadcrumb, _} <- ...` → `breadcrumb`). When
  the sigil isn't inside a `def`/`defp`, or the pattern only binds
  underscore names, the name falls back to `extracted_for_<line>`.

  Collision is **not** auto-resolved: if two extracted blocks would
  produce the same name (e.g. several `for item <- ...` loops in
  one function), the second generated `defp` will collide at
  compile-time. The author renames a loop variable, splits the
  function, or extracts one block manually. Auto-suffixing (`_x`,
  `_x_x`) was tried and produced unreadable names — deferring to
  the human keeps the rest meaningful.

  ## Free vars

  At the call site: each loop-pattern binding referenced in the
  body is forwarded as `name={name}`, each outer `@assign`
  referenced in the body as `name={@name}`.

  Inside the lifted component: those local references become
  `@local`, **but only inside HEEx code regions** (`<%= ... %>` and
  attribute-curly `{...}`). Plain HTML text is preserved verbatim,
  so a CSS class like `dock-fab-item` doesn't get rewritten to
  `dock-fab-@item`.
  """

  use Number42.Refactors.Refactor

  # Don't extract trivial bodies — a single line of HEEx in a `for`
  # is more readable inline than as a separate component. The
  # threshold is body line count (newline-counted), so a one-liner
  # `<li>{x}</li>` is left alone but a multi-line `<article>` block
  # gets lifted.
  @min_body_lines 4

  @impl Number42.Refactors.Refactor
  def description, do: "Extract `<%= for %>` bodies in ~H sigils into private function-components"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Multi-line `for` bodies inside HEEx sigils are templates inside
    templates — they hide a renderable unit (a list item, a card row, a
    breadcrumb) inside an outer render function. Lifting the body into a
    named private component makes that unit explicit, gives it a name
    you can grep for, and lets the LiveView diff engine reason about
    each iteration as its own component. The render function stays
    short and the loop iterations become first-class citizens.
    """
  end

  @doc """
  For diagnostic use: returns a list of
  `%{line, pattern, coll, body, source_line, source_column}` for every
  extractable `<%= for %>` block in the module.

  An "extractable" block is one whose body contains only `:text` and
  inline `:expr` (`<%= ... %>`) tokens — no nested EEx control flow,
  no `<% binding = ... %>` local assignments.
  """
  def find_blocks(source), do: Sourceror.parse_string(source) |> blocks_or_empty()

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp already_extracted?(tokens) do
    body_text =
      tokens
      |> Enum.map(fn
        {:text, chars, _} -> to_string(chars)
        {:expr, ~c"=", chars, _} -> "<%= " <> to_string(chars) <> " %>"
        _ -> ""
      end)
      |> IO.iodata_to_binary()
      |> String.trim()

    Regex.match?(~r/\A<\.\w+(\s[^<>]*)?\/>\z/, body_text)
  end

  defp analyze_free_vars(inner_tokens, pattern_ast) do
    pattern_vars = heex_pattern_var_names(pattern_ast)

    {assigns, locals} =
      inner_tokens
      |> Enum.reduce({MapSet.new(), MapSet.new()}, fn
        {:expr, ~c"=", code, _}, acc ->
          scan_elixir(to_string(code), pattern_vars, acc)

        {:text, chars, _}, acc ->
          chars
          |> to_string()
          |> extract_curly_snippets()
          |> Enum.reduce(acc, &scan_elixir(&1, pattern_vars, &2))

        _, acc ->
          acc
      end)

    {MapSet.to_list(locals) |> Enum.sort(), MapSet.to_list(assigns) |> Enum.sort()}
  end

  # Re-locate the outer `defmodule`'s closing `end` in the rewritten
  defp append_components(rewritten_source, _module_node, blocks_with_names),
    # source: the original `end_line` from `Sourceror.get_range` no
    # longer matches because the sigil-rewrite step shrank the body.
    # Each rewritten module ends with a final `end` on its own line —
    # find that anchor and splice the components above it.
    do:
      find_module_end_line(rewritten_source)
      |> append_at_end_or_passthrough(blocks_with_names, rewritten_source)

  defp assign_unique_names(blocks, existing_names) do
    # Two ways the synthesized component name can collide:
    #   1. against a function that already exists in the module
    #      (`existing_names`) — e.g. someone hand-wrote a
    #      `render_house_component` that this loop would also produce.
    #   2. against another extractable block in the same pass — e.g.
    #      two `for item <- …` loops inside `render/1` would both
    #      synthesize `render_item_component`.
    # In either case, emitting the `defp` would compile-fail with a
    # clause-cannot-match warning. The reviewer can rename a loop var
    # and re-run; here we silently drop the colliding blocks so the
    # rest of the pass still applies cleanly.
    #
    # Naming uses `synth_compound_name/4` so the seam-merge
    # between `<fn>` and `<var>_component` is consistent with other
    # refactors. Resolution uses `resolve_collision/3` in
    # `:skip` mode against the existing-name index — first collision
    # drops the block. Intra-pass dupes are still counted up front
    # because resolve_collision can't see other blocks in this pass.
    existing_index =
      for name <- existing_names do
        {Atom.to_string(name), :exists}
      end
      |> Map.new()

    named =
      blocks
      |> Enum.map(&Map.put(&1, :name, base_name(&1)))

    intra_pass_dupes =
      named
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _} -> name end)
      |> MapSet.new()

    named
    |> Enum.flat_map(fn block ->
      cond do
        MapSet.member?(intra_pass_dupes, block.name) ->
          []

        true ->
          case resolve_collision(Atom.to_string(block.name), existing_index, on_collision: :skip) do
            :skip -> []
            {:ok, _name} -> [block]
          end
      end
    end)
  end

  defp base_name(block) do
    case block.enclosing_fn do
      nil ->
        :"extracted_for_#{block.source_line}"

      fn_name ->
        synth_compound_name(
          "",
          Atom.to_string(fn_name),
          to_string(var_part(block)),
          "component"
        )
        |> String.to_atom()
    end
  end

  defp blocks_in_sigil(%{
         body: body,
         enclosing_fn: enclosing_fn,
         file_line: file_line,
         sigil_node: sigil_node
       }),
       do:
         EEx.tokenize(body, line: 1, column: 1, trim: false, indentation: 0)
         |> for_blocks_in_tokens_or_empty(body, enclosing_fn, file_line, sigil_node)

  defp body_long_enough?(start_meta, end_meta),
    do: end_meta.line - start_meta.line - 1 >= @min_body_lines

  defp build_sigil_patch(%{body: body, sigil_node: sigil_node}, blocks) do
    new_body = rewrite_body(body, blocks)
    range = Sourceror.get_range(sigil_node)
    indent = String.duplicate(" ", range.start[:column] - 1)

    rendered = render_sigil(new_body, indent)
    Patch.new(%{end: range.end, start: range.start}, rendered, false)
  end

  defp check_collisions(locals, assigns) do
    case locals |> Enum.filter(&(&1 in assigns)) do
      [] -> :ok
      _ -> :collision
    end
  end

  defp coll_part({:@, _, [{name, _, ctx}]}) when is_atom(name) and is_atom(ctx),
    do: Atom.to_string(name)

  defp coll_part(_), do: nil
  defp collect_curlies(<<>>, _depth, _buf, acc), do: acc |> Enum.reverse()

  defp collect_curlies(<<"{", rest::binary>>, 0, _buf, acc),
    do: collect_curlies(rest, 1, [], acc)

  defp collect_curlies(<<"{", rest::binary>>, depth, buf, acc),
    do: collect_curlies(rest, depth + 1, ["{" | buf], acc)

  defp collect_curlies(<<"}", rest::binary>>, 1, buf, acc) do
    snippet = buf |> Enum.reverse() |> IO.iodata_to_binary()
    collect_curlies(rest, 0, [], [snippet | acc])
  end

  defp collect_curlies(<<"}", rest::binary>>, depth, buf, acc) when depth > 1,
    do: collect_curlies(rest, depth - 1, ["}" | buf], acc)

  defp collect_curlies(<<_c, rest::binary>>, 0, buf, acc),
    do: collect_curlies(rest, 0, buf, acc)

  defp collect_curlies(<<c, rest::binary>>, depth, buf, acc),
    do: collect_curlies(rest, depth, [<<c>> | buf], acc)

  defp collect_h_sigils(ast) do
    # Walk the module's top-level expressions; for every `def`/`defp`,
    # collect `~H` sigils inside its body and tag them with the
    # enclosing function's name. Sigils outside any def (rare — module
    # attributes, etc.) get `:nil` enclosing — naming falls back to
    # `extracted_for_<line>`.
    case ast do
      {:defmodule, _, [_name, [{_do, body}]]} ->
        body
        |> body_to_exprs()
        |> Enum.flat_map(&sigils_in_top_expr/1)

      _ ->
        []
    end
  end

  defp component_body(block),
    do:
      block.inner_tokens
      |> Enum.map(&render_body_token(&1, block.locals))
      |> IO.iodata_to_binary()
      |> String.trim("\n")

  defp do_rewrite_curlies(<<>>, _locals, _depth, _curly_buf, out),
    do: out |> Enum.reverse() |> IO.iodata_to_binary()

  defp do_rewrite_curlies(<<"{", rest::binary>>, locals, 0, _curly_buf, out),
    do: do_rewrite_curlies(rest, locals, 1, [], ["{" | out])

  defp do_rewrite_curlies(<<"{", rest::binary>>, locals, depth, buf, out),
    do: do_rewrite_curlies(rest, locals, depth + 1, ["{" | buf], out)

  defp do_rewrite_curlies(<<"}", rest::binary>>, locals, 1, buf, out) do
    code = buf |> Enum.reverse() |> IO.iodata_to_binary()
    rewritten = rewrite_locals_in_code(code, locals)
    do_rewrite_curlies(rest, locals, 0, [], ["}", rewritten | out])
  end

  defp do_rewrite_curlies(<<"}", rest::binary>>, locals, depth, buf, out) when depth > 1,
    do: do_rewrite_curlies(rest, locals, depth - 1, ["}" | buf], out)

  defp do_rewrite_curlies(<<c, rest::binary>>, locals, 0, _buf, out),
    do: do_rewrite_curlies(rest, locals, 0, [], [<<c>> | out])

  defp do_rewrite_curlies(<<c, rest::binary>>, locals, depth, buf, out),
    do: do_rewrite_curlies(rest, locals, depth, [<<c>> | buf], out)

  defp element_part({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    string = Atom.to_string(name)

    if String.starts_with?(string, "_") or name in [:when, :=, :|, :"::"],
      do: nil,
      else: string
  end

  defp element_part(other), do: hash_part(other)
  defp extract_curly_snippets(text), do: collect_curlies(text, 0, [], [])
  defp extract_def_name({:when, _, [head | _]}), do: extract_def_name(head)
  defp extract_def_name({name, _, _}) when is_atom(name), do: name
  defp extract_def_name(_), do: nil

  defp extracted_transform(sigil, blocks, name_lookup) do
    # Drop blocks whose name was filtered out by `assign_unique_names`
    # (collision against existing function or another in-pass block).
    # Their sigil region must stay untouched, otherwise we'd emit a
    # `<.foo />` call with no matching `defp foo/1`.
    blocks =
      blocks
      |> Enum.filter(&Map.has_key?(name_lookup, &1.source_line))
      |> Enum.map(&Map.put(&1, :name, Map.fetch!(name_lookup, &1.source_line)))

    build_sigil_patch(sigil, blocks)
  end

  defp extracted_transform_3(sigil) do
    blocks =
      case EEx.tokenize(sigil.body, line: 1, column: 1, trim: false, indentation: 0) do
        {:ok, tokens} ->
          find_for_blocks(
            tokens,
            sigil.body,
            sigil.sigil_node,
            sigil.file_line,
            sigil.enclosing_fn
          )

        _ ->
          []
      end

    {sigil, blocks}
  end

  defp find_for_blocks(tokens, body, sigil_node, file_line_offset, enclosing_fn) do
    indexed = tokens |> Enum.with_index()

    indexed
    |> Enum.flat_map(fn
      {{:start_expr, ~c"=", code, meta}, idx} ->
        case parse_for_header(to_string(code)) do
          {:ok, pattern_ast, coll_ast} ->
            case find_matching_end(tokens, idx) do
              {:ok, end_idx} ->
                inner = tokens |> Enum.slice((idx + 1)..(end_idx - 1)//1)

                start_meta = meta
                {:end_expr, _, end_code, end_meta} = tokens |> Enum.at(end_idx)

                with true <- simple_body?(inner),
                     true <- body_long_enough?(start_meta, end_meta),
                     {locals, assigns} <- analyze_free_vars(inner, pattern_ast),
                     :ok <- check_collisions(locals, assigns) do
                  [
                    %{
                      assigns: assigns,
                      body: body,
                      body_preview: preview(body, idx, end_idx, tokens),
                      coll: coll_ast,
                      enclosing_fn: enclosing_fn,
                      end_code_len: length(end_code),
                      end_column: end_meta.column,
                      end_line: end_meta.line,
                      inner_tokens: inner,
                      locals: locals,
                      pattern: pattern_ast,
                      sigil_node: sigil_node,
                      source_line: file_line_offset + start_meta.line - 1,
                      start_column: start_meta.column,
                      start_line: start_meta.line
                    }
                  ]
                else
                  _ -> []
                end

              :error ->
                []
            end

          :error ->
            []
        end

      _ ->
        []
    end)
  end

  defp find_matching_end(tokens, start_idx) do
    tokens
    |> Enum.drop(start_idx + 1)
    |> Enum.with_index(start_idx + 1)
    |> Enum.reduce_while(1, fn
      {{:start_expr, _, _, _}, _}, depth -> {:cont, depth + 1}
      {{:end_expr, _, _, _}, idx}, 1 -> {:halt, {:ok, idx}}
      {{:end_expr, _, _, _}, _}, depth -> {:cont, depth - 1}
      {_, _}, depth -> {:cont, depth}
    end)
    |> case do
      {:ok, idx} -> {:ok, idx}
      _ -> :error
    end
  end

  defp find_module(ast) do
    case ast do
      {:defmodule, _meta, [_name, [{_do, body}]]} = node ->
        exprs =
          case body do
            {:__block__, _, e} -> e
            single -> [single]
          end

        names =
          exprs
          |> Enum.flat_map(fn
            {def_kind, _, [head | _]} when def_kind?(def_kind) ->
              case extract_def_name(head) do
                nil -> []
                name -> [name]
              end

            _ ->
              []
          end)
          |> MapSet.new()

        {node, names}

      _ ->
        nil
    end
  end

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

  defp hash_part(ast) do
    stripped = strip_meta(ast)
    "phash_#{:erlang.phash2(stripped) |> Integer.to_string(16) |> String.downcase()}"
  end

  defp indent_lines(text, indent) do
    text
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> indent <> line
    end)
  end

  defp inner_end_offset(body, block) do
    line_offset = line_to_byte_offset(body, block.end_line)
    line_offset + block.end_column - 1
  end

  defp inner_start_offset(body, block) do
    # `<%=` (3 chars) + code chars + ` %>` (3 chars) — but EEx token
    # `start_expr` `column` already points at the `<%=`, and `code` is
    # the unescaped Elixir between markers. Actual byte length is just
    # the source span from `<%=` through `%>` — easier to compute by
    # locating `%>` after `start_column`.
    line_offset = line_to_byte_offset(body, block.start_line)
    col_offset = block.start_column - 1
    search_from = line_offset + col_offset

    case :binary.match(body, "%>", scope: {search_from, byte_size(body) - search_from}) do
      {pos, _} -> pos + 2
      :nomatch -> search_from
    end
  end

  defp insert_before_line(source, line, insert_text) do
    lines = String.split(source, "\n", trim: false)
    {head, tail} = lines |> Enum.split(line - 1)
    (head ++ [insert_text | tail]) |> Enum.join("\n")
  end

  defp line_to_byte_offset(body, line) when line >= 1 do
    body
    |> String.split("\n", trim: false)
    |> Enum.take(line - 1)
    |> Enum.reduce(0, fn part, acc -> acc + byte_size(part) + 1 end)
  end

  defp parse_for_header(code) do
    code = code |> String.trim() |> String.trim_trailing("do") |> String.trim()

    case code do
      "for " <> rest ->
        wrapped = "for " <> rest <> " do :ok end"

        case Code.string_to_quoted(wrapped) do
          {:ok, {:for, _, args}} ->
            generators =
              args
              |> Enum.filter(fn
                {:<-, _, _} -> true
                _ -> false
              end)

            case generators do
              [{:<-, _, [pattern, coll]}] -> {:ok, pattern, coll}
              _ -> :error
            end

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp heex_pattern_var_names(pattern_ast) do
    pattern_ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
        string = Atom.to_string(name)

        if String.starts_with?(string, "_") or name in [:when, :=, :|, :"::"],
          do: [],
          else: [name]

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp preview(_body, start_idx, end_idx, tokens) do
    tokens
    |> Enum.slice((start_idx + 1)..(end_idx - 1)//1)
    |> Enum.map(fn
      {:text, chars, _} -> to_string(chars)
      {:expr, ~c"=", chars, _} -> "<%= " <> to_string(chars) <> " %>"
      _ -> ""
    end)
    |> IO.iodata_to_binary()
  end

  defp render_body_token({:text, chars, _}, locals),
    do:
      chars
      |> to_string()
      |> rewrite_curlies_in_text(locals)

  defp render_body_token({:expr, ~c"=", chars, _}, locals) do
    code = chars |> to_string() |> rewrite_locals_in_code(locals)
    "<%= " <> code <> " %>"
  end

  defp render_body_token(_, _), do: ""

  defp render_component(block) do
    body = component_body(block)

    """

      defp #{block.name}(assigns) do
        ~H\"\"\"
    #{indent_lines(body, "    ")}
        \"\"\"
      end
    """
  end

  defp render_invocation(block) do
    name = block.name

    local_attrs = block.locals |> Enum.map(&"#{&1}={#{&1}}")
    assign_attrs = block.assigns |> Enum.map(&"#{&1}={@#{&1}}")

    case local_attrs ++ assign_attrs do
      [] -> "<.#{name} />"
      attrs -> "<.#{name} " <> Enum.join(attrs, " ") <> " />"
    end
  end

  defp render_sigil(new_body, indent) do
    lines = String.split(new_body, "\n", trim: false)

    indented_body =
      lines
      |> Enum.map_join("\n", fn
        "" -> ""
        line -> indent <> line
      end)

    "~H\"\"\"\n" <> indented_body <> indent <> "\"\"\""
  end

  defp render_tuple_elements(elements) do
    rendered =
      elements
      |> Enum.map(&element_part/1)
      |> Enum.reject(&is_nil/1)

    case rendered do
      [] -> nil
      parts -> parts |> Enum.join("_")
    end
  end

  defp rewrite_body(body, blocks) do
    blocks_sorted = blocks |> Enum.sort_by(& &1.start_line)

    {chunks, cursor} =
      blocks_sorted
      |> Enum.reduce({[], 0}, fn block, {acc, cursor} ->
        inner_start = inner_start_offset(body, block)
        inner_end = inner_end_offset(body, block)

        before_chunk = binary_part(body, cursor, inner_start - cursor)
        invocation = render_invocation(block)

        {[invocation, before_chunk | acc], inner_end}
      end)

    tail = binary_part(body, cursor, byte_size(body) - cursor)
    [tail | chunks] |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp rewrite_curlies_in_text(text, locals), do: text |> do_rewrite_curlies(locals, 0, [], [])

  defp rewrite_locals_in_code(code, locals) do
    locals
    |> Enum.reduce(code, fn name, acc ->
      pattern = ~r/(?<![@\w])#{Regex.escape(Atom.to_string(name))}(?!\w)/
      Regex.replace(pattern, acc, "@#{name}")
    end)
  end

  defp scan_elixir(code, pattern_vars, {assigns, locals}),
    do:
      Code.string_to_quoted(code)
      |> assign_local_scan_or_keep(assigns, locals, pattern_vars)

  defp sigil_in_node(
         {:sigil_H, _meta, [{:<<>>, body_meta, [body]}, _modifiers]} = node,
         enclosing_fn
       )
       when is_binary(body) do
    [
      %{
        body: body,
        enclosing_fn: enclosing_fn,
        file_column: Keyword.get(body_meta, :column, 1),
        file_line: Keyword.get(body_meta, :line, 1),
        sigil_node: node
      }
    ]
  end

  defp sigil_in_node(_, _), do: []

  defp sigils_in_top_expr({def_kind, _, [head | _]} = node) when def_kind?(def_kind) do
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

  defp simple_body?(tokens) do
    Enum.all?(tokens, fn
      {:text, _, _} -> true
      {:expr, ~c"=", _, _} -> true
      _ -> false
    end) and not already_extracted?(tokens)
  end

  defp single_var_part({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    string = Atom.to_string(name)

    if String.starts_with?(string, "_") or name in [:when, :=, :|, :"::"],
      do: nil,
      else: string
  end

  defp single_var_part(_), do: nil

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp tuple_part({:{}, _, elements}) when is_list(elements), do: render_tuple_elements(elements)
  defp tuple_part({a, b}), do: render_tuple_elements([a, b])
  defp tuple_part(_), do: nil

  defp var_part(block) do
    cond do
      part = tuple_part(block.pattern) -> part
      part = single_var_part(block.pattern) -> part
      part = coll_part(block.coll) -> part
      true -> hash_part(block.pattern)
    end
  end

  defp blocks_or_empty({:ok, ast}),
    do:
      ast
      |> collect_h_sigils()
      |> Enum.flat_map(&blocks_in_sigil/1)

  defp blocks_or_empty({:error, _}), do: []

  defp apply_patches({:ok, ast}, source),
    do: find_module(ast) |> apply_sigil_patches_or_skip(ast, source)

  defp apply_patches({:error, _}, source), do: source

  defp append_at_end_or_passthrough(nil, _blocks_with_names, rewritten_source),
    do: rewritten_source

  defp append_at_end_or_passthrough(
         end_line,
         blocks_with_names,
         rewritten_source
       ) do
    components =
      blocks_with_names |> Enum.map_join("\n", &render_component/1)

    insert_before_line(rewritten_source, end_line, components)
  end

  defp for_blocks_in_tokens_or_empty({:ok, tokens}, body, enclosing_fn, file_line, sigil_node),
    do: tokens |> find_for_blocks(body, sigil_node, file_line, enclosing_fn)

  defp for_blocks_in_tokens_or_empty(_, _body, _enclosing_fn, _file_line, _sigil_node), do: []

  defp assign_local_scan_or_keep({:ok, ast}, assigns, locals, pattern_vars) do
    Macro.prewalk(ast, {assigns, locals}, fn node, {a, l} ->
      case node do
        {:@, _, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) ->
          {node, {MapSet.put(a, name), l}}

        {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
          cond do
            String.starts_with?(Atom.to_string(name), "_") -> {node, {a, l}}
            MapSet.member?(pattern_vars, name) -> {node, {a, MapSet.put(l, name)}}
            true -> {node, {a, l}}
          end

        _ ->
          {node, {a, l}}
      end
    end)
    |> elem(1)
  end

  defp assign_local_scan_or_keep(_, assigns, locals, _pattern_vars), do: {assigns, locals}

  defp apply_sigil_patches_or_skip(nil, _ast, source), do: source

  defp apply_sigil_patches_or_skip(
         {module_node, existing_names},
         ast,
         source
       ) do
    sigils = collect_h_sigils(ast)

    sigils_with_blocks =
      sigils
      |> Enum.map(&extracted_transform_3(&1))
      |> Enum.reject(fn {_, blocks} -> blocks == [] end)

    all_blocks = sigils_with_blocks |> Enum.flat_map(fn {_, b} -> b end)
    blocks_with_names = assign_unique_names(all_blocks, existing_names)
    name_lookup = Map.new(blocks_with_names, &{&1.source_line, &1.name})

    # Drop sigils whose remaining blocks were all filtered out by
    # collision detection — there's nothing to rewrite for them, and
    # passing an empty block list to `build_sigil_patch` would still
    # emit a (no-op) patch and trigger formatting churn.
    sigils_with_blocks =
      sigils_with_blocks
      |> Enum.reject(fn {_sigil, blocks} ->
        blocks |> Enum.all?(&(not Map.has_key?(name_lookup, &1.source_line)))
      end)

    case sigils_with_blocks do
      [] ->
        source

      _ ->
        patches =
          sigils_with_blocks
          |> Enum.map(fn {sigil, blocks} ->
            extracted_transform(sigil, blocks, name_lookup)
          end)

        source
        |> Sourceror.patch_string(patches)
        |> append_components(module_node, blocks_with_names)
    end
  end
end
