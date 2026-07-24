# Number42.Refactors

AST-based refactor engine for Elixir — pluggable, idempotent rewrites
driven by [Sourceror][sourceror].

> ⚠️ **No semantic-equivalence guarantee.** Refactors aim to keep
> behaviour intact, but this is not formally proven. Treat every run
> as a code change: review the diff, run your test suite, and rely on
> CI before merging.

> Status: pre-release. Extracted from an internal project; the public
> API is settling. Expect cosmetic changes before `v1.0`.

## Intent

**The engine writes the change you already knew you wanted, and refuses
when it cannot tell.**

That sentence carries the two halves of the design, and the second half
is the load-bearing one.

Automated rewriting is easy to do badly. A tool that rewrites
aggressively produces diffs nobody can review, and a diff nobody
reviews is a behaviour change nobody consented to. So every refactor
here is built around a decline: it establishes that a rewrite is
warranted, or it leaves the source untouched. **Skipping is always
correct; guessing never is.** Where those two conflict this codebase
picks skipping — and the cost of that choice is real recall, given up
deliberately.

Three consequences follow, and they explain most of what looks unusual
in here:

- **Idempotence is a hard requirement, not a nice property.** The
  engine runs a fixpoint loop, so a refactor that keeps changing its
  own output never terminates. Every refactor ships an idempotence
  test.
- **Detection is the hard part; rewriting is mechanical.** The
  interesting code decides *whether* a site qualifies. Once that is
  settled, emitting the patch is usually short. This is why detection
  quality — not transform coverage — is where the effort goes.
- **Naming is part of correctness.** A refactor that extracts a
  function must name it. A name that says nothing (`do_block`,
  `helper_2`) is permanent noise, worse than the duplication it
  replaced — so several refactors decline purely because they cannot
  name their output confidently.

### What it is

A Mix task plus ~139 modular refactors that rewrite Elixir source into
more idiomatic Elixir — from local idiom fixes (`Enum.into` → `Map.new`,
`length(x) == 0` → `x == []`) up to structural work: extracting shared
modules, deriving behaviours from adapter families, lifting duplicated
HEEx into shared components, splitting low-cohesion modules.

### What it is not

- Not a formatter — that is `mix format`.
- Not a linter — that is Credo. A linter reports; this rewrites.
- Not a compiler plugin. Every refactor is a pure string
  transformation `source → source`, driven by Sourceror.

### Who uses it

Elixir projects, as a dev-only dependency
(`only: [:dev, :test], runtime: false`). The end product is a git diff.
Nothing here runs in production.

---

## Contents

- [Installation](#installation)
- [Quickstart](#quickstart)
- [Configuration: `.refactor.exs`](#configuration-refactorexs)
- [What's inside](#whats-inside)
- [Safety model](#safety-model)
- [Local development](#local-development)
- [Testing](#testing)
- [Bugfixing workflow](#bugfixing-workflow)
- [Writing your own refactor](#writing-your-own-refactor)
- [Architecture in 5 minutes](#architecture-in-5-minutes)
- [CI & quality gates](#ci--quality-gates)
- [Release & versioning](#release--versioning)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Installation

```elixir
def deps do
  [
    {:number42_refactors, "~> 0.1", only: [:dev, :test], runtime: false}
  ]
end
```

Then `mix deps.get`, and create a `.refactor.exs` as described under
[Configuration](#configuration-refactorexs) — without it the task
refuses to run. That refusal is deliberate: a refactor engine with no
declared input set would default to rewriting whatever it found.

## Quickstart

```sh
mix refactor                     # apply everything, write in place
mix refactor --check             # CI gate: exit ≠ 0 if anything would change
mix refactor --dry-run           # print a git-style diff, write nothing
mix refactor --log               # per refactor: description, rationale, diff
mix refactor --auto              # commit after each file
mix refactor --step-by-step      # one refactor at a time, across all files
mix refactor --only RejectIsNil  # a single refactor (suffix or snake_case)
mix refactor lib/foo/bar.ex      # restrict to given paths

mix refactor.heex_clones         # HEEx clone report (exact / class-stripped / attrs-stripped)
```

Start with `--dry-run`. Full option list: `mix help refactor` and
`mix help refactor.heex_clones`.

## Configuration: `.refactor.exs`

Lives in the **consumer's** project root and is a plain
`Code.eval_string/3` map expression.

```elixir
%{
  # Required: paths the engine rewrites by default.
  inputs: ["lib/**/*.ex", "test/**/*.exs"],

  # Optional: per-refactor options. Keys are fully-qualified modules,
  # values are keyword lists. Common keys:
  #   priority:        integer (default 100; higher runs earlier)
  #   skip_in_modules: [Module, ...] — source files defining one of
  #                    these modules are left alone
  configured_modules: [
    {Number42.Refactors.Ex.ExpandShortFormBindings,
     skip_in_modules: [MyApp.Color]}
  ],

  # Optional: refactors that should never run in this project.
  skipped_modules: [],

  # Optional: HEEx clone extraction. Set the target CoreComponents
  # module. Without this key, ExtractHeexExactClone is a no-op.
  heex: %{
    core_components_module: "MyAppWeb.CoreComponents"
  }
}
```

`skipped_modules` is how a refactor is held back — there is no
per-refactor enabled flag. This repo's own `.refactor.exs` is worth
reading as an example: each skipped entry carries the reason it is off,
which is the convention to follow. Several are off because their
heuristics mis-trigger specifically on a codebase full of
similar-shaped AST walkers.

See the `Mix.Tasks.Refactor` moduledoc for full flag semantics and
interactions (`--auto` + `--test`, `--step-by-step` + `--stop`, …).

## What's inside

Roughly **139 refactors**. The [refactor catalog][catalog] is the full
index with per-module rationale; the groups below are the map.

**Local idiom** — the bread and butter. Enum/Map/Stream canonicalisation
(`Enum.into` → `Map.new`, reduce-to-sum, filter-first-to-find), length
and string idioms, pattern matching over conditionals (`if`-lift to
clauses, nested `case` → `with`), pipe shaping.

**Style & ordering** — alias sorting and expansion, directive ordering,
keyword sorting, attribute spacing. Layout only; nothing moves between
modules.

**Definition hygiene** — short-form expansion, unused variables,
`@impl true` resolution, identity passthrough removal, exact-duplicate
delegation, flag-argument splitting.

**Extraction & structure** — the ambitious half. Shared modules,
parametric and renamed clones, common prologs, behaviours derived from
adapter families, protocols from struct families, low-cohesion module
splitting, primitive-to-struct promotion.

**HEEx** — clone extraction into CoreComponents, near-clone merging via
tree-edit distance, component extraction by assign seam, public
component promotion, attribute contract tightening.

**Type & API safety** — untyped params lifted to struct patterns,
unsafe `Map.get` passes, `try/rescue` with safer alternatives.

**Semantic naming** — several refactors name their output using frozen
static-embedding tables in `priv/semantic` (verb and predicate models).
The tables ship with the library; the generation dependencies (`nx`,
`tokenizers`, `safetensors`) are `:dev`-only and never reach consumers.

`mix help refactor` lists every refactor with its short name.

## Safety model

Worth understanding before enabling anything broad, because the
guarantees differ sharply by refactor class.

**Single-file refactors** are the well-covered case. Each is
independently tested, idempotent, and verified by a convergence sweep:
every file's output is re-run through the engine to confirm a second
pass changes nothing, with oscillation caught by timeout. The current
sweep covers 331 files with zero flagged.

**Cross-file refactors** carry more risk and less verification. They
rewrite several files as one atomic set — a shared module plus its
callers — so the output only compiles as a whole. The convergence sweep
explicitly excludes them, and dogfooding has produced non-compiling
diffs from this class before. Treat their output as requiring real
review, not a skim.

**What the engine guarantees:** termination (fixpoint capped at 5
passes), idempotence per refactor, and that a declined site is left
byte-identical.

**What it does not guarantee:** semantic equivalence. Read the diff.

See the [safety and limitations guide][safety] for the full treatment.

---

## Local development

Requires **devenv + direnv** (see `devenv.nix`). First-time setup:

```sh
direnv allow            # let direnv load the dev shell automatically
devenv shell            # Elixir 1.19 / OTP 28 plus tooling
mix deps.get            # the enterShell script does this too
mix compile
```

After that, `cd` into the project and direnv activates the shell. If you
would rather avoid Nix, set the versions from `devenv.nix`
(Elixir 1.18+/1.19, OTP 27+/28) via `asdf`/`mise`; CI tests the matrix
`1.18/27` and `1.19/28`.

**Daily commands:**

| Task                               | Command                                   |
| ---------------------------------- | ----------------------------------------- |
| Run tests                          | `mix test`                                |
| One test file                      | `mix test test/refactors/ex/foo_test.exs` |
| Only what changed                  | `mix test --stale`                        |
| Coverage                           | `mix test --cover`                        |
| Format check                       | `mix format --check-formatted`            |
| Format                             | `mix format`                              |
| Compile with warnings as errors    | `mix compile --warnings-as-errors`        |
| Credo (high priority)              | `mix credo --min-priority=high`           |
| Credo strict (full list)           | `mix credo --strict`                      |
| Dialyzer (builds PLT on first run) | `mix dialyzer`                            |
| Dependency security audit          | `mix deps.audit`                          |
| Build and open docs                | `mix docs && open doc/index.html`         |

**Run the pre-commit triad before committing:**

```sh
mix format
mix compile --warnings-as-errors
mix test
```

That is exactly what `devenv shell precommit` runs. Doing it up front
means the commit lands on the first attempt — otherwise the hook
reformats, the commit aborts, and you re-stage.

## Testing

Every refactor has **exactly one** test file at
`test/refactors/<area>/<name>_test.exs` that exercises it **in
isolation**, not through the full pipeline. A red test therefore points
at exactly one module.

The case module is `Number42.RefactorCase`
(`test/support/refactor_case.ex`), providing three helpers:

```elixir
defmodule Number42.Refactors.Ex.RejectIsNilTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.RejectIsNil
  @subject RejectIsNil

  describe "rewrites" do
    test "filter + not is_nil → Enum.reject(&is_nil/1)" do
      assert_rewrites(
        @subject,
        "Enum.filter(list, fn x -> not is_nil(x) end)",
        "Enum.reject(list, &is_nil/1)"
      )
    end
  end

  describe "leaves alone" do
    test "already canonical" do
      assert_unchanged(@subject, "Enum.reject(list, &is_nil/1)")
    end
  end

  describe "idempotent" do
    test "twice == once" do
      assert_idempotent(@subject, "Enum.filter(list, fn x -> not is_nil(x) end)")
    end
  end
end
```

Conventions that matter:

- **`async: true` is mandatory** — refactors are pure functions with no
  shared database or process state.
- **Three sections per file:** `rewrites`, `leaves alone`,
  `idempotent`. The middle one is not filler — a refactor's decline
  behaviour is half its contract, and it is the half that prevents
  damage.
- **Idempotence is not optional.** The engine has a fixpoint loop; a
  non-idempotent refactor runs to the cap and produces churn.
- **Whitespace-agnostic comparison.** `assert_rewrites/3` collapses
  whitespace runs before comparing, so heredocs can be indented
  naturally and the test path skips a `mix format` pass. Failure
  messages still show the raw strings.
- **Tests cover our refactors, not Sourceror.** A test that would break
  on a Sourceror bump with no change on our side is testing the
  library — rewrite it or delete it.

```sh
mix test --cover
mix test test/refactors/ex/reject_is_nil_test.exs --trace
```

## Bugfixing workflow

A typical bug: a consumer reports that something was rewritten
incorrectly, or a file keeps changing on a second pass (broken
idempotence).

1. **Isolate the reproduction.** Build the smallest input that shows
   the behaviour, and look at the AST before opening the refactor:

    ```sh
    mix run --no-start -e '
      src = "your_buggy_example"
      {:ok, ast} = Sourceror.parse_string(src)
      IO.inspect(ast, limit: :infinity)
    '
    ```

2. **Failing test first.** Add an `assert_rewrites` or
   `assert_unchanged` case with your input, and watch it go red:

    ```sh
    mix test test/refactors/ex/your_refactor_test.exs --trace
    ```

3. **Rule out the pipeline.** Check whether the single refactor
   reproduces it:

    ```sh
    mix refactor --only YourRefactor --dry-run lib/path/to/file.ex
    ```

4. **Fix it.** Read `lib/number42/refactors/ast_helpers.ex` before
   building a helper — most of what you need exists (`bare_var`,
   `body_to_exprs`, `clip_end_for_boolish_tail`, …).
5. **Add the idempotence case**, or the bug returns via the fixpoint.
6. **Smoke-test against this library itself** if the refactor does
   anything structural, then `git checkout -- lib/ test/`. We commit
   the refactor and its test, never incidental pipeline output.
7. **Before committing:** the pre-commit triad, then
   `git add <refactor>.ex <refactor>_test.exs` and nothing else.

### Common AST traps

Details and examples in `AGENTS_README.md`:

- Sourceror wraps `true`, `false`, `nil`, atoms, integers and floats in
  `{:__block__, _, [literal]}`. Match both forms.
- Sourceror overshoots the range of `true`/`false`/`nil` by one column,
  so `Patch.replace` eats the following character. Use
  `clip_end_for_boolish_tail/2` from `AstHelpers`.
- `def`/`defp`/`defmacro`/`defmacrop` heads look like generic calls.
  Skip or special-case them explicitly, or you will rewrite
  signatures.
- `Sourceror.to_string/1` re-emits `:leading_comments` and
  `:trailing_comments` from node meta. Strip them with `Macro.prewalk`
  before stringifying a reused subtree, or comments duplicate.
- **When the pattern is ambiguous, leave it alone.** This is the house
  rule, not a fallback.

## Writing your own refactor

A refactor is a module implementing `Number42.Refactors.Refactor`,
marked with `use`. The engine discovers it automatically at startup.

```elixir
defmodule MyApp.Refactors.MyRule do
  use Number42.Refactors.Refactor

  @impl true
  def description, do: "What this refactor does — one line."

  @impl true
  def transform(source, _opts) do
    # Sourceror-based rewrite; return the rewritten string.
    # Idempotent! Conforming code must pass through untouched.
    source
  end

  # All optional:
  # @impl true
  # def explanation, do: "Long-form rationale, shown by --log."
  # @impl true
  # def priority, do: 150               # default 100; higher runs earlier
  # @impl true
  # def reformat_after?, do: true       # trigger mix format afterwards
  # @impl true
  # def prepare(_opts), do: {:ok, term} # once per engine run, cached
  # @impl true
  # def patches(ast, source, _opts), do: []   # opt into AST sharing
end
```

**`patches/3` instead of `transform/2`** is worth knowing about: the
engine parses a file once and shares that AST across every refactor
implementing `patches/3`, gated on disjoint ranges. Around 79 refactors
opt in, and it is a measurable win on large runs. Use it unless your
refactor needs the raw source string.

Non-negotiables:

- **Idempotent.** Second run equals first run.
- **Decline rather than guess.** An ambiguous case stays untouched.
  Missing an opportunity costs nothing; a wrong rewrite costs trust in
  every other diff the tool produces.
- **Name confidently or decline.** If you cannot derive a name that
  says what the extracted thing is, do not extract it.
- **Best-effort, not guaranteed.** Refactors *aim* to preserve
  observable behaviour without formally assuring it.

Write it test-first: test file → red → refactor module → green →
optional smoke test against this repo, then
`git checkout -- lib/ test/`.

See the [authoring guide][authoring] for the full walkthrough.

## Architecture in 5 minutes

```
       .refactor.exs                 mix refactor [opts] [paths]
            │                                │
            ▼                                ▼
 ┌─────────────────────────────────────────────────────────┐
 │ Mix.Tasks.Refactor       (lib/mix/tasks/refactor.ex)    │
 │  • load config, expand inputs                           │
 │  • --auto/--test/--check/--step-by-step drivers          │
 │  • mix format follow-up when reformat_after?             │
 └───────────┬─────────────────────────────────────────────┘
             ▼
 ┌─────────────────────────────────────────────────────────┐
 │ Number42.Refactors.Engine                               │
 │  • discovers refactors (is_refactor attribute)           │
 │  • sorts by priority/0 (higher first)                    │
 │  • fixpoint loop per file (max 5 passes)                 │
 │  • prepare/1 cache via :persistent_term                  │
 │  • shares one AST across patches/3 refactors             │
 └───────────┬─────────────────────────────────────────────┘
             ▼
 ┌─────────────────────────────────────────────────────────┐
 │ a refactor module (lib/number42/refactors/ex/*.ex)       │
 │  • transform(source, opts) or patches(ast, source, opts) │
 │  • uses Sourceror + AstHelpers + the analysis engines    │
 └─────────────────────────────────────────────────────────┘
```

Key modules:

- **`Engine`** — pure library, no I/O, no Mix. Drives the pipeline:
  `--only`, `skipped_modules`, priorities, fixpoint, AST sharing.
- **`Refactor`** — the behaviour plus `__using__`. Sets the
  `is_refactor` attribute and imports `AstHelpers`.
- **`AstHelpers`** — shared AST predicates and accessors. Read it
  before writing a helper.
- **`AstDiff`** — diff helpers for `--log` and test failures.

The analysis engines are the reusable substrate the structural
refactors build on, and most are under-consumed relative to what they
can do:

- **`Semantic`** — frozen embedding tables; verb and predicate models
  for naming decisions.
- **`TreeEditDistance`** — tree-agnostic edit distance, with adapters
  for Elixir and HEEx trees.
- **`CommunityDetection`** — modularity-maximising graph clustering.
- **`BlockSegmentation`** — per-statement read/write sets, carrier
  tracking, phase grouping.
- **`AttributeClassifier`**, **`VocabularyClassifier`**,
  **`HelperNaming`**, **`IdentifierExpansion`**, **`LiteralNaming`** —
  classification and naming.
- **`Heex.*`** — tree, fingerprint, normalizer, motif, scope and clone
  detection for HEEx subtrees.
- **`Number42.RefactorCase`** (`test/support/`) — `assert_rewrites`,
  `assert_unchanged`, `assert_idempotent`.

Full detail in the [architecture guide][architecture].

## CI & quality gates

Workflows in `.github/workflows/`, on every PR and push to `main`:

- **`ci.yml`** — matrix `1.18 / OTP 27` and `1.19 / OTP 28`:
  `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix test`.
- **`credo.yml`** — `mix credo --min-priority=high`. High priority only,
  so lower-severity hints do not block; `mix credo --strict` locally is
  the full list.
- **`dialyzer.yml`** — `mix dialyzer --format short`, with PLT cache.
- **`security.yml`** — `mix deps.audit`, weekly and per PR.
- **`auto-merge-dependabot.yml`** — patch/minor Dependabot PRs
  auto-merge once the above are green.

This repo also applies the library to **its own source** (the
`.refactor.exs` in the root), so every rule shipped to consumers holds
here too. If a refactor change turns `mix refactor --check` red, that
is the gate working.

## Release & versioning

- Semver; `CHANGELOG.md` in Keep-a-Changelog format. `CHANGELOG.md` is
  marked `merge=union` in `.gitattributes`, because parallel refactor
  PRs otherwise collide on it constantly.
- Build with `mix hex.build`. Publishing is deliberately manual from
  the maintainer account.
- Update the `## [Unreleased]` block with every released change.

## Troubleshooting

**`mix` not found.** You are outside the dev shell. `direnv reload` or
`devenv shell`. If that does not help: `rm -rf .direnv .devenv`, then
`direnv reload`.

**Pre-commit hook aborts the commit.** Almost always a `mix format`
mismatch. Run `mix format`, re-stage, commit again. **Never
`--no-verify` by default** — only when the infrastructure itself is
stuck, and only with the triad manually green first.

**A refactor loops forever in tests.** Broken idempotence. Run that
refactor's test file with `--trace`.

**`Sourceror.to_string/1` duplicates comments.** Comments in node meta;
see [Common AST traps](#common-ast-traps).

**`mix refactor` wants a `.refactor.exs` that does not exist.** In a
consumer project, create one. This repo has its own for the bootstrap
run.

**A cross-file refactor produced code that will not compile.** Known
class limitation — see [Safety model](#safety-model). Discard the diff
and file an issue with the input.

**Dialyzer is slow.** The first run builds the PLT into `priv/plts/`,
cached in CI by `mix.lock` hash. If the cache is dirty:
`rm -rf priv/plts && mix dialyzer`.

**A run takes minutes on a large project.** Cross-file refactors each
build a project-wide plan, and that phase dominates the wall clock.
Narrow the run with paths or `--only`.

## License

MIT — see [LICENSE](LICENSE).

[sourceror]: https://github.com/doorgan/sourceror
[catalog]: guides/refactor-catalog.md
[safety]: guides/safety-and-limitations.md
[authoring]: guides/authoring-a-refactor.md
[architecture]: guides/architecture.md
