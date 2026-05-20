# Authoring a Refactor

> **Status:** STUB — to be filled.

End-to-end walkthrough for writing a new refactor module.

## TODO outline

- [ ] **The contract** — recap of `Number42.Refactors.Refactor` callbacks.
  Required vs. optional.
- [ ] **Worked example** — pick a small, real refactor (e.g.
  `LengthZeroToEmpty`) and explain every line: pattern, traversal,
  rewrite, edge cases.
- [ ] **Sourceror primer** — the bare minimum a refactor author needs:
  - `Sourceror.parse_string!/1` vs. `Code.string_to_quoted!/1`
  - `Sourceror.to_string/1` and what it does to pipes
  - `Sourceror.Zipper` traversal patterns
  - Preserving comments via the metadata
- [ ] **Helpers in `Number42.Refactors.AstHelpers`** — what's available, what
  to reach for first.
- [ ] **Testing** — `Number42.Refactors.RefactorCase`, golden-input style,
  idempotence assertion.
- [ ] **The two correctness properties** — semantics-preserving and
  idempotent. How to check both manually + with property tests.
- [ ] **Pitfalls** — macro expansion, sigils, `unquote`, generated code,
  `__MODULE__` references, `defmacrop`, anonymous functions vs. captures.
- [ ] **Performance hints** — when to use `prepare/1`, when to bail out
  early from `transform/2`, why string-level shortcuts can save passes.
- [ ] **Naming & scope** — one rewrite per module, file name == module
  short name, no umbrella refactors.
- [ ] **Submission checklist** — `@moduledoc` with before/after,
  `description/0`, `explanation/0`, tests, idempotence test, no Credo
  regressions.
