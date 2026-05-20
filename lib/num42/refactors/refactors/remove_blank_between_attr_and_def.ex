defmodule Num42.Refactors.Refactors.RemoveBlankBetweenAttrAndDef do
  @moduledoc """
  Removes blank lines between a function-attached attribute (`@impl`,
  `@doc`, `@spec`, `@deprecated`, `@dialyzer`, `@typedoc`, `@since`)
  and the `def`/`defp` it belongs to.

      @impl true
                       <- this blank line confuses the compiler
      def init(opts), do: opts

      ↓

      @impl true
      def init(opts), do: opts

  When an attribute is separated by a blank line from its function,
  the compiler emits "module attribute @impl was not set" warnings —
  the binding is broken and `--warnings-as-errors` builds fail.

  ## Why pure-text

  This is a one-shot whitespace fixup, not a structural change. We
  scan the source line by line and elide any blank line that sits
  directly between an `@<attached>` line and a `def`/`defp` line at
  the same indentation. No AST parse needed; the rule is purely
  textual.

  ## Idempotence

  After a rewrite, the blank lines are gone — a second pass finds
  no more candidates and changes nothing.
  """

  use Num42.Refactors.Refactor

  @attached_attrs ~w(impl spec doc deprecated dialyzer typedoc since)

  @impl Num42.Refactors.Refactor
  def description, do: "Strip blank lines between function-attached attributes and their def"

  @impl Num42.Refactors.Refactor
  def priority, do: 10

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    `@doc`, `@spec`, `@impl` etc. belong to the `def` immediately
    below them — that's how the language ties them. A blank line in
    between visually breaks that pairing and lets the reader's eye
    treat them as separate items. Removing the blank keeps the
    attribute group glued to its definition so attribute and signature
    read as one unit.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: false
  @impl Num42.Refactors.Refactor
  def transform(source, _opts) do
    attr_re = Regex.compile!("^(\\s+)@(?:#{@attached_attrs |> Enum.join("|")})\\b")

    lines = String.split(source, "\n")
    result = walk(lines, attr_re, [])

    if result == lines do
      source
    else
      result |> Enum.join("\n")
    end
  end

  defp def_at_indent?(line, indent),
    do: Regex.compile!("^#{indent}defp?\\b") |> Regex.match?(line)

  defp walk([attr, blank, defp_line | rest], attr_re, acc) do
    with [_, indent] <- Regex.run(attr_re, attr),
         true <- blank == "" or String.trim(blank) == "",
         true <- def_at_indent?(defp_line, indent) do
      walk([defp_line | rest], attr_re, [attr | acc])
    else
      _ -> walk([blank, defp_line | rest], attr_re, [attr | acc])
    end
  end

  defp walk([line | rest], attr_re, acc), do: walk(rest, attr_re, [line | acc])
  defp walk([], _attr_re, acc), do: acc |> Enum.reverse()
end
