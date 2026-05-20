defmodule Number42.Refactors.Ex.ResolveImplTrue do
  @moduledoc """
  Replaces `@impl true` with `@impl <Behaviour>` by looking up which
  behaviour declares the callback in question.

      use GenServer

      @impl true
      def init(state), do: {:ok, state}
      ↓
      @impl GenServer
      def init(state), do: {:ok, state}

  ## How the lookup works

  We rely on the project being **already compiled**: the engine runs
  after `mix compile`, so every module's BEAM is on disk and loadable.
  For each `defmodule X.Y.Z` we encounter, we resolve the alias to a
  module atom, check that it's loaded, and read
  `__info__(:attributes)[:behaviour]` to get the list of behaviours
  effectively declared on the module — both `@behaviour Foo` AND
  behaviours injected by `use Foo`. For each behaviour we read
  `behaviour_info(:callbacks)` to build a `{name, arity} -> behaviour`
  map.

  ## What we rewrite

  Inside a module body, every `@impl true` immediately preceding a
  `def`/`defp`/`defmacro`/`defmacrop` whose `{name, arity}` resolves
  to **exactly one** behaviour is rewritten to `@impl <Behaviour>`.

  ## What we skip (per @impl true site)

  - The `def` head doesn't match any callback in any of the module's
    behaviours. Likely user error; the compiler will warn — leave
    alone for the human.
  - The callback is declared by **two or more** behaviours. Picking
    one would be a guess; the user's mental model is the source of
    truth. Skip and let the human disambiguate.
  - The annotation isn't `@impl true` (e.g. already `@impl Foo`, or
    `@impl false`). Out of scope.

  ## What we skip (per module)

  - The module's name can't be resolved to a loaded atom (mistyped,
    or compiled to a different name). Without BEAM info we can't
    verify any callback, so skip the whole module.
  - The module declares no behaviours.

  ## Why procedural

  We need to walk the module body in **block order** to pair every
  `@impl true` attribute with the `def` clause that follows it. Plus
  we need an out-of-AST side channel: BEAM introspection. The
  declarative DSL can't express either.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "@impl true -> @impl <Behaviour> via BEAM lookup"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `@impl true` tells the compiler "yes, this is a callback" without
    saying *which* behaviour declares it. That's a hint for humans:
    when reading code, you have to scan upwards to find the
    `@behaviour`/`use` lines and cross-reference each callback name
    with the behaviour's documented contract. `@impl <Behaviour>`
    says it directly at the call site — and the compiler verifies the
    pairing, catching mistakes like "I thought this was a GenServer
    callback but it's actually a Supervisor one".
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_patches(ast),
    do:
      ast
      |> collect_modules()
      |> Enum.flat_map(&patches_for_module/1)

  # Walk the AST, return a list of `{module_atom, body_exprs}` for every
  # `defmodule` we can resolve. Nested modules are returned separately
  # so each gets its own callback table.
  defp collect_modules(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, mod} -> [{mod, body_to_exprs(body)}]
          :error -> []
        end

      _ ->
        []
    end)
  end

  defp patches_for_module({mod, exprs}),
    do: callback_table(mod) |> patches_for_callbacks_or_skip(exprs)

  # Build `{name, arity} -> behaviour` lookup. Skips entries claimed by
  # ≥2 behaviours: those would be guesses.
  defp callback_table(mod) do
    if Code.ensure_loaded?(mod) do
      behaviours =
        mod.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      case behaviours do
        [] ->
          :skip

        [_ | _] = list ->
          list
          |> Enum.flat_map(&callbacks_for/1)
          |> Enum.group_by(fn {key, _beh} -> key end, fn {_key, beh} -> beh end)
          |> Enum.reduce(%{}, fn
            {key, [beh]}, acc -> Map.put(acc, key, beh)
            # ≥2 behaviours claim this callback — leave the entry out
            # of the table; sites resolving to it will skip.
            {_key, [_, _ | _]}, acc -> acc
          end)
      end
    else
      :skip
    end
  end

  defp callbacks_for(behaviour) do
    if Code.ensure_loaded?(behaviour) and
         function_exported?(behaviour, :behaviour_info, 1) do
      behaviour.behaviour_info(:callbacks)
      |> Enum.map(fn {name, arity} -> {{name, arity}, behaviour} end)
    else
      []
    end
  rescue
    _ -> []
  end

  # Walk body expressions in order, pair each `@impl true` with the
  # immediately-following def-like clause. Returns a list of
  # `{impl_node, def_node}` tuples for the patch decision step.
  defp pair_impls_with_defs(exprs), do: pair_impls_with_defs(exprs, [])

  defp pair_impls_with_defs([], acc), do: acc |> Enum.reverse()

  defp pair_impls_with_defs([impl_node, next | rest], acc) do
    if impl_true?(impl_node) and def_clause?(next) do
      pair_impls_with_defs([next | rest], [{impl_node, next} | acc])
    else
      pair_impls_with_defs([next | rest], acc)
    end
  end

  defp pair_impls_with_defs([_], acc), do: acc |> Enum.reverse()

  # Sourceror wraps literal arguments in `{:__block__, meta, [literal]}`.
  # `Code.string_to_quoted` does not. Accept both shapes so the refactor
  # works against either parser.
  defp impl_true?({:@, _, [{:impl, _, [{:__block__, _, [true]}]}]}), do: true
  defp impl_true?({:@, _, [{:impl, _, [true]}]}), do: true
  defp impl_true?(_), do: false

  defp def_clause?({kind, _, [_head | _]}) when def_or_macro_kind?(kind), do: true

  defp def_clause?(_), do: false

  defp maybe_patch({impl_node, def_node}, table) do
    with {:ok, {name, arity}} <- def_name_arity(def_node),
         {:ok, behaviour} <- Map.fetch(table, {name, arity}) do
      replacement = "@impl #{inspect(behaviour)}"

      case build_patch(impl_node, replacement, boolish_tail?: true) do
        nil -> [Patch.replace(impl_node, replacement)]
        patch -> [patch]
      end
    else
      _ -> []
    end
  end

  # `def head` is either `{:when, _, [actual_head, _guards]}` or the
  # head directly. Strip a `when` wrapper, then extract `{name, arity}`.
  defp def_name_arity({_kind, _, [head | _]}), do: strip_when(head) |> name_arity_or_error()

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patches_for_callbacks_or_skip(:skip, _exprs), do: []

  defp patches_for_callbacks_or_skip(table, exprs),
    do: exprs |> pair_impls_with_defs() |> Enum.flat_map(&maybe_patch(&1, table))

  defp name_arity_or_error({name, _, args}) when is_atom(name) and is_list(args) do
    {:ok, {name, length(args)}}
  end

  defp name_arity_or_error({name, _, nil}) when is_atom(name) do
    {:ok, {name, 0}}
  end

  defp name_arity_or_error(_), do: :error

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
