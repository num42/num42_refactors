# Configuration

> **Status:** STUB — to be filled.

Reference for the `.refactor.exs` project-level configuration file.

## TODO outline

- [ ] **Why a separate config file** — not `config.exs` (no runtime), not
  `.formatter.exs` (we don't want to overload it). Plain `Code.eval_string/3`
  map at project root.
- [ ] **Full schema reference** — every recognized top-level key with type
  and default:
  - `inputs` (required)
  - `configured_modules`
  - `skipped_modules`
  - `heex.core_components_module`
- [ ] **Per-refactor options** — what `configured_modules` accepts. Common
  keys (`priority`, `skip_in_modules`) and refactor-specific keys.
- [ ] **Recipes** — copy-pasteable snippets for common setups:
  - Phoenix app
  - Library (no HEEx)
  - Monorepo / umbrella
  - Excluding generated files
  - Pinning priorities for stable diffs
- [ ] **Validation & error messages** — what the engine does when the config
  is malformed or missing a required key.
- [ ] **Reloading** — config is read once per `mix refactor` invocation; no
  watching.
