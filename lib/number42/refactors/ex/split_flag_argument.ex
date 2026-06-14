defmodule Number42.Refactors.Ex.SplitFlagArgument do
  @moduledoc """
  Split a function whose behaviour is gated by a boolean (or small-enum)
  flag parameter into separately-named functions, and rewrite every call
  site that passes a *literal* flag. Classic Fowler "Remove Flag
  Argument".

      # before
      def render(data, compact \\\\ false) do
        if compact, do: render_compact(data), else: render_full(data)
      end
      # call sites: render(x, true) / render(x, false) / render(x)
      #
      # after
      def render_compact(data), do: render_compact(data)   # branch bodies moved in
      def render_full(data), do: render_full(data)
      # call sites: render(x, true) -> render_compact(x)
      #             render(x, false) -> render_full(x)
      #             render(x)        -> render_full(x)   (default-implied)

  The rewrite is trivial; the hard part is proving the parameter is a
  genuine behaviour-switching flag **and** that the call sites can be
  rewritten without leaving a half-renamed (non-compiling) call graph.

  ## Detection (all must hold, else skip)

  A parameter `p` of a single-clause `def`/`defp` is a flag only when:

    1. The clause body is **exactly one** top-level `if`/`case` whose
       discriminant is the bare variable `p` and nothing else — no
       statements before or after it.
    2. `p` is used **solely** as that discriminant: it appears nowhere in
       any branch body, is never passed onward, stored, or combined into
       an expression. If splitting would change more than the name, skip.
    3. The branch is **exhaustive and exclusive** on `p`'s value domain:

         * bool — an `if p` (the `true`/`false` arms) or a
           `case p do true -> ...; false -> ... end`.
         * small enum — a `case p do :a -> ...; :b -> ...; :c -> ... end`
           over 2..#{4} distinct atom literals with **no** `_` /
           variable / `true` fall-through arm (a catch-all arm handles
           values the named split can't enumerate → not a clean split).

    4. `p` is the function's **last** declared parameter and a plain
       bare variable (no pattern, no guard reference). The default (if
       any) must be a literal in `p`'s domain.

  ## Call-site strategy — dispatcher-shim (option (b) from the issue)

  A clean split is worthless if the callers can't be rewritten. We use
  the *more useful* dispatcher-shim policy:

    * **Literal call sites** (`render(x, true)`) rewrite to the named
      split (`render_compact(x)`).
    * **Default-implied call sites** (`render(x)` when `p` has a default)
      rewrite to the default-branch function.
    * **Dynamic call sites** (`render(x, runtime_bool)` — a non-literal
      flag) and **unfindable** ones (`apply/3`, `&render/2` captures)
      **cannot** be statically named. Rather than skip the whole
      refactor, the original `render/N` is **kept as a thin dispatcher**
      that delegates to the splits, and only the literal/default sites
      are rewritten.

  When **every** call site is literal/default and no capture/apply names
  the function, the dispatcher is dropped entirely. Otherwise it stays —
  a deliberate **partial win**: the flag function survives, but every
  static caller now reads as an intent-named call.

  We never half-rewrite: either the original survives as a dispatcher
  delegating to the splits, or it is fully replaced and all sites are
  renamed. A call graph with some sites renamed and the flag function
  silently gone would not compile, so that state is unreachable.

  ## Cross-file context (`prepare/1`)

  Call sites of a public flag function can live in any file, so the
  call-graph completeness analysis must see the whole corpus. `prepare/1`
  reads every input source (`opts[:source_files]`, defaulting to the
  `.refactor.exs` `:inputs` glob), groups `defmodule` fragments by module
  name, and builds a per-module rewrite plan. `transform/2` looks up the
  plan for the module(s) in the file it is handed.

  Tests build the plan inline with `build_plan/1` over `[{path, source}]`
  tuples.

  ## Naming

  Each split is named `name_<intent>`:

    * bool — the `true` arm → `name_<intent>`, the `false` arm →
      `name_<intent>`. Intent is derived from the branch body's called
      helper (`render_compact(data)` → `compact`) when that yields a
      clean suffix; otherwise the literal flag value (`render_true` /
      `render_false`).
    * enum — `name_<atom>` per arm.

  If a derived name collides with an existing definition in the module
  (any arity) the split is abandoned for that function — a suffixed
  `_2` name would be a confusing split target. Skip and log instead.

  ## Idempotence

  After the rewrite the flag parameter is gone from the splits, the
  branch is gone, and literal/default call sites name the splits. A
  second pass finds no single-`if`/`case`-on-a-param function to split →
  no change. When a dispatcher is retained it still pattern-matches the
  flag, but its body is a flat delegation (no inner branch on the bare
  param in the splittable shape), so it is not re-split.

  ## Format

  `reformat_after?/0 == true` so the engine normalizes whitespace
  produced by the patches.

  ## Default-OFF (opt-in only)

  A structural refactor that rewrites call sites across files is never
  auto-on. `transform/2` is a no-op unless its own opts carry
  `enabled: true`. Enable per project once the call-graph completeness
  is trusted for that codebase:

      configured_modules: [
        {Number42.Refactors.Ex.SplitFlagArgument, enabled: true}
      ]
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @excluded_path_prefixes ["test/", "dev/"]

  # Upper bound on the number of atoms in a small-enum flag. Beyond this
  # a `case`-on-a-param is a dispatch table, not a flag, and splitting it
  # into N named functions is noise rather than a "remove flag" win.
  @max_enum_values 4

  @typedoc """
  One eligible flag-function split within a module.

    * `name`/`arity` — the flag function (original arity, before the
      param drop).
    * `pos` — zero-based position of the flag parameter (always the last).
    * `splits` — `[{value, split_name, body_ast}]`, one per flag value.
      `value` is the literal the call site passes (`true`/`false`/atom).
    * `default` — `{:ok, value}` when the flag param has a literal
      default, else `:none`.
    * `keep_dispatcher?` — whether the original `name/arity` must survive
      as a dispatcher (some caller is dynamic/unfindable).
    * `head_args` — the original head's argument ASTs, used to render the
      split heads and the dispatcher.
    * `kind` — `:def` or `:defp`.
  """
  @type split :: %{
          name: atom(),
          arity: arity(),
          pos: non_neg_integer(),
          splits: [{term(), atom(), Macro.t()}],
          default: {:ok, term()} | :none,
          keep_dispatcher?: boolean(),
          head_args: [Macro.t()],
          kind: :def | :defp
        }

  @doc """
  Build a rewrite plan from `[{path, source}]` tuples.

  Returns a map keyed by module atom; each value is the list of
  `t:split/0` rewrites for that module. Exposed so tests can build a
  plan without the engine.
  """
  @spec build_plan([{String.t(), String.t()}]) :: %{module() => [split()]}
  def build_plan(sources) do
    sources
    |> Enum.reject(fn {path, _src} -> excluded_path?(path) end)
    |> Enum.flat_map(&module_bodies/1)
    |> Enum.group_by(fn {module, _body} -> module end, fn {_module, body} -> body end)
    |> Enum.flat_map(fn {module, bodies} -> plan_for_module(module, List.flatten(bodies)) end)
    |> Enum.group_by(fn {module, _split} -> module end, fn {_module, split} -> split end)
  end

  @impl Number42.Refactors.Refactor
  def description,
    do: "Split a boolean/enum flag function into named functions + rewrite call sites"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A parameter used only to select one of a function's mutually
    exclusive branches is a flag argument — a named smell (Fowler,
    "Remove Flag Argument"). Splitting the function into one
    intent-named function per flag value removes the per-call branch and
    makes each call site state its intent. Literal and default-implied
    call sites are rewritten to the named splits; dynamic or unfindable
    callers keep the original as a thin dispatcher (partial win).
    Default-off: the cross-file call-site rewrite is only safe once the
    call-graph completeness is trusted for the codebase.
    """
  end

  @impl Number42.Refactors.Refactor
  def prepare(opts), do: Keyword.get(opts, :source_files) |> prepared_for_paths()

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      Keyword.get(opts, :prepared) |> rewrite_with_plan_or_passthrough(source)
    else
      source
    end
  end

  # ── prepare/1 plumbing ────────────────────────────────────────────

  defp prepared_for_paths(nil), do: load_default_sources() |> plan_from_sources()

  defp prepared_for_paths(paths) when is_list(paths) do
    sources = paths |> Enum.map(fn p -> {p, File.read!(p)} end)
    {:ok, build_plan(sources)}
  end

  defp plan_from_sources([]), do: :no_cache
  defp plan_from_sources(sources), do: {:ok, build_plan(sources)}

  defp load_default_sources, do: File.read(".refactor.exs") |> parse_inputs_from_config()

  defp parse_inputs_from_config({:ok, contents}) do
    {config, _} = Code.eval_string(contents)

    Map.get(config, :inputs, [])
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&excluded_path?/1)
    |> Enum.map(fn path -> {path, File.read!(path)} end)
  end

  defp parse_inputs_from_config(_), do: []

  defp excluded_path?(path) do
    normalized = String.trim_leading(path, "./")
    @excluded_path_prefixes |> Enum.any?(&String.starts_with?(normalized, &1))
  end

  defp module_bodies({_path, source}),
    do: Sourceror.parse_string(source) |> module_bodies_or_empty()

  defp module_bodies_or_empty({:ok, ast}) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        case alias_to_module(name_ast) do
          {:ok, module} -> [{module, body_to_exprs(body)}]
          :error -> []
        end

      _ ->
        []
    end)
  end

  defp module_bodies_or_empty({:error, _}), do: []

  # ── Eligibility analysis (per module) ─────────────────────────────

  defp plan_for_module(module, body_exprs) do
    existing_names = existing_def_names(body_exprs)

    body_exprs
    |> single_clause_groups()
    |> Enum.flat_map(fn {{kind, name, arity}, clause} ->
      case eligible_split(kind, name, arity, clause, body_exprs, existing_names) do
        {:ok, split} -> [{module, split}]
        :skip -> []
      end
    end)
  end

  # Group the def/defp clauses; only single-clause groups are candidates.
  # A multi-clause flag function is a different (harder) shape — skip.
  defp single_clause_groups(body_exprs) do
    body_exprs
    |> Enum.filter(&def_clause?/1)
    |> Enum.group_by(&clause_kind_name_arity/1)
    |> Enum.reject(fn {key, _} -> key == :skip end)
    |> Enum.flat_map(fn
      {key, [only]} -> [{key, only}]
      {_key, _many} -> []
    end)
  end

  defp def_clause?({kind, _, [_head | _]}) when kind in [:def, :defp], do: true
  defp def_clause?(_), do: false

  defp clause_kind_name_arity({kind, _, [head | _]}) do
    case strip_when(head) do
      {name, _, args} when is_atom(name) and is_list(args) -> {kind, name, length(args)}
      _ -> :skip
    end
  end

  defp eligible_split(kind, name, arity, clause, body_exprs, existing_names) do
    bodies = definition_bodies(body_exprs)

    with {:ok, head, body_kw} <- unguarded_head_body(clause),
         {:ok, head_args} <- plain_head_args(head),
         {:ok, pos, flag_var, default} <- flag_param(head_args),
         {:ok, body} <- single_branch_body(body_kw),
         {:ok, value_bodies} <- branch_on_var(body, flag_var),
         :ok <- check_not_self_delegating(name, value_bodies),
         :ok <- check_flag_used_only_as_discriminant(value_bodies, flag_var),
         {:ok, splits} <- name_splits(name, value_bodies, existing_names),
         :ok <- check_default_in_domain(default, value_bodies),
         keep? <- needs_dispatcher?(name, arity, bodies) do
      {:ok,
       %{
         arity: arity,
         default: default,
         head_args: head_args,
         keep_dispatcher?: keep?,
         kind: kind,
         name: name,
         pos: pos,
         splits: splits
       }}
    else
      _ -> :skip
    end
  end

  defp unguarded_head_body({_kind, _, [{:when, _, _}, _body_kw]}), do: :skip

  defp unguarded_head_body({_kind, _, [head, body_kw]}) when is_list(body_kw),
    do: {:ok, head, body_kw}

  defp unguarded_head_body(_), do: :skip

  # Every arg must be a plain var or a `var \\ default`. A pattern/struct
  # arg means the head can't be re-emitted as a flat split head safely.
  defp plain_head_args({_name, _, args}) when is_list(args) and args != [] do
    if Enum.all?(args, &plain_or_default_arg?/1), do: {:ok, args}, else: :skip
  end

  defp plain_head_args(_), do: :skip

  defp plain_or_default_arg?({:\\, _, [inner, _default]}), do: plain_var_arg?(inner)
  defp plain_or_default_arg?(other), do: plain_var_arg?(other)

  defp plain_var_arg?({name, _, ctx}) when is_atom(name) and is_atom(ctx),
    do: not underscore?(name)

  defp plain_var_arg?(_), do: false

  # The flag parameter must be the LAST declared argument (so dropping it
  # never shifts another argument's position) and a plain var, optionally
  # with a literal default.
  defp flag_param(args) do
    pos = length(args) - 1

    case List.last(args) do
      {:\\, _, [{name, _, ctx}, default]} when is_atom(name) and is_atom(ctx) ->
        {:ok, pos, name, {:ok, literal_value(default)}}

      {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
        {:ok, pos, name, :none}

      _ ->
        :skip
    end
  end

  defp single_branch_body(body_kw) do
    case fetch_do(body_kw) do
      {:ok, {:__block__, _, [single]}} -> {:ok, single}
      {:ok, {:__block__, _, _multiple}} -> :skip
      {:ok, expr} -> {:ok, expr}
      :error -> :skip
    end
  end

  # Recognize the branch and return `[{value, body}]` — exhaustive and
  # exclusive over the flag's domain.
  #
  #   if p, do: A, else: B           -> [{true, A}, {false, B}]
  #   case p do true -> A; false -> B end
  #   case p do :a -> A; :b -> B; ... end   (atoms only, no catch-all)
  defp branch_on_var({:if, _, [disc, kw]}, flag_var) when is_list(kw) do
    with true <- var_ref?(disc, flag_var),
         {:ok, do_body} <- fetch_do(kw),
         {:ok, else_body} <- fetch_else(kw) do
      {:ok, [{true, do_body}, {false, else_body}]}
    else
      _ -> :skip
    end
  end

  defp branch_on_var({:case, _, [disc, [{_do, clauses}]]}, flag_var) when is_list(clauses) do
    if var_ref?(disc, flag_var), do: case_value_bodies(clauses), else: :skip
  end

  defp branch_on_var(_, _), do: :skip

  defp case_value_bodies(clauses) do
    parsed = Enum.map(clauses, &clause_value_body/1)

    cond do
      Enum.any?(parsed, &(&1 == :skip)) -> :skip
      not exhaustive_exclusive?(parsed) -> :skip
      true -> {:ok, parsed}
    end
  end

  defp clause_value_body({:->, _, [[pattern], body]}) do
    case literal_pattern_value(pattern) do
      {:ok, value} -> {value, body}
      :error -> :skip
    end
  end

  defp clause_value_body(_), do: :skip

  # A `case` is a clean flag split when its clause values are either the
  # bool pair `{true, false}` or 2..@max_enum_values distinct atoms — and
  # there is no catch-all (`_`/var/`true`) arm, which `literal_pattern_value`
  # already rejects (those don't parse to a literal value).
  defp exhaustive_exclusive?(parsed) do
    values = Enum.map(parsed, fn {v, _} -> v end)

    cond do
      values != Enum.uniq(values) -> false
      bool_pair?(values) -> true
      atom_enum?(values) -> true
      true -> false
    end
  end

  defp bool_pair?(values), do: Enum.sort(values) == [false, true]

  defp atom_enum?(values) do
    length(values) in 2..@max_enum_values and
      Enum.all?(values, &(is_atom(&1) and &1 not in [true, false, nil]))
  end

  # Refuse a flag function whose every branch body bare-delegates to a
  # sibling named `name_<suffix>`. This is exactly the dispatcher shape
  # this refactor emits, so re-running on the output would oscillate
  # (`render` → `render_render_shrink` …) — refusing it is what makes the
  # rewrite idempotent.
  #
  # It also (deliberately) declines a *hand-written* flag function that
  # already delegates to `name_*`-shaped helpers (the issue's literal
  # `render_compact`/`render_full` example): that function is one rename
  # away from being split-ready, and "skip rather than guess" beats
  # emitting a confusingly self-similar split. A flag function delegating
  # to differently-named helpers (`shrink`/`expand`, `to_json`) splits
  # normally.
  defp check_not_self_delegating(name, value_bodies) do
    prefix = Atom.to_string(name) <> "_"

    self_delegating? =
      Enum.all?(value_bodies, fn {_value, body} ->
        case extract_call_name(unwrap_block(body)) do
          {:ok, called} -> String.starts_with?(Atom.to_string(called), prefix)
          :error -> false
        end
      end)

    if self_delegating?, do: :skip, else: :ok
  end

  # The flag var may appear ONLY as the discriminant (already consumed by
  # `branch_on_var`); it must not appear in any branch body.
  defp check_flag_used_only_as_discriminant(value_bodies, flag_var) do
    used? =
      value_bodies
      |> Enum.any?(fn {_value, body} -> MapSet.member?(used_var_names(body), flag_var) end)

    if used?, do: :skip, else: :ok
  end

  defp check_default_in_domain(:none, _value_bodies), do: :ok

  defp check_default_in_domain({:ok, value}, value_bodies) do
    domain = Enum.map(value_bodies, fn {v, _} -> v end)
    if value in domain, do: :ok, else: :skip
  end

  # ── Naming ────────────────────────────────────────────────────────

  defp name_splits(name, value_bodies, existing_names) do
    base = Atom.to_string(name)

    splits =
      Enum.map(value_bodies, fn {value, body} ->
        {value, split_name(base, value, body), body}
      end)

    split_names = Enum.map(splits, fn {_v, n, _b} -> n end)

    cond do
      split_names != Enum.uniq(split_names) -> :skip
      Enum.any?(split_names, &MapSet.member?(existing_names, &1)) -> :skip
      true -> {:ok, splits}
    end
  end

  # Name a split `base_<suffix>`.
  #
  #   * enum flag — the atom value IS the intent (`:json` → `emit_json`).
  #   * bool flag — `true`/`false` carry no intent, so derive the suffix
  #     from the branch body's called helper (`shrink(d)` →
  #     `render_shrink`); when the body is not a single bare call (no
  #     helper to name from), fall back to the value (`render_true`).
  #
  # Branch bodies that bare-delegate to a sibling `base_*` helper never
  # reach here — `check_not_self_delegating/2` skips them upstream — so
  # this cannot produce a self-recursive `render_render_*` name.
  defp split_name(base, value, _body) when is_atom(value) and value not in [true, false],
    do: String.to_atom(base <> "_" <> value_suffix(value))

  defp split_name(base, value, body) do
    case intent_from_body(body) do
      {:ok, suffix} -> String.to_atom(base <> "_" <> suffix)
      :none -> String.to_atom(base <> "_" <> value_suffix(value))
    end
  end

  defp intent_from_body(body) do
    case extract_call_name(unwrap_block(body)) do
      {:ok, called} -> {:ok, Atom.to_string(called)}
      :error -> :none
    end
  end

  defp value_suffix(true), do: "true"
  defp value_suffix(false), do: "false"
  defp value_suffix(atom) when is_atom(atom), do: Atom.to_string(atom)

  # ── Call-graph completeness ───────────────────────────────────────

  # The original must survive as a dispatcher when ANY caller can't be
  # statically rewritten to a named split: a non-literal flag argument, a
  # capture `&name/arity`, or an `apply/3` naming `name`.
  defp needs_dispatcher?(name, arity, bodies) do
    bodies
    |> Enum.any?(fn expr ->
      expr
      |> Macro.prewalker()
      |> Enum.any?(&unrewritable_site?(&1, name, arity))
    end)
  end

  defp unrewritable_site?({:&, _, [{:/, _, [{n, _, ctx}, cap_arity]}]}, name, arity)
       when is_atom(n) and is_atom(ctx) do
    n == name and literal_value(cap_arity) == arity
  end

  defp unrewritable_site?({:apply, _, [_mod, fn_name, _args]}, name, _arity),
    do: literal_value(fn_name) == name

  defp unrewritable_site?(
         {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [_m, fn_name, _a]},
         name,
         _arity
       ),
       do: literal_value(fn_name) == name

  # A direct call `name(args)` whose flag-position argument is NOT a
  # literal in the domain → dynamic → unrewritable.
  defp unrewritable_site?({n, _, args}, name, arity)
       when n == name and is_list(args) and length(args) == arity do
    flag_arg = List.last(args)
    not literal_in_any_domain?(flag_arg)
  end

  defp unrewritable_site?(_, _, _), do: false

  # A literal we could route to a split: a bool or a bare/wrapped atom.
  # (Domain membership is re-checked per split during rewrite.)
  defp literal_in_any_domain?(arg) do
    case literal_value(arg) do
      v when is_atom(v) and not is_nil(v) -> true
      _ -> false
    end
  end

  # ── Rewrite (per source/module) ───────────────────────────────────

  defp rewrite_with_plan_or_passthrough(nil, source), do: source
  defp rewrite_with_plan_or_passthrough(plan, source) when map_size(plan) == 0, do: source
  defp rewrite_with_plan_or_passthrough(plan, source), do: rewrite(plan, source)

  defp rewrite(plan, source),
    do: Sourceror.parse_string(source) |> apply_plan_to_parse_result(plan, source)

  defp apply_plan_to_parse_result({:ok, ast}, plan, source) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name_ast, [{_do, body}]]} ->
        patches_for_defmodule(name_ast, body, plan)

      _ ->
        []
    end)
    |> patch_or_passthrough(source)
  end

  defp apply_plan_to_parse_result({:error, _}, _plan, source), do: source

  defp patches_for_defmodule(name_ast, body, plan) do
    with {:ok, module} <- alias_to_module(name_ast),
         splits when is_list(splits) <- Map.get(plan, module) do
      patches_for_module(body_to_exprs(body), splits)
    else
      _ -> []
    end
  end

  defp patches_for_module(body_exprs, splits) do
    splits |> Enum.flat_map(&patches_for_split(body_exprs, &1))
  end

  defp patches_for_split(body_exprs, split) do
    def_patch(body_exprs, split) ++ call_site_patches(body_exprs, split)
  end

  # Replace the original flag function with the named splits, optionally
  # preceded by a retained dispatcher.
  #
  # Re-applying a stale plan (same `opts[:prepared]` over already-rewritten
  # source — what `assert_idempotent` and a single engine run with a
  # retained dispatcher exercise) must be a no-op. The dispatcher we emit
  # keeps the original `name/arity`, so a name/arity match alone would
  # re-replace it forever. We therefore only match a clause whose body is
  # still the *original* flag shape (a branch delegating to non-`name_*`
  # helpers), never the dispatcher we produce.
  defp def_patch(body_exprs, %{arity: arity, kind: kind, name: name} = split) do
    body_exprs
    |> Enum.filter(&original_clause?(&1, kind, name, arity))
    |> Enum.flat_map(&rewrite_original_clause(&1, split))
  end

  defp original_clause?({kind, _, [head, body_kw]}, kind, name, arity) when is_list(body_kw) do
    case strip_when(head) do
      {^name, _, args} when is_list(args) and length(args) == arity ->
        not already_dispatcher?(name, body_kw)

      _ ->
        false
    end
  end

  defp original_clause?(_, _, _, _), do: false

  # Is this clause body already the self-delegating dispatcher we emit?
  defp already_dispatcher?(name, body_kw) do
    with {:ok, body} <- single_branch_body(body_kw),
         {:ok, value_bodies} <- dispatcher_value_bodies(body) do
      check_not_self_delegating(name, value_bodies) == :skip
    else
      _ -> false
    end
  end

  # The arm bodies of a `case`, regardless of discriminant — we only care
  # whether they self-delegate, not which var they switch on.
  defp dispatcher_value_bodies({:case, _, [_disc, [{_do, clauses}]]}) when is_list(clauses) do
    parsed = Enum.map(clauses, &clause_value_body/1)
    if Enum.any?(parsed, &(&1 == :skip)), do: :skip, else: {:ok, parsed}
  end

  defp dispatcher_value_bodies(_), do: :skip

  defp rewrite_original_clause(node, split) do
    replacement =
      [dispatcher_source(split), split_sources(split)]
      |> List.flatten()
      |> Enum.join("\n\n")

    [Patch.replace(node, replacement)]
  end

  defp dispatcher_source(%{keep_dispatcher?: false}), do: []

  defp dispatcher_source(%{kind: kind, name: name, head_args: head_args, pos: pos} = split) do
    flag_name = flag_param_name(head_args, pos)
    other_arg_names = other_arg_names(head_args, pos)
    head = render_head(name, strip_default_args(head_args))

    arms =
      Enum.map_join(split.splits, "\n", fn {value, split_name, _body} ->
        call = render_call(split_name, other_arg_names)
        "    #{render_value(value)} -> #{call}"
      end)

    [
      """
      #{kind} #{head} do
        case #{flag_name} do
      #{arms}
        end
      end\
      """
    ]
  end

  defp split_sources(%{kind: kind, head_args: head_args, pos: pos, splits: splits}) do
    split_head_args = drop_at(head_args, pos) |> strip_default_args()

    Enum.map(splits, fn {_value, split_name, body} ->
      head = render_head(split_name, split_head_args)
      "#{kind} #{head} do\n  #{render(unwrap_block(body))}\nend"
    end)
  end

  # Rewrite literal + default-implied call sites of `name/arity` to the
  # matching split. Scanned over clause bodies only.
  defp call_site_patches(body_exprs, split) do
    body_exprs
    |> definition_bodies()
    |> Enum.flat_map(fn expr ->
      expr
      |> Macro.prewalker()
      |> Enum.flat_map(&call_site_patch(&1, split))
    end)
  end

  defp call_site_patch({n, meta, args} = node, %{arity: arity, name: name, pos: pos} = split)
       when n == name and is_list(args) and length(args) == arity do
    flag_arg = Enum.at(args, pos)

    case route_value(literal_value(flag_arg), split) do
      {:ok, split_name} ->
        replacement = {split_name, meta, drop_at(args, pos)}
        [Patch.replace(node, render(replacement))]

      :skip ->
        []
    end
  end

  # Default-implied call site `name(other_args)` at `arity - 1` when the
  # flag param has a default. Routes to the default-branch split.
  defp call_site_patch({n, meta, args} = node, %{arity: arity, name: name} = split)
       when n == name and is_list(args) and length(args) == arity - 1 do
    case split.default do
      {:ok, value} ->
        case route_value(value, split) do
          {:ok, split_name} -> [Patch.replace(node, render({split_name, meta, args}))]
          :skip -> []
        end

      :none ->
        []
    end
  end

  defp call_site_patch(_, _), do: []

  defp route_value(value, %{splits: splits}) when not is_nil(value) do
    Enum.find_value(splits, :skip, fn {v, split_name, _body} ->
      if v == value, do: {:ok, split_name}, else: nil
    end)
  end

  defp route_value(_value, _split), do: :skip

  # ── Rendering helpers ─────────────────────────────────────────────

  defp flag_param_name(head_args, pos) do
    head_args |> Enum.at(pos) |> arg_name()
  end

  defp other_arg_names(head_args, pos) do
    head_args |> drop_at(pos) |> Enum.map(&arg_name/1)
  end

  defp arg_name({:\\, _, [inner, _default]}), do: arg_name(inner)
  defp arg_name({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: name

  defp strip_default_args(args) do
    Enum.map(args, fn
      {:\\, _, [inner, _default]} -> inner
      other -> other
    end)
  end

  defp render_head(name, args) do
    arg_src = Enum.map_join(args, ", ", &render/1)
    "#{name}(#{arg_src})"
  end

  defp render_call(name, arg_names) do
    arg_src = Enum.map_join(arg_names, ", ", &Atom.to_string/1)
    "#{name}(#{arg_src})"
  end

  defp render_value(true), do: "true"
  defp render_value(false), do: "false"
  defp render_value(atom) when is_atom(atom), do: inspect(atom)

  defp render(ast), do: Sourceror.to_string(ast)

  # ── Shared utilities ──────────────────────────────────────────────

  defp existing_def_names(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {kind, _, [head | _]} when kind in [:def, :defp, :defmacro, :defmacrop] ->
        case strip_when(head) do
          {name, _, _} when is_atom(name) -> [name]
          _ -> []
        end

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp definition_bodies(body_exprs) do
    body_exprs
    |> Enum.flat_map(fn
      {kind, _, [_head, body_kw]} when kind in [:def, :defp] and is_list(body_kw) ->
        Keyword.values(body_kw)

      _ ->
        []
    end)
  end

  defp fetch_do(kw) do
    kw
    |> Enum.find_value(:error, fn
      {{:__block__, _, [:do]}, value} -> {:ok, value}
      {:do, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp fetch_else(kw) do
    kw
    |> Enum.find_value(:error, fn
      {{:__block__, _, [:else]}, value} -> {:ok, value}
      {:else, value} -> {:ok, value}
      _ -> nil
    end)
  end

  defp literal_pattern_value({:__block__, _, [value]})
       when is_atom(value) or is_integer(value),
       do: {:ok, value}

  defp literal_pattern_value(value) when is_atom(value) or is_integer(value), do: {:ok, value}
  defp literal_pattern_value(_), do: :error

  defp literal_value({:__block__, _, [value]}), do: value
  defp literal_value(value) when is_atom(value) or is_integer(value), do: value
  defp literal_value(_), do: nil

  defp drop_at(list, pos), do: List.delete_at(list, pos)

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)
end
