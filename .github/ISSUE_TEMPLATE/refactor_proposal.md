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

## What invariant makes the rewrite plausible?

<!-- We do not claim semantic equivalence — we claim a well-argued
     mechanical rewrite. Walk through the edge cases you considered
     (macros, sigils, side effects, exceptions, type signatures,
     dispatch order) and call out the inputs you would deliberately
     SKIP rather than rewrite. -->

## Why is this rewrite idempotent?

<!-- This one IS a hard requirement — the engine's fixpoint loop
     depends on it. Running the refactor on the After snippet must
     produce the same output. Explain why. -->

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
