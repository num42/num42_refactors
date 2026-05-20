# Using `number42_refactors` in CI

> **Status:** STUB — to be filled.

How to wire the refactor engine into continuous integration.

## TODO outline

- [ ] **`--check` mode** — exit code semantics, what counts as „would
  change", interaction with `mix format --check-formatted`.
- [ ] **GitHub Actions example** — full workflow yaml with caching.
- [ ] **GitLab CI example** — short equivalent.
- [ ] **Pre-commit hook** — `.pre-commit-config.yaml` snippet, when to use
  vs. CI-only.
- [ ] **PR-comment workflow** — running `mix refactor --auto` on a bot
  branch and opening a PR with the diff.
- [ ] **Performance in CI** — when to cache `_build`, when not, parallel
  test sharding considerations.
- [ ] **Suppressing noisy refactors** — `skipped_modules` for refactors
  that produce large, opinionated diffs in legacy code.
- [ ] **Reporting** — using `--log` output as a CI artifact, machine-readable
  output formats (future work?).
