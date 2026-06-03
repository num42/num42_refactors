defmodule Number42.Refactors.AstHelpers do
  alias Sourceror.Patch

  @moduledoc """
  Module-agnostic AST predicates and accessors shared across refactors,
  plus a small set of compound-name (snake_case word) heuristics used
  by the `ExpandShortForm*` refactors.

  Every helper here is "the same shape, the same answer, in every
  refactor that needs it." If a helper is conceptually shared but
  semantically diverges between refactors (e.g. several modules have
  a `module_body_exprs/1` but with different match heads), it stays
  per-module — the cost of forcing a shared signature is worse than
  the duplication.

  AST helpers don't depend on Sourceror or ExAST; they're pure AST
  tuple predicates. The compound-name helpers (`singularize/1`,
  `latch_match/2`, `maybe_past_participle/4`, ...) operate on plain
  strings and don't touch AST at all — they live here because both
  ExpandShortForm refactors share them and the alternative is a
  one-purpose helper module.
  """

  @doc """
  Resolve an `{:__aliases__, _, parts}` AST node into the concrete
  module atom. Returns `{:ok, module}` on success, `:error` for any
  other shape or for an empty parts list.

  Used by refactors that need to compare a written alias (`Foo.Bar`
  in source) against `__MODULE__` or a known module name to decide
  whether to rewrite.
  """
  @spec alias_to_module(term()) :: {:ok, module()} | :error
  def alias_to_module({:__aliases__, _, parts}) when is_list(parts) and parts != [] do
    {:ok, Module.concat(parts)}
  rescue
    _ -> :error
  end

  def alias_to_module(_), do: :error

  @doc """
  Build a `Sourceror.Patch` that replaces `node`'s source range with
  `replacement` text. Returns `nil` if Sourceror can't compute a range
  for the node (typically bare atoms, integers, or floats).

  ## Options

    * `:boolish_tail?` — when `true`, shave one column off the end of
      the range before building the patch. Use this when the rewritten
      node ends in a `nil` / `true` / `false` literal whose Sourceror
      range over-shoots by one. See `clip_end_for_boolish_tail/2`.
  """
  @spec build_patch(term(), String.t(), keyword()) :: Sourceror.Patch.t() | nil
  def build_patch(node, replacement, opts \\ []),
    do: Sourceror.get_range(node) |> patch_for_range_or_nil(node, opts, replacement)

  @doc """
  Whether `kind` is one of the basic function-definition kinds
  (`:def` or `:defp`). Use when a refactor only cares about regular
  functions and explicitly wants to leave macros alone.

  Usable in guards.
  """
  defguard def_kind?(kind) when kind in [:def, :defp]

  @doc """
  Whether `kind` is any function- or macro-definition kind
  (`:def`, `:defp`, `:defmacro`, `:defmacrop`). Use when a refactor's
  invariant applies equally to functions and macros (e.g. socket-pipe
  rewriting in any callable head).

  Usable in guards.
  """
  defguard def_or_macro_kind?(kind) when kind in [:def, :defp, :defmacro, :defmacrop]

  @doc """
  Whether `op` is an operator that, when wrapped in a fresh `|>` pipe,
  would rebind precedence and produce different (often invalid) code.

  Refactors that introduce new pipe stages (`extract_to_pipeline`,
  `extract_socket_to_pipe`, `enum_capture`) consult this guard to
  decide whether to skip the rewrite at this position.

  Usable in guards: `when pipe_unsafe_op?(op) and is_list(args)`.
  """
  defguard pipe_unsafe_op?(op)
           when op in [
                  :++,
                  :+,
                  :-,
                  :*,
                  :/,
                  :==,
                  :!=,
                  :===,
                  :!==,
                  :>,
                  :<,
                  :>=,
                  :<=,
                  :and,
                  :or,
                  :not,
                  :&&,
                  :||,
                  :!,
                  :in,
                  :|,
                  :"::",
                  :<>,
                  :<-
                ]

  @doc """
  Extract a bare variable name from an AST node.

  Returns `{:ok, name}` for `{name, _, ctx}` where both `name` and
  `ctx` are atoms and `name` doesn't start with an underscore.
  Otherwise `:skip`.
  """
  def bare_var({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    if underscore?(name), do: :skip, else: {:ok, name}
  end

  def bare_var(_), do: :skip

  @doc """
  Unwrap a `do` body into a flat list of expressions.

      iex> #{__MODULE__}.body_to_exprs({:__block__, [], [:a, :b]})
      [:a, :b]

      iex> #{__MODULE__}.body_to_exprs(:single)
      [:single]
  """
  def body_to_exprs({:__block__, _, exprs}), do: exprs
  def body_to_exprs(single), do: [single]

  @doc """
  Pull the function/macro name out of a call expression. Looks at the
  *outermost* call — for a pipe, that's the last stage; for a remote
  call, that's the function part of the dot:

      build_changeset(x)              → {:ok, :build_changeset}
      x |> build_changeset()          → {:ok, :build_changeset}
      Foo.bar(x)                      → {:ok, :bar}
      x |> Foo.bar()                  → {:ok, :bar}

  Returns `:error` for anything that isn't a call (variables, literals,
  blocks).
  """
  @spec extract_call_name(term()) :: {:ok, atom()} | :error
  def extract_call_name({:|>, _, [_lhs, rhs]}), do: extract_call_name(rhs)
  def extract_call_name({{:., _, [_callee, name]}, _, _}) when is_atom(name), do: {:ok, name}
  def extract_call_name({name, _, args}) when is_atom(name) and is_list(args), do: {:ok, name}
  def extract_call_name(_), do: :error

  @doc """
  Derive a snake_case name from a module — the last segment, lowercased.
  Used by helper-naming heuristics that turn a struct/alias into a
  candidate parameter name.

  Accepts either a bare atom module (`MyApp.Foo`), an `{:__aliases__, _, segs}`
  AST node, or a tuple of segments. Returns `nil` for inputs that don't
  resolve to a module name.

      iex> #{__MODULE__}.humanize_module(MyApp.ReferenceBuilding)
      "reference_building"

      iex> #{__MODULE__}.humanize_module({:__aliases__, [], [:Foo, :Bar]})
      "bar"
  """
  @spec humanize_module(term()) :: String.t() | nil
  def humanize_module({:__aliases__, _, segs}) when is_list(segs) and segs != [] do
    segs |> List.last() |> Atom.to_string() |> Macro.underscore()
  end

  def humanize_module(mod) when is_atom(mod) and not is_nil(mod) do
    Atom.to_string(mod) |> module_name_underscored()
  end

  def humanize_module(_), do: nil

  @doc """
  Unwrap the body of a `defmodule` AST node into a flat list of
  expressions. Returns `nil` for any other shape.

  Equivalent to `body_to_exprs/1` applied to the body argument of a
  `defmodule` node — exists as its own function so callers don't have
  to re-pattern-match the `defmodule` wrapper.
  """
  def module_body_exprs({:defmodule, _, [_name, [{_do, body}]]}), do: body_to_exprs(body)
  def module_body_exprs(_), do: nil

  # Elixir reserved words that cannot be used as parameter names.
  @reserved_words ~w(true false nil when and or not in fn do end after else
                     catch rescue case cond if unless quote unquote receive try with for)

  @doc """
  Collect every bare variable name introduced as a binding by the
  given AST: LHS of `=` assignments, lambda parameters, comprehension
  generators, and `case`/`with`/`fn` clause patterns. Underscored and
  reserved names (`__MODULE__`, `__CALLER__`, `__ENV__`) are skipped.

  Conservative: a name appearing in *any* binding shape inside `ast`
  is reported, even if the binding is on a branch that wouldn't
  execute. That's safe — over-reporting only suppresses helper
  parameters that turn out to be unneeded, never the other way
  around.
  """
  @spec bound_in(term()) :: MapSet.t()
  def bound_in(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:=, _, [lhs, _rhs]} ->
        pattern_var_names(lhs)

      {:fn, _, clauses} ->
        clauses
        |> Enum.flat_map(fn
          {:->, _, [args, _body]} -> args |> Enum.flat_map(&pattern_var_names/1)
          _ -> []
        end)

      {:<-, _, [lhs, _rhs]} ->
        pattern_var_names(lhs)

      _ ->
        []
    end)
    |> MapSet.new()
  end

  @doc """
  Shave one column off `end_pos` if `ast` ends in a `nil` / `true` /
  `false` literal that has no closing-bracket metadata. Sourceror
  over-shoots the range of these tokens by exactly one column (it
  measures via `:nil` / `:true` / `:false` atom names), and a raw
  slice using that range leaks the next character — typically a `,`
  or `}` — into the result.

  Pass-through for any other shape, so this is safe to apply
  unconditionally before slicing or patching.
  """
  @spec clip_end_for_boolish_tail(term(), keyword()) :: keyword()
  def clip_end_for_boolish_tail(ast, end_pos) do
    if has_closing_meta?(ast) do
      end_pos
    else
      if rightmost_is_boolish?(ast) do
        [line: l, column: c] = end_pos
        [line: l, column: c - 1]
      else
        end_pos
      end
    end
  end

  @doc """
  Whether `ast` is the empty list literal — either bare `[]` or the
  Sourceror-parsed `{:__block__, _, [[]]}` form. Both shapes mean the
  same thing semantically; consumers should treat them equally.
  """
  def empty_list?([]), do: true
  def empty_list?({:__block__, _, [[]]}), do: true
  def empty_list?(_), do: false

  @doc """
  Read the line number where this expression *ends* — Sourceror records
  this in `meta[:end_of_expression][:line]` when available, otherwise
  falls back to `meta[:line]`, otherwise `1`.

  Used for inserting new lines immediately after an existing node.
  """
  def end_of_expression_line({_, meta, _}) when is_list(meta) do
    Keyword.get(meta, :end_of_expression) |> end_of_expression_line_get(meta)
  end

  def end_of_expression_line(_), do: 1

  @doc """
  Pull `{name, params}` from a `def`/`defp`/`defmacro` head.

      def foo(a, b)         → {:foo, [a_ast, b_ast]}
      def foo(a) when ...   → {:foo, [a_ast]}      (when-guard stripped)
      def foo                → {:foo, []}           (no args)

  Returns `:error` for any shape that isn't a recognisable function head.
  """
  @spec extract_fn_signature(term()) :: {atom(), [term()]} | :error
  def extract_fn_signature({:when, _, [inner | _]}), do: extract_fn_signature(inner)

  def extract_fn_signature({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, args}

  def extract_fn_signature({name, _, nil}) when is_atom(name), do: {name, []}
  def extract_fn_signature(_), do: :error

  @doc """
  Compute the free variables of `ast` relative to a set of `available`
  outer-scope names.

  A name is free if it is referenced inside `ast` but not bound there
  (no LHS-of-`=`, lambda arg, generator, etc.) AND it appears in
  `available`. The `available` filter prevents module names, imported
  functions, and other non-variable identifiers from being counted —
  the caller passes in the names they know to be in scope at the
  extraction site (function parameters + previously-bound vars).

  Returned as a sorted atom list for deterministic helper signatures.
  """
  @spec free_vars(term(), MapSet.t()) :: [atom()]
  def free_vars(ast, available) do
    used = used_var_names(ast)
    bound = bound_in(ast)

    used
    |> MapSet.difference(bound)
    |> MapSet.intersection(available)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @doc """
  Recursively rewrite every `lhs |> rhs` pipe in `ast` into the
  equivalent direct call (`rhs(lhs, …)` with `lhs` injected as first
  argument). Identical to applying `Macro.pipe/3` step-by-step, except
  it walks the whole tree so nested/non-toplevel pipes are also
  inlined.

  Used by clone-detection passes that must compare two ASTs purely on
  call-shape: pipes are sugar, and treating `a |> f(b)` as different
  from `f(a, b)` would split semantically identical clones into
  different buckets and produce broken helpers when only one side of a
  divergent pipe-RHS gets parametrised.

      iex> #{__MODULE__}.inline_pipes(quote do: a |> b(1))
      quote(do: b(a, 1))
  """
  @spec inline_pipes(term()) :: term()
  def inline_pipes(ast) do
    Macro.prewalk(ast, fn
      {:|>, _meta, [lhs, rhs]} -> inline_pipe(lhs, rhs)
      other -> other
    end)
  end

  @doc """
  Read the source line from a node's metadata. Falls back to `1` for
  shapes without a usable `:line` key.
  """
  def line_of({_, meta, _}) when is_list(meta), do: Keyword.get(meta, :line, 1)
  def line_of(_), do: 1

  @doc """
  Derive a candidate identifier (string) from a hole-value AST. Used by
  the helper-naming heuristic — the result is a *suggestion* that the
  caller may further sanitise / disambiguate against existing names.

  Dispatches on AST shape:

  * bare variable (`{name, _, ctx}` with atom ctx) → the var name
  * Sourceror-wrapped atom literal (`{:__block__, _, [:foo]}`) → `"foo"`
  * dot-property access (`assigns.group`) → `"group"`
  * function call (`Mod.fn(_)`, `local_fn(_)`) → the function name
  * struct match pattern (`%Mod{} = var`) → humanised module name

  Returns `nil` when no name can be derived (string/int/float literals,
  opaque AST shapes).
  """
  @spec name_from_value(term()) :: String.t() | nil
  def name_from_value({:=, _, [{:%{}, _, _}, var]}), do: name_from_value(var)

  def name_from_value({:=, _, [{:%, _, [aliases, _]}, _var]}),
    do: humanize_module(aliases)

  def name_from_value({:%, _, [aliases, _]}), do: humanize_module(aliases)

  def name_from_value({:__block__, _, [v]}) when is_atom(v) and not is_nil(v) do
    Atom.to_string(v) |> name_from_atom_string(v)
  end

  def name_from_value({:__block__, _, [v]}) when is_binary(v) do
    # String literals can stand in for keys ("name", "logo-asset-id").
    # Only accept strings that look like an identifier or a kebab-case
    # key — anything else (free-form text, mixed case, embedded space)
    # would not be a sensible param name.
    if Regex.match?(~r/\A[a-z_][a-z0-9_-]*\z/, v),
      do: sanitize_identifier(v),
      else: nil
  end

  def name_from_value({:__block__, _, [_v]}), do: nil

  def name_from_value({{:., _, [_target, prop]}, _, []}) when is_atom(prop) do
    sanitize_identifier(Atom.to_string(prop))
  end

  def name_from_value({{:., _, [_target, fn_name]}, _, args})
      when is_atom(fn_name) and is_list(args) do
    sanitize_identifier(Atom.to_string(fn_name))
  end

  def name_from_value({fn_name, _, args})
      when is_atom(fn_name) and is_list(args) and args != [] do
    sanitize_identifier(Atom.to_string(fn_name))
  end

  def name_from_value({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    sanitize_identifier(Atom.to_string(name))
  end

  def name_from_value(_), do: nil

  @doc """
  Variable names introduced by a pattern (LHS of `=`, lambda arg,
  case/with clause head). Walks the pattern and collects every
  `{name, _, ctx}` where both atoms, skipping underscored names and
  the `__MODULE__`/`__CALLER__`/`__ENV__` reserved trio.

  Name capture in patterns: `{a, b}`, `%{key: c}`, `[d | rest]` all
  introduce their bare-var children.
  """
  @spec pattern_var_names(term()) :: [atom()]
  def pattern_var_names(pattern) do
    pattern
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
        string = Atom.to_string(name)

        if String.starts_with?(string, "_") or name in [:__MODULE__, :__CALLER__, :__ENV__] do
          []
        else
          [name]
        end

      _ ->
        []
    end)
  end

  @doc """
  Compute the on-disk path for a freshly-emitted module under `lib/`.

  The naive convention `Macro.underscore` each module segment breaks
  when a namespace doesn't round-trip: `Macro.underscore("CodeQA")` is
  `"code_qa"`, but a project may lay that namespace out under
  `lib/codeqa/`. Underscoring blindly would spawn a duplicate top-level
  `lib/code_qa/` dir and, on a later run, module/path collisions (#9).

  Derivation, most-accurate first:

    1. **Existing layout** — the real top-level `lib/<dir>/` the source
       files already live in. `source_paths` are the on-disk paths of
       the files being refactored; their most common `lib/<dir>` prefix
       is the source of truth. In production every source comes from a
       real on-disk path (`source_files` / `.refactor.exs` inputs read
       via `File.read!/1`), so this branch fires whenever it matters.
    2. **`Macro.underscore`** — fallback that preserves the historical
       behaviour when no source path reveals a `lib/<dir>` (e.g. tests
       that pass synthetic `"a.ex"` paths).

  Only the *top-level* segment is layout-derived; nested segments keep
  the standard `Macro.underscore` mapping (`Items.Positions` →
  `items/positions`), which is the actual file convention for nested
  modules.
  """
  @spec shared_module_path(module(), Path.t(), [Path.t()]) :: Path.t()
  def shared_module_path(target_module, write_root, source_paths) do
    [first | tail] = Module.split(target_module)

    root = lib_top_dir(first, source_paths)
    rest = Enum.map(tail, &Macro.underscore/1)

    rel = Path.join(["lib", root | rest]) <> ".ex"
    Path.join(write_root, rel)
  end

  @doc """
  Decide whether a binding/param/function name is "short" — a candidate
  for the ExpandShortForm refactors.

  A name is short when **at least one** of its `_`-split subtokens is
  short (≤ 3 chars) and not whitelisted. This catches `cs`, `cs_id`,
  `user_cs_form` (mid-token short) just as well as bare single-segment
  shorts.

  Short-circuits:

  - `_`-prefixed names (intentional ignores) → never short
  - exact-name in `ctx.whitelist` → never short
  - exact-name key in `ctx.known` → always short

  `ctx` is a map with `:whitelist` (`MapSet.t()` of `atom`) and `:known`
  (a `%{String.t() => String.t()}` mapping). Extra keys are ignored.
  """
  @spec short_name?(atom(), %{
          required(:whitelist) => MapSet.t(),
          required(:known) => map(),
          optional(any()) => any()
        }) :: boolean()
  def short_name?(name, ctx) when is_atom(name) do
    string = Atom.to_string(name)

    cond do
      MapSet.member?(ctx.whitelist, name) -> false
      Map.has_key?(ctx.known, string) -> true
      String.starts_with?(string, "_") -> false
      true -> any_short_subtoken?(string, ctx.whitelist)
    end
  end

  @doc """
  Render an AST node back to source text, preferring direct rendering
  for literal forms over `Sourceror.get_range/1`-based slicing.

  Used by refactors that splice subexpressions verbatim (e.g.
  `merge_assign_keywords`, `pipe_reassign`, `use_map_join`) — slicing
  preserves the user's exact formatting (string escapes, parens,
  comments) where re-emitting via `Sourceror.to_string/1` would not.

  ## Why direct rendering for literals?

  Sourceror's range for `true`/`false`/`nil` literals over-shoots the
  source token by exactly one column (it measures via `:true`/`:false`/
  `:nil` atom names). For shapes like `foo(x || false)` the range of
  the `||` operator inherits this over-shoot from its right operand
  and leaks the enclosing call's `)` into the slice — producing
  `false)` and a duplicated `)` after the patch.

  Two-pronged defence:
  1. Bare and `:__block__`-wrapped literals (atom/int/float — including
     `true`/`false`/`nil`) render directly from the AST, never touching
     `Sourceror.get_range/1`.
  2. For composite expressions whose right-most leaf is a boolish
     literal, the range's `end_column` is shaved by one before slicing.

  Returns `{:ok, text}` or `:error` if no usable range is available.
  """
  @spec slice_node(String.t(), term()) :: {:ok, String.t()} | :error
  def slice_node(_source, atom) when is_atom(atom), do: {:ok, render_atom(atom)}
  def slice_node(_source, n) when is_integer(n), do: {:ok, Integer.to_string(n)}
  def slice_node(_source, n) when is_float(n), do: {:ok, Float.to_string(n)}

  def slice_node(_source, {:__block__, _, [literal]})
      when is_atom(literal) or is_integer(literal) or is_float(literal) do
    {:ok, render_atom_or_number(literal)}
  end

  def slice_node(source, ast), do: Sourceror.get_range(ast) |> slice_or_error(ast, source)

  @doc """
  Slice raw source text between two `[line: l, column: c]` positions.

  Both positions use Sourceror's 1-indexed line/column convention,
  with the `end` column **exclusive** — same convention as
  `Sourceror.get_range/1` and `Sourceror.Patch.new/3`.
  """
  @spec slice_source(String.t(), keyword(), keyword()) :: String.t()
  def slice_source(source, start_pos, end_pos) do
    l1 = Keyword.fetch!(start_pos, :line)
    c1 = Keyword.fetch!(start_pos, :column)
    l2 = Keyword.fetch!(end_pos, :line)
    c2 = Keyword.fetch!(end_pos, :column)

    lines = String.split(source, "\n", trim: false)

    cond do
      l1 == l2 ->
        line = lines |> Enum.at(l1 - 1, "")
        String.slice(line, (c1 - 1)..(c2 - 2)//1)

      true ->
        first_line = lines |> Enum.at(l1 - 1, "") |> String.slice((c1 - 1)..-1//1)
        middle_lines = lines |> Enum.slice(l1..(l2 - 2)//1)
        last_line = lines |> Enum.at(l2 - 1, "") |> String.slice(0..(c2 - 2)//1)

        ([first_line | middle_lines] ++ [last_line]) |> Enum.join("\n")
    end
  end

  @doc """
  Whether the AST node is a special form that uses `do/end` blocks
  rather than `(...)` argument lists.

  These look like 2-arg function calls in the AST
  (`{:case, _, [scrutinee, [do: ...]]}`) but rewriting them as pipe
  steps or paren-calls produces invalid syntax — Sourceror's range
  covers the `end` keyword which slicing logic built for `)` mishandles.

  Refactors that turn calls into pipes / re-paren them must skip these.
  """
  def special_form?({name, _, _})
      when name in [
             :case,
             :cond,
             :for,
             :fn,
             :if,
             :quote,
             :receive,
             :try,
             :unless,
             :unquote,
             :with
           ],
      do: true

  def special_form?(_), do: false

  @doc """
  Whether `name` (an atom) is an underscore-prefixed binding name.

  Used to skip rewrites whose variables are intentionally unused —
  promoting them would either break or pointlessly churn the source.
  """
  def underscore?(name) when is_atom(name) do
    name |> Atom.to_string() |> String.starts_with?("_")
  end

  @doc """
  Strip a single-expression `__block__` wrapper. Other shapes pass
  through unchanged.
  """
  def unwrap_block({:__block__, _, [inner]}), do: inner
  def unwrap_block(other), do: other

  @doc """
  Every bare variable name *referenced* (not bound) anywhere in `ast`.

  This is a syntactic over-approximation — a name `foo` that's actually
  a zero-arg local function call parses as `{:foo, _, ctx}` where `ctx`
  is an atom and is indistinguishable from a variable reference at the
  AST level. Callers filter this set against a known scope (e.g. via
  `free_vars/2`) to drop those false positives.

  Underscored and reserved names (`__MODULE__`/etc.) are excluded —
  they're never things you'd thread through a helper signature.
  """
  @spec used_var_names(term()) :: MapSet.t()
  def used_var_names(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
        string = Atom.to_string(name)

        if String.starts_with?(string, "_") or name in [:__MODULE__, :__CALLER__, :__ENV__] do
          []
        else
          [name]
        end

      _ ->
        []
    end)
    |> MapSet.new()
  end

  @doc """
  Whether `node` is a reference to the variable named `var`.

  `{name, _, ctx}` where both atoms and `name == var`.
  """
  def var_ref?({name, _, ctx}, var) when is_atom(name) and is_atom(ctx), do: name == var
  def var_ref?(_, _), do: false

  defp any_short_subtoken?(string, whitelist) do
    string
    |> String.split("_", trim: true)
    |> Enum.any?(fn part ->
      cryptic_subtoken?(part) and not whitelisted_subtoken?(part, whitelist)
    end)
  end

  defp consonant_heavy?(part) do
    slots = part |> strip_plural_s() |> String.downcase() |> phoneme_slots()
    vowel_count = slots |> Enum.count(&vowel_slot?/1)

    cond do
      consonant_run_at_least?(slots, 3) -> true
      length(slots) == 4 and vowel_count <= 1 -> true
      true -> false
    end
  end

  @doc """
  Whether an underscore-separated subtoken reads as cryptic on its
  own — length ≤ 3 (`bi`, `cs`, `fb`) or consonant-heavy (`brnd`,
  `mngr`). Used to decide whether a name needs expanding and whether
  a candidate rename target is itself too short to be worth substituting.
  """
  def cryptic_subtoken?(part) do
    length = String.length(part)

    cond do
      length <= 3 -> true
      true -> consonant_heavy?(part)
    end
  end

  defp end_of_expression_line_get(nil, meta), do: meta |> Keyword.get(:line, 1)

  defp end_of_expression_line_get(eoe, meta),
    do: eoe |> Keyword.get(:line, Keyword.get(meta, :line, 1))

  defp has_closing_meta?({_, meta, _}) when is_list(meta) do
    Keyword.has_key?(meta, :closing)
  end

  defp has_closing_meta?(_), do: false

  defp inline_pipe(lhs, {fun, meta, args}) when is_atom(fun) and is_list(args) do
    {fun, meta, [lhs | args]}
  end

  defp inline_pipe(lhs, {{:., _, _} = dot, meta, args}) when is_list(args) do
    {dot, meta, [lhs | args]}
  end

  defp inline_pipe(lhs, {fun, meta, ctx}) when is_atom(fun) and is_atom(ctx) do
    {fun, meta, [lhs]}
  end

  defp inline_pipe(lhs, rhs), do: {:|>, [], [lhs, rhs]}

  defp plural_singular_in_whitelist?(part, whitelist) do
    cond do
      String.ends_with?(part, "ies") and String.length(part) > 3 ->
        singular = String.slice(part, 0..-4//1) <> "y"
        MapSet.member?(whitelist, String.to_atom(singular))

      String.ends_with?(part, "s") and String.length(part) > 1 ->
        singular = String.slice(part, 0..-2//1)
        MapSet.member?(whitelist, String.to_atom(singular))

      true ->
        false
    end
  end

  defp render_atom(nil), do: "nil"
  defp render_atom(true), do: "true"
  defp render_atom(false), do: "false"
  defp render_atom(atom) when is_atom(atom), do: ":" <> Atom.to_string(atom)
  defp render_atom_or_number(atom) when is_atom(atom), do: render_atom(atom)
  defp render_atom_or_number(n) when is_integer(n), do: Integer.to_string(n)
  defp render_atom_or_number(n) when is_float(n), do: Float.to_string(n)
  defp rightmost_is_boolish?({:__block__, _, [v]}) when v in [nil, true, false], do: true

  defp rightmost_is_boolish?({_op, meta, args})
       when is_list(meta) and is_list(args) and args != [] do
    # If this node has its own closing-bracket meta (e.g. a function
    # call `Keyword.get(opts, :ci, false)`), its end position already
    # accounts for the `)` — we must NOT recurse into its arguments
    # looking for a boolish leaf. Sourceror's range over-shoot only
    # affects bare boolish literals at the right edge.
    if Keyword.has_key?(meta, :closing) do
      false
    else
      rightmost_is_boolish?(List.last(args))
    end
  end

  defp rightmost_is_boolish?(_), do: false

  defp sanitize_identifier(str) when is_binary(str) do
    # Kebab-case atoms (`:"oz-fragment"`) translate cleanly to a
    # snake-case identifier — replace dashes with underscores. Any
    # other non-identifier char makes the string unusable.
    candidate = String.replace(str, "-", "_")

    cond do
      candidate == "" -> nil
      candidate in @reserved_words -> candidate <> "_"
      not Regex.match?(~r/\A[a-z_][a-zA-Z0-9_]*\z/, candidate) -> nil
      true -> candidate
    end
  end

  defp whitelisted_subtoken?(part, whitelist),
    do:
      MapSet.member?(whitelist, String.to_atom(part)) or
        plural_singular_in_whitelist?(part, whitelist)

  @consonant_digraphs ~w(th st ch sh ph ng nk ck)

  # Walk left to right collapsing recognized digraphs into single
  # slots; anything else stays as a one-grapheme slot.
  @doc """
  Promote the head subtoken to a past-participle form when:

  1. The tail's last subtoken actually got singularized (it carried
     a plural marker — so we have a "transformed plural → singular"
     shape, not a `render_node`-style noun phrase).
  2. The head's last subtoken is recognizably a **verb**, via either
     - a verb-shaped suffix (`-ize`, `-ate`, `-ify`, `-en`), or
     - explicit membership in `pp_verbs` (for verbs that don't carry
       a tell-tale suffix: `parse`, `fetch`, `merge`, `build`, ...).
  3. The head doesn't already look past-tense (no trailing `-ed`) —
     otherwise we'd produce nonsense like `indexed → indexeded`.

  Rationale: only verbal heads deserve PP promotion. `normalize_keys`
  → `normalized_key` (verb suffix `-ize`); `mass_deps` stays as
  `mass_deps` (`mass` is a noun, not a verb). `csv_attributes` stays
  (`csv` is an acronym/noun). `indexed_args` stays (already `-ed`).

  Returns `{:ok, "normalized"}` on success, `:skip` otherwise.
  """
  @spec maybe_past_participle([String.t()], [String.t()], String.t(), MapSet.t()) ::
          {:ok, String.t()} | :skip
  def maybe_past_participle(head, [tail_last], singularized, pp_verbs)
      when tail_last != singularized and head != [] do
    verb = List.last(head)

    cond do
      String.ends_with?(verb, "ed") -> :skip
      verb_shaped?(verb) -> {:ok, past_participle(verb)}
      MapSet.member?(pp_verbs, verb) -> maybe_past_participle_for_listed(verb)
      true -> :skip
    end
  end

  def maybe_past_participle(_head, _tail, _singularized, _pp_verbs), do: :skip

  @doc """
  Inverse of `singularize/1`, applied to the LAST subtoken of a
  snake_case compound. Mirrors the singularize rules 1:1 so a
  round-trip is the identity for the cases this module handles.

      "key"          → "keys"
      "entry"        → "entries"
      "class"        → "classes"
      "formula_builder" → "formula_builders"
  """
  @spec pluralize_compound(String.t()) :: String.t()
  def pluralize_compound(compound) do
    case String.split(compound, "_", trim: true) |> Enum.split(-1) do
      {head, [last]} ->
        (head ++ [pluralize_word(last)]) |> Enum.join("_")

      _ ->
        compound
    end
  end

  @doc """
  Pluralize a single word using rules that mirror `singularize/1`.

      "key"     → "keys"
      "entry"   → "entries"
      "class"   → "classes"
      "box"     → "boxes"
  """
  @spec pluralize_word(String.t()) :: String.t()
  def pluralize_word(word) do
    base = drop_bang_or_question(word)

    cond do
      String.ends_with?(base, "y") and not String.ends_with?(base, "ay") and
        not String.ends_with?(base, "ey") and not String.ends_with?(base, "iy") and
        not String.ends_with?(base, "oy") and not String.ends_with?(base, "uy") ->
        String.slice(base, 0..-2//1) <> "ies"

      String.ends_with?(base, "s") or String.ends_with?(base, "x") or
          String.ends_with?(base, "z") ->
        base <> "es"

      true ->
        base <> "s"
    end
  end

  @doc """
  Appends `suffix` to `name`, dealing with a trailing `?` or `!`
  marker safely.

  Two modes:

    * `:keep` — keeps the marker, placing it AFTER the suffix.
      Use when `name` is a function-name and the marker is
      semantically meaningful (`references_var?` → `references_var_shared?`).
    * `:drop` — discards the marker. Use when the output is a
      variable identifier or another context where `?`/`!` are
      nonsensical (`references_var?` → `references_var_shared`).

      iex> AstHelpers.safe_append_suffix("references_var?", "_shared", :keep)
      "references_var_shared?"

      iex> AstHelpers.safe_append_suffix("fetch_user!", "_shared", :drop)
      "fetch_user_shared"

      iex> AstHelpers.safe_append_suffix("emit", "_shared", :keep)
      "emit_shared"
  """
  @spec safe_append_suffix(String.t(), String.t(), :keep | :drop) :: String.t()
  def safe_append_suffix(name, suffix, mode) when mode in [:keep, :drop] do
    {base, marker} = pop_bang_or_question(name)

    case mode do
      :keep -> base <> suffix <> marker
      :drop -> base <> suffix
    end
  end

  @doc """
  Naive English singularization on a single word.

  Three rules cover most practical cases:

      ies → y               entries → entry
      sses/xes/zes →        classes → class, boxes → box, fizzes → fizz
      trailing s →          keys → key, items → item

  Words that don't follow these rules (children, feet, data, formulae)
  pass through unchanged. Words ≤ 2 chars also pass through.
  """
  @spec singularize(String.t()) :: String.t()
  def singularize(word) do
    base = drop_bang_or_question(word)

    cond do
      String.length(base) <= 2 ->
        base

      String.ends_with?(base, "ies") ->
        String.slice(base, 0..-4//1) <> "y"

      String.ends_with?(base, "sses") or String.ends_with?(base, "xes") or
          String.ends_with?(base, "zes") ->
        String.slice(base, 0..-3//1)

      String.ends_with?(base, "ss") ->
        base

      String.ends_with?(base, "s") ->
        String.slice(base, 0..-2//1)

      true ->
        base
    end
  end

  defp consonant_run_at_least?(slots, n) do
    slots
    |> Enum.reduce_while(0, fn slot, run ->
      cond do
        vowel_slot?(slot) -> {:cont, 0}
        run + 1 >= n -> {:halt, :found}
        true -> {:cont, run + 1}
      end
    end)
    |> Kernel.==(:found)
  end

  defp drop_bang_or_question(word), do: pop_bang_or_question(word) |> elem(0)

  defp maybe_past_participle_for_listed(verb) do
    if String.ends_with?(verb, "e"), do: {:ok, past_participle(verb)}, else: :skip
  end

  defp phoneme_slots(""), do: []

  defp phoneme_slots(stem),
    do: String.split_at(stem, 2) |> slots_with_leading_digraph_or_char(stem)

  defp pop_bang_or_question(word) do
    cond do
      String.ends_with?(word, "!") -> {String.slice(word, 0..-2//1), "!"}
      String.ends_with?(word, "?") -> {String.slice(word, 0..-2//1), "?"}
      true -> {word, ""}
    end
  end

  defp strip_plural_s(part) do
    cond do
      String.ends_with?(part, "ies") and String.length(part) > 3 ->
        String.slice(part, 0..-4//1) <> "y"

      String.ends_with?(part, "s") and String.length(part) > 1 ->
        String.slice(part, 0..-2//1)

      true ->
        part
    end
  end

  defp vowel_slot?(slot), do: slot in ~w(a e i o u y)

  # Suffix-based verb shape detector. Catches the regular verb-forming
  # suffixes in English. Deliberately conservative: we'd rather miss a
  # legitimate PP promotion than emit `csved_attribute` or `massed_dep`.
  @verb_suffixes ~w(ize ise ate ify en)

  @doc """
  Collect every variable name that gets *bound* by a pattern inside
  the given AST.

  Returns a `MapSet` of atom names. A variable is "bound" if it
  appears on the LHS of:

    * `=` match operator (`x = ...`, `{a, b} = ...`)
    * `case`/`cond`/`fn` clause heads (the LHS of `->`)
    * `with`/`for` generator (the LHS of `<-`)
    * struct/map/tuple/list patterns inside any of the above
      (e.g. `%S{} = f` binds `f`; `{:ok, user}` binds `user`)

  Bare-var **usages** (RHS positions, function-argument positions in
  calls, etc.) are NOT counted.

  Underscore-prefixed names (`_`, `_ignored`) are excluded —
  consistent with `bare_var/1`.

  This is the dual of `bare_var/1`: while `bare_var/1` answers
  "is this node a usage of a bare variable", `collect_bound_vars/1`
  answers "what variables does this AST introduce".
  """
  @spec collect_bound_vars(term()) :: MapSet.t(atom())
  def collect_bound_vars(ast) do
    {_, vars} =
      Macro.prewalk(ast, MapSet.new(), fn node, acc ->
        case node do
          # Match operator: LHS is a pattern, RHS is a value.
          {:=, _, [lhs, _rhs]} ->
            {node, collect_pattern_vars(lhs, acc)}

          # Generator (`<-`) in `with` / `for`: LHS is a pattern.
          {:<-, _, [lhs, _rhs]} ->
            {node, collect_pattern_vars(lhs, acc)}

          # Clause head (`->`): LHS list is a tuple of patterns
          # (could be guarded via `when`).
          {:->, _, [lhs_args, _body]} when is_list(lhs_args) ->
            acc =
              lhs_args |> Enum.reduce(acc, fn arg, a -> collect_pattern_vars(arg, a) end)

            {node, acc}

          _ ->
            {node, acc}
        end
      end)

    vars
  end

  @doc """
  Latch-match a short string against a snake_case compound's subtokens.

  Tries each subtoken position as the latch start. For each candidate:

  1. Greedy phase: consume short chars while each one matches the
     INITIAL of the next subtoken. The first subtoken's initial must
     match (otherwise no latch).
  2. Subsequence phase: any remaining short chars must appear as an
     in-order subsequence in the REST of the LAST greedily-consumed
     subtoken — not in following subtokens, because that would mean
     jumping into a new word without hitting its start.

  Tie-break: prefer the match with the most subtoken-starts hit; on
  equal start-count, prefer the latest start (leaves a non-empty head
  available for past-participle promotion).

  Returns `{:ok, start_idx, starts_hit}` where `start_idx` is the
  subtoken index where the latch started and `starts_hit` is the number
  of subtoken initials successfully consumed (≥ 1). Returns `:error`
  when no latch position produces a match.

  ## Examples

      iex> AstHelpers.latch_match("bi", ~w(build brand item))
      {:ok, 1, 2}

      iex> AstHelpers.latch_match("cs", ~w(build changeset))
      {:ok, 1, 1}

      iex> AstHelpers.latch_match("xyz", ~w(build changeset))
      :error
  """
  @spec latch_match(String.t(), [String.t()]) :: {:ok, non_neg_integer(), pos_integer()} | :error
  def latch_match(short, subtokens) when is_binary(short) and is_list(subtokens) do
    short_chars = String.graphemes(short)

    case short_chars do
      [] ->
        :error

      _ ->
        candidates =
          0..(length(subtokens) - 1)
          |> Enum.flat_map(fn idx ->
            case latch_try_at(short_chars, subtokens, idx) do
              {:ok, starts_hit} -> [{idx, starts_hit}]
              :error -> []
            end
          end)

        case candidates do
          [] ->
            :error

          _ ->
            {idx, starts_hit} =
              candidates |> Enum.max_by(fn {idx, starts_hit} -> {starts_hit, idx} end)

            {:ok, idx, starts_hit}
        end
    end
  end

  @doc """
  Regular-English past participle:

      "normalize" → "normalized"   (-e → +d)
      "parse"     → "parsed"
      "apply"     → "applied"       (consonant + y → -y +ied)
      "render"    → "rendered"      (default: +ed)
  """
  @spec past_participle(String.t()) :: String.t()
  def past_participle(verb) do
    cond do
      String.ends_with?(verb, "e") ->
        verb <> "d"

      String.ends_with?(verb, "y") and consonant_before_trailing_y?(verb) ->
        String.slice(verb, 0..-2//1) <> "ied"

      true ->
        verb <> "ed"
    end
  end

  @doc """
  Replace every literal leaf in `ast` with a positional placeholder, in
  a meta-stripped pass.

  Returns a normalized AST suitable for **skeleton hashing** — two
  Type-II clones (same shape, different literal values) collapse to the
  same `:erlang.phash2` result, while structurally different ASTs do
  not.

  Each literal leaf becomes `{:"$lit", [], [path]}` where `path` is the
  leaf's index in a pre-order walk. All other nodes have their meta
  reduced to `[]` so position information (line/column), Sourceror
  artifacts (`:closing`, `:token`, `:delimiter`, `:format`), and
  comments don't perturb the hash.

  ## What counts as a literal

  Sourceror wraps every literal leaf in `{:__block__, _, [value]}`
  where `value` is `is_atom`, `is_integer`, `is_float`, or `is_binary`
  (booleans and `nil` are atoms). Only those wrapped forms are
  hole'd — bare atoms inside non-`__block__` shells (e.g. the `:do`
  key of a keyword tuple, or a function name in a call head) are
  structural and stay untouched.

  ## What `path` is for

  The `path` is a stable per-leaf index. Two ASTs that differ only in
  literal *values* produce identical placeholder lists (same indices,
  same shape) and therefore identical hashes. Two ASTs that differ
  structurally — different number of leaves, different leaf positions
  in the walk — produce different placeholder shapes and different
  hashes.

  The path is *only* meaningful inside one normalized AST; never
  compare paths across trees.
  """
  @spec replace_literals_with_holes(term()) :: term()
  def replace_literals_with_holes(ast) do
    {result, _counter} =
      Macro.prewalk(ast, 0, fn node, idx ->
        case node do
          {:__block__, _meta, [value]}
          when is_atom(value) or is_integer(value) or
                 is_float(value) or is_binary(value) ->
            {{:"$lit", [], [idx]}, idx + 1}

          {form, meta, args} when is_list(meta) ->
            {{form, [], args}, idx}

          other ->
            {other, idx}
        end
      end)

    result
  end

  @doc """
  Resolve a synthesised name against an index of already-occupied names.

  `existing_index` maps `String.t() => payload` — payload is whatever
  the caller wants to inspect to decide structural equality (AST
  clauses, full source text, a struct, anything).

  ## Options

    * `:same?` — `(payload -> boolean)`. Called with the occupant's
      payload at each candidate slot. Returning `true` means the
      occupant is already what the refactor would emit, so the
      extraction is a no-op → result is `:skip`. Default: always
      returns `false` (no slot is ever a match; pure name dedupe).

    * `:on_collision` — `:suffix` (default) walks `_2`, `_3`, … until
      a free slot or a `same?` match. `:skip` returns `:skip`
      immediately on the first occupied slot — useful when a refactor
      can't disambiguate (HEEx component names) and prefers to drop
      the extraction over emitting a confusingly-suffixed identifier.

  Returns `{:ok, name}` for a free or distinct slot, `:skip` for a
  structural match or a `:skip`-mode collision.
  """
  @spec resolve_collision(String.t(), %{String.t() => any()}, keyword()) ::
          {:ok, String.t()} | :skip
  def resolve_collision(base_name, existing_index, opts \\ []) do
    same? = Keyword.get(opts, :same?, fn _ -> false end)
    on_collision = Keyword.get(opts, :on_collision, :suffix)

    walk_collision(base_name, base_name, 1, existing_index, same?, on_collision)
  end

  @doc """
  Decide which name a synthesised handler should take, given the
  module's `defp` index and the branches the refactor would emit.

  Wrapper around `resolve_collision/3` that flattens the `{name, arity}`
  keyed `defps_index` into a name → clauses map and supplies the
  AST-level structural-equality callback for `case`-clause helpers.

  - No existing helper with this name at any arity → use `base_name`.
  - Existing helper with this exact arity AND clauses match the
    extraction's branches one-for-one (modulo metadata) → `:skip`.
  - Existing helper but clauses differ (or different arity, even though
    Elixir would tolerate same-name/different-arity — we suffix anyway
    to keep the FIXME helper visually grouped) → walk `_2`, `_3`, …
    until a free slot or another structural match is found.

  `defps_index` shape: `%{{name_atom, arity} => [{head_ast, body_kw_ast}, ...]}`.

  `branches` is a list of `%{pattern, body, guard, free_vars,
  used_in_body}` maps. The per-branch `used_in_body` set lets us
  tolerate `_var` spellings on unused params in existing helpers.
  """
  @spec resolve_handler_name(String.t(), pos_integer(), [map()], [atom()], %{
          {atom(), pos_integer()} => list()
        }) ::
          {:ok, String.t()} | :skip
  def resolve_handler_name(base_name, arity, branches, free_vars, defps_index) do
    flat_index = flatten_defps_index(defps_index, arity)

    same? = fn clauses_at_correct_arity ->
      helpers_match?(clauses_at_correct_arity, branches, free_vars)
    end

    resolve_collision(base_name, flat_index, same?: same?)
  end

  @doc """
  Build a synthesised helper name from up to four snake_case fragments.

  Fragments in order: `prefix`, `host`, `scrutinee`, `suffix`. Each is
  split on `_`, empty strings filtered out, then folded into a single
  list with **overlap-merge** at every seam — if the tail of the
  accumulator equals the head of the next fragment, the overlap is
  taken only once. Overlap is checked longest-first.

      [a, b, c] ⊕ [b, c, d]  →  [a, b, c, d]
      [a]       ⊕ [a]        →  [a]
      [a, b]    ⊕ [c, d]     →  [a, b, c, d]

  ## Host-drop heuristic

  If `scrutinee` splits into **2 or more subtokens**, `host` is treated
  as redundant and dropped — the scrutinee already encodes the dispatch
  identity. `prefix` and `suffix` still merge with the scrutinee.

      synth_compound_name("handle", "host", "fetch_user_by_id", "")
      → "handle_fetch_user_by_id"

  Single-token scrutinees keep `host`:

      synth_compound_name("handle", "host", "fetch", "")
      → "handle_host_fetch"

  Inputs may be strings, atoms, or `nil`/`""` (treated as empty).
  Caller is responsible for stripping `?`/`!` suffixes that would
  otherwise terminate identifiers mid-name.
  """
  @spec synth_compound_name(
          String.t() | atom() | nil,
          String.t() | atom() | nil,
          String.t() | atom() | nil,
          String.t() | atom() | nil
        ) :: String.t()
  def synth_compound_name(prefix, host, scrutinee, suffix) do
    prefix_parts = to_subtokens(prefix)
    host_parts = to_subtokens(host)
    scrutinee_parts = to_subtokens(scrutinee)
    suffix_parts = to_subtokens(suffix)

    fragments =
      if length(scrutinee_parts) >= 2 do
        [prefix_parts, scrutinee_parts, suffix_parts]
      else
        [prefix_parts, host_parts, scrutinee_parts, suffix_parts]
      end

    fragments
    |> Enum.reject(&(&1 == []))
    |> Enum.reduce([], &overlap_merge(&2, &1))
    |> Enum.join("_")
  end

  defp args_or_empty({_name, args}), do: {args, nil}
  defp args_or_empty(:error), do: {[], nil}
  defp args_or_empty_with_guard({_name, args}, guard), do: {args, guard}
  defp args_or_empty_with_guard(:error, guard), do: {[], guard}
  defp ast_eq?(a, b), do: strip_meta(a) == strip_meta(b)

  defp clause_matches?(head, body_kw, branch, free_vars) do
    {existing_args, existing_guard} = head_args_and_guard(head)

    with {:ok, existing_body} <- fetch_do_body(body_kw),
         %{body: body, guard: guard, pattern: pattern, used_in_body: used_in_body} <- branch,
         [scrutinee_arg | extra_args] <- existing_args,
         true <- length(extra_args) == length(free_vars),
         true <- ast_eq?(scrutinee_arg, pattern),
         true <- guards_eq?(existing_guard, guard),
         true <- extra_args_eq?(extra_args, free_vars, used_in_body),
         true <- ast_eq?(existing_body, body) do
      true
    else
      _ -> false
    end
  end

  defp collect_pattern_vars(pattern, acc) do
    Macro.prewalk(pattern, acc, fn
      # Strip `when`-guards: only the LHS of `when` is a pattern; the
      # RHS is a guard expression (uses, not binds).
      {:when, _, [inner_pat, _guard]}, a ->
        {nil, collect_pattern_vars(inner_pat, a)}

      # `pattern = var` (or vice versa): both sides are patterns.
      {:=, _, [l, r]}, a ->
        a = collect_pattern_vars(l, a)
        a = collect_pattern_vars(r, a)
        {nil, a}

      # Bare variable in pattern position: bind it.
      {name, _, ctx}, a when is_atom(name) and is_atom(ctx) ->
        case bare_var({name, [], ctx}) do
          {:ok, n} -> {nil, MapSet.put(a, n)}
          :skip -> {nil, a}
        end

      other, a ->
        {other, a}
    end)
    |> elem(1)
  end

  defp consonant?(""), do: false
  defp consonant?(ch), do: ch not in ~w(a e i o u y)

  defp consonant_before_trailing_y?(verb),
    do: String.slice(verb, -2..-2//1) |> consonant?()

  defp extra_args_eq?(extra_args, free_vars, used_in_body) do
    extra_args
    |> Enum.zip(free_vars)
    |> Enum.all?(fn {arg, var} ->
      case arg do
        {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
          name == var or
            (not MapSet.member?(used_in_body, var) and
               name == String.to_atom("_" <> Atom.to_string(var)))

        _ ->
          false
      end
    end)
  end

  defp fetch_do_body(keyword) do
    keyword
    |> Enum.find_value(:error, fn
      {{:__block__, _, [:do]}, value} -> {:ok, value}
      {:do, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp flatten_defps_index(defps_index, arity) do
    defps_index
    |> Map.keys()
    |> Enum.map(fn {name_atom, _arity} -> name_atom end)
    |> Enum.uniq()
    |> Map.new(fn name_atom ->
      {Atom.to_string(name_atom), Map.get(defps_index, {name_atom, arity}, [])}
    end)
  end

  defp guards_eq?(nil, nil), do: true
  defp guards_eq?(nil, _), do: false
  defp guards_eq?(_, nil), do: false
  defp guards_eq?(a, b), do: ast_eq?(a, b)

  defp head_args_and_guard({:when, _, [inner, guard]}),
    do: extract_fn_signature(inner) |> args_or_empty_with_guard(guard)

  defp head_args_and_guard(head),
    do: extract_fn_signature(head) |> args_or_empty()

  defp helpers_match?(existing_clauses, branches, _free_vars)
       when length(existing_clauses) != length(branches),
       do: false

  defp helpers_match?(existing_clauses, branches, free_vars) do
    existing_clauses
    |> Enum.zip(branches)
    |> Enum.all?(fn {{head, body_kw}, branch} ->
      clause_matches?(head, body_kw, branch, free_vars)
    end)
  end

  defp latch_consume_starts([], _subtokens, _next_idx, _last_sub, starts), do: {:ok, starts}

  defp latch_consume_starts([c | rest] = remaining, subtokens, next_idx, last_sub, starts) do
    next_sub = subtokens |> Enum.at(next_idx)

    cond do
      next_sub != nil and String.first(next_sub) == c ->
        latch_consume_starts(rest, subtokens, next_idx + 1, next_sub, starts + 1)

      true ->
        last_sub_rest = String.slice(last_sub, 1..-1//1)
        if subsequence?(remaining, last_sub_rest), do: {:ok, starts}, else: :error
    end
  end

  defp latch_try_at([first | rest], subtokens, idx) do
    sub = subtokens |> Enum.at(idx)

    if sub != nil and String.first(sub) == first do
      latch_consume_starts(rest, subtokens, idx + 1, sub, 1)
    else
      :error
    end
  end

  # Resolve the real top-level `lib/<dir>` for a namespace's first
  # segment. Prefer the layout the source files already live in; fall
  # back to `Macro.underscore` only when no source path reveals it.
  defp lib_top_dir(first_segment, source_paths) do
    case top_lib_dir_from_paths(source_paths) do
      {:ok, dir} -> dir
      :error -> Macro.underscore(first_segment)
    end
  end

  # The most common `lib/<dir>` top-level directory among the on-disk
  # source paths. Ties pick the first by Enum.max_by ordering; paths
  # not under any `lib/` segment are ignored.
  defp top_lib_dir_from_paths(source_paths) do
    source_paths
    |> Enum.map(&top_lib_dir_of_path/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.max_by(fn {_dir, count} -> count end, fn -> nil end)
    |> case do
      {dir, _count} -> {:ok, dir}
      nil -> :error
    end
  end

  # The directory immediately following the *last* `lib` segment in the
  # path. Handles both relative (`lib/codeqa/x.ex`) and absolute
  # (`/tmp/proj/lib/codeqa/x.ex`) paths, and a `write_root` that itself
  # contains a `lib` segment (last wins).
  defp top_lib_dir_of_path(path) do
    path
    |> Path.split()
    |> dir_after_last_lib()
  end

  defp dir_after_last_lib(segments) do
    segments
    |> Enum.with_index()
    |> Enum.filter(fn {seg, _i} -> seg == "lib" end)
    |> List.last()
    |> case do
      {_lib, i} -> Enum.at(segments, i + 1)
      nil -> nil
    end
  end

  defp module_name_underscored("Elixir." <> rest),
    do:
      rest
      |> String.split(".")
      |> List.last()
      |> Macro.underscore()

  defp module_name_underscored(_), do: nil
  defp name_from_atom_string("Elixir." <> _, v), do: v |> humanize_module()
  defp name_from_atom_string(str, _v), do: str |> sanitize_identifier()
  defp overlap_merge([], next), do: next
  defp overlap_merge(acc, []), do: acc

  defp overlap_merge(acc, next) do
    max_overlap = min(length(acc), length(next))

    overlap =
      max_overlap..1//-1
      |> Enum.find(0, fn n ->
        Enum.take(acc, -n) == Enum.take(next, n)
      end)

    acc ++ Enum.drop(next, overlap)
  end

  defp patch_for_range_or_nil(%{end: end_pos, start: start_pos}, node, opts, replacement) do
    end_pos =
      if Keyword.get(opts, :boolish_tail?, false) do
        clip_end_for_boolish_tail(node, end_pos)
      else
        end_pos
      end

    Patch.new(%{end: end_pos, start: start_pos}, replacement)
  end

  defp patch_for_range_or_nil(_, _node, _opts, _replacement), do: nil

  defp resolve_collision_step(
         :error,
         _attempt,
         _base_name,
         candidate,
         _existing_index,
         _on_collision,
         _same?
       ),
       do: {:ok, candidate}

  defp resolve_collision_step(
         {:ok, payload},
         attempt,
         base_name,
         _candidate,
         existing_index,
         on_collision,
         same?
       ) do
    if same?.(payload) do
      :skip
    else
      case on_collision do
        :skip ->
          :skip

        :suffix ->
          next_attempt = attempt + 1
          next = base_name <> "_" <> Integer.to_string(next_attempt)
          walk_collision(next, base_name, next_attempt, existing_index, same?, on_collision)
      end
    end
  end

  defp slice_or_error(%{end: end_pos, start: start_pos}, ast, source) do
    end_pos = clip_end_for_boolish_tail(ast, end_pos)
    {:ok, slice_source(source, start_pos, end_pos)}
  end

  defp slice_or_error(_, _ast, _source), do: :error

  defp slots_with_leading_digraph_or_char({digraph, rest}, _stem)
       when digraph in @consonant_digraphs do
    [digraph | phoneme_slots(rest)]
  end

  defp slots_with_leading_digraph_or_char(_, stem) do
    {head, rest} = String.split_at(stem, 1)
    [head | phoneme_slots(rest)]
  end

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp subsequence?([], _haystack), do: true
  defp subsequence?(_chars, ""), do: false

  defp subsequence?([c | rest], haystack) do
    case :binary.match(haystack, c) do
      :nomatch -> false
      {pos, _} -> subsequence?(rest, String.slice(haystack, (pos + 1)..-1//1))
    end
  end

  defp to_subtokens(nil), do: []
  defp to_subtokens(atom) when is_atom(atom), do: to_subtokens(Atom.to_string(atom))

  defp to_subtokens(str) when is_binary(str) do
    String.split(str, "_", trim: true)
  end

  defp verb_shaped?(word), do: @verb_suffixes |> Enum.any?(&String.ends_with?(word, &1))

  defp walk_collision(candidate, base_name, attempt, existing_index, same?, on_collision),
    do:
      Map.fetch(existing_index, candidate)
      |> resolve_collision_step(
        attempt,
        base_name,
        candidate,
        existing_index,
        on_collision,
        same?
      )
end
