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

  # Dispatched by name from outside any call site this refactor can read.
  @framework_callbacks ~w(
    init start_link child_spec terminate code_change format_status
    handle_call handle_cast handle_info handle_continue handle_event
    handle_params handle_async handle_in handle_out
    mount render update preload join authorize policy call plug
    changeset new run perform up down change
  )a

  @impl Number42.Refactors.Refactor
  def description, do: "Shorten identifiers of five-plus word tokens (default-OFF)"

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: false

  # The rarity rule is only informed if it has the project's own identifiers to
  # count, so the corpus is built once over the whole read corpus.
  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    case Keyword.get(opts, :source_files) do
      files when is_list(files) and files != [] ->
        {:ok, build_plan(files, opts)}

      _ ->
        :no_cache
    end
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      corpus = corpus_from(opts)

      case Sourceror.parse_string(source) do
        {:ok, ast} -> rewrite(ast, source, corpus, opts[:prepared])
        _ -> source
      end
    else
      source
    end
  end

  defp corpus_from(opts) do
    case opts[:prepared] do
      %{corpus: corpus} -> corpus
      _ -> Keyword.get(opts, :identifier_corpus, %{})
    end
  end

  # Every name this refactor could ever rename, which is exactly the population
  # the frequencies should be read over.
  defp identifier_names(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {kind, _, [head | _]} when kind in [:def, :defp] ->
        head |> strip_when() |> name_of() |> List.wrap() |> Enum.map(&Atom.to_string/1)

      {:=, _, [{name, _, nil}, _rhs]} when is_atom(name) ->
        [Atom.to_string(name)]

      _ ->
        []
    end)
  end

  defp rewrite(ast, source, corpus, prepared) do
    case patches_for(ast, corpus) ++ public_patches(ast, source, prepared) do
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

  # ---- cross-file plan -----------------------------------------------------

  # One pass over the corpus: what each file defines and imports, which atoms
  # are spoken as literals, and what the templates say. A public rename can only
  # be decided against all of that at once.
  defp build_plan(files, opts) do
    contents =
      files
      |> Enum.map(fn file -> {file, File.read(file)} end)
      |> Enum.flat_map(fn
        {file, {:ok, source}} -> [{file, source}]
        _ -> []
      end)

    parsed =
      Enum.flat_map(contents, fn {file, source} ->
        case Sourceror.parse_string(source) do
          {:ok, ast} -> [{file, source, ast}]
          _ -> []
        end
      end)

    corpus =
      Keyword.get(opts, :identifier_corpus) ||
        parsed
        |> Enum.flat_map(fn {_f, _s, ast} -> identifier_names(ast) end)
        |> Compression.corpus()

    literals = parsed |> Enum.flat_map(fn {_f, _s, ast} -> atom_literals(ast) end) |> MapSet.new()
    template_words = template_words(Keyword.get(opts, :template_files) || templates_near(files))
    protected = MapSet.union(literals, template_words)

    public =
      Enum.reduce(parsed, %{}, fn {_file, _source, ast}, acc ->
        case {module_name(ast), public_renames(ast, corpus, protected)} do
          {nil, _} -> acc
          {_module, renames} when renames == %{} -> acc
          {module, renames} -> Map.put(acc, module, renames)
        end
      end)

    %{
      corpus: corpus,
      source_to_file: Map.new(contents, fn {file, source} -> {source, file} end),
      file_module: Map.new(parsed, fn {file, _s, ast} -> {file, module_name(ast)} end),
      imports: Map.new(parsed, fn {file, _s, ast} -> {file, imported_modules(ast)} end),
      public: public
    }
  end

  defp public_renames(ast, corpus, protected) do
    taken = MapSet.new(defined_names(ast))

    ast
    |> defs_of_kind(:def)
    |> Enum.reduce(%{}, fn name, acc ->
      with false <- MapSet.member?(protected, name),
           false <- name in @framework_callbacks,
           false <- component?(ast, name),
           {:ok, shorter} <- Compression.compress(name, corpus),
           false <- MapSet.member?(taken, shorter),
           false <- shorter in Map.values(acc) do
        Map.put(acc, Atom.to_string(name), shorter)
      else
        _ -> acc
      end
    end)
  end

  # This file sees its own module's renames bare, an imported module's renames
  # bare as well, and every module's renames qualified.
  defp public_patches(_ast, _source, nil), do: []

  defp public_patches(ast, source, prepared) do
    file = Map.get(prepared.source_to_file, source)

    bare =
      [prepared.file_module[file] | Map.get(prepared.imports, file, [])]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&(prepared.public |> Map.get(&1, %{}) |> Map.to_list()))
      |> Map.new()

    Enum.map(occurrences(ast, bare), &rename_patch/1) ++
      Enum.map(qualified_occurrences(ast, prepared.public), &rename_patch/1)
  end

  # ---- guards --------------------------------------------------------------

  # A `~H` body is a template, and `attr`/`slot` above a def declares one —
  # either way the callers are templates rather than call sites.
  defp component?(ast, name) do
    heex_def?(ast, name) or declared_component?(ast, name)
  end

  defp heex_def?(ast, name) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:def, _, [head | body]} ->
        strip_when(head) |> name_of() == name and
          body |> Macro.prewalker() |> Enum.any?(&match?({:sigil_H, _, _}, &1))

      _ ->
        false
    end)
  end

  defp declared_component?(ast, name) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [_alias, [{_do, block}]]} -> [block_exprs(block)]
      _ -> []
    end)
    |> Enum.any?(&declared_before?(&1, name))
  end

  defp declared_before?(exprs, name) do
    exprs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn
      [{form, _, _}, {:def, _, [head | _]}] when form in [:attr, :slot] ->
        strip_when(head) |> name_of() == name

      _ ->
        false
    end)
  end

  defp block_exprs({:__block__, _, exprs}), do: exprs
  defp block_exprs(other), do: [other]

  # Atoms spoken as values rather than as call heads — the shapes dynamic
  # dispatch takes (`apply/3`, `{Mod, :name}`, a keyword config).
  defp atom_literals(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:__block__, _meta, [atom]} when is_atom(atom) -> [atom]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp imported_modules(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:import, _, [{:__aliases__, _, _} = target | _]} -> [Macro.to_string(target)]
      _ -> []
    end)
    |> Enum.uniq()
  end

  # Templates are not parsed here, so every word one contains is treated as a
  # reference this rewrite could not follow.
  defp templates_near(files) do
    files
    |> Enum.flat_map(fn file ->
      case String.split(Path.dirname(file), "/lib/", parts: 2) do
        [root, _rest] -> [root]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.flat_map(&Path.wildcard(&1 <> "/**/*.{heex,eex}"))
    |> Enum.uniq()
  end

  defp template_words(paths) do
    paths
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, content} -> ~r/[a-z_][a-zA-Z0-9_]*[?!]?/ |> Regex.scan(content) |> Enum.map(&hd/1)
        _ -> []
      end
    end)
    |> MapSet.new(&String.to_atom/1)
  end

  # `Mod.name(...)` and `&Mod.name/1`: the dot node carries the position and the
  # name starts one column past the dot.
  defp qualified_occurrences(ast, per_module) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {{:., meta, [{:__aliases__, _, _} = target, name]}, _, _} when is_atom(name) ->
        located(Atom.to_string(name), Map.get(per_module, Macro.to_string(target), %{}), meta, 1)

      _ ->
        []
    end)
  end

  defp module_name(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value(fn
      {:defmodule, _, [{:__aliases__, _, _} = target | _]} -> Macro.to_string(target)
      _ -> nil
    end)
  end

  defp defs_of_kind(ast, kind) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {^kind, _, [head | _]} -> head |> strip_when() |> name_of() |> List.wrap()
      _ -> []
    end)
    |> Enum.uniq()
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
      {name, meta, _args} when is_atom(name) -> located(Atom.to_string(name), renames, meta, 0)
      _ -> []
    end)
  end

  defp located(old, renames, meta, offset) do
    case {Map.get(renames, old), Keyword.get(meta, :line), Keyword.get(meta, :column)} do
      {nil, _, _} -> []
      {_, nil, _} -> []
      {_, _, nil} -> []
      {new, line, column} -> [{old, new, line, column + offset}]
    end
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
