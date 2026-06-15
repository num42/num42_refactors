# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `ExtractCommonProlog` (#232): now fires on **near matches**, not just
  byte-identical prologs. When several contiguous functions share a prolog
  and exactly **one** clause carries a single extra binding at the prolog
  boundary (a getter the others don't need), that extra is pulled into the
  helper too. A **pure read** — a `param.field.field` chain
  (`socket.assigns.current_user`) or any `pure?/1`-true RHS — stays eager
  in the return tuple. A **side-effect-possible getter** (`Repo.get`, a
  local `get_user/1`) is wrapped in a **lazy thunk** (`fn -> … end`)
  returned in a `*_fun` slot: the needing clause forces it (`u = u_fun.()`),
  the others underscore the slot and never run it (laziness is a correctness
  requirement here — an eager pull would run the getter for clauses that
  don't need it). The near match qualifies only when the extra is safely
  deferrable (at the boundary, read solely in the bearer's tail, reading
  only params/shared-prolog bindings, exactly one bearer); otherwise the
  exact-match path runs unchanged. A dedicated `field_access_over_param?`
  predicate accepts the dotted field-access chain that `pure?/1` rejects
  (its root is a dot-call, not an `__aliases__`).
- LiftUntypedParamToStructPattern (#222 follow-up): close the delegation
  field-leak the first #222 fix missed. A private `defp` narrowed by
  field-superset is allowed, but the field origin now propagates through
  `:delegation` (tagged `:delegation_field`), so a PUBLIC `def` delegating
  the whole var into that helper — directly or through a chain of private
  hops — is no longer narrowed (`:public_field_delegation` decline). A bare
  map from an out-of-corpus caller of the public wrapper would otherwise be
  rejected by the injected `%Struct{}` head at runtime. Found dogfooding
  position-db (`build_attr_constraints_for_test` → `build_attr_constraints`).
- `PushParamIntoCallee`: added a `public: true` mode that also rewrites
  public `def` callees (previously `defp`-only). Dropping a public
  function's parameter is an arity change external callers can't see, so
  the rewrite keeps a backward-compat wrapper at the original arity that
  forwards to the new one (`def f(d, _cfg), do: f(d)`), placed after the
  last callee clause to keep clauses grouped. The wrapper discards the
  argument it used to forward and uses the pushed constant — external
  callers that passed a different value now get the corpus value (the
  documented trade of this mode). Skips a `def` when the lower arity is
  already taken, and the wrapper's `_` at the dropped position keeps the
  rewrite idempotent. `defp` behaviour and the default (`public: false`,
  every `def` skipped) are unchanged. (#83)
- LiftUntypedParamToStructPattern (#222): field-superset narrowing (a pure
  `.field`-reading body) now fires only on a **private `defp`**, whose
  caller set is fully in project. A **public `def`** is no longer narrowed
  on field-superset alone (`:public_field_only` decline) — an out-of-corpus
  caller could pass a bare map with the same fields that a `%Struct{}` head
  would reject at runtime. The decline still flows to the stronger sources
  (call sites, AST delegation, Dialyzer), which rescue a public def when
  they have real evidence of the struct; a `@spec` still binds. A declined
  public field-only lift is also kept out of the delegation receiver index
  so it can't leak its unproven type to delegating callers.
- ExtractRepeatedGuardToDefguard: now also lifts a body `if` whose
  condition is a **complex** guard expression (≥ 2 guard operators) into a
  named `defguardp` plus two guard-driven clauses
  (`def f(x) do if COND, do: A, else: B end` → `defguardp valid_x(x) when
  COND` + `def f(x) when valid_x(x), do: A` / `def f(x), do: B`). A
  one-operator condition is declined and left to `ExtractCondIfGuardClauses`
  (inline `when`), which has no naming value; runs at priority 70 so the
  named form wins on complex conditions before the inline lifter sees them.
  Truthiness is preserved (non-boolean conditions wrapped in
  `not in [nil, false]`) and unused params in the lifted clauses are
  underscored. The existing repeated-head-guard extraction is unchanged.

### Fixed

- `mix refactor --auto` (#237): files a refactor *generates* are now staged
  in the per-unit commit, so cross-file extraction converges. Refactors like
  `ExtractSharedModule` write a new `*.Shared` host in `prepare/1`; the
  auto-stager only knew about the per-unit input paths, so the generated file
  stayed untracked, got re-created from scratch every fixpoint pass, and the
  run never settled. `--auto` now snapshots the working tree
  (`git status --porcelain`) *before* each unit and stages the delta — the
  files this unit actually created/touched — alongside the input paths.
  Untracked files that already existed before the unit ran are excluded, so
  unrelated dirty files in the tree are left alone (no `git add -A`). Together
  with the #226 delegate-idempotence fix, the position-db fixpoint dogfood now
  converges instead of accumulating an untracked host every pass.
- `LiftUntypedParamToStructPattern` (#234): a field-superset narrowing of a
  private helper no longer leaks to a public `def` that forwards a whole,
  open param into it through delegation — including the one-line
  `def f(x), do: g(x)` shorthand form, not just the block form. A
  public-delegation poison set transitively marks every receiver position an
  open public param flows into; narrowing any poisoned position is declined,
  since an out-of-corpus caller can pass a bare map that flows unchanged into
  the narrowed head and crashes. Positions a public head statically proves to
  be a struct (`@spec`/`%Mod{}` pattern) are exempt. Closes a residual gap
  from the #222/#231 delegation work surfaced by the position-db dogfood
  (`build_attr_constraints_for_test/1` → `defp build_attr_constraints/1`).
- `DelegateExactDuplicates` (#226): made idempotent at the destination
  module. The refactor no longer re-inserts a `defdelegate name(args), to:
  T` when the module already carries an AST-identical delegation (same
  name/arity/target). Previously, a module holding both a leftover local
  `def` (e.g. re-generated by `ExtractSharedModule` each pass) and a prior
  identical `defdelegate` got a *second* identical delegation appended every
  pass — the fixpoint dogfood against position-db locked at +1 commit/pass
  with `support.ex` growing +3 lines each time. A second pass on the
  refactor's own output is now a no-op. (The cooperating
  `ExtractSharedModule` half — incomplete caller de-duplication and unstaged
  generated modules in `--auto` — is tracked separately in #237.)

### Added

- `CanonicalStatementOrder` (#233): reorders independent statements
  inside a `def`/`defp` body into a deterministic **canonical order** so
  two bodies that differ only in the ordering of order-independent
  statements collapse to the same normalized-AST fingerprint — making
  them detectable as clones by `DelegateExactDuplicates` (which hashes
  an order-sensitive statement list). Builds a def-use + side-effect
  dependency DAG per body (RAW/WAW/WAR hazards, rebinding chains,
  destructuring patterns) and emits a Kahn topological order whose
  tie-break is a three-stage total key: a variable-name-independent
  `:erlang.phash2` of the normalized statement, then the structural
  `Sourceror.to_string`, then the original index — so the output is
  unique and idempotent. Two not-provably-pure statements keep their
  relative source order (conservative side-effect ordering);
  control-flow forms (`case`/`cond`/`if`/`with`/`for`/…), pins (`^x`),
  and dynamic pattern keys are barriers that segment the body and stay
  fixed; the trailing return value is never sorted forward. Statements
  are sliced verbatim and reassembled as one Sourceror patch (no
  re-rendering, so string escapes/pipes survive). **Default-OFF**
  (`enabled: true` to opt in), `priority: 300` so it runs before the
  clone detectors, configurable `min_block_statements` (default 3).
- InlineDefdelegate (#225): the inverse of the move-method delegations —
  rewrites every in-corpus call site of a `defdelegate`'d function to call
  the delegated target directly (alias-aware: short form when the caller
  aliases the target, fully-qualified otherwise, never injecting an
  alias), supporting 1:1 and `as:`-rename forms. Removes the
  `defdelegate` only when its module is not a public API boundary (a
  conservative depth heuristic; contexts/facades are always kept) and no
  caller survives the rewrite. Skips multi-form keyword-list delegates,
  unresolvable targets, and any delegate that is dynamically dispatched
  (`apply/3` or `&name/arity` capture). **Default-OFF** (`enabled: true`
  to opt in) since it both rewrites across files and deletes definitions.
- `ExtractPrimitiveToStruct` (#118): detects a recurring primitive shape
  — the same bare tuple or bare map threaded through many function heads
  — and extracts it into a named struct, rewriting the heads and the
  provable construction sites. **Default-OFF** (`enabled: true` to opt
  in): a wrong positional mapping compiles-but-corrupts, the highest-risk
  class in the catalog. Detection: a tuple shape qualifies only when it
  appears in `>= K` heads (default `K = 3`) binding each position to a
  bare variable whose name-stem is **consistent across every occurrence**
  — `{lat, lng}` and `{lng, lat}` disagree and decline the whole shape
  (the anti-swap guard); the position→field map must also be injective.
  Maps match on an **exact key set** (`%{name, age}` ≠ `%{name, age,
  email}`; subset/superset is a follow-up slice). Naming: a small
  field-name dictionary (`lat`+`lng` → `Coord`, `x`+`y` → `Point`, …),
  falling back to `ExtractedStruct<N>` plus an inline rename reminder when
  it misses (documented weakness). False-positive guards: tagged tuples
  (`{:ok, _}`/`{:error, _}`), one-off transients (the `K` threshold),
  tuples flowing into stdlib tuple consumers (`List.keyfind`, `:ets`,
  `Keyword`, `Tuple`), and shapes already backed by a `defstruct`.
  Construction sites are rewritten only by **provable dataflow** — a
  literal tuple at a call position whose head this pass struct-typed —
  never by arity-guessing. Every ambiguous case declines and is recorded
  for `--log` review.
- `SplitLowCohesionModule`: splits a low-cohesion "god module" into
  focused submodules along the seams of its internal call-graph. The
  hard part is **detection**, not the rewrite. Builds the module-local
  undirected call-graph (`AstHelpers.collect_definitions/1`) and runs
  greedy modularity-maximising community detection
  (`Number42.Refactors.CommunityDetection`, Clauset-Newman-Moore) — plain
  connected components is too blunt because one shared helper bridges
  every island into a single blob. The split is gated by three
  configurable, justified thresholds: `:min_modularity` (default `0.3`,
  Newman's textbook "no significant community structure" floor — below it
  the refactor **declines** rather than impose an arbitrary cut),
  `:max_cut_ratio` (default `0.25`, the direct "islands barely call
  across" signal), and `:min_cluster_size` (default `2`); plus a
  `:min_module_functions` floor (default `6`). Hard false-positive guards,
  each of which declines the whole module: a `@attr`/`%__MODULE__{}`
  referenced across clusters (splitting would orphan shared state),
  `@behaviour`/`@impl` (callbacks must stay on the module), `use X`
  (may inject functions invisible to the source call-graph), and dynamic
  `apply/3` (incomplete graph + unrewritable call sites). The cluster
  with the most public functions stays in the home module; others move to
  `Original.<DominantFunction>` submodules with `defdelegate` shims left
  behind and cross-file call sites rewritten. Every considered-but-
  declined module is recorded with its reason and surfaced by `report/1`
  for `--dry-run` review. **Default-OFF** (the most destructive refactor
  in the catalogue) — both `prepare/1` and `transform/2` are no-ops unless
  `enabled: true`.
- `SplitFlagArgument`: splits a function gated by a boolean (or
  small-enum) flag parameter into one intent-named function per flag
  value (Fowler "Remove Flag Argument"), and rewrites the literal and
  default-implied call sites across files. **Default-off** — a
  structural refactor that rewrites call sites is never auto-on;
  `transform/2` is a no-op unless its opts carry `enabled: true`.
  Detection is strict: the flag parameter must be a single-clause
  function's **last** plain-variable argument, used **solely** as the
  discriminant of exactly one top-level `if`/`case` on that parameter
  (never woven into a branch body, passed onward, or stored), and the
  branch must be exhaustive/exclusive on the flag domain (bool
  `true`/`false`, or 2..4 distinct atoms with no catch-all arm).
  Call-site policy is the **dispatcher-shim** (option (b) from the
  issue): literal sites (`render(x, true)`) rewrite to the named split
  (`render_shrink(x)`), default-implied sites (`render(x)` under a
  default) route to the default-branch split, and **dynamic**
  (`render(x, runtime_bool)`) or **unfindable** (`apply/3`, `&render/2`
  captures) callers keep the original as a thin dispatcher delegating to
  the splits — a deliberate partial win, never a half-rewritten call
  graph. When every caller is literal/default and no capture/apply names
  the function, the dispatcher is dropped. Enum atoms name the split by
  value (`emit_json`); bool splits name from the branch body's called
  helper (`shrink` → `render_shrink`). Skips when the flag is woven into
  the computation, the branch is non-exhaustive, the function is
  multi-clause, the flag isn't the last parameter, a derived name
  collides with an existing definition, or the branch bodies already
  bare-delegate to `name_*`-shaped siblings (the dispatcher shape it
  emits — refused to keep the rewrite idempotent).
- `ReduceToNamedAggregate`: classifies a multi-line `Enum.reduce/3`
  whose accumulator follows a known aggregation shape and rewrites it to
  the named idiom. `Map.update(acc, key, [v], &[v | &1])` with seed `%{}`
  → `Enum.group_by/2` (or `/3` when the grouped value differs from the
  element); `Map.update(acc, key, 1, &(&1 + 1))` with seed `%{}` →
  `Enum.frequencies_by/2`; `acc * value` with seed `1` →
  `Enum.product_by/2`. Both capture (`&[v | &1]`, `&(&1 + 1)`) and
  explicit (`fn e -> [v | e] end`, `fn c -> c + 1 end`) fold funs are
  recognised. The `+`/`0` **sum** case is left to `EnumReduceToSum` and
  the single-line `Map.put` map-build to `ReduceMapPut` — this only adds
  the idioms those two don't cover. Documented divergence: the
  `group_by` source prepends (reverse within-bucket order) while
  `Enum.group_by/3` appends (input order); keys and per-bucket membership
  are identical, only within-bucket order flips, so it rewrites and
  relies on the mandatory manual review for the rare order-sensitive
  case. Skips when the body is more than the recognised expression (extra
  statements, multiple acc updates), the seed mismatches the idiom
  (non-`%{}`, non-`1`), the key/value projection doesn't reference the
  element, or the group_by seed-elem and cons-elem differ.
- `HoistInvariantOutOfComprehension` now covers **multiple generators**
  and **nested** comprehensions. A flat multi-generator `for` is one
  scope: a subexpression invariant w.r.t. *every* generator and filter
  binding lifts before the whole `for` (a subexpression that depends on
  an earlier generator but not a later one is left in place — a flat
  `for` has no statement position between generators to host the binding
  without restructuring the loop). For nested `for`/`Enum.map`, each
  comprehension lifts only what is invariant in its own body to just
  before itself, so a partially-invariant subexpression lands at the
  tightest legal level. The invariance check is now **scope-aware**:
  it excludes variables introduced by any nested scope inside the body
  (an inner `for`, a `fn`, a `with`, a `case`/`cond`/`receive`/`try`
  clause), fixing a latent bug where such a subexpression was hoisted
  past its binder into non-compiling code. Still gated on `pure?/1`
  (pure + total, empty-collection-safe); one hoist per pass; idempotent.
- `CondToCase`: a `cond` whose every non-default arm is `var == literal`
  (or the symmetric `literal == var`) over the **same** bare variable →
  a `case` on that variable, one `literal -> body` clause per arm, with a
  trailing `true ->` mapped to `_ ->`. Arm bodies are kept verbatim. A
  `cond` with no `true ->` arm is still rewritten — `CondClauseError` and
  `CaseClauseError` are equivalent "no match" behaviour. Right-hand sides
  are limited to scalar literals (atom, number, binary, `nil`, boolean)
  that are valid `case` patterns as-is. Skips when arms test different
  variables, any arm is relational (`x > 5`), the RHS is a non-literal
  (another variable, a call, `@attr`, `Mod.const`, `^pin`), the RHS is a
  composite literal (tuple/list/map — could embed a bare variable that
  would become a binding pattern), any test is a function call
  (evaluation-order/short-circuit hazard), a literal repeats across arms
  (`case` clause shadowing), or a `true ->` arm is not the final clause.
  The multi-clause-`def` target (#38) is produced downstream by
  `CaseToFunctionClauses`; this is the upstream `cond -> case` half.
- `ExtractRepeatedGuardToDefguard`: a single-variable `when`-guard
  repeated across `>= 3` (`:min_occurrences`, default `3`) clause heads
  in one module → a `defguardp <is_valid_var>(<var>) when <expr>`
  inserted at the first top-level expression (after aliases, before its
  first use), with each head rewritten to `when is_valid_var(var)`.
  Guards are compared **structurally modulo the single guarded var
  name**, so `is_integer(id) and id > 0` and `is_integer(n) and n > 0`
  group together. Sound by construction — a guard that compiled in a
  `when` is guard-legal, exactly what `defguardp` accepts. Skips when
  below threshold, when the guard references more than one parameter (v1
  is single-var only), when the guarded variable is not a bare parameter,
  or when the head already calls a guard defined in the module
  (idempotence).
- `ExtractCondIfGuardClauses`: lift a `def`/`defp` whose entire body is a
  two-branch `if`/`else` with a guard-expressible condition into two
  `when`-guarded clauses (`def f(n) when n < 0, do: :neg` /
  `def f(n), do: :pos`). The two-branch sibling of
  `ExtractCondToGuardClauses` (it reuses the same guard-safety predicate)
  and a strict, no-pattern-synthesis subset of `IfLiftToClauses` — for
  cases where the condition is a plain guard over the parameters and no
  head-pattern destructuring applies. Skips non-guard-safe conditions,
  conditions over non-parameter bindings, `if` without `else`, an `if`
  embedded in a larger body, heads with a non-bare param or an existing
  `when`-guard, and `defmacro`. Parameters used in neither a clause's
  guard nor its body are underscored so the output compiles cleanly.
- `LambdaDestructureToHead`: a single-bare-param lambda whose first body
  statement destructures that param (`fn pair -> {k, v} = pair; rest end`)
  lifts the pattern into the head (`fn {k, v} -> rest end`); a `for`
  generator with the same shape (`for pair <- coll do {k, v} = pair; … end`)
  moves the pattern onto the `<-`. Fires only when the param is destructured
  by a real pattern (not a bare rename) and is **not used again as a whole**
  afterwards — otherwise the bound whole-value reference would be lost, so it
  skips. Also skips multi-clause/guarded lambdas, non-first-statement
  destructures, a pattern that re-binds the param's own name, and a `for`
  whose param is shared by another clause.
- `ExtractPipelineToFunction`: a long inline `|>` pipeline (default `>= 5`
  stages), bound to a single variable or returned as the body's tail, is
  lifted into a named private helper. The chain's free variables — every
  bare variable referenced inside it but not bound within it (lambda args,
  comprehension generators), restricted to names in scope at the extraction
  site — become the helper's parameters, with the head-seed variable first
  and the rest in source order; the call site passes each by name. The
  helper name is derived from the terminal call, never a placeholder
  (`Repo.all` → `load_<seed>`, `Enum.map` → `map_<seed>`), with a host-derived
  `<fn>_pipeline` fallback (bang-safe). Skips pipelines below the threshold,
  dead bound results, a host body that is *only* the pipeline (would extract
  to a self-call), multi-clause hosts, module-attribute references, and
  chains with no in-scope seed. Default-OFF — opt in with
  `{Number42.Refactors.Ex.ExtractPipelineToFunction, enabled: true}`.
- `ExtractCommonProlog`: a setup prolog shared by several functions —
  their identical leading statements — is lifted into one private helper
  that returns the bindings still read afterwards (liveness-analysed) as
  a tuple; each call site destructures it (`{socket, current_user} =
  prepare_handle_event(socket)`). Free vars the prolog reads but doesn't
  bind become helper params; the statements move verbatim, in order, so
  side-effect ordering is preserved. A single live binding is returned
  bare (no tuple); every call site destructures the **same** shape even
  when one reads only part of it (monomorphic helper). Skips when the
  prolog is shorter than `:min_prolog_statements` (default `2`), appears
  in fewer than `:min_functions` (default `2`) contiguous defs, diverges
  in a literal (a parametric clone), contains control flow, has no live
  binding (pure side-effect run), is the function's whole body (full-body
  clone), or needs an input that isn't a bare parameter everywhere. The
  cross-function counterpart to `DedupeClausePrologue` (shared prolog
  across the *clauses* of one function).
- `CollapseRichCaseToWithElse`: collapses a nested `case` pyramid whose
  error arms do real work (transform, log, re-tag — not just propagate
  `{:error, e}`) into a `with` chain plus an `else` block. The rich-arm
  counterpart to `CollapseNestedCaseToWith`, which only fires when every
  error arm is a trivial pass-through and the `with` needs no `else`.
  Each level's single success arm (`{:ok, _}` / `:ok`) becomes a `<-`
  clause; every non-success arm from every level is collected, outer
  level first, into one flat `else` block. Refuses to fire when an error
  arm references a variable bound by an earlier success arm (the binding
  is out of scope in `else` → uncompilable), when two levels share an
  error pattern (the flat `else` would mis-route one of them →
  behaviour change), when a level has more than one success-shaped arm
  (ambiguous spine), or when every arm is a trivial pass-through (that's
  `CollapseNestedCaseToWith`'s job).
- `ManualTapToTap`: a hand-rolled "run a side effect, return the
  original value" lambda in a pipe → `Kernel.tap/2`. Matches
  `value |> then(fn x -> eff; x end)` and the immediately-applied
  `value |> (fn x -> eff; x end).()`, where the lambda is single-clause,
  single-bare-param, and its block body ends in exactly the bound param
  after at least one side effect. The trailing `; x` is dropped on emit
  (`tap` ignores the return). Skips when the body returns a derived
  value, is identity-only, has a multi/destructuring param, or **rebinds
  the param before the final `x`** (the returned value would no longer
  be the original).
- `DropTrailingReturnBinding` — drops a trailing binding that exists only
  to be returned. When a block's last statement is a bare variable `v`
  and the statement immediately before it is `v = rhs` (bare-variable
  LHS), the binding is removed and `rhs` becomes the block's final
  expression. Unlike `InlineSingleUseBinding` (#37), there is no use site
  the RHS moves to — it stays in the exact same tail position — so no
  purity check is needed and a side-effecting or possibly-raising RHS
  (`Repo.insert!(...)`, `do_thing!()`) still de-binds safely. Skips
  pattern-match LHS (`{:ok, v} = …; v` — the match carries semantics), a
  binding read earlier in the block, and a binding whose variable appears
  in its own RHS. Applies to any block tail: `def`/`defp`/`fn` bodies and
  `case`/`with`/`if` arm bodies. One shim per pass for determinism;
  idempotent.
- `FilterFirstToFind` fuses `Enum.filter(coll, pred) |> List.first()` and
  the `|> Enum.at(0)` variant (plus the call-nested
  `List.first(Enum.filter(...))` / `Enum.at(Enum.filter(...), 0)` forms)
  into `Enum.find(coll, pred)`. `filter |> first` runs the predicate over
  every element and builds the whole match list just to keep its head;
  `Enum.find/2` stops at the first match for the same result. Only the
  provably-safe set rewrites: downstream must be exactly `List.first/1` or
  `Enum.at(_, 0)` — never `Enum.at(_, n != 0)` or `hd/1` (which raises on
  `[]`). The 2-arg `List.first(list, default)` is skipped (it returns
  `default` on no match where `Enum.find/2` returns `nil`, and the arg
  order differs from `Enum.find/3`). A predicate that performs IO, sends a
  message, or raises is skipped, since early-stop changes how often its
  effect fires.
- `ClauseLookupToMap` — collapses N (>= 3) clauses of one arity-1
  function, each mapping a single literal head (atom / int / string /
  bool) to a single constant body, into a `@<plural_name>` lookup-map
  attribute plus one passthrough clause (`name(key), do: @attr[key]`).
  Clause order is preserved and duplicate heads keep the first entry. A
  trailing catch-all clause (`name(_), do: default`) becomes the
  `Map.get(@attr, key, default)` default. Guards on any clause,
  non-literal heads, multi-arg heads, and non-constant bodies leave the
  group untouched.
- `RangeLiteralToRangeNew` — opinionated, **DEFAULT-OFF** style-inversion
  that rewrites range literals to explicit calls: `a..b` → `Range.new(a, b)`
  and `a..b//step` → `Range.new(a, b, step)`. It runs against the library's
  usual `verbose -> idiomatic-short` direction and the common Elixir style
  guide (which prefers the `..` literal), so it only fires with
  `enabled: true` — the in-module gate is the default-off convention, no
  `skipped_modules` entry needed. Exists for cases where the call form is
  clearer: named step argument (vs the easy-to-misread `a..b//step`) and
  dynamic bounds. Skips full-slice `..` (no operands) and ranges in guards
  and patterns (`x in 1..10`, `case n do 1..10 -> … end`, `1..10 = r`)
  where `Range.new` is illegal syntax. Idempotent.
- `LiftUntypedParamToStructPattern`'s call-site source now reads
  **transitive struct returns**. A project function whose every clause
  provably returns a single in-project struct — through Ecto's get-family
  (`Repo.get!(Schema, _)`, `Repo.get_by`, `Repo.one`, `Repo.reload`, and
  the pipe form `Schema |> Repo.get!(id)`) or a bare `%Struct{}` literal as
  the last expression — is recorded as a getter. A variable bound to such a
  getter's result (`item = Catalog.get_item!(id)`) is then known to be that
  struct, so passing it bare (`f(item)`) types `f`'s parameter — the same
  data-flow lift the binding tracker already does for struct literals,
  extended one hop through the getter. `Repo.all` (returns a list) and
  getters whose clauses disagree on the struct are deliberately excluded;
  only an unconditional single-struct return qualifies. Zero-arity defs
  (`def blank, do: %Item{}`, and `def go do … end` callers) are now
  collected as clauses so they participate as getters and as binding
  sources. On position-db this added 0 lifts — every getter result there
  flows into context functions that already pattern-match the struct — but
  it is a clean general source that fires on codebases where getter results
  reach untyped helpers.
- `LiftUntypedParamToStructPattern`'s call-site source now tracks
  **variable bindings**, not just struct literals at the call. A var
  bound to a struct in the caller's head (`%Brand{} = b`) or body
  (`b = %Brand{…}`) and then passed bare (`f(b)`) is recognised as a
  struct call site. Bindings are scoped per clause. On position-db this
  added 2 lifts (`ItemImport.persist`/`valid_unique_rows` off a
  `workbook = %Workbook{…}` body binding), bringing the running total to
  16 (from the 3-lift spec+fields baseline).
- `LiftUntypedParamToStructPattern` gains an **AST delegation** source and
  a **fixpoint loop**. A param the body proves nothing about but passes
  whole into a call (`f(arg), do: Shared.g(arg)`) borrows its type from the
  receiver's head when `g/1` pattern-matches a struct at that position in
  every clause — pure source, no PLT. Resolution then iterates to a
  fixpoint: each round's lifts type their own heads, which become new
  delegation receivers, so type info propagates up multi-hop chains
  (`h → f → g`, leaf-typed `g` lifts `f` then `h`). The loop terminates
  (monotone, bounded receiver index; round cap as a guard). On a real
  Phoenix app this is the largest pure-AST lever — most params flow through
  context functions rather than being read field-by-field; combined with
  the existing sources the lift count rose 10 → 14 (3 → 14 vs. the original
  spec+fields-only baseline), every new lift compiling under
  `--warnings-as-errors`.
- `LiftUntypedParamToStructPattern` now infers struct types from **two
  more sources** beyond `@spec` + field-superset, strongest first:
  **call sites** (a project-wide AST scan — a struct literal passed at a
  call, `f(%Brand{})`, types the parameter by real data flow; overrides a
  weaker field guess, declines on conflict, rescues a body that proved
  nothing) and **Dialyzer success typing** (the project PLT is read
  directly via `:dialyzer_cplt`/`:dialyzer_plt` — the only source that
  sees through delegation, e.g. `f(arg), do: Shared.g(arg)` where `g/1`
  matches `%Scope{}` back-propagates `arg :: %Scope{}`; opt out with
  `dialyzer: false`, point at a PLT with `plt_path:`). Visible code always
  wins over Dialyzer; the builder/projection decline is preserved by both.
  When call sites pass **several** distinct structs, the single clause is
  **duplicated** into one struct-typed head per target — but only when the
  function has one clause and every field the body reads exists in every
  target struct (else `:polymorphic_unsafe`). Calibrated against a real
  Phoenix app: doubled the lift count (3 → 6), every new lift correct and
  compiling under `--warnings-as-errors`.
- `EnumIntoToMapSet`: rewrites `Enum.into(coll, MapSet.new())` to
  `MapSet.new(coll)` (pipe form `coll |> Enum.into(MapSet.new())` →
  `coll |> MapSet.new()`). Sibling of `EnumIntoToMapNew` for `MapSet`.
  Fires only on the zero-arg `MapSet.new()` accumulator — a seeded
  `MapSet.new(seed)` merges into an existing set and is left untouched.
- `ListWrapConditional`: rewrites `if is_list(x), do: x, else: [x]` to
  `List.wrap(x)`. Fires only on the exact shape — `is_list/1` guard on a
  bare variable, `do` branch the same variable, `else` branch the
  singleton `[x]`; both the inline (`if c, do: …, else: …`) and block
  (`if c do … else … end`) forms are accepted. **Default-off** (listed
  in this repo's `.refactor.exs` `skipped_modules`): `List.wrap(nil)` is
  `[]`, while the conditional yields `[nil]` for `x == nil`, and the
  conditional alone can't prove `x` is non-nil — so the rewrite is only
  behaviour-preserving when `nil` is ruled out at the call sites. Enable
  per project by removing it from `skipped_modules` once that holds.
- `LiftUntypedParamToStructPattern`: lifts a bare untyped parameter to a
  struct-pattern match (`def f(r)` → `def f(%Position{} = r)`) when the
  body **proves** the type. Inference, strongest first: an existing
  `@spec` naming the arg type wins; otherwise the `var.field` accesses
  must be a superset of exactly one project `defstruct` (scanned from
  source AST, cross-file) and no other. Declines (leaves the head alone)
  on any ambiguity — two structs fit, none fit (the value is a map, e.g.
  a `select`-projection with join/compute fields no struct carries),
  fewer than `:min_fields` (default 2) **distinctive** accesses (generic
  fields like `id`/`name`/`type` still match but don't count toward the
  threshold — reading only `var.type`/`var.name` proves nothing), the
  param is passed whole into another call (fields we can't see), the body
  is a **builder** (`X_to_Y(arg)` constructing `%Y{… arg.field …}` —
  `arg` is the source projection, not `%Y{}`), or clauses would infer
  divergent structs. Field counting excludes zero-arg calls (`var.fun()`)
  so a module isn't mistaken for a struct. **Default on** — calibrated
  against a real Phoenix app (every surviving lift correct, the library's
  own source yields zero); a wrong lift inserts a runtime-breaking
  pattern, so the layered decline guards are the core of the design.
  Review the dry-run on an unfamiliar codebase or opt out via
  `skipped_modules`.
- `ExtractBehaviourFromAdapterFamily`: detects module families with a
  shared public API via BEAM introspection (`__info__(:functions)` +
  implemented behaviours), scores candidate pairs (sibling/same-depth
  namespace bonus), synthesizes a behaviour module with spec-derived
  callbacks, and inserts `@behaviour`/`@impl true` into the members.
  The surface counts genuine `def`s only — `defdelegate`s (unrewritten
  call sites) and `use`-injected functions (`child_spec/1`, `start_link`
  from `GenServer`/`Supervisor`/`Ecto.Repo`, …) are intersected out.
  Optional `:require_dispatch` keeps only families with a polymorphic
  call site (`var.fun(..)`/`apply(var, :fun, ..)`, framework receivers
  like `repo`/`conn` ignored); when on, families seed from the smallest
  dispatched core and majority-shared functions become
  `@optional_callbacks`. **Default off** (opt in via `.refactor.exs`):
  shape-based matching tends to surface coincidences over genuine
  abstractions. See num42/num42_refactors#158 for the protocol sibling.
- `ExtractProtocolFromStructFamily`: the data-polymorphism sibling of
  the behaviour refactor. Detects functions defined over several
  **distinct** struct types at the dispatch arg (`def label(%Brand{})`
  / `def label(%Item{})` / …, deduped to distinct types, `:min_structs`
  floor of 3), and rewrites a single-module family into a real
  `defprotocol` + one `defimpl` per struct in a new `-able`-named file
  (`label` → `Catalog.Labelable`), migrating each clause and its
  `@spec` (lifted to the protocol with the dispatch type as `t()`).
  Static call sites shift to the protocol only when the name moves
  (`Catalog.Labeling.label(x)` → `Catalog.Labelable.label(x)`);
  otherwise dispatch is transparent. A second **name-family** axis
  reports near-misses where dispatch is hand-rolled through the
  function name instead (`*_to_result`, `subscribe_*`) as hints, gated
  by body-convergence + specific-operation + subsumption filters — a
  pointer, never a rewrite (the values are often maps, not structs).
  Cross-module families are reported but not rewritten. **Default off**
  (opt in via `.refactor.exs`): idiomatic Elixir rarely hand-rolls
  struct-type dispatch, so the honest first result is often "none".
- `SortReverseToDesc`: `Enum.sort(coll) |> Enum.reverse()` →
  `Enum.sort(coll, :desc)` and the `sort_by` analogue (both call and
  pipe forms). Skips a sort that already carries a sorter/direction arg
  (arity-based gate, e.g. `Enum.sort(coll, &>=/2)` / `:asc`) and any
  `Enum.reverse/2`. **Default off** (opt in via `.refactor.exs` with
  `enabled: true`): `Enum.sort/1` is stable so `sort |> reverse` flips
  tie order while `sort(:desc)` preserves it — not strictly
  behaviour-preserving when duplicate sort keys exist (accepted
  best-effort trade-off for the dominant no-relevant-ties case).
- `MemberToInOperator`: `Enum.member?(coll, x)` → `x in coll`, negated
  calls fold to `not in`; guard context gated on literal collections.
- `MapSumToSumBy`: `Enum.map(coll, fun) |> Enum.sum()` →
  `Enum.sum_by(coll, fun)` (Elixir 1.18+).
- `EnumFindToKeyfind`: `Enum.find(list, fn {k, _} -> k == key end)` →
  `List.keyfind(list, key, 0)`, incl. the `elem(t, n) ==` form.
- `FilterCountToCount`: `Enum.filter(coll, pred) |> Enum.count()` →
  `Enum.count(coll, pred)` (pipe, half-pipe and nested-call forms);
  lambda/capture predicates only, leaves `Enum.count/2` alone.
- `RangeToListRedundant`: drops a redundant `Enum.to_list/1` on a range
  that feeds directly into another `Enum.*`/`Stream.*` call —
  `Enum.to_list(1..n) |> Enum.map(fun)` → `1..n |> Enum.map(fun)`,
  `Enum.map(Enum.to_list(a..b), fun)` → `Enum.map(a..b, fun)`. Fires
  only when the `to_list` argument is a syntactic range (`a..b`,
  `a..b//s`, `Range.new(...)`) and the consumer is a direct Enum/Stream
  call (pipe or nested); skips bound results, unknown consumers, and
  non-range arguments.
- `MergePipelineIntoComprehension` now also fuses
  `Enum.reject |> Enum.map` (`for x <- coll, !pred(x), do: f(x)`).
- Initial public release, extracted from an internal project.
- ~60 AST refactors covering Enum/Map/Stream idioms, pattern-matching
  rewrites, pipe and `with` reshaping, definition hygiene, cross-file
  extraction, and HEEx clone consolidation.
- `mix refactor` task with `--check` (CI), `--log` (per-refactor
  rationale + diff), `--auto` (commit per refactor), `--step-by-step`,
  and `--dry-run` modes.
- `Number42.Refactors.Refactor` behaviour for authoring custom refactors.
- `.refactor.exs` project-level configuration.

### Changed

- `SinkBindingIntoBranches` now also sinks into `cond` arms. A pure,
  bare-variable binding read in **exactly one** arm body of the
  immediately following `cond` is sunk into that arm; arms that don't
  read it stay untouched. The cycle guard extends to `cond`: if **any**
  arm condition reads the binding it can't be sunk (every condition is
  evaluated top-down before the matching arm runs, so the value must
  stay live before the block). The existing purity, single-branch
  liveness, and read-after gates carry over unchanged, so the
  strictness shift stays unobservable. `case`/`if` behaviour is
  unaffected.
- `LiftCommonTailFromBranches` now also lifts the common tail out of
  `cond` blocks, not just `case`/`if`. When every arm of a `cond` ends in
  the same trailing statement(s), that run is pulled out to a single
  execution after the block. The existing preconditions carry over: the
  longest AST-identical trailing run is lifted (each arm keeps at least
  one statement before it), the tail may not read any arm-local binding,
  and the `cond` must sit in statement position (its value not consumed by
  `=`, `|>`, or a call argument). A `cond` is treated as exhaustive only
  when its final arm is a literal `true ->` catch-all — the same
  implicit-branch SKIP rule that guards a non-exhaustive `case` and an
  `else`-less `if`; a `cond` without it raises when no arm matches and so
  carries an implicit branch that would not run the tail.
- `HoistHardcodedConfig` now hoists config-shaped strings out of
  `cond`/`case` branch *bodies*: a URL/path literal appearing in the
  bodies of multiple branches collapses to one shared `@module_attribute`
  with every branch use-site rewritten; one in a single branch still
  hoists on its own. The clause *head* (the `->` left-hand side, also for
  `with`/`fn`/`for`) is a pattern/guard position, so a literal there is
  left inline — a `@attribute` cannot stand in a match. Same shape
  predicates and idempotence guarantee as before.
- `RepeatedPatternToMacro` now also collapses **single-parameter**
  functions, not only zero-arity ones. A group of `def name(var), do:
  ...` clauses that share one literal-stripped skeleton, agree on the
  bare-var param name, and whose only free variable is that param is
  lifted into a `for {fun, arg1, ...} <- [...] do def unquote(fun)(var),
  do: ... end` block with the param threaded through verbatim (only the
  varying literals become `unquote` holes — the param is reproduced as a
  normal head var, so its body reads stay in scope; no `var!`/hygiene
  escape needed). Multi-param heads, non-bare-var/pattern params, mixed
  param names across the group, and bodies reading any free variable
  beyond the param are still rejected. Remains default-off and
  threshold-gated.
- `PipelineFromRebindChain` now also folds chains whose **head seed** is
  a nested function call. `x = f(g(h(input))); x = step(x)` previously
  treated the seed as atomic and skipped; it now unwraps the
  leading-argument spine into pipe stages —
  `h(input) |> g() |> f() |> step()`. The recursion stops at the
  innermost call (`h(input)`), which is rendered whole as the seed, and
  sibling arguments stay on their own stage so left-to-right evaluation
  order is preserved. Single-call seeds (`x = f(g(input))`) keep their
  existing `g(input) |> f()` shape. No new liveness invariants.
- `RelocateMisplacedFunction`: the feature-envy threshold `min_envy_refs`
  (how many references to a single other module a body must make before
  it counts as misplaced) is now configurable via `min_envy_refs:` in the
  refactor's opts. Defaults to `2` — unchanged behaviour when unset.
  Raise it for fewer, more confident moves; lower it to `1` to catch thin
  forwarders. Non-positive or non-integer values fall back to the
  default (#84).
