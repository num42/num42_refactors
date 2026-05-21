# Architecture

This guide explains how `Number42.Refactors` is structured and why. It
complements `README.md`, which shows what the library *does*; this
document shows what it *is*.

## Three layers, by design

```
       .refactor.exs               mix refactor [opts] [paths]
            │                              │
            ▼                              ▼
  ┌───────────────────────────────────────────────────────┐
  │ Layer 3 — CLI driver                                  │
  │   Mix.Tasks.Refactor                                  │
  │   reads files, writes files, runs `mix format`,       │
  │   drives --check / --auto / --step-by-step            │
  └─────────────────────┬─────────────────────────────────┘
                        │ source string
                        ▼
  ┌───────────────────────────────────────────────────────┐
  │ Layer 2 — Pipeline engine                             │
  │   Number42.Refactors.Engine                           │
  │   pure: source in, source out                         │
  │   discovers refactors, sorts by priority,             │
  │   runs the fixpoint loop, caches `prepare/1`          │
  └─────────────────────┬─────────────────────────────────┘
                        │ source string + per-module opts
                        ▼
  ┌───────────────────────────────────────────────────────┐
  │ Layer 1 — A single refactor                           │
  │   Number42.Refactors.Ex.Foo / .Heex.Foo               │
  │   pure: source in, source out                         │
  │   uses Sourceror + AstHelpers + AstDiff               │
  └───────────────────────────────────────────────────────┘
```

The split matters: layer 1 and layer 2 are pure functions. They do not
read or write files, do not call `mix format`, do not consult `git`. All
of that lives in layer 3. You can `Number42.Refactors.Engine.run(source,
opts)` from any context — IEx, a script, another library — and get
deterministic output.

## The refactor behaviour

`Number42.Refactors.Refactor` is the contract. Six callbacks; two are
required, four are optional with sensible defaults.

| Callback             | Required | Default      |
|----------------------|----------|--------------|
| `transform/2`        | yes      | —            |
| `description/0`      | yes      | —            |
| `explanation/0`      | no       | `description/0` |
| `priority/0`         | no       | `100`        |
| `prepare/1`          | no       | not called   |
| `reformat_after?/0`  | no       | `false`      |

`use Number42.Refactors.Refactor` registers the module by setting a
persistent attribute (`@is_refactor true`) that the engine reads at
runtime. There is no central registry to keep in sync — adding a refactor
is one file, no other edits.

## Discovery

The engine asks the BEAM:

```elixir
:application.get_key(:number42_refactors, :modules)
|> elem(1)
|> Enum.filter(&refactor?/1)
```

`refactor?/1` reads `__info__(:attributes)` and looks for `is_refactor:
[true]`. The result is a sorted list of every refactor in the loaded
application — including any custom refactors a host project has compiled
into the same application (rare, but supported).

This means:

- **No registry to forget.** A new module under `lib/number42/refactors/ex/`
  shows up automatically the moment it compiles.
- **Order is reproducible.** Discovery sort is alphabetical; the
  pipeline re-sorts by `priority/0` with alphabetical tiebreak. Same
  input → same diff, every time.

## The fixpoint loop

Refactors can feed each other. `MultiAliasExpand` produces single
aliases that then become input for `AliasOrder`. Rather than building a
dependency graph, the engine applies the pipeline repeatedly until
nothing changes, with a hard cap of `@max_passes = 5`.

```
source₀ ──[pipeline]──▶ source₁ ──[pipeline]──▶ source₂ ──▶ ...
                                                            │
                                            same as previous?
                                                   ├─ yes ─▶ done
                                                   └─ no, and pass < 5 ─▶ continue
```

In practice two passes are usually enough. The cap exists to fail loud
if a refactor is silently non-idempotent.

## `prepare/1` and the per-run cache

Some refactors need project-wide context that's expensive to compute but
identical for every file in a run — e.g. the set of all Ecto schema
field names, or the cluster table of detected HEEx clones.

`prepare/1` is the answer. It's called once per engine run, *before* any
`transform/2`. The return value is threaded into every per-file call as
`opts[:prepared]`.

Internally the result is memoised in `:persistent_term` keyed by
`{module, opts}`. Without this cache, the Mix task layer's per-file
loop would re-run `prepare/1` once per file — turning an O(n) project
walk into an O(n²) one.

The opt-in shape (`:no_cache` vs. `{:ok, term}`) lets a refactor decide
at preparation time whether it has anything to contribute for this
particular run.

## The HEEx subsystem

HEEx is *not* Elixir AST. Sourceror cannot parse a `~H` body, and
`Code.string_to_quoted/1` only sees the sigil as an opaque string.

The `Number42.Refactors.Heex.*` modules form a small, self-contained
parallel pipeline:

- `Heex.Tree` — parses HEEx into a typed tree (`{:element, ...}`,
  `{:eex_block, ...}`, `{:eex_expr, ...}`, `{:text, ...}`).
- `Heex.Normalizer` — produces a canonical form per detection mode
  (`:exact`, `:class_stripped`, `:attrs_stripped`).
- `Heex.Fingerprint` — hashes the normalised tree.
- `Heex.Clones` — buckets fingerprints across all sources to find
  clusters worth extracting.

Only two refactors today consume this subsystem
(`ExtractHeexExactClone`, `ExtractHeexFor`), but the API is reusable for
new HEEx-shaped refactors.

## The reformat trigger

Some refactors produce code that's formatted differently from what `mix
format` would prefer. Rather than re-implementing the formatter, each
refactor can flag `reformat_after?/0 == true`. When any refactor in the
pipeline raises that flag, the engine returns `reformat_triggered?:
true`. The Mix task reacts by running `mix format` on the affected
files.

This re-uses the host project's `.formatter.exs` — including
`import_deps: [:phoenix]` and any plugins. A bare
`Code.format_string!/2` call from inside the engine would miss all of
that.

## What is intentionally *not* in scope

- **Formatting.** That's `mix format`'s job, and the engine triggers it
  rather than reproducing it.
- **Linting.** That's [Credo](https://github.com/rrrene/credo). Linters
  *report*; refactors *rewrite*. The two are complementary and the
  rule sets only partially overlap.
- **Type checking.** That's Dialyzer. Refactors do not infer or
  verify types, and they make no formal claim about preserving type
  signatures across a rewrite — they just don't deliberately change
  them.
- **Cross-project rewrites.** Each `mix refactor` run is scoped to one
  project's `inputs`. There is no awareness of dependencies' source
  trees.

## Module map

| Module                                   | Role                                              |
|------------------------------------------|---------------------------------------------------|
| `Number42.Refactors.Engine`              | pipeline driver, fixpoint loop, discovery, cache  |
| `Number42.Refactors.Refactor`            | behaviour + `__using__` macro                     |
| `Number42.Refactors.AstHelpers`          | shared AST predicates and accessors               |
| `Number42.Refactors.AstDiff`             | diff helpers for `--log` and test failures        |
| `Number42.Refactors.Ex.*`                | the Elixir-AST refactors (~57)                    |
| `Number42.Refactors.Heex.{Tree,...}`     | HEEx parsing + clone detection                    |
| `Number42.Refactors.Ex.ExtractHeex*`     | HEEx-aware refactors (2)                          |
| `Mix.Tasks.Refactor`                     | CLI driver (`--check`, `--auto`, …)               |
| `Mix.Tasks.Refactor.HeexClones`          | standalone HEEx clone report                      |
| `Number42.RefactorCase` (`test/support`) | `assert_rewrites/3`, `assert_unchanged/2`, `assert_idempotent/2` |
