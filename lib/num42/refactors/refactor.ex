defmodule Num42.Refactors.Refactor do
  @moduledoc """
  Behaviour for AST refactor modules applied by `Num42.Refactors.Engine`.

  A refactor implements `transform/2` and rewrites the source string
  itself with `Sourceror`. The plugin treats them opaquely: source in,
  source out.

  ## Required

  - `description/0` — human-readable summary
  - `transform/2`   — the rewrite itself
  - Mark the module with `use Num42.Refactors.Refactor` for
    auto-discovery.

  ## Required correctness properties

  All refactors must be **semantics-preserving** and **idempotent**:
  applying the formatter twice on the same source must yield the same
  result, and code that already conforms must not change.
  """

  @doc """
  Rewrite the source string. Receives the source and the formatter opts
  (see `Mix.Tasks.Format`). Must return the rewritten source. Returning
  the input unchanged is the correct no-op.
  """
  @callback transform(source :: String.t(), opts :: keyword()) :: String.t()

  @doc "One-line human-readable description of the transformation."
  @callback description() :: String.t()

  @doc """
  Long-form rationale shown by `mix refactor --log`.

  Use this to explain *why* the rewrite is correct/safe and what
  improvement it produces — e.g. "replaces O(n) length-in-guard with
  O(1) pattern matching", or "Map.new/1 avoids the implicit
  acc-merge semantics of Enum.into/2 with a non-empty map".

  Optional callback. Defaults to `description/0` when not implemented.
  """
  @callback explanation() :: String.t()

  @doc """
  Whether the rewritten source needs a second formatting pass.

  When `true`, the engine flips `reformat_triggered?: true` in its
  result. The Mix task layer responds by running `mix format` on the
  affected files — that pass picks up the project's `.formatter.exs`
  (`import_deps: [:phoenix]`, plugins, …), which is what we want.

  Note: this only normalizes formatting. It does **not** reconstruct
  pipe chains that `Sourceror.to_string/1` flattened into nested
  calls. If your replacement risks producing a flattened pipe, write
  the replacement as a single expression (no pipes) — pipe shape is a
  stylistic concern outside this plugin's scope.

  Optional callback. Defaults to `false`.
  """
  @callback reformat_after?() :: boolean()

  @doc """
  Pipeline ordering weight. Higher runs earlier.

  The engine sorts refactors by `{-priority, module_name}` — so a
  refactor that returns `200` runs before the default-`100` block,
  and within the same priority the order stays alphabetical for
  determinism. Use this for refactors that *produce* input another
  refactor relies on (e.g. `MultiAliasExpand` → `AliasOrder`) or for
  cleanup steps that must come after body-simplifying passes
  (e.g. `InlineSingleExpressionDef`, `UnusedVariable`).

  Can be overridden per refactor in `.refactor.exs` via
  `configured_modules: [{Mod, priority: 200}]` — the config value wins
  over the module default.

  Optional callback. Defaults to `100`.
  """
  @callback priority() :: integer()

  @doc """
  Compute a value once per engine run, then receive it back in every
  `transform/2` call as `opts[:prepared]`.

  Use this for project-wide context that's expensive to derive but
  identical across files — e.g. the set of all Ecto schema field names.
  The engine calls `prepare/1` exactly once per pipeline run, before
  any `transform/2`, and threads the result through every per-file
  invocation.

  Receives the per-module opts (whatever the user configured under
  `configured_modules`). Returns either `{:ok, term}` to inject the
  term into `opts[:prepared]`, or `:no_cache` to skip injection.

  Optional callback. Refactors that don't need any pre-computed state
  simply don't implement it.
  """
  @callback prepare(opts :: keyword()) :: {:ok, term()} | :no_cache

  @optional_callbacks reformat_after?: 0, explanation: 0, prepare: 1, priority: 0

  @doc """
  Marks the using module as a refactor and registers it for discovery.

  Registration relies on the `is_refactor` persistent attribute, which
  `Num42.Refactors.Engine` reads via `__info__(:attributes)` to
  enumerate refactors at runtime.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Num42.Refactors.Refactor

      import Num42.Refactors.AstHelpers

      Module.register_attribute(__MODULE__, :is_refactor, persist: true)
      @is_refactor true
    end
  end
end
