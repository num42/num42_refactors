# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `LiftUntypedParamToStructPattern`: lifts a bare untyped parameter to a
  struct-pattern match (`def f(r)` → `def f(%Position{} = r)`) when the
  body **proves** the type. Inference, strongest first: an existing
  `@spec` naming the arg type wins; otherwise the `var.field` accesses
  must be a superset of exactly one project `defstruct` (scanned from
  source AST, cross-file) and no other. Declines (leaves the head alone)
  on any ambiguity — two structs fit, none fit (the value is a map, e.g.
  a `select`-projection with join/compute fields no struct carries),
  fewer than `:min_fields` (default 2) **distinctive** accesses (generic
  fields like `id`/`name`/`type` still match but don't count toward the
  threshold — reading only `var.type`/`var.name` proves nothing), the
  param is passed whole into another call (fields we can't see), the body
  is a **builder** (`X_to_Y(arg)` constructing `%Y{… arg.field …}` —
  `arg` is the source projection, not `%Y{}`), or clauses would infer
  divergent structs. Field counting excludes zero-arg calls (`var.fun()`)
  so a module isn't mistaken for a struct. **Default on** — calibrated
  against a real Phoenix app (every surviving lift correct, the library's
  own source yields zero); a wrong lift inserts a runtime-breaking
  pattern, so the layered decline guards are the core of the design.
  Review the dry-run on an unfamiliar codebase or opt out via
  `skipped_modules`.
- `ExtractBehaviourFromAdapterFamily`: detects module families with a
  shared public API via BEAM introspection (`__info__(:functions)` +
  implemented behaviours), scores candidate pairs (sibling/same-depth
  namespace bonus), synthesizes a behaviour module with spec-derived
  callbacks, and inserts `@behaviour`/`@impl true` into the members.
  The surface counts genuine `def`s only — `defdelegate`s (unrewritten
  call sites) and `use`-injected functions (`child_spec/1`, `start_link`
  from `GenServer`/`Supervisor`/`Ecto.Repo`, …) are intersected out.
  Optional `:require_dispatch` keeps only families with a polymorphic
  call site (`var.fun(..)`/`apply(var, :fun, ..)`, framework receivers
  like `repo`/`conn` ignored); when on, families seed from the smallest
  dispatched core and majority-shared functions become
  `@optional_callbacks`. **Default off** (opt in via `.refactor.exs`):
  shape-based matching tends to surface coincidences over genuine
  abstractions. See num42/num42_refactors#158 for the protocol sibling.
- `ExtractProtocolFromStructFamily`: the data-polymorphism sibling of
  the behaviour refactor. Detects functions defined over several
  **distinct** struct types at the dispatch arg (`def label(%Brand{})`
  / `def label(%Item{})` / …, deduped to distinct types, `:min_structs`
  floor of 3), and rewrites a single-module family into a real
  `defprotocol` + one `defimpl` per struct in a new `-able`-named file
  (`label` → `Catalog.Labelable`), migrating each clause and its
  `@spec` (lifted to the protocol with the dispatch type as `t()`).
  Static call sites shift to the protocol only when the name moves
  (`Catalog.Labeling.label(x)` → `Catalog.Labelable.label(x)`);
  otherwise dispatch is transparent. A second **name-family** axis
  reports near-misses where dispatch is hand-rolled through the
  function name instead (`*_to_result`, `subscribe_*`) as hints, gated
  by body-convergence + specific-operation + subsumption filters — a
  pointer, never a rewrite (the values are often maps, not structs).
  Cross-module families are reported but not rewritten. **Default off**
  (opt in via `.refactor.exs`): idiomatic Elixir rarely hand-rolls
  struct-type dispatch, so the honest first result is often "none".
- `SortReverseToDesc`: `Enum.sort(coll) |> Enum.reverse()` →
  `Enum.sort(coll, :desc)` and the `sort_by` analogue (both call and
  pipe forms). Skips a sort that already carries a sorter/direction arg
  (arity-based gate, e.g. `Enum.sort(coll, &>=/2)` / `:asc`) and any
  `Enum.reverse/2`. **Default off** (opt in via `.refactor.exs` with
  `enabled: true`): `Enum.sort/1` is stable so `sort |> reverse` flips
  tie order while `sort(:desc)` preserves it — not strictly
  behaviour-preserving when duplicate sort keys exist (accepted
  best-effort trade-off for the dominant no-relevant-ties case).
- `MemberToInOperator`: `Enum.member?(coll, x)` → `x in coll`, negated
  calls fold to `not in`; guard context gated on literal collections.
- `MapSumToSumBy`: `Enum.map(coll, fun) |> Enum.sum()` →
  `Enum.sum_by(coll, fun)` (Elixir 1.18+).
- `EnumFindToKeyfind`: `Enum.find(list, fn {k, _} -> k == key end)` →
  `List.keyfind(list, key, 0)`, incl. the `elem(t, n) ==` form.
- `MergePipelineIntoComprehension` now also fuses
  `Enum.reject |> Enum.map` (`for x <- coll, !pred(x), do: f(x)`).
- Initial public release, extracted from an internal project.
- ~60 AST refactors covering Enum/Map/Stream idioms, pattern-matching
  rewrites, pipe and `with` reshaping, definition hygiene, cross-file
  extraction, and HEEx clone consolidation.
- `mix refactor` task with `--check` (CI), `--log` (per-refactor
  rationale + diff), `--auto` (commit per refactor), `--step-by-step`,
  and `--dry-run` modes.
- `Number42.Refactors.Refactor` behaviour for authoring custom refactors.
- `.refactor.exs` project-level configuration.
