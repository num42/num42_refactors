defmodule Number42.Refactors.PatchRefactor do
  @moduledoc """
  Shared skeleton for the most common refactor shape: parse the source,
  build a patch list from the AST, apply it (or pass the source through
  unchanged on a parse error or when there are no patches).

  Dozens of refactor modules carry the exact same four-line mechanics:

      def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)
      defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
      defp apply_patches({:error, _}, source), do: source
      defp patch_or_passthrough([], source), do: source
      defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  `use Number42.Refactors.PatchRefactor` injects all of it and leaves the
  module to implement just the part that differs — a `build_patches/1`
  function (`def` or `defp`, the macro calls it locally either way):

      use Number42.Refactors.PatchRefactor

      defp build_patches(ast) do
        ast
        |> Macro.prewalker()
        |> Enum.flat_map(&maybe_patch/1)
      end

  `build_patches/1` receives the parsed AST (the `{:ok, ast}` payload of
  `Sourceror.parse_string/1`) and returns a list of Sourceror patches;
  return `[]` to leave the source unchanged.

  `use Number42.Refactors.PatchRefactor` also pulls in
  `use Number42.Refactors.Refactor`, so a patch-shaped refactor needs
  exactly one `use`. The module still supplies `description/0`,
  `explanation/0`, `priority/0`, and `reformat_after?/0` as usual.

  ## When *not* to use this

  This skeleton is for refactors whose `transform/2` ignores `opts` and
  whose control flow is exactly "parse → build patches → apply". A
  refactor that reads `opts`, threads extra state through its helpers,
  or returns the source from a custom branch keeps its own `transform/2`
  and does not `use` this module.
  """

  alias Sourceror.Patch

  @typedoc "A Sourceror patch produced from the AST."
  @type patch :: Patch.t() | %{required(:change) => String.t(), required(:range) => map()}

  @doc false
  defmacro __using__(_opts) do
    runner = __MODULE__

    quote do
      use Number42.Refactors.Refactor

      @impl Number42.Refactors.Refactor
      def transform(source, _opts),
        do: Sourceror.parse_string(source) |> __patch_refactor_apply__(source)

      defp __patch_refactor_apply__({:ok, ast}, source),
        do: build_patches(ast) |> unquote(runner).patch_or_passthrough(source)

      defp __patch_refactor_apply__({:error, _}, source), do: source
    end
  end

  @doc """
  Apply `patches` to `source`, or return `source` unchanged when the
  patch list is empty.
  """
  @spec patch_or_passthrough([patch()], String.t()) :: String.t()
  def patch_or_passthrough([], source), do: source
  def patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
