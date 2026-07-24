defmodule Number42.Refactors.Analysis do
  @moduledoc """
  Pure measurement over source, AST and tokens — the lowest layer of the
  refactor pipeline.

  Analysis produces facts and holds no opinions. It does not decide that
  something *should* change; it reports what is there. Detection consumes
  that output to locate candidate sites, Suggestion turns findings into
  named plans, and Transform applies them.

  Run on its own, this layer is a metrics report.

  ## Membership

  A module belongs under `Analysis` when all of the following hold:

  - **Deterministic** — same input, same output. No wall-clock, no
    randomness, no dependence on ambient process state.
  - **No network.** Reading a model bundled under `priv/` is allowed
    (it ships with the application and is part of the input); reaching
    for a remote service is not.
  - **Input is source, AST or tokens; output is data.** No patches, no
    file writes, no opinion about whether a rewrite is warranted.

  Convenience `from_paths/2`-style wrappers that read files off disk are
  acceptable *provided* the module also exposes a pure in-memory twin
  (`from_sources/2`), which is what the detectors and tests call.

  This layer is intentionally **behaviour-free**: these are libraries,
  not plugins. There is nothing to dispatch on, so nothing to declare.

  ## What lives here

  `Heex.*` holds the HEEx-specific analyses (tree, motif, fingerprint,
  scope, clone detection); the flat modules cover Elixir AST helpers,
  naming/vocabulary classification, graph community detection, and tree
  edit distance.
  """
end
