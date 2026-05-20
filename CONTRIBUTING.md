# Contributing to Number42.Refactors

Thanks for considering a contribution. This is the entry point for
anyone who wants to add a refactor, fix a bug, or improve the docs.

By participating you agree to abide by the [Code of
Conduct](CODE_OF_CONDUCT.md).

## Quick start

```sh
git clone https://github.com/num42/num42_refactors.git
cd num42_refactors
direnv allow           # if you use the Nix dev shell (recommended)
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted
mix credo --strict
mix dialyzer
```

Everything green? You're set.

## Dev environment

The project ships a `devenv.nix` for `devenv` + `direnv` users (Elixir
1.18 / 1.19, OTP 27 / 28). If you don't use Nix, install equivalent
versions with `asdf` / `mise` / your tool of choice — the version
matrix is in `.github/workflows/ci.yml`.

Common rescue commands when the Nix shell misbehaves:

```sh
rm -rf .devenv .direnv
direnv reload
```

## Project layout

```
lib/
├── mix/tasks/                  # Mix task layer (CLI driver)
│   ├── refactor.ex
│   ├── refactor.heex_clones.ex
│   └── refactor/shared.ex
└── number42/refactors/
    ├── engine.ex               # pipeline + fixpoint loop
    ├── refactor.ex             # behaviour
    ├── ast_helpers.ex          # shared AST predicates
    ├── ast_diff.ex             # diff helpers
    ├── ex/                     # the Elixir-AST refactors (~57)
    └── heex/                   # HEEx parsing + clone detection
test/
├── support/refactor_case.ex    # assert_rewrites/3 et al
└── refactors/
    ├── ex/<name>_test.exs      # one test file per refactor
    └── heex/...
guides/                         # HexDocs guide pages
```

See [`guides/architecture.md`](guides/architecture.md) for a deeper
tour of how the parts fit together.

## Adding a refactor

Walkthrough lives in
[`guides/authoring-a-refactor.md`](guides/authoring-a-refactor.md).
Short version:

1. Read an existing similar refactor first. `LengthZeroToEmpty` is a
   good template for AST-walk-with-patches; `ExtractSharedModule` is
   the canonical cross-file example.
2. **Write the test first.** `test/refactors/ex/<name>_test.exs`, with
   `describe "rewrites"`, `describe "leaves alone"`,
   `describe "idempotent"` sections.
3. Make it red: `mix test test/refactors/ex/<name>_test.exs --trace`.
4. Implement the refactor module under `lib/number42/refactors/ex/`.
5. Make it green.
6. Add an `@moduledoc` with before/after examples and an
   `explanation/0` callback.
7. Update `mix.exs` `groups_for_modules` so HexDocs slots the module
   into the right sidebar group.
8. Add a `CHANGELOG.md` entry under `[Unreleased]` → `### Added`.

## Tests

Every refactor must have at least three test cases:

- **rewrites**: a minimal antipattern → expected output
- **leaves alone**: conformant code passes through untouched
- **idempotent**: applying twice equals applying once

`Number42.RefactorCase` provides `assert_rewrites/3`,
`assert_unchanged/2`, `assert_idempotent/2`. Comparison is
whitespace-agnostic so heredocs with natural indentation work
without `mix format` in the test path.

All test files use `async: true`. Refactors are pure functions with
no shared state.

## Commit style

We use [Conventional
Commits](https://www.conventionalcommits.org/). Common prefixes:

- `feat: ` — new refactor or new engine feature
- `fix: ` — bug fix in a refactor or in the engine
- `refactor: ` — internal cleanup with no observable change
- `docs: ` — documentation only
- `test: ` — test additions/changes
- `chore: ` — tooling, deps, CI
- `wip: ` — work in progress (never released; squash before merge)

Look at `git log --oneline -30` for examples that match the codebase's
style.

## Branch naming

- `feat/<short-slug>`
- `fix/<short-slug>`
- `docs/<short-slug>`

Avoid `wip/...` branches in PRs; if you've been working on `wip/foo`
locally, rename to `feat/foo` (or similar) before opening the PR.

## Pull-request checklist

Before opening a PR:

- [ ] `mix test` passes
- [ ] `mix format --check-formatted` is clean
- [ ] `mix credo --strict` is clean (or new findings explained in the
  PR description)
- [ ] `mix dialyzer` is clean (or new warnings explained)
- [ ] If adding a refactor: golden test + idempotence test + no-op
  test (see above)
- [ ] If user-visible: `CHANGELOG.md` updated under `[Unreleased]`
- [ ] If the config schema or behaviour changed: the relevant guide in
  `guides/` is updated
- [ ] If a new module: it's listed in `mix.exs`
  `groups_for_modules` so HexDocs renders it correctly

The PR template in `.github/PULL_REQUEST_TEMPLATE.md` mirrors this
checklist.

## Reporting bugs

Use `.github/ISSUE_TEMPLATE/bug_report.md`. The essentials:

- the affected refactor module
- a **minimal** input source (10–30 lines, complete `defmodule`)
- the expected output
- the actual output (or stack trace)
- `mix refactor --log` output for that file, if non-empty

Bugs that include a minimal repro get fixed fast. Bugs without one
take longer because we have to reconstruct the case.

## Proposing a new refactor

Use `.github/ISSUE_TEMPLATE/refactor_proposal.md` first if you want
feedback on the idea before implementing. For straightforward,
narrowly-scoped refactors, opening a PR directly is also fine.

What we'll ask:

- **Is the rewrite semantics-preserving?** Walk through the edge
  cases you considered.
- **Is the rewrite idempotent?** Show that running it on the *output*
  produces the output unchanged.
- **Is the rewrite worth a module?** Tiny, single-pattern rewrites can
  be wholesome on their own; very narrow ones may be better as a
  per-refactor config option.

## Security issues

Please don't open public issues for security-sensitive bugs (e.g. a
crafted input that triggers code execution during refactor parsing).
Email instead — address TBD; until that's published, open an issue
prefixed `[security]` and we'll move the discussion off-platform.

## Release process (maintainers)

1. Bump `@version` in `mix.exs`.
2. Move `[Unreleased]` entries in `CHANGELOG.md` to a new dated
   section.
3. `mix hex.build` — verify the tarball locally.
4. `mix hex.publish --dry-run` — verify the publish.
5. Tag: `git tag v<version> && git push --tags`.
6. `mix hex.publish` — actually publish.
7. GitHub release with the changelog entry as the body.
