defmodule Number42.Refactors.Ex.ExtractExpressionClone do
  @moduledoc """
  Expression-level (sub-tree) clone detector. Where
  `ExtractIntraModuleClone` & friends hash whole `def`/`defp` bodies and
  only fire above `@default_min_mass 20`, this refactor walks *into* the
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

      # after
      defmodule M do
        def a(order), do: compute_subtotal_and_taxed(order)
        def b(cart), do: compute_subtotal_and_taxed(cart)

        defp compute_subtotal_and_taxed(order) do
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
  bleibt der Refactor reviewbar und lässt die laufenden Finder unberührt.

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

  ## Nutzen-Schwelle (Slice 3 — Noise-Filter)

  `:min_mass` allein trennt triviale von echten Klonen nicht: ein
  2-Zeiler `scope = socket.assigns.current_scope; item =
  socket.assigns.item` hat wegen der verschachtelten Map-Zugriffe schon
  Masse ~19, mehr als ein echter 3-Zeiler-`Enum.sum`-Block. Slice 3 führt
  daher zwei orthogonale Schwellen ein, die am rohen `mass`-Filter
  vorbeigehende Trivialitäten aussieben:

    * **`:max_live_out`** (Default 3) — eine Gruppe mit mehr als so vielen
      live-out-Variablen wird verworfen. Ein Helper, der ein 8-Tupel
      zurückgibt und an jeder Call-Site `{a, b, c, d, e, f, g, h} =
      helper(…)` destrukturiert, ist *schlechter* lesbar als die inline-
      Statements — die Extraktion wäre eine Verschlechterung. Harte
      Grenze, analog `max_carriers` in `SplitPipeableResponsibilities`.

    * **`:min_savings`** (Default 12) — der geschätzte Netto-Nutzen einer
      Extraktion muss die Schwelle erreichen. Nutzen ≈ gesparte
      Duplizierung minus Overhead:

          savings = block_mass * (occurrences - 1)
                    - occurrences * (1 + free_vars + live_out)

      Der pro-Occurrence-Overhead bestraft breite Signaturen (jeder
      free-var ist ein Call-Argument, jeder live-out eine
      Destrukturierung) — genau die Lesbarkeitskosten, die einen
      `{scope, item} = extracted_clone(socket)`-Ersatz wertlos machen. Ein
      2-Occurrence-Trivialklon liegt unter der Schwelle und wird
      übersprungen; echte Klone (mehr Occurrences oder mehr echte Arbeit
      pro Statement) bleiben darüber. Default 12 ist konservativ gewählt:
      er siebt die `{scope, x}`-2-Zeiler aus, lässt aber die im
      position-db-Dry-Run beobachteten echten Klone (provider_runner,
      configurator, er_diagram, sort/limit-Gruppen) durch.

  ## live-out (Slice 1 — Tupel-Rückgabe)

  Bindet der Block eine Variable, die *nach* dem Block im selben Body noch
  gelesen wird, wird er **nicht mehr übersprungen**, sondern via
  Wert-Rückgabe gehandhabt (Slice 1):

    * Der Helper gibt die live-out-Menge zurück — ein-elementig als bare
      Var (`… end`), mehr-elementig als Tupel (`{a, b} end`).
    * Jeder Call-Site destrukturiert in seine *eigenen* Namen:
      `a = extracted_clone(args)` bzw. `{a, b} = extracted_clone(args)`.
    * **Ordnung der Tupel-Elemente**: nach erstem strukturellem Vorkommen
      im Block (dieselbe kanonische de-Bruijn-Reihenfolge, die
      `rename_vars/1` für den Hash benutzt). Slot N referenziert in jeder
      Occurrence dieselbe Binding-Position — verschiedene Renamings
      (`{subtotal, taxed}` vs `{sub, tax}`) können so nicht kreuz-verdrahten.
    * **Bucket-Schutz**: `length(live_out)` geht in den Fingerprint ein
      (analog `length(free_vars)`). Strukturell gleiche Blöcke mit
      *unterschiedlicher* live-out-Anzahl landen in verschiedenen Buckets
      und werden nie zusammen extrahiert (sonst würde ein bare-Return-Fall
      ein Tupel destrukturieren o.ä.).

  ## Helper-Naming + Kollisions-Sicherheit (Slice 2)

  Der Helper heißt nicht mehr fest `:extracted_clone`, sondern wird über
  `Number42.Refactors.HelperNaming` aus dem Block selbst benannt: ein Verb
  aus dem dominanten Call des Blocks (`Enum.sum` → `compute`) plus dem
  live-out-Objekt → `compute_subtotal_and_taxed`. Da ein Klon über mehrere
  Funktionen läuft, gibt es keinen einzelnen Host-Namen — Naming-Basis ist
  der Block (Statements → Verb, live-out → Objekt), nicht eine Host-Funktion.
  `host` ist daher `nil`; lässt sich kein Name ableiten, bleibt
  `:extracted_clone` als ehrlicher Fallback.

  Der Name wird **einmal pro Klon-Gruppe** abgeleitet (aus der ersten
  Occurrence) und für **alle** Occurrences verwendet — es ist EIN
  gemeinsamer Helper. Da alle Occurrences strukturell gleich sind, stimmen
  Verb und Objekt über alle überein.

  Kollisions-Sicherheit (via `HelperNaming`): der Name kollidiert nie mit
  einem existierenden `def`/`defp` im Modul und schattet keinen live-out-
  oder Parameter-Namen. Ist ein abgeleiteter Name belegt, weicht der
  Refactor auf den nächsten freien Kandidaten aus
  (`compute_subtotal_and_taxed` belegt → `subtotal_and_taxed`). Ist selbst
  der Fallback belegt, wird die Extraktion **übersprungen** statt einen
  kaputten Namen zu emittieren (analog `ExtractFunctionFromBlock`).

  ## SICHERHEITS-FALLEN (siehe auch Bericht)

  Der PoC ist bewusst konservativ. Eine Gruppe wird **übersprungen**, wenn:

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

  ## Gruppen-Auswahl (Slice 3 — Nutzen statt roher Masse)

  Pro Pass wird *eine* Klon-Gruppe extrahiert (re-run findet die
  nächste). Die Auswahl rankt nicht mehr nach roher Masse
  (`mass * occurrences`), sondern nach **Netto-Nutzen** (`group_value/1`,
  derselbe `savings`-Term wie die `:min_savings`-Schwelle). Das löst die
  greedy-Überlappung an `item_live`: dort gewann früher die *größte*
  Gruppe (ein 8-Tupel-Return = Verschlechterung) und wurde dann
  nachträglich zerlegt. Jetzt scheidet die 8-Tupel-Gruppe schon an
  `:max_live_out` aus, und unter den verbleibenden gültigen Gruppen
  gewinnt die nutzenstärkste — bevorzugt mehrere kleine sinnvolle Gruppen
  (`fetch_sort_field_and_sort_dir`, `fetch_limit_and_offset`) statt einer
  Riesen-Tupel-Gruppe.

  Voll-optimales Set-Cover (mehrere disjunkte Gruppen *gleichzeitig* in
  einem Pass, NP-hart) ist bewusst **nicht** gebaut: die
  Nutzen-Rankings + `:max_live_out` lösen das beobachtete
  Verschlechterungs-Problem, und Idempotenz konvergiert ohnehin über
  re-runs (ein zweiter Pass greift die nächstbeste nicht-überlappende
  Gruppe). Echtes simultanes Set-Cover bleibt ein dokumentierter
  Folge-Slice.

  ## Default-OFF (opt-in only)

  Disabled by default — `transform/2` ist ein no-op, solange die eigenen
  opts nicht `enabled: true` tragen. Cross-function-Extraktion ist der
  aggressivste Eingriff der Refactor-Familie (ein frischer geteilter
  Helper, freie Variablen → Parameter, live-out → Tupel-Rückgabe über
  mehrere Funktionen). Auch mit Nutzen-Schwelle und semantischem Naming
  bleibt die Frage „ist dieser Klon *konzeptionell* einer?" eine
  Urteilssache. Pro Projekt opt-in, wo der Trade gewünscht ist:

      configured_modules: [
        {Number42.Refactors.Ex.ExtractExpressionClone, enabled: true}
      ]
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.AstHelpers
  alias Number42.Refactors.BlockSegmentation
  alias Number42.Refactors.HelperNaming

  @default_min_mass 8
  @default_min_savings 12
  @default_max_live_out 3
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
    do: "Expression-level clone extraction (sub-blocks across functions, default-OFF)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Finds structurally identical contiguous statement groups that recur
    across two or more functions in a module and lifts them into one
    shared defp, replacing each occurrence with a call. Live-out bindings
    (names read after the block) are returned from the helper — bare for
    one, a tuple for several — and destructured at each call site.
    Deliberately conservative: skips blocks with control-flow
    (raise/with/pin/capture/module-attr) or mismatched free-variable shape,
    and only extracts when the estimated net savings clear `:min_savings`
    and the live-out width stays within `:max_live_out`. Default-OFF —
    opt in per project with `enabled: true`.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      source
      |> Sourceror.parse_string()
      |> apply_to_parse_result(config(opts), source)
    else
      source
    end
  end

  # Thresholds gathered once: raw block mass floor, net-savings floor, and
  # the hard live-out-width cap. Threaded through collection and selection
  # as a single map so the safety knobs travel together.
  defp config(opts) do
    %{
      min_mass: Keyword.get(opts, :min_mass, @default_min_mass),
      min_savings: Keyword.get(opts, :min_savings, @default_min_savings),
      max_live_out: Keyword.get(opts, :max_live_out, @default_max_live_out)
    }
  end

  defp apply_to_parse_result({:ok, ast}, cfg, source),
    do: ast |> apply_to_ast(cfg, source)

  defp apply_to_parse_result({:error, _}, _cfg, source), do: source

  defp apply_to_ast(ast, cfg, source) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [_name, [{_do, body}]]} = mod_node ->
        plan_for_module(mod_node, body, cfg, source)

      _ ->
        []
    end)
    |> patch_or_passthrough(source)
  end

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  # --- candidate collection ---------------------------------------------

  defp plan_for_module(mod_node, body, cfg, source) do
    clauses = body |> AstHelpers.body_to_exprs() |> Enum.filter(&def_clause?/1)
    existing_names = def_names(clauses)

    candidates =
      clauses
      |> Enum.flat_map(&candidates_in_clause(&1, cfg))

    groups =
      candidates
      |> Enum.group_by(& &1.fingerprint)
      |> Enum.filter(fn {_fp, occs} -> length(occs) >= 2 end)

    case groups do
      [] -> []
      _ -> emit_plan(groups, mod_node, existing_names, cfg, source)
    end
  end

  # All `def`/`defp` names already defined in the module. The synthesised
  # helper's name must avoid these (a fresh `defp` colliding with an
  # existing definition would either redefine it or split a clause group).
  defp def_names(clauses) do
    clauses
    |> Enum.flat_map(fn {_kind, _, [head | _]} ->
      case AstHelpers.extract_fn_signature(strip_when(head)) do
        {name, _args} -> [name]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp def_clause?({kind, _, [_head, body_kw]})
       when kind in [:def, :defp] and is_list(body_kw),
       do: true

  defp def_clause?(_), do: false

  # Every contiguous statement group `stmts[i..j]` of length >= @min_group
  # in this clause's `do` block becomes a candidate (unless rejected by a
  # safety gate). Free variables are computed against the names in scope at
  # the group's start (clause params + everything bound by earlier stmts).
  defp candidates_in_clause({_kind, _, [head, body_kw]} = clause, cfg) do
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
      candidate_for_group(group_stmts, i, j, segments, param_names, cfg, clause)
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

  defp candidate_for_group(group_stmts, i, j, segments, param_names, cfg, clause) do
    group_ast = wrap_block(group_stmts)
    scope_at_start = scope_before(segments, i, param_names)
    # Flow-sensitive: a name read before its own (re)binding inside the
    # group is free. `socket = socket |> f()` reads `socket` on the RHS
    # before rebinding it, so `socket` must become a helper parameter; the
    # set-based `free_vars/2` would cancel it via `bound_in` and emit a
    # helper that references an undefined `socket`.
    free = AstHelpers.free_vars_in_order(group_stmts, scope_at_start)
    # live-out in canonical structural order (see live_out_of_group/3): the
    # names the group itself binds that some later statement still reads. An
    # empty list means the trivial tail case (nothing read after the group).
    live = live_out_of_group(group_ast, segments, j)

    cond do
      node_mass(group_ast) < cfg.min_mass ->
        []

      # Hard live-out cap: a helper returning more than `max_live_out`
      # values forces a wide tuple destructure (`{a, b, c, …} = helper(…)`)
      # at every call site that reads worse than the inline statements —
      # the extraction would be a net regression, so don't even buffer it.
      length(live) > cfg.max_live_out ->
        []

      unsafe_control_flow?(group_ast) ->
        []

      true ->
        [
          %{
            ast: group_ast,
            clause_key: clause_key(clause),
            free_vars: free,
            live_out: live,
            fingerprint: fingerprint(group_ast, free, live),
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

  # The group's live-out variables: names the group *itself* binds that
  # some statement strictly after `j` still reads — the values the helper
  # must hand back. Returned as an ordered list (not a set) so the helper's
  # return tuple and every call-site's destructure agree positionally.
  #
  # `BlockSegmentation.live_out(segments, j + 1)` gives every name written
  # in `0..j` and read after `j`; intersecting with the group's own bound
  # names drops carriers established *before* the group (those stay in the
  # host, the helper has no business returning them).
  #
  # ## Ordering (correctness-critical)
  #
  # Ordered by **first structural appearance inside the group** (the same
  # canonical de-Bruijn index `rename_vars/1` assigns). Two structural
  # clones share that index per slot, so slot N of every occurrence's
  # ordered live-out refers to the *same* binding position. The helper
  # returns slot N as the first occurrence's local name; each call-site
  # destructures slot N into its own local name. Cross-occurrence rename
  # divergence (`{subtotal, taxed}` vs `{sub, tax}`) therefore can't
  # cross-wire. Alphabetical-by-name order would, since the names differ.
  defp live_out_of_group(group_ast, segments, j) do
    crossing = BlockSegmentation.live_out(segments, j + 1)
    own = AstHelpers.bound_in(group_ast)
    live_set = MapSet.intersection(crossing, own)

    group_ast
    |> canonical_var_order()
    |> Enum.filter(&MapSet.member?(live_set, &1))
  end

  # Variable names in first-encounter (prewalk) order — the canonical
  # ordering `rename_vars/1` hashes against. Underscored names are excluded
  # (they're never live-out: nothing reads `_x`).
  defp canonical_var_order(ast) do
    {_ast, {_seen, order}} =
      Macro.prewalk(ast, {MapSet.new(), []}, fn
        {name, _, ctx} = node, {seen, order} when is_atom(name) and is_atom(ctx) ->
          if AstHelpers.underscore?(name) or MapSet.member?(seen, name) do
            {node, {seen, order}}
          else
            {node, {MapSet.put(seen, name), [name | order]}}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(order)
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
  # plus the arity of the free-variable list AND the arity of the live-out
  # list, so two groups only bucket together if they'd produce the same
  # helper signature *and* return shape.
  #
  # Folding `length(live_out)` in is the safety latch the slice requires:
  # live-out depends on the *surrounding* body (what's read after the
  # group), not on the group AST, so two structurally identical groups can
  # legitimately have different live-out arity. Bucketing them together
  # would force one return shape on both — the bare-return occurrence would
  # destructure a tuple, or vice versa, and miscompile. Different arity →
  # different fingerprint → different bucket → never co-extracted.
  defp fingerprint(ast, free_vars, live_out) do
    normalized =
      ast
      |> AstHelpers.inline_pipes()
      |> strip_meta()
      |> rename_vars()

    {length(free_vars), length(live_out), :erlang.phash2(normalized)}
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

  # Extract ONE clone group per run (keeps the rewrite obviously-correct
  # and idempotent — a re-run finds the next non-overlapping group). Pick
  # the highest-NET-VALUE group (gross duplication saved minus call/return
  # overhead, see `group_savings/1`), resolve overlaps among its
  # occurrences, drop it if savings fall below `:min_savings`, then emit:
  #   * one shared `defp helper(<free vars>) do ...; <return> end` before
  #     the module's closing `end`, where `<return>` is the first
  #     occurrence's live-out (bare var, or tuple for 2+)
  #   * one call-site replacement per surviving occurrence — a plain
  #     `helper(args)` when nothing is live-out, or
  #     `<lhs> = helper(args)` destructuring the occurrence's own live-out
  defp emit_plan(groups, mod_node, existing_names, cfg, source) do
    case best_group(groups, cfg) do
      {:ok, occurrences} -> emit_group(occurrences, mod_node, existing_names, source)
      :none -> []
    end
  end

  # Rank by net savings, not raw mass. Raw `mass * occurrences` over-values
  # a big block that recurs widely even when it produces a regression-shaped
  # return; net savings discounts that overhead, so several small genuine
  # groups outrank one bloated one. Groups below `:min_savings` (computed on
  # the overlap-resolved occurrence count) are dropped as not worth a helper.
  defp best_group(groups, cfg) do
    groups
    |> Enum.map(fn {_fp, occs} -> resolve_overlaps(occs) end)
    |> Enum.filter(&(length(&1) >= 2))
    |> Enum.filter(&(group_savings(&1) >= cfg.min_savings))
    |> case do
      [] ->
        :none

      candidates ->
        {:ok, Enum.max_by(candidates, &group_savings/1)}
    end
  end

  # Estimated net reduction in node count from extracting this group:
  #
  #   gross = block_mass * (occurrences - 1)   # duplicated copies removed
  #   cost  = occurrences * (1 + free + live)  # per call site: the call
  #                                            # node, its free-var args,
  #                                            # and the live-out destructure
  #
  # One copy of the block survives as the helper body, so only
  # `occurrences - 1` copies are saved. The per-occurrence cost penalises
  # wide signatures (many params) and wide returns (many destructured
  # live-outs) — exactly the readability tax a `{a, b} = helper(socket)`
  # plumbing-clone incurs. Negative/low savings ⇒ not worth a helper.
  defp group_savings([first | _] = occs) do
    occurrences = length(occs)
    gross = node_mass(first.ast) * (occurrences - 1)
    cost = occurrences * (1 + length(first.free_vars) + length(first.live_out))
    gross - cost
  end

  defp emit_group([first | _] = occurrences, mod_node, existing_names, source) do
    case synth_name(first, existing_names) do
      {:ok, helper_name} -> emit_named_group(occurrences, helper_name, mod_node, source)
      :skip -> []
    end
  end

  defp emit_named_group([first | _] = occurrences, helper_name, mod_node, source) do
    helper_args = first.free_vars
    # The helper body is the first occurrence's AST; its return shape is
    # therefore the first occurrence's live-out, rendered in that
    # occurrence's own names.
    helper_patch =
      helper_append_patch(mod_node, helper_name, helper_args, first.ast, first.live_out)

    call_patches =
      occurrences
      |> Enum.flat_map(&occurrence_call_patch(&1, helper_name, source))

    case call_patches do
      [] -> []
      _ -> [helper_patch | call_patches]
    end
  end

  # The helper is named after what the block *does* and *produces*, via
  # `HelperNaming` — a verb inferred from the block's dominant call joined
  # to the live-out object (`compute_subtotal_and_taxed`). A clone spans
  # several functions, so there is no single host name to derive from: the
  # naming basis is the block itself (its statements feed verb inference,
  # its live-out feeds the object). `host` is therefore `nil` (the
  # host-derived `strip_suffix` candidate is suppressed) and `:extracted_clone`
  # is the honest last-resort fallback when nothing nameable surfaces —
  # preserving the pre-Slice-2 name for the unnameable case.
  #
  # One name is derived per clone group (shared by every occurrence), not
  # per occurrence. The first occurrence's stmts/free-vars/live-out stand
  # in for the group — all occurrences are structurally equal, so verb and
  # object agree across them.
  #
  # Collision safety: the candidate must miss every existing `def`/`defp`
  # name and not shadow a live-out or free-var (param) name. `HelperNaming`
  # enforces both and returns `:skip` if even the fallback collides with an
  # existing definition — in which case the whole extraction is skipped
  # rather than emit a confusing or clashing name (mirrors
  # `ExtractFunctionFromBlock`).
  defp synth_name(%{stmts: stmts, free_vars: free, live_out: live}, existing_names) do
    HelperNaming.name(nil, live, stmts, free, existing_names, fallback: :extracted_clone)
  end

  # Replace the occurrence's source range with the helper call. The free
  # vars of THIS occurrence (in fingerprint-canonical order) are the call
  # arguments — they line up positionally with the helper params because
  # both derive from the same canonical ordering. When the group is
  # live-out, the call is destructured into THIS occurrence's own live-out
  # names (`{a, b} = helper(...)` / `a = helper(...)`) so the surrounding
  # body still sees them.
  defp occurrence_call_patch(%{ast: ast, free_vars: free, live_out: live}, helper_name, source) do
    case range_of_group(ast, source) do
      {:ok, range} ->
        call = render_call(helper_name, free) |> bind_live_out(live)
        [%{change: call, range: range}]

      :error ->
        []
    end
  end

  # Wrap a helper call in a destructuring bind when the group is live-out.
  # Single live-out → bare bind; 2+ → tuple bind. Mirrors
  # ExtractFunctionFromBlock's `return_lhs/1`.
  defp bind_live_out(call, []), do: call
  defp bind_live_out(call, live), do: "#{return_lhs(live)} = #{call}"

  defp return_lhs([single]), do: Atom.to_string(single)
  defp return_lhs(live), do: "{" <> Enum.map_join(live, ", ", &Atom.to_string/1) <> "}"

  defp range_of_group(ast, _source) do
    case Sourceror.get_range(ast) do
      %{end: e, start: s} -> {:ok, %{end: e, start: s}}
      _ -> :error
    end
  end

  defp render_call(name, []), do: "#{name}()"
  defp render_call(name, args), do: "#{name}(#{Enum.join(args, ", ")})"

  defp helper_append_patch({:defmodule, _, _} = mod_node, name, args, body_ast, live_out) do
    %{end: end_pos} = Sourceror.get_range(mod_node)

    rendered = render_helper(name, args, body_ast, live_out)
    insert_pos = [line: end_pos[:line], column: 1]

    %{change: rendered, range: %{end: insert_pos, start: insert_pos}}
  end

  defp render_helper(name, args, body_ast, live_out) do
    head =
      case args do
        [] -> "#{name}()"
        _ -> "#{name}(#{Enum.join(args, ", ")})"
      end

    body_src = body_ast |> Sourceror.to_string() |> indent("    ")
    return_src = render_return(live_out)

    "  defp #{head} do\n#{body_src}#{return_src}\n  end\n"
  end

  # The helper's explicit return when the group is live-out: a bare var
  # (single) or a tuple (2+), in the first occurrence's own names, on its
  # own line after the relocated body. Empty live-out → the body's own
  # last expression is the return, nothing appended.
  defp render_return([]), do: ""
  defp render_return([single]), do: "\n    #{single}"

  defp render_return(live),
    do: "\n    {" <> Enum.map_join(live, ", ", &Atom.to_string/1) <> "}"

  defp indent(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end
end
