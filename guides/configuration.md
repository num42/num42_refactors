# Configuration

Reference for `.refactor.exs`, the project-level configuration file
that `mix refactor` reads.

## Why a separate file

- Not `config.exs` — that's compile-time / runtime project config, and
  `mix refactor` runs at development time.
- Not `.formatter.exs` — overloading it with refactor-specific keys
  would couple two different tools.
- Plain `Code.eval_string/3` map at the project root. No dependencies
  beyond the Elixir standard library.

## Minimal example

```elixir
%{
  inputs: ["lib/**/*.ex", "test/**/*.exs"]
}
```

That's all you need to run `mix refactor`. Without the file the task
aborts with a clear error.

## Full reference

```elixir
%{
  # ─── Required ─────────────────────────────────────────────
  # Glob patterns the engine rewrites by default. Paths passed on
  # the command line override this list.
  inputs: ["lib/**/*.ex", "test/**/*.exs"],

  # ─── Optional ─────────────────────────────────────────────
  # Per-refactor options. Keys are fully-qualified modules.
  configured_modules: [
    {Number42.Refactors.Ex.ExpandShortFormBindings,
     skip_in_modules: [MyApp.Color],
     priority: 150}
  ],

  # Refactors to omit entirely from this project's pipeline.
  skipped_modules: [
    Number42.Refactors.Ex.SortFunctions
  ],

  # HEEx-aware refactors read this block.
  heex: %{
    # The CoreComponents module that ExtractHeexExactClone appends
    # generated components to. Omit to make that refactor a no-op.
    core_components_module: "MyAppWeb.CoreComponents"
  }
}
```

## Keys in detail

### `inputs` (required)

A list of glob patterns (`Path.wildcard/1` semantics). Recursive
patterns (`**`) are supported. The engine resolves the union of these
patterns to a flat file list before applying any refactor.

Passing paths on the CLI (`mix refactor lib/foo.ex`) replaces this list
for the duration of that invocation only.

### `configured_modules`

A list of `{Module, keyword_list}` tuples. Recognised per-module keys:

#### `priority: integer`

Overrides the refactor's own `priority/0` callback. Default `100`;
higher runs earlier. Use this when project-specific ordering matters
(e.g. a custom refactor that should run before bundled ones).

```elixir
{Number42.Refactors.Ex.MultiAliasExpand, priority: 200}
```

#### `skip_in_modules: [Module, ...]`

Source files that define `defmodule X` for any listed module are left
alone by this refactor. Useful for refactors whose heuristics misfire
on a known module:

```elixir
# ExpandShortFormBindings turns single-letter bindings into
# fully-spelled names — wrong for math-y code in Color/Vector modules.
{Number42.Refactors.Ex.ExpandShortFormBindings,
 skip_in_modules: [MyApp.Color, MyApp.Vector]}
```

The match is on literal `defmodule X.Y.Z` text — fast, and good enough
in practice. False positives in comments or string literals are
vanishingly rare.

#### Refactor-specific keys

A few refactors accept their own keys. Look at the refactor's
moduledoc:

- `ExtractHeexExactClone` — reads `heex.core_components_module` from
  the top-level config (not from its own opts entry).

### `skipped_modules`

A list of modules to remove from the pipeline entirely. Equivalent to
not having them compiled in the first place. Use this for refactors
whose output style doesn't fit your house rules.

### `heex.core_components_module` (string)

Fully-qualified module name as a string. The HEEx clone extractor
appends generated `defp <name>(assigns)` functions to the source file
that contains `defmodule <this string>`. Omit it and HEEx clone
extraction becomes a no-op.

## CLI overrides

Some config decisions can be overridden per invocation:

| CLI flag             | Equivalent config             |
|----------------------|-------------------------------|
| `<paths...>`         | `inputs` (replaced)           |
| `--only <Module>`    | filters `pipeline_modules`    |
| `--dry-run`          | sets `dry_run: true` in opts  |

The CLI flags do **not** modify `.refactor.exs` on disk.

## Recipes

### Phoenix application

```elixir
%{
  inputs: [
    "lib/**/*.ex",
    "lib/**/*.heex",
    "test/**/*.exs"
  ],
  heex: %{
    core_components_module: "MyAppWeb.CoreComponents"
  }
}
```

### Pure library (no HEEx, no extraction)

```elixir
%{
  inputs: ["lib/**/*.ex", "test/**/*.exs"],
  skipped_modules: [
    Number42.Refactors.Ex.ExtractHeexExactClone,
    Number42.Refactors.Ex.ExtractHeexFor,
    Number42.Refactors.Ex.ExtractSharedModule,
    Number42.Refactors.Ex.ExtractParametricClone,
    Number42.Refactors.Ex.ExtractRenamedClone
  ]
}
```

### Umbrella

`.refactor.exs` sits at the umbrella root. Inputs cross app
boundaries:

```elixir
%{
  inputs: [
    "apps/*/lib/**/*.ex",
    "apps/*/test/**/*.exs"
  ]
}
```

Cross-file refactors (extractions, HEEx clones) operate over the
union of all included files — extracting a clone from `apps/web/` and
`apps/api/` into a shared module is supported, but you'll want to
verify the chosen target file makes sense for your dependency graph.

### Excluding generated code

```elixir
%{
  inputs: [
    "lib/**/*.ex",
    "test/**/*.exs"
  ],
  # If your build outputs to `lib/generated/`, make sure your input
  # globs don't reach it.
}
```

There is no `exclude:` key — keep generated paths out of `inputs` and
out of cross-file refactor reach by leaving them out of the glob.

### Pinning priorities for stable diffs

If your team is sensitive to the *order* of edits in a diff, fix the
priorities of refactors that touch overlapping code:

```elixir
configured_modules: [
  {Number42.Refactors.Ex.MultiAliasExpand, priority: 250},
  {Number42.Refactors.Ex.AliasOrder,       priority: 200},
  {Number42.Refactors.Ex.ImportAfterAlias, priority: 150}
]
```

The fixpoint loop will converge to the same final state regardless,
but the order of intermediate edits — visible with `--step-by-step` —
becomes deterministic and obvious.

## Validation

The loader (`Mix.Tasks.Refactor.Shared`) validates:

- the file exists at the project root
- it evaluates to a map
- `inputs` is present and is a list of strings

A missing or malformed file produces a Mix-task abort with a message
pointing at the specific problem. There is no "default config" fallback
— the absence is a hard error so missing setup is not silently
papered over.

## Reloading

`.refactor.exs` is read once per `mix refactor` invocation. There is no
file watcher. If you edit the config, re-run the task.
