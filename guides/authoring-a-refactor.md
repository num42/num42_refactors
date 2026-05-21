# Authoring a Refactor

End-to-end walkthrough for writing a new refactor module — the contract,
the tools, the testing, and the pitfalls.

## The contract

A refactor is a module that implements `Number42.Refactors.Refactor`
and is marked with `use Number42.Refactors.Refactor`. The engine
discovers it automatically via the `is_refactor` persistent attribute.

```elixir
defmodule MyApp.Refactors.MyRule do
  use Number42.Refactors.Refactor

  @impl true
  def description, do: "What this refactor does in one line."

  @impl true
  def transform(source, _opts) do
    # Sourceror-based rewrite; return the rewritten string.
    # Idempotent! Already-conformant code must pass through unchanged.
    source
  end
end
```

Two callbacks are required (`transform/2`, `description/0`), four are
optional with sensible defaults (`explanation/0`, `priority/0`,
`prepare/1`, `reformat_after?/0`). See `architecture.md` and
`Number42.Refactors.Refactor` for the full list.

## Correctness properties

### Idempotent (hard requirement)

Applying the refactor twice must produce the same source as applying it
once. The engine's fixpoint loop will re-invoke your refactor until the
source stabilises, capped at 5 passes. A non-idempotent refactor will
either hit that cap (and the engine raises) or, worse, oscillate
silently.

Most idempotence bugs are pattern-match shapes: the rewrite produces
code that re-matches the *input* pattern. The fix is usually a check
in `transform/2` that detects the post-rewrite shape and returns the
source untouched.

### Behaviour preservation (best effort, not a guarantee)

A refactor *aims* to leave observable behaviour unchanged: return
values, side effects, raised exceptions, dispatch order, message
passing. In practice this is a best-effort property — the engine has
no way to formally verify it, and there is no mechanism in this
project that proves a given rewrite is sound.

What this means in practice:

- Treat every rewrite as a code change, not a free pass. Review the
  diff, run the consumer's test suite, rely on CI.
- When the rewrite shape is ambiguous (multiple plausible semantics,
  macro-touched call sites, generated code), **skip rather than
  rewrite**. A skipped case is a non-event; a wrong rewrite is a bug
  in production.
- If a refactor's correctness depends on a non-obvious invariant
  (a guard context, a specific call shape, the absence of side
  effects in a sub-expression), say so in the moduledoc's
  `explanation/0` and the test file. Reviewers and future-you need to
  see the reasoning.

A useful sanity check while developing: run the rewritten code against
the project's existing test suite (or a property-based harness, if
available). Differences are bugs; identical output is evidence, not
proof.

## A worked example: `LengthZeroToEmpty`

Real bundled refactor, ~250 lines, illustrates the typical shape.

**What it does** (excerpt from the moduledoc):

```
Enum.count(x) == 0   →   Enum.empty?(x)
length(x) > 0        →   not Enum.empty?(x)
Enum.count(x, fun) > 0  →  Enum.any?(x, fun)
```

**The structure:**

1. **Parse.** `Sourceror.parse_string(source)`. On error, return the
   source untouched — never crash on malformed input.
2. **Collect guard-context nodes.** `length/1` rewrites differently
   inside a `when` clause (where `Enum.empty?/1` isn't allowed). A
   prewalk builds a `MapSet` of every node that lives in a guard.
3. **Walk + classify.** A prewalk emits a list of `Sourceror.Patch`
   structs, one per comparison expression we want to rewrite. The
   classify step distinguishes `:empty` / `:nonempty` / `:any` /
   `:none` cases and remembers whether the source was `length/1` or
   `Enum.count/1` (relevant in guards).
4. **Render.** For each patch, build the replacement string (handling
   pipe-form vs. call-form of the collection expression).
5. **Apply.** `Sourceror.patch_string(source, patches)` produces the
   final source. If there are no patches, return the source unchanged
   (cheap, and avoids a needless string re-emit).

Read `lib/number42/refactors/ex/length_zero_to_empty.ex` for the full
implementation.

## Sourceror primer

The minimum you need to know to write a refactor.

### Parse / re-emit

```elixir
{:ok, ast} = Sourceror.parse_string(source)
new_source = Sourceror.to_string(ast)
```

`Sourceror.parse_string/1` preserves comments, formatting metadata, and
node positions. `Sourceror.to_string/1` re-emits the tree, including
leading/trailing comments from the metadata.

**Do not use** `Code.string_to_quoted!/1` — it strips comments and
metadata, which means round-tripping through it loses information.

### Patches

For rewrites that touch only specific subtrees, build a list of
`Sourceror.Patch` structs and apply them with
`Sourceror.patch_string/2`. This is faster than re-emitting the whole
tree and preserves surrounding formatting:

```elixir
patches = [
  Sourceror.Patch.replace(node, "Enum.empty?(x)")
]
Sourceror.patch_string(source, patches)
```

Patches must not overlap. The engine sorts them back-to-front
internally; if you build them in source order, that's fine.

### Pipe shape

`Sourceror.to_string/1` does *not* reconstruct pipes that were
flattened during rewrite. If your replacement risks producing a
flattened pipe chain, either:

- write the replacement as a single non-piped expression and set
  `reformat_after?/0 == true` (the host `mix format` pass will not
  rebuild the pipe, but it will fix any other formatting drift), or
- emit the pipe form directly in your replacement string.

Pipe shape is a stylistic concern outside the engine's scope. Don't
try to detect "this should be a pipe" in your refactor — leave that
to the formatter or to a dedicated pipe-shaping refactor.

### Traversal: prewalk vs. zipper

For simple "scan once, emit patches" rewrites, `Macro.prewalker/1`
returns a lazy stream you can `Enum.flat_map/2` over. Cheap, no state
threading.

For rewrites that need surrounding context (parent node, depth,
sibling state), `Sourceror.Zipper` is the tool — it lets you move
up/down/left/right in the tree and reason about node neighbourhoods.

Most bundled refactors use the prewalker. Reach for the zipper only
when you actually need parent context.

## Helpers in `Number42.Refactors.AstHelpers`

Before writing a helper, check what's there:

- `alias_to_module/1` — `{:__aliases__, _, parts}` → `{:ok, Module}`.
- `bare_var?/1`, `bare_var/1` — recognise plain variable references.
- `body_to_exprs/1` — flatten a `{:__block__, _, exprs}` to its
  contained expressions, or wrap a single expr.
- `clip_end_for_boolish_tail/2` — fixes a Sourceror quirk where
  `true` / `false` / `nil` ranges overshoot by one column.
- `singularize/1`, `latch_match/2`, `maybe_past_participle/4` —
  compound-name heuristics used by the `ExpandShortForm*` family.

If a helper would serve only one refactor, keep it private. Helpers
are the shared shape, not the shared logic.

## Testing

Each refactor has exactly one test file under
`test/refactors/<area>/<name>_test.exs`. Tests use
`Number42.RefactorCase`:

```elixir
defmodule Number42.Refactors.Ex.RejectIsNilTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.RejectIsNil
  @subject RejectIsNil

  describe "rewrites" do
    test "filter + not is_nil → Enum.reject(&is_nil/1)" do
      assert_rewrites(
        @subject,
        "Enum.filter(list, fn x -> not is_nil(x) end)",
        "Enum.reject(list, &is_nil/1)"
      )
    end
  end

  describe "leaves alone" do
    test "already canonical" do
      assert_unchanged(@subject, "Enum.reject(list, &is_nil/1)")
    end
  end

  describe "idempotent" do
    test "twice == once" do
      assert_idempotent(@subject, "Enum.filter(list, fn x -> not is_nil(x) end)")
    end
  end
end
```

Three sections per file, in this order. The idempotence section is
**not optional** — without it, the engine's fixpoint loop can
silently catch a regression in production but not in CI.

Comparison is whitespace-agnostic (see
`Number42.RefactorCase.squeeze/1`) so heredocs with natural
indentation work without a `mix format` pass in the test path.

## Common pitfalls

### Sourceror wraps literals

`true`, `false`, `nil`, atoms, integers, floats appear in the AST as
`{:__block__, _, [literal]}`, not as the bare literal. Pattern-match
both forms or normalise first.

### `def` / `defp` / `defmacro` heads look like generic calls

A `def foo(x)` head has the same tuple shape as a `foo(x)` call. If
your refactor walks calls, you must either skip def-heads explicitly
or handle them differently. Otherwise you'll rewrite function
signatures.

### Comments live in node metadata

`Sourceror.to_string/1` re-emits `:leading_comments` and
`:trailing_comments` from each node's metadata. If you reuse an
existing subtree as part of a larger replacement, strip those
metadata fields first with `Macro.prewalk/2` — otherwise comments
duplicate.

### Macros and `unquote`

Refactors operate on the *source* AST, not on macro-expanded code.
`quote do ... end` blocks and `unquote(...)` interpolations are
visible to your refactor as syntactic constructs. Most refactors
should leave them alone — the semantics of the expanded form is
determined by the macro definition, which the refactor has no
visibility into.

### Sigil bodies are opaque strings

`~r/.../`, `~w(...)`, etc. appear in the AST with their body as a
string. HEEx (`~H`) is special-cased via the
`Number42.Refactors.Heex.*` subsystem; other sigils are best left
alone unless your refactor explicitly understands the sigil's
grammar.

### Generated code

Some macros generate code via `unquote_splicing/1` that looks
structurally identical to handwritten code but is part of a template
that gets expanded later. Refactors that rewrite call sites can break
templates by making them no longer reduce the way the macro author
intended. When in doubt: skip rather than rewrite.

## Performance hints

- **Bail early.** If your refactor's first check (a regex against the
  source string, say) tells you nothing matches, return the source
  immediately. Don't parse and walk for nothing.
- **Use `prepare/1` for project-wide state.** Reading every schema in
  the project once per file is O(n²). Reading them once per run with
  `prepare/1` is O(n).
- **`reformat_after?/0 == true` triggers a `mix format`.** That's not
  free. Only set it if your rewrite actually leaves the source in a
  state the formatter would fix.

## Naming and scope

- One rewrite concept per module.
- File path matches module short name (`lib/number42/refactors/ex/foo_bar.ex`
  ↔ `Number42.Refactors.Ex.FooBar`).
- No "umbrella refactors" that branch on a config flag to do five
  different rewrites — split into five modules.
- Naming convention: imperative or transformation-named
  (`MultiAliasExpand`, `LengthZeroToEmpty`, `ExtractSharedModule`).
  Avoid `*Cleaner`, `*Fixer`, `*Improver`.

## Submission checklist

Before opening a PR:

- [ ] `@moduledoc` with **before / after** examples
- [ ] `description/0` is one short line
- [ ] `explanation/0` explains *why* the rewrite is correct + helpful
- [ ] Test file with `rewrites` / `leaves alone` / `idempotent`
  sections, `async: true`
- [ ] No regressions in `mix credo --strict` or `mix dialyzer`
- [ ] `CHANGELOG.md` entry under `[Unreleased]` → `### Added`
- [ ] `mix.exs` `groups_for_modules` updated if the refactor lands
  in a new category
