defmodule Num42.Refactors.Refactors.PipeReassign do
  @moduledoc """
  Rewrites `x = f(x, more, args)` to `x = x |> f(more, args)`.

      assigns = assign(assigns, :delete_visible, visible)
      ↓
      assigns = assigns |> assign(:delete_visible, visible)

      socket = Phoenix.LiveView.assign(socket, :k, :v)
      ↓
      socket = socket |> Phoenix.LiveView.assign(:k, :v)

  Captures the recurring LiveView/Plug pattern of threading the same
  variable through a transformation. The pipe form reads as "take
  `assigns`, apply `assign(:delete_visible, visible)`", which is the
  intent; the bare-call form forces the reader to spot that the first
  argument is the same name as the LHS before the line makes sense.

  ## Scope

  We rewrite `lhs = call(lhs, arg2, ...)` only when:

  - The LHS is a **bare variable** (`{name, _meta, ctx}` with `ctx`
    an atom). Pattern-matching LHSs (`{:ok, x} = ...`, `[h | t] = ...`)
    are skipped — there's no single name to lift to the front of a
    pipe.
  - The call has **at least two arguments**. Single-arg `x = f(x)` is
    a stylistic toss-up (`x = x |> f()` reads no clearer); leaving it
    alone keeps the rewrite limited to cases where the gain is real.
  - The call's **first argument is syntactically identical** to the
    LHS variable name. We compare names only — a shadowed local with
    the same name would also match, but in practice that's a code
    smell the rewrite doesn't make worse.
  - The RHS is **not already a pipe**. `x = x |> f(...)` is what we
    produce, so a re-run finds nothing.
  - The call is a **named function call**, not an operator
    (`x = x + 1` parses as `{:+, _, [x, 1]}` — same shape, but `+`
    isn't pipeable). We allow bare local calls (`f(...)`) and
    module-qualified calls (`Mod.f(...)` / `A.B.f(...)`) only.

  ## Source slicing

  We splice the **original source bytes** for the LHS variable and
  the rest-of-args via `Sourceror.get_range/1`. Re-emitting the AST
  via `Sourceror.to_string/1` would corrupt:

  - String escapes (`\\n` → `\\\\n`)
  - Map-access calls re-emitted with parens (`m.k` → `m.k()`)
  - Multi-line literal layouts

  Slicing keeps the user's formatting verbatim and lets `mix format`
  normalize the resulting pipe afterwards.

  ## Idempotence

  After the rewrite the line reads `x = x |> f(...)` — RHS is a pipe,
  which the rewrite explicitly skips. A second pass is a no-op.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Num42.Refactors.Refactor
  def description, do: "x = f(x, ...) -> x = x |> f(...)"

  @impl Num42.Refactors.Refactor
  def priority, do: 200

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    Threading the same variable through a chain of transformations is
    the canonical use-case for `|>`. Writing `assigns = assign(assigns,
    :k, v)` makes the reader scan for the repeated name to confirm what
    the line does; `assigns = assigns |> assign(:k, v)` reads as the
    intent ("take assigns, apply assign(:k, v)"). The pipe form also
    composes — adding a second step is appending a `|>`, not nesting
    another call around the existing one.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp advance_past_separator(_source, lines, line: l, column: c) do
    line = lines |> Enum.at(l - 1)

    if line == nil do
      nil
    else
      do_advance(lines, l, c, line)
    end
  end

  defp bare_var_name({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {:ok, name}
  defp bare_var_name(_), do: :error

  defp build_patches(ast, source),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch(&1, source))

  defp callable_with_args({name, _, args} = call)
       when is_atom(name) and is_list(args) and args != [] do
    cond do
      pipe_or_operator?(name) -> :error
      special_form?(call) -> :error
      true -> {:ok, callee_node(call), args}
    end
  end

  defp callable_with_args({{:., _, [_mod_ast, fun]}, _, args} = call)
       when is_atom(fun) and is_list(args) and args != [] do
    {:ok, callee_node(call), args}
  end

  defp callable_with_args(_), do: :error

  defp callee_node({{:., _, [mod_ast, fun]}, _meta, _args}),
    do: {{:., [], [mod_ast, fun]}, [], []}

  defp callee_node({name, _meta, _args}) when is_atom(name) do
    {name, [], nil}
  end

  defp do_advance(lines, l, c, line) do
    cond do
      c - 1 >= String.length(line) ->
        next_line = lines |> Enum.at(l)

        if next_line == nil do
          nil
        else
          do_advance(lines, l + 1, 1, next_line)
        end

      true ->
        ch = String.at(line, c - 1)

        cond do
          ch in [",", " ", "\t", "\n"] -> do_advance(lines, l, c + 1, line)
          true -> [line: l, column: c]
        end
    end
  end

  defp maybe_patch({:=, _, [lhs, rhs]} = node, source) do
    with {:ok, lhs_name} <- bare_var_name(lhs),
         {:ok, callee_ast, [first_arg | rest_args]} <- callable_with_args(rhs),
         true <- rest_args != [],
         {:ok, ^lhs_name} <- bare_var_name(first_arg),
         {:ok, lhs_text} <- render_lhs_or_callee(source, lhs),
         {:ok, callee_text} <- render_lhs_or_callee(source, callee_ast),
         {:ok, rest_text} <- slice_rest_args(source, rhs, first_arg) do
      replacement =
        "#{lhs_text} = #{lhs_text} |> #{callee_text}(" <> rest_text <> ")"

      [Patch.replace(node, replacement)]
    else
      _ -> []
    end
  end

  defp maybe_patch(_, _), do: []
  defp pipe_or_operator?(:|>), do: true

  defp pipe_or_operator?(name),
    do:
      name
      |> Atom.to_string()
      |> String.match?(~r/^[^\w]/)

  defp positions_lt?([line: l1, column: c1], line: l2, column: c2) do
    cond do
      l1 < l2 -> true
      l1 > l2 -> false
      true -> c1 < c2
    end
  end

  defp render_lhs_or_callee(_source, {name, _meta, nil}) when is_atom(name) do
    {:ok, Atom.to_string(name)}
  end

  defp render_lhs_or_callee(_source, {{:., _, [mod_ast, fun]}, _, _}) when is_atom(fun) do
    {:ok, render_mod_fun(mod_ast, fun)}
  end

  defp render_lhs_or_callee(source, node), do: slice_node(source, node)

  defp render_mod_fun({:__aliases__, _, parts}, fun),
    do: Enum.join(parts, ".") <> "." <> Atom.to_string(fun)

  defp render_mod_fun({name, _, ctx}, fun) when is_atom(name) and is_atom(ctx) do
    "#{name}.#{fun}"
  end

  defp render_mod_fun(_, fun), do: Atom.to_string(fun)

  defp slice_rest_args(source, rhs, first_arg) do
    with %{} = rhs_range <- Sourceror.get_range(rhs),
         %{} = first_range <- Sourceror.get_range(first_arg) do
      lines = String.split(source, "\n", trim: false)
      first_end = first_range.end
      rhs_end = rhs_range.end

      after_first = advance_past_separator(source, lines, first_end)

      before_close =
        case rhs_end do
          [line: l, column: c] -> [line: l, column: c - 1]
          other -> other
        end

      cond do
        after_first == nil ->
          :error

        positions_lt?(after_first, before_close) ->
          {:ok, slice_source(source, after_first, before_close)}

        true ->
          {:ok, ""}
      end
    else
      _ -> :error
    end
  end

  defp apply_patches({:ok, ast}, source),
    do: build_patches(ast, source) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
