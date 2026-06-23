defmodule Number42.Refactors.LiteralNaming do
  @moduledoc """
  Shared naming machinery for the literal-hoisting refactors
  (`ExtractMagicNumber`, `ExtractStringLiteral`).

  Both refactors lift a repeated literal into a `@module_attribute` and
  face the identical naming problem: derive a name that documents the
  value's *meaning*, not its content. This module owns the parts of that
  problem that are independent of whether the literal is a number or a
  string:

    * **keyword-key enrichment** — a `key: value` literal is named by its
      key, enriched with the call's first literal param and the call's
      noun (`validate_length(:email, max: 160)` → `email_max_length`),
      with the enclosing function borrowed as the subject for a thin
      wrapper around a like-named call (`def show, do: JS.show(time:
      300)` → `show_time`);
    * **call-context names** — a positional literal is named by the call
      that takes it (`String.slice(x, 0, 200)` → context `slice`);
    * **clause-head names** — a literal that *is* a guard-free clause
      body is named by the function plus its discriminating pattern
      (`def image_width("md"), do: …` → `{image_width, md}`), with `nil`
      and `_` patterns named `nil`/`default`;
    * **ambiguity detection** — a value whose occurrences carry two
      distinct keys is a coincidental clash, not one constant;
    * **stem sanitizing** — every produced token is folded to a valid
      attribute stem.

  The caller stays in control of the *literal predicate* (number vs.
  string) and of the final name policy (numbers drop value-only
  fallbacks; strings slugify their content). This module only assembles
  the `%{key:, context:, clause:}` opts that feed
  `IdentifierExpansion.derive_constant_name/2`, plus the hit tagging and
  ambiguity verdict.

  ## Hit shape

  Every hit the refactor builds and feeds back here is

      %{
        node:    Macro.t(),           # the {:__block__, meta, [value]} literal node
        value:   number() | binary(), # grouping key + name source
        key:     String.t() | nil,    # enriched name string from keyword_value_keys/2
        context: String.t() | nil,    # call name from call_contexts/2
        clause:  {String.t(), term()} | nil  # {fun, pattern} from clause_contexts/2
      }
  """

  alias Number42.Refactors.IdentifierExpansion

  @type literal_pred :: (term() -> boolean())

  @block_keywords ~w(do else after catch rescue)a
  @call_verbs ~w(validate put set cast get fetch assign update build make)
  @directive_calls [:import, :alias, :require, :use, :attr, :slot]

  # --- context maps --------------------------------------------------

  @doc """
  Map each literal value-node to the enriched name derived from the
  keyword key it sat under: `key`, plus the call's first literal param
  and the call's noun, deduped and ordered `param_key_noun`. A bare
  keyword arg with no enriching call keeps just its key. Block keywords
  (`do:`/`else:`/…) are structural and excluded.
  """
  @spec keyword_value_keys([Macro.t()], literal_pred) :: %{Macro.t() => String.t()}
  def keyword_value_keys(exprs, literal?) do
    exprs
    |> Enum.flat_map(&keyword_names_in_scope(&1, nil, literal?))
    |> Map.new()
  end

  # Walk carrying the nearest enclosing function name as scope, so a call
  # with no literal param of its own can borrow the function as the
  # subject. A `def` sets the scope for its whole body; the walk recurses
  # with that scope instead of re-descending scope-less, so each call is
  # named exactly once.
  defp keyword_names_in_scope({kind, _, [head | rest]}, _scope, literal?)
       when kind in [:def, :defp] do
    fun = enclosing_function_name(head)
    Enum.flat_map(rest, &keyword_names_in_scope(&1, fun, literal?))
  end

  defp keyword_names_in_scope({_, _, args} = node, scope, literal?) when is_list(args) do
    call_keyword_names(node, scope, literal?) ++
      Enum.flat_map(args, &keyword_names_in_scope(&1, scope, literal?))
  end

  defp keyword_names_in_scope({left, right}, scope, literal?) do
    keyword_names_in_scope(left, scope, literal?) ++
      keyword_names_in_scope(right, scope, literal?)
  end

  defp keyword_names_in_scope(list, scope, literal?) when is_list(list) do
    Enum.flat_map(list, &keyword_names_in_scope(&1, scope, literal?))
  end

  defp keyword_names_in_scope(_node, _scope, _literal?), do: []

  defp enclosing_function_name(head) do
    case strip_when(head) do
      {fun, _, _} when is_atom(fun) -> Atom.to_string(fun)
      _ -> nil
    end
  end

  defp call_keyword_names({{:., _, [_mod, fun]}, _, args}, scope, literal?)
       when is_atom(fun) and is_list(args),
       do: keyword_names_in_call(fun, args, scope, literal?)

  defp call_keyword_names({fun, _, args}, scope, literal?) when is_atom(fun) and is_list(args),
    do: keyword_names_in_call(fun, args, scope, literal?)

  defp call_keyword_names(_, _scope, _literal?), do: []

  defp keyword_names_in_call(fun, args, scope, literal?) do
    subject = first_literal_param(args) || scope_subject(scope, fun)
    noun = call_noun(fun)

    for kw_list <- args,
        is_list(kw_list),
        {{:__block__, _, [key]}, {:__block__, _, [value]} = value_node} <- kw_list,
        is_atom(key) and key not in @block_keywords and literal?.(value),
        name = enriched_name([subject, Atom.to_string(key), noun]),
        name != "" do
      {value_node, name}
    end
  end

  # The enclosing function names the value only when the function is a
  # thin wrapper around the like-named call — `def show, do: JS.show(time:
  # 300)` (`show` == call `show`). A function whose name differs from the
  # call it makes is not the subject; using it would split one constant
  # across unrelated clause names.
  defp scope_subject(nil, _fun), do: nil
  defp scope_subject(scope, fun), do: if(scope == Atom.to_string(fun), do: scope, else: nil)

  # The first positional argument that is a plain atom/string literal.
  # Names the subject the call acts on. nil when no such param precedes
  # the keywords.
  defp first_literal_param(args) do
    Enum.find_value(args, fn
      {:__block__, _, [value]} when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      {:__block__, _, [value]} when is_binary(value) -> value
      _ -> nil
    end)
  end

  # The call's noun: its name with a leading domain verb stripped
  # (`validate_length` → `length`). nil when the name is a bare verb or
  # carries no recognized verb prefix.
  defp call_noun(fun) do
    str = Atom.to_string(fun)

    Enum.find_value(@call_verbs, fn verb ->
      case String.split(str, verb <> "_", parts: 2) do
        ["", noun] when noun != "" -> noun
        _ -> nil
      end
    end)
  end

  @doc """
  Map each literal value-node to the name of the call that took it as a
  positional argument (`String.slice(x, 0, 200)` → `200 ↦ "slice"`).
  """
  @spec call_contexts([Macro.t()], literal_pred) :: %{Macro.t() => String.t()}
  def call_contexts(exprs, literal?) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(&call_arg_contexts(&1, literal?))
    |> Map.new()
  end

  defp call_arg_contexts({{:., _, [_mod, fun]}, _, args}, literal?)
       when is_atom(fun) and is_list(args),
       do: tag_literal_args(fun, args, literal?)

  defp call_arg_contexts({fun, _, args}, literal?) when is_atom(fun) and is_list(args),
    do: tag_literal_args(fun, args, literal?)

  defp call_arg_contexts(_, _literal?), do: []

  defp tag_literal_args(fun, args, literal?) do
    args
    |> Enum.filter(fn
      {:__block__, _, [value]} -> literal?.(value)
      _ -> false
    end)
    |> Enum.map(&{&1, Atom.to_string(fun)})
  end

  @doc """
  Map each literal value-node to the `{function_name, pattern}` of the
  guard-free function clause whose body it *is* — `def image_width("md"),
  do: 80` ↦ `80 ↦ {"image_width", "md"}`. Only a clause whose entire body
  is the bare literal qualifies.
  """
  @spec clause_contexts([Macro.t()], literal_pred) :: %{Macro.t() => {String.t(), term()}}
  def clause_contexts(exprs, literal?) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(&clause_body_context(&1, literal?))
    |> Map.new()
  end

  defp clause_body_context({kind, _, [head, [{{:__block__, _, [:do]}, body_node}]]}, literal?)
       when kind in [:def, :defp] do
    with {fun, pattern} <- clause_name_and_pattern(head),
         {:__block__, _, [value]} = node <- body_node,
         true <- literal?.(value) do
      [{node, {fun, pattern}}]
    else
      _ -> []
    end
  end

  defp clause_body_context(_, _literal?), do: []

  defp clause_name_and_pattern(head) do
    case strip_when(head) do
      {fun, _, [first | _]} when is_atom(fun) -> {Atom.to_string(fun), literal_pattern(first)}
      _ -> :error
    end
  end

  # The discriminating token of a clause's first argument. A `nil` literal
  # and the `_` wildcard both name their clause — `nil` and `default` — so
  # a `f(nil)`/`f(_)` pair yields `@f_nil`/`@f_default` rather than a
  # `@f`/`@f_2` collision.
  defp literal_pattern({:__block__, _, [nil]}), do: "nil"
  defp literal_pattern(nil), do: "nil"
  defp literal_pattern({:_, _, ctx}) when is_atom(ctx), do: "default"

  defp literal_pattern({:__block__, _, [value]}) when is_binary(value) or is_atom(value),
    do: value

  defp literal_pattern(value) when is_binary(value) or is_atom(value), do: value
  defp literal_pattern(_), do: nil

  # --- occurrence roles ----------------------------------------------

  @log_calls [:debug, :info, :warning, :warn, :error, :notice, :critical, :alert, :emergency]
  @dbg_calls [:dbg, :inspect]

  @doc """
  Map each literal value-node to the syntactic *role* it plays, for
  callers that want a per-role hoisting threshold:

    * `:keyword` — the value of a `key: value` keyword argument
      (`as: "collection"`); config-ish, churns less than a repeated body.
    * `:log` — an argument of a `Logger.*` / `dbg` / `IO.inspect` call;
      a one-off log message is its own documentation.
    * `:other` — everything else (plain call arg, clause body, binding).

  A node that is both a keyword value and inside a log call resolves to
  `:log` (the stronger "leave it" signal). Nodes with no entry are
  `:other` by the caller's default.
  """
  @spec occurrence_roles([Macro.t()], literal_pred) :: %{Macro.t() => :keyword | :log | :other}
  def occurrence_roles(exprs, literal?) do
    keyword = role_nodes_keyword(exprs, literal?)
    log = role_nodes_log(exprs, literal?)

    Map.merge(
      Map.new(keyword, &{&1, :keyword}),
      Map.new(log, &{&1, :log})
    )
  end

  defp role_nodes_keyword(exprs, literal?) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {{:__block__, _, [key]}, {:__block__, _, [value]} = node}
      when is_atom(key) and key not in @block_keywords ->
        if literal?.(value), do: [node], else: []

      _ ->
        []
    end)
  end

  defp role_nodes_log(exprs, literal?) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {{:., _, [_mod, fun]}, _, args} when fun in @log_calls or fun in @dbg_calls ->
        literal_arg_nodes(args, literal?)

      {fun, _, args} when (fun in @log_calls or fun in @dbg_calls) and is_list(args) ->
        literal_arg_nodes(args, literal?)

      _ ->
        []
    end)
  end

  defp literal_arg_nodes(args, literal?) do
    Enum.flat_map(args, fn
      {:__block__, _, [value]} = node -> if literal?.(value), do: [node], else: []
      _ -> []
    end)
  end

  # --- exclusions ----------------------------------------------------

  @doc """
  Every literal node under a directive or declaration call whose literals
  are not repeated data: `import`/`alias`/`require`/`use` (arities and
  compile-time macro options — `use P, token: "X"` hands `__using__/1`
  raw AST, so a `@attr` there breaks expansion) and `attr`/`slot`
  (component declaration defaults). These literals are neither candidate
  nor counted.
  """
  @spec directive_nodes([Macro.t()], literal_pred) :: MapSet.t()
  def directive_nodes(exprs, literal?) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {directive, _, _} = node when directive in @directive_calls ->
        literal_value_nodes(node, literal?)

      _ ->
        []
    end)
    |> MapSet.new()
  end

  @doc """
  Every `{:__block__, _, [value]}` node under `ast` whose value satisfies
  `literal?`.
  """
  @spec literal_value_nodes(Macro.t(), literal_pred) :: [Macro.t()]
  def literal_value_nodes(ast, literal?) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:__block__, _, [value]} = node -> if literal?.(value), do: [node], else: []
      _ -> []
    end)
  end

  # --- naming opts + verdicts ----------------------------------------

  @doc """
  Build the `%{key:, context:, clause:}` opts for a value group from its
  hits — the first non-nil signal of each axis, in source order.
  """
  @spec name_opts([map]) :: %{key: term(), context: term(), clause: term()}
  def name_opts(hits) do
    %{
      key: Enum.find_value(hits, & &1.key),
      context: Enum.find_value(hits, & &1.context),
      clause: Enum.find_value(hits, & &1.clause)
    }
  end

  @doc """
  Whether a value group's occurrences agree on the *deliberate* naming
  signal they carry — the keyword key or the clause function.

  A group is ambiguous when its hits disagree on the dominant deliberate
  axis: two distinct keyword keys (`batch_size: 5` vs
  `max_concurrency: 5`), or — the trap that motivated this — a keyed hit
  mixed with a key-less one. A `nil` key is **not** a wildcard: an
  occurrence with no key of its own (a positional arg, an arithmetic
  operand, a tuple element) would silently inherit a name minted for an
  unrelated keyword site — `max_concurrency: 10` lending its name to
  `idx + 10`, or to `Map.get(ranges, prefix, {1, 10})`. So a keyed hit
  only agrees with other hits carrying the *same* key.

  The `context` axis (the surrounding call name) is deliberately **not**
  an agreement source: it is a fallback name, below value-content for
  strings (`log("x")`/`warn("x")` both name themselves `@x`), so a
  context disagreement there is no clash.
  """
  @spec unambiguous?([map]) :: boolean()
  def unambiguous?(hits) do
    case dominant_axis(hits) do
      nil -> true
      axis -> hits |> Enum.map(&axis_signal(&1, axis)) |> Enum.uniq() |> length() == 1
    end
  end

  # The highest-priority *deliberate* axis on which any hit carries a
  # signal — key over clause, matching `derive_constant_name/2`'s order.
  # nil when no hit carries a key or clause (the group is named by context
  # or value-content, neither an ambiguity source).
  defp dominant_axis(hits) do
    Enum.find([:key, :clause], fn axis ->
      Enum.any?(hits, &(not is_nil(axis_signal(&1, axis))))
    end)
  end

  # The agreement token a hit contributes on an axis. The clause axis
  # agrees on the *function name* — different patterns of one function
  # (`icon_size(:large)`, `icon_size(_)`) return the same constant and
  # are not a clash. The key axis agrees on its whole value.
  defp axis_signal(hit, :clause) do
    case Map.get(hit, :clause) do
      {fun, _pattern} -> fun
      other -> other
    end
  end

  defp axis_signal(hit, axis), do: Map.get(hit, axis)

  # --- stem assembly -------------------------------------------------

  @doc """
  Join the available tokens into one snake_case attribute stem: drop
  nils, split on `_`, sanitize each subtoken to `[a-z0-9_]`, drop any
  with no letter, dedup in order (`["email", "max", "length"]` →
  `"email_max_length"`). Returns `""` when nothing nameable survives.
  """
  @spec enriched_name([String.t() | nil]) :: String.t()
  def enriched_name(tokens) do
    tokens
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.flat_map(&String.split(&1, "_", trim: true))
    |> Enum.flat_map(&sanitize_subtoken/1)
    |> Enum.dedup()
    |> Enum.uniq()
    |> valid_stem()
  end

  @doc """
  Join sanitized subtokens into an attribute stem that is a *valid*
  identifier. It must start with a letter (`@24h` does not compile), so
  leading subtokens that begin with a digit (`["3", "day"]`, `["24h"]`)
  are dropped until one starts with a letter; a digit-leading subtoken in
  a later position is kept (`["padding", "2xl"]` → `"padding_2xl"`). A
  stem that lands on a reserved word or a special module attribute
  (`@true`, `@type`, `@end`) is rejected. When nothing valid survives, the
  stem is `""`.
  """
  @spec valid_stem([String.t()]) :: String.t()
  def valid_stem(subtokens) do
    stem = subtokens |> Enum.drop_while(&starts_with_digit?/1) |> Enum.join("_")
    if IdentifierExpansion.reserved_attribute_name?(stem), do: "", else: stem
  end

  defp starts_with_digit?(token), do: String.match?(token, ~r/^[0-9]/)

  @doc """
  Fold one token to a valid attribute subtoken (`[a-z0-9_]`), or `[]`
  when it keeps no letter (a punctuation delimiter carries no name).
  """
  @spec sanitize_subtoken(String.t()) :: [String.t()]
  def sanitize_subtoken(token) do
    cleaned =
      token |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")

    if cleaned == "" or not String.match?(cleaned, ~r/[a-z]/), do: [], else: [cleaned]
  end

  # --- shared head helpers -------------------------------------------

  @doc "Strip a `when` guard off a clause head, yielding the bare pattern."
  @spec strip_when(Macro.t()) :: Macro.t()
  def strip_when({:when, _, [pat | _]}), do: pat
  def strip_when(other), do: other
end
