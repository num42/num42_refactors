defmodule Number42.Refactors.Ex.ExtractProtocolFromStructFamily do
  @moduledoc """
  Detects functions defined over several **distinct struct types** —
  a hand-rolled protocol — and rewrites them into a real `defprotocol`
  with one `defimpl` per struct.

  This is the data-polymorphism sibling of
  `ExtractBehaviourFromAdapterFamily`. The behaviour refactor handles
  *module-identity* dispatch (`Mod.fun()` → `@behaviour`/`@impl`); this
  one handles *data-type* dispatch (first-arg struct → `defprotocol`/
  `defimpl`).

      # scattered clauses — a protocol waiting to be named
      def label(%Brand{} = b), do: b.name
      def label(%Item{} = i), do: i.title
      def label(%Asset{} = a), do: a.filename

  becomes a `defprotocol` plus one `defimpl` per struct, in a new file:

      defprotocol Catalog.Labelable do
        @spec label(t()) :: String.t()
        def label(data)
      end

      defimpl Catalog.Labelable, for: Brand do
        def label(%Brand{} = b), do: b.name
      end
      # …one defimpl per struct

  ## Detection

  1. Parse every non-test source. In each module body collect public
     `def` clauses (never `defp` — a protocol is a public surface).
  2. For each clause, look at the **dispatch argument** (the first
     positional arg by default; see `:dispatch_arg`). If it pattern
     matches a struct (`%StructMod{} = _` or `%StructMod{...}`), record
     `{name, arity} => StructMod` together with the clause AST and its
     home module.
  3. Group by `{name, arity}`, collect the set of **distinct** struct
     types each is defined over.
  4. A candidate is a `{name, arity}` defined over at least
     `:min_structs` distinct structs (default 3).

  ## ⚠️ Form-equality is not a polymorphism need

  Counting clauses by name is wildly over-eager. The trap (measured on
  a real codebase): the top hit was a function with five clauses that
  all pattern-matched the **same** struct on different shapes — pure
  arity/shape overloading, *zero* protocol value. Two guards follow
  from that:

  - **Dedupe to distinct struct types.** Five clauses over one struct
    is one struct, not five. The candidate count is `MapSet.size` of
    the struct types, never the clause count.
  - **A high `:min_structs` floor.** Two distinct structs sharing a
    function name is thin (they may merely collide on a common verb).
    The default floor is 3.

  ## Dispatch argument

  Elixir protocols dispatch on the **first** argument. A clause only
  contributes when its dispatch arg is a struct pattern; clauses where
  the struct sits in a later position can't become a protocol without
  reordering, so they're ignored. `:dispatch_arg` (0-based, default 0)
  lets a project point at a consistent non-first position for the
  report — synthesis still only rewrites first-arg families.

  ## Synthesis

  A candidate whose clauses **all live in one module** is rewritten:

  - A new `.ex` file is written next to the source module's layout (the
    same path derivation as `ExtractSharedModule`/the behaviour
    refactor), rooted at `opts[:write_root]`. It holds the
    `defprotocol` (one `def head/arity` plus a derived `@spec`) and one
    `defimpl …, for: Struct` per struct, each carrying that struct's
    original clauses verbatim.
  - The migrated clauses are removed from the source module by
    `transform/2`.
  - The protocol is named after the dispatched function as an `-able`
    noun (`label` → `Labelable`, `render` → `Renderable`), rooted at the
    source module's namespace. When that name differs from the source
    module, call sites that named the function statically
    (`Catalog.Labeling.label(x)`) are rewritten to the protocol
    (`Catalog.Labelable.label(x)`); otherwise protocol dispatch is
    transparent and no call site changes.

  A candidate whose clauses are **scattered across several modules** is
  reported but not rewritten (recorded with reason `:cross_module`):
  one protocol can't be sourced from clauses in different files without
  a judgement call this refactor doesn't make.

  ## Name-family hints (the near-miss axis)

  Struct-dispatch detection only fires when a clause literally
  pattern-matches `%Struct{}`. But a codebase often hand-rolls dispatch
  through the **function name** instead — `position_to_result`,
  `item_to_result`, `brand_to_result`, … all build the same thing for
  a different entity, and `subscribe_items`/`subscribe_brands`/… all
  subscribe one entity's topic. These share a token *stem* (the suffix
  `to_result`, the prefix `subscribe`) with a varying discriminator
  token (`position`, `item`, …) that is the would-be type.

  `name_families` reports those: function-name groups sharing a leading
  or trailing token run, with `:min_family` distinct members and
  distinct discriminators (default 3), excluding generic stopword stems
  (`to`, `get`, …).

  Two filters keep this from drowning in noise:

  - **Body convergence.** A shared name-stem alone is worthless —
    `delete_asset`/`delete_brand`/… share `delete` but each does
    something different (a `Multi` here, a `Repo.delete` there). A family
    only counts when every member's body converges on the **same**
    outermost operation: the same struct build (`%Result{}`) or the same
    named call (`subscribe`). Language constructs (`case`/`if`/`fn`/…)
    and macro sigils (`~H`) never count as an operation.
  - **Specific operation.** Even a converging call can be plumbing:
    `maybe_filter_* |> where`, `list_* |> Repo.all`, `*_subtotals |>
    Enum.reduce` all converge, but on stdlib/framework operations, not a
    domain contract. Calls to generic operations (`where`, `all`, `new`,
    `reduce`, `put_flash`, …) are filtered; struct builds always pass.

  On a real Phoenix app these two filters cut the raw 173 name-stem
  collisions down to the handful that converge on something specific —
  the `subscribe`/`broadcast` PubSub families and the `to_result` search
  family, exactly the spots a human audit flagged.

  This is a **hint, not a candidate.** The functions behind a name
  family frequently take *maps*, not structs — the `*_to_result` family
  in a real Phoenix app runs on raw `select` projections (`%{distance:,
  id:, …}`), so no protocol could dispatch on them. Lifting such a
  family to a protocol first requires hoisting its inputs to real
  structs, which this refactor cannot judge. So name-families live in
  their own plan key, never in `candidates`, and never drive a rewrite —
  they point a human at a spot worth a manual look.

  ## Default off

  Mechanically sound but precision-sensitive: the honest first result
  on a domain-heavy codebase may be "no good candidates" (idiomatic
  Elixir rarely hand-rolls struct-type dispatch), which is itself the
  useful signal. Shipped **not** in the default `.refactor.exs`.

  ## Side effect: file write

  Like `ExtractSharedModule`, `prepare/1` writes one new `.ex` file per
  synthesized protocol under `opts[:write_root]` (defaults to
  `File.cwd!/0`). With `dry_run: true` the plan is fully populated but
  nothing is written.
  """

  use Number42.Refactors.Refactor

  @default_min_structs 3
  @default_dispatch_arg 0

  # Name-family detection: how many distinct functions sharing a token
  # stem before it counts as a family (`item_topic`/`brand_topic`/… → a
  # `topic` family). Three keeps it from firing on an incidental pair.
  @default_min_family 3

  # Stems too generic to mean anything as a family root. A shared `get`
  # or `to` says nothing — half a codebase has them.
  @stopword_stems ~w(to from for get put new do run all one any is has of by)

  @excluded_path_prefixes ["test/", "dev/"]

  @impl Number42.Refactors.Refactor
  def description, do: "extract functions over distinct struct types into a protocol"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A function defined over several distinct struct types is a
    hand-rolled protocol: each clause is effectively a `defimpl`
    waiting to be named. Lifting it to a real `defprotocol` gives
    compile-time completeness checking (`Protocol.assert_impl!`),
    release-time consolidation, and an explicit, discoverable
    contract — one `def` head, one `defimpl` per type.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    {:ok, build_plan(plan_sources(opts), opts)}
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    case Keyword.get(opts, :prepared) do
      %{synthesized: [_ | _] = synthesized} -> rewrite_source(source, synthesized)
      _ -> source
    end
  end

  @doc """
  Build the detection + synthesis plan from `[{path, source}]` tuples.

  Plan shape:

      %{
        candidates: [%{name:, arity:, structs: [module], clauses: count,
                       module:, path:}],
        rejected: [%{name:, arity:, structs:, clauses:, reason:}],
        synthesized: [%{protocol:, source_module:, name:, arity:,
                        structs:, path:, rendered:, name_shift?:}],
        skipped: [%{name:, arity:, structs:, reason:}],
        name_families: [%{stem:, position:, members:, discriminators:,
                          signature:}]
      }

  `candidates` are `{name, arity}` groups defined over `:min_structs`+
  distinct structs. `synthesized` is the subset whose clauses all live
  in one module and resolve to a free protocol name — each carries the
  rendered protocol file and is written (unless `dry_run: true`).
  `skipped` records candidates that detected but couldn't be
  synthesized (`:cross_module`, `:naming_collision`). `rejected` records
  groups that pattern-matched a struct but didn't clear the floor.
  `name_families` is the weaker near-miss axis — a hint, not a candidate.
  """
  @spec build_plan([{String.t(), String.t()}], keyword()) :: map()
  def build_plan(sources, opts \\ []) do
    min_structs = Keyword.get(opts, :min_structs, @default_min_structs)
    min_family = Keyword.get(opts, :min_family, @default_min_family)
    dispatch_arg = Keyword.get(opts, :dispatch_arg, @default_dispatch_arg)
    write_root = Keyword.get(opts, :write_root, File.cwd!())
    dry_run? = Keyword.get(opts, :dry_run, false)

    parsed =
      sources
      |> Enum.reject(fn {path, _src} -> excluded_path?(path) end)
      |> Enum.flat_map(&parse_module_defs/1)

    groups =
      parsed
      |> Enum.flat_map(&struct_clauses(&1, dispatch_arg))
      |> group_by_function()

    {candidates, rejected} = classify(groups, min_structs)

    {synthesized, skipped} = synthesize(candidates, parsed, write_root)

    unless dry_run?, do: Enum.each(synthesized, &write_protocol_file/1)

    %{
      candidates: Enum.map(candidates, &candidate_report/1),
      rejected: rejected,
      synthesized: synthesized,
      skipped: skipped,
      name_families: name_families(parsed, min_family)
    }
  end

  defp candidate_report(%{name: name, arity: arity, structs: structs, clauses: clauses} = group) do
    %{
      name: name,
      arity: arity,
      structs: structs,
      clauses: clauses,
      module: group.module,
      path: group.path
    }
  end

  @doc """
  Human-readable report of a plan, for `--log`/manual dry-run review.

  Lists synthesized protocols, then struct-dispatch candidates that
  couldn't be rewritten, then name-family hints. Returns
  `"no protocol candidates"` when all are empty.
  """
  @spec report(map()) :: String.t()
  def report(plan) do
    sections =
      [
        synthesized_lines(Map.get(plan, :synthesized, [])),
        skipped_lines(Map.get(plan, :skipped, [])),
        family_lines(Map.get(plan, :name_families, []))
      ]
      |> Enum.reject(&(&1 == ""))

    case sections do
      [] -> "no protocol candidates"
      _ -> Enum.join(sections, "\n\n")
    end
  end

  defp synthesized_lines([]), do: ""

  defp synthesized_lines(synthesized) do
    "extracted protocols:\n" <>
      Enum.map_join(synthesized, "\n", fn s ->
        "  #{inspect(s.protocol)} (#{s.name}/#{s.arity}) over #{length(s.structs)} structs: " <>
          Enum.map_join(s.structs, ", ", &inspect/1)
      end)
  end

  defp skipped_lines([]), do: ""

  defp skipped_lines(skipped) do
    "struct-dispatch candidates (not rewritten):\n" <>
      Enum.map_join(skipped, "\n", fn s ->
        "  #{s.name}/#{s.arity} over #{length(s.structs)} structs (#{s.reason})"
      end)
  end

  defp family_lines([]), do: ""

  defp family_lines(families) do
    "name-family hints (converge on one op; verify values are structs, not maps):\n" <>
      Enum.map_join(families, "\n", fn %{
                                         stem: stem,
                                         position: pos,
                                         members: members,
                                         signature: sig
                                       } ->
        "  #{stem} (#{pos} of #{length(members)}, #{signature_label(sig)}): " <>
          Enum.map_join(members, ", ", &to_string/1)
      end)
  end

  defp signature_label({:struct, mod}), do: "builds #{inspect(mod)}"
  defp signature_label({:call, fun}), do: "calls #{fun}"

  # --- parsing ---

  # Parse one source into the `def`/`defp` clauses it declares, each
  # carrying its home module and path. Both detection axes and synthesis
  # run off this single parse. A clause record is
  # `%{kind:, name:, arity:, args:, body_head:, module:, path:, ast:}`;
  # `ast` is the raw `def`/`defp` node, kept for clause migration.
  #
  # `defp` is collected for the name-family axis (a hand-rolled protocol
  # is often a swarm of private `*_to_result/1` helpers) but filtered
  # back out of the struct-dispatch axis, which stays public.
  defp parse_module_defs({path, src}) do
    case Sourceror.parse_string(src) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.flat_map(&module_clauses(&1, path))

      {:error, _} ->
        []
    end
  end

  defp module_clauses({:defmodule, _, [name_ast, [{_do, body}]]}, path) do
    case alias_to_module(name_ast) do
      {:ok, module} ->
        body
        |> body_to_exprs()
        |> Enum.flat_map(&def_clause(&1, module, path))

      :error ->
        []
    end
  end

  defp module_clauses(_node, _path), do: []

  defp def_clause({kind, _, [head | rest]} = ast, module, path) when kind in [:def, :defp] do
    case name_and_args(strip_when(head)) do
      {:ok, name, args} ->
        [
          %{
            kind: kind,
            name: name,
            arity: length(args),
            args: args,
            body_head: body_head(rest),
            module: module,
            path: path,
            ast: ast
          }
        ]

      :error ->
        []
    end
  end

  defp def_clause(_node, _module, _path), do: []

  # The convergence signature of a clause body: the outermost expression,
  # reduced to a comparable key. `%Result{…}` → `{:struct, Result}`;
  # `PubSub.subscribe(…)` / a piped chain ending in it → `{:call, fun}`.
  # Anything else → `nil` (no shared signature). This is what tells a
  # genuine protocol family (all build a `%Result{}`) apart from a CRUD
  # family (`delete_asset` runs a Multi, `delete_brand` a Repo.delete).
  defp body_head([[{_do, body} | _]]), do: signature(block_return(body))
  defp body_head(_), do: nil

  # A do-block may be a single expr or a `__block__` of several; the
  # convergence signature keys off the block's *last* expression — its
  # return value (`x = …; %Result{…}` returns the struct).
  defp block_return({:__block__, _, exprs}) when exprs != [], do: List.last(exprs)
  defp block_return(expr), do: expr

  # Language constructs and macro sigils that, as a clause's outermost
  # form, say nothing about a shared *operation*. Two functions both
  # ending in a `case` (or both rendering a `~H` template, or both
  # building a tuple) have NOT converged on one operation — they just
  # both branch / both render. Excluding these is what separates the
  # genuine `subscribe`/`to_result` families from the dozen `~H` view
  # families and the `case`/`if`/`__block__` false convergences.
  @non_operation_heads ~w(case cond if unless with for fn try receive __block__ {}
                          %{} = |> <<>> ++ -- when . & ::)a

  # A pipe returns the signature of its right end (`rows |> Result.new()`
  # converges on `Result.new`). A struct literal and a *named* call are
  # signatures; language constructs, sigils, and bare values are not.
  defp signature({:|>, _, [_lhs, rhs]}), do: signature(rhs)

  defp signature({:%, _, [{:__aliases__, _, segs}, {:%{}, _, _}]}) when is_list(segs) do
    if Enum.all?(segs, &is_atom/1), do: {:struct, Module.concat(segs)}, else: nil
  end

  defp signature({{:., _, [_receiver, fun]}, _, _args}) when is_atom(fun), do: named_call(fun)
  defp signature({fun, _meta, args}) when is_atom(fun) and is_list(args), do: named_call(fun)
  defp signature(_), do: nil

  defp named_call(fun) do
    name = Atom.to_string(fun)

    if fun in @non_operation_heads or String.starts_with?(name, "sigil_"),
      do: nil,
      else: {:call, fun}
  end

  # --- clause collection (struct-dispatch axis) ---

  # `{ {name, arity}, %{struct:, module:, path:, ast:} }` for each public
  # clause whose dispatch arg is a struct pattern. `defp` never seeds a
  # protocol. The clause AST + home module ride along for synthesis.
  defp struct_clauses(%{kind: :defp}, _dispatch_arg), do: []

  defp struct_clauses(
         %{name: name, arity: arity, args: args, module: module, path: path, ast: ast},
         dispatch_arg
       ) do
    case dispatch_struct(args, dispatch_arg) do
      {:ok, struct_mod} ->
        [{{name, arity}, %{struct: struct_mod, module: module, path: path, ast: ast}}]

      :error ->
        []
    end
  end

  defp name_and_args({name, _, args}) when is_atom(name) and is_list(args),
    do: {:ok, name, args}

  defp name_and_args(_), do: :error

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  # The struct module pattern-matched at `index`, if any. Handles both
  # `%Mod{...}` directly and `%Mod{...} = var`.
  defp dispatch_struct(args, index) do
    case Enum.at(args, index) do
      nil -> :error
      arg -> struct_pattern(arg)
    end
  end

  defp struct_pattern({:=, _, operands}),
    do: operands |> Enum.find_value(:error, &maybe_struct/1)

  defp struct_pattern(arg), do: struct_pattern_node(arg)

  defp maybe_struct(node) do
    case struct_pattern_node(node) do
      {:ok, mod} -> {:ok, mod}
      :error -> nil
    end
  end

  # `%Mod{...}` parses to `{:%, _, [{:__aliases__, _, segs}, {:%{}, _, _}]}`.
  defp struct_pattern_node({:%, _, [{:__aliases__, _, segs}, {:%{}, _, _}]})
       when is_list(segs) do
    if Enum.all?(segs, &is_atom/1), do: {:ok, Module.concat(segs)}, else: :error
  end

  defp struct_pattern_node(_), do: :error

  # --- grouping & classification ---

  # Group by `{name, arity}`, carry the distinct struct set plus, for
  # synthesis, the home module(s) and the per-struct clause AST.
  defp group_by_function(entries) do
    entries
    |> Enum.group_by(fn {key, _info} -> key end, fn {_key, info} -> info end)
    |> Enum.map(fn {{name, arity}, infos} ->
      modules = infos |> Enum.map(& &1.module) |> Enum.uniq()

      %{
        name: name,
        arity: arity,
        structs: infos |> Enum.map(& &1.struct) |> Enum.uniq() |> Enum.sort(),
        clauses: length(infos),
        modules: modules,
        module: hd(modules),
        path: hd(infos).path,
        infos: infos
      }
    end)
    |> Enum.sort_by(&{-length(&1.structs), &1.name, &1.arity})
  end

  defp classify(groups, min_structs) do
    Enum.split_with(groups, fn %{structs: structs} -> length(structs) >= min_structs end)
    |> then(fn {candidates, below} -> {candidates, Enum.map(below, &reject_record/1)} end)
  end

  defp reject_record(%{structs: [_single], clauses: clauses} = group) when clauses > 1,
    do: rejected(group, :single_struct_overload)

  defp reject_record(group), do: rejected(group, :below_min_structs)

  defp rejected(%{name: name, arity: arity, structs: structs, clauses: clauses}, reason),
    do: %{name: name, arity: arity, structs: structs, clauses: clauses, reason: reason}

  # --- synthesis ---

  # Each candidate becomes either a synthesized protocol or a skip. A
  # candidate is synthesizable only when all its clauses live in one
  # module (`:cross_module` otherwise) and the derived protocol name is
  # free (`:naming_collision`). The `taken` set guards two candidates in
  # the same run from claiming the same protocol name.
  defp synthesize(candidates, parsed, write_root) do
    {synthesized, skipped, _taken} =
      Enum.reduce(candidates, {[], [], MapSet.new()}, fn cand, {ok, skip, taken} ->
        case synthesize_one(cand, parsed, write_root, taken) do
          {:ok, syn} -> {[syn | ok], skip, MapSet.put(taken, syn.protocol)}
          {:skip, reason} -> {ok, [skip_record(cand, reason) | skip], taken}
        end
      end)

    {Enum.reverse(synthesized), Enum.reverse(skipped)}
  end

  defp synthesize_one(%{modules: [_, _ | _]} = _cand, _parsed, _root, _taken),
    do: {:skip, :cross_module}

  defp synthesize_one(cand, parsed, write_root, taken) do
    protocol = protocol_name(cand)

    cond do
      MapSet.member?(taken, protocol) -> {:skip, :naming_collision}
      Code.ensure_loaded?(protocol) -> {:skip, :naming_collision}
      true -> build_synthesis(cand, protocol, parsed, write_root)
    end
  end

  defp build_synthesis(cand, protocol, parsed, write_root) do
    path = protocol_path(protocol, cand, write_root)
    rendered = render_protocol(protocol, cand, parsed)

    case existing_file_status(path, rendered) do
      :foreign ->
        {:skip, :naming_collision}

      _free_or_ours ->
        {:ok,
         %{
           protocol: protocol,
           source_module: cand.module,
           name: cand.name,
           arity: cand.arity,
           structs: cand.structs,
           path: path,
           rendered: rendered,
           name_shift?: protocol != cand.module
         }}
    end
  end

  defp skip_record(%{name: name, arity: arity, structs: structs}, reason),
    do: %{name: name, arity: arity, structs: structs, reason: reason}

  # --- protocol naming ---

  # `label` → `Catalog.Labelable`: the dispatched function name as an
  # `-able` adjective noun, rooted at the source module's parent
  # namespace. A name already ending in `able`/`ible` passes through
  # (`Enumerable` stays `Enumerable`); a trailing `e` is dropped before
  # `able` (`serialize` → `Serializable`). Falls back to a CamelCase of
  # the name when it can't be adjectivized cleanly.
  defp protocol_name(%{name: name, module: module}) do
    parent = module |> Module.split() |> Enum.drop(-1)
    Module.concat(parent ++ [protocol_basename(name)])
  end

  defp protocol_basename(name) do
    base = name |> Atom.to_string() |> String.trim_trailing("?") |> String.trim_trailing("!")

    cond do
      String.ends_with?(base, ["able", "ible"]) -> Macro.camelize(base)
      String.ends_with?(base, "e") -> Macro.camelize(String.trim_trailing(base, "e") <> "able")
      true -> Macro.camelize(base <> "able")
    end
  end

  # --- protocol rendering ---

  defp render_protocol(protocol, cand, parsed) do
    impls = Enum.map_join(struct_clauses_for(cand), "\n\n", &render_defimpl(protocol, &1))

    """
    defprotocol #{inspect(protocol)} do
      @moduledoc \"\"\"
      Protocol extracted from `#{inspect(cand.module)}.#{cand.name}/#{cand.arity}`,
      which dispatched on the first-argument struct type across:

    #{Enum.map_join(cand.structs, "\n", &"    - `#{inspect(&1)}`")}
      \"\"\"

    #{protocol_spec(cand, parsed)}  def #{cand.name}(#{protocol_head_args(cand.arity)})
    end

    #{impls}
    """
  end

  # The protocol head dispatches on the first arg (named `data` by
  # convention); any further args keep positional names.
  defp protocol_head_args(arity) do
    ["data" | Enum.map(1..(arity - 1)//1, &"arg#{&1}")] |> Enum.join(", ")
  end

  # `@spec name(t(), …) :: <agreed return>` when every implementing
  # clause that carries a matching `@spec` agrees, with the dispatch
  # type rewritten to the protocol's `t()`. Falls back to
  # `name(t(), term()…) :: term()` when specs disagree or are absent.
  defp protocol_spec(cand, parsed) do
    case agreed_return(cand, parsed) do
      {:ok, return} -> "  @spec #{cand.name}(#{spec_args(cand.arity)}) :: #{return}\n"
      :none -> "  @spec #{cand.name}(#{spec_args(cand.arity)}) :: term()\n"
    end
  end

  defp spec_args(arity), do: ["t()" | List.duplicate("term()", arity - 1)] |> Enum.join(", ")

  # Look at the `@spec name(arity)` declared in the source module just
  # above each migrated clause's family; if every one renders the same
  # return type, use it. Specs are matched by `{name, arity}` on the
  # `@spec` attributes parsed from the same module.
  defp agreed_return(cand, parsed) do
    returns =
      parsed
      |> specs_in_module(cand.module)
      |> Map.get({cand.name, cand.arity}, [])
      |> Enum.uniq()

    case returns do
      [single] -> {:ok, single}
      _ -> :none
    end
  end

  # `%{ {name, arity} => [rendered_return_type] }` for the `@spec`s in a
  # module. Parsed from the raw clause records' source via a re-walk of
  # the spec attributes — kept simple since specs are optional.
  defp specs_in_module(parsed, module) do
    parsed
    |> Enum.filter(&(&1.module == module))
    |> Enum.map(& &1.path)
    |> Enum.uniq()
    |> Enum.flat_map(&specs_in_path/1)
    |> Enum.group_by(fn {key, _ret} -> key end, fn {_key, ret} -> ret end)
    |> Map.new(fn {key, rets} -> {key, Enum.uniq(rets)} end)
  end

  defp specs_in_path(path) do
    with {:ok, src} <- File.read(path),
         {:ok, ast} <- Sourceror.parse_string(src) do
      ast |> Macro.prewalker() |> Enum.flat_map(&spec_entry/1)
    else
      _ -> []
    end
  end

  # `@spec name(args) :: return` → `{ {name, arity}, return_string }`.
  defp spec_entry({:@, _, [{:spec, _, [{:"::", _, [head, return]}]}]}) do
    case name_and_args(head) do
      {:ok, name, args} -> [{{name, length(args)}, Macro.to_string(strip_all_meta(return))}]
      :error -> []
    end
  end

  defp spec_entry(_), do: []

  defp strip_all_meta(ast), do: Macro.prewalk(ast, &strip_meta/1)
  defp strip_meta({node, meta, args}) when is_list(meta), do: {node, [], args}
  defp strip_meta(node), do: node

  # One `defimpl Protocol, for: Struct do … end`, carrying every clause
  # of that struct verbatim (a struct may have several clauses — guards,
  # field-shape overloads — and they all move together).
  defp render_defimpl(protocol, {struct, infos}) do
    clauses = Enum.map_join(infos, "\n", fn %{ast: ast} -> "  " <> Macro.to_string(ast) end)

    """
    defimpl #{inspect(protocol)}, for: #{inspect(struct)} do
    #{clauses}
    end
    """
  end

  # `[{struct, [clause_info]}]` for the candidate, struct order matching
  # the sorted struct list so output is deterministic.
  defp struct_clauses_for(%{infos: infos, structs: structs}) do
    by_struct = Enum.group_by(infos, & &1.struct)
    Enum.map(structs, fn struct -> {struct, by_struct[struct]} end)
  end

  # --- protocol file path ---

  # `lib/catalog/labeling.ex` defining `Catalog.Labeling` reveals the
  # source root `lib/`; the protocol follows the same convention →
  # `lib/catalog/labelable.ex`. Falls back to the source file's directory.
  defp protocol_path(protocol, cand, write_root) do
    source_suffix = module_path_suffix(cand.module)

    derived =
      if String.ends_with?(cand.path, source_suffix) do
        root = String.slice(cand.path, 0, String.length(cand.path) - String.length(source_suffix))
        root <> module_path_suffix(protocol)
      else
        Path.join(Path.dirname(cand.path), Macro.underscore(basename(protocol)) <> ".ex")
      end

    rooted(derived, write_root)
  end

  defp basename(mod), do: mod |> Module.split() |> List.last()
  defp module_path_suffix(mod), do: (mod |> inspect() |> Macro.underscore()) <> ".ex"

  defp rooted(path, write_root) do
    case Path.type(path) do
      :absolute -> path
      _ -> Path.join(write_root, path)
    end
  end

  defp existing_file_status(path, rendered) do
    case File.read(path) do
      {:ok, ^rendered} -> :ours
      {:ok, _other} -> :foreign
      {:error, _} -> :free
    end
  end

  defp write_protocol_file(%{path: path, rendered: rendered}) do
    File.mkdir_p!(Path.dirname(path))

    case File.read(path) do
      {:ok, ^rendered} -> :ok
      _ -> File.write!(path, rendered)
    end
  end

  # --- source rewriting (clause removal + call-site shift) ---

  # In the source module, two edits per synthesized protocol: remove the
  # migrated `def` clauses (they now live in the `defimpl`s), and — only
  # when the protocol name differs from the source module — rewrite
  # static call sites of `Module.fun(args)` to `Protocol.fun(args)`.
  defp rewrite_source(source, synthesized) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        patches =
          clause_removal_patches(ast, synthesized) ++ call_site_patches(ast, synthesized)

        patch_or_passthrough(patches, source)

      {:error, _} ->
        source
    end
  end

  # A migrated clause is a `def name(args)` inside the source module
  # whose dispatch arg is one of the protocol's structs. Remove its full
  # source range (the whole `def … end` / `def …, do: …`).
  defp clause_removal_patches(ast, synthesized) do
    targets =
      Map.new(synthesized, fn s -> {{s.source_module, s.name, s.arity}, MapSet.new(s.structs)} end)

    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&module_removal_patches(&1, targets))
  end

  defp module_removal_patches({:defmodule, _, [name_ast, [{_do, body}]]}, targets) do
    case alias_to_module(name_ast) do
      {:ok, module} ->
        body
        |> body_to_exprs()
        |> Enum.flat_map(&removal_patch(&1, module, targets))

      :error ->
        []
    end
  end

  defp module_removal_patches(_node, _targets), do: []

  defp removal_patch({:def, _, [head | _]} = node, module, targets) do
    with {:ok, name, args} <- name_and_args(strip_when(head)),
         structs when not is_nil(structs) <- Map.get(targets, {module, name, length(args)}),
         {:ok, struct} <- dispatch_struct(args, 0),
         true <- MapSet.member?(structs, struct) do
      [removal_patch_for(node)]
    else
      _ -> []
    end
  end

  # The migrated function's `@spec` is now orphaned (its function lives
  # in the protocol) — leaving it would emit a spec-for-undefined-function
  # warning. Remove it whenever its `{name, arity}` matches a migrated
  # clause in this module.
  defp removal_patch({:@, _, [{:spec, _, [{:"::", _, [spec_head | _]}]}]} = node, module, targets) do
    case name_and_args(spec_head) do
      {:ok, name, args} ->
        if Map.has_key?(targets, {module, name, length(args)}),
          do: [removal_patch_for(node)],
          else: []

      :error ->
        []
    end
  end

  defp removal_patch(_node, _module, _targets), do: []

  defp removal_patch_for(node) do
    range = Sourceror.get_range(node)
    %{change: "", range: range, preserve_indentation: false}
  end

  # Static call sites `Module.fun(args)` → `Protocol.fun(args)`, only
  # for synthesized protocols whose name shifted. Protocol dispatch is
  # otherwise transparent — same module + function name means no edit.
  defp call_site_patches(ast, synthesized) do
    shifts =
      synthesized
      |> Enum.filter(& &1.name_shift?)
      |> Map.new(fn s -> {{s.source_module, s.name, s.arity}, s.protocol} end)

    if shifts == %{} do
      []
    else
      ast |> Macro.prewalker() |> Enum.flat_map(&call_site_patch(&1, shifts))
    end
  end

  defp call_site_patch({{:., _, [recv_ast, fun]}, _, args} = node, shifts)
       when is_atom(fun) and is_list(args) do
    with {:ok, module} <- alias_to_module(recv_ast),
         protocol when not is_nil(protocol) <- Map.get(shifts, {module, fun, length(args)}) do
      [rewrite_receiver_patch(node, protocol)]
    else
      _ -> []
    end
  end

  defp call_site_patch(_node, _shifts), do: []

  # Replace only the receiver alias node, leaving the `.fun(args)` tail
  # untouched — a precise patch that survives multi-line arg lists.
  defp rewrite_receiver_patch({{:., _, [recv_ast, _fun]}, _, _args}, protocol) do
    range = Sourceror.get_range(recv_ast)
    %{change: inspect(protocol), range: range, preserve_indentation: false}
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  # --- name-family detection (the "near-miss" axis) ---

  # A weaker, orthogonal signal to struct dispatch: a *naming* family
  # that **converges on one operation**.
  # `position_to_result`/`item_to_result`/… share the suffix stem
  # `to_result` AND all build a `%Result{}`; `subscribe_items`/
  # `subscribe_brands`/… share the prefix `subscribe` AND all call
  # `PubSub.subscribe`. The varying token (`position`, `item`, …) is the
  # would-be type — the codebase hand-rolls dispatch through the function
  # name instead of a value.
  #
  # The convergence check is what makes this useful rather than noise. A
  # name-stem alone is worthless: `delete_asset`/`delete_brand`/… share
  # `delete` but each does something different (a Multi here, a
  # `Repo.delete` there) — that's a CRUD context API, not a protocol. So
  # a family only counts when every member's body has the **same**
  # outermost signature (`{:struct, Result}` or `{:call, :subscribe}`).
  #
  # Even then it's a *hint*, not an extractable candidate: the functions
  # may take maps, not structs (the `*_to_result` family does exactly
  # that — it runs on raw `select` projections, so a protocol couldn't
  # dispatch on them). So name-families land in their own plan key, never
  # in `candidates`. They point a human at a spot, they don't drive a
  # rewrite.
  defp name_families(parsed, min_family) do
    # name → the set of body signatures across its clauses (a multi-clause
    # function with one consistent return shape collapses to one sig).
    sigs_by_name =
      parsed
      |> Enum.group_by(& &1.name, & &1.body_head)
      |> Map.new(fn {name, heads} -> {name, heads |> Enum.reject(&is_nil/1) |> Enum.uniq()} end)

    names = Map.keys(sigs_by_name)
    tokenized = Enum.map(names, fn name -> {name, camel_or_snake_tokens(name)} end)

    (families_by_stem(tokenized, :suffix, min_family, sigs_by_name) ++
       families_by_stem(tokenized, :prefix, min_family, sigs_by_name))
    # When several stem lengths yield the same member set (`result` and
    # `to_result` for the same 7 functions), keep the longest — it is
    # the more specific, more informative stem. Longest-first before the
    # dedup makes `uniq_by` keep it.
    |> Enum.sort_by(&(-String.length(to_string(&1.stem))))
    |> Enum.uniq_by(& &1.members)
    |> Enum.sort_by(&{-length(&1.members), to_string(&1.stem)})
    |> drop_subsumed()
  end

  # A `subscribe_item` family (members ⊆ a larger `subscribe` family,
  # same signature) is a redundant sub-view of it. Drop it: it points at
  # the same spot. Families are pre-sorted largest-first, so a later one
  # subsumed by an earlier one is the redundant view.
  defp drop_subsumed(families) do
    Enum.reduce(families, [], fn fam, kept ->
      if Enum.any?(kept, &subsumes?(&1, fam)), do: kept, else: [fam | kept]
    end)
    |> Enum.reverse()
  end

  defp subsumes?(larger, smaller) do
    larger.signature == smaller.signature and
      MapSet.subset?(MapSet.new(smaller.members), MapSet.new(larger.members))
  end

  # Group function names by a shared leading (`:prefix`) or trailing
  # (`:suffix`) token run, then keep only the groups that converge on a
  # single body signature. A family needs `min_family` distinct members
  # AND distinct discriminators, a non-stopword stem, and one shared sig.
  defp families_by_stem(tokenized, position, min_family, sigs_by_name) do
    tokenized
    |> Enum.flat_map(fn {name, tokens} -> stem_keys(name, tokens, position) end)
    |> Enum.group_by(fn {stem, _name, _disc} -> stem end, fn {_stem, name, disc} ->
      {name, disc}
    end)
    |> Enum.reject(fn {stem, _members} -> stem in @stopword_stems end)
    |> Enum.flat_map(fn {stem, members} ->
      build_family(stem, members, position, min_family, sigs_by_name)
    end)
  end

  # Each name contributes one stem candidate per possible shared run
  # length, anchored at the relevant end. `position_to_result` at
  # `:suffix` yields stems `result`, `to_result` (and `position_to_result`,
  # dropped — a full-name stem has no discriminator). The discriminator
  # is everything outside the stem run.
  defp stem_keys(name, tokens, position) do
    count = length(tokens)

    for run <- 1..(count - 1)//1 do
      {stem_tokens, disc_tokens} = split_run(tokens, run, position)
      {Enum.join(stem_tokens, "_"), name, Enum.join(disc_tokens, "_")}
    end
  end

  defp split_run(tokens, run, :suffix) do
    {stem, disc} = Enum.split(tokens, -run)
    {disc, stem}
  end

  defp split_run(tokens, run, :prefix) do
    Enum.split(tokens, run)
  end

  defp build_family(stem, members, position, min_family, sigs_by_name) do
    discriminators = members |> Enum.map(fn {_name, disc} -> disc end) |> Enum.uniq()
    member_names = members |> Enum.map(fn {name, _disc} -> name end) |> Enum.uniq() |> Enum.sort()

    with true <- length(member_names) >= min_family,
         true <- length(discriminators) >= min_family,
         {:ok, signature} <- shared_signature(member_names, sigs_by_name) do
      [
        %{
          stem: String.to_atom(stem),
          position: position,
          members: member_names,
          discriminators: Enum.sort(discriminators),
          signature: signature
        }
      ]
    else
      _ -> []
    end
  end

  # Standard-library / framework operations that are too generic to mark
  # a *domain* family. Many name families converge on one of these
  # (`maybe_filter_* |> where`, `list_* |> Repo.all`, `*_subtotals |>
  # Enum.reduce`) — a real convergence, but on plumbing, not on a shared
  # contract worth a protocol. Building a struct is always specific, so
  # only `{:call, fun}` signatures are filtered, never `{:struct, _}`.
  @generic_ops ~w(where all new get fetch from join select preload limit order_by
                  reduce reduce_while map filter each into flat_map reject sort_by
                  group_by count sum take drop uniq zip concat
                  put_flash assign assign_new push_event redirect put_session
                  run call apply build put merge update delete insert)a

  # The family converges only when every member resolves to exactly the
  # same single body signature AND that signature is a *specific*
  # operation (a struct build, or a non-generic named call). A member
  # with no signature (opaque body) or two members disagreeing breaks
  # convergence — that's a CRUD-style name collision, not a protocol.
  defp shared_signature(member_names, sigs_by_name) do
    sigs = Enum.map(member_names, fn name -> Map.get(sigs_by_name, name, []) end)

    with [signature] <- sigs |> List.flatten() |> Enum.uniq(),
         true <- Enum.all?(sigs, &(&1 == [signature])),
         true <- specific_operation?(signature) do
      {:ok, signature}
    else
      _ -> :error
    end
  end

  defp specific_operation?({:struct, _mod}), do: true
  defp specific_operation?({:call, fun}), do: fun not in @generic_ops

  defp camel_or_snake_tokens(name) do
    name
    |> Atom.to_string()
    |> String.split("_", trim: true)
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
