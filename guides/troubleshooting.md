# Troubleshooting

> **Status:** STUB — to be filled.

Common problems and their fixes.

## TODO outline

- [ ] **`.refactor.exs` not found** — symptom, fix, minimal valid file.
- [ ] **„No refactors registered"** — usually `mix deps.compile` not run,
  or `is_refactor` attribute missing on a custom module.
- [ ] **Refactor changes pipe shape unexpectedly** — Sourceror's
  `to_string/1` flattening behavior, fix is `reformat_after?/0 == true`
  OR writing the replacement without a pipe.
- [ ] **Refactor is not idempotent** — how to diagnose: run twice, diff,
  identify the cycle. Common cause: rewrite produces input that the
  same refactor re-matches.
- [ ] **`mix format` undoes my refactor** — config mismatch, plugins,
  `import_deps`.
- [ ] **HEEx refactor does nothing** — `heex.core_components_module` not
  set in `.refactor.exs`.
- [ ] **`--auto` commits in the wrong order** — explain commit batching,
  how to interleave with manual edits.
- [ ] **Compilation fails after a refactor pass** — almost always a
  refactor bug; how to bisect with `--only`.
- [ ] **Slow on large codebase** — measure with `--log`, identify the
  hot refactor, use `skipped_modules` or open an issue.
- [ ] **Dialyzer warnings after refactor** — known cases and fixes.
