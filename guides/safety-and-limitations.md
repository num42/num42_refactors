# Safety & Limitations

> **Status:** STUB — to be filled.

What this library guarantees, what it doesn't, and where the rough edges
are.

## TODO outline

- [ ] **Two hard guarantees** — semantics-preserving and idempotent. What
  these mean concretely, what they don't mean (no claim about
  *performance* equivalence, no claim about *type* equivalence).
- [ ] **How we enforce idempotence** — fixpoint loop + per-refactor test
  + (future) property tests.
- [ ] **Known limitations** — macro hygiene, generated code via
  `unquote`, sigil bodies (HEEx is special-cased; other sigils are
  treated as opaque strings), `defmacro` bodies, code that depends on
  source order in unusual ways.
- [ ] **What can break** — call sites of refactored functions if a
  refactor renames or restructures public API (e.g. `extract_shared_module`).
  Mitigation: use `--step-by-step` for these.
- [ ] **What is irreversible without git** — `--auto` writes to disk.
  Always commit before running.
- [ ] **Cross-file refactors** — extra caveats. They cannot see private
  config, behaviours, or dynamic dispatch.
- [ ] **HEEx specifics** — only top-level `.heex` templates handled;
  inline `~H` in `.ex` files is processed via the HEEx pipeline too,
  but with different scoping.
- [ ] **API stability** — what counts as a public surface (engine + Mix
  task + behaviour) vs. internal (helpers, traversal utilities). Pre-1.0
  policy: any change to a public surface gets a CHANGELOG entry.
