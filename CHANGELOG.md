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
  fewer than `:min_fields` distinct accesses (default 2 — one generic
  field is too thin), the param is passed whole into another call (fields
  we can't see), the body is a **builder** (`X_to_Y(arg)` constructing
  `%Y{… arg.field …}` — `arg` is the source projection, not `%Y{}`), or
  clauses would infer divergent structs. Field counting excludes zero-arg
  calls (`var.fun()`) so a module isn't mistaken for a struct. **Default
  off** (opt in via `.refactor.exs`): a wrong lift inserts a
  runtime-breaking pattern, so the decline-on-ambiguity guard is the core
  of the design.
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
