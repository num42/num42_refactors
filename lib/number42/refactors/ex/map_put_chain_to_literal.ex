defmodule Number42.Refactors.Ex.MapPutChainToLiteral do
  @moduledoc """
  Collapses a `%{}`-seeded `Map.put/3` rebind chain into a single map
  literal.

      payload = %{}
      payload = Map.put(payload, :id, user.id)
      payload = Map.put(payload, :name, user.name)
      payload
      ↓
      %{id: user.id, name: user.name}

  ## When this fires

  A run inside a block of the shape

    * a **seed** statement `x = %{}` (the empty-map literal), immediately
      followed by
    * two or more contiguous `x = Map.put(x, key, value)` rebinds of the
      **same** bare variable `x`, where the map base is exactly `x` and
      neither `key` nor `value` reads `x`,

  and where after the run `x` is **dead** — either the run is the block's
  tail, or it is followed by a single bare read of `x` that is the block's
  last statement. The whole run (seed + puts + optional trailing read)
  collapses into one bare `%{…}` literal: each `Map.put(x, k, v)`
  contributes a `k => v` (or `k: v` for atom keys) entry, in order.

  ## Why a literal, not a pipe (relationship to PipelineFromRebindChain)

  `PipelineFromRebindChain` (#36/#81) already folds a generic
  `x = f(x, …)` rebind chain into a `|>` pipe. To avoid overlap this
  refactor targets **only** the `%{}`-seeded, all-`Map.put` chain and
  emits a map **literal**. The two never compete:

    * the seed here is `x = %{}` (not a transform call), which the pipe
      refactor's head step — required to *not* read `x` and to seed the
      pipe — would turn into a degenerate `%{} |> …`; this refactor runs
      at a higher priority and removes the chain first;
    * a chain that mixes `Map.put` with any other call (`Map.merge`,
      `put_new`, a conditional put) is **not** all-`Map.put`, so this
      refactor skips it and leaves it to the pipe refactor.

  ## What we skip — correctness

  * **Non-`%{}` seed** (`x = %{a: 1}`): the literal would drop the
    pre-existing entries.
  * **`key`/`value` reads `x`** (`Map.put(x, :n, map_size(x))`): the value
    at that put depends on the intermediate map, which the flat literal
    cannot express.
  * **`x` read between puts** (`IO.inspect(x)`): that read observes a
    partial map that differs from the final literal. Such a statement is
    not a `Map.put` rebind, so it breaks the contiguous run; with fewer
    than two puts on either side the run is dropped.
  * **`x` read after the run** in any position other than a single
    trailing tail read: the value would still be needed downstream, so the
    binding cannot dissolve.

  Duplicate keys are safe: `Map.put` and a map literal both resolve them
  last-write-wins, and the entries are emitted in source order.

  ## Idempotence

  After folding, the run is a single `%{…}` literal — there is no seed or
  rebind chain left, so a second pass matches nothing.
  """

  use Number42.Refactors.Refactor

  @impl Number42.Refactors.Refactor
  def description, do: "Collapse a %{}-seeded Map.put rebind chain into a map literal"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `x = %{}; x = Map.put(x, :a, 1); x = Map.put(x, :b, 2); x` is a map
    literal written as a sequence of in-place rebinds — the seed, the
    repeated `Map.put`, and the threaded variable are all bookkeeping the
    `%{…}` constructor handles directly. Folding it into `%{a: 1, b: 2}`
    states the shape of the data once, drops a dead binding, and removes a
    class of bugs where a non-empty seed silently merges into the result.
    The fold only fires when every put's base is the chain variable, no
    key or value depends on the intermediate map, and the variable is dead
    after the run, so evaluation order and the final value are preserved.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 150

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: source |> Sourceror.parse_string() |> apply_patches(source)

  @impl Number42.Refactors.Refactor
  def patches(ast, _source, _opts), do: build_patches(ast)

  defp apply_patches({:ok, ast}, source),
    do: ast |> build_patches() |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&block_patches/1)
  end

  defp block_patches({:__block__, _, stmts}) when is_list(stmts), do: chain_patches(stmts, 0, [])
  defp block_patches(_), do: []

  # Walk statements left-to-right; on a collapsible run emit one patch and
  # skip past the whole consumed region so emitted ranges stay disjoint.
  defp chain_patches(stmts, index, acc) do
    case Enum.drop(stmts, index) do
      [] ->
        Enum.reverse(acc)

      [_first | _] = rest ->
        case run_at(rest, stmts, index) do
          {:ok, consumed, patch} -> chain_patches(stmts, index + consumed, [patch | acc])
          :skip -> chain_patches(stmts, index + 1, acc)
        end
    end
  end

  # A run starts at a `var = %{}` seed, takes the maximal contiguous block
  # of `var = Map.put(var, k, v)` rebinds, then optionally a trailing bare
  # `var` tail read. It validates liveness and projects the puts into a
  # map literal.
  defp run_at(rest, stmts, index) do
    with {:ok, var} <- seed_var(rest),
         puts when length(puts) >= 2 <- collect_puts(Enum.drop(rest, 1), var),
         {:ok, entries} <- project(puts, var),
         {:ok, consumed} <- consume_tail(rest, stmts, index, var, length(puts)) do
      {:ok, consumed, run_patch(rest, consumed, render(entries))}
    else
      _ -> :skip
    end
  end

  # First statement must be `var = %{}`.
  defp seed_var([{:=, _, [lhs, {:%{}, _, []}]} | _]), do: bare_var(lhs)
  defp seed_var(_), do: :skip

  # Greedily take the longest prefix of consecutive `var = Map.put(var, _, _)`.
  defp collect_puts(rest, var) do
    Enum.take_while(rest, fn
      {:=, _, [lhs, rhs]} -> bare_var(lhs) == {:ok, var} and map_put_of?(rhs, var)
      _ -> false
    end)
  end

  defp map_put_of?(
         {{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [base, _key, _value]},
         var
       ),
       do: var_ref?(base, var)

  defp map_put_of?(_, _), do: false

  # Each put contributes a `{key, value}` entry; neither may read `var`
  # (else the value depends on the intermediate map).
  defp project(puts, var) do
    puts
    |> Enum.reduce_while([], fn {:=, _, [_, {_, _, [_base, key, value]}]}, acc ->
      if reads?(key, var) or reads?(value, var) do
        {:halt, :skip}
      else
        {:cont, [{key, value} | acc]}
      end
    end)
    |> case do
      :skip -> :skip
      entries -> {:ok, Enum.reverse(entries)}
    end
  end

  # After the puts, `var` must be dead: either the run is the block tail
  # (nothing reads it later), or the very next statement is a bare `var`
  # tail read with nothing reading it afterward. Returns how many leading
  # statements of `rest` the run consumes (seed + puts [+ tail read]).
  defp consume_tail(rest, stmts, index, var, put_count) do
    run_len = put_count + 1
    last_run_index = index + run_len - 1

    cond do
      not read_after?(var, stmts, last_run_index) ->
        {:ok, run_len}

      tail_read?(rest, run_len, var) and not read_after?(var, stmts, last_run_index + 1) ->
        {:ok, run_len + 1}

      true ->
        :skip
    end
  end

  defp tail_read?(rest, run_len, var) do
    case Enum.drop(rest, run_len) do
      [tail] -> var_ref?(tail, var)
      _ -> false
    end
  end

  defp run_patch(rest, consumed, replacement) do
    run = Enum.take(rest, consumed)

    range = %{
      start: Sourceror.get_range(hd(run)).start,
      end: Sourceror.get_range(List.last(run)).end
    }

    %{change: replacement, range: range}
  end

  defp reads?(ast, var), do: MapSet.member?(used_var_names(ast), var)

  # Keys that are simple atoms render as the keyword shorthand `k: v`; any
  # other key forces the all-arrow form `k => v` for every entry, which
  # sidesteps the rule that keyword entries must come last in a map literal.
  defp render(entries) do
    body =
      if Enum.all?(entries, &keyword_key?/1),
        do: Enum.map_join(entries, ", ", &keyword_entry/1),
        else: Enum.map_join(entries, ", ", &arrow_entry/1)

    "%{" <> body <> "}"
  end

  defp keyword_key?({key, _value}) do
    case atom_literal(key) do
      {:ok, atom} -> simple_keyword_atom?(atom)
      :skip -> false
    end
  end

  defp simple_keyword_atom?(atom),
    do: atom |> Atom.to_string() |> String.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]*[?!]?\z/)

  defp keyword_entry({key, value}) do
    {:ok, atom} = atom_literal(key)
    "#{atom}: #{node_text(value)}"
  end

  defp arrow_entry({key, value}), do: "#{node_text(key)} => #{node_text(value)}"

  defp atom_literal(key) when is_atom(key), do: {:ok, key}
  defp atom_literal({:__block__, _, [atom]}) when is_atom(atom), do: {:ok, atom}
  defp atom_literal(_), do: :skip

  defp node_text(node), do: Sourceror.to_string(node)

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
