defmodule Number42.Refactors.Heex.AttrType do
  @moduledoc """
  Infer a Phoenix `attr` `:type` for each assign an extracted HEEx
  component reads, from the evidence in the cut subtree itself.

  `ExtractHeexComponentBySeam` lifts a `~H` subtree into a private
  `def name(assigns)` component and declares one `attr :x, <type>` per
  assign the subtree reads. An `:any`-typed attr documents nothing and
  gives the compiler no leverage over callers, so where the markup pins
  an assign's runtime shape we infer a narrower type.

  ## Two evidence sources

  Per the design, evidence comes from two complementary sources:

    1. **Motif / structural role** — how the assign sits in the template's
       structure. The dominant, unambiguous one is *iteration*: an assign
       that is the source of a `:for={x <- @a}` directive, an EEx
       `<%= for x <- @a %>` block, or the first argument of an
       `Enum.*`/`Stream.*` call is a `:list`. (When `StructureMotif`
       lands — #277 — a recognised motif supplies typed attrs/slots for
       its whole API; this module covers the per-assign fallback.)

    2. **Signature / usage** — how the assign is used in expressions: a
       unary `not @a` / `!@a` gate is a `:boolean`; a string-only operation
       (`@a <> _`, `_ <> @a`, `String.fun(@a, ...)`) is a `:string`.

  ## Conservative bias — `:any` over a wrong guess

  A wrong narrow type is worse than `:any`: it mis-documents the component
  and, where a literal is ever passed, breaks compilation. So a type is
  emitted **only when the evidence is unambiguous**, and the rules are
  deliberately narrow:

    * **bare interpolation `{@a}` is never typed** — `to_string/1` accepts
      strings, numbers, atoms and any `String.Chars`, so `{@a}` proves
      nothing about `@a`'s type (measured: ~56% of extracted assigns are
      bare interpolation and stay `:any`);
    * an attribute value `class={@a}` / `id={@a}` is likewise untyped — an
      attribute accepts many shapes;
    * a guard or comparison (`@a == :ok`, `@a > 0`) is **not** used to
      infer `:atom`/`:integer` — the compared literal constrains the
      comparison, not necessarily the assign's declared type;
    * when an assign collects **two conflicting** strong signals (e.g.
      iterated *and* string-concatenated), it falls back to `:any` rather
      than picking one.

  Only `:list`, `:boolean` and `:string` are ever inferred; everything
  else is `:any`. `:integer`/`:float`/`:atom` are intentionally excluded:
  their usage signals (arithmetic, comparison) do not safely separate the
  numeric/atom subtypes, so they would violate the no-false-types rule.
  """

  alias Number42.Refactors.Heex.Tree

  @type t :: :list | :boolean | :string | :any

  @doc """
  Infer the `attr` type of `assign` (a bare assign name, no `@`) from how
  it is used across the cut `nodes` (a `Tree` subtree or node list).

  Returns one of `:list`, `:boolean`, `:string`, or `:any`. `:any` is the
  conservative default whenever the evidence is absent, weak, or
  self-contradictory.
  """
  @spec infer(String.t(), [Tree.node_t()] | Tree.node_t()) :: t()
  def infer(assign, nodes) when is_binary(assign) do
    nodes
    |> signals(assign)
    |> resolve()
  end

  # Collect the set of strong type signals `assign` carries across the
  # subtree. A subtree may legitimately read the same assign in several
  # spots; conflicting signals are resolved (to `:any`) afterwards.
  defp signals(nodes, assign) do
    Tree.walk(nodes, MapSet.new(), fn node, acc ->
      MapSet.union(acc, node_signals(node, assign))
    end)
  end

  # `:for={x <- @a}` directive — `@a` is the iterated collection.
  defp node_signals({:element, _tag, attrs, _children, _meta}, assign) do
    Enum.reduce(attrs, MapSet.new(), fn
      {":for", {:expr, code}}, acc -> add_if(acc, :list, for_source?(code, assign))
      {_name, {:expr, code}}, acc -> MapSet.union(acc, code_signals(code, assign))
      {_name, {:string, _}}, acc -> acc
    end)
  end

  # An EEx `<%= for x <- @a %>` block header iterates `@a`.
  defp node_signals({:eex_block, header, _children, _meta}, assign) do
    add_if(MapSet.new(), :list, for_source?(header, assign))
  end

  defp node_signals({:eex_expr, code, _meta}, assign), do: code_signals(code, assign)
  defp node_signals({:text, _text, _meta}, _assign), do: MapSet.new()

  # ---- expression-level signals --------------------------------------------

  # Parse an interpolation/attribute expression and read the strong signals
  # `@assign` carries inside it. Unparseable code yields no signal.
  defp code_signals(code, assign) when is_binary(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> ast_signals(ast, assign)
      _ -> MapSet.new()
    end
  end

  defp ast_signals(ast, assign) do
    {_ast, acc} =
      Macro.prewalk(ast, MapSet.new(), fn node, acc ->
        {node, MapSet.union(acc, local_signal(node, assign))}
      end)

    acc
  end

  # `not @a` / `!@a` — used purely as a boolean gate.
  defp local_signal({op, _, [arg]}, assign) when op in [:not, :!],
    do: add_if(MapSet.new(), :boolean, assign?(arg, assign))

  # `@a <> _` / `_ <> @a` — string concatenation is string-only.
  defp local_signal({:<>, _, [lhs, rhs]}, assign),
    do: add_if(MapSet.new(), :string, assign?(lhs, assign) or assign?(rhs, assign))

  # `String.fun(@a, ...)` — every `String` function takes a binary first arg.
  defp local_signal({{:., _, [{:__aliases__, _, [:String]}, _fun]}, _, [first | _]}, assign),
    do: add_if(MapSet.new(), :string, assign?(first, assign))

  # `Enum.fun(@a, ...)` / `Stream.fun(@a, ...)` — the first arg is an enumerable.
  defp local_signal({{:., _, [{:__aliases__, _, [mod]}, _fun]}, _, [first | _]}, assign)
       when mod in [:Enum, :Stream],
       do: add_if(MapSet.new(), :list, assign?(first, assign))

  defp local_signal(_node, _assign), do: MapSet.new()

  # ---- iteration source ----------------------------------------------------

  # True when `code` is a comprehension generator whose source is `@assign`,
  # i.e. `x <- @assign` (the `:for` directive body or an EEx `for` header).
  defp for_source?(code, assign) do
    code
    |> strip_for_keyword()
    |> parse_expr()
    |> generator_source_is?(assign)
  end

  defp strip_for_keyword(code) do
    code
    |> String.trim()
    |> String.replace_prefix("for ", "")
    |> String.replace_trailing("do", "")
    |> String.trim()
  end

  defp parse_expr(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> ast
      _ -> nil
    end
  end

  defp generator_source_is?(nil, _assign), do: false

  defp generator_source_is?(ast, assign) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:<-, _, [_lhs, rhs]} = node, _acc -> {node, assign?(rhs, assign)}
        node, acc -> {node, acc}
      end)

    found?
  end

  # ---- helpers -------------------------------------------------------------

  # An `@assign` AST node referencing exactly the name `assign`.
  defp assign?({:@, _, [{name, _, ctx}]}, assign)
       when is_atom(ctx) and is_atom(name),
       do: Atom.to_string(name) == assign

  defp assign?(_other, _assign), do: false

  defp add_if(set, _type, false), do: set
  defp add_if(set, type, true), do: MapSet.put(set, type)

  # A single strong signal types the attr; none or several (conflicting)
  # fall back to `:any` — the conservative bias against a wrong guess.
  defp resolve(signals) do
    case MapSet.to_list(signals) do
      [single] -> single
      _ -> :any
    end
  end
end
