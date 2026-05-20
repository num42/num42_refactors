defmodule Num42.Refactors.Refactors.ExtractRenamedClone do
  @moduledoc """
  Extracts identical function bodies that live under **different
  function names** across modules into a shared `{LCP}.Shared`
  module. Companion to `ExtractSharedModule`, which only collapses
  same-name clones.

      # before
      defmodule MyApp.Items do
        def compute(x, y) do
          x |> Kernel.+(y) |> Kernel.*(2)
        end
      end

      defmodule MyApp.Items.Sub do
        def derive(x, y) do
          x |> Kernel.+(y) |> Kernel.*(2)
        end
      end

      # after
      defmodule MyApp.Items.Shared do
        # extracted from: MyApp.Items, MyApp.Items.Sub
        def compute(x, y) do
          x |> Kernel.+(y) |> Kernel.*(2)
        end
      end

      defmodule MyApp.Items do
        def compute(x, y), do: MyApp.Items.Shared.compute(x, y)
      end

      defmodule MyApp.Items.Sub do
        def derive(x, y), do: MyApp.Items.Shared.compute(x, y)
      end

  ## Why a separate refactor instead of folding into `ExtractSharedModule`?

  `ExtractSharedModule` groups clones by `{name, arity, body_hash}`,
  so renamed clones never cluster in its plan. We could lower the key
  to `{arity, body_hash}` everywhere — but the loser-rewrite story is
  different enough that it's clearer to split the two:

  - same-name clones can use `defdelegate` (cheaper, more
    idiomatic);
  - renamed clones need an explicit wrapper-`def` that bridges the
    name (Elixir's `import` doesn't rename).

  Separate plans + separate refactors also let the engine apply them
  in distinct steps and target either one selectively via `--only`.

  ## Naming policy

  Within a clone group, modules are sorted alphabetically. The
  function name from the **first** module wins; that's the name the
  shared definition takes, and that every wrapper-`def` calls. The
  loser modules keep their *own* original function name as the
  wrapper's head — call sites in surrounding code don't change.

  ## What's skipped

  - clone groups where every member already has the same name —
    that's `ExtractSharedModule`'s job.
  - any group with a non-plain-var head (pattern-match arg or guard)
    on any clause — wrapper-`def` would need its own pattern, which
    risks behaviour drift.
  - bodies that reference module attributes (same conservatism as
    `ExtractSharedModule`).
  - LCP < 1 segment (no sensible target namespace).

  ## Side effect

  Like `ExtractSharedModule`, this refactor writes new `.ex` files
  under `:write_root` (defaults to `File.cwd!/0`). Pass
  `dry_run: true` (the engine forwards this from
  `mix refactor --dry-run`) to skip every disk write while still
  returning a fully populated rewrite plan.
  """

  use Num42.Refactors.Refactor

  @default_min_mass 20

  @impl Num42.Refactors.Refactor
  def description, do: "Cross-file: extract renamed duplicates into a {LCP}.Shared module"

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    Same body, different function name across modules → extract the
    body into `{LCP}.Shared` under the alphabetically-first module's
    function name, and replace each original with a wrapper-`def`
    pointing at the shared definition.
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Num42.Refactors.Refactor
  def prepare(opts), do: Keyword.get(opts, :source_files) |> handle_prepare_get(opts)

  @impl Num42.Refactors.Refactor
  def transform(source, opts), do: Keyword.get(opts, :prepared) |> handle_transform_get(source)

  @doc """
  Build a rewrite plan from `[{path, source_string}]` tuples.

  Plan shape:
  `%{loser_module => [%{kind, name, arity, args, target, shared_name}, ...]}`.

  `name` is the loser's original function name; `shared_name` is the
  function name in the shared module (the alphabetically-first
  loser's name).
  """
  @spec build_plan([{String.t(), String.t()}], keyword()) :: %{module() => [map()]}
  def build_plan(sources, opts \\ []) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)
    write_root = Keyword.get(opts, :write_root, File.cwd!())
    dry_run? = Keyword.get(opts, :dry_run, false)

    entries =
      sources
      |> Enum.flat_map(&extract_module_info(&1, min_mass))

    plan_entries =
      entries
      |> Enum.group_by(fn e -> {e.arity, e.hash} end)
      |> Enum.flat_map(&plan_for_group/1)

    unless dry_run? do
      plan_entries
      |> Enum.group_by(fn {_loser, e} -> e.target end)
      |> Enum.each(fn {target, group} ->
        write_shared_module(target, group, write_root)
      end)
    end

    plan_entries |> Enum.group_by(fn {loser, _} -> loser end, fn {_, entry} -> entry end)
  end

  # ---- Source extraction ----------------------------------------------

  defp extract_module_info({_path, source}, min_mass),
    do: Sourceror.parse_string(source) |> handle_parse_string(min_mass, source)

  defp extract_from_ast(ast, _source, min_mass) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, mod} ->
            body_exprs = body_to_exprs(body)
            functions_in_module(mod, body_exprs, min_mass)

          :error ->
            []
        end

      _ ->
        []
    end)
  end

  defp functions_in_module(module, body_exprs, min_mass) do
    body_exprs
    |> Enum.filter(&def_clause?/1)
    |> Enum.group_by(&def_name_arity_or_skip/1)
    |> Enum.reject(fn {key, _} -> key == :skip end)
    |> Enum.flat_map(fn {{kind, name, arity}, clauses} ->
      build_function_entry(module, kind, name, arity, clauses, min_mass)
    end)
  end

  defp def_clause?({kind, _, [_head, body_kw]}) when kind in [:def, :defp] and is_list(body_kw),
    do: true

  defp def_clause?(_), do: false

  defp def_name_arity_or_skip({kind, _, [head | _]}) when kind in [:def, :defp] do
    strip_when(head) |> handle_strip_when(kind)
  end

  defp build_function_entry(module, kind, name, arity, clauses, min_mass) do
    cond do
      kind == :defp ->
        # Renamed-clone migration of `defp` would need every loser
        # to expose its name as a `defp` wrapper but `import` can't
        # rename — and we can't `defdelegate` to a `def` whose name
        # differs. Keep v1 scoped to public functions.
        []

      length(clauses) > 1 ->
        []

      not Enum.all?(clauses, &plain_var_clause?/1) ->
        []

      total_mass(clauses) < min_mass ->
        []

      body_uses_module_attribute?(clauses) ->
        []

      true ->
        # Plain-var clauses guarantee usable original arg names —
        # nicer to read in the wrapper than synthetic `arg_0`s.
        args = clause_arg_names(hd(clauses))

        [
          %{
            args: args,
            arity: arity,
            clauses: clauses,
            hash: hash_clauses(clauses),
            kind: kind,
            module: module,
            name: name
          }
        ]
    end
  end

  defp clause_arg_names({_kind, _, [head | _]}), do: strip_when(head) |> handle_strip_when_2()

  defp plain_var_clause?({_kind, _, [head | _]}) do
    case strip_when(head) do
      ^head -> args_are_plain_vars?(head)
      _ -> false
    end
  end

  defp args_are_plain_vars?({_name, _, args}) when is_list(args),
    do: args |> Enum.all?(&plain_var?/1)

  defp args_are_plain_vars?({_name, _, nil}), do: true
  defp args_are_plain_vars?(_), do: false

  defp plain_var?({:\\, _, _}), do: false

  defp plain_var?({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    not underscore?(name)
  end

  defp plain_var?(_), do: false

  defp body_uses_module_attribute?(clauses),
    do: clauses |> Enum.any?(&clause_references_attribute?/1)

  defp clause_references_attribute?({_kind, _, [_head, body_kw]}),
    do: body_kw |> Keyword.values() |> Enum.any?(&references_attribute?/1)

  defp references_attribute?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:@, _, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) -> true
      _ -> false
    end)
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp total_mass(clauses), do: clauses |> Enum.map(&clause_mass/1) |> Enum.sum()

  defp clause_mass({_kind, _, [_head, body_kw]}),
    do: body_kw |> Keyword.values() |> Enum.map(&node_count/1) |> Enum.sum()

  defp node_count(ast) do
    {_, count} = Macro.prewalk(ast, 0, fn node, acc -> {node, acc + 1} end)
    count
  end

  defp hash_clauses(clauses), do: clauses |> Enum.map(&normalize_clause/1) |> :erlang.phash2()

  # IMPORTANT for renamed-clone detection: drop the function NAME
  # from the head before hashing. Otherwise two identical bodies
  # under different names hash differently and never cluster.
  defp normalize_clause({_kind, _, [head, body_kw]}) do
    stripped_head_args =
      case strip_when(head) do
        {_name, _, args} when is_list(args) -> args |> Enum.map(&strip_meta/1)
        {_name, _, nil} -> []
        _ -> []
      end

    stripped_body = body_kw |> Keyword.values() |> Enum.map(&strip_meta/1)
    rename_vars({stripped_head_args, stripped_body})
  end

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp rename_vars(ast) do
    {result, _} = Macro.prewalk(ast, %{}, &rename_var_node/2)
    result
  end

  defp rename_var_node({name, [], ctx} = node, acc)
       when is_atom(name) and is_atom(ctx) do
    cond do
      underscore?(name) ->
        {node, acc}

      Map.has_key?(acc, name) ->
        {{:"$var", [], [Map.fetch!(acc, name)]}, acc}

      true ->
        idx = map_size(acc)
        {{:"$var", [], [idx]}, Map.put(acc, name, idx)}
    end
  end

  defp rename_var_node(node, acc), do: {node, acc}

  # ---- Plan building --------------------------------------------------

  defp plan_for_group({_key, [_only]}), do: []

  defp plan_for_group({_key, entries}) do
    # Skip when every clone uses the same name — that's
    # ExtractSharedModule's job.
    names = entries |> Enum.map(& &1.name) |> Enum.uniq()

    if length(names) == 1 do
      []
    else
      sorted = entries |> Enum.sort_by(&Module.split(&1.module))

      case decide_target(sorted) do
        :skip ->
          []

        {:ok, target_module} ->
          # Skip if the target module is one of the input modules —
          # that would mean we already extracted earlier.
          if sorted |> Enum.any?(&(&1.module == target_module)) do
            []
          else
            winner = hd(sorted)
            shared_name = winner.name

            sorted
            |> Enum.map(fn entry ->
              {entry.module,
               %{
                 args: entry.args,
                 arity: entry.arity,
                 kind: entry.kind,
                 name: entry.name,
                 shared_name: shared_name,
                 target: target_module,
                 winner_clauses: winner.clauses
               }}
            end)
          end
      end
    end
  end

  defp decide_target(entries) do
    parts_lists = entries |> Enum.map(&Module.split(&1.module))
    prefix = longest_common_prefix(parts_lists)

    if length(prefix) >= 1 do
      {:ok, Module.concat(prefix ++ ["Shared"])}
    else
      :skip
    end
  end

  defp longest_common_prefix([]), do: []
  defp longest_common_prefix([single]), do: single

  defp longest_common_prefix(lists) do
    lists
    |> Enum.zip()
    |> Enum.take_while(fn tuple ->
      elems = Tuple.to_list(tuple)
      elems |> Enum.all?(&(&1 == hd(elems)))
    end)
    |> Enum.map(&elem(&1, 0))
  end

  # ---- Per-file rewrite -----------------------------------------------

  defp rewrite(source, plan),
    do: Sourceror.parse_string(source) |> handle_parse_string_2(plan, source)

  defp apply_plan_to_ast(ast, source, plan) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, mod} -> patches_for_module(mod, body_to_exprs(body), plan)
          :error -> []
        end

      _ ->
        []
    end)
    |> patch_or_passthrough(source)
  end

  defp patches_for_module(module, body_exprs, plan),
    do: Map.get(plan, module) |> handle_patches_for_module_get(body_exprs)

  defp patch_for_entry(body_exprs, entry) do
    clauses = body_exprs |> Enum.filter(&clause_matches?(&1, entry.name, entry.arity))

    case clauses do
      [] ->
        []

      [single] ->
        replacement = render_replacement(entry)
        clause_replacement_patch(single, replacement)

      _multi ->
        # Skipped earlier in build_function_entry; defensive guard.
        []
    end
  end

  defp clause_matches?({kind, _, [head | _]}, name, arity) when kind in [:def, :defp] do
    case strip_when(head) do
      {^name, _, args} when is_list(args) and length(args) == arity -> true
      {^name, _, nil} when arity == 0 -> true
      _ -> false
    end
  end

  defp clause_matches?(_, _, _), do: false

  defp render_replacement(%{args: args, name: name, shared_name: shared, target: target}) do
    arg_list = args |> Enum.join(", ")
    "def #{name}(#{arg_list}), do: #{inspect(target)}.#{shared}(#{arg_list})"
  end

  defp clause_replacement_patch(clause, replacement),
    do: Sourceror.get_range(clause) |> handle_get_range(replacement)

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  # ---- Writing the shared module --------------------------------------

  defp write_shared_module(target_module, group, write_root) do
    path = shared_module_path(target_module, write_root)
    File.mkdir_p!(Path.dirname(path))

    if File.exists?(path) do
      append_if_missing(path, target_module, group)
    else
      File.write!(path, render_fresh_module(target_module, group))
    end
  end

  defp render_fresh_module(target_module, group) do
    body = render_shared_body(group)

    """
    defmodule #{inspect(target_module)} do
    #{indent(body, "  ")}
    end
    """
  end

  defp render_shared_body(group) do
    # Group entries by shared_name so each shared function is rendered
    # once, with its `extracted from:` comment listing every source
    # module that contributed.
    group
    |> Enum.group_by(fn {_loser, e} -> e.shared_name end)
    |> Enum.map_join("\n\n", fn {_shared_name, items} ->
      sources =
        items
        |> Enum.map(fn {loser, _} -> loser end)
        |> Enum.sort()
        |> Enum.map_join(", ", &inspect/1)

      # All items in a shared-name bucket share the same winner_clauses
      {_, e} = hd(items)

      header = "# extracted from: #{sources}"
      body = render_clauses(e.winner_clauses)

      [header, body] |> Enum.join("\n")
    end)
    |> String.trim()
  end

  defp render_clauses(clauses), do: clauses |> Enum.map_join("\n\n", &Sourceror.to_string/1)

  defp append_if_missing(path, target_module, group) do
    source = File.read!(path)

    Sourceror.parse_string(source) |> handle_parse_string_3(group, path, source, target_module)
  end

  defp collect_existing_function_keys(ast, target_module) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, ^target_module} -> {:ok, body_to_exprs(body)}
          _ -> nil
        end

      _ ->
        nil
    end)
    |> case do
      {:ok, body_exprs} ->
        body_exprs
        |> Enum.filter(&def_clause?/1)
        |> Enum.map(fn c ->
          case def_name_arity_or_skip(c) do
            {_kind, name, arity} -> {name, arity}
            :skip -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp splice_before_module_end(source, addition) do
    lines = String.split(source, "\n")
    {prefix, suffix} = split_at_last_end(lines)
    indented = indent(addition, "  ")
    (prefix ++ ["", indented] ++ suffix) |> Enum.join("\n")
  end

  defp split_at_last_end(lines) do
    idx =
      lines
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {line, i} ->
        if String.trim(line) == "end", do: i, else: nil
      end)

    case idx do
      nil -> {lines, []}
      i -> {lines |> Enum.take(i), lines |> Enum.drop(i)}
    end
  end

  defp shared_module_path(target_module, write_root) do
    parts = Module.split(target_module)

    {root, rest} =
      case parts do
        [first | tail] -> {Macro.underscore(first), tail |> Enum.map(&Macro.underscore/1)}
        _ -> {"", []}
      end

    rel = Path.join(["lib", root | rest]) <> ".ex"
    Path.join(write_root, rel)
  end

  defp indent(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_prepare_get(nil, _opts), do: {:ok, %{}}

  defp handle_prepare_get(paths, opts) when is_list(paths) do
    sources = paths |> Enum.map(fn p -> {p, File.read!(p)} end)
    {:ok, build_plan(sources, opts)}
  end

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_transform_get(nil, source), do: source

  defp handle_transform_get(plan, source), do: source |> rewrite(plan)

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_parse_string({:ok, ast}, min_mass, source),
    do: ast |> extract_from_ast(source, min_mass)

  defp handle_parse_string({:error, _}, _min_mass, _source), do: []

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_strip_when({name, _, args}, kind) when is_atom(name) and is_list(args) do
    {kind, name, length(args)}
  end

  defp handle_strip_when({name, _, nil}, kind) when is_atom(name) do
    {kind, name, 0}
  end

  defp handle_strip_when(_, _kind), do: :skip

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_strip_when_2({_name, _, args}) when is_list(args) do
    args |> Enum.map(fn {n, _, _} -> n end)
  end

  defp handle_strip_when_2({_name, _, nil}), do: []

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_parse_string_2({:ok, ast}, plan, source), do: ast |> apply_plan_to_ast(source, plan)

  defp handle_parse_string_2({:error, _}, _plan, source), do: source

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_patches_for_module_get(nil, _body_exprs), do: []

  defp handle_patches_for_module_get(entries, body_exprs),
    do:
      entries
      |> Enum.flat_map(&patch_for_entry(body_exprs, &1))

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_get_range(%{end: end_pos, start: start_pos}, replacement),
    do: [%{change: replacement, range: %{end: end_pos, start: start_pos}}]

  defp handle_get_range(_, _replacement), do: []

  # FIXME: extracted automatically by ExtractCaseToHelper — review
  # the parameter list and consider a better name.
  defp handle_parse_string_3({:ok, ast}, group, path, source, target_module) do
    existing_keys = collect_existing_function_keys(ast, target_module)

    new_items =
      group
      |> Enum.reject(fn {_loser, e} ->
        MapSet.member?(existing_keys, {e.shared_name, e.arity})
      end)

    if new_items == [] do
      :ok
    else
      addition = render_shared_body(new_items)
      File.write!(path, splice_before_module_end(source, addition))
    end
  end

  defp handle_parse_string_3(_, _group, _path, _source, _target_module), do: :ok
end
