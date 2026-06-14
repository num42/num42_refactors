# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `ManualTapToTap`: a hand-rolled "run a side effect, return the
  original value" lambda in a pipe → `Kernel.tap/2`. Matches
  `value |> then(fn x -> eff; x end)` and the immediately-applied
  `value |> (fn x -> eff; x end).()`, where the lambda is single-clause,
  single-bare-param, and its block body ends in exactly the bound param
  after at least one side effect. The trailing `; x` is dropped on emit
  (`tap` ignores the return). Skips when the body returns a derived
  value, is identity-only, has a multi/destructuring param, or **rebinds
  the param before the final `x`** (the returned value would no longer
  be the original).
- `LiftUntypedParamToStructPattern`'s call-site source now reads
  **transitive struct returns**. A project function whose every clause
  provably returns a single in-project struct — through Ecto's get-family
  (`Repo.get!(Schema, _)`, `Repo.get_by`, `Repo.one`, `Repo.reload`, and
  the pipe form `Schema |> Repo.get!(id)`) or a bare `%Struct{}` literal as
  the last expression — is recorded as a getter. A variable bound to such a
  getter's result (`item = Catalog.get_item!(id)`) is then known to be that
  struct, so passing it bare (`f(item)`) types `f`'s parameter — the same
  data-flow lift the binding tracker already does for struct literals,
  extended one hop through the getter. `Repo.all` (returns a list) and
  getters whose clauses disagree on the struct are deliberately excluded;
  only an unconditional single-struct return qualifies. Zero-arity defs
  (`def blank, do: %Item{}`, and `def go do … end` callers) are now
  collected as clauses so they participate as getters and as binding
  sources. On position-db this added 0 lifts — every getter result there
  flows into context functions that already pattern-match the struct — but
  it is a clean general source that fires on codebases where getter results
  reach untyped helpers.
- `LiftUntypedParamToStructPattern`'s call-site source now tracks
  **variable bindings**, not just struct literals at the call. A var
  bound to a struct in the caller's head (`%Brand{} = b`) or body
  (`b = %Brand{…}`) and then passed bare (`f(b)`) is recognised as a
  struct call site. Bindings are scoped per clause. On position-db this
  added 2 lifts (`ItemImport.persist`/`valid_unique_rows` off a
  `workbook = %Workbook{…}` body binding), bringing the running total to
  16 (from the 3-lift spec+fields baseline).
- `LiftUntypedParamToStructPattern` gains an **AST delegation** source and
  a **fixpoint loop**. A param the body proves nothing about but passes
  whole into a call (`f(arg), do: Shared.g(arg)`) borrows its type from the
  receiver's head when `g/1` pattern-matches a struct at that position in
  every clause — pure source, no PLT. Resolution then iterates to a
  fixpoint: each round's lifts type their own heads, which become new
  delegation receivers, so type info propagates up multi-hop chains
  (`h → f → g`, leaf-typed `g` lifts `f` then `h`). The loop terminates
  (monotone, bounded receiver index; round cap as a guard). On a real
  Phoenix app this is the largest pure-AST lever — most params flow through
  context functions rather than being read field-by-field; combined with
  the existing sources the lift count rose 10 → 14 (3 → 14 vs. the original
  spec+fields-only baseline), every new lift compiling under
  `--warnings-as-errors`.
- `LiftUntypedParamToStructPattern` now infers struct types from **two
  more sources** beyond `@spec` + field-superset, strongest first:
  **call sites** (a project-wide AST scan — a struct literal passed at a
  call, `f(%Brand{})`, types the parameter by real data flow; overrides a
  weaker field guess, declines on conflict, rescues a body that proved
  nothing) and **Dialyzer success typing** (the project PLT is read
  directly via `:dialyzer_cplt`/`:dialyzer_plt` — the only source that
  sees through delegation, e.g. `f(arg), do: Shared.g(arg)` where `g/1`
  matches `%Scope{}` back-propagates `arg :: %Scope{}`; opt out with
  `dialyzer: false`, point at a PLT with `plt_path:`). Visible code always
  wins over Dialyzer; the builder/projection decline is preserved by both.
  When call sites pass **several** distinct structs, the single clause is
  **duplicated** into one struct-typed head per target — but only when the
  function has one clause and every field the body reads exists in every
  target struct (else `:polymorphic_unsafe`). Calibrated against a real
  Phoenix app: doubled the lift count (3 → 6), every new lift correct and
  compiling under `--warnings-as-errors`.
- `EnumIntoToMapSet`: rewrites `Enum.into(coll, MapSet.new())` to
  `MapSet.new(coll)` (pipe form `coll |> Enum.into(MapSet.new())` →
  `coll |> MapSet.new()`). Sibling of `EnumIntoToMapNew` for `MapSet`.
  Fires only on the zero-arg `MapSet.new()` accumulator — a seeded
  `MapSet.new(seed)` merges into an existing set and is left untouched.
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
- `FilterCountToCount`: `Enum.filter(coll, pred) |> Enum.count()` →
  `Enum.count(coll, pred)` (pipe, half-pipe and nested-call forms);
  lambda/capture predicates only, leaves `Enum.count/2` alone.
- `RangeToListRedundant`: drops a redundant `Enum.to_list/1` on a range
  that feeds directly into another `Enum.*`/`Stream.*` call —
  `Enum.to_list(1..n) |> Enum.map(fun)` → `1..n |> Enum.map(fun)`,
  `Enum.map(Enum.to_list(a..b), fun)` → `Enum.map(a..b, fun)`. Fires
  only when the `to_list` argument is a syntactic range (`a..b`,
  `a..b//s`, `Range.new(...)`) and the consumer is a direct Enum/Stream
  call (pipe or nested); skips bound results, unknown consumers, and
  non-range arguments.
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
