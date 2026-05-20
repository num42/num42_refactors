# Comparison with Other Tools

> **Status:** STUB — to be filled.

How `number42_refactors` differs from neighboring tools in the Elixir
ecosystem, and when to pick which.

## TODO outline

- [ ] **vs. `mix format`** — formatter is layout-only; refactor engine
  changes semantics-preserving structure (which function you call, how
  branches are shaped). Refactors trigger `mix format` as a follow-up
  step, never replace it.
- [ ] **vs. Credo** — Credo lints and reports; refactor engine rewrites.
  Useful overlap (some Credo checks have refactor equivalents here) but
  different intent.
- [ ] **vs. Sourceror itself** — this library is built ON Sourceror. We
  add: the engine, the behaviour, the registry, fixpoint loop, Mix
  task, ~60 ready-made rewrites.
- [ ] **vs. Refactorex / styler / quokka** — feature matrix. What overlaps,
  what's unique here (cross-file extraction, HEEx clones, configurable
  per-refactor priority).
- [ ] **vs. doing it by hand with `sed`/`gsed`** — semantics-preserving
  guarantees, idempotence, undo via git.
- [ ] **When NOT to use this library** — large legacy codebases with
  intentional anti-patterns that you don't want auto-rewritten, projects
  on older Elixir versions, projects that vendor Sourceror incompatibly.
