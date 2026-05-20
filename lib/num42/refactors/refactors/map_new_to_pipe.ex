defmodule Num42.Refactors.Refactors.MapNewToPipe do
  @moduledoc """
  Rewrites `Map.new(coll)` to `coll |> Map.new()` so the build step
  reads as the tail of whatever produced `coll`, in line with the
  codebase's pipe-first style.

  ## What fires

  Only `Map.new/1` with a non-literal argument:

      Map.new(items_for_brand(brand))
      ↓
      items_for_brand(brand) |> Map.new()

  ## Skipped

  - `Map.new(%{...})` / `Map.new([...])` — literal arguments read
    worse as a pipe (`%{a: 1} |> Map.new()` is just noise).
  - `Map.new(coll, fn ... end)` (arity-2) — the mapper-form is a
    different transformation; piping the collection while the mapper
    sits as the second arg is its own stylistic call.
  - `Map.new()` (arity-0) — there's nothing to pipe.
  - `x |> Map.new()` — already piped; the `Map.new` AST node here is
    arity-0 (the pipe inserts the LHS at compile-time), so the
    arity-1 antipattern doesn't match.
  - `x |> Map.new(fn ... end)` and `x |> Map.new(&{&1.k, &1})` — both
    pipe into the arity-2 form. The pipe sugar makes them look like
    `Map.new(fn)` / `Map.new(&...)` (arity-1) at the AST level, with
    the lambda/capture as the apparent collection. Rejected via
    explicit guards on the argument shape so we don't produce
    `x |> fn ... end |> Map.new()` or the equivalent with `&`.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Num42.Refactors.Refactor
  def description, do: "Map.new(coll) -> coll |> Map.new()"

  @impl Num42.Refactors.Refactor
  def priority, do: 130

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    `Map.new(coll)` reads outside-in: the reader sees "build a map" and
    then has to scan inward to find what's being built from. When `coll`
    is itself a multi-step expression — `items_for_brand(brand)`,
    `Enum.zip(ks, vs)` — the call site forces the eye to jump back and
    forth. Piping (`coll |> Map.new()`) inverts the order to inside-out:
    "produce coll, turn it into a map", which matches how the data
    actually flows and how the rest of the codebase chains
    transformations.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp maybe_patch({{:., _, [{:__aliases__, _, [:Map]}, :new]}, _, [coll]} = node) do
    if pipe_friendly?(coll) do
      lhs = wrap_if_low_precedence(coll, Sourceror.to_string(coll))
      [Patch.replace(node, "#{lhs} |> Map.new()")]
    else
      []
    end
  end

  defp maybe_patch(_), do: []

  # When the collection is a low-precedence operator (`||`, `&&`, `or`,
  # `++`, `<>`, ...), the bare text would re-associate with the new
  # `|>`: `a || b |> Map.new()` parses as `a || (b |> Map.new())`.
  # Wrap to force the intended precedence; the formatter strips redundant
  # parens afterwards.
  defp wrap_if_low_precedence({op, _, args}, text) when pipe_unsafe_op?(op) and is_list(args) do
    "(#{text})"
  end

  defp wrap_if_low_precedence(_node, text), do: text

  # Skip when the argument shape would produce noisy/invalid pipe output.
  defp pipe_friendly?({:%{}, _, _}), do: false
  defp pipe_friendly?({:fn, _, _}), do: false
  defp pipe_friendly?({:&, _, _}), do: false
  defp pipe_friendly?(list) when is_list(list), do: false

  # Sourceror parses literal lists as `{:__block__, _, [list]}`.
  defp pipe_friendly?({:__block__, _, [inner]}) when is_list(inner), do: false

  defp pipe_friendly?(_), do: true

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
