defmodule Number42.Refactors.Ex.MapPutChainToLiteral do
  @moduledoc """
  Collapses a `%{}`-seeded `Map.put/3` rebind chain into a map literal.

      payload = %{}
      payload = Map.put(payload, :id, user.id)
      payload = Map.put(payload, :name, user.name)
      payload
      ↓
      %{
        id: user.id,
        name: user.name
      }

  ## When this fires

  A contiguous run of statements inside a block of the form:

    * `x = %{}` to seed the map,
    * followed by one or more `x = Map.put(x, key, value)` rebinds of the
      same bare variable,
    * ending either in a bare read of `x` or with the final `Map.put/3`
      assignment as the tail expression.

  Each `Map.put/3` contributes one entry to the emitted literal. Atom keys
  that can be rendered in keyword syntax become `key: value`; other keys stay
  in the explicit `key => value` form.

  ## Boundaries vs `PipelineFromRebindChain`

  A pure `Map.put/3` chain with the last assignment as the tail expression
  also looks like a generic same-variable rebind pipeline. This refactor runs
  earlier and claims that narrower shape first, so `%{}`-seeded map assembly
  becomes a literal instead of a `|>` chain.

  Mixed chains are left alone on purpose. Once any step is not `Map.put/3`,
  the rewrite is no longer a static literal fold and belongs to
  `PipelineFromRebindChain` instead.

  ## Real skip case

  If the intermediate map value is read before the chain finishes, replacing
  the statements with one final literal would change what that read observes.
  Only uninterrupted `%{}` + `Map.put/3` runs are rewritten.

  ## Idempotence

  After rewriting, the run is a single map literal expression. There is no
  `%{}` seed or `Map.put/3` chain left, so a second pass matches nothing.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "%{}-seeded Map.put rebind chain -> map literal"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `payload = %{}; payload = Map.put(payload, k, v); payload` is a map
    literal spelled out as mutable-looking bookkeeping. Replacing the `%{}`
    seed plus pure `Map.put/3` accumulation with `%{k => v, ...}` removes the
    rebinding noise, makes the constructed shape visible at a glance, and
    avoids competing with the more generic pipe-oriented rebind cleanup.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 130

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp build_patches(ast, source) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&block_patches(&1, source))
  end

  defp block_patches({:__block__, _, stmts}, source) when is_list(stmts),
    do: chain_patches(stmts, source, 0, [])

  defp block_patches(_, _source), do: []

  defp chain_patches(stmts, source, index, acc) do
    case Enum.drop(stmts, index) do
      [] ->
        Enum.reverse(acc)

      [_ | _] = rest ->
        case run_at(rest, source) do
          {:ok, consumed, replacement} ->
            patch = run_patch(rest, consumed, replacement)
            chain_patches(stmts, source, index + consumed, [patch | acc])

          :skip ->
            chain_patches(stmts, source, index + 1, acc)
        end
    end
  end

  defp run_at([seed | rest], source) do
    with {:ok, var} <- seed_assignment(seed),
         puts when puts != [] <- collect_put_rebinds(rest, var),
         {:ok, consumed} <- run_terminator(rest, length(puts), var) do
      entries =
        puts
        |> Enum.map(&put_entry!/1)
        |> Enum.map(fn {key, value} ->
          {node_text(source, key), node_text(source, value), atom_key(key)}
        end)

      {:ok, consumed + 1, render_literal(entries)}
    else
      _ -> :skip
    end
  end

  defp run_at(_, _source), do: :skip

  defp run_patch(rest, consumed, replacement) do
    run = Enum.take(rest, consumed)

    range = %{
      start: Sourceror.get_range(hd(run)).start,
      end: Sourceror.get_range(List.last(run)).end
    }

    Patch.new(range, replacement, false)
  end

  defp seed_assignment({:=, _, [lhs, rhs]}) do
    with {:ok, var} <- bare_var(lhs),
         true <- empty_map?(rhs) do
      {:ok, var}
    else
      _ -> :skip
    end
  end

  defp seed_assignment(_), do: :skip

  defp collect_put_rebinds(rest, var) do
    rest
    |> Enum.take_while(&same_var_assignment?(&1, var))
    |> Enum.take_while(&map_put_rebind?(&1, var))
  end

  defp run_terminator(rest, puts_len, var) do
    tail = Enum.at(rest, puts_len)
    next = Enum.at(rest, puts_len + 1)

    cond do
      tail == nil ->
        {:ok, puts_len}

      var_ref?(tail, var) and next == nil ->
        {:ok, puts_len + 1}

      true ->
        :skip
    end
  end

  defp same_var_assignment?({:=, _, [lhs, _rhs]}, var), do: bare_var(lhs) == {:ok, var}
  defp same_var_assignment?(_, _var), do: false

  defp map_put_rebind?({:=, _, [lhs, rhs]}, var),
    do: bare_var(lhs) == {:ok, var} and match?({:ok, _, _}, map_put_call(rhs, var))

  defp map_put_rebind?(_, _var), do: false

  defp put_entry!({:=, _, [_lhs, rhs]}) do
    case map_put_call(rhs, nil) do
      {:ok, key, value} -> {key, value}
      :skip -> raise ArgumentError, "expected Map.put rebind"
    end
  end

  defp map_put_call(
         {{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [{name, _, ctx}, key, value]},
         var
       )
       when is_atom(name) and is_atom(ctx) do
    if is_nil(var) or name == var, do: {:ok, key, value}, else: :skip
  end

  defp map_put_call({:__block__, _, [single]}, var), do: map_put_call(single, var)
  defp map_put_call(_, _var), do: :skip

  defp render_literal(entries) do
    body =
      entries
      |> Enum.map_join(",\n", fn {key_text, value_text, atom_key} ->
        "  " <> render_entry(key_text, value_text, atom_key)
      end)

    "%{\n#{body}\n}"
  end

  defp render_entry(_key_text, value_text, atom) when is_atom(atom) and not is_nil(atom),
    do: Atom.to_string(atom) <> ": " <> value_text

  defp render_entry(key_text, value_text, nil), do: key_text <> " => " <> value_text

  defp atom_key({:__block__, _, [atom]}) when is_atom(atom), do: atom_key(atom)

  defp atom_key(atom) when is_atom(atom) and not is_nil(atom) do
    name = Atom.to_string(atom)

    if Regex.match?(~r/^[a-z_][a-zA-Z0-9_]*[!?]?$/, name), do: atom, else: nil
  end

  defp atom_key(_), do: nil

  defp empty_map?({:%{}, _, []}), do: true
  defp empty_map?({:__block__, _, [{:%{}, _, []}]}), do: true
  defp empty_map?(_), do: false

  defp node_text(source, node) do
    case slice_node(source, node) do
      {:ok, text} -> text
      :error -> Sourceror.to_string(node)
    end
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
