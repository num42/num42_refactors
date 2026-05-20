# Refactor Catalog

> **Status:** STUB — to be filled.

Curated index of all bundled refactors with one-line description,
before/after snippet, and link to the module doc.

## TODO outline

This page is the **shop window** for the library. A reader who lands
here should, within 30 seconds, recognize at least one refactor they
want for their codebase.

Group the list using the same buckets as `groups_for_modules` in
`mix.exs`:

- [ ] **Style & Ordering** — alias ordering, multi-alias expand,
  import-after-alias, sort functions/keywords, lift directives,
  remove-blank-between-attr-and-def, merge-assign-keywords.
- [ ] **Enum / Map / Stream** — Enum.into → Map.new, Enum.reduce →
  Enum.sum, Enum.reverse |> Enum.concat → Enum.reverse/2, flat_map →
  filter, Map.new lambda → comprehension, Map.new → pipe,
  reduce-as-map, reduce-map-put, reject-is-nil, Enum.map_join →
  Enum.map_join (use_map_join), enum-capture.
- [ ] **Pattern Matching & Control Flow** — case true/false, collapse
  nested case → with, if-lift-to-clauses, redundant-boolean-if,
  remove-trivial-else-clause, with-single-clause-to-case,
  with-without-else.
- [ ] **Pipes & Sigils** — extract-socket-to-pipe, extract-to-pipeline,
  lift-pinned-Ecto-expr, lift-with-into-pipeline, pipe-reassign.
- [ ] **Length / String / List** — graphemes-length, length-in-guard,
  length-zero-to-empty, list-last-of-reverse, sort-for-top-k.
- [ ] **Definition Hygiene** — delegate-exact-duplicates,
  expand-short-form-bindings/functions/params, identity-passthrough,
  inline-single-expression-def, resolve-impl-true, unused-variable.
- [ ] **Cross-File Extraction** — extract-case-to-helper,
  extract-inline-block, extract-intra-module-clone,
  extract-lambda-block, extract-nested-block,
  extract-parametric-clone, extract-renamed-clone,
  extract-shared-module.
- [ ] **HEEx** — extract-heex-exact-clone (configurable target),
  extract-heex-for.
- [ ] **Type & API Safety** — map-get-unsafe-pass,
  try-rescue-with-safe-alternative, utc-now-truncate.

Entry template:

```markdown
### `Number42.Refactors.Ex.Foo`

> One-line description.

**Before**
\`\`\`elixir
# bad
\`\`\`

**After**
\`\`\`elixir
# good
\`\`\`

**Why** — short rationale. Link to the module doc for the full story.
```
