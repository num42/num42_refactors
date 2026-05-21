# Performance

How fast `number42_refactors` is, why, and how to make it faster on
your codebase.

## Cost model

Per file, the cost decomposes as:

```
parse (Sourceror)
+ N × (per-refactor traversal + rewrite cost)
+ optional reformat (mix format)
+ × M fixpoint passes (typically 1–2)
```

The dominant term varies:

- **Small codebase (< 1k files):** Sourceror parsing dominates. The
  engine spends most of its time tokenising and tree-building.
- **Medium (1k–10k files):** per-refactor traversal dominates. Each
  refactor walks the AST once; 60 refactors × 5k files × 2 passes =
  ~600k walks.
- **Large (> 10k files):** cross-file refactors dominate. They each
  walk every file in `inputs` to build a project-wide cluster
  table.

## The `prepare/1` cache

The biggest win available to refactor authors is using `prepare/1`
for project-wide state. Without it, the Mix task layer's per-file
loop re-runs `prepare/1` once per file — turning an O(n) project walk
into an O(n²) one.

The engine caches the `prepare/1` return value in `:persistent_term`
keyed by `{module, opts}`. First call does the work; every
subsequent call is a constant-time lookup.

Refactors that should use `prepare/1`:

- Any refactor whose decision depends on **the entire project**
  (cross-file extractors, anything that needs to know all schemas /
  all behaviours / all CoreComponents).
- Any refactor with **expensive per-run setup** that's independent of
  the file being rewritten.

Refactors that should *not* use `prepare/1`:

- Anything whose context is purely per-file. Build that context in
  `transform/2` — there's no benefit to caching it across files.
- Refactors that need *per-file* state. The cache key doesn't include
  the source string, so per-file state would be wrong.

## Parallelism

Today: sequential. The engine processes files one at a time.

The case for parallelism is real:

- Most refactors are CPU-bound pure functions. They scale linearly
  with cores.
- `prepare/1` results are immutable and cached in `:persistent_term`,
  so they're safe to share across worker processes.

The case against (today):

- Process startup overhead for `Task.async_stream/3` is non-trivial
  on small projects. For < 100 files, sequential is faster.
- Sourceror parsing is allocation-heavy; multiple parallel parsers
  compete for GC time.
- Cross-file refactors need to see the full project before they can
  produce per-file output, so they can't easily go parallel without a
  two-phase design.

If you want to experiment: `mix refactor` accepts a `--paths` list,
so you can shard externally:

```sh
ls lib/ | xargs -P 4 -I {} mix refactor lib/{}
```

This works for refactors that are purely intra-file. Cross-file
refactors will produce inconsistent output if sharded this way — the
cluster table is per-invocation.

## Expensive refactors

If you find `mix refactor` slow, profile with `--log` and look for
the refactor modules that show up most often in the timing output.
The usual suspects:

- **`ExtractSharedModule`** — full project scan, AST clustering,
  similarity-based grouping.
- **`ExtractParametricClone`** / **`ExtractRenamedClone`** — same
  shape, different similarity criteria.
- **`ExtractHeexExactClone`** — full HEEx parse + clone detection
  across every template.
- **`ExtractHeexFor`** — HEEx parse, loop pattern detection.

For these, scope tightly with `inputs` or move them to a less
frequent CI workflow. See [`guides/ci-usage.md`](ci-usage.md) for
patterns.

## Profiling

For a single refactor on a single file:

```sh
mix refactor --only LengthZeroToEmpty --log lib/path/to/file.ex
```

The `--log` output includes per-refactor timing.

For deep profiling (`:eprof` / `:fprof`):

```elixir
# in IEx -S mix
source = File.read!("lib/path/to/file.ex")
opts = [paths: Path.wildcard("lib/**/*.ex")]

:eprof.start_profiling([self()])
Number42.Refactors.Engine.run(source, opts)
:eprof.stop_profiling()
:eprof.analyze()
```

Look for:

- excessive `Sourceror` calls (likely a per-refactor re-parse — that
  should be once, at the engine level)
- repeated `String.split/2` / `Enum.flat_map/2` patterns (these are
  cheap individually but add up across large files)

## Stable diffs

Performance also matters for *review effort*. A stable diff is one
that produces the same output on the same input across runs.

The library enforces stability via:

- alphabetical sort of discovery (`refactors/0` sorts the module
  list)
- secondary alphabetical sort within a priority tier
- deterministic priority resolution (config wins, callback is
  fallback, `100` is default)

If you observe diff instability:

1. Check `inputs` glob ordering. Glob expansion is filesystem-order
   on some filesystems; if it matters, sort the result yourself.
2. Check for refactor modules whose `transform/2` depends on iteration
   order over a map (maps don't guarantee order).
3. If still unstable, that's a bug — please file an issue.

## When to skip the optimisation work

For most users, `mix refactor` is fast enough that any tuning is
overengineering. If your full run finishes in under a minute, you
don't need this guide.

The cases where it matters:

- you run the engine on every push, and CI minutes are billed
- your codebase has > 10k files and you can't skip cross-file
  refactors
- you're building a tool *on top of* the engine that calls
  `Number42.Refactors.Engine.run/2` in a tight loop

For everyone else: the defaults are tuned for correctness first.
"Correctness" here means **idempotence** (a hard requirement, enforced
by tests and the engine's fixpoint loop) plus **best-effort behaviour
preservation** (an aim, not a formal guarantee — see
[safety-and-limitations.md](safety-and-limitations.md)). Performance
is the next priority after that.
