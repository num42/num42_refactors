# Configuration for `mix refactor` — applies to **this repo itself**.
#
# Bootstrap: the library is applied to its own source so every stylistic
# rule we ship to consumers also holds for our code. If you change a
# refactor and `mix refactor --check` turns red, that's the feature.
#
# Local usage:
#
#     mix refactor --dry-run        # show the diff, write nothing
#     mix refactor --check          # CI gate, exit ≠ 0 on drift
#     mix refactor                  # rewrite in place
#
# Path conventions:
#   * `lib/**`  — production code (including the Mix task and the
#                 refactors themselves).
#   * `test/**` — tests. `test/support/` is test infrastructure; it
#                 stays in scope so the RefactorCase is refactored too.
#   * `mix.exs` — not covered by the globs on purpose. The wildcard
#                 `**/*.{ex,exs}` would match it, but refactor-driven
#                 edits to `mix.exs` are almost always unintended.
#                 If you really want it: `mix refactor mix.exs`.

%{
  inputs: [
    "lib/**/*.ex",
    "test/**/*.{ex,exs}"
  ],

  # Refactors we do not run on our own repo. Rationale per entry.
  skipped_modules: [
    # Cross-file refactor that pulls project-wide clones into a new
    # shared module. In a refactor library with deliberately
    # similar-shaped AST walkers this produces phantom extractions
    # between two thematically related refactors. Try locally with
    # `mix refactor --only ExtractSharedModule --dry-run`.
    Number42.Refactors.Ex.ExtractSharedModule,

    # These build a project-wide symbol inventory and try to
    # parametrise or deduplicate similar function definitions. In
    # this codebase they produce noise: every refactor file has
    # near-identical `transform/2` and `apply_patches/2` heads that
    # look structurally cloned but are intentionally distinct per
    # refactor. Re-enable once the heuristics are robust enough.
    Number42.Refactors.Ex.ExtractParametricClone,
    Number42.Refactors.Ex.ExtractRenamedClone,
    Number42.Refactors.Ex.DelegateExactDuplicates
  ],

  # Per-refactor options. Keys are fully-qualified modules, values are
  # keyword lists with e.g. `priority:` or `skip_in_modules:`.
  configured_modules: [
    # `ExpandShortFormBindings` expands short variable names (`x`, `n`,
    # …) into longer forms. In the AST helper and refactor code we
    # use short names on purpose, because they are conventionalised
    # AST identifiers (`m` = meta, `op` = operator, `lhs`/`rhs` for
    # operands). `skip_in_modules` keeps the rewrite away from the
    # files where the convention is legitimate.
    {Number42.Refactors.Ex.ExpandShortFormBindings,
     skip_in_modules: [
       Number42.Refactors.AstHelpers,
       Number42.Refactors.AstDiff
     ]}
  ]

  # `heex:` is not set — the library has no CoreComponents of its own,
  # so `ExtractHeexExactClone` would be a no-op. Consumers need the
  # block (see README); we don't.
}
