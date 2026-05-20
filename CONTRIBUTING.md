# Contributing to Number42.Refactors

> **Status:** STUB — to be filled.

Thanks for considering a contribution. This file is the entry point for
anyone who wants to add a refactor, fix a bug, or improve the docs.

## TODO outline

- [ ] **Code of conduct** — link to `CODE_OF_CONDUCT.md`.
- [ ] **Quick start** — clone, `mix deps.get`, `mix test`, `mix
  format`, `mix credo`, `mix dialyzer`.
- [ ] **Dev environment** — Nix-based (`devenv` + `direnv`), how to
  enter the shell, common issues (`rm -rf .devenv .direnv`).
- [ ] **Project layout** — pointer to `guides/architecture.md`.
- [ ] **Adding a refactor** — pointer to
  `guides/authoring-a-refactor.md`.
- [ ] **Tests** — every refactor needs at least:
  - golden input/output test (before → after)
  - idempotence test (applying twice == applying once)
  - no-op test (already-conforming code is untouched)
- [ ] **Commit style** — Conventional Commits (`feat:`, `fix:`,
  `refactor:`, `docs:`, …). See recent `git log` for examples.
- [ ] **Branch naming** — `feat/<short-slug>`, `fix/<short-slug>`.
- [ ] **PR checklist** — tests, format, credo, dialyzer, CHANGELOG
  entry under `[Unreleased]`.
- [ ] **Reporting bugs** — minimal repro template; isolate to a single
  source string + which refactor reproduces it.
- [ ] **Security issues** — please do not open public issues; email
  instead (address TBD).
- [ ] **Release process** — for maintainers: tag, CHANGELOG, `mix
  hex.publish --dry-run`, publish, push tag.
