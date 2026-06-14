defmodule Number42.Refactors.Ex.LambdaDestructureToHead do
  @moduledoc """
  Lifts a lambda's (or `for` generator's) first-statement param
  destructure into the binding pattern:

      Enum.map(pairs, fn pair ->
        {key, value} = pair
        process(key, value)
      end)
      ↓
      Enum.map(pairs, fn {key, value} -> process(key, value) end)

      for pair <- pairs do
        {key, value} = pair
        process(key, value)
      end
      ↓
      for {key, value} <- pairs do
        process(key, value)
      end

  ## When this fires

  - **Lambda**: single-clause, single **bare-var** param, whose body's
    **first statement** is `pattern = param` — the bound param,
    destructured. The pattern must be a real destructure (tuple, list,
    map, struct, binary, or a `pattern = var` whole-binding), never a
    bare variable (`y = param` is a rename, not a destructure).
  - **`for` comprehension**: a generator `param <- coll` whose body's
    first statement is `pattern = param`. The matched param must belong
    to exactly one generator.

  In both cases the destructure statement is dropped and `param` is
  replaced by `pattern` in the binding position.

  ## Why it's safe

  Moving `pattern = param` into the head is semantically identical: the
  same pattern match runs on the same value, only earlier. A refutable
  pattern (`{:ok, v} = param`) still raises on mismatch — the error site
  shifts but the behaviour does not (see issue #113).

  ## What we skip — `param` re-used as a whole

  If `param` is referenced anywhere after the destructure (passed whole
  somewhere, used in another generator/filter), the head-pattern lift
  would drop the binding to the whole value and break those references.
  We **skip** rather than emit a `fn pattern = param -> ...` head: the
  bare lift is the unambiguously-safe core the issue asks for, and the
  `= param` form just reintroduces a shape this refactor would have to
  reason about for idempotence. When the whole value is still needed,
  the lambda stays as written.

  Also skipped:

  - multi-clause lambdas (`fn a -> …; b -> … end`)
  - lambdas with a guard (`fn x when … -> …`)
  - param that is underscore-prefixed (intentionally unused)
  - a pattern that re-binds the param's own name (`{pair, _} = pair`)
  - a `for` whose matched param belongs to more than one generator

  ## Idempotence

  After a rewrite the binding position holds a pattern, not a bare var,
  so the head/generator no longer matches — a second pass is a no-op.

  ## Reformatting

  Emits the replacement as raw text and relies on the `mix format` pass
  (`reformat_after?: true`) to normalise indentation. Tests compare
  whitespace-agnostically.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description,
    do: "fn x -> pat = x; rest end -> fn pat -> rest end (and the for-generator form)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A lambda whose first act is to destructure its own parameter is
    saying "match this shape" one statement too late. Lifting the
    pattern into the head says the same thing where the binding happens,
    drops a line, and makes the shape the reader's first signal instead
    of a buried `=`. The same applies to a `for` generator: the pattern
    belongs on the `<-`.

    The rewrite is intentionally narrow — single bare-var param, the
    destructure must be the first statement, and the whole value must
    not be used again — because that is exactly the case where moving
    the match into the binding position is behaviour-preserving. When
    the param is still needed as a whole, or the shape is anything
    looser, the lambda is left untouched.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 150
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp apply_patches({:ok, ast}, source),
    do: ast |> collect_patches() |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  # Walk top-down, but once a node is patched we do NOT descend into it: its
  # replacement is re-rendered as text, so a child patch would overlap the
  # parent's range. Any nested match is picked up on the engine's next
  # fixpoint pass (and `assert_idempotent`'s second pass).
  defp collect_patches(ast) do
    case maybe_patch(ast) do
      {:patch, patch} -> [patch]
      :no_patch -> ast |> children() |> Enum.flat_map(&collect_patches/1)
    end
  end

  defp children({_form, _meta, args}) when is_list(args), do: args
  defp children({left, right}), do: [left, right]
  defp children(list) when is_list(list), do: list
  defp children(_), do: []

  # --- lambda -------------------------------------------------------------

  defp maybe_patch({:fn, _, [{:->, _, [[param], body]}]} = node) do
    with {:ok, param_name} <- bare_var_name(param),
         {:ok, pattern, rest} <- split_destructure(body, param_name),
         :ok <- ensure_not_reused(rest, param_name) do
      {:patch, Patch.replace(node, render_lambda(pattern, rest))}
    else
      _ -> :no_patch
    end
  end

  # --- for comprehension --------------------------------------------------

  defp maybe_patch({:for, _, args} = node) when is_list(args) do
    with {:ok, generators, body} <- split_for(args),
         {:ok, gen_index, param_name} <- destructured_generator(generators, body),
         {:ok, pattern, rest} <- split_destructure(body, param_name),
         :ok <- ensure_not_reused(rest, param_name),
         :ok <- ensure_not_in_other_clauses(generators, gen_index, param_name) do
      {:patch, Patch.replace(node, render_for(generators, gen_index, pattern, rest))}
    else
      _ -> :no_patch
    end
  end

  defp maybe_patch(_), do: :no_patch

  # --- shared analysis ----------------------------------------------------

  # First statement is `pattern = param`; returns the pattern and the
  # remaining statements (re-wrapped as a block, or the lone statement).
  defp split_destructure({:__block__, meta, [first | rest]}, param_name) when rest != [] do
    with {:ok, pattern} <- match_against_param(first, param_name) do
      {:ok, pattern, {:__block__, meta, rest}}
    end
  end

  defp split_destructure({:=, _, _} = first, param_name) do
    with {:ok, pattern} <- match_against_param(first, param_name) do
      {:ok, pattern, :empty}
    end
  end

  defp split_destructure(_body, _param_name), do: :skip

  defp match_against_param({:=, _, [pattern, {name, _, ctx}]}, param_name)
       when name == param_name and is_atom(ctx) do
    if destructuring_pattern?(pattern) and not binds_name?(pattern, param_name) do
      {:ok, pattern}
    else
      :skip
    end
  end

  defp match_against_param(_, _), do: :skip

  # A bare variable on the LHS is a rename, not a destructure. Everything
  # else (tuple / list / map / struct / binary / nested) is a real
  # destructure worth lifting. A `pat = whole` whole-binding counts too.
  defp destructuring_pattern?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: false
  defp destructuring_pattern?(_), do: true

  defp bare_var_name({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    if String.starts_with?(Atom.to_string(name), "_"), do: :skip, else: {:ok, name}
  end

  defp bare_var_name(_), do: :skip

  defp ensure_not_reused(:empty, _param_name), do: :ok

  defp ensure_not_reused(rest, param_name) do
    if var_count(rest, param_name) == 0, do: :ok, else: :skip
  end

  defp binds_name?(pattern, name), do: var_count(pattern, name) > 0

  defp var_count(ast, name) do
    ast
    |> Macro.prewalker()
    |> Enum.count(fn
      {^name, _, ctx} when is_atom(ctx) -> true
      _ -> false
    end)
  end

  # --- for helpers --------------------------------------------------------

  # `for gen1, gen2, …, filter, [{do_block, body}]` — peel the trailing
  # keyword block, keep the generators/filters as the clause list.
  defp split_for(args) do
    case List.last(args) do
      [{{:__block__, _, [:do]}, body}] -> {:ok, Enum.drop(args, -1), body}
      _ -> :skip
    end
  end

  # The generator whose pattern is the bare var the body's first match
  # destructures. Returns its index among the clause list.
  defp destructured_generator(generators, body) do
    with {:ok, param_name} <- first_match_rhs(body),
         index when is_integer(index) <-
           Enum.find_index(generators, &generator_binds?(&1, param_name)) do
      {:ok, index, param_name}
    else
      _ -> :skip
    end
  end

  defp first_match_rhs({:__block__, _, [{:=, _, [pattern, {name, _, ctx}]} | _]})
       when is_atom(name) and is_atom(ctx) do
    if destructuring_pattern?(pattern), do: {:ok, name}, else: :skip
  end

  defp first_match_rhs(_), do: :skip

  defp generator_binds?({:<-, _, [{name, _, ctx}, _coll]}, param_name)
       when is_atom(ctx),
       do: name == param_name

  defp generator_binds?(_, _), do: false

  # The param must not be referenced by any other generator/filter clause —
  # those share the binding and would lose it if we move the pattern.
  defp ensure_not_in_other_clauses(generators, gen_index, param_name) do
    others = List.delete_at(generators, gen_index)

    if Enum.all?(others, &(var_count(&1, param_name) == 0)), do: :ok, else: :skip
  end

  # --- rendering ----------------------------------------------------------

  defp render_lambda(pattern, rest) do
    "fn #{render(pattern)} ->\n  #{render_body(rest)}\nend"
    |> relift()
  end

  defp render_for(generators, gen_index, pattern, rest) do
    clauses =
      generators
      |> List.update_at(gen_index, fn {:<-, meta, [_var, coll]} ->
        {:<-, meta, [pattern, coll]}
      end)
      |> Enum.map_join(", ", &render/1)

    "for #{clauses} do\n  #{render_body(rest)}\nend"
    |> relift()
  end

  # The walker stops descending into a patched node, so a nested lambda/for
  # in the lifted body isn't seen on this pass. Re-running the transform on
  # the rendered text lifts those nested matches now, making a single pass a
  # fixpoint (so `transform ∘ transform == transform`).
  defp relift(text), do: transform(text, [])

  # `:empty` means the destructure was the lambda's only statement — the
  # lifted form has an empty body. Render `nil` so the result still parses.
  defp render_body(:empty), do: "nil"
  defp render_body({:__block__, _, [single]}), do: render(single)
  defp render_body(rest), do: render(rest)

  defp render(ast), do: ast |> strip_comments() |> Sourceror.to_string()

  defp strip_comments(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        {form, Keyword.drop(meta, [:leading_comments, :trailing_comments]), args}

      other ->
        other
    end)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
