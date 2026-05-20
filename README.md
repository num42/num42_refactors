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
mix refactor          # apply all refactors
mix refactor --check  # exit non-zero if anything would change (CI mode)
mix refactor --log    # show per-refactor rationale
```

See `mix help refactor` for the full option list.

## Configuration

Optional `.refactor.exs` at your project root, read on each run:

```elixir
%{
  heex: %{
    # Target module for ExtractHeexExactClone; omit to disable that refactor.
    core_components_module: "MyAppWeb.CoreComponents"
  }
}
```

## License

MIT — see [LICENSE](LICENSE).

[sourceror]: https://github.com/doorgan/sourceror
