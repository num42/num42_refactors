defmodule Number42.Refactors.Ex.ExtractErrorVocabulary do
  @moduledoc """
  Centralise a repeated `{:error, atom}` vocabulary into a named `defp`
  helper, and replace each **construction** site with a call to it.

      def fetch(id), do: lookup(id) || {:error, :not_found}
      def update(id), do: ... {:error, :not_found}
      def delete(id), do: ... {:error, :not_found}
      ↓
      defp error_not_found, do: {:error, :not_found}

      def fetch(id), do: lookup(id) || error_not_found()
      def update(id), do: ... error_not_found()
      def delete(id), do: ... error_not_found()

  ## Trigger

  The same `{:error, <atom>}` tuple is **constructed** in
  `>= min_occurrences` (default `3`) positions inside one module. The
  inner atom is the grouping key, so `{:error, :not_found}` constructed
  in a `def` body, a `case` arm, and a `with else` arm all count toward
  the same vocabulary entry.

  ## Construction vs. match — the correctness invariant

  A tagged-error tuple appears in two fundamentally different positions:

    * **Construction** — the tuple is a *value* being produced: a return
      expression, the RHS of `=` / `<-`, a `case`/`with`/`fn` clause
      body. These are replaced with `error_<atom>()`.
    * **Match** — the tuple is a *pattern*: the LHS of `=`, the LHS of a
      `with` `<-` generator, a `case`/`with else`/`fn`/`receive` clause
      head, or a function-head argument or `when`-guard literal. A
      function call can never stand in a pattern, so these are **left
      untouched**.

  The walk descends only into construction positions when collecting
  candidates and patching; pattern subtrees are skipped wholesale. A
  module whose only occurrences are matches is left entirely unchanged.

  ## Naming and placement

  The helper is `defp error_<atom>, do: {:error, <atom>}`, inserted at
  the first top-level expression of the module body (after aliases,
  before the first clause that uses it). `<atom>` is the inner error
  atom verbatim. When `error_<atom>` would collide with a function name
  already defined in the module, that vocabulary entry is **skipped**
  rather than suffixed — a `error_not_found_2` helper would be
  misleading.

  ## Skip conditions (entry left unchanged when any holds)

  - **Below threshold.** Fewer than `min_occurrences` construction sites
    share the inner atom.
  - **Generic control-flow atom.** Inner atoms that are flow signals
    rather than error vocabulary (`:ok`, `:error`, `:noreply`, `:reply`,
    `:stop`, `:continue`, `:cont`, `:halt`, `:next`, `:done`) are
    skipped — `{:error, :ok}` is not a distinct error name.
  - **Non-`:error` tag.** Only `{:error, atom}` two-tuples qualify;
    `{:ok, _}`, three-tuples (`{:error, :x, detail}`), and tuples with a
    non-atom payload are ignored.
  - **Name collision.** `error_<atom>` already names a function in the
    module.

  ## Idempotence

  After the rewrite the construction sites read `error_<atom>()` and the
  only remaining literal `{:error, <atom>}` is the one inside the
  synthesised helper's own body — a single occurrence, below threshold.
  The second pass therefore finds nothing to extract.

  ## Default-OFF (opt-in only)

  Disabled by default — `transform/2` is a no-op unless its opts carry
  `enabled: true`. The naming heuristic (`error_<atom>`) and the
  construction/match discrimination are conservative but the acceptance
  criteria gate this on solid naming heuristics, so it ships opt-in:

      configured_modules: [
        {Number42.Refactors.Ex.ExtractErrorVocabulary, enabled: true}
      ]
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @default_min_occurrences 3

  # Inner atoms that are control-flow signals, not error vocabulary.
  @generic_atoms ~w(ok error noreply reply stop continue cont halt next done)a

  @impl Number42.Refactors.Refactor
  def description,
    do: "Centralise a repeated {:error, atom} constructed >= 3x into a defp error_<atom> helper"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    The same tagged-error tuple constructed across many call sites is a
    vocabulary spread thin: the atom's meaning lives in every copy and
    drifts when one copy is edited. Naming it once as
    `defp error_<atom>, do: {:error, <atom>}` gives the error a single
    definition and an intent-revealing call (`error_not_found()`), while
    leaving every pattern-match position untouched — a function call can
    never stand where a literal pattern is required, so only construction
    sites are rewritten.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      min = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
      Sourceror.parse_string(source) |> apply_patches(source, min)
    else
      source
    end
  end

  defp apply_patches({:ok, ast}, source, min),
    do: ast |> build_patches(min) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source, _min), do: source

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp build_patches(ast, min) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value([], fn
      {:defmodule, _, [_name, [{_do, body}]]} -> module_patches(body, min)
      _ -> nil
    end)
  end

  defp module_patches(body, min) do
    exprs = body_to_exprs(body)
    taken = defined_names(exprs)

    exprs
    |> collect_constructions()
    |> Enum.group_by(&inner_atom/1)
    |> Enum.filter(fn {atom, nodes} -> eligible?(atom, nodes, min, taken) end)
    |> Enum.sort_by(fn {atom, _nodes} -> atom end)
    |> Enum.flat_map(fn {atom, nodes} -> emit_entry(atom, nodes, exprs) end)
  end

  # An entry is eligible when its inner atom is real error vocabulary,
  # it clears the threshold, and the helper name is free.
  defp eligible?(atom, nodes, min, taken) do
    atom not in @generic_atoms and
      length(nodes) >= min and
      not MapSet.member?(taken, helper_name(atom))
  end

  # --- construction collection -----------------------------------------

  # Walk `exprs`, gathering every `{:error, atom}` tuple that sits in a
  # construction (value) position. Pattern subtrees are never entered, so
  # a tagged-error literal used as a match is never collected.
  defp collect_constructions(exprs) when is_list(exprs),
    do: Enum.flat_map(exprs, &collect_constructions/1)

  # `lhs = rhs` / `lhs <- rhs`: lhs is a pattern, rhs is a value.
  defp collect_constructions({op, _, [_lhs, rhs]}) when op in [:=, :<-],
    do: collect_constructions(rhs)

  # `pattern(s) -> body`: the head list is patterns, the body is a value.
  defp collect_constructions({:->, _, [_heads, body]}),
    do: collect_constructions(body)

  # def/defp/defmacro head + body: the head is patterns/guards, only the
  # `do:` (and `rescue`/`after`/...) bodies are values.
  defp collect_constructions({kind, _, [_head, body_kw]})
       when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(body_kw),
       do: collect_constructions(Keyword.values(body_kw))

  # A `{:error, atom}` construction tuple is recorded as a whole. Any
  # other 3-element node is descended into.
  defp collect_constructions({_, _, _} = node) do
    case error_tuple_atom(node) do
      {:ok, _atom} -> [node]
      :error -> collect_children(node)
    end
  end

  defp collect_constructions(other), do: collect_children(other)

  defp collect_children({_form, _meta, args}) when is_list(args),
    do: collect_constructions(args)

  defp collect_children({a, b}),
    do: collect_constructions(a) ++ collect_constructions(b)

  defp collect_children(list) when is_list(list),
    do: Enum.flat_map(list, &collect_constructions/1)

  defp collect_children(_), do: []

  # --- error-tuple recognition -----------------------------------------

  # A Sourceror-parsed `{:error, :atom}` two-tuple is
  # `{:__block__, _, [{tag_block, payload_block}]}` where both inner
  # blocks wrap a bare atom. Returns the inner atom or `:error`.
  defp error_tuple_atom({:__block__, _, [{tag, payload}]}) do
    with {:ok, :error} <- block_atom(tag),
         {:ok, atom} <- block_atom(payload) do
      {:ok, atom}
    else
      _ -> :error
    end
  end

  defp error_tuple_atom(_), do: :error

  defp block_atom({:__block__, _, [atom]}) when is_atom(atom), do: {:ok, atom}
  defp block_atom(_), do: :error

  defp inner_atom(node) do
    {:ok, atom} = error_tuple_atom(node)
    atom
  end

  # --- emit -------------------------------------------------------------

  defp emit_entry(atom, nodes, exprs) do
    name = helper_name(atom)

    replacements =
      Enum.map(nodes, fn node -> Patch.replace(node, "#{name}()") end)

    [helper_patch(atom, name, exprs) | replacements]
  end

  # One line-anchored insertion of the `defp` helper, placed at the first
  # top-level expression's line, column 1 — after the module's aliases,
  # before the first clause that uses it.
  defp helper_patch(atom, name, exprs) do
    line = exprs |> hd() |> line_of()
    text = "defp #{name}, do: {:error, #{inspect(atom)}}\n\n"
    range = %{start: [line: line, column: 1], end: [line: line, column: 1]}
    Patch.new(range, text, false)
  end

  # --- naming -----------------------------------------------------------

  defp helper_name(atom), do: :"error_#{atom}"

  # Names of every function/macro defined in the module body, so a
  # synthesised helper that would collide is skipped.
  defp defined_names(exprs) do
    exprs
    |> Enum.flat_map(fn
      {kind, _, [head | _]} when kind in [:def, :defp, :defmacro, :defmacrop] ->
        case extract_fn_signature(head) do
          {name, _args} -> [name]
          :error -> []
        end

      _ ->
        []
    end)
    |> MapSet.new()
  end
end
