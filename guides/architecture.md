# Architecture

> **Status:** STUB — to be filled.

High-level overview of how `Number42.Refactors` is structured and why.

## TODO outline

- [ ] **The pure engine vs. the Mix layer** — `Number42.Refactors.Engine` is a
  pure function over source strings; `Mix.Tasks.Refactor` adds I/O, `git`
  integration, and the format pass. Diagram.
- [ ] **The refactor behaviour** — `Number42.Refactors.Refactor` callbacks
  (`transform/2`, `description/0`, `explanation/0`, `priority/0`,
  `prepare/1`, `reformat_after?/0`), and the `is_refactor` persistent
  attribute used for runtime discovery.
- [ ] **Discovery** — how the engine enumerates refactors at runtime via
  `:attributes`, and why this avoids a hard-coded registry.
- [ ] **The fixpoint loop** — priorities, ordering, `@max_passes`, why two
  passes are usually enough (`MultiAliasExpand` → `AliasOrder` example).
- [ ] **`prepare/1` and per-run caches** — when to use it (project-wide
  state), when not to (per-file state belongs in `transform/2`).
- [ ] **The HEEx subsystem** — `Heex.Tree`, `Heex.Normalizer`,
  `Heex.Fingerprint`, `Heex.Clones`. Why HEEx is separate from the Elixir
  AST pipeline.
- [ ] **Reformat trigger** — what `reformat_after?/0 == true` actually does
  end-to-end (engine flag → Mix task runs `mix format`).
- [ ] **What is intentionally NOT in scope** — formatting (delegated to
  `mix format`), linting (delegated to Credo), type errors (Dialyzer).
