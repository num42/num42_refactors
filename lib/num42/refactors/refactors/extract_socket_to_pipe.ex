defmodule Num42.Refactors.Refactors.ExtractSocketToPipe do
  @moduledoc """
  Rewrites any call whose first argument is the bare `socket` variable
  into pipe form:

      assign(socket, :k, v)
      ↓
      socket |> assign(:k, v)

      Phoenix.LiveView.assign(socket, :k, v)
      ↓
      socket |> Phoenix.LiveView.assign(:k, v)

  ## When this fires

  Any local call `f(socket, ...)` or remote call `Mod.f(socket, ...)`
  whose **first argument is exactly the variable `socket`** (AST
  shape `{:socket, _, nil}`). Single-arg calls become
  `socket |> f()`, matching codebase pipe style.

  ## When it does not fire

  - First arg is anything other than the bare `socket` variable
    (`socket.assigns`, `conn`, `%{}`). The pipe sugar would shift
    semantics or read worse.
  - The call is already a pipe stage (`socket |> assign(...)`); the
    first arg is the implicit pipe input, rewriting would double up.
  - The call sits in a pipe-unsafe operand position (`++`, `==`,
    `and`, `<>`, ...). Pipe has very low precedence and would
    silently re-associate.
  - The call is inside a `&`-capture; rewriting produces `&socket |>
    f(...)` which lexer-collides with `&&`. Same hazard as
    `ExtractToPipeline`.
  - The call is inside a `^`-pin (Ecto query macros). The pin expects
    a value/variable, not a pipe expression.
  - The function being called is itself named `socket`. Rewriting
    `socket(socket, opts)` to `socket |> socket(opts)` is technically
    valid but confusing — leave the human to decide.

  ## Why procedural

  Same shape as `ExtractToPipeline`: needs the source slice of every
  arg plus context flags (`in_pipe?`, `pipe_unsafe?`, `in_capture?`)
  threaded through a manual walk. The declarative DSL can't express
  the "first arg is exactly `socket`" precondition together with the
  contextual skips.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Num42.Refactors.Refactor
  def description, do: "any_function(socket, ...) -> socket |> any_function(...)"

  @impl Num42.Refactors.Refactor
  def priority, do: 200

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    Phoenix LiveView code threads `socket` through long chains of
    `assign`, `put_flash`, `push_event`, etc. The call form
    `assign(socket, :k, v)` reads outside-in; the pipe form
    `socket |> assign(:k, v)` matches how the data actually flows and
    composes naturally with the surrounding chain. The codebase
    already prefers the pipe form for socket transforms; this rewrite
    extends that preference to single-call sites for consistency.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_patches(ast), do: ast |> walk(false, false, false, []) |> Enum.reverse()

  # Three contextual flags, mirrored from `ExtractToPipeline`:
  #
  # - `in_pipe?`: this node is the RHS of a `|>`. The call already has
  #   its first arg piped in implicitly; rewriting would double up.
  #
  # - `pipe_unsafe?`: the immediate parent matches `pipe_unsafe_op?/1`
  #   operator. Introducing a `|>` here would re-associate the
  #   surrounding expression. Skip the rewrite, descend with the flag
  #   reset.
  #
  # - `in_capture?`: we're inside a `&...`-capture. Elixir forbids `|>`
  #   directly inside a capture (and the lexer eats `&&` as boolean
  #   and), so any rewrite here would emit unparseable text.
  defp walk(node, in_pipe?, pipe_unsafe?, in_capture?, acc),
    do:
      maybe_patch(node, in_pipe?, pipe_unsafe?, in_capture?)
      |> walk_maybe_patch(acc, in_capture?, node)

  defp descend({:|>, _, [lhs, rhs]}, in_capture?, acc) do
    acc = walk(lhs, false, false, in_capture?, acc)
    walk(rhs, true, false, in_capture?, acc)
  end

  # Function/macro definitions: the head shares the AST shape of a
  # local call (`{name, _, args}`), so without this clause the walker
  # would try to pipe-rewrite the def's name (`def socket |> foo(x)` —
  # invalid). Skip the head; descend into all body clauses so calls
  # inside the function (incl. `rescue:`, `catch:`, `else:`, `after:`)
  # are still rewriting candidates.
  defp descend({def_kind, _, [_head, body_kw]}, in_capture?, acc)
       when def_or_macro_kind?(def_kind) and is_list(body_kw) do
    body_kw
    |> Enum.reduce(acc, fn {_clause, body}, acc ->
      walk(body, false, false, in_capture?, acc)
    end)
  end

  # Header-only `def foo(...)` (used in @callback, behaviours, specs
  # without a body). No body to descend into — leave alone.
  defp descend({def_kind, _, [_head]}, _in_capture?, acc)
       when def_or_macro_kind?(def_kind) do
    acc
  end

  defp descend({op, _, args}, in_capture?, acc) when pipe_unsafe_op?(op) and is_list(args) do
    args |> Enum.reduce(acc, fn child, acc -> walk(child, false, true, in_capture?, acc) end)
  end

  # Same reasoning as `ExtractToPipeline`: never rewrite under a `^`
  # pin operator. Ecto query macros require the pin to wrap a
  # value/variable directly, and `^` binds tighter than `|>`.
  defp descend({:^, _, args}, in_capture?, acc) when is_list(args) do
    args |> Enum.reduce(acc, fn child, acc -> walk(child, false, true, in_capture?, acc) end)
  end

  defp descend(node, in_capture?, acc) do
    node
    |> children()
    |> Enum.reduce(acc, fn child, acc -> walk(child, false, false, in_capture?, acc) end)
  end

  defp children({_, _, args}) when is_list(args), do: args
  defp children({left, right}), do: [left, right]
  defp children(list) when is_list(list), do: list
  defp children(_), do: []

  defp maybe_patch(_node, true, _, _), do: :no_patch
  defp maybe_patch(_node, _, true, _), do: :no_patch
  defp maybe_patch(_node, _, _, true), do: :no_patch

  # Local call: `f(socket, ...)` where `f` is an atom function name.
  # Three rejections:
  #   - operators (`=`, `<-`, `++`, ...) share the AST shape of a call
  #     but emit invalid syntax when rewritten as a pipe (`socket |> =(...)`).
  #     `Macro.operator?/2` is the source of truth.
  #   - `fun == :socket` would rewrite `socket(socket, opts)` to
  #     `socket |> socket(opts)` — valid but confusing.
  #   - `fun == :|>` is the pipe operator itself; the `in_pipe?` flag
  #     handles the RHS but the node itself must not be treated as a call.
  defp maybe_patch({fun, _, [first | rest] = args} = node, _, _, _)
       when is_atom(fun) and fun != :socket and fun != :|> do
    cond do
      Macro.operator?(fun, length(args)) -> :no_patch
      socket_var?(first) -> patch_for(node, fun_str_local(fun), rest)
      true -> :no_patch
    end
  end

  # Remote call: `Mod.f(socket, ...)` (any alias chain).
  defp maybe_patch(
         {{:., _, [_callee, fun]}, _, [first | rest]} = node,
         _,
         _,
         _
       )
       when is_atom(fun) do
    if socket_var?(first) do
      patch_for(node, fun_str_remote(node), rest)
    else
      :no_patch
    end
  end

  defp maybe_patch(_, _, _, _), do: :no_patch

  defp socket_var?({:socket, _, nil}), do: true
  defp socket_var?(_), do: false

  defp patch_for(node, head, rest), do: render_rest(rest) |> patch_for_render_rest(head, node)

  defp fun_str_local(fun), do: Atom.to_string(fun)

  defp fun_str_remote({{:., _, [callee, fun]}, _, _}),
    do: "#{Sourceror.to_string(callee)}.#{Atom.to_string(fun)}"

  defp render_rest([]), do: {:ok, ""}

  defp render_rest(args) do
    parts = args |> Enum.map(&Sourceror.to_string/1)
    {:ok, parts |> Enum.join(", ")}
  rescue
    _ -> :error
  end

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp walk_maybe_patch({:patch, patch}, acc, _in_capture?, _node), do: [patch | acc]

  defp walk_maybe_patch(:no_patch, acc, in_capture?, node) do
    next_in_capture? = in_capture? or match?({:&, _, _}, node)
    descend(node, next_in_capture?, acc)
  end

  defp patch_for_render_rest({:ok, rest_text}, head, node) do
    replacement = "socket |> #{head}(#{rest_text})"
    {:patch, Patch.replace(node, replacement)}
  end

  defp patch_for_render_rest(_, _head, _node), do: :no_patch

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
