defmodule Number42.Refactors.Ex.ExtractPrimitiveToStruct do
  @moduledoc """
  Detects a recurring primitive shape — the same bare tuple or bare map
  threaded through many function heads — and extracts it into a named
  struct, rewriting the heads and the construction sites.

      # before
      def distance({lat1, lng1}, {lat2, lng2}), do: …
      def midpoint({lat1, lng1}, {lat2, lng2}), do: …
      # call site: distance({52.5, 13.4}, {48.1, 11.6})
      # after
      defmodule Coord do
        defstruct [:lat, :lng]
      end
      def distance(%Coord{lat: lat1, lng: lng1}, %Coord{lat: lat2, lng: lng2}), do: …
      def midpoint(%Coord{lat: lat1, lng: lng1}, %Coord{lat: lat2, lng: lng2}), do: …
      # call site: distance(%Coord{lat: 52.5, lng: 13.4}, …)

  The rewrite is mechanical. The hard, dangerous part is **recognising**
  that a pile of `{lat, lng}` tuples is secretly one domain type, and
  proving it can be extracted without silently corrupting meaning.

  ## The critical trap: positional consistency (anti-swap)

  `{lat, lng}` and `{lng, lat}` are the same arity and opposite meaning.
  A swapped field mapping **compiles and is silently wrong** — the worst
  failure class of this refactor. The defence: a tuple shape qualifies
  only when its positions are used **consistently** across every
  occurrence, and consistency is **proven from the head bindings**, not
  guessed.

  Concretely, every occurrence of the shape must appear as a **pattern in
  a function head** binding each position to a **bare variable**, and the
  variable *name* at a position must agree (modulo a numeric/cluster
  suffix) across all occurrences. `{lat, lng}` and `{lat2, lng2}` agree
  (`lat`/`lat2` share the stem `lat`, `lng`/`lng2` the stem `lng`); a head
  binding `{lng, lat}` disagrees at both positions and **declines the
  whole shape**. The position→field-name map is the *stem* at each
  position; it must be a function (one stem per position) and injective
  (no stem on two positions). If the stems can't be made to agree, the
  semantics aren't provable and the shape is left alone. A wrong field
  mapping is worse than no extraction.

  This is deliberately strict — it ignores tuples bound to a single var,
  destructured in the body, or built positionally without head evidence.
  Those are real extraction opportunities the next slice can chase with
  stronger flow analysis; v1 only fires where the head **names** the
  positions and thereby proves their semantics.

  ## Map shapes are never extracted (#372)

  A bare-map pattern `%{k: v}` is a **subset match** — it matches any map
  carrying those keys. Rewriting it to a struct pattern `%Struct{k: v}`
  turns it into a **type assertion** that matches only that exact struct,
  so any plain map (a query-option map, a `params` map) flowing into that
  head silently stops matching at runtime — a `FunctionClauseError`, worse
  than a compile error. The key set is no proof the value is the struct,
  and proving it would need whole-program construction analysis this
  refactor does not do. Unlike the tuple side — where head bindings prove
  each position's semantics — the map side has no soundness proof, so every
  map shape is **declined** (recorded in the plan's `declined` list for
  `--log` review). Only positionally-proven tuple shapes are extracted.

  ## Threshold K

  A shape qualifies only when it appears in `>= K` function heads
  (default `K = 3`). Justification: K=2 catches genuine one-off pairs (a
  helper and its single caller both destructuring the same ad-hoc tuple)
  that aren't a domain type; K=3 is the smallest count that signals a
  *recurring* structural convention rather than a coincidence. Configure
  via `min_occurrences:`.

  ## Naming policy: derive or decline (#372/#375)

  There is **no signal in the code** for what to call the struct, so the
  name is derived from the field-name set via a small dictionary
  (`lat`+`lng` → `Coord`, `x`+`y` → `Point`, `lon`/`lng`/`longitude`
  normalised). There is **no `ExtractedStruct<N>` placeholder fallback**: a
  generic struct name carries no domain meaning and shipping
  `# TODO: rename` into user code is worse than leaving the raw tuple in
  place. When the dictionary has no entry the shape is **declined**
  (`finalize_shape` records `:no_meaningful_name`). The dictionary is tiny
  and English-biased by design — that is the cost of refusing to guess a
  type name.

  ## False-positive guards (hard exclusions)

  - **Tagged tuples** — `{:ok, v}`, `{:error, reason}`, `{:noreply, s}`:
    a first element that is a *tag-like atom literal* marks control-flow,
    not a domain type. Any occurrence with a literal (non-variable) at a
    position disqualifies the shape (it's not a uniform N-of-values
    record).
  - **Transient one-offs** — guarded by the `>= K` threshold.
  - **Stdlib tuple consumers** — a tuple flowing into `List.keyfind/3`,
    `:ets.*`, `List.keystore`, `Keyword`/keyword-list APIs etc. relies on
    the raw-tuple contract; wrapping it in a struct breaks that. A shape
    whose construction sites feed a known tuple-consuming API is excluded.
  - **Already a struct** — a shape whose fields exactly match an existing
    `defstruct` (project-wide, via `prepare/1`) is not re-extracted.
  - **Name collision** — if the chosen struct name already exists as a
    module in the project, decline rather than clash.

  ## Where detection gives up

  Tuples without head bindings (a bare var, body destructuring,
  arithmetic on the whole tuple); positionally-inconsistent heads;
  arity-1 tuples; mixed literal/variable positions. In every ambiguous
  case the shape is **declined** — recorded in the plan's `declined` list
  for `--log` review — never extracted on a guess.

  ## Default-OFF (opt-in only)

  Disabled by default — `transform/2` is a no-op unless its own opts
  carry `enabled: true`. The detection is heuristic and a wrong
  positional mapping compiles-but-corrupts, so this is the highest-risk
  refactor in the catalog. Enable per project after reviewing the dry-run
  diff:

      configured_modules: [
        {Number42.Refactors.Ex.ExtractPrimitiveToStruct, enabled: true}
      ]
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  # >= K function-head occurrences before a shape is a recurring type.
  # K=2 still catches accidental one-off pairs; K=3 is the smallest count
  # signalling a convention rather than a coincidence.
  @default_min_occurrences 3

  # field-name set -> struct name. Tiny and English-biased by design;
  # the documented weakness of the naming policy. First match wins.
  @name_dictionary [
    {~w(lat lng)a, "Coord"},
    {~w(x y)a, "Point"},
    {~w(x y z)a, "Point3D"},
    {~w(width height)a, "Size"},
    {~w(row col)a, "Cell"},
    {~w(line column)a, "Position"},
    {~w(red green blue)a, "Color"},
    {~w(min max)a, "Range"},
    {~w(start end)a, "Span"},
    {~w(key value)a, "Pair"},
    {~w(name age)a, "Person"},
    {~w(first last)a, "Name"}
  ]

  # Position-name stems normalised so `lng`/`longitude`/`lon` agree.
  @stem_aliases %{
    "longitude" => "lng",
    "lon" => "lng",
    "latitude" => "lat",
    "col" => "col",
    "column" => "col"
  }

  # First-element atoms that mark a tagged control-flow tuple.
  @control_tags ~w(ok error noreply reply stop ignore halt cont)a

  # Remote calls whose tuple arguments rely on the raw-tuple contract.
  @tuple_consumers %{
    List => ~w(keyfind keyfind! keytake keydelete keyreplace keystore keymember?)a,
    :ets => :any,
    Keyword => ~w(get fetch fetch! put delete has_key?)a,
    Tuple => :any
  }

  @impl Number42.Refactors.Refactor
  def description,
    do: "detect a recurring tuple/map shape and extract it into a named struct"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    The same `{lat, lng}` tuple or `%{name: _, age: _}` map threaded
    through many heads is primitive obsession: a domain type living as a
    raw shape. Extracting it into a named struct documents the type,
    lets the compiler check field access, and removes positional
    fragility. The dangerous part is positional consistency — a swapped
    tuple mapping compiles and silently corrupts — so a tuple is
    extracted only when its head bindings prove every position's
    semantics; otherwise it is declined.
    """
  end

  # Synthesising a new `defmodule` block and rewriting heads needs a
  # formatting pass to settle.
  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    {:ok, build_plan(plan_sources(opts), opts)}
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      structs = prepared_structs(opts)
      min = prepared_min(opts)
      rewrite(source, structs, min)
    else
      source
    end
  end

  defp prepared_structs(opts) do
    case Keyword.get(opts, :prepared) do
      %{structs: structs} -> structs
      _ -> %{}
    end
  end

  defp prepared_min(opts) do
    case Keyword.get(opts, :prepared) do
      %{min_occurrences: min} -> min
      _ -> Keyword.get(opts, :min_occurrences, @default_min_occurrences)
    end
  end

  @doc """
  Build the cross-file plan: the project-wide struct field index plus,
  for `--log` review, the shapes that would be extracted and declined.

      %{
        structs: %{module => MapSet(field_atoms)},
        min_occurrences: pos_integer,
        extractions: [%{name:, fields:, kind:, count:}],
        declined: [%{kind:, reason:, detail:}]
      }
  """
  @spec build_plan([{String.t(), String.t()}], keyword()) :: map()
  def build_plan(sources, opts \\ []) do
    min = Keyword.get(opts, :min_occurrences, @default_min_occurrences)
    structs = struct_index(sources)

    {extractions, declined} =
      sources
      |> Enum.flat_map(&module_shapes/1)
      |> resolve_shapes(structs, min)

    %{
      structs: structs,
      min_occurrences: min,
      extractions: extractions,
      declined: declined
    }
  end

  @doc "Human-readable plan report for `--log`/dry-run review."
  @spec report(map()) :: String.t()
  def report(%{extractions: []}), do: "no recurring primitive shapes to extract"

  def report(%{extractions: extractions}) do
    "extractable shapes:\n" <>
      Enum.map_join(extractions, "\n", fn e ->
        "  #{e.name} #{inspect(MapSet.to_list(e.fields))} (#{e.kind}, #{e.count}x)"
      end)
  end

  # --- project-wide struct index ---

  defp struct_index(sources) do
    sources
    |> Enum.flat_map(&structs_in_source/1)
    |> Map.new()
  end

  defp structs_in_source({_path, src}) do
    case Sourceror.parse_string(src) do
      {:ok, ast} -> ast |> Macro.prewalker() |> Enum.flat_map(&module_struct/1)
      {:error, _} -> []
    end
  end

  defp module_struct({:defmodule, _, [name_ast, [{_do, body}]]}) do
    with {:ok, module} <- alias_to_module(name_ast),
         {:ok, fields} <- struct_fields(body) do
      [{module, fields}]
    else
      _ -> []
    end
  end

  defp module_struct(_node), do: []

  defp struct_fields(body) do
    body
    |> body_to_exprs()
    |> Enum.find_value(:error, fn
      {:defstruct, _, [fields]} -> {:ok, field_set(unwrap_block(fields))}
      _ -> nil
    end)
  end

  defp field_set(fields) when is_list(fields) do
    fields
    |> Enum.map(fn
      {:__block__, _, [atom]} when is_atom(atom) -> atom
      atom when is_atom(atom) -> atom
      {key, _value} -> field_key(key)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp field_set(_), do: MapSet.new()

  defp field_key({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp field_key(atom) when is_atom(atom), do: atom
  defp field_key(_), do: nil

  # --- shape collection ---

  # Every tuple/map head-pattern occurrence in a source, as a raw
  # observation: kind, the per-position binding stems (tuple) or key set
  # (map), and whether any guard disqualifies it.
  defp module_shapes({_path, src}) do
    case Sourceror.parse_string(src) do
      {:ok, ast} ->
        consumed = consumed_tuple_arities(ast)
        ast |> Macro.prewalker() |> Enum.flat_map(&head_shapes(&1, consumed))

      {:error, _} ->
        []
    end
  end

  defp head_shapes({kind, _, [head | _]}, consumed) when kind in [:def, :defp] do
    head
    |> strip_when()
    |> head_args()
    |> Enum.flat_map(&shape_observation(&1, consumed))
  end

  defp head_shapes(_node, _consumed), do: []

  defp head_args(head) do
    case head do
      {name, _, args} when is_atom(name) and is_list(args) -> args
      _ -> []
    end
  end

  # A 2-tuple head pattern: `{:__block__, _, [{a, b}]}`.
  defp shape_observation({:__block__, _, [{e1, e2}]}, consumed),
    do: tuple_observation([e1, e2], consumed)

  # A 3+-tuple head pattern: `{:{}, _, elems}`.
  defp shape_observation({:{}, _, elems}, consumed) when is_list(elems),
    do: tuple_observation(elems, consumed)

  # A map head pattern: `{:%{}, _, pairs}`.
  defp shape_observation({:%{}, _, pairs}, _consumed) when is_list(pairs),
    do: map_observation(pairs)

  defp shape_observation(_node, _consumed), do: []

  # A tuple head pattern qualifies for a positionally-provable observation
  # only when every position binds a bare variable. A literal at any
  # position (a constant) disqualifies — that's a partial match, not a
  # uniform record. A leading **tag-like atom** (`{:ok, v}`) is dropped
  # entirely: it's a control-flow idiom, never a domain type.
  defp tuple_observation(elems, consumed) do
    arity = length(elems)
    stems = Enum.map(elems, &binding_stem/1)

    cond do
      arity < 2 -> []
      tagged_tuple?(elems) -> []
      Enum.any?(stems, &is_nil/1) -> []
      arity in consumed -> [%{kind: :tuple, arity: arity, stems: stems, disqualified: :stdlib}]
      true -> [%{kind: :tuple, arity: arity, stems: stems, disqualified: nil}]
    end
  end

  # `{:ok, _}`, `{:error, _}`, `{:noreply, _}` …: the first element is a
  # bare atom literal from the control-flow tag set.
  defp tagged_tuple?([first | _]), do: tag_atom(first) in @control_tags
  defp tagged_tuple?(_), do: false

  defp tag_atom({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp tag_atom(_), do: nil

  # The binding stem of a tuple position, or nil if it isn't a bare var.
  # `lat2` -> "lat", `lng` -> "lng"; trailing digits are dropped and the
  # alias table folds `longitude`/`lon` -> `lng` etc.
  defp binding_stem(node) do
    case bare_var(node) do
      {:ok, var} -> var |> Atom.to_string() |> stem()
      :skip -> nil
    end
  end

  defp stem(name) do
    base = String.replace(name, ~r/\d+$/, "")
    Map.get(@stem_aliases, base, base)
  end

  # A map head pattern qualifies when every key is an atom literal; the
  # field set is the key set. Values (the bound vars) are irrelevant to
  # identity — only the key set defines the map type.
  defp map_observation(pairs) do
    keys = Enum.map(pairs, &pair_key/1)

    cond do
      keys == [] -> []
      Enum.any?(keys, &is_nil/1) -> []
      true -> [%{kind: :map, fields: MapSet.new(keys), disqualified: nil}]
    end
  end

  defp pair_key({{:__block__, _, [key]}, _value}) when is_atom(key), do: key
  defp pair_key(_), do: nil

  # Tuple arities consumed by a known stdlib tuple API anywhere in the
  # source. We can't trace dataflow per-shape cheaply, so any shape of a
  # consumed arity is excluded — conservative on purpose.
  defp consumed_tuple_arities(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&consumer_call_arities/1)
    |> MapSet.new()
  end

  defp consumer_call_arities({{:., _, [mod_ast, fun]}, _, args})
       when is_atom(fun) and is_list(args) do
    with {:ok, module} <- consumer_module(mod_ast),
         true <- consumer_fun?(module, fun) do
      args |> Enum.flat_map(&literal_tuple_arity/1)
    else
      _ -> []
    end
  end

  defp consumer_call_arities(_node), do: []

  defp consumer_module({:__aliases__, _, _} = alias_ast), do: alias_to_module(alias_ast)
  defp consumer_module(mod) when is_atom(mod), do: {:ok, mod}
  defp consumer_module(_), do: :error

  defp consumer_fun?(module, fun) do
    case Map.get(@tuple_consumers, module) do
      :any -> true
      funs when is_list(funs) -> fun in funs
      _ -> false
    end
  end

  defp literal_tuple_arity({:__block__, _, [{_, _}]}), do: [2]
  defp literal_tuple_arity({:{}, _, elems}) when is_list(elems), do: [length(elems)]
  defp literal_tuple_arity(_), do: []

  # --- resolution ---

  # Group observations into a per-shape decision: extract or decline.
  defp resolve_shapes(observations, structs, min) do
    {tuples, maps} = Enum.split_with(observations, &(&1.kind == :tuple))

    {tuple_ext, tuple_dec} = resolve_tuples(tuples, structs, min)
    {map_ext, map_dec} = resolve_maps(maps, structs, min)

    {tuple_ext ++ map_ext, tuple_dec ++ map_dec}
  end

  # Tuples group by arity. Within an arity group, positional consistency
  # is the gate: each position must resolve to a single stem across all
  # occurrences, and the stems must be distinct (injective). A
  # disagreement at any position declines the whole arity group — the
  # anti-swap guard.
  defp resolve_tuples(tuples, structs, min) do
    tuples
    |> Enum.group_by(& &1.arity)
    |> Enum.reduce({[], []}, fn {arity, group}, {ext, dec} ->
      collect_decision(resolve_tuple_group(arity, group, structs, min), ext, dec)
    end)
  end

  defp resolve_tuple_group(arity, group, structs, min) do
    cond do
      Enum.any?(group, &(&1.disqualified == :stdlib)) ->
        {:decline, decline(:tuple, :stdlib_tuple_consumer, %{arity: arity})}

      length(group) < min ->
        :skip

      true ->
        decide_tuple_fields(arity, group, structs)
    end
  end

  # The position->stem map must be consistent (one stem per position) and
  # injective (a stem can't name two fields). Either failure is the
  # positional-inconsistency / anti-swap decline.
  defp decide_tuple_fields(arity, group, structs) do
    per_position =
      0..(arity - 1)//1
      |> Enum.map(fn pos -> group |> Enum.map(&Enum.at(&1.stems, pos)) |> Enum.uniq() end)

    if Enum.any?(per_position, &(length(&1) > 1)) do
      {:decline, decline(:tuple, :inconsistent_positions, %{arity: arity})}
    else
      finalize_tuple(arity, Enum.map(per_position, &hd/1), length(group), structs)
    end
  end

  defp finalize_tuple(arity, fields, count, structs) do
    if length(Enum.uniq(fields)) != length(fields) do
      {:decline, decline(:tuple, :non_injective_positions, %{arity: arity, fields: fields})}
    else
      finalize_shape(:tuple, Enum.map(fields, &String.to_atom/1), count, structs)
    end
  end

  # Map shapes are **never extracted** (#372). A bare-map pattern `%{k: v}`
  # is a *subset* match: it matches any map carrying those keys. Rewriting
  # it to a struct pattern `%Struct{k: v}` turns it into a *type assertion*
  # that only matches that exact struct — so any plain map (a query-option
  # map, a params map) flowing into that head silently stops matching at
  # runtime (a `FunctionClauseError`, worse than a compile error). The key
  # set is no proof the value is the struct, and proving it would need
  # whole-program construction analysis this refactor does not do. The tuple
  # side is sound because head bindings prove each position's semantics; the
  # map side has no equivalent proof, so every map group is declined
  # (recorded for `--log` visibility).
  defp resolve_maps(maps, _structs, min) do
    declined =
      maps
      |> Enum.group_by(& &1.fields)
      |> Enum.filter(fn {_fields, group} -> length(group) >= min end)
      |> Enum.map(fn {fields, _group} ->
        decline(:map, :bare_map_pattern_unprovable, %{fields: MapSet.to_list(fields)})
      end)

    {[], declined}
  end

  defp collect_decision({:extract, record}, ext, dec), do: {[record | ext], dec}
  defp collect_decision({:decline, record}, ext, dec), do: {ext, [record | dec]}
  defp collect_decision(:skip, ext, dec), do: {ext, dec}

  # Tuple tail: already-a-struct guard, then a *meaningful* name from the
  # field set — or decline. There is no `ExtractedStruct<N>` placeholder
  # (#372/#375): a generic struct name + `# TODO: rename` ships meaningless
  # type names into user code. When the dictionary has no entry the shape
  # is declined; a domain type no one can name reads better as the raw
  # tuple it already is.
  defp finalize_shape(kind, field_atoms, count, structs) do
    field_set = MapSet.new(field_atoms)

    cond do
      already_struct?(field_set, structs) ->
        {:decline, decline(kind, :already_a_struct, %{fields: field_atoms})}

      struct_name(field_atoms, structs) == nil ->
        {:decline, decline(kind, :no_meaningful_name, %{fields: field_atoms})}

      true ->
        {:extract,
         %{
           kind: kind,
           name: struct_name(field_atoms, structs),
           fields: field_set,
           ordered_fields: field_atoms,
           count: count
         }}
    end
  end

  defp already_struct?(field_set, structs) do
    Enum.any?(structs, fn {_mod, fields} -> MapSet.equal?(fields, field_set) end)
  end

  defp decline(kind, reason, detail),
    do: %{kind: kind, reason: reason, detail: detail}

  # --- naming policy (derive or decline) ---

  # A meaningful name from the field set, or `nil` to decline. There is no
  # `ExtractedStruct<N>` placeholder (#372/#375): a generic name carries no
  # domain meaning and shipping `# TODO: rename` into user code is worse
  # than leaving the raw tuple in place. `_structs` is unused now that the
  # numbered fallback is gone; kept in the signature for call-site symmetry.
  defp struct_name(fields, _structs), do: dict_name(Enum.sort(fields))

  defp dict_name(sorted_fields) do
    Enum.find_value(@name_dictionary, fn {keys, name} ->
      if Enum.sort(keys) == sorted_fields, do: name
    end)
  end

  # --- rewriting ---

  defp rewrite(source, structs, min) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> do_rewrite(source, ast, structs, min)
      {:error, _} -> source
    end
  end

  defp do_rewrite(source, ast, structs, min) do
    {extractions, _declined} =
      [{"", source}]
      |> Enum.flat_map(&module_shapes/1)
      |> resolve_shapes(structs, min)

    case extractions do
      [] ->
        source

      _ ->
        index = extraction_index(extractions)
        head_patches = ast |> Macro.prewalker() |> Enum.flat_map(&head_node_patches(&1, index))
        head_ranges = MapSet.new(head_patches, & &1.range)
        call_targets = call_target_index(ast, index)

        construction_patches =
          ast
          |> Macro.prewalker()
          |> Enum.flat_map(&construction_node_patches(&1, call_targets, head_ranges))

        patches = head_patches ++ construction_patches ++ [defstruct_patch(ast, extractions)]
        Sourceror.patch_string(source, patches)
    end
  end

  # `%{ {name, arity} => %{pos => extraction} }` — for every function this
  # rewrite struct-types at a head position, which struct sits there. A
  # call site passing a literal tuple at such a position is a **provable**
  # construction site: the value flows into a parameter we just typed.
  # This replaces an arity-only guess and removes the swap risk of
  # rewriting arbitrary value tuples.
  defp call_target_index(ast, index) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&head_struct_positions(&1, index))
    |> Enum.reduce(%{}, fn {key, pos, ext}, acc ->
      Map.update(acc, key, %{pos => ext}, &Map.put(&1, pos, ext))
    end)
  end

  defp head_struct_positions({kind, _, [head | _]}, index) when kind in [:def, :defp] do
    case strip_when(head) do
      {name, _, args} when is_atom(name) and is_list(args) ->
        args
        |> Enum.with_index()
        |> Enum.flat_map(&typed_position(&1, {name, length(args)}, index))

      _ ->
        []
    end
  end

  defp head_struct_positions(_node, _index), do: []

  defp typed_position({arg, pos}, key, index) do
    case head_param_extraction(arg, index) do
      nil -> []
      ext -> [{key, pos, ext}]
    end
  end

  defp head_param_extraction({:__block__, _, [{e1, e2}]}, index),
    do: tuple_extraction([e1, e2], index)

  defp head_param_extraction({:{}, _, elems}, index) when is_list(elems),
    do: tuple_extraction(elems, index)

  defp head_param_extraction(_arg, _index), do: nil

  defp tuple_extraction(elems, index) do
    stems = Enum.map(elems, &binding_stem/1)
    if Enum.any?(stems, &is_nil/1), do: nil, else: get_in(index, [:tuple, stems])
  end

  # Lookup tables: tuple arity+stems -> {name, fields}; map key-set ->
  # {name, fields}. Built once per rewrite from the resolved extractions.
  defp extraction_index(extractions) do
    Enum.reduce(extractions, %{tuple: %{}, map: %{}}, fn e, acc ->
      case e.kind do
        :tuple ->
          stems = Enum.map(e.ordered_fields, &Atom.to_string/1)
          put_in(acc, [:tuple, stems], e)

        :map ->
          put_in(acc, [:map, e.fields], e)
      end
    end)
  end

  defp head_node_patches({kind, _, [head | _]}, index) when kind in [:def, :defp] do
    head
    |> strip_when()
    |> head_args()
    |> Enum.flat_map(&pattern_patch(&1, index))
  end

  defp head_node_patches(_node, _index), do: []

  # A call `name(args)` to a function we struct-typed: any arg that is a
  # literal tuple sitting at a struct-typed position is a provable
  # construction site — the value flows into a parameter we just typed.
  # Local `name(args)` only (intra-module v1); remote calls would need
  # cross-module resolution, a follow-up slice.
  defp construction_node_patches({name, _, args}, call_targets, head_ranges)
       when is_atom(name) and is_list(args) do
    case Map.get(call_targets, {name, length(args)}) do
      nil ->
        []

      positions ->
        args
        |> Enum.with_index()
        |> Enum.flat_map(fn {arg, pos} ->
          arg_construction_patch(arg, Map.get(positions, pos), head_ranges)
        end)
    end
  end

  defp construction_node_patches(_node, _call_targets, _head_ranges), do: []

  defp arg_construction_patch(_arg, nil, _head_ranges), do: []

  defp arg_construction_patch({:__block__, _, [{e1, e2}]} = node, ext, head_ranges),
    do: construction_patch(node, [e1, e2], ext, head_ranges)

  defp arg_construction_patch({:{}, _, elems} = node, ext, head_ranges) when is_list(elems),
    do: construction_patch(node, elems, ext, head_ranges)

  defp arg_construction_patch(_arg, _ext, _head_ranges), do: []

  # --- head pattern rewrites ---

  defp pattern_patch({:__block__, _, [{e1, e2}]} = node, index),
    do: tuple_head_patch(node, [e1, e2], index)

  defp pattern_patch({:{}, _, elems} = node, index) when is_list(elems),
    do: tuple_head_patch(node, elems, index)

  defp pattern_patch({:%{}, _, pairs} = node, index) when is_list(pairs),
    do: map_head_patch(node, pairs, index)

  defp pattern_patch(_node, _index), do: []

  defp tuple_head_patch(node, elems, index) do
    stems = Enum.map(elems, &binding_stem/1)

    with false <- Enum.any?(stems, &is_nil/1),
         %{} = ext <- get_in(index, [:tuple, stems]) do
      vars = Enum.map(elems, &elem(bare_var(&1), 1))
      [Patch.new(Sourceror.get_range(node), struct_pattern(ext, vars))]
    else
      _ -> []
    end
  end

  defp map_head_patch(node, pairs, index) do
    keys = Enum.map(pairs, &pair_key/1)

    with false <- Enum.any?(keys, &is_nil/1),
         %{} = ext <- get_in(index, [:map, MapSet.new(keys)]) do
      [Patch.new(Sourceror.get_range(node), map_struct_pattern(ext, pairs))]
    else
      _ -> []
    end
  end

  # `%Coord{lat: lat1, lng: lng1}` — field name from the extraction's
  # ordered fields, binding var from the head.
  defp struct_pattern(ext, vars) do
    inner =
      ext.ordered_fields
      |> Enum.zip(vars)
      |> Enum.map_join(", ", fn {field, var} -> "#{field}: #{var}" end)

    "%#{ext.name}{#{inner}}"
  end

  defp map_struct_pattern(ext, pairs) do
    inner =
      pairs
      |> Enum.map_join(", ", fn {{:__block__, _, [key]}, value} ->
        "#{key}: #{Sourceror.to_string(value)}"
      end)

    "%#{ext.name}{#{inner}}"
  end

  # --- construction site rewrites ---

  # A literal tuple passed at a struct-typed call position becomes
  # `%Name{f1: v1, …}`, mapping each position to the extraction's ordered
  # field. The arity must match (a 3-tuple at a 2-field position is a
  # different shape and is left alone — never silently reshaped).
  defp construction_patch(node, elems, ext, head_ranges) do
    range = Sourceror.get_range(node)

    cond do
      length(elems) != length(ext.ordered_fields) -> []
      MapSet.member?(head_ranges, range) -> []
      true -> [Patch.new(range, build_struct(ext, elems))]
    end
  end

  defp build_struct(ext, elems) do
    inner =
      ext.ordered_fields
      |> Enum.zip(elems)
      |> Enum.map_join(", ", fn {field, value} ->
        "#{field}: #{Sourceror.to_string(value)}"
      end)

    "%#{ext.name}{#{inner}}"
  end

  # --- synthesised defstruct block ---

  # One `defmodule Name do defstruct […] end` per extraction, prepended
  # above the first top-level expression. The name is always dictionary-
  # derived (an unnameable shape is declined upstream), so no placeholder
  # rename reminder is ever emitted.
  defp defstruct_patch(ast, extractions) do
    line = first_expr_line(ast)
    text = Enum.map_join(extractions, "\n\n", &struct_module_text/1)
    range = %{start: [line: line, column: 1], end: [line: line, column: 1]}
    Patch.new(range, text <> "\n\n", false)
  end

  defp struct_module_text(ext) do
    fields = Enum.map_join(ext.ordered_fields, ", ", &":#{&1}")
    "defmodule #{ext.name} do\n  defstruct [#{fields}]\nend"
  end

  defp first_expr_line(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value(1, fn
      {:defmodule, meta, _} -> Keyword.get(meta, :line, 1)
      _ -> nil
    end)
  end

  # --- shared helpers ---

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp plan_sources(opts) do
    opts
    |> Keyword.get(:paths, [])
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, source} -> [{path, source}]
        {:error, _} -> []
      end
    end)
  end
end
