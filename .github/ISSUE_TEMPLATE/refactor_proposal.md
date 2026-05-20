---
name: New refactor proposal
about: Propose a new refactor module.
title: "[refactor] "
labels: enhancement, refactor-proposal
assignees: ''
---

## Working name

<!-- e.g. Number42.Refactors.Ex.FooBar -->

## One-line description

<!-- The `description/0` callback you'd write. Keep it short. -->

## Before

```elixir
```

## After

```elixir
```

## Why is this rewrite semantics-preserving?

<!-- Walk through the edge cases you considered: macros, sigils,
     side effects, exceptions, type signatures. -->

## Why is this rewrite idempotent?

<!-- Running the refactor on the After snippet must produce the
     same output. Explain why. -->

## Suggested priority

<!-- Default is 100. Higher runs earlier. Use a non-default value
     only if order matters relative to another refactor. -->

## Does it need `prepare/1`?

<!-- yes / no, with a short note on what project-wide data the
     refactor would precompute. -->

## Prior art

<!-- Credo check, Sourceror example, blog post, similar refactor in
     another tool (Styler/Quokka/Refactorex). Optional but useful. -->

## Additional context

<!-- Anything else worth knowing. -->
