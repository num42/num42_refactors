defmodule Number42.Refactors.Ex.DropRedundantAttrDefaults do
  @moduledoc """
  Drop a call-site attribute whose **literal** value equals the component's
  **declared default** — so `<.button size="md" />` becomes `<.button />` when
  the `button` component declares `attr :size, :string, default: "md"`.

  ## Why

  A call site that re-passes the declared default carries no information: it
  renders identically with or without the attr. Worse, it *pins* the value — if
  the component's default later changes from `"md"` to `"lg"`, every site that
  still passes `size="md"` silently overrides the new default and keeps the old
  look. Removing the redundant attr makes call sites smaller and lets a default
  change actually take effect where the operator intended.

  ## Literal-only, exact, type-aware — the safety constraint

  The rewrite fires **only** for a literal-vs-literal match where both the
  passed value and the declared default are literals of the *same kind* and
  *equal value*. Kinds compared: string, number, boolean, `nil`, atom. A
  string `"3"` does **not** match a number default `3`; `true` does not match
  `"true"`. Equality is on the canonical `{kind, value}` pair, so a
  type-confused match is impossible by construction.

  Anything non-literal is **never touched**: `size={@dynamic}`, `size={fun()}`,
  a list/map/tuple expression — equality to a default cannot be proven, so the
  attr stays. A wrong drop changes rendering; a conservative keep does not.

  ## Resolving the component's declared defaults

  Defaults are read from the component's own module:

    * `<.name …/>` — a **local** call: resolved against this file's own module
      (if it declares `def name(assigns)` with attrs) or a module the file
      `import`s.
    * `<Alias.name …/>` / `<Mod.name …/>` — a **qualified** call: the head is
      resolved to a fully-qualified module via the file's `alias` directives,
      then `name` is looked up there.

  A call whose target component cannot be resolved — unknown tag, no matching
  declaration anywhere in the corpus, an attr the component does not declare,
  or an attr declared **without** a `default:` — is **declined** (the attr is
  kept). Cross-file resolution uses the corpus file list threaded through
  `prepare/1` as `:source_files`.

  ## Enabled by default + idempotence

  `transform/2` runs unattended. The literal-vs-literal, type-aware match
  (string never matches a number, a wrong-typed value never matches) plus the
  decline-on-anything-unresolvable contract (unknown tag, no matching
  declaration, an attr the component does not declare, an attr declared without
  a `default:`, a re-declared/shadowed attr resolved per-component, a
  degenerate byte range) cover the shapes that could otherwise change
  rendering. A full-suite dogfood run on a real Phoenix codebase is green, so
  the conservative opt-in gate was removed.

  The rewrite removes only redundant attrs and never re-adds them, so a second
  pass on its own output changes nothing — idempotent by construction.

  `find_redundant/2` is always available for `--dry-run`/diagnostics.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Heex.Tree

  @type literal ::
          {:string, String.t()}
          | {:number, number()}
          | {:boolean, boolean()}
          | {nil, nil}
          | {:atom, atom()}

  @type defaults :: %{optional(String.t()) => literal()}
  @type module_decls :: %{optional(atom()) => defaults()}
  @type prepared :: %{
          declarations: %{optional(String.t()) => module_decls()},
          source_to_file: %{optional(String.t()) => String.t()},
          file_to_source: %{optional(String.t()) => String.t()}
        }

  @type redundant :: %{
          tag: String.t(),
          attr: String.t(),
          value: literal(),
          sigil_index: non_neg_integer(),
          range: {non_neg_integer(), non_neg_integer()}
        }

  @impl Number42.Refactors.Refactor
  def description,
    do: "Drop a call-site attr whose literal value equals the component's declared default"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A call site that re-passes a component's declared default carries no
    information and pins the value against a later default change. Where a
    call site passes a literal equal to the declared default
    (`<.button size="md" />` against `attr :size, :string, default: "md"`),
    the attr is dropped. The match is literal-vs-literal, exact and
    type-aware — a string never matches a number, a wrong-typed value never
    matches — and any non-literal (`@dynamic`, a call) is left untouched.
    Unresolvable components and attrs without a declared default are declined.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    case Keyword.get(opts, :source_files) do
      files when is_list(files) and files != [] -> {:ok, prepared_for_paths(files)}
      _ -> :no_cache
    end
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    prepared = prepared_for(source, opts)

    case find_redundant(source, prepared) do
      [] -> source
      drops -> rewrite(source, drops)
    end
  end

  @doc """
  Diagnostic: every redundant attr in `source` — `tag`, `attr`, the matched
  literal `value`, and the attr's byte `range` in its sigil body. Read-only.

  `context` is the resolution context: either the `prepared` map from
  `prepare/1` or a freshly built one for `source` alone (single-file mode).
  """
  @spec find_redundant(String.t(), prepared() | nil) :: [redundant()]
  def find_redundant(source, context \\ nil) do
    prepared = context || prepared_for(source, [])
    decls = prepared.declarations
    file_module = module_name(source)
    directives = directives(source)

    case Tree.from_source(source) do
      {:ok, sigils} ->
        sigils
        |> Enum.with_index()
        |> Enum.flat_map(fn {sigil, index} ->
          redundant_in_sigil(sigil, index, decls, file_module, directives)
        end)

      :error ->
        []
    end
  end

  # ---- detection -----------------------------------------------------------

  defp redundant_in_sigil(sigil, index, decls, file_module, directives) do
    sigil.tree
    |> component_elements()
    |> Enum.flat_map(&redundant_attrs(&1, sigil, index, decls, file_module, directives))
  end

  defp component_elements(tree) do
    Tree.walk(tree, [], fn
      {:element, tag, _attrs, _ch, _} = node, acc ->
        if component_tag?(tag), do: [node | acc], else: acc

      _other, acc ->
        acc
    end)
  end

  defp redundant_attrs(
         {:element, tag, attrs, _ch, _} = node,
         sigil,
         index,
         decls,
         file_module,
         directives
       ) do
    case resolve_defaults(tag, decls, file_module, directives) do
      nil ->
        []

      component_defaults ->
        {start, _end} = Tree.node_byte_range(node, sigil.body)
        open_tag = open_tag_slice(sigil.body, start)

        if open_tag_for_tag?(open_tag, tag) do
          spans = attr_spans(open_tag)
          Enum.flat_map(attrs, &redundant_attr(&1, component_defaults, tag, index, spans, start))
        else
          # A degenerate/mismatched byte range (Tree cannot always pin every
          # element in a complex template) would make any attr span point at the
          # wrong bytes. Decline rather than risk deleting unrelated source.
          []
        end
    end
  end

  # The slice at the node's range must actually be this element's open tag —
  # `<tag` followed by a name boundary — or the range is not trustworthy.
  defp open_tag_for_tag?(open_tag, tag) do
    String.starts_with?(open_tag, "<" <> tag) and
      boundary_after?(open_tag, byte_size("<" <> tag))
  end

  defp boundary_after?(open_tag, pos) do
    case binary_part_safe(open_tag, pos, 1) do
      c when c in [" ", "\t", "\n", "\r", "/", ">", ""] -> true
      _ -> false
    end
  end

  defp redundant_attr({name, value}, component_defaults, tag, index, spans, base) do
    with {:ok, default} <- Map.fetch(component_defaults, name),
         {:ok, passed} <- literal_value(value),
         true <- passed == default,
         {:ok, {s, e}} <- Map.fetch(spans, name) do
      [%{tag: tag, attr: name, value: passed, sigil_index: index, range: {base + s, base + e}}]
    else
      _ -> []
    end
  end

  # ---- literal classification (call-site + declared default) ---------------

  # Call-site attr value → canonical literal, or `:error` for non-literals.
  defp literal_value({:string, s}), do: {:ok, {:string, s}}

  defp literal_value({:expr, code}) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> classify(ast)
      _ -> :error
    end
  end

  # Declared `default: <value>` AST node → the same canonical literal.
  defp default_literal(ast), do: classify(ast)

  defp classify(value) when is_binary(value), do: {:ok, {:string, value}}
  defp classify(value) when is_number(value), do: {:ok, {:number, value}}
  defp classify(nil), do: {:ok, {nil, nil}}
  defp classify(value) when is_boolean(value), do: {:ok, {:boolean, value}}
  defp classify(value) when is_atom(value), do: {:ok, {:atom, value}}
  defp classify(_other), do: :error

  # ---- component resolution ------------------------------------------------

  # `<.name>` → this file's module first, then any module the file imports.
  # `<Mod.name>` / `<Alias.name>` → the alias-resolved module.
  defp resolve_defaults("." <> name, decls, file_module, directives) do
    component = String.to_atom(name)

    local_defaults(decls, file_module, component) ||
      imported_defaults(decls, directives.imports, component)
  end

  defp resolve_defaults(tag, decls, _file_module, directives) do
    with [head, name] <- split_qualified(tag),
         module when is_binary(module) <- Map.get(directives.aliases, head, head),
         component <- String.to_atom(name) do
      get_in(decls, [module, component])
    else
      _ -> nil
    end
  end

  defp local_defaults(_decls, nil, _component), do: nil
  defp local_defaults(decls, file_module, component), do: get_in(decls, [file_module, component])

  defp imported_defaults(decls, imports, component) do
    Enum.find_value(imports, fn module -> get_in(decls, [module, component]) end)
  end

  # `"Comp.thing"` → ["Comp", "thing"]; a deeper `"A.B.thing"` → ["A.B", "thing"].
  defp split_qualified(tag) do
    case String.split(tag, ".") do
      parts when length(parts) >= 2 ->
        {head, [name]} = Enum.split(parts, length(parts) - 1)
        [Enum.join(head, "."), name]

      _ ->
        nil
    end
  end

  defp component_tag?("." <> _rest), do: true
  defp component_tag?(tag), do: tag =~ ~r/^[A-Z][\w.]*\.[a-z_]/

  # ---- declared defaults per module (prepare) ------------------------------

  defp prepared_for_paths(paths) do
    sources =
      paths
      |> Enum.flat_map(fn p ->
        case File.read(p) do
          {:ok, src} -> [{p, src}]
          _ -> []
        end
      end)

    %{
      declarations: declarations_from(Enum.map(sources, fn {_p, src} -> src end)),
      source_to_file: Map.new(sources, fn {p, src} -> {src, p} end),
      file_to_source: Map.new(sources, fn {p, src} -> {p, src} end)
    }
  end

  # In-process context: declarations from this source alone plus, when called
  # through the engine, the corpus declarations carried in `opts[:prepared]`.
  defp prepared_for(source, opts) do
    case opts[:prepared] do
      %{declarations: _} = prepared -> prepared
      _ -> %{declarations: declarations_from([source]), source_to_file: %{}, file_to_source: %{}}
    end
  end

  defp declarations_from(sources) do
    sources
    |> Enum.flat_map(&module_declarations/1)
    |> Map.new()
  end

  # `{module_string => %{component => %{attr_name => literal}}}` for every
  # module in `source` that both declares `attr … default:` and defines a
  # matching `def name(assigns)`.
  defp module_declarations(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.flat_map(&module_entry/1)

      _ ->
        []
    end
  end

  defp module_entry({:defmodule, _, [name_ast, [{_do, body}]]}) do
    case module_string(name_ast) do
      nil -> []
      module -> [{module, component_defaults_in(body)}]
    end
  end

  defp module_entry(_), do: []

  # Walk a module body, pairing the run of `attr` declarations that precede a
  # `def name(assigns)` with that component (Phoenix's attach-to-next rule).
  defp component_defaults_in(body) do
    body
    |> body_exprs()
    |> Enum.reduce({%{}, %{}}, &accumulate_component/2)
    |> elem(0)
  end

  defp accumulate_component({:attr, _, args}, {acc, pending}) do
    case attr_default(args) do
      {name, literal} -> {acc, Map.put(pending, name, literal)}
      :none -> {acc, pending}
    end
  end

  defp accumulate_component({def_kind, _, [head | _]}, {acc, pending})
       when def_kind in [:def, :defp] do
    case component_name(head) do
      {:ok, name} when pending != %{} -> {Map.put(acc, name, pending), %{}}
      _ -> {acc, %{}}
    end
  end

  # `slot`, `@doc`, and any other non-`def` node between an `attr` run and its
  # component do NOT reset the pending defaults — only a `def`/`defp` consumes
  # them (Phoenix attaches the accumulated `attr`s to the next function head).
  defp accumulate_component(_other, {acc, pending}), do: {acc, pending}

  # `attr :x, :type, default: <lit>` → `{"x", literal}`; no usable default → :none.
  defp attr_default([name_ast, _type, opts | _]) when is_list(opts) do
    with name when is_atom(name) <- literal_name(name_ast),
         {:ok, default_ast} <- Keyword.fetch(opts, :default),
         {:ok, literal} <- default_literal(default_ast) do
      {Atom.to_string(name), literal}
    else
      _ -> :none
    end
  end

  defp attr_default(_args), do: :none

  defp literal_name(name) when is_atom(name), do: name
  defp literal_name(_), do: nil

  defp component_name({:when, _, [head | _]}), do: component_name(head)

  defp component_name({name, _, [{:assigns, _, ctx}]}) when is_atom(name) and is_atom(ctx),
    do: {:ok, name}

  defp component_name(_), do: :error

  # ---- file context (module name, alias/import directives) -----------------

  defp module_name(source) do
    case Code.string_to_quoted(source) do
      {:ok, {:defmodule, _, [name_ast, _]}} -> module_string(name_ast)
      {:ok, {:__block__, _, exprs}} -> first_module(exprs)
      _ -> nil
    end
  end

  defp first_module(exprs) do
    Enum.find_value(exprs, fn
      {:defmodule, _, [name_ast, _]} -> module_string(name_ast)
      _ -> nil
    end)
  end

  defp module_string({:__aliases__, _, segments}), do: Enum.map_join(segments, ".", &to_string/1)
  defp module_string(_), do: nil

  # `%{aliases: %{"Local" => "Fully.Qualified"}, imports: ["Fully.Qualified", …]}`
  defp directives(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> collect_directives(ast)
      _ -> %{aliases: %{}, imports: []}
    end
  end

  defp collect_directives(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, %{aliases: %{}, imports: []}, fn node, acc ->
        {node, merge_directive(node, acc)}
      end)

    acc
  end

  defp merge_directive({:alias, _, [target | rest]}, acc) do
    case module_string(target) do
      nil -> acc
      module -> put_in(acc.aliases[alias_local(module, rest)], module)
    end
  end

  defp merge_directive({:import, _, [target | _]}, acc) do
    case module_string(target) do
      nil -> acc
      module -> %{acc | imports: [module | acc.imports]}
    end
  end

  defp merge_directive(_node, acc), do: acc

  # `alias Foo.Bar` → "Bar"; `alias Foo.Bar, as: Baz` → "Baz".
  defp alias_local(module, [opts | _]) when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, segments} -> Enum.map_join(segments, ".", &to_string/1)
      _ -> last_segment(module)
    end
  end

  defp alias_local(module, _rest), do: last_segment(module)

  defp last_segment(module), do: module |> String.split(".") |> List.last()

  # ---- open-tag attribute spans --------------------------------------------

  # The element's open tag: `<` through the first top-level `>` / `/>`,
  # quote- and brace-aware so a `>` inside `{...}` or a quoted value is skipped.
  defp open_tag_slice(body, start) do
    len = tag_end(body, start + 1, byte_size(body), :none, 0) - start
    binary_part(body, start, len)
  end

  defp tag_end(_body, pos, limit, _quote_state, _depth) when pos >= limit, do: limit

  defp tag_end(body, pos, limit, quote_state, depth) do
    char = binary_part(body, pos, 1)
    tag_end_step(char, body, pos, limit, quote_state, depth)
  end

  defp tag_end_step(<<?">>, body, pos, limit, :none, depth),
    do: tag_end(body, pos + 1, limit, :double, depth)

  defp tag_end_step(<<?">>, body, pos, limit, :double, depth),
    do: tag_end(body, pos + 1, limit, :none, depth)

  defp tag_end_step(<<?'>>, body, pos, limit, :none, depth),
    do: tag_end(body, pos + 1, limit, :single, depth)

  defp tag_end_step(<<?'>>, body, pos, limit, :single, depth),
    do: tag_end(body, pos + 1, limit, :none, depth)

  defp tag_end_step(<<?{>>, body, pos, limit, :none, depth),
    do: tag_end(body, pos + 1, limit, :none, depth + 1)

  defp tag_end_step(<<?}>>, body, pos, limit, :none, depth) when depth > 0,
    do: tag_end(body, pos + 1, limit, :none, depth - 1)

  defp tag_end_step(<<?/>>, body, pos, limit, :none, 0) do
    case binary_part_safe(body, pos + 1, 1) do
      ">" -> pos + 2
      _ -> tag_end(body, pos + 1, limit, :none, 0)
    end
  end

  defp tag_end_step(<<?>>>, _body, pos, _limit, :none, 0), do: pos + 1

  defp tag_end_step(_char, body, pos, limit, quote_state, depth),
    do: tag_end(body, pos + 1, limit, quote_state, depth)

  # `%{attr_name => {start_byte, end_byte}}` within the open-tag slice — the span
  # from the leading whitespace before the name through the end of the value, so
  # deleting it leaves no dangling separator.
  defp attr_spans(open_tag) do
    open_tag
    |> scan_attrs(byte_size(tag_head(open_tag)), %{})
  end

  # the `<tag` head, after which attributes begin
  defp tag_head(open_tag) do
    case Regex.run(~r/^<[.\w:-]+/, open_tag) do
      [head] -> head
      _ -> "<"
    end
  end

  defp scan_attrs(open_tag, pos, acc) when pos >= byte_size(open_tag), do: acc

  defp scan_attrs(open_tag, pos, acc) do
    limit = byte_size(open_tag)
    ws_start = pos
    pos = skip_ws(open_tag, pos, limit)

    case read_name(open_tag, pos, limit) do
      {"", _next} ->
        acc

      {name, after_name} ->
        case value_end(open_tag, after_name, limit) do
          {:value, value_end} ->
            scan_attrs(open_tag, value_end, Map.put_new(acc, name, {ws_start, value_end}))

          :bare ->
            scan_attrs(open_tag, after_name, Map.put_new(acc, name, {ws_start, after_name}))

          :done ->
            acc
        end
    end
  end

  defp value_end(open_tag, pos, limit) do
    pos = skip_ws(open_tag, pos, limit)

    case binary_part_safe(open_tag, pos, 1) do
      "=" -> typed_value_end(open_tag, skip_ws(open_tag, pos + 1, limit), limit)
      _ -> :bare
    end
  end

  defp typed_value_end(open_tag, pos, limit) do
    case binary_part_safe(open_tag, pos, 1) do
      "\"" -> {:value, after_quote(open_tag, pos + 1, limit, ?")}
      "'" -> {:value, after_quote(open_tag, pos + 1, limit, ?')}
      "{" -> {:value, after_curly(open_tag, pos + 1, limit, 1)}
      "" -> :done
      _ -> {:value, after_unquoted(open_tag, pos, limit)}
    end
  end

  defp after_quote(open_tag, pos, limit, q) when pos < limit do
    case binary_part(open_tag, pos, 1) do
      <<^q>> -> pos + 1
      _ -> after_quote(open_tag, pos + 1, limit, q)
    end
  end

  defp after_quote(_open_tag, pos, _limit, _q), do: pos

  defp after_curly(_open_tag, pos, limit, _depth) when pos >= limit, do: limit

  defp after_curly(open_tag, pos, _limit, 1) when binary_part(open_tag, pos, 1) == "}",
    do: pos + 1

  defp after_curly(open_tag, pos, limit, depth) do
    case binary_part(open_tag, pos, 1) do
      "{" -> after_curly(open_tag, pos + 1, limit, depth + 1)
      "}" -> after_curly(open_tag, pos + 1, limit, depth - 1)
      _ -> after_curly(open_tag, pos + 1, limit, depth)
    end
  end

  defp after_unquoted(open_tag, pos, limit) when pos < limit do
    case binary_part(open_tag, pos, 1) do
      c when c in [" ", "\t", "\n", "\r", ">", "/"] -> pos
      _ -> after_unquoted(open_tag, pos + 1, limit)
    end
  end

  defp after_unquoted(_open_tag, pos, _limit), do: pos

  defp read_name(open_tag, pos, limit), do: read_name(open_tag, pos, limit, pos)

  defp read_name(open_tag, pos, limit, start) when pos < limit do
    case binary_part(open_tag, pos, 1) do
      c when c in [" ", "\t", "\n", "\r", "=", "/", ">"] ->
        {binary_part(open_tag, start, pos - start), pos}

      _ ->
        read_name(open_tag, pos + 1, limit, start)
    end
  end

  defp read_name(open_tag, pos, _limit, start),
    do: {binary_part_safe(open_tag, start, pos - start), pos}

  defp skip_ws(open_tag, pos, limit) when pos < limit do
    case binary_part(open_tag, pos, 1) do
      c when c in [" ", "\t", "\n", "\r"] -> skip_ws(open_tag, pos + 1, limit)
      _ -> pos
    end
  end

  defp skip_ws(_open_tag, pos, _limit), do: pos

  defp binary_part_safe(bin, pos, len) do
    cond do
      pos >= byte_size(bin) -> ""
      pos + len > byte_size(bin) -> binary_part(bin, pos, byte_size(bin) - pos)
      true -> binary_part(bin, pos, len)
    end
  end

  # ---- rewrite -------------------------------------------------------------

  defp rewrite(source, drops) do
    by_sigil = Enum.group_by(drops, & &1.sigil_index)
    sigils = collect_sigils(source)
    ranges = sigil_ranges(source)

    patches =
      sigils
      |> Enum.zip(ranges)
      |> Enum.with_index()
      |> Enum.flat_map(fn {{sigil, range}, index} ->
        sigil_patch(sigil, range, Map.get(by_sigil, index, []))
      end)

    patch_or_passthrough(patches, source)
  end

  defp sigil_patch(_sigil, _range, []), do: []

  defp sigil_patch(sigil, range, drops) do
    new_body =
      drops
      |> Enum.sort_by(fn d -> -elem(d.range, 0) end)
      |> Enum.reduce(sigil.body, fn d, body -> delete_range(body, d.range) end)

    rendered = render_sigil(new_body, range)
    [Sourceror.Patch.new(%{start: range.start, end: range.end}, rendered, false)]
  end

  defp delete_range(body, {s, e}) do
    binary_part(body, 0, s) <> binary_part(body, e, byte_size(body) - e)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  # Reproduce the original sigil's delimiter form: an inline `~H"…"` when it sat
  # on one line and the body carries no `"` (so the `"` delimiter needs no
  # escaping), a heredoc `~H"""…"""` otherwise. Rendering a heredoc for an inline
  # sigil — or an inline `"` form around a body containing `"` — yields
  # uncompilable code, so the heredoc is the safe fallback.
  defp render_sigil(body, range) do
    if inline?(range) and not String.contains?(body, "\""),
      do: "~H\"" <> body <> "\"",
      else: render_heredoc(body, String.duplicate(" ", range.start[:column] - 1))
  end

  defp inline?(range), do: range.start[:line] == range.end[:line]

  defp render_heredoc(body, indent) do
    indented =
      body
      |> String.split("\n", trim: false)
      |> Enum.map_join("\n", fn
        "" -> ""
        line -> indent <> line
      end)

    "~H\"\"\"\n" <> indented <> indent <> "\"\"\""
  end

  defp collect_sigils(source) do
    case Tree.from_source(source) do
      {:ok, sigils} -> sigils
      :error -> []
    end
  end

  defp sigil_ranges(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        {_ast, acc} =
          Macro.prewalk(ast, [], fn
            {:sigil_H, _, _} = node, acc -> {node, [Sourceror.get_range(node) | acc]}
            node, acc -> {node, acc}
          end)

        Enum.reverse(acc)

      _ ->
        []
    end
  end

  # ---- body helpers --------------------------------------------------------

  defp body_exprs({:__block__, _, exprs}), do: exprs
  defp body_exprs(single), do: [single]
end
