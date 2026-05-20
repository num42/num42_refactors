# Num42.Refactors

AST-based refactor engine for Elixir — pluggable, idempotent,
semantics-preserving rewrites driven by [Sourceror][sourceror].

> Status: pre-release. Extracted from an internal project; the public
> API is settling. Expect cosmetic changes before `v1.0`.

## Installation

Add `num42_refactors` to your `mix.exs`:

```elixir
def deps do
  [
    {:num42_refactors, "~> 0.1", only: [:dev, :test], runtime: false}
  ]
end
```

## Quickstart

```sh
mix refactor              # apply all refactors
mix refactor --check      # exit non-zero if anything would change (CI mode)
mix refactor --log        # show per-refactor rationale + diff
mix refactor --auto       # apply, run mix format, commit per refactor
mix refactor --step-by-step  # walk one refactor at a time
mix refactor lib/foo/bar.ex  # restrict to specific files
```

`mix help refactor` for the full option list.

## Configuration

Required `.refactor.exs` at the project root (the task aborts without
it). The file is a plain `Code.eval_string/3` map:

```elixir
%{
  # Required: paths the engine should rewrite by default
  inputs: ["lib/**/*.ex", "test/**/*.exs"],

  # Optional: per-refactor opts. Keys are fully-qualified modules,
  # values are keyword lists. Common keys:
  #   priority: integer (default 100; higher runs first)
  #   skip_in_modules: [Module, ...] (leave files that defmodule any of these alone)
  configured_modules: [
    {Num42.Refactors.Refactors.ExpandShortFormBindings,
     skip_in_modules: [MyApp.Color]}
  ],

  # Optional: refactors to omit entirely from this project's pipeline
  skipped_modules: [],

  # Optional: HEEx clone extraction target
  heex: %{
    # CoreComponents module that ExtractHeexExactClone appends to.
    # Omit to no-op that refactor.
    core_components_module: "MyAppWeb.CoreComponents"
  }
}
```

## What's in the box

~60 refactors across these areas:

- **Style & ordering**: alias ordering, multi-alias expansion, import-after-alias,
  function sorting, keyword sorting, blank lines between attrs.
- **Enum / Map / Stream idioms**: `Enum.into → Map.new`, `Enum.reduce → Enum.sum`,
  `Enum.reverse |> Enum.concat`, `Enum.flat_map → Enum.filter`, `Map.new`
  lambda-to-comprehension, `Stream`-friendly rewrites, `Enum.reject(&is_nil/1)`,
  `reduce_as_map`, `reduce_map_put`.
- **Pattern matching over conditionals**: `if`-lift to clauses, redundant-boolean-if,
  nested `case → with`, `with` single-clause-to-case, `with`-without-else.
- **Pipe & sigil rewrites**: extract socket-to-pipe, extract-to-pipeline,
  pipe-reassign, lift-with-into-pipeline, lift-pinned-Ecto-expr.
- **Length / String / List**: length-in-guard, length-zero-to-empty,
  list-last-of-reverse, graphemes-length, sort-for-top-k.
- **Definition hygiene**: inline-single-expression-def, identity-passthrough,
  delegate-exact-duplicates, expand-short-form-{bindings,functions,params},
  unused-variable, resolve-impl-true, remove-trivial-else-clause,
  case-true-false.
- **Cross-file extraction**: extract-shared-module, extract-parametric-clone,
  extract-renamed-clone, extract-intra-module-clone, extract-nested-block,
  extract-lambda-block, extract-inline-block, extract-case-to-helper.
- **HEEx clones**: extract-heex-exact-clone (configurable target),
  extract-heex-for.
- **Type / API safety**: try-rescue-with-safe-alternative,
  map-get-unsafe-pass, utc-now-truncate.

`mix help refactor` enumerates every module by short name.

## Authoring a custom refactor

Implement `Num42.Refactors.Refactor` and `use` the behaviour for
auto-discovery:

```elixir
defmodule MyApp.Refactors.MyRule do
  use Num42.Refactors.Refactor

  @impl true
  def description, do: "What this refactor does in one line"

  @impl true
  def transform(source, _opts) do
    # Sourceror-based rewrite; return the rewritten string.
    source
  end
end
```

Refactors must be **semantics-preserving** and **idempotent** — running
the engine twice yields the same result as once. The engine drives a
fixpoint loop, so refactors can feed each other.

## License

MIT — see [LICENSE](LICENSE).

[sourceror]: https://github.com/doorgan/sourceror
