defmodule Number42.Refactors.Ex.DebugInspectCleanup do
  @moduledoc """
  Replaces `IO.inspect` debugging calls with a deliberate debug
  primitive and drops the inspect options that only exist to label
  ad-hoc traces:

      IO.inspect(x)                →   dbg(x)
      IO.inspect(x, label: "foo")  →   dbg(x)
      x |> IO.inspect()            →   x |> dbg()
      x |> IO.inspect(label: ...)  →   x |> dbg()

  With `target: :logger` the direct form routes through `Logger`
  instead:

      IO.inspect(x)   →   Logger.debug(inspect(x))

  ## Why

  `IO.inspect/2` is the reach-for-it debugging call: it prints to
  stdout, survives into committed code, and bypasses the log level
  that production uses to stay quiet. `dbg/1` is the intentional
  successor — it's pipe-aware, shows the expression alongside its
  value, and is trivial to grep for and strip. Routing to
  `Logger.debug/1` instead keeps the trace inside the logging system
  so it honours configured levels and metadata.

  The `label:`/`limit:` options on a stray `IO.inspect` are scaffolding
  for telling two traces apart at a glance; once the call becomes a
  `dbg`, the expression itself is the label, so the options are dropped.

  ## What we match

  - `IO.inspect(expr)` and `IO.inspect(expr, opts)` — direct calls
  - `lhs |> IO.inspect()` and `lhs |> IO.inspect(opts)` — piped calls

  Only the fully-qualified `IO.inspect` is touched. `Logger.debug`,
  `Logger.info`, `IO.puts`, and bare local calls are left alone.

  The piped form always rewrites to `dbg/1` regardless of `target` —
  a `Logger.debug(inspect(...))` can't sit mid-pipe the way `dbg` can.

  ## Idempotence

  After rewriting, the call is `dbg`/`Logger.debug` — neither matches
  the `IO.inspect` shape, so a second pass is a no-op.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Number42.Refactors.Refactor
  def description, do: "Replace IO.inspect debugging with dbg/1 (or Logger.debug)"
  @impl Number42.Refactors.Refactor
  def explanation do
    """
    `IO.inspect/2` is debugging that escaped into committed code: it
    prints to stdout unconditionally, ignoring log levels, and its
    `label:` options are throwaway scaffolding for telling traces
    apart. `dbg/1` is the intentional replacement — pipe-aware, shows
    the expression with its value, and greps cleanly when it's time to
    strip the trace. `target: :logger` routes the direct form through
    `Logger.debug/1` instead so the trace honours configured levels.
    """
  end

  @impl Number42.Refactors.Refactor
  def priority, do: 110
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true
  @impl Number42.Refactors.Refactor
  def transform(source, opts), do: Sourceror.parse_string(source) |> apply_patches(source, opts)
  defp apply_patches({:ok, ast}, source, opts), do: build_patches(ast, opts) |> patch(source)
  defp apply_patches({:error, _}, source, _opts), do: source

  defp build_patches(ast, opts) do
    target = Keyword.get(opts, :target, :dbg)

    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&maybe_patch(&1, target))
  end

  defp maybe_patch(
         {:|>, _, [lhs, {{:., _, [{:__aliases__, _, [:IO]}, :inspect]}, _, _}]} = node,
         _target
       ),
       do: [Patch.replace(node, "#{Sourceror.to_string(lhs)} |> dbg()")]

  defp maybe_patch({{:., _, [{:__aliases__, _, [:IO]}, :inspect]}, _, [expr | _]} = node, target),
    do: [Patch.replace(node, render_direct(target, expr))]

  defp maybe_patch(_node, _target), do: []

  defp render_direct(:logger, expr), do: "Logger.debug(inspect(#{Sourceror.to_string(expr)}))"
  defp render_direct(_dbg, expr), do: "dbg(#{Sourceror.to_string(expr)})"

  defp patch([], source), do: source
  defp patch(patches, source), do: Sourceror.patch_string(source, patches)
end
