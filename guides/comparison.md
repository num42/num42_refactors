# Comparison with Other Tools

The Elixir ecosystem has several tools in this neighbourhood. This page
locates `number42_refactors` among them and explains when to reach for
which.

## TL;DR

| Tool                  | Reports problems | Rewrites code | AST-based | Style-only | Cross-file |
|-----------------------|:----------------:|:-------------:|:---------:|:----------:|:----------:|
| `mix format`          |        —         |       ✓       |     —     |     ✓      |     —      |
| Credo                 |        ✓         |       —       |     ✓     |   mostly   |     —      |
| Sourceror             |        —         |       ✓       |     ✓     |     —      |     —      |
| Styler / Quokka       |        —         |       ✓       |     ✓     |     ✓      |     —      |
| Refactorex            |        —         |       ✓       |     ✓     |     —      |   limited  |
| `number42_refactors`  |        —         |       ✓       |     ✓     |     —      |     ✓      |

The interesting columns are the last two: **rewrites that go beyond
style** and **cross-file refactoring**. That's where
`number42_refactors` sits. None of these tools — this one included —
*guarantees* that a rewrite leaves observable behaviour intact; they
all rely on disciplined patterns + your test suite for that.

## vs. `mix format`

`mix format` is the layout-only formatter that ships with Elixir. It
normalises whitespace, indentation, line breaks, alias grouping
(within limits) — but it never changes which function you call, how a
branch is shaped, or which module a piece of code lives in.

`number42_refactors` is upstream of formatting. It changes
**structure** (`Enum.count(x) == 0` → `Enum.empty?(x)`), not
**layout**. A refactor that produces unformatted output sets
`reformat_after?/0 == true` to trigger `mix format` as a follow-up.

**Use both.** They don't overlap.

## vs. Credo

[Credo](https://github.com/rrrene/credo) is the Elixir linter. It
reports issues — style, design, refactor opportunities, software-design
smells — but it does **not** rewrite code.

`number42_refactors` *rewrites*. Some of its refactors have Credo
analogues that flag the same problem; the difference is that Credo
points at a line and asks the human to fix it, while
`number42_refactors` produces the diff directly.

**Use both.** Credo for code-review signal that doesn't fit a
mechanical rewrite (cyclomatic complexity, naming smells, design
patterns). `number42_refactors` for the mechanical wins.

There is some overlap in scope. We try to keep the overlap on the
rewrite-able side: if Credo can report something *and* a mechanical
rewrite has a plausible "before/after" pair, we offer the rewrite. If
the call requires human judgement, we leave it to Credo.

## vs. Sourceror itself

[Sourceror](https://github.com/doorgan/sourceror) is the library that
makes all of this possible — a low-level toolkit for parsing and
re-emitting Elixir source while preserving comments, layout, and
positions.

`number42_refactors` is built **on top of** Sourceror. We provide:

- the **engine** that discovers and orchestrates refactors
- the **behaviour** that defines what a refactor looks like
- the **Mix task** with `--check` / `--auto` / `--step-by-step`
- ~60 **ready-made rewrites** so you don't start from scratch
- helpers (`AstHelpers`, `AstDiff`, the HEEx subsystem) that knock
  the common cases off

If you're writing one bespoke rewrite for one codebase, use Sourceror
directly. If you're building or consuming a *collection* of rewrites,
this library gives you the framework.

## vs. Styler / Quokka

[Styler](https://github.com/adobe/elixir-styler) and
[Quokka](https://github.com/smartrent/quokka) (a Styler fork) are
opinionated style rewriters: one canonical layout, applied
aggressively, no configuration. They produce excellent diffs on the
patterns they target.

Differences with `number42_refactors`:

- **Scope.** Styler/Quokka focus on style and idiomatic-Elixir
  rewrites (pipe shape, alias ordering, `if`/`unless` cleanup).
  `number42_refactors` covers that *and* extends into cross-file
  extraction, HEEx clone consolidation, and refactors that aren't
  purely stylistic (e.g. `LengthZeroToEmpty` rewrites `length(x) ==
  0` to `Enum.empty?(x)` for genuine performance reasons).
- **Configurability.** Styler is famously opinionated and minimally
  configurable. `number42_refactors` lets you skip refactors per
  project (`skipped_modules`), exclude files per module
  (`skip_in_modules`), and tune priorities — useful in legacy
  codebases where some rewrites are unwelcome.
- **Cross-file.** `ExtractSharedModule`, `ExtractParametricClone`,
  `ExtractHeexExactClone` operate over a *set* of files at once.
  Styler-style tools generally don't.

Many teams will get plenty of value from Styler/Quokka alone. The
case for `number42_refactors` is "we want the style rewrites *and*
the cross-file ones *and* per-refactor opt-out *and* a way to add
custom refactors."

The bundled style rewrites here overlap a lot with Styler/Quokka.
That's fine — pick one or the other for the overlap, or run both and
let one win the diff (the engines are happy to be downstream of each
other).

## vs. Refactorex

[Refactorex](https://github.com/gp-pereira/refactorex) is a Language
Server Protocol implementation that exposes refactorings as editor
actions ("extract function", "rename variable", "inline let").

Different *interaction model*:

- Refactorex: pick a refactoring from a menu, apply it interactively.
- `number42_refactors`: run a pipeline of refactorings across the
  whole project, batch-style.

Both are valid. Refactorex shines for the in-editor refactoring you'd
do during normal coding ("I want to extract this expression into a
helper, right now"). `number42_refactors` shines for the
across-the-codebase "clean up everything that matches pattern X" pass.

## vs. doing it by hand with `sed` / `gsed` / `perl -i`

Tempting for one-shot rewrites. The reasons not to:

- **Context-awareness.** A regex rewrite has no idea whether it's
  inside a string literal, a comment, or a sigil. An AST-based
  refactor does — which keeps it from rewriting strings as if they
  were code. (This is not a semantic-equivalence guarantee, just a
  much smaller foot-gun than `sed`.)
- **Idempotence.** A regex on `length(x) == 0` will happily match
  inside an already-rewritten file again, doubling up annotations,
  or worse.
- **Reviewability.** `mix refactor --log` produces a per-refactor
  rationale that a reviewer can read. `sed -i` produces a wall of
  edits with no story.
- **Undo.** `mix refactor --auto` commits per refactor; `sed -i`
  doesn't.

For genuinely one-shot, idiosyncratic rewrites that fit on a single
line, a careful `gsed` is fine. For anything else, a refactor module
+ a test is barely more work and dramatically safer.

## When NOT to use this library

- **Legacy codebases with intentional anti-patterns.** Refactors are
  opinionated by design. In a codebase where, say, `length(x) == 0`
  is preferred for readability over `Enum.empty?/1`, the relevant
  refactor will keep undoing your team's choices. Either skip those
  refactors or, more honestly, accept that this tool is not aligned
  with the codebase's style.
- **Pre-Elixir 1.18 projects.** The library uses `mix_audit` /
  newer Sourceror features that need recent Elixir. The Sourceror
  dependency in particular pins us to versions that may not
  retro-fit to older Elixir.
- **Projects that vendor Sourceror at an incompatible version.**
  Library users should match Sourceror major versions with us.
  Refusing to upgrade Sourceror means refusing to upgrade us.
- **Live production systems.** This is a development-time tool.
  `runtime: false` in the install instructions is deliberate — there
  is no value, only cost, to shipping the refactor engine in a
  release.
