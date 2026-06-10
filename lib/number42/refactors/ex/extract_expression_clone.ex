defmodule Number42.Refactors.Ex.ExtractExpressionClone do
  @moduledoc """
  **PROTOTYP / Proof-of-Concept — NICHT production-ready.**

  Expression-level (sub-tree) clone detector. Where
  `ExtractIntraModuleClone` & friends hash whole `def`/`defp` bodies and
  only fire above `@default_min_mass 20`, this prototype walks *into* the
  bodies and treats **statement groups** (contiguous slices of a `do`
  block) as clone candidates. Structurally-equal groups that occur in two
  or more functions get lifted into one shared `defp` and replaced by a
  call to it.

      # before
      defmodule M do
        def a(order) do
          subtotal = Enum.sum(order.lines)
          taxed = subtotal * 1.19
          {subtotal, taxed}
        end

        def b(cart) do
          subtotal = Enum.sum(cart.lines)
          taxed = subtotal * 1.19
          {subtotal, taxed}
        end
      end

      # after (conceptually — see "Was der PoC kann / nicht kann")
      defmodule M do
        def a(order), do: extracted_clone(order)
        def b(cart), do: extracted_clone(cart)

        defp extracted_clone(order) do
          subtotal = Enum.sum(order.lines)
          taxed = subtotal * 1.19
          {subtotal, taxed}
        end
      end

  ## Warum ein eigener Refactor (statt ExtractIntraModuleClone zu erweitern)

  Die Funktions-Level-Finder rewriten den *Kopf* einer Verlierer-Klausel
  (`def loser(args), do: winner(args)`). Hier ist der Eingriff ein anderer:
  ein Sub-Block *innerhalb* eines Bodies wird durch einen Call ersetzt und
  ein frischer Helper entsteht. Die komplette Sicherheits-Analyse (freie
  Variablen → Parameter, live-out → Rückgabe, Control-Flow, Overlap) ist
  neu und würde das bestehende, single-purpose Modul aufblähen. Separat
  bleibt der PoC reviewbar und lässt die laufenden Finder unberührt.

  ## Wie Sammeln + Fingerprinting funktioniert

  Pro `def`/`defp`-Body werden alle *kontiguierlichen Statement-Gruppen*
  ab Länge `@min_group` enumeriert (eine Gruppe = `block[i..j]`). Jede
  Gruppe wird über `AstHelpers.inline_pipes/1` (Pipe-Zucker normalisiert)
  und Variablen-Renaming (de-Bruijn-artige Indizes, identisch zur Logik in
  `ExtractIntraModuleClone`) zu einem strukturellen Fingerprint gehasht.
  Gruppen mit gleichem Hash *und* gleicher Form der freien Variablen
  (Anzahl/Reihenfolge) über ≥2 Funktionen bilden eine Klon-Gruppe. Die
  Masse (`node_count`) muss `>= :min_mass` (Default 8, kleiner als bei den
  Funktions-Findern) sein.

  ## SICHERHEITS-FALLEN (siehe auch Bericht)

  Der PoC ist bewusst konservativ. Eine Gruppe wird **übersprungen**, wenn:

    * **live-out**: der Block bindet eine Variable, die *nach* dem Block im
      selben Body noch gelesen wird. Ein Helper-Call kann nur EINEN Wert
      zurückgeben; mehrere live-out-Variablen müsste man als Tupel
      zurückgeben und am Call-Site destrukturieren. PoC: skip bei
      `live_out != []` außer der triviale Fall "Block ist das Body-Ende und
      sein Wert ist der Rückgabewert". (Production: Tupel-Rückgabe +
      Destrukturierung.)
    * **Control-Flow**: der Block enthält `raise`/`throw`/`with`/`^`(Pin)/
      `&`-Capture-Refs/`@`-Modulattribut/`__MODULE__` & Co. Solche Blöcke
      sind nicht scope-neutral extrahierbar; PoC skippt sie.
    * **freie Variablen**: werden via `AstHelpers.free_vars/2` ermittelt und
      zu Helper-Parametern. Stimmen die freien-Var-*Mengen* zwischen den
      Klon-Instanzen strukturell nicht überein, skip.
    * **Overlap**: pro Body wird nur die *größte* nicht-überlappende
      Gruppe je Position gewählt (greedy, längste zuerst), damit ein
      äußerer und ein in ihm enthaltener Klon nicht doppelt extrahiert
      werden.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.AstHelpers
  alias Number42.Refactors.BlockSegmentation

  @default_min_mass 8
  @min_group 2

  # Formen, die einen Block als unsicher-zu-extrahieren markieren.
  @control_flow_forms [
    :raise,
    :throw,
    :reraise,
    :with,
    :receive,
    :try,
    :^,
    :@
  ]

  @reserved_macros [:__MODULE__, :__ENV__, :__CALLER__, :__DIR__, :__STACKTRACE__]

  @impl Number42.Refactors.Refactor
  def description,
    do: "PROTOTYPE: expression-level clone extraction (sub-blocks across functions)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    PROTOTYPE. Finds structurally identical contiguous statement groups
    that recur across two or more functions in a module and lifts them
    into one shared defp, replacing each occurrence with a call. Deliberately
    conservative: skips blocks with live-out bindings, control-flow
    (raise/with/pin/capture/module-attr), or mismatched free-variable shape.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    min_mass = Keyword.get(opts, :min_mass, @default_min_mass)

    source
    |> Sourceror.parse_string()
    |> apply_to_parse_result(min_mass, source)
  end

  defp apply_to_parse_result({:ok, ast}, min_mass, source),
    do: ast |> apply_to_ast(min_mass, source)

  defp apply_to_parse_result({:error, _}, _min_mass, source), do: source

  defp apply_to_ast(ast, min_mass, source) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [_name, [{_do, body}]]} = mod_node ->
        plan_for_module(mod_node, body, min_mass, source)

      _ ->
        []
    end)
    |> patch_or_passthrough(source)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  # --- candidate collection ---------------------------------------------

  defp plan_for_module(mod_node, body, min_mass, source) do
    clauses = body |> AstHelpers.body_to_exprs() |> Enum.filter(&def_clause?/1)

    candidates =
      clauses
      |> Enum.flat_map(&candidates_in_clause(&1, min_mass))

    groups =
      candidates
      |> Enum.group_by(& &1.fingerprint)
      |> Enum.filter(fn {_fp, occs} -> length(occs) >= 2 end)

    case groups do
      [] -> []
      _ -> emit_plan(groups, mod_node, source)
    end
  end

  defp def_clause?({kind, _, [_head, body_kw]})
       when kind in [:def, :defp] and is_list(body_kw),
       do: true

  defp def_clause?(_), do: false

  # Every contiguous statement group `stmts[i..j]` of length >= @min_group
  # in this clause's `do` block becomes a candidate (unless rejected by a
  # safety gate). Free variables are computed against the names in scope at
  # the group's start (clause params + everything bound by earlier stmts).
  defp candidates_in_clause({_kind, _, [head, body_kw]} = clause, min_mass) do
    body_ast = body_kw |> Keyword.values() |> List.first()
    stmts = AstHelpers.body_to_exprs(body_ast)
    param_names = head_param_names(head)
    segments = BlockSegmentation.segment(stmts)

    # NOTE: overlap resolution is intentionally NOT applied here. A larger
    # *non-clone* group (distinct prefixes between functions) would
    # greedily suppress a smaller genuine tail-clone before we even know
    # which groups recur. Overlap is resolved at emit time, on the
    # occurrences that actually form a clone group (see resolve_overlaps/1).
    contiguous_groups(stmts)
    |> Enum.flat_map(fn {i, j} ->
      group_stmts = Enum.slice(stmts, i..j)
      candidate_for_group(group_stmts, i, j, stmts, segments, param_names, min_mass, clause)
    end)
  end

  defp head_param_names({:when, _, [inner | _]}), do: head_param_names(inner)

  defp head_param_names({_name, _, args}) when is_list(args),
    do: args |> Enum.flat_map(&AstHelpers.pattern_var_names/1) |> MapSet.new()

  defp head_param_names(_), do: MapSet.new()

  defp contiguous_groups(stmts) do
    n = length(stmts)

    for i <- 0..(n - 1)//1,
        j <- (i + @min_group - 1)..(n - 1)//1,
        j < n,
        do: {i, j}
  end

  defp candidate_for_group(group_stmts, i, j, stmts, segments, param_names, min_mass, clause) do
    group_ast = wrap_block(group_stmts)
    scope_at_start = scope_before(segments, i, param_names)
    free = AstHelpers.free_vars(group_ast, scope_at_start)
    live = live_out_of_group(segments, j, stmts)

    cond do
      node_mass(group_ast) < min_mass ->
        []

      unsafe_control_flow?(group_ast) ->
        []

      # live-out > trivial: the group binds names read later in the body.
      # Extracting it would lose those bindings. PoC: only allow the
      # trivial case where the group is the tail of the body (j == last)
      # — then its value is the function's return value and nothing is
      # read after it.
      not MapSet.equal?(live, MapSet.new()) and j != length(stmts) - 1 ->
        []

      true ->
        [
          %{
            ast: group_ast,
            clause_key: clause_key(clause),
            free_vars: free,
            fingerprint: fingerprint(group_ast, free),
            range: {i, j},
            stmts: group_stmts
          }
        ]
    end
  end

  # Identity of the host clause so overlap is only checked among groups in
  # the *same* function body (ranges are statement indices, meaningful
  # only within one clause).
  defp clause_key({_kind, _, [head | _]}), do: AstHelpers.extract_fn_signature(strip_when(head))

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp wrap_block([single]), do: single
  defp wrap_block(stmts), do: {:__block__, [], stmts}

  # Names in scope when the group starts: clause params + everything bound
  # by statements before index `i`.
  defp scope_before(segments, i, param_names) do
    segments
    |> Enum.take(i)
    |> Enum.reduce(param_names, fn seg, acc -> MapSet.union(acc, seg.writes) end)
  end

  # Variables written inside the group (segments i..j) that are read by
  # some statement strictly after j. Reuses the BlockSegmentation live-out
  # idea, scoped to this group's own end-cut.
  defp live_out_of_group(segments, j, _stmts) do
    BlockSegmentation.live_out(segments, j + 1)
  end

  # --- overlap resolution ------------------------------------------------

  # Greedy, longest-first: accept an occurrence only if its statement
  # range doesn't overlap one already accepted *in the same clause*.
  # Occurrences in different clauses can never overlap (ranges are
  # per-clause indices), so the clause_key guards that comparison. Keeps
  # an outer clone from being double-extracted with an inner one when the
  # same clause hosts two members of the chosen group.
  defp resolve_overlaps(occurrences) do
    occurrences
    |> Enum.sort_by(fn %{range: {i, j}} -> {-(j - i), i} end)
    |> Enum.reduce([], fn occ, accepted ->
      if Enum.any?(accepted, &overlaps_in_same_clause?(&1, occ)) do
        accepted
      else
        [occ | accepted]
      end
    end)
    |> Enum.reverse()
  end

  defp overlaps_in_same_clause?(%{clause_key: k, range: a}, %{clause_key: k, range: b}),
    do: ranges_overlap?(a, b)

  defp overlaps_in_same_clause?(_, _), do: false

  defp ranges_overlap?({a1, a2}, {b1, b2}), do: a1 <= b2 and b1 <= a2

  # --- safety gates ------------------------------------------------------

  defp unsafe_control_flow?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {form, _, _} when form in @control_flow_forms -> true
      {:&, _, [n]} when is_integer(n) -> true
      {name, _, ctx} when is_atom(name) and is_atom(ctx) and name in @reserved_macros -> true
      _ -> false
    end)
  end

  # --- fingerprint -------------------------------------------------------

  # Structural hash modulo metadata, pipe-sugar, and variable renaming —
  # plus the arity/shape of the free-variable list so that two groups only
  # bucket together if they'd produce the same helper signature.
  defp fingerprint(ast, free_vars) do
    normalized =
      ast
      |> AstHelpers.inline_pipes()
      |> strip_meta()
      |> rename_vars()

    {length(free_vars), :erlang.phash2(normalized)}
    |> :erlang.phash2()
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
      AstHelpers.underscore?(name) ->
        {node, acc}

      Map.has_key?(acc, name) ->
        {{:"$var", [], [Map.fetch!(acc, name)]}, acc}

      true ->
        idx = map_size(acc)
        {{:"$var", [], [idx]}, Map.put(acc, name, idx)}
    end
  end

  defp rename_var_node(node, acc), do: {node, acc}

  defp node_mass(ast) do
    {_, count} = Macro.prewalk(ast, 0, fn node, acc -> {node, acc + 1} end)
    count
  end

  # --- emission ----------------------------------------------------------

  # PoC scope: extract ONE clone group per run (keeps the rewrite
  # obviously-correct and idempotent — a re-run finds the next group).
  # Pick the highest-value group (mass * occurrence count), resolve
  # overlaps among its occurrences, then emit:
  #   * one shared `defp helper(<free vars>) do ... end` before the
  #     module's closing `end`
  #   * one call-site replacement per surviving occurrence
  defp emit_plan(groups, mod_node, source) do
    case best_group(groups) do
      {:ok, occurrences} -> emit_group(occurrences, mod_node, source)
      :none -> []
    end
  end

  defp best_group(groups) do
    groups
    |> Enum.map(fn {_fp, occs} -> resolve_overlaps(occs) end)
    |> Enum.filter(&(length(&1) >= 2))
    |> case do
      [] ->
        :none

      candidates ->
        {:ok, Enum.max_by(candidates, &group_value/1)}
    end
  end

  defp group_value([first | _] = occs), do: node_mass(first.ast) * length(occs)

  defp emit_group([first | _] = occurrences, mod_node, source) do
    helper_name = synth_name(occurrences)
    helper_args = first.free_vars

    helper_patch = helper_append_patch(mod_node, helper_name, helper_args, first.ast)

    call_patches =
      occurrences
      |> Enum.flat_map(&occurrence_call_patch(&1, helper_name, source))

    case call_patches do
      [] -> []
      _ -> [helper_patch | call_patches]
    end
  end

  defp synth_name(_occurrences), do: :extracted_clone

  # Replace the occurrence's source range with `helper(args)`. The free
  # vars of THIS occurrence (in fingerprint-canonical order) are the call
  # arguments — they line up positionally with the helper params because
  # both derive from the same canonical ordering.
  defp occurrence_call_patch(%{ast: ast, free_vars: free}, helper_name, source) do
    case range_of_group(ast, source) do
      {:ok, range} ->
        call = render_call(helper_name, free)
        [%{change: call, range: range}]

      :error ->
        []
    end
  end

  defp range_of_group(ast, _source) do
    case Sourceror.get_range(ast) do
      %{end: e, start: s} -> {:ok, %{end: e, start: s}}
      _ -> :error
    end
  end

  defp render_call(name, []), do: "#{name}()"
  defp render_call(name, args), do: "#{name}(#{Enum.join(args, ", ")})"

  defp helper_append_patch({:defmodule, _, _} = mod_node, name, args, body_ast) do
    %{end: end_pos} = Sourceror.get_range(mod_node)

    rendered = render_helper(name, args, body_ast)
    insert_pos = [line: end_pos[:line], column: 1]

    %{change: rendered, range: %{end: insert_pos, start: insert_pos}}
  end

  defp render_helper(name, args, body_ast) do
    head =
      case args do
        [] -> "#{name}()"
        _ -> "#{name}(#{Enum.join(args, ", ")})"
      end

    body_src = body_ast |> Sourceror.to_string() |> indent("    ")

    "  defp #{head} do\n#{body_src}\n  end\n"
  end

  defp indent(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end
end
