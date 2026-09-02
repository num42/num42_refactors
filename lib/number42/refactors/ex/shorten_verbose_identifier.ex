defmodule Number42.Refactors.Ex.ShortenVerboseIdentifier do
  @moduledoc """
  Rename identifiers whose name has grown past five word tokens, dropping the
  tokens that carry the least information and rewriting every reference.

      # before
      defp build_serie_match_conditions_match_binding(x), do: x

      # after
      defp build_match_conditions_binding(x), do: x

  The token rules live in `Number42.Refactors.Analysis.IdentifierCompression`;
  this module decides *what* may be renamed at all.

  ## Scope — only what can be renamed soundly

    * **private functions** — a `defp` and its calls are module-local, so the
      whole set of references sits in this one file. Every clause moves together.
    * **local bindings** — a `left = right` inside a function clause, renamed
      within that clause only.

  Deliberately out of scope:

    * **public functions** — their callers live wherever the project imports
      them, and this refactor sees one file. Renaming would break a caller it
      cannot read.
    * **function parameters** — the name is part of the clause head, and a head
      often documents the caller's argument; leave that to the author.

  Declines whenever the shorter name is already taken in the same scope, since
  the rename would then merge two distinct identifiers into one.

  Default-OFF, opt-in:

      {ShortenVerboseIdentifier, enabled: true, identifier_corpus: %{"binding" => 99}}

  `:identifier_corpus` is a document-frequency map (see
  `IdentifierCompression.corpus/1`); with it, the token the codebase repeats
  everywhere is the first to go instead of the leading qualifier.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Analysis.AstHelpers
  alias Number42.Refactors.Analysis.IdentifierCompression, as: Compression

  @impl Number42.Refactors.Refactor
  def description, do: "Shorten identifiers of five-plus word tokens (default-OFF)"

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: false

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      corpus = Keyword.get(opts, :identifier_corpus, %{})

      case Sourceror.parse_string(source) do
        {:ok, ast} -> rewrite(ast, source, corpus)
        _ -> source
      end
    else
      source
    end
  end

  defp rewrite(ast, source, corpus) do
    case patches_for(ast, corpus) do
      [] -> source
      patches -> Sourceror.patch_string(source, patches)
    end
  end

  defp patches_for(ast, corpus) do
    function_renames = function_renames(ast, corpus)

    function_patches =
      ast
      |> occurrences(function_renames)
      |> Enum.map(&rename_patch/1)

    binding_patches =
      ast
      |> clauses()
      |> Enum.flat_map(&binding_patches(&1, corpus))

    function_patches ++ binding_patches
  end

  # ---- private functions ---------------------------------------------------

  # `%{old_name => new_name}` for every `defp` over the trigger whose shorter
  # name nothing else in the module answers to.
  defp function_renames(ast, corpus) do
    taken = MapSet.new(defined_names(ast))

    ast
    |> private_names()
    |> Enum.reduce(%{}, fn name, acc ->
      with {:ok, shorter} <- Compression.compress(name, corpus),
           false <- MapSet.member?(taken, shorter),
           false <- shorter in Map.values(acc) do
        Map.put(acc, Atom.to_string(name), shorter)
      else
        _ -> acc
      end
    end)
  end

  defp private_names(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defp, _, [head | _]} -> head |> strip_when() |> name_of() |> List.wrap()
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp defined_names(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {kind, _, [head | _]} when kind in [:def, :defp] ->
        head |> strip_when() |> name_of() |> List.wrap() |> Enum.map(&Atom.to_string/1)

      _ ->
        []
    end)
  end

  defp name_of(head) do
    case AstHelpers.extract_fn_signature(head) do
      {name, args} when is_list(args) -> name
      _ -> nil
    end
  end

  # ---- bindings ------------------------------------------------------------

  # Every `def`/`defp` clause body, the scope a binding rename may touch.
  defp clauses(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {kind, _, [head, body]} when kind in [:def, :defp] -> [{strip_when(head), body}]
      _ -> []
    end)
  end

  defp binding_patches({head, body}, corpus) do
    used = MapSet.new(names_in(body) ++ names_in(head))
    params = MapSet.new(param_names(head))

    body
    |> bound_names()
    |> Enum.reject(&MapSet.member?(params, &1))
    |> Enum.reduce({%{}, []}, fn name, {renames, patches} ->
      with {:ok, shorter} <- Compression.compress(name, corpus),
           false <- MapSet.member?(used, shorter),
           false <- shorter in Map.values(renames) do
        {Map.put(renames, Atom.to_string(name), shorter), patches}
      else
        _ -> {renames, patches}
      end
    end)
    |> then(fn {renames, _} ->
      body |> occurrences(renames) |> Enum.map(&rename_patch/1)
    end)
  end

  # Left-hand sides of a match in the clause body — the bindings this file owns.
  defp bound_names(body) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:=, _, [{name, _, nil}, _rhs]} when is_atom(name) -> [name]
      _ -> []
    end)
    |> Enum.uniq()
  end

  # Only the clause head's own variables count as parameters; the function name
  # itself sits at the head of the same node and must not shadow a binding.
  defp param_names(head) do
    case head do
      {_name, _meta, args} when is_list(args) ->
        args
        |> Enum.flat_map(&Macro.prewalker/1)
        |> Enum.flat_map(fn
          {name, _, nil} when is_atom(name) -> [name]
          _ -> []
        end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp names_in(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {name, _, _} when is_atom(name) -> [Atom.to_string(name)]
      _ -> []
    end)
    |> Enum.uniq()
  end

  # ---- patching ------------------------------------------------------------

  # Every node whose head atom is a key of `renames`, with the position of the
  # name itself — a call, a def head and a `&name/1` capture all land here.
  defp occurrences(_ast, renames) when renames == %{}, do: []

  defp occurrences(ast, renames) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {name, meta, _args} when is_atom(name) ->
        old = Atom.to_string(name)

        case {Map.get(renames, old), Keyword.get(meta, :line), Keyword.get(meta, :column)} do
          {nil, _, _} -> []
          {_, nil, _} -> []
          {_, _, nil} -> []
          {new, line, column} -> [{old, new, line, column}]
        end

      _ ->
        []
    end)
  end

  defp rename_patch({old, new, line, column}) do
    %{
      change: new,
      range: %{
        start: [line: line, column: column],
        end: [line: line, column: column + String.length(old)]
      }
    }
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other
end
