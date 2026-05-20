# Performance

> **Status:** STUB — to be filled.

How fast `number42_refactors` is, why, and how to make it faster on your
codebase.

## TODO outline

- [ ] **Cost model** — per file: parse (Sourceror) + N refactors *
  (traversal + rewrite) + reformat? Cost grows with #refactors *
  #files * #passes.
- [ ] **Benchmarks** — wall time on representative codebases (small,
  medium, large). Methodology: cold cache, `_build` warm.
- [ ] **`prepare/1` and the per-run cache** — when it actually wins,
  measured. Example: schema-field set used by `LiftPinnedEctoExpr`.
- [ ] **Parallelism** — current model (sequential per file? per
  refactor?), the case for `Task.async_stream`.
- [ ] **Refactors that are expensive** — cross-file extractors,
  HEEx clones. Why. How to scope them with `inputs`.
- [ ] **Profiling** — `:fprof` / `:eprof` quick start, what to look
  for.
- [ ] **Stable diffs** — performance also matters for review effort.
  How priority + sort ordering keep diffs deterministic across runs.
