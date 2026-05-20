# Troubleshooting

Common problems and their fixes.

## "No `.refactor.exs` found"

**Symptom**

```
** (Mix) .refactor.exs not found at project root
```

**Fix**

Create a `.refactor.exs` at the root of the project that *consumes* the
library. The library itself doesn't have one — it's a library, not a
consumer. Minimal config:

```elixir
%{inputs: ["lib/**/*.ex", "test/**/*.exs"]}
```

See [`guides/configuration.md`](configuration.md) for the full
reference.

## "No refactors registered" or empty pipeline

**Symptom**

```
mix refactor
Applied 0 refactors.
```

**Cause**

The refactor modules weren't compiled into the application before the
task ran. Discovery uses
`:application.get_key(:number42_refactors, :modules)` — if compilation
didn't happen, the list is empty.

**Fix**

```sh
mix deps.compile number42_refactors
mix refactor
```

If you wrote a custom refactor, also check:

- `use Number42.Refactors.Refactor` is on the module
- the file is under `lib/` (not `test/`, not `priv/`)
- the module compiled — `mix compile --warnings-as-errors` is green

## Refactor changes pipe shape unexpectedly

**Symptom**

After a refactor, a code chunk that used to be

```elixir
x
|> foo()
|> bar()
```

becomes

```elixir
bar(foo(x))
```

**Cause**

`Sourceror.to_string/1` does not reconstruct pipes that were flattened
during AST manipulation. If your replacement involves rebuilding a
subtree, the pipe shape is lost.

**Fixes (in order of preference)**

1. **`reformat_after?/0 == true`**, only if the formatter would
   restore the pipe — it usually doesn't for hand-rolled chains, but
   does normalise spacing and grouping. Verify on your specific case.
2. **Emit the pipe form directly** in your replacement string. If
   you're building a string with `Sourceror.to_string/1`, prepend
   `Enum.join` or build the chain by hand.
3. **Skip the case.** Pipe shape is a stylistic decision; if you
   can't preserve it deterministically, leave the source unchanged
   for that input.

## Refactor is not idempotent (engine hits max passes)

**Symptom**

```
** (RuntimeError) refactor pipeline did not converge after 5 passes
```

**Diagnosis**

1. Identify which refactor is firing repeatedly. Run with `--log`:

   ```sh
   mix refactor --log --dry-run lib/path/to/file.ex
   ```

2. Look for the same refactor module appearing multiple times in the
   `Applied` list, especially with diffs that *undo* each other or
   re-apply the same rewrite.

**Common causes**

- The rewrite produces code that re-matches the *input* pattern. Add
  a guard in `transform/2` that detects the post-rewrite shape.
- Two refactors fight each other (rare, but happens with style
  refactors that have opposing opinions). Look at relative
  priorities; one should clearly run after the other, not both
  every pass.

**Fix**

Add an `assert_idempotent` test for the failing input. Make it green.

## `mix format` undoes my refactor

**Symptom**

You apply a refactor, then `mix format` runs (either via
`reformat_after?/0` or manually) and your change is gone.

**Cause**

Formatter plugins (e.g. Phoenix's HEEx formatter) can rewrite chunks
of the file that overlap with what the refactor produced. Or, more
commonly: the refactor produced syntactically valid but
stylistically non-conformant code, and the formatter "fixed" it back
toward the original.

**Fix**

Check what `.formatter.exs` includes. If `import_deps: [:phoenix]`
is set and your refactor touches HEEx, the Phoenix formatter has
strong opinions. Either:

1. Adjust the refactor's output to match the formatter's preferred
   shape, or
2. Disable the relevant plugin for files this refactor touches
   (usually a worse trade).

## HEEx refactor does nothing

**Symptom**

`mix refactor --only ExtractHeexExactClone` reports zero changes even
though you have obvious duplication across templates.

**Cause**

`heex.core_components_module` is not set in `.refactor.exs`. Without
that key, the refactor is a no-op by design — we won't guess where
to put generated components.

**Fix**

```elixir
%{
  inputs: [...],
  heex: %{core_components_module: "MyAppWeb.CoreComponents"}
}
```

Use the actual module name in your project. The string must match
`defmodule X.Y.Z` in some source file in `inputs`.

## `--auto` commits in the wrong order

**Symptom**

`mix refactor --auto` commits per refactor, but the commits aren't in
the order you'd expect from the priority ordering.

**Cause**

`--auto` commits **per file × refactor application**, not per
refactor. If file A is rewritten by refactor R1 and then R2, and
file B only by R2, the commit sequence interleaves: `R1(A)`, `R2(A)`,
`R2(B)`. That's correct — each commit is self-contained — but it's
not strictly "all R1 commits, then all R2 commits."

**Fix**

If you want strict per-refactor batching, use `--step-by-step`. It
applies one refactor to all files, then the next, etc., with a
pause between for `git commit -a` if desired.

## Compilation fails after a refactor pass

**Symptom**

`mix refactor` runs, `mix compile` afterwards reports a syntax error
or undefined function.

**Cause (in descending order of likelihood)**

1. A refactor produced invalid code. This is a bug — the refactor
   must produce valid Elixir.
2. A refactor rewrote a call site without rewriting the
   corresponding definition (e.g. `ExtractSharedModule` extracted a
   helper but the original module still defines it).
3. Two refactors interacted badly across the fixpoint loop.

**Diagnosis**

Isolate with `--only`:

```sh
git checkout -- .
for r in $(mix help refactor | grep -oE '[A-Z][a-zA-Z]+$'); do
  mix refactor --only $r --dry-run > /dev/null && \
    mix refactor --only $r && \
    mix compile --warnings-as-errors > /dev/null || {
      echo "broken by: $r"
      git diff
      git checkout -- .
      break
    }
done
```

Report the breaking refactor + minimal input as a bug.

## Slow on large codebases

**Symptom**

`mix refactor` takes minutes on a 100k-LOC repo.

**Diagnosis**

Run with `--log`. Most refactors are cheap (sub-second per file).
Cross-file extractors and HEEx clone detection do more work because
they have to walk every file in `inputs` to build their cluster
table. If those refactors dominate the time, restrict their input
or move them to a separate, slower CI workflow.

**Fix**

```elixir
# .refactor.exs
%{
  inputs: ["lib/**/*.ex", "test/**/*.exs"],
  skipped_modules: [
    # Move these to a weekly batch instead of every PR.
    Number42.Refactors.Ex.ExtractSharedModule,
    Number42.Refactors.Ex.ExtractParametricClone,
    Number42.Refactors.Ex.ExtractRenamedClone,
    Number42.Refactors.Ex.ExtractHeexExactClone
  ]
}
```

See [`guides/performance.md`](performance.md) for more.

## Dialyzer warnings after a refactor

**Symptom**

A refactor pass introduces Dialyzer warnings that weren't there
before.

**Causes**

- The rewrite is correct but exposes a pre-existing type issue.
  Example: `LengthZeroToEmpty` rewrites `length(x) == 0` to
  `Enum.empty?(x)`; Dialyzer now complains that the call site
  receives a non-list, which was already wrong but masked by
  `length/1`'s laxer typing.
- The rewrite is incorrect for your specific type signature. This
  is a bug — please open an issue with a minimal repro.

**Fix**

Read the Dialyzer warning carefully. If it points at the call site,
it's option 1 — fix the type. If it points at the rewritten
expression itself, it's option 2 — file a bug.

## `mix docs` shows refactors in the wrong sidebar group

**Symptom**

A refactor appears in the wrong "Refactors – ..." group, or under no
group at all.

**Cause**

`groups_for_modules:` in `mix.exs` is a manual mapping. New refactors
need to be added by hand.

**Fix**

Add the module to the appropriate group in `mix.exs` and re-run
`mix docs`.

## Pre-commit hook fails the commit

**Symptom**

`git commit` aborts with a hook failure.

**Most common cause**

`mix format` ran in the hook and modified staged files. The commit
itself didn't happen.

**Fix**

```sh
git add -u
git commit
```

The reformatted files are now staged; the commit goes through.

**`--no-verify` is the last resort**, not the default. If you find
yourself reaching for it often, fix the underlying drift instead
(usually: run `mix format` manually before committing).
