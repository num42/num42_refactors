---
name: New refactor proposal
about: Propose a new refactor module.
title: "[refactor] "
labels: enhancement, refactor-proposal
assignees: ''
---

> **Status:** STUB template — refine after first real proposals.

## TODO checklist for proposer

- [ ] Working name of the refactor (e.g. `Number42.Refactors.Ex.FooBar`).
- [ ] One-line description.
- [ ] **Before** snippet (≤ 15 lines).
- [ ] **After** snippet (≤ 15 lines).
- [ ] Why this rewrite is **semantics-preserving** — explicitly call out
  edge cases you've considered (macros, sigils, side effects).
- [ ] Why this rewrite is **idempotent** — re-running the refactor on
  the After snippet must produce the same output.
- [ ] Suggested priority (default 100).
- [ ] Any `prepare/1` need (project-wide data) — yes/no.
- [ ] Existing prior art (Credo check, Sourceror example, blog post).
