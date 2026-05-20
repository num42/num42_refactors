<!-- Thanks for the PR! Fill in what's relevant and delete what isn't. -->

## What & Why

<!-- One paragraph: what does this PR change, and why is it the right
     change? Link any related issue (e.g. "Closes #123"). -->

## How

<!-- Brief description of the implementation approach. Skip for
     trivial PRs. -->

## Checklist

- [ ] `mix test` passes
- [ ] `mix format --check-formatted` is clean
- [ ] `mix credo --strict` is clean (or new findings explained below)
- [ ] `mix dialyzer` is clean (or new warnings explained below)
- [ ] If adding a refactor: golden test + idempotence test + no-op test
- [ ] If user-visible: `CHANGELOG.md` updated under `[Unreleased]`
- [ ] If the config schema or behaviour changed: the relevant guide in
  `guides/` is updated
- [ ] If a new module: it's listed in `mix.exs` `groups_for_modules`

## Notes for the reviewer

<!-- Anything that would help review: a tricky edge case, a perf
     trade-off, a follow-up you've deferred. -->
