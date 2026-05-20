defmodule Num42.Refactors.Refactors.ExtractToPipeline do
  @moduledoc """
  Rewrites `Enum.<fn>(coll, ...)` and `Stream.<fn>(coll, ...)` call
  forms into pipe form: `coll |> Enum.<fn>(...)`.

      Enum.map(list, fun)
      ↓
      list |> Enum.map(fun)

      Enum.to_list(Stream.filter(list, pred))
      ↓
      Stream.filter(list, pred) |> Enum.to_list()

  ## When this fires

  Any `Enum.f(arg1, ...)` or `Stream.f(arg1, ...)` call with at least
  one argument and that is **not already a pipe stage** (i.e. not on
  the RHS of `|>`). Single-arg calls become `coll |> Enum.f()` —
  parens preserved, matching codebase style.

  ## When it does not fire

  - The call is already a pipe stage (`x |> Enum.map(fun)`). The
    first arg is the implicit pipe input; rewriting would shift it.
  - The call sits in a **pipe-unsafe** parent expression (operand of
    `++`, `+`, `==`, `and`, `<>`, etc.). Pipe has very low precedence;
    introducing one inside an operator silently re-associates the
    expression. Better to leave the call form than emit subtly wrong
    code.
  - Zero-arg calls — nothing to extract.

  ## Why procedural

  Rewriting needs the source slice of the first arg (to preserve the
  user's exact formatting) plus the remaining args, plus context about
  whether we're inside a pipe or an unsafe operator. That's three flags
  threaded through a manual walk; a 1:1 declarative pattern can't
  express the "not in pipe / not in unsafe op" preconditions cleanly.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Num42.Refactors.Refactor
  def description, do: "Enum/Stream call form -> pipe form (extract first arg)"

  @impl Num42.Refactors.Refactor
  def priority, do: 180

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    `Enum.map(list, fun)` reads as "apply map(list, fun)"; `list |>
    Enum.map(fun)` reads as "take list, then map it". The pipe form
    matches how the data actually flows and composes naturally with
    further stages. The codebase already prefers the pipe form for
    multi-stage chains; this rewrite extends that preference to
    single-call sites for consistency.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true

  @host_modules [:Enum, :Stream]

  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_patches(ast), do: ast |> walk(false, false, false, []) |> Enum.reverse()

  # Three contextual flags:
  #
  # - `in_pipe?`: this node is the RHS of a `|>`. The Enum/Stream call
  #   already has its first arg piped in implicitly; rewriting would
  #   double-extract.
  #
  # - `pipe_unsafe?`: the immediate parent matches `pipe_unsafe_op?/1`.
  #   Introducing a `|>` here would re-associate the surrounding
  #   expression. Skip the rewrite, descend into operands with the
  #   flag reset (a NESTED Enum call that's not itself unsafe is fine
  #   to extract — the unsafe-ness was about the operator's direct
  #   operand position).
  #
  # - `in_capture?`: we're inside a `&...`-capture subtree. Elixir
  #   forbids `|>` directly inside a capture (and the lexer eats `&&`
  #   as a single boolean operator), so any rewrite here would emit
  #   unparseable text like `&&1 |> Enum.join(".")`. Lambda HOFs
  #   inside a capture stay as-is.
  defp walk(node, in_pipe?, pipe_unsafe?, in_capture?, acc),
    do:
      maybe_patch(node, in_pipe?, pipe_unsafe?, in_capture?)
      |> patch_or_descend(acc, in_capture?, node)

  defp descend({:|>, _, [lhs, rhs]}, in_capture?, acc) do
    acc = walk(lhs, false, false, in_capture?, acc)
    walk(rhs, true, false, in_capture?, acc)
  end

  defp descend({op, _, args}, in_capture?, acc) when pipe_unsafe_op?(op) and is_list(args) do
    args |> Enum.reduce(acc, fn child, acc -> walk(child, false, true, in_capture?, acc) end)
  end

  # `^expr` is the Ecto/macro pin operator. Two reasons we never
  # rewrite under it:
  #   1. `^` binds tighter than `|>`, so `^coll |> Enum.map(...)`
  #      parses as `(^coll) |> Enum.map(...)` — wrong association.
  #   2. Ecto's query macros require the pin to wrap a value/variable
  #      directly; even a parenthesized pipe wouldn't survive the
  #      macro's traversal.
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

  defp maybe_patch(
         {{:., _, [{:__aliases__, _, [mod]}, fun]}, _, args} = node,
         _in_pipe?,
         _pipe_unsafe?,
         _in_capture?
       )
       when mod in @host_modules and is_atom(fun) and is_list(args) and args != [] do
    [first | rest] = args

    with {:ok, first_text} <- slice_node_or_render(first),
         {:ok, rest_text} <- render_rest(rest) do
      mod_str = Atom.to_string(mod)
      fun_str = Atom.to_string(fun)
      lhs = wrap_if_low_precedence(first, first_text)
      replacement = "#{lhs} |> #{mod_str}.#{fun_str}(#{rest_text})"
      {:patch, Patch.replace(node, replacement)}
    else
      _ -> :no_patch
    end
  end

  defp maybe_patch(_, _, _, _), do: :no_patch

  # When the first arg is a low-precedence operator (`||`, `&&`, `or`,
  # `++`, ...), the bare text would re-associate with the new `|>`:
  # `a || b |> Enum.f(...)` parses as `a || (b |> Enum.f(...))`. Wrap
  # to force the intended precedence; the formatter strips redundant
  # parens afterwards.
  defp wrap_if_low_precedence({op, _, args}, text) when pipe_unsafe_op?(op) and is_list(args) do
    "(#{text})"
  end

  defp wrap_if_low_precedence(_node, text), do: text

  # Sourceror.to_string preserves more formatting than Macro.to_string
  # (string escapes, comments inside expressions, parens). We don't
  # need byte-exact source slices here because the engine reformats
  # afterwards; but to_string keeps trailing-arg shapes (e.g. multi-line
  # do-blocks, captured functions) faithfully enough for the result
  # to compile.
  defp slice_node_or_render(node) do
    {:ok, Sourceror.to_string(node)}
  rescue
    _ -> :error
  end

  defp render_rest([]), do: {:ok, ""}

  defp render_rest(args) do
    parts = args |> Enum.map(&Sourceror.to_string/1)
    {:ok, parts |> Enum.join(", ")}
  rescue
    _ -> :error
  end

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch_or_descend({:patch, patch}, acc, _in_capture?, _node), do: [patch | acc]

  defp patch_or_descend(:no_patch, acc, in_capture?, node) do
    next_in_capture? = in_capture? or match?({:&, _, _}, node)
    descend(node, next_in_capture?, acc)
  end

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
