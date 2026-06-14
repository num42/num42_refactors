defmodule Number42.Refactors.Ex.SuggestInputStructsForProtocol do
  @moduledoc """
  Stage 1 of the two-stage protocol path: a **detector** that proposes
  input structs so `ExtractProtocolFromStructFamily` (stage 2) has a
  value to dispatch on.

  The protocol rewriter finds nothing in idiomatic Phoenix code because
  the hand-rolled dispatch runs through the function *name*, not a value:

      defp position_to_result(r), do: %Result{id: r.id, title: r.name, …}
      defp item_to_result(r),     do: %Result{id: r.id, title: r.name, …}
      defp brand_to_result(r),    do: %Result{id: r.id, name: r.name, …}
      # …7 total — the search-result family

  These all build the same `%Result{}`, but `r` is a bare binding over a
  raw `select`-projection map, not a `%Struct{}`. A protocol would
  dispatch on `Map` and the polymorphism evaporates. The name-family
  axis already *finds* this spot (it surfaces as a `name_families` hint
  with a `{:struct, Result}` signature); what it cannot do is decide the
  missing structs — that is an architecture call.

  This refactor renders that call as a paste-ready proposal. It is a
  **reporter, never a rewriter**: `transform/2` always returns its input
  unchanged. Lifting the inputs to structs touches the `select` query and
  is left to a human.

  ## What it produces

  Per `*_to_X` / `X_*` family that converges on a struct build over a
  bare-map argument, one proposal carrying:

  - one input struct per member, named from the discriminator token
    (`position` → `PositionSearchHit`, suffix configurable via
    `:struct_suffix`);
  - the shared protocol, named from the stem (`to_result` → `Searchable`,
    overridable via `:protocol`);
  - per-member field sets inferred body-only from the `r.<field>` reads;
  - the **shared compute fields** (read by every member — `distance`,
    `id`) flagged out of the structs rather than folded into each;
  - a rendered `defstruct`-per-member + `defprotocol` + `defimpl`-per-struct
    skeleton.

  ## Output contract with stage 2

  The suggested struct names and the protocol name are exactly what
  `ExtractProtocolFromStructFamily` would detect once the `def` heads
  pattern-match those structs — stage 1 produces what stage 2 consumes.
  The rendered `defimpl` heads read `def to_result(%PositionSearchHit{} = r)`
  so that, once a human lifts the `select` to return the struct, the
  existing rewriter fires unchanged.

  ## Scope: body-only field inference

  Fields come from the `r.<field>` accesses in each body. Cross-checking
  the feeding `select(_, %{…})` map shape would be more precise but
  couples the detector to Ecto query AST; per the issue's design note it
  is a later refinement, not part of v1. Body-only misses fields passed
  through helpers — acceptable for a *proposal* a human finalizes.

  ## Why a shared compute field stays out

  A field read by *every* member (`distance` — a `cosine_distance` score;
  `id`) is not entity data: it is a join/compute column the `select` adds.
  Folding it into all seven structs is wrong (no entity struct carries
  `distance`). The tool flags such fields instead of guessing where they
  belong — a separate score arg, a wrapper — and leaves that to the human.

  ## Default off

  A suggestion detector, not a rewrite: it never changes a file, and its
  output is a starting point for a human edit. Shipped **not** in the
  default `.refactor.exs`; run it explicitly to audit for protocol
  candidates hidden behind projection maps.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Ex.ExtractProtocolFromStructFamily, as: ProtocolFamily

  @default_struct_suffix "SearchHit"
  @excluded_path_prefixes ["test/", "dev/"]

  @impl Number42.Refactors.Refactor
  def description, do: "suggest input structs that turn a *_to_X map family into a protocol"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A `*_to_result` family that builds one struct from seven different
    projection maps is a hand-rolled protocol whose dispatch value is
    missing: `r` is a `Map`, so no `defprotocol` can dispatch on it.
    Introducing one input struct per member supplies that value and lets
    `ExtractProtocolFromStructFamily` lift the family to a real protocol.
    Choosing the structs is an architecture decision, so this detector
    only proposes — it renders paste-ready `defstruct`/`defprotocol`/
    `defimpl` skeletons and never edits the source.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: false

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    {:ok, build_plan(plan_sources(opts), opts)}
  end

  # A detector never patches the code it scans. The proposal lives in the
  # plan/report; the source is returned verbatim.
  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: source

  @doc """
  Build the suggestion plan from `[{path, source}]` tuples.

  Plan shape:

      %{
        proposals: [%{
          stem:, target:, protocol:, position:,
          shared_fields: [atom],
          members: [%{
            discriminator:, function:, struct:,
            fields: [atom],        # all body-inferred reads
            struct_fields: [atom]  # fields minus shared_fields
          }],
          rendered: String.t()
        }]
      }

  A proposal is produced for each name-family (from
  `ExtractProtocolFromStructFamily.build_plan/2`) that converges on a
  **struct build** AND whose members take a **bare-map** first argument
  (a `%Struct{}` first arg is stage 2's job, not stage 1's).

  Options: `:struct_suffix` (default `"SearchHit"`) and `:protocol`
  (override the stem-derived protocol name).
  """
  @spec build_plan([{String.t(), String.t()}], keyword()) :: map()
  def build_plan(sources, opts \\ []) do
    sources = Enum.reject(sources, fn {path, _src} -> excluded_path?(path) end)
    struct_suffix = Keyword.get(opts, :struct_suffix, @default_struct_suffix)
    protocol_override = Keyword.get(opts, :protocol)

    families = struct_families(sources, opts)
    bodies = bodies_by_function(sources)

    proposals =
      families
      |> Enum.flat_map(&build_proposal(&1, bodies, struct_suffix, protocol_override))

    %{proposals: proposals}
  end

  @doc """
  Human-readable report of a plan, for `--log`/manual review.

  Lists each proposed protocol with its members, inferred struct fields,
  and the shared compute fields it flags out. Returns
  `"no input-struct suggestions"` when the plan is empty.
  """
  @spec report(map()) :: String.t()
  def report(%{proposals: []}), do: "no input-struct suggestions"
  def report(%{proposals: proposals}), do: Enum.map_join(proposals, "\n\n", &proposal_lines/1)

  defp proposal_lines(p) do
    header =
      "input-struct suggestion: #{p.stem} family → #{inspect(p.protocol)} " <>
        "(builds #{inspect(p.target)})"

    members =
      Enum.map_join(p.members, "\n", &"  #{inspect(&1.struct)}: #{field_list(&1.struct_fields)}")

    shared =
      "  shared compute fields (flagged, not in any struct): #{field_list(p.shared_fields)}"

    Enum.join([header, members, shared], "\n")
  end

  defp field_list([]), do: "(none)"
  defp field_list(fields), do: Enum.map_join(fields, ", ", &to_string/1)

  # --- family selection ---

  # Only name-families that build a struct are protocol candidates; a
  # family converging on a named call (`subscribe`) has no struct to make.
  defp struct_families(sources, opts) do
    sources
    |> ProtocolFamily.build_plan(Keyword.put(opts, :dry_run, true))
    |> Map.get(:name_families, [])
    |> Enum.filter(&match?(%{signature: {:struct, _}}, &1))
  end

  # --- body parsing ---

  # `%{ function_name => {first_arg_ast, body_ast} }` for every def/defp.
  # Both axes need the body (field inference) and the first arg (the
  # bare-map vs struct check), so parse once.
  defp bodies_by_function(sources) do
    sources
    |> Enum.flat_map(&parse_clauses/1)
    |> Map.new()
  end

  defp parse_clauses({_path, src}) do
    case Sourceror.parse_string(src) do
      {:ok, ast} -> ast |> Macro.prewalker() |> Enum.flat_map(&clause_entry/1)
      {:error, _} -> []
    end
  end

  defp clause_entry({kind, _, [head, [{_do, body}]]}) when kind in [:def, :defp] do
    case name_first_arg(strip_when(head)) do
      {:ok, name, first_arg} -> [{name, {first_arg, body}}]
      :error -> []
    end
  end

  defp clause_entry(_node), do: []

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp name_first_arg({name, _, [first | _]}) when is_atom(name), do: {:ok, name, first}
  defp name_first_arg(_), do: :error

  # --- proposal construction ---

  defp build_proposal(family, bodies, struct_suffix, protocol_override) do
    members = align_members(family, bodies, struct_suffix)

    with true <- members != [],
         true <- Enum.all?(members, & &1.bare_map?) do
      target = struct_module(family.signature)
      shared = shared_fields(members)
      protocol = protocol_override || protocol_name(family.stem)
      members = finalize_members(members, shared)

      [
        %{
          stem: family.stem,
          target: target,
          protocol: protocol,
          position: family.position,
          shared_fields: shared,
          members: members,
          rendered: render(protocol, target, members, shared, family.stem)
        }
      ]
    else
      _ -> []
    end
  end

  # Pair each family member (function name) with its discriminator,
  # inferred fields, and whether its first arg is a bare binding (a map)
  # rather than a `%Struct{}` pattern (which would be stage 2's input).
  defp align_members(family, bodies, struct_suffix) do
    family.members
    |> Enum.map(fn fun ->
      disc = discriminator(fun, family.stem, family.position)
      {first_arg, body} = Map.get(bodies, fun, {nil, nil})

      %{
        function: fun,
        discriminator: disc,
        struct: struct_name(disc, struct_suffix),
        fields: inferred_fields(body, first_arg),
        bare_map?: bare_binding?(first_arg)
      }
    end)
    |> Enum.sort_by(& &1.function)
  end

  defp finalize_members(members, shared) do
    Enum.map(members, fn m -> Map.put(m, :struct_fields, m.fields -- shared) end)
  end

  # The discriminator is the family member's name with the shared stem
  # run stripped from the relevant end — `position_to_result` at `:suffix`
  # over stem `to_result` → `position`.
  defp discriminator(fun, stem, position) do
    fun_tokens = String.split(Atom.to_string(fun), "_", trim: true)
    stem_tokens = String.split(Atom.to_string(stem), "_", trim: true)

    case position do
      :suffix -> fun_tokens |> Enum.drop(-length(stem_tokens)) |> Enum.join("_")
      :prefix -> fun_tokens |> Enum.drop(length(stem_tokens)) |> Enum.join("_")
    end
  end

  # --- field inference (body-only) ---

  # The set of `<arg>.field` reads in the body, where `<arg>` is the
  # function's first-argument binding. Sorted + deduped — a proposal needs
  # the field *set*, not the read order or count.
  defp inferred_fields(nil, _arg), do: []

  defp inferred_fields(body, first_arg) do
    case binding_name(first_arg) do
      {:ok, var} ->
        body
        |> Macro.prewalker()
        |> Enum.flat_map(&field_access(&1, var))
        |> Enum.uniq()
        |> Enum.sort()

      :error ->
        []
    end
  end

  # `r.field` parses to `{ {:., _, [{r, _, ctx}, :field]}, _, [] }`.
  defp field_access({{:., _, [{var, _, ctx}, field]}, _, []}, var)
       when is_atom(ctx) and is_atom(field),
       do: [field]

  defp field_access(_node, _var), do: []

  # --- argument classification ---

  defp binding_name({var, _, ctx}) when is_atom(var) and is_atom(ctx), do: {:ok, var}
  defp binding_name(_), do: :error

  # A bare binding (`r`) is a map to dispatch through; a `%Struct{}`
  # pattern (or `%Struct{} = r`) is already a struct — stage 2 territory.
  defp bare_binding?({var, _, ctx}) when is_atom(var) and is_atom(ctx), do: true
  defp bare_binding?(_), do: false

  # --- shared compute fields ---

  # Fields read by EVERY member — entity-agnostic compute/score columns
  # (`distance`, `id`) that don't belong in any one entity's struct.
  defp shared_fields([]), do: []

  defp shared_fields(members) do
    members
    |> Enum.map(&MapSet.new(&1.fields))
    |> Enum.reduce(&MapSet.intersection/2)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  # --- naming ---

  defp struct_module({:struct, mod}), do: mod

  # `position` → `PositionSearchHit` (suffix configurable). A multi-token
  # discriminator camelizes whole (`item_variant` → `ItemVariantSearchHit`).
  defp struct_name(discriminator, suffix) do
    Module.concat([Macro.camelize(discriminator) <> suffix])
  end

  # `to_result` → `Searchable`: the stem as an `-able` adjective noun.
  # An already-`-able`/`-ible` stem passes through; a trailing `e` is
  # dropped before `able` (`serialize` → `Serializable`). The leading verb
  # of a multi-token stem is dropped (`to_result` → `result` → `Searchable`?
  # no — the stem's *last* token is the contract noun: `result`).
  defp protocol_name(stem) do
    noun = stem |> Atom.to_string() |> String.split("_", trim: true) |> List.last()
    Module.concat([adjectivize(noun)])
  end

  defp adjectivize(noun) do
    cond do
      String.ends_with?(noun, ["able", "ible"]) -> Macro.camelize(noun)
      String.ends_with?(noun, "e") -> Macro.camelize(String.trim_trailing(noun, "e") <> "able")
      true -> Macro.camelize(noun <> "able")
    end
  end

  # --- rendering ---

  defp render(protocol, target, members, shared, stem) do
    structs = Enum.map_join(members, "\n\n", &render_defstruct/1)
    impls = Enum.map_join(members, "\n\n", &render_defimpl(protocol, stem, &1))

    """
    # Stage-1 suggestion — paste, finalize the names/fields, then make the
    # `select` return the struct. Shared compute fields (read by every
    # member) are flagged below, NOT folded into any struct:
    #   shared compute fields: #{field_list(shared)}

    #{structs}

    defprotocol #{inspect(protocol)} do
      @spec #{stem}(t()) :: #{inspect(target)}.t()
      def #{stem}(data)
    end

    #{impls}
    """
  end

  defp render_defstruct(%{struct: struct, struct_fields: fields}) do
    """
    defmodule #{inspect(struct)} do
      defstruct #{inspect(fields)}
    end\
    """
  end

  # The impl head pattern-matches the suggested struct — the stage-2
  # dispatch contract. The body is a stub: the human moves the original
  # `#{function}/1` body here (which builds the real target struct, defined
  # elsewhere), so the skeleton stays compilable on its own.
  defp render_defimpl(protocol, stem, %{struct: struct, function: function}) do
    """
    defimpl #{inspect(protocol)}, for: #{inspect(struct)} do
      def #{stem}(%#{inspect(struct)}{} = r) do
        # move the body of #{function}/1 here
        r
      end
    end\
    """
  end

  # --- engine plumbing ---

  defp excluded_path?(path), do: String.starts_with?(path, @excluded_path_prefixes)

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
