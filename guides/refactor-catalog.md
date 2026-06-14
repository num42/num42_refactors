# Refactor Catalog

Curated index of every bundled refactor, grouped by area. Each entry
links to the module documentation, which carries the full rationale,
edge cases, and idempotence notes.

Use this page as the **shop window**: skim the descriptions and click
through for the one-pager on any refactor that catches your eye.

> All refactors live under `Number42.Refactors.Ex.*` (or `Heex.*` for
> HEEx internals). The full module name is shown next to each entry.

## Style & Ordering

Refactors that normalise the *layout* of a module without changing
which functions exist.

### `Number42.Refactors.Ex.AliasOrder`

> Sort contiguous alias groups alphabetically.

### `Number42.Refactors.Ex.AliasUsage`

> Alias multi-segment module references at the top of the module.

### `Number42.Refactors.Ex.ImportAfterAlias`

> Move module-top `import` statements after the `alias` block.

### `Number42.Refactors.Ex.LiftDirectives`

> Lift function-local `alias` / `import` / `require` directives to the
> module level.

### `Number42.Refactors.Ex.MergeAssignKeywords`

> Merge consecutive `x = x |> assign(:k, v)` statements.

### `Number42.Refactors.Ex.MultiAliasExpand`

> Expand `alias Foo.{A, B}` into one alias per module.

### `Number42.Refactors.Ex.RemoveBlankBetweenAttrAndDef`

> Strip blank lines between function-attached attributes and their
> `def`.

### `Number42.Refactors.Ex.SortFunctions`

> Sort `def` / `defp` groups alphabetically.

### `Number42.Refactors.Ex.SortKeywords`

> Sort keyword-list contents alphabetically.

## Enum / Map / Stream

Idiom rewrites that replace verbose compositions with the named
function that already does the same thing.

### `Number42.Refactors.Ex.EnumCapture`

> Convert single-call lambdas in Enum/Stream HOFs to `&`-capture form.

### `Number42.Refactors.Ex.EnumFindToKeyfind`

> `Enum.find(list, fn {k, _} -> k == key end)` →
> `List.keyfind(list, key, 0)`.

### `Number42.Refactors.Ex.EnumIntoToMapNew`

> `Enum.into(coll, %{})` → `Map.new(coll)`.

### `Number42.Refactors.Ex.EnumMapIntoToMapNew`

> `Enum.map(coll, fun) |> Enum.into(%{})` → `Map.new(coll, fun)`.

### `Number42.Refactors.Ex.EnumReduceToSum`

> `Enum.reduce/3` summing lambdas → `Enum.sum/1` or `Enum.sum_by/2`.

### `Number42.Refactors.Ex.EnumReverseConcat`

> `Enum.reverse(a) ++ b` → `Enum.reverse(a, b)`.

### `Number42.Refactors.Ex.FilterCountToCount`

> `Enum.filter(coll, pred) |> Enum.count()` → `Enum.count(coll, pred)`.

### `Number42.Refactors.Ex.FlatMapToFilter`

> `Enum.flat_map(coll, fn x -> if c, do: [x], else: [] end)` →
> `Enum.filter(coll, &c/1)`.

### `Number42.Refactors.Ex.MapNewLambdaToForComprehension`

> `Map.new(coll, fn x -> {k, v} end)` →
> `for x <- coll, do: {k, v} |> Map.new()`.

### `Number42.Refactors.Ex.MapNewToPipe`

> `Map.new(coll)` → `coll |> Map.new()`.

### `Number42.Refactors.Ex.MapSumToSumBy`

> `Enum.map(coll, fun) |> Enum.sum()` → `Enum.sum_by(coll, fun)`.

### `Number42.Refactors.Ex.MemberToInOperator`

> `Enum.member?(coll, x)` → `x in coll` (negated calls → `not in`).

### `Number42.Refactors.Ex.MergePipelineIntoComprehension`

> `coll |> Enum.filter/reject(pred) |> Enum.map(f)` →
> `for x <- coll, [!]pred(x), do: f(x)` (pure bodies only).

### `Number42.Refactors.Ex.ReduceAsMap`

> `Enum.reduce/3` building a list → `Enum.map/2`.

### `Number42.Refactors.Ex.ReduceMapPut`

> `Enum.reduce/3` building a map via `Map.put` → `Map.new/2`.

### `Number42.Refactors.Ex.RejectIsNil`

> Manual nil-filtering lambdas → `Enum.reject(&is_nil/1)`.

### `Number42.Refactors.Ex.UseMapJoin`

> `Enum.map(coll, fun) |> Enum.join(sep)` →
> `Enum.map_join(coll, sep, fun)`.

## Pattern Matching & Control Flow

Refactors that reshape branches toward pattern matching and away from
nested conditionals.

### `Number42.Refactors.Ex.CaseTrueFalse`

> Rewrite `case ... do true -> ...; false -> ... end` as `if`/`else`.

### `Number42.Refactors.Ex.CollapseNestedCaseToWith`

> Collapse nested `{:ok, _}` / `{:error, _}` cases into a `with` chain.

### `Number42.Refactors.Ex.IfLiftToClauses`

> Lift `def f(p) do if ... else ... end end` to pattern-matched
> clauses.

### `Number42.Refactors.Ex.RedundantBooleanIf`

> Rewrite `if cond, do: true, else: false` to the condition itself.

### `Number42.Refactors.Ex.RemoveTrivialElseClause`

> Remove identity-only `else` clauses from `with` expressions.

### `Number42.Refactors.Ex.WithSingleClauseToCase`

> Rewrite single-clause `with` into `case`.

### `Number42.Refactors.Ex.WithWithoutElse`

> Drop redundant `else` blocks on `with` chains.

## Pipes & Sigils

Refactors that reshape data-flow expressions into pipe form.

### `Number42.Refactors.Ex.ExtractSocketToPipe`

> `any_function(socket, ...)` → `socket |> any_function(...)`.

### `Number42.Refactors.Ex.ExtractToPipeline`

> `Enum` / `Stream` call form → pipe form (extract first arg).

### `Number42.Refactors.Ex.LiftPinnedEctoExpr`

> Pinned non-var expression in `Ecto` query → hoist to a named binding.

### `Number42.Refactors.Ex.LiftWithIntoPipeline`

> Lift single-clause `with` with a transformation body into a pipe.

### `Number42.Refactors.Ex.ManualTapToTap`

> `value |> then(fn x -> eff; x end)` /
> `value |> (fn x -> eff; x end).()` → `value |> tap(fn x -> eff end)`.

### `Number42.Refactors.Ex.PipeReassign`

> `x = f(x, ...)` → `x = x |> f(...)`.

## Length / String / List

Refactors that fix correctness or performance bugs hidden inside
`length` and friends.

### `Number42.Refactors.Ex.GraphemesLength`

> `String.graphemes(s) |> length()` → `String.length(s)`.

### `Number42.Refactors.Ex.LengthInGuard`

> Replace `length/1` guards with explicit pattern clauses + existing
> catch-all body.

### `Number42.Refactors.Ex.LengthZeroToEmpty`

> `length` / `Enum.count == 0` / `> 0` → `Enum.empty?` / `Enum.any?`.

### `Number42.Refactors.Ex.ListLastOfReverse`

> `List.last(Enum.reverse(list))` → `List.first(list)`.

### `Number42.Refactors.Ex.SortForTopK`

> `Enum.sort + take(1)` / `hd` → `Enum.min` / `Enum.max`.

## Definition Hygiene

Refactors that clean up redundant or unhelpful `def` shapes.

### `Number42.Refactors.Ex.DelegateExactDuplicates`

> Cross-file: replace exact duplicates with `defdelegate`.

### `Number42.Refactors.Ex.ExpandShortFormBindings`

> Expand short-form local bindings to long forms.

### `Number42.Refactors.Ex.ExpandShortFormFunctions`

> Expand short-form private function names to long forms.

### `Number42.Refactors.Ex.ExpandShortFormParams`

> Expand short-form parameter names to long forms.

### `Number42.Refactors.Ex.IdentityPassthrough`

> Remove `case` expressions where every clause is `pat -> pat`.

### `Number42.Refactors.Ex.InlineSingleExpressionDef`

> Collapse single-expression `def` / `defp` body to `do:` form.

### `Number42.Refactors.Ex.ResolveImplTrue`

> `@impl true` → `@impl <Behaviour>` via BEAM lookup.

### `Number42.Refactors.Ex.UnusedVariable`

> Prefix unused bindings in `def` / `case` / `with` / `fn` / `cond`
> clauses with `_`.

## Cross-File Extraction

Refactors that reach across files to consolidate duplication.

> **Caveat.** Cross-file refactors are the most powerful and the most
> opinionated. Run them with `--dry-run` first on legacy code; use
> `--step-by-step` to review per refactor. See
> [`guides/safety-and-limitations.md`](safety-and-limitations.md).

### `Number42.Refactors.Ex.ExtractCaseToHelper`

> `case <call>(...) do ... end` at tail of `fn` → extract
> `handle_<host>_<call>`.

### `Number42.Refactors.Ex.ExtractInlineBlock`

> Extract duplicated function bodies into a shared private helper.

### `Number42.Refactors.Ex.ExtractIntraModuleClone`

> Within-module clone collapse: extra clauses delegate to the first.

### `Number42.Refactors.Ex.ExtractLambdaBlock`

> Extract duplicated anonymous-function bodies into a shared private
> helper.

### `Number42.Refactors.Ex.ExtractNestedBlock`

> Extract too-deeply-nested `fn` bodies into private helpers.

### `Number42.Refactors.Ex.ExtractParametricClone`

> Type-II clone extraction: parametrise differing literals into a
> helper.

### `Number42.Refactors.Ex.ExtractRenamedClone`

> Cross-file: extract renamed duplicates into a `{LCP}.Shared` module.

### `Number42.Refactors.Ex.ExtractSharedModule`

> Cross-file: extract exact duplicates into a `{LCP}.Shared` module.

## HEEx

Refactors that operate on HEEx templates (inline `~H` sigils and
`.heex` files).

### `Number42.Refactors.Ex.ExtractHeexExactClone`

> Extract `:exact` HEEx clones into the configured `CoreComponents`
> module. Requires `heex.core_components_module` in `.refactor.exs`.

### `Number42.Refactors.Ex.ExtractHeexFor`

> Extract `<%= for %>` bodies in `~H` sigils into private
> function-components.

## Type & API Safety

Refactors that fix specific bug patterns rather than style issues.

### `Number42.Refactors.Ex.MapGetUnsafePass`

> `Map.get(x, k, nil)` → `Map.get(x, k)` (also `Keyword.get`).

### `Number42.Refactors.Ex.TryRescueWithSafeAlternative`

> `try` / `rescue` around `Map.fetch!` / `Keyword.fetch!` →
> `.get(..., default)`.

### `Number42.Refactors.Ex.UtcNowTruncate`

> `DateTime.utc_now() |> DateTime.truncate(p)` → `DateTime.utc_now(p)`.
