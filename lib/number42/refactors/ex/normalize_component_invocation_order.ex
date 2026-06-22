defmodule Number42.Refactors.Ex.NormalizeComponentInvocationOrder do
  @moduledoc """
  Reorder the attributes at a `<.name …/>` HEEx call site to match the order
  the target component declares its `attr`s.

      <.foo c={@c} a={@a} b={@b} />     # declarations: attr :a / attr :b / attr :c
      <.foo a={@a} b={@b} c={@c} />     # rewritten

  HEEx attribute order is irrelevant to rendering, so this is **purely
  cosmetic** — it aligns call sites with the component's own declared
  vocabulary, which makes a screen of invocations read top-to-bottom like the
  component's `attr` block and surfaces a missing/extra attr at a glance.

  ## Ordering rule

  Within one call-site tag the attributes are partitioned and re-emitted as:

    1. **Structural directives** (`:for`, `:if`, `:let`) — ALWAYS first, in their
       original relative order. They are framework control flow, not data, and
       moving `:for`/`:let` could change what later expressions bind to. They are
       never sorted into the attr order.
    2. **Declared attrs** — sorted by the index of the matching `attr`
       declaration.
    3. **Unknown / extra attrs** (global attrs, `phx-*`, `data-*`, anything not
       declared) — kept in their original relative order, AFTER the declared ones.

  Each attribute is spliced **verbatim** from the source (its exact text,
  quoting and interpolation preserved); only the order changes.

  ## Resolving the declared order

  The declaration order comes from the component's module, discovered across the
  corpus in `prepare/1` (`%{module => %{component_fn => [attr, …]}}`). A call
  site resolves to a component by:

    - `<.name …/>` — a **local** component (a `def name(assigns)` in the same
      module), or a `name/1` brought in by an `import` directive in the file;
    - `<Alias.name …/>` — `name/1` in the module the `Alias` resolves to via the
      file's `alias` directives (or the fully-qualified module itself).

  ## Conservative declines (no rewrite)

  - The tag is a plain HTML element (`<div>`, `<table>`) — not a component.
  - The component cannot be resolved to a declaration in the corpus (unknown
    module, no `attr`s declared, ambiguous import). A reorder we cannot ground in
    a real declaration is a guess, and a wrong reorder on someone else's codebase
    is a defect — so we decline rather than guess.
  - The call site already matches the declared order (no-op).

  ## Idempotence

  Once a call site is ordered, re-running partitions to the same sequence and
  produces no patch. A second pass is a no-op.

  ## Default-OFF

  `transform/2` returns the source unchanged unless the module's opts carry
  `enabled: true`. `prepare/1` always builds the declaration index so
  `--dry-run`/diagnostics see candidates.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Heex.Tree
  alias Sourceror.Patch

  @directives ~w(:for :if :let)

  @type decls :: %{String.t() => %{String.t() => [String.t()]}}

  @impl Number42.Refactors.Refactor
  def description,
    do: "Order call-site attrs to match the component's attr declaration order"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    HEEx attribute order does not affect rendering, so a call site whose attrs
    are in a different order from the component's `attr` declarations is pure
    noise. We reorder the call-site attrs to match the declaration order:
    structural directives (`:for`/`:if`/`:let`) stay first, declared attrs follow
    in declaration order, and unknown/global/`phx-*` attrs keep their relative
    order after the declared ones. The declared order is resolved from the
    component's module (local `def`, or via the file's `import`/`alias`); a call
    site we cannot ground in a real declaration is declined rather than guessed.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def priority, do: 10

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    case Keyword.get(opts, :source_files) do
      files when is_list(files) and files != [] -> {:ok, prepared_for_paths(files)}
      _ -> :no_cache
    end
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    with true <- Keyword.get(opts, :enabled, false),
         %{decls: decls} <- opts[:prepared] do
      rewrite(source, decls)
    else
      _ -> source
    end
  end

  # ---- declaration index (prepare) -----------------------------------------

  @doc """
  Parse `source` into `%{module => %{component_fn => [attr_name, …]}}`,
  recording the declared `attr` order for each function component. `slot`
  declarations are ignored — only `attr`s order a call site. Public for tests.
  """
  @spec declared_attr_order(String.t()) :: decls()
  def declared_attr_order(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> modules_in(ast)
      _ -> %{}
    end
  end

  defp prepared_for_paths(paths) do
    sources =
      paths
      |> Enum.flat_map(fn p ->
        case File.read(p) do
          {:ok, src} -> [{p, src}]
          _ -> []
        end
      end)
      |> Map.new()

    decls =
      sources
      |> Map.values()
      |> Enum.map(&declared_attr_order/1)
      |> Enum.reduce(%{}, &merge_decls/2)

    source_to_file = Map.new(sources, fn {path, src} -> {src, path} end)
    %{decls: decls, source_to_file: source_to_file}
  end

  defp merge_decls(a, b), do: Map.merge(a, b, fn _mod, fa, fb -> Map.merge(fa, fb) end)

  defp modules_in(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case module_name(name_ast) do
          nil -> []
          name -> [{name, components_in(body)}]
        end

      _ ->
        []
    end)
    |> Enum.reject(fn {_name, comps} -> comps == %{} end)
    |> Map.new()
  end

  # Walk the module body top-level expressions in order: accumulate `attr` names
  # until a `def`/`defp` consumes them as that component's declared order.
  defp components_in(body) do
    {comps, _pending} =
      body
      |> body_exprs()
      |> Enum.reduce({%{}, []}, fn expr, {comps, pending} ->
        consume_decl(expr, comps, pending)
      end)

    comps
  end

  defp consume_decl({:attr, _, [name_ast | _]}, comps, pending) do
    case decl_name(name_ast) do
      nil -> {comps, pending}
      name -> {comps, pending ++ [name]}
    end
  end

  defp consume_decl({vis, _, [head | _]}, comps, pending) when vis in [:def, :defp] do
    case def_name(head) do
      nil -> {comps, []}
      fn_name -> {Map.put(comps, fn_name, pending), []}
    end
  end

  # A non-attr, non-def expression (e.g. `slot`, a moduledoc) neither declares
  # an attr nor consumes the pending ones — it just sits between them.
  defp consume_decl(_other, comps, pending), do: {comps, pending}

  defp body_exprs({:__block__, _, exprs}), do: exprs
  defp body_exprs(single), do: [single]

  defp decl_name({:__block__, _, [name]}) when is_atom(name), do: Atom.to_string(name)
  defp decl_name(name) when is_atom(name), do: Atom.to_string(name)
  defp decl_name(_), do: nil

  defp def_name({:when, _, [head | _]}), do: def_name(head)
  defp def_name({name, _, _}) when is_atom(name), do: Atom.to_string(name)
  defp def_name(_), do: nil

  defp module_name({:__aliases__, _, segments}),
    do: segments |> Enum.map_join(".", &Atom.to_string/1)

  defp module_name(_), do: nil

  # ---- rewrite (enabled) ---------------------------------------------------

  defp rewrite(source, decls) do
    resolver = build_resolver(source, decls)

    source
    |> Sourceror.parse_string()
    |> sigils_or_empty()
    |> Enum.flat_map(&sigil_patch(&1, resolver))
    |> patch_or_passthrough(source)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp sigil_patch(%{body: body, tree: tree, sigil_node: node}, resolver) do
    case reorder_sites(tree, body, resolver) do
      [] ->
        []

      sites ->
        new_body = splice_sites(body, sites)
        range = Sourceror.get_range(node)
        indent = String.duplicate(" ", range.start[:column] - 1)
        [Patch.new(%{start: range.start, end: range.end}, render_sigil(new_body, indent), false)]
    end
  end

  # Every component call site whose attrs are not already in declared order,
  # as `{range, reordered_tag_text}` against `body`.
  defp reorder_sites(tree, body, resolver) do
    Tree.walk(tree, [], fn
      {:element, tag, attrs, _ch, _meta} = node, acc ->
        case reorder_tag(tag, attrs, body, node, resolver) do
          nil -> acc
          {range, text} -> [{range, text} | acc]
        end

      _other, acc ->
        acc
    end)
  end

  # Only the OPENING tag is rewritten. An element's byte range spans the whole
  # `<.foo …>children</.foo>`; reordering must touch just the open tag, so we
  # scan from the element start to the open tag's `>`/`/>` and patch that span.
  #
  # `Tree.node_byte_range/2` can hand back a degenerate range for a node it
  # cannot pin (e.g. a component buried in nested `<%= if/for %>` blocks lands
  # at the body end). A node we cannot slice back to its own `<tag` is declined
  # rather than spliced blindly — a wrong splice on real markup is a defect.
  defp reorder_tag(tag, attrs, body, node, resolver) do
    limit = byte_size(body)

    with order when is_list(order) <- resolver.(tag),
         reordered when reordered != attrs <- reorder_attrs(attrs, order),
         {s, _e} = Tree.node_byte_range(node, body),
         true <- s < limit,
         open_end when open_end > s and open_end <= limit <- open_tag_end(body, s + 1),
         original = binary_part(body, s, open_end - s),
         true <- String.starts_with?(original, "<" <> tag) do
      {{s, open_end}, rebuild_tag(original, tag, attrs, reordered)}
    else
      _ -> nil
    end
  end

  # Position just past the open tag's terminating `>` or `/>`, scanning from
  # `pos` (just after the leading `<`). Quote- and `{…}`-aware so a `>` inside
  # an attribute value or interpolation does not end the tag early.
  defp open_tag_end(body, pos), do: open_tag_end(body, pos, :none, 0)

  defp open_tag_end(body, pos, quote, depth),
    do: open_step(char_at(body, pos), body, pos, quote, depth)

  # end of body — return what we have
  defp open_step("", _body, pos, _quote, _depth), do: pos

  # inside a quoted value: only the matching quote closes it
  defp open_step("\"", body, pos, :double, depth), do: open_tag_end(body, pos + 1, :none, depth)
  defp open_step("'", body, pos, :single, depth), do: open_tag_end(body, pos + 1, :none, depth)

  defp open_step(_c, body, pos, q, depth) when q != :none,
    do: open_tag_end(body, pos + 1, q, depth)

  # outside quotes: enter a quote, track `{…}` depth, close on top-level `>`
  defp open_step("\"", body, pos, :none, depth), do: open_tag_end(body, pos + 1, :double, depth)
  defp open_step("'", body, pos, :none, depth), do: open_tag_end(body, pos + 1, :single, depth)
  defp open_step("{", body, pos, :none, depth), do: open_tag_end(body, pos + 1, :none, depth + 1)
  defp open_step(">", _body, pos, :none, 0), do: pos + 1

  defp open_step("}", body, pos, :none, depth) when depth > 0,
    do: open_tag_end(body, pos + 1, :none, depth - 1)

  defp open_step(_c, body, pos, :none, depth), do: open_tag_end(body, pos + 1, :none, depth)

  # directives first (original relative order), then declared attrs by
  # declaration index, then unknown attrs (original relative order).
  defp reorder_attrs(attrs, order) do
    index = order |> Enum.with_index() |> Map.new()

    {directives, rest} = Enum.split_with(attrs, &directive?/1)
    {declared, unknown} = Enum.split_with(rest, fn {name, _} -> Map.has_key?(index, name) end)
    declared = Enum.sort_by(declared, fn {name, _} -> Map.fetch!(index, name) end)

    directives ++ declared ++ unknown
  end

  defp directive?({name, _value}), do: name in @directives

  # Slice each attr's verbatim text out of the original tag, then reassemble
  # in the new order. The attr region is everything after the tag name up to
  # the closing `/>`/`>`; rebuilding from verbatim spans preserves exact
  # quoting, interpolation, and whitespace inside each value.
  defp rebuild_tag(original, tag, attrs, reordered) do
    {prefix, region, suffix} = tag_parts(original, tag)
    spans = attr_spans(region, attrs)
    body = Enum.map_join(reordered, " ", &Map.fetch!(spans, &1))
    pad = if String.starts_with?(suffix, "/"), do: " ", else: ""
    prefix <> " " <> body <> pad <> suffix
  end

  # `<tag ...attrs... />` → {"<tag", " ...attrs... ", "/>"} (or ">"). The space
  # before a self-closing `/>` is re-added by `rebuild_tag`; here we strip it
  # so it does not bleed into the last attr's span.
  defp tag_parts(original, tag) do
    name_len = byte_size("<" <> tag)
    prefix = binary_part(original, 0, name_len)
    rest = binary_part(original, name_len, byte_size(original) - name_len)

    {suffix_len, suffix} =
      cond do
        String.ends_with?(rest, "/>") -> {2, "/>"}
        String.ends_with?(rest, ">") -> {1, ">"}
        true -> {0, ""}
      end

    region = binary_part(rest, 0, byte_size(rest) - suffix_len)
    {prefix, region, suffix}
  end

  # Map each `{name, value}` attr to its verbatim source span within `region`
  # by scanning the region in document order. Scanning (not reconstruction)
  # keeps the original quoting (`a="x"` vs `a={"x"}`) and inner whitespace.
  defp attr_spans(region, attrs) do
    {spans, _rest} =
      Enum.reduce(attrs, {%{}, region}, fn {name, _value} = attr, {spans, remaining} ->
        {span, after_span} = next_attr_span(remaining, name)
        {Map.put(spans, attr, String.trim(span)), after_span}
      end)

    spans
  end

  # From `remaining`, locate `name`, then consume up to (but not including) the
  # start of the next attribute name — so the span carries the name and its
  # value verbatim. The final attr's span runs to the end of the region.
  defp next_attr_span(remaining, name) do
    case :binary.match(remaining, name) do
      {pos, len} ->
        after_name = pos + len
        value_end = scan_attr_value_end(remaining, after_name)
        span = binary_part(remaining, pos, value_end - pos)
        rest = binary_part(remaining, value_end, byte_size(remaining) - value_end)
        {span, rest}

      :nomatch ->
        {name, remaining}
    end
  end

  # Walk from just after the attr name: skip an optional `=value` (quoted
  # string or `{...}` interpolation), then stop at the next non-space.
  defp scan_attr_value_end(region, pos) do
    pos = skip_ws(region, pos)

    case char_at(region, pos) do
      "=" -> region |> skip_ws(pos + 1) |> scan_value(region)
      _ -> pos
    end
  end

  defp scan_value(pos, region) do
    case char_at(region, pos) do
      "\"" -> scan_quoted(region, pos + 1, "\"")
      "'" -> scan_quoted(region, pos + 1, "'")
      "{" -> scan_curly(region, pos + 1, 1)
      _ -> scan_bare(region, pos)
    end
  end

  defp scan_quoted(region, pos, q) do
    case char_at(region, pos) do
      "" -> pos
      ^q -> pos + 1
      _ -> scan_quoted(region, pos + 1, q)
    end
  end

  defp scan_curly(_region, pos, 0), do: pos

  defp scan_curly(region, pos, depth) do
    case char_at(region, pos) do
      "" -> pos
      "{" -> scan_curly(region, pos + 1, depth + 1)
      "}" -> scan_curly(region, pos + 1, depth - 1)
      _ -> scan_curly(region, pos + 1, depth)
    end
  end

  defp scan_bare(region, pos) do
    case char_at(region, pos) do
      "" -> pos
      c when c in [" ", "\t", "\n", "\r"] -> pos
      _ -> scan_bare(region, pos + 1)
    end
  end

  defp skip_ws(region, pos) do
    case char_at(region, pos) do
      c when c in [" ", "\t", "\n", "\r"] -> skip_ws(region, pos + 1)
      _ -> pos
    end
  end

  defp char_at(bin, pos) when pos >= 0 and pos < byte_size(bin), do: binary_part(bin, pos, 1)
  defp char_at(_bin, _pos), do: ""

  # right-to-left splice so earlier byte ranges stay valid
  defp splice_sites(body, sites) do
    sites
    |> Enum.sort_by(fn {{s, _e}, _text} -> -s end)
    |> Enum.reduce(body, fn {{s, e}, text}, acc ->
      binary_part(acc, 0, s) <> text <> binary_part(acc, e, byte_size(acc) - e)
    end)
  end

  # ---- call-site → declared order resolver ---------------------------------

  # `tag -> [attr_name] | nil`. nil means "not a resolvable component" (plain
  # HTML, unknown module, or no declaration found) → decline.
  defp build_resolver(source, decls) do
    self_module = enclosing_module(source)
    aliases = alias_map(source)
    imports = import_modules(source)
    self_fns = Map.get(decls, self_module, %{})

    fn tag -> resolve(tag, decls, self_fns, aliases, imports) end
  end

  # A `<.name/>` is a local `def name` if the enclosing module declares it,
  # otherwise an imported component.
  defp resolve("." <> fn_name, decls, self_fns, _aliases, imports) do
    case Map.fetch(self_fns, fn_name) do
      {:ok, order} -> order
      :error -> imported_order(fn_name, decls, imports)
    end
  end

  defp resolve(<<u, _::binary>> = tag, decls, _self_fns, aliases, _imports) when u in ?A..?Z do
    case String.split(tag, ".") do
      segments when length(segments) >= 2 ->
        {fn_name, mod_segments} = List.pop_at(segments, -1)
        module = expand_module(mod_segments, aliases)
        decls |> Map.get(module, %{}) |> Map.get(fn_name)

      _ ->
        nil
    end
  end

  defp resolve(_tag, _decls, _self_fns, _aliases, _imports), do: nil

  # An imported `<.name/>` resolves only when exactly one imported module
  # declares `name` — otherwise the binding is ambiguous and we decline.
  defp imported_order(fn_name, decls, imports) do
    imports
    |> Enum.flat_map(fn module ->
      case decls |> Map.get(module, %{}) |> Map.get(fn_name) do
        nil -> []
        order -> [order]
      end
    end)
    |> case do
      [order] -> order
      _ -> nil
    end
  end

  defp expand_module(segments, aliases) do
    dotted = Enum.join(segments, ".")
    Map.get(aliases, dotted, dotted)
  end

  defp enclosing_module(source) do
    case Regex.run(~r/^\s*defmodule\s+([A-Z][\w.]*)/m, source) do
      [_, name] -> name
      _ -> nil
    end
  end

  # `alias Foo.Bar` → %{"Bar" => "Foo.Bar"}; `alias Foo.Bar, as: Baz` →
  # %{"Baz" => "Foo.Bar"}. Built from the AST so multi-line aliases survive.
  defp alias_map(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.flat_map(&alias_entry/1)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp alias_entry({:alias, _, [{:__aliases__, _, segs}]}) do
    full = Enum.map_join(segs, ".", &Atom.to_string/1)
    [{Atom.to_string(List.last(segs)), full}]
  end

  defp alias_entry({:alias, _, [{:__aliases__, _, segs}, opts]}) when is_list(opts) do
    full = Enum.map_join(segs, ".", &Atom.to_string/1)

    case Keyword.get(opts, :as) do
      {:__aliases__, _, as_segs} -> [{Atom.to_string(List.last(as_segs)), full}]
      _ -> [{Atom.to_string(List.last(segs)), full}]
    end
  end

  defp alias_entry(_), do: []

  defp import_modules(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.flat_map(fn
          {:import, _, [{:__aliases__, _, segs} | _]} ->
            [Enum.map_join(segs, ".", &Atom.to_string/1)]

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  # ---- sigil collection + rendering ----------------------------------------

  defp sigils_or_empty({:ok, ast}), do: collect_h_sigils(ast)
  defp sigils_or_empty(_), do: []

  defp collect_h_sigils(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&sigil_in_node/1)
    |> Enum.flat_map(&parse_sigil_or_skip/1)
  end

  defp sigil_in_node({:sigil_H, _meta, [{:<<>>, body_meta, [body]}, _mods]} = node)
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
end
