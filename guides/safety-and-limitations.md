# Safety & Limitations

What this library does and does not promise, and where the rough
edges are. Read this before running `mix refactor --auto` on code you
care about.

## What we promise

### Idempotence (hard requirement)

Applying a refactor twice equals applying it once. The engine's
fixpoint loop relies on this: a non-idempotent refactor either hits
the `@max_passes = 5` cap (and the engine raises) or, worse, produces
oscillating output between two stable states.

Every refactor's test file has an `idempotent` section that asserts
this property on its representative inputs. A failing idempotence
test is a bug we take seriously.

### Best-effort behaviour preservation (no guarantee)

Every bundled refactor *aims* to keep the rewritten code behaving the
same as the input — same return values, same side effects, same
exceptions, same dispatch order. But this is an aim, not a formal
guarantee:

- There is **no automated proof** that a given rewrite is sound. The
  engine doesn't (and can't, in general) verify semantic equivalence.
- A rewrite is only as correct as the patterns the refactor author
  wrote, the test cases they covered, and the edge cases they
  anticipated. Real-world code routinely exposes gaps.
- Macros, dynamic dispatch, `apply/3`, generated code, and side
  effects inside sub-expressions are all places where a "structurally
  identical" rewrite can still change behaviour.

**Practical consequence:** treat every `mix refactor` run as a code
change. Commit before running, review the diff, run your test suite,
and let CI gate it. Do not run `--auto` against code you cannot
revert.

If a rewrite changes runtime behaviour, that's a bug — file it (see
[Reporting safety issues](#reporting-safety-issues)). But the
absence of a bug report is not the same as a proof of correctness.

## What we explicitly do *not* claim

### Performance equivalence

Most refactors are performance wins (`length(x) == 0` → `Enum.empty?/1`
turns O(n) into O(1)), but no refactor *guarantees* faster code. A
refactor that reshapes a `case` into a `with` may, on a hot path,
perform measurably differently.

If your code lives on a microbenchmarked hot path, profile before and
after.

### Type-signature stability

A refactor may tighten or loosen the inferred type of an expression
without breaking the surface contract (same arity, same call shape).
Dialyzer warnings that fire after a refactor pass are usually
pre-existing type issues that the laxer original code masked — but
the refactor engine does no type analysis and makes no formal claim
about type compatibility.

### Source-level structural stability

Anything not protected by the idempotence requirement is fair game to
rewrite: function order, alias grouping, branch shape, expression
nesting. If your team has stylistic conventions that conflict with a
bundled refactor, use `skipped_modules` to opt out.

### Cosmetic stability of generated names

Refactors like `ExtractHeexExactClone` and `ExtractSharedModule`
generate names (`:shared_user_card_abcdef12`). The hash inputs are
deterministic, so the name stays the same across runs — but the
hash *algorithm* may change between library versions. Treat generated
names as content-addressed identifiers that may change on major
version bumps.

## Known limitations

### Macros and `quote do … end`

Refactors operate on the *source* AST. Inside a `quote` block, the
AST you see is a template that will be unquoted and spliced into a
caller's context. Rewrites inside `quote` blocks can produce
templates that no longer expand correctly.

**Current behaviour:** most refactors do not special-case `quote`.
They walk the tree and rewrite matching patterns. This is usually
safe (the rewrites are local and don't depend on context), but it
can break templates with subtle dependencies.

**Mitigation:** if a refactor breaks a macro for you, open an issue
with the minimal `defmacro` + caller. We'll either teach the refactor
to skip the macro body or document the case as a known limitation.

### Generated code via `unquote_splicing/1`

Code that's generated at compile time and never written in source
form is invisible to the refactor engine. A macro that generates ten
similar function clauses produces ten clauses in the *expanded* form,
but only one `def` in the source form. Refactors that look for
duplication across clauses won't find it.

This is by design — we're a source-level tool, not a compile-time
plugin.

### Sigil bodies

Most sigils (`~r`, `~w`, `~s`, custom sigils) appear in the AST with
their body as an opaque string. Refactors leave them alone. The one
exception is HEEx (`~H`), which has its own parsing pipeline (see
[architecture.md](architecture.md)).

If you write a custom refactor that needs to understand a sigil's
contents, you'll need to parse the sigil body yourself — the engine
gives you the string and gets out of your way.

### Cross-file refactors

The `Extract*` family operates on a set of files at once. These have
extra caveats:

- They cannot see **private compilation config** (e.g.
  `@compile {:inline, ...}` attributes outside the matched
  duplication).
- They cannot see **behaviours and dynamic dispatch**. A function
  that looks like a duplicate may be a behaviour callback whose
  signature must stay stable.
- They cannot see **runtime call patterns**. A function that's
  called via `apply(mod, fun, args)` looks unreferenced to static
  analysis.

For these refactors, prefer `--step-by-step` or `--dry-run` on first
runs so you can review what's being extracted.

### HEEx specifics

The HEEx subsystem (`Number42.Refactors.Heex.*`) handles:

- `.heex` template files
- inline `~H"""..."""` sigils in `.ex` / `.exs` files

It does **not** handle:

- `.html.eex` legacy templates (EEx without H)
- `~E` sigils
- HEEx fragments embedded in JavaScript strings or other meta-templates

The clone detector is conservative: it requires byte-for-byte
identical subtrees (in `:exact` mode) or attribute-stripped equality
(`:attrs_stripped`). Near-duplicates that differ in nontrivial ways
are left alone.

## API stability

Pre-1.0. The contract:

- The **public surface** is:
  - `Number42.Refactors.Refactor` (behaviour)
  - `Number42.Refactors.Engine` (`run/2`, `apply_one/3`,
    `pipeline_modules/1`, `refactors/0`)
  - `Mix.Tasks.Refactor` (CLI)
  - `.refactor.exs` schema

- Anything else (helpers, traversal utilities, HEEx internals) is
  **subject to change** without a deprecation cycle. If you build
  on a non-public module, pin your dependency narrowly.

- Changes to the public surface get a `CHANGELOG.md` entry under
  `### Changed` or `### Deprecated`. We won't break those silently.

Post-1.0 we'll switch to SemVer in the strict sense: breaking changes
only on majors, deprecation cycle for one minor before removal.

## Reversibility

`mix refactor --auto` writes to disk. Always:

1. Commit (or at least stash) before running.
2. Inspect the diff afterwards (`git diff` between the pre-run
   commit and HEAD).
3. Run tests.

`mix refactor --check` and `mix refactor --dry-run` are read-only
and safe to run anywhere.

## Reporting safety issues

If a refactor produces code that:

- fails to compile
- changes runtime behaviour in a way that the moduledoc didn't warn
  about
- oscillates between two states (idempotence violation)

…that's a bug we want to know about. File an issue with:

- the affected refactor module
- the minimal input source (10–30 lines)
- the expected output
- the actual output

See `.github/ISSUE_TEMPLATE/bug_report.md` for the template.
