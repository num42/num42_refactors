defmodule Number42.Refactors.Ex.EnumCapture do
  @moduledoc """
  Rewrites single-call `fn` arguments to `Enum`/`Stream` higher-order
  functions into `&`-capture form:

      Enum.map(list, fn x -> foo(x) end)
      ↓
      Enum.map(list, &foo(&1))

      list |> Enum.filter(fn %{age: a} -> a > 18 end)
      ↓
      list |> Enum.filter(&(&1.age > 18))

  Mirrors the `Credo.Check.Refactor.PipeChainStart`-adjacent style
  preference: when a lambda body is a single expression that just
  forwards/projects its argument, the capture form is shorter and
  clearer.

  ## When this fires

  Lambda must:

  - have exactly one clause (no `fn x -> a; y -> b end`)
  - have a single-statement body (no `;`-separated sequence)
  - body references each lambda argument either as a bare variable
    or via a *supported* pattern-match destructure (see below)

  Pattern destructures supported in Stage 1:

  - bare variable: `fn x -> ... end` → `x` becomes `&1`
  - map shorthand: `fn %{key: v} -> ... end` → `v` becomes `&1.key`
  - whole-binding: `fn %{...} = whole -> ... end` → `whole` becomes `&1`,
    inner keys still resolve via the map pattern

  Anything else (tuples, lists, structs, nested patterns, guards) is
  skipped — the body's lambda is left as-is.

  ## Why we limit the host functions

  Only Enum/Stream HOFs whose lambda is unambiguously single-arg or
  two-arg (reduce-style) are rewritten. We don't touch
  `Enum.reduce_while`, `Enum.zip_with`, etc., where capture form would
  be ambiguous to read.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Convert single-call lambdas in Enum/Stream HOFs to &-capture form"

  @impl Number42.Refactors.Refactor
  def priority, do: 150

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `fn x -> f(x) end` is a roundabout way of saying "use `f`" — three
    extra tokens and a fresh binding for an operation that already has a
    name. The capture form `&f/1` says the same thing and reads as a
    function value, which is what an HOF argument is supposed to be. The
    payoff is mostly readability and uniformity across the codebase.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  # Map of host-fn name => lambda arity. Only these are rewritten.
  # `Enum.reduce/3` is intentionally absent — `&(&2 + &1)` reverses the
  # `(elem, acc)` order and reads worse than the lambda form. Same for
  # `reduce_while`, `zip_with`, etc.
  @host_fns %{
    all?: 1,
    any?: 1,
    count: 1,
    drop_while: 1,
    each: 1,
    filter: 1,
    find: 1,
    find_index: 1,
    find_value: 1,
    flat_map: 1,
    group_by: 1,
    map: 1,
    max_by: 1,
    min_by: 1,
    reject: 1,
    sort_by: 1,
    split_with: 1,
    take_while: 1,
    uniq_by: 1
  }

  @host_modules [:Enum, :Stream]

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  # Walk the AST top-down. When we emit a patch for a node, do NOT
  # descend into its children — nested `Enum.<fn>` calls would each
  # generate their own patch, and overlapping patches inside the same
  # outer rewrite produce malformed output. The fixpoint loop in
  # `Number42.Refactors.Engine` reruns the refactor, so the inner
  # rewrites land on the next pass.
  #
  # We track three contextual flags as we descend:
  #
  # - `in_capture?`: are we inside a `&...`-capture subtree? Elixir
  #   disallows nested captures, so any `Enum.<fn>` call whose lambda
  #   we'd rewrite into another capture must be skipped here. The
  #   lambda form is legal there; the capture form would not compile.
  #
  # - `in_pipe?`: are we already a pipe stage? If so, we do NOT also
  #   pipe the collection into the call — `a |> Enum.map(coll |>
  #   Enum.filter(...))` is nonsense. Only call sites at the outer
  #   "expression" level get the coll-pipe rewrite; lambda-only
  #   rewrites (replacing `fn ... end` with `&...`) are unaffected.
  #
  # - `pipe_unsafe?`: is the immediate parent an operator that would
  #   reorder against a newly-introduced `|>`? Pipe has very low
  #   precedence; injecting one inside an `++`/`+`/`==`/etc. operand
  #   silently re-associates the surrounding expression. We disable
  #   the coll-pipe rewrite in those positions (lambda-only is still
  #   fine) and let the lambda survive as-is.
  defp build_patches(ast),
    do: ast |> walk_collecting_patches(false, false, false, []) |> Enum.reverse()

  defp build_slot_map(fn_args) do
    fn_args
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn {arg, slot}, {:ok, acc} ->
      case extract_bindings(arg, slot) do
        {:ok, bindings} ->
          merged = Map.merge(acc, bindings)

          if map_size(merged) == map_size(acc) + map_size(bindings) do
            {:cont, {:ok, merged}}
          else
            # Two args bind the same name — bail out, can't disambiguate.
            {:halt, :skip}
          end

        :skip ->
          {:halt, :skip}
      end
    end)
  end

  defp children({_, _, args}) when is_list(args), do: args
  defp children({left, right}), do: [left, right]
  defp children(list) when is_list(list), do: list
  defp children(_), do: []

  defp ensure_no_capture_conflict(body) do
    has_conflict? =
      body
      |> Macro.prewalker()
      |> Enum.any?(fn
        {:&, _, _} -> true
        _ -> false
      end)

    if has_conflict?, do: :skip, else: :ok
  end

  defp ensure_no_pipe_in_body(body) do
    has_pipe? =
      body
      |> Macro.prewalker()
      |> Enum.any?(fn
        {:|>, _, _} -> true
        _ -> false
      end)

    if has_pipe?, do: :skip, else: :ok
  end

  defp ensure_not_top_level_match({:=, _, _}), do: :skip
  defp ensure_not_top_level_match(_), do: :ok
  defp ensure_single_statement({:__block__, _, exprs}) when length(exprs) > 1, do: :skip
  defp ensure_single_statement(_), do: :ok

  defp extract_bindings({name, _, ctx}, slot) when is_atom(name) and is_atom(ctx) do
    if String.starts_with?(Atom.to_string(name), "_") do
      # Underscore: nothing to bind, but slot is consumed.
      {:ok, %{}}
    else
      {:ok, %{name => slot_ast(slot)}}
    end
  end

  defp extract_bindings({:%{}, _, pairs}, slot) do
    pairs
    |> Enum.reduce_while({:ok, %{}}, fn pair, {:ok, acc} ->
      with {:ok, key} <- pair_key(pair),
           {:ok, var_name} <- pair_var(pair) do
        if String.starts_with?(Atom.to_string(var_name), "_") do
          {:cont, {:ok, acc}}
        else
          {:cont, {:ok, Map.put(acc, var_name, projection_ast(slot, key))}}
        end
      else
        # Nested pattern (`%{key: %{...}}`, `%{key: [a, b]}`, etc.) or
        # non-atom key — too complex for stage 1.
        :skip -> {:halt, :skip}
      end
    end)
  end

  defp extract_bindings({:=, _, [left, right]}, slot) do
    {map_part, var_part} =
      case {left, right} do
        {{:%{}, _, _} = m, {v, _, c} = w} when is_atom(v) and is_atom(c) -> {m, w}
        {{v, _, c} = w, {:%{}, _, _} = m} when is_atom(v) and is_atom(c) -> {m, w}
        _ -> {nil, nil}
      end

    case {map_part, var_part} do
      {nil, _} ->
        :skip

      {map_ast, {whole_name, _, _}} ->
        map_ast
        |> extract_bindings(slot)
        |> case do
          {:ok, inner} ->
            if String.starts_with?(Atom.to_string(whole_name), "_") do
              {:ok, inner}
            else
              {:ok, Map.put(inner, whole_name, slot_ast(slot))}
            end

          other ->
            other
        end
    end
  end

  defp extract_bindings(_pattern, _slot), do: :skip
  defp lambda_only(_node), do: :no_patch
  defp maybe_patch_for(node, in_capture?, _in_pipe?) when in_capture?, do: lambda_only(node)

  defp maybe_patch_for(
         {{:., _, [{:__aliases__, _, [mod]}, fun]}, _meta, args} = call_node,
         _,
         in_pipe?
       )
       when mod in @host_modules and is_atom(fun) and is_list(args) do
    with {:ok, arity} <- Map.fetch(@host_fns, fun),
         {:fn, _, [{:->, _, [fn_args, body]}]} = fn_node <- List.last(args),
         true <- length(fn_args) == arity,
         {:ok, capture_text} <- try_capture(fn_args, body) do
      cond do
        not in_pipe? and length(args) == 2 ->
          [coll, _lambda] = args
          coll_text = Sourceror.to_string(coll)
          mod_str = Atom.to_string(mod)
          fun_str = Atom.to_string(fun)
          replacement = "#{coll_text} |> #{mod_str}.#{fun_str}(#{capture_text})"
          {:patch, Patch.replace(call_node, replacement)}

        true ->
          {:patch, Patch.replace(fn_node, capture_text)}
      end
    else
      _ -> :no_patch
    end
  end

  defp maybe_patch_for(_, _, _), do: :no_patch
  defp pair_key({{:__block__, _, [key]}, _}) when is_atom(key), do: {:ok, key}
  defp pair_key({key, _}) when is_atom(key), do: {:ok, key}
  defp pair_key(_), do: :skip

  defp pair_var({_, {var_name, _, ctx}}) when is_atom(var_name) and is_atom(ctx),
    do: {:ok, var_name}

  defp pair_var(_), do: :skip

  defp projection_ast(slot, key), do: {{:., [], [slot_ast(slot), key]}, [no_parens: true], []}

  defp rewrite_body(body, slot_map) do
    rewritten =
      Macro.prewalk(body, fn
        {name, _meta, ctx} = node when is_atom(name) and is_atom(ctx) ->
          case Map.fetch(slot_map, name) do
            {:ok, replacement} -> replacement
            :error -> node
          end

        node ->
          node
      end)

    {:ok, rewritten}
  end

  defp slot_ast(n), do: {:&, [], [n]}

  defp try_capture(fn_args, body) do
    with :ok <- ensure_single_statement(body),
         :ok <- ensure_not_top_level_match(body),
         :ok <- ensure_no_pipe_in_body(body),
         :ok <- ensure_no_control_flow(body),
         {:ok, slot_map} <- build_slot_map(fn_args),
         :ok <- ensure_no_capture_conflict(body),
         {:ok, rewritten} <- rewrite_body(body, slot_map),
         :ok <- ensure_uses_slot(rewritten) do
      case ensure_simple_capture_shape(rewritten) do
        :ok ->
          text = "&" <> wrap_capture_body(rewritten)
          {:ok, text}

        other ->
          other
      end
    end
  end

  # `fn _ -> :literal end`-style lambdas have no reference to any
  # lambda parameter, so `rewrite_body/2` leaves the body untouched
  # — no `&N` slot ever appears in the result. The capture form `&(...)`
  # would then be `&(:literal)` / `&(0)` / `&(default)`, which is not
  # legal capture syntax: the `&` operator requires either a remote/
  # local function reference or a body that contains at least one
  # `&1`/`&2`/... slot. Leave the lambda as-is in that case.
  defp ensure_uses_slot(ast) do
    has_slot? =
      ast
      |> Macro.prewalker()
      |> Enum.any?(fn
        {:&, _, [n]} when is_integer(n) -> true
        _ -> false
      end)

    if has_slot?, do: :ok, else: :skip
  end

  # Body-shape gates that check what the *capture* expression would
  # look like — rejected shapes stay as `fn` because the capture form
  # reads worse than the lambda.
  #
  # `ensure_no_control_flow`: reject `case`/`if`/`cond`/`fn`/`with`/
  # `try`/`receive` anywhere in the body. The lambda form gives those
  # constructs a name (`fn` is "the function I'm passing"), the capture
  # form turns them into `&(case &1 do ... end)` which is unreadable.
  defp ensure_no_control_flow(body) do
    has_control? =
      body
      |> Macro.prewalker()
      |> Enum.any?(fn
        {kw, _, _} when kw in [:case, :cond, :if, :unless, :with, :try, :receive, :fn] -> true
        _ -> false
      end)

    if has_control?, do: :skip, else: :ok
  end

  # Reject capture shapes that read worse than the lambda:
  #
  # - the bare slot (`& &1` for `fn x -> x end`) — pointless. The
  #   lambda was already silly; we just leave it alone.
  #
  # - an operator with non-trivial expressions on both sides
  #   (`f(&1) <op> g(&1)`, `&1.a == &1.b`). The capture loses the
  #   named binding that made the relationship between the two sides
  #   readable. "Non-trivial" = a call or a field access.
  defp ensure_simple_capture_shape({:&, _, [n]}) when is_integer(n), do: :skip

  defp ensure_simple_capture_shape({op, _, [lhs, rhs]})
       when op in [
              :+,
              :-,
              :*,
              :/,
              :==,
              :!=,
              :===,
              :!==,
              :>,
              :<,
              :>=,
              :<=,
              :<>,
              :++,
              :and,
              :or,
              :&&,
              :||,
              :in
            ] do
    if call_node?(lhs) and call_node?(rhs), do: :skip, else: :ok
  end

  # Sourceror wraps the body's top-level expression in
  # `{:__block__, _, [actual]}`. Unwrap once before classifying.
  defp ensure_simple_capture_shape({:__block__, _, [inner]}),
    do: ensure_simple_capture_shape(inner)

  # Collection literals (`{...}`, `[...]`, `%{...}`, `%S{...}`) with
  # the slot referenced more than once read poorly as captures —
  # `&({label(&1), &1})` makes the eye chase the slot through every
  # position. The lambda's named binding (`v`) keeps that obvious.
  defp ensure_simple_capture_shape({:{}, _, _} = node), do: check_slot_count(node)
  defp ensure_simple_capture_shape({_a, _b} = node), do: check_slot_count(node)
  defp ensure_simple_capture_shape({:%{}, _, _} = node), do: check_slot_count(node)
  defp ensure_simple_capture_shape({:%, _, _} = node), do: check_slot_count(node)
  defp ensure_simple_capture_shape(node) when is_list(node), do: check_slot_count(node)
  defp ensure_simple_capture_shape(_), do: :ok

  defp check_slot_count(node) do
    count =
      node
      |> Macro.prewalker()
      |> Enum.count(fn
        {:&, _, [n]} when is_integer(n) -> true
        _ -> false
      end)

    if count > 1, do: :skip, else: :ok
  end

  # "Non-trivial" side of an operator: a call (`f(...)`, `M.f(...)`) or
  # a field access (`x.field`). Anything that's a bare variable or a
  # literal is "trivial". Sourceror wraps bare literals in
  # `{:__block__, _, [literal]}`; that's not a call.
  defp call_node?({:__block__, _, _}), do: false
  defp call_node?({fname, _, args}) when is_atom(fname) and is_list(args), do: true
  defp call_node?({{:., _, _}, _, _}), do: true
  defp call_node?(_), do: false

  defp walk_collecting_patches(node, in_capture?, in_pipe?, pipe_unsafe?, acc),
    do:
      maybe_patch_for(node, in_capture?, in_pipe? or pipe_unsafe?)
      |> patch_or_descend(acc, in_capture?, in_pipe?, node)

  defp wrap_capture_body(ast) do
    text = Sourceror.to_string(ast, locals_without_parens: [])
    "(" <> text <> ")"
  end

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch_or_descend(
         {:patch, patch},
         acc,
         _in_capture?,
         _in_pipe?,
         _node
       ),
       do: [patch | acc]

  defp patch_or_descend(:no_patch, acc, in_capture?, in_pipe?, node) do
    next_in_capture? = in_capture? or match?({:&, _, _}, node)

    case node do
      {:|>, _, [lhs, rhs]} ->
        acc = walk_collecting_patches(lhs, next_in_capture?, in_pipe?, false, acc)
        walk_collecting_patches(rhs, next_in_capture?, true, false, acc)

      {op, _, args} when pipe_unsafe_op?(op) and is_list(args) ->
        args
        |> Enum.reduce(acc, fn child, acc ->
          walk_collecting_patches(child, next_in_capture?, false, true, acc)
        end)

      _ ->
        node
        |> children()
        |> Enum.reduce(acc, fn child, acc ->
          walk_collecting_patches(child, next_in_capture?, false, false, acc)
        end)
    end
  end

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
