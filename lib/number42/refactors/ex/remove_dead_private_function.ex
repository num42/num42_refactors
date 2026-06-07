defmodule Number42.Refactors.Ex.RemoveDeadPrivateFunction do
  @moduledoc """
  Deletes a private function with no call site anywhere in the module.

      # before
      def used, do: helper_a()
      defp helper_a, do: :ok
      defp helper_b, do: :never_called   # dead

      # after
      def used, do: helper_a()
      defp helper_a, do: :ok

  **DESTRUCTIVE.** This removes code; under `--check` / `--dry-run` the
  deletion shows as a removal patch. We err on the side of *keeping*
  code: a function is deleted only when it is provably unreachable.

  ## What "dead" means

  A `defp` is dead when its `{name, arity}` is not reachable from any
  **public `def`** in the module — not by a direct call, not via a
  `&name/arity` capture, not transitively through other reachable
  functions.

  Reachability is computed by `AstHelpers.reachable_defs/2` over the
  module-local call graph (`AstHelpers.collect_definitions/1`). The
  call graph already recognises both capture AST forms and corrects
  pipe arities.

  ## Roots: public `def`s only

  The reachability roots are the module's public `def`s — the external
  contract. Consequently:

  - A `def` is **never** deleted (it may have callers outside the
    corpus). Only `defp` is eligible.
  - A module with **no public `def`** has no known roots, so every
    private would look dead. That is almost always a module reached
    through macros / `use` / behaviour injection rather than a direct
    public entry point, so we **skip** such modules entirely rather
    than delete their privates.

  ## `apply/3` conservatism

  A dynamic `apply` — `apply(__MODULE__, name, args)` with a
  non-literal function name — could reach *any* private. The call
  graph emits a dynamic-dispatch sentinel for it, and
  `reachable_defs/2` then treats **every** definition as reachable, so
  nothing is deleted. We never delete a private when a dynamic dispatch
  is reachable.

  ## Macros & `quote` blocks

  `collect_definitions/1` only walks `def`/`defp` bodies, so calls made
  from a `defmacro`/`defmacrop` are invisible to the base call graph.
  A macro body runs at expansion time and can name any private — both
  the compile-time code *before* the `quote` and the quoted AST — so
  every local call in a macro body is added as a reachability root.
  Qualified self-calls (`__MODULE__.fn(...)` / `ThisModule.fn(...)`, the
  common shape inside `quote`) are also counted as roots. And a `quote`
  block that dispatches through a dynamic `unquote(...)` at the
  call-name position keeps every private in the module — we cannot
  resolve which one it names at expansion time. All are the safe
  direction for a destructive pass.

  ## Sigil templates (HEEx/EEx)

  Sourceror keeps a sigil's content (`~H\"""…\"""`, `~F`, …) as an
  unparsed string literal, so a helper called only from a template —
  `{format_datetime(@x)}` in a HEEx body — is invisible to the call
  graph. We scan every sigil's text for tokens matching a defined
  function name and keep **all** arities of any match (name-only,
  arity-agnostic). Over-keeping here is the safe direction for a
  destructive pass.

  ## Known limit

  Reachability is **module-local**. A private reached only from outside
  the module by name — e.g. registered as a string/atom callback in
  another module (`:telemetry.attach(_, _, &…)`, a `GenServer` handler
  named in config) — is invisible to this analysis. In practice such
  entry points are `def` (public), which is never deleted; but a `defp`
  wired in by an out-of-module dynamic reference is a residual risk.
  This is why the pass is destructive-but-conservative and surfaces its
  removals under `--dry-run`.

  ## What we delete

  When a dead `defp` is found, all of its clauses are removed, and the
  contiguous run of attached attributes (`@doc`, `@spec`, `@impl`,
  `@deprecated`, `@dialyzer`, `@typedoc`, `@since`) immediately above
  the **first** clause goes with it.

  ## Idempotence & determinism

  At most **one** dead `{name, arity}` is removed per pass — the first
  in source order across the file's modules. After removal it is gone,
  so a re-run finds no further reference to it; the engine's fixpoint
  loop picks up any remaining dead functions on later passes (and a
  function that became dead *because* of an earlier removal is caught
  then).

  ## Reachability across macros

  Two dogfood false positives are guarded: a `defp` referenced only from
  inside a `quote do … end` macro body, and a `defp` called from the
  compile-time body of a `defmacro` (before its `quote`). Both count as
  reachable.
  """

  use Number42.Refactors.Refactor

  @attached_attrs ~w(doc spec impl deprecated dialyzer typedoc since)a

  @impl Number42.Refactors.Refactor
  def description, do: "Delete a private function with no call site (incl. captures and apply)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A `defp` that nothing reaches is dead weight: it compiles, it reads
    as if it matters, and it misleads the next person who greps for it.
    Reachability is computed from the module's public `def`s over the
    local call graph, so captures and transitive calls keep a function
    alive; only the genuinely unreachable ones are removed. Conservative
    by design — a dynamic `apply`, a `quote`-block reference, or a
    module with no public entry point all keep every private intact.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts) do
    Sourceror.parse_string(source) |> apply_to_parse_result(source)
  end

  defp apply_to_parse_result({:ok, ast}, source),
    do: ast |> first_module_patches() |> patch_or_passthrough(source)

  defp apply_to_parse_result({:error, _}, source), do: source

  # Delete every dead private in the first module that has any — all of
  # them in one pass. `reachable_defs/2` already gives the full
  # reachable set, so a single pass is sufficient and a re-run is a
  # no-op. We still stop at the first module with deletions so a
  # multi-defmodule file stays deterministic across passes.
  defp first_module_patches(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value([], fn
      {:defmodule, _, [module_name, [{_do, body}]]} ->
        case patches_for_module(body_to_exprs(body), module_name) do
          [] -> nil
          patches -> patches
        end

      _ ->
        nil
    end)
  end

  defp patches_for_module(body_exprs, module_name) do
    definitions = collect_definitions(body_exprs)
    roots = reachability_roots(definitions, body_exprs, module_name)

    cond do
      # No public entry point → reached some other way → keep everything.
      public_def_roots(definitions) == [] ->
        []

      # A dynamic `unquote(...)` at a call-name position inside a quote
      # block could name any private at macro-expansion time; we can't
      # resolve it, so keep every private in the module.
      dynamic_quote_dispatch?(body_exprs) ->
        []

      true ->
        delete_all_dead(definitions, reachable_defs(definitions, MapSet.new(roots)), body_exprs)
    end
  end

  # Roots = public `def`s (external contract), any private named by a
  # qualified self-call `__MODULE__.fn(...)` / `ThisModule.fn(...)`, and
  # every local call made from a `defmacro`/`defmacrop` body.
  #
  # The local call graph (`collect_definitions/1`) only walks `def`/`defp`
  # bodies, so a private reached solely through a qualified self-reference
  # or from inside a macro would otherwise look dead. A macro body runs at
  # expansion time — both the code *before* the `quote` and the quoted code
  # can name a private, so we count the whole body.
  defp reachability_roots(definitions, body_exprs, module_name) do
    public_def_roots(definitions) ++
      self_qualified_uses(body_exprs, module_name) ++
      macro_body_uses(body_exprs) ++
      sigil_referenced_defs(definitions, body_exprs)
  end

  # Local calls made from any `defmacro`/`defmacrop` body, as roots.
  # `collect_calls/1` walks the whole body (pre-`quote` compile-time code
  # and the quoted AST alike), so a private named anywhere in a macro stays
  # alive — the conservative direction for a destructive pass.
  defp macro_body_uses(body_exprs) do
    body_exprs
    |> Enum.flat_map(&macro_clause_calls/1)
  end

  defp macro_clause_calls({kind, _, [_head, body_kw]})
       when kind in [:defmacro, :defmacrop] and is_list(body_kw) do
    body_kw |> Keyword.values() |> Enum.flat_map(&collect_calls/1)
  end

  defp macro_clause_calls(_), do: []

  # Names referenced inside a sigil literal (`~H`, `~F`, … HEEx/EEx
  # templates), as roots. Sourceror keeps sigil content as an unparsed
  # string, so the call graph never sees a `{format_datetime(@x)}` call
  # or a `<.list_items />` component invocation in a template. We scan
  # every sigil's text for *any* identifier token matching a defined
  # function name and keep all arities of every match — name-only,
  # arity-agnostic. Over-keeping a `defp` whose name merely appears as a
  # word in a template is the safe direction for a destructive pass.
  defp sigil_referenced_defs(definitions, body_exprs) do
    tokens = body_exprs |> sigil_text() |> sigil_tokens()

    definitions
    |> Enum.filter(&MapSet.member?(tokens, Atom.to_string(&1.name)))
    |> Enum.map(&{&1.name, &1.arity})
  end

  # Identifier-shaped substrings of the template text. Compared as
  # strings against the (string) definition names — never atomised, so
  # arbitrary template words don't leak into the atom table.
  defp sigil_tokens(text) do
    ~r/[a-z_][a-zA-Z0-9_]*[!?]?/
    |> Regex.scan(text)
    |> List.flatten()
    |> MapSet.new()
  end

  defp sigil_text(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn expr ->
      expr
      |> Macro.prewalker()
      |> Enum.flat_map(&sigil_literal_parts/1)
    end)
    |> Enum.join("\n")
  end

  defp sigil_literal_parts({sigil, _, [{:<<>>, _, parts}, _mods]}) when is_atom(sigil) do
    case Atom.to_string(sigil) do
      "sigil_" <> _ -> Enum.filter(parts, &is_binary/1)
      _ -> []
    end
  end

  defp sigil_literal_parts(_), do: []

  # Public `def`s are the reachability roots — the module's external
  # contract. A module with none is reached some other way; skip it.
  defp public_def_roots(definitions) do
    definitions
    |> Enum.filter(&(&1.kind == :def))
    |> Enum.map(&{&1.name, &1.arity})
  end

  # Collect `{name, arity}` for every `__MODULE__.name(args)` or
  # `<this-module>.name(args)` call in the body — a qualified call onto
  # the module itself is a real use of a local function.
  defp self_qualified_uses(body_exprs, module_name) do
    body_exprs
    |> Enum.flat_map(fn expr ->
      expr
      |> Macro.prewalker()
      |> Enum.flat_map(&self_qualified_call(&1, module_name))
    end)
  end

  defp self_qualified_call({{:., _, [target, fn_name]}, _, args}, module_name)
       when is_atom(fn_name) and is_list(args) do
    if self_target?(target, module_name), do: [{fn_name, length(args)}], else: []
  end

  defp self_qualified_call(_, _), do: []

  defp self_target?({:__MODULE__, _, ctx}, _module_name) when is_atom(ctx), do: true

  defp self_target?({:unquote, _, [{:__MODULE__, _, ctx}]}, _module_name) when is_atom(ctx),
    do: true

  defp self_target?({:__aliases__, _, _} = alias_ast, {:__aliases__, _, _} = module_name) do
    alias_to_module(alias_ast) == alias_to_module(module_name)
  end

  defp self_target?(_, _), do: false

  # A `quote` block whose call-name position is a dynamic `unquote(var)`
  # could expand into a call to any private; we cannot resolve the
  # target statically, so the safe move is to keep every private.
  defp dynamic_quote_dispatch?(body_exprs) do
    body_exprs
    |> Enum.any?(fn expr ->
      expr
      |> Macro.prewalker()
      |> Enum.any?(&quote_with_dynamic_call?/1)
    end)
  end

  defp quote_with_dynamic_call?({:quote, _, args}) when is_list(args) do
    args
    |> Macro.prewalker()
    |> Enum.any?(fn
      # `unquote(expr).fn(...)` where expr is not `__MODULE__`
      {{:., _, [{:unquote, _, [inner]}, _fn]}, _, _} -> not match?({:__MODULE__, _, _}, inner)
      # `unquote(fn_name)(...)` — dynamic local call name
      {{:unquote, _, _}, _, call_args} when is_list(call_args) -> true
      _ -> false
    end)
  end

  defp quote_with_dynamic_call?(_), do: false

  defp delete_all_dead(definitions, reachable, body_exprs) do
    definitions
    |> Enum.filter(&dead_private?(&1, reachable))
    |> Enum.flat_map(&delete_patches(&1, body_exprs))
  end

  defp dead_private?(%{kind: :defp, name: name, arity: arity}, reachable),
    do: not MapSet.member?(reachable, {name, arity})

  defp dead_private?(_, _), do: false

  # Build the delete patches: one zeroing patch spanning the contiguous
  # attached-attribute run plus the clause, for every clause of the
  # dead function. Only the first clause carries the leading attrs.
  defp delete_patches(%{clauses: clauses}, body_exprs) do
    [first | rest] = clauses_in_source_order(clauses)

    [delete_with_leading_attrs(first, body_exprs) | Enum.map(rest, &delete_node/1)]
    |> Enum.reject(&is_nil/1)
  end

  defp clauses_in_source_order(clauses), do: Enum.sort_by(clauses, &line_of/1)

  defp delete_with_leading_attrs(clause_node, body_exprs) do
    idx = Enum.find_index(body_exprs, &(&1 == clause_node))
    first_node = leading_attr_start(body_exprs, idx, clause_node)

    with %{start: start_pos} <- Sourceror.get_range(first_node),
         %{end: end_pos} <- Sourceror.get_range(clause_node) do
      %{change: "", range: %{end: end_pos, start: start_pos}}
    else
      _ -> nil
    end
  end

  defp delete_node(clause_node) do
    case Sourceror.get_range(clause_node) do
      %{} = range -> %{change: "", range: range}
      _ -> nil
    end
  end

  defp leading_attr_start(_body_exprs, nil, clause_node), do: clause_node

  defp leading_attr_start(body_exprs, idx, clause_node) do
    body_exprs
    |> Enum.take(idx)
    |> Enum.reverse()
    |> Enum.take_while(&attached_attr?/1)
    |> List.last()
    |> case do
      nil -> clause_node
      attr -> attr
    end
  end

  defp attached_attr?({:@, _, [{attr, _, _}]}) when is_atom(attr), do: attr in @attached_attrs
  defp attached_attr?(_), do: false

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
