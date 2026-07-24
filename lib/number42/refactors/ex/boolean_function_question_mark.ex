defmodule Number42.Refactors.Ex.BooleanFunctionQuestionMark do
  @moduledoc """
  Appends `?` to a boolean-returning private function and renames every
  call site inside the module.

      defmodule M do
        def go(x) do
          if valid(x), do: :ok, else: :error
        end

        defp valid(x), do: x > 0
      end
      ↓
      defmodule M do
        def go(x) do
          if valid?(x), do: :ok, else: :error
        end

        defp valid?(x), do: x > 0
      end

  The trailing `?` is the Elixir convention for a predicate. Restoring
  it makes call sites read as questions (`if valid?(x)`) and signals the
  return type at a glance.

  ## Scope — deliberately narrow (high-risk rewrite)

  - **`defp` only.** A `def`/`defmacro` rename would silently break
    cross-module callers, which this refactor cannot see.
  - **Every clause must be provably boolean.** A clause is boolean when
    its body is a literal `true`/`false`, a boolean/comparison/membership
    operator, a known boolean kernel guard (`is_*`), a call to a `?`
    predicate, or an `if`/`cond`/`case` whose branches are all boolean.
    If *any* clause fails this test, the whole group is skipped.
  - **The name must read as a predicate.** A boolean body is necessary
    but not sufficient: `parse_boolean`/`compute_type_mismatch` return
    booleans yet `parse_boolean?` is nonsense — they *do*, they don't
    *ask*. A static-embedding model classifies the name as predicate or
    action; on `:unknown` a verb-stem heuristic stands in (an action stem
    like `parse`/`update`/`compute` means "not a predicate"). This stops
    the action-verb false renames a body-only check would wave through.
  - **No side effects before the result.** A predicate computes, it never
    mutates. A clause whose leading (non-tail) statements are anything but
    pure `=` bindings — a `Repo.update!`, a `send`, a `Logger.info` — is an
    action with a boolean side-result; `?` would lie about it, so the
    group is skipped.

  ## Skip conditions

  - **Public def**, **already `?`/`!`-suffixed name**, **non-boolean
    clause**, **action-shaped name**, **side-effecting body**,
    **collision** (`name?` already exists as a def or as a
    `use`-injected macro).
  - **Dynamic dispatch** anywhere in the module
    (`apply(__MODULE__, name, …)` with a non-literal name). Such a call
    could reach the function without a syntactic call site, so the
    rename might leave a dangling reference — skip the whole module.

  ## Idempotence

  After the rewrite the name ends in `?`, which the candidate filter
  rejects, so a second pass changes nothing.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Analysis.AstHelpers
  alias Number42.Refactors.Analysis.HelperNaming
  alias Number42.Refactors.Analysis.Semantic
  alias Sourceror.Patch

  # Operators that *always* yield a boolean. `and`/`or` qualify because
  # the language enforces boolean operands (a non-boolean LHS raises
  # `BadBooleanError`), so the result is always a boolean.
  @comparison_ops ~w(and or == != === !== < > <= >= in)a
  @negation_ops ~w(not !)a

  # `&&`/`||` are short-circuit operators that return an *operand*, not
  # a coerced boolean — `{:ok, v} || :error` yields the tuple. They are
  # boolean only when both operands are themselves boolean, so they are
  # checked recursively rather than treated as always boolean.
  @short_circuit_ops ~w(&& ||)a

  @boolean_guards ~w(
    is_atom is_binary is_bitstring is_boolean is_float is_function
    is_integer is_list is_map is_map_key is_nil is_number is_pid
    is_port is_reference is_tuple is_struct is_exception
  )a

  @use_injected_callables %{
    [:ExUnit, :Case] => ~w(test describe setup setup_all)a,
    [:ExUnit, :CaseTemplate] => ~w(test describe setup setup_all)a
  }

  @impl Number42.Refactors.Refactor
  def description, do: "Append `?` to boolean-returning private functions and their call sites"

  @impl Number42.Refactors.Refactor
  def priority, do: 250

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    The `?` suffix is how Elixir marks a predicate. A boolean-returning
    `defp` named `valid` reads as a noun at the call site (`if valid(x)`)
    when it should read as a question (`if valid?(x)`). Restoring the
    suffix documents the return contract in the name. Restricted to
    private functions with a provably boolean body in every clause, so
    no caller outside the module and no non-predicate function is ever
    touched.
    """
  end

  @impl Number42.Refactors.Refactor
  def transform(source, _opts) do
    Sourceror.parse_string(source) |> apply_patches(source)
  end

  @impl Number42.Refactors.Refactor
  def patches(ast, _source, _opts), do: build_patches(ast)

  defp apply_patches({:ok, ast}, source),
    do: ast |> build_patches() |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp build_patches(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, _} = mod -> module_patches(mod)
      _ -> []
    end)
  end

  defp module_patches({:defmodule, _, [_name, [{_do, body}]]}) do
    exprs = body_to_exprs(body)

    with false <- has_dynamic_self_dispatch?(exprs),
         resolutions when resolutions != %{} <- resolve_renames(exprs) do
      rename_patches(body, resolutions)
    else
      _ -> []
    end
  end

  defp module_patches(_), do: []

  # %{old_atom => new_atom} for every private function whose every
  # clause is boolean and whose `?` target is free.
  defp resolve_renames(exprs) do
    {groups, def_names} = private_groups(exprs)
    occupied = MapSet.union(def_names, use_injected_callables(exprs))

    groups
    |> Enum.flat_map(fn {name, clauses} -> rename_or_skip(name, clauses, occupied) end)
    |> Map.new()
  end

  defp rename_or_skip(name, clauses, occupied) do
    new = :"#{name}?"

    if renamable_name?(name) and predicate_name?(name) and
         all_clauses_boolean?(clauses) and all_clauses_pure?(clauses) and
         not MapSet.member?(occupied, new) do
      [{name, new}]
    else
      []
    end
  end

  # The `?` suffix claims a *predicate* — a name that asks, not one that
  # acts. A boolean body alone isn't enough: `parse_boolean`/`maybe_update_oz`
  # both return booleans but reading `parse_boolean?` is nonsense.
  #
  # Three tiers, most-specific first:
  #
  #   1. The predicate embedding, when it recognises a token in the name.
  #   2. A modal/possessive prefix (`has_`, `can_`, `should_`, `is_`, …).
  #      These are *grammatically* interrogative — `has_role` asks whether
  #      a role is held — and the model's vocabulary does not cover them
  #      (it scores adjectives like `valid`/`enabled`, so `has_role`,
  #      `can_edit`, `needs_review` all come back `:unknown`). Reading the
  #      prefix is structural, not statistical: it holds for any stem,
  #      including domain nouns no embedding table will ever contain.
  #   3. The verb-stem heuristic — an action stem (`parse`/`update`/…)
  #      means "not a predicate", anything else is allowed.
  #
  # Tier 2 exists because tier 3 was deciding the majority of real names
  # by exclusion rather than recognition (#408). It reaches the same verdict
  # for the modal class, but on a stated reason instead of a fallthrough.
  defp predicate_name?(name) do
    case Semantic.classify(Atom.to_string(name), :predicate) do
      {:ok, :predicate, _} -> true
      {:ok, :action, _} -> false
      :unknown -> modal_predicate_name?(name) or not HelperNaming.action_verb?(name)
    end
  end

  # Auxiliary and modal prefixes only — words that cannot head a clause on
  # their own, so whatever follows is necessarily a *claim about* the stem
  # rather than an action performed on it. `has_update_flag` asks whether an
  # update flag is held; it does not update anything.
  #
  # Deliberately excluded: `owns_`, `uses_`, `contains_`, `includes_`,
  # `matches_`, `knows_`, `accepts_`, `supports_`. Those are ordinary
  # transitive verbs, so a compound like `uses_fetch_row` reads as an action
  # and must keep falling through to the verb-stem tier. Only prefixes whose
  # own part of speech forces an interrogative reading belong here.
  #
  # A trailing `_` is required so `is_owner` matches while `island` does not
  # — the prefix must be a whole leading segment, not a substring.
  @modal_prefixes ~w(has_ have_ had_ can_ cannot_ could_ should_ shall_ must_
                     may_ might_ will_ would_ is_ are_ was_ were_ been_
                     needs_ need_ wants_ want_ requires_ require_)

  defp modal_predicate_name?(name) do
    str = Atom.to_string(name)
    Enum.any?(@modal_prefixes, &String.starts_with?(str, &1))
  end

  defp renamable_name?(name) do
    str = Atom.to_string(name)
    not String.ends_with?(str, ["?", "!"])
  end

  # ---------------------------------------------------------------
  # Definition collection
  # ---------------------------------------------------------------

  # {%{name => [clause_node]} for defp, all_def_names_set}.
  defp private_groups(exprs) do
    {priv, names} =
      Enum.reduce(exprs, {[], MapSet.new()}, fn
        {kind, _, [head, _body]} = node, {priv, names}
        when kind in [:def, :defp, :defmacro, :defmacrop] ->
          reduce_def(kind, node, head, priv, names)

        _, acc ->
          acc
      end)

    grouped = Enum.group_by(priv, fn {name, _} -> name end, fn {_, node} -> node end)
    {grouped, names}
  end

  defp reduce_def(kind, node, head, priv, names) do
    case AstHelpers.extract_fn_signature(strip_when(head)) do
      {name, _params} ->
        names = MapSet.put(names, name)
        if kind == :defp, do: {[{name, node} | priv], names}, else: {priv, names}

      :error ->
        {priv, names}
    end
  end

  defp strip_when({:when, _, [head | _]}), do: head
  defp strip_when(head), do: head

  defp use_injected_callables(exprs) do
    exprs
    |> Enum.flat_map(fn
      {:use, _, [{:__aliases__, _, parts} | _]} when is_list(parts) ->
        Map.get(@use_injected_callables, parts, [])

      _ ->
        []
    end)
    |> MapSet.new()
  end

  # ---------------------------------------------------------------
  # Boolean-body detection
  # ---------------------------------------------------------------

  defp all_clauses_boolean?(clauses), do: Enum.all?(clauses, &clause_boolean?/1)

  # A predicate may compute, never mutate. The body's *tail* is the boolean
  # result (already checked); its leading statements, if any, must be pure
  # setup. A `defp` that calls `Repo.update!` before returning a boolean is
  # an action with a boolean side-result — `?` would lie about it. We allow
  # only `=` bindings as non-tail statements; anything else (a bare call, a
  # `send`, a `Logger.info`) is a potential effect, so the group is skipped.
  defp all_clauses_pure?(clauses), do: Enum.all?(clauses, &clause_pure?/1)

  defp clause_pure?({_kind, _, [_head, body_kw]}) when is_list(body_kw) do
    case fetch_block(body_kw, :do) do
      {:ok, {:__block__, _, exprs}} when is_list(exprs) ->
        exprs |> Enum.drop(-1) |> Enum.all?(&pure_binding?/1)

      {:ok, _single} ->
        true

      :error ->
        false
    end
  end

  defp clause_pure?(_), do: false

  # A non-tail statement is pure only if it is a `=` match — `x = expr`.
  # (The bound expression itself could in theory call an effectful function,
  # but binding the result of a pure computation is the overwhelmingly common
  # case, and a leading mutating call is what we actually need to catch.)
  defp pure_binding?({:=, _, [_lhs, _rhs]}), do: true
  defp pure_binding?(_), do: false

  defp clause_boolean?({_kind, _, [_head, body_kw]}) when is_list(body_kw) do
    case fetch_block(body_kw, :do) do
      {:ok, body} -> boolean_expr?(body)
      :error -> false
    end
  end

  defp clause_boolean?(_), do: false

  # Read a block keyword (`:do`/`:else`) from a Sourceror keyword list
  # where keys are wrapped in `{:__block__, _, [key]}`.
  defp fetch_block(kw, key) when is_list(kw) do
    Enum.find_value(kw, :error, fn
      {{:__block__, _, [^key]}, value} -> {:ok, value}
      {^key, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp block_values(kw) when is_list(kw) do
    Enum.flat_map(kw, fn
      {{:__block__, _, [_key]}, value} -> [value]
      {_key, value} -> [value]
    end)
  end

  defp block_values(_), do: []

  defp boolean_expr?({:__block__, _, [literal]}) when is_boolean(literal), do: true

  defp boolean_expr?({:__block__, _, exprs}) when is_list(exprs),
    do: exprs |> List.last() |> boolean_expr?()

  defp boolean_expr?(literal) when is_boolean(literal), do: true

  defp boolean_expr?({op, _, args}) when op in @comparison_ops and is_list(args), do: true
  defp boolean_expr?({op, _, _args}) when op in @negation_ops, do: true

  defp boolean_expr?({op, _, operands}) when op in @short_circuit_ops and is_list(operands),
    do: Enum.all?(operands, &boolean_expr?/1)

  defp boolean_expr?({guard, _, args}) when guard in @boolean_guards and is_list(args), do: true

  # Control flow is boolean when every branch is boolean. Listed before
  # the generic call clause so `if`/`unless`/`cond`/`case` heads aren't
  # mistaken for `?`-predicate calls.
  defp boolean_expr?({:if, _, [_cond, branches]}) when is_list(branches),
    do: branches |> block_values() |> all_boolean?()

  defp boolean_expr?({:unless, _, [_cond, branches]}) when is_list(branches),
    do: branches |> block_values() |> all_boolean?()

  defp boolean_expr?({:cond, _, [body_kw]}) when is_list(body_kw),
    do: body_kw |> fetch_block(:do) |> clauses_bodies_boolean?()

  defp boolean_expr?({:case, _, [_subject, body_kw]}) when is_list(body_kw),
    do: body_kw |> fetch_block(:do) |> clauses_bodies_boolean?()

  # A local/remote call to a `?`-predicate is boolean.
  defp boolean_expr?({{:., _, [_mod, name]}, _, _args}) when is_atom(name),
    do: String.ends_with?(Atom.to_string(name), "?")

  defp boolean_expr?({name, _, args}) when is_atom(name) and is_list(args),
    do: String.ends_with?(Atom.to_string(name), "?")

  defp boolean_expr?(_), do: false

  defp all_boolean?([]), do: false
  defp all_boolean?(exprs), do: Enum.all?(exprs, &boolean_expr?/1)

  defp clauses_bodies_boolean?({:ok, clauses}) when is_list(clauses),
    do: clauses_bodies_boolean?(clauses)

  defp clauses_bodies_boolean?(clauses) when is_list(clauses) and clauses != [] do
    Enum.all?(clauses, fn
      {:->, _, [_lhs, body]} -> boolean_expr?(body)
      _ -> false
    end)
  end

  defp clauses_bodies_boolean?(_), do: false

  # ---------------------------------------------------------------
  # Safety: dynamic dispatch into this module
  # ---------------------------------------------------------------

  # `apply(__MODULE__, name, args)` / `Kernel.apply(...)` with a
  # non-literal function name could call any private function without a
  # syntactic call site — the rename would miss it. Bail on the whole
  # module.
  defp has_dynamic_self_dispatch?(exprs) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.any?(&dynamic_apply?/1)
  end

  defp dynamic_apply?({:apply, _, [mod, fn_name, _args]}),
    do: self_module?(mod) and not literal_atom?(fn_name)

  defp dynamic_apply?(
         {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [mod, fn_name, _args]}
       ),
       do: self_module?(mod) and not literal_atom?(fn_name)

  defp dynamic_apply?(_), do: false

  defp self_module?({:__MODULE__, _, ctx}) when is_atom(ctx), do: true
  defp self_module?(_), do: false

  defp literal_atom?({:__block__, _, [atom]}) when is_atom(atom), do: true
  defp literal_atom?(atom) when is_atom(atom), do: true
  defp literal_atom?(_), do: false

  # ---------------------------------------------------------------
  # Patching — definition heads, call sites, captures, HEEx
  # ---------------------------------------------------------------

  defp rename_patches(body, resolutions) do
    ast_patches(body, resolutions) ++ heex_patches(body, resolutions)
  end

  defp ast_patches(body, resolutions) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(&node_patch(&1, resolutions))
  end

  defp node_patch({:&, _, [{:/, _, [{name, meta, ctx}, _arity]}]}, resolutions)
       when is_atom(name) and is_atom(ctx) do
    name_patch(Map.fetch(resolutions, name), meta, name)
  end

  defp node_patch({name, meta, args}, resolutions) when is_atom(name) and is_list(args) do
    name_patch(Map.fetch(resolutions, name), meta, name)
  end

  defp node_patch(_, _), do: []

  defp name_patch(:error, _meta, _name), do: []

  defp name_patch({:ok, new_atom}, meta, old_atom) do
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)

    if is_integer(line) and is_integer(column) do
      old = Atom.to_string(old_atom)

      range = %{
        start: [line: line, column: column],
        end: [line: line, column: column + String.length(old)]
      }

      [Patch.new(range, Atom.to_string(new_atom))]
    else
      []
    end
  end

  # ~H sigil call sites: `<.old`, `</.old`, `old(`, `&old/`.
  defp heex_patches(body, resolutions) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:sigil_H, meta, [{:<<>>, _, [content]}, _]} = node when is_binary(content) ->
        heex_patch(node, meta, content, patch_heex_content(content, resolutions))

      _ ->
        []
    end)
  end

  defp heex_patch(_node, _meta, content, new_content) when new_content == content, do: []

  defp heex_patch(node, meta, _content, new_content) do
    delim = Keyword.get(meta, :delimiter, "\"")
    prefix = if delim in ["\"\"\"", "'''"], do: "\n", else: ""
    [Patch.new(Sourceror.get_range(node), "~H#{delim}#{prefix}#{new_content}#{delim}")]
  end

  defp patch_heex_content(content, resolutions) do
    Enum.reduce(resolutions, content, fn {old, new}, acc ->
      old_re = old |> Atom.to_string() |> Regex.escape()
      new_str = Atom.to_string(new)

      acc
      |> String.replace(~r/<\.#{old_re}\b/, "<.#{new_str}")
      |> String.replace(~r/<\/\.#{old_re}\b/, "</.#{new_str}")
      |> String.replace(~r/(?<![a-zA-Z0-9_])#{old_re}\(/, "#{new_str}(")
      |> String.replace(~r/&#{old_re}\//, "&#{new_str}/")
    end)
  end
end
