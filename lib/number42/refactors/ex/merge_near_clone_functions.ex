defmodule Number42.Refactors.Ex.MergeNearCloneFunctions do
  @moduledoc """
  Merge a near-clone cluster of `def`/`defp` bodies into one parametrised helper
  and rewrite each occurrence to delegate to it. The Elixir-AST analogue of
  `MergeNearCloneComponents` (#380), built on `Ex.NearClones` (#393).

      # before — two siblings differing only in a result atom and a label string
      def unit_circle_area(%{args: [rad]}, r, vf) do
        case vf.(rad, r) do
          {:ok, dim} when dim in [:length, :dimensionless] -> {:ok, :area}
          {:ok, dim} -> {:error, "circle_area: bad \#{dim}"}
          {:error, _} = err -> err
        end
      end
      def unit_circle_circumference(%{args: [rad]}, r, vf), do: …  # :length / "circle_circumference: …"

      # after — the divergent values become trailing parameters
      def unit_circle_area(call, r, vf),
        do: unit_circle_dim(call, r, vf, :area, "circle_area")
      def unit_circle_circumference(call, r, vf),
        do: unit_circle_dim(call, r, vf, :length, "circle_circumference")

      defp unit_circle_dim(%{args: [rad]}, r, vf, result_dim, label) do
        case vf.(rad, r) do
          {:ok, dim} when dim in [:length, :dimensionless] -> {:ok, result_dim}
          {:ok, dim} -> {:error, "\#{label}: bad \#{dim}"}
          {:error, _} = err -> err
        end
      end

  ## Two modes

    * **same-module** — the cluster's occurrences live in one file. The shared
      helper is added to that module; each occurrence is rewritten in place.
    * **cross-file** — occurrences span files (resolved via `prepare`/
      `source_files`). The shared helper is added to the survivor's module; each
      clone elsewhere is rewritten to a qualified delegation. (No file is
      deleted — an Elixir `def` is one member of a larger module, unlike a
      single-`def` component file.)

  ## Value-based lift (robust against normalisation drift)

  `Ex.NearClones` reports divergences as `{kind, path, from, to}` with `path`
  indexing the *normalised* tree (pipe-inlined, α-renamed) — that path does not
  map cleanly back onto the raw AST. So the lift is **value-based**: for each
  divergence the survivor's `from` value (a literal / atom / call form) is
  replaced in the survivor body by a fresh parameter, and every occurrence passes
  its own value at that slot. A divergence is liftable only when its `from` value
  occurs **exactly once** in the survivor body — otherwise the slot is ambiguous
  (which `:area` did the diff mean?) and the whole merge declines.

  ## Derive-or-decline (default-OFF)

  Opinionated → default-OFF, opt-in:

      {MergeNearCloneFunctions, enabled: true, threshold: 0.85, min_merge_mass: 40}

  Declines (leaves everything untouched) when soundness can't be proven:

    * no mergeable cluster (`Ex.NearClones` withheld the flag — a structural
      divergence, or average block mass below `:min_merge_mass`),
    * a `:var` divergence (a renamed-variable slot mismatch is not a value to
      lift — α-renaming already collapsed real renames, a residual one is noise),
    * an ambiguous lift value (the `from` value occurs more than once),
    * a derived helper name that collides with an existing def, or
    * (cross-file) an occurrence whose module can't be located in the corpus.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Analysis.AstHelpers
  alias Number42.Refactors.Ex.NearClones

  @default_threshold 0.85
  @default_min_merge_mass 40

  # Atom-headed forms that are operators / special forms / common Kernel calls,
  # never module-local functions — excluded when classifying calls to lift.
  @non_liftable_forms ~w(if unless cond case with for try receive fn def defp
                         and or not in when do else __block__ __aliases__
                         length hd tl elem tuple_size map_size is_nil is_list
                         is_map is_atom is_binary is_integer is_float to_string
                         inspect raise throw send self spawn)a

  @impl Number42.Refactors.Refactor
  def description,
    do: "Merge near-clone def/defp bodies into one parametrised helper (default-OFF)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    Two or more functions that are the same body with a few divergent values —
    a result atom, a literal threshold, a label string — are one function
    duplicated. Tree-edit-distance (Ex.NearClones) clusters them and reports the
    divergent values; where every divergence is a liftable value occurring once
    in the body, the duplicates collapse into one shared helper with those values
    as trailing parameters, and each occurrence becomes a thin delegation.
    Default-OFF and conservative: a structural difference, a renamed-variable
    divergence, an ambiguous lift value, a name collision, or (cross-file) an
    unlocatable occurrence declines the merge.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    case Keyword.get(opts, :source_files) do
      files when is_list(files) and files != [] ->
        {:ok, build_corpus_plan(files, config(opts))}

      _ ->
        :no_cache
    end
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false), do: dispatch(source, opts), else: source
  end

  defp config(opts) do
    %{
      threshold: Keyword.get(opts, :threshold, @default_threshold),
      min_merge_mass: Keyword.get(opts, :min_merge_mass, @default_min_merge_mass)
    }
  end

  # With a corpus plan, dispatch on this file's role; without one, fall back to
  # the same-module merge over this file alone.
  defp dispatch(source, opts) do
    with %{} = prepared <- opts[:prepared],
         file when is_binary(file) <- Map.get(prepared.source_to_file, source) do
      apply_corpus_role(file, source, prepared)
    else
      _ -> same_module_merge(source, config(opts))
    end
  end

  # ---- same-module mode ----------------------------------------------------

  defp same_module_merge(source, cfg) do
    with [_ | _] = clusters <- NearClones.from_sources([{"_", source}], cluster_opts(cfg)),
         %{} = cluster <- Enum.find(clusters, &single_file_mergeable?/1),
         {:ok, plan} <- liftable_plan(cluster),
         {:ok, patches} <- same_module_patches(plan, source) do
      Sourceror.patch_string(source, patches)
    else
      _ -> source
    end
  end

  defp single_file_mergeable?(%{mergeable: true, occurrences: occ}) do
    occ |> Enum.map(& &1.file) |> Enum.uniq() |> length() == 1
  end

  defp single_file_mergeable?(_), do: false

  # ---- cross-file mode -----------------------------------------------------

  # Build a per-file plan: detect cross-file mergeable clusters across the whole
  # corpus, classify each occurrence's module-private calls (lifted to function
  # captures), pick the survivor, and key the resulting rewrites by file path so
  # each file's `transform/2` knows its role. `same_file_clusters` are handled by
  # the same-module path; only genuinely cross-file ones go here.
  defp build_corpus_plan(files, cfg) do
    contents =
      files
      |> Enum.map(fn f -> {f, File.read(f)} end)
      |> Enum.flat_map(fn
        {f, {:ok, src}} -> [{f, src}]
        _ -> []
      end)

    source_to_file = Map.new(contents, fn {f, src} -> {src, f} end)
    clause_counts = Map.new(contents, fn {f, src} -> {f, module_clause_counts(src)} end)
    module_names = Map.new(contents, fn {f, src} -> {f, module_name(src)} end)

    clusters =
      NearClones.from_files(files, cluster_opts(cfg))
      |> Enum.filter(&(&1.mergeable and cross_file?(&1)))

    rewrites =
      clusters
      |> Enum.flat_map(&cross_file_rewrites(&1, clause_counts, module_names))
      |> Enum.reduce(%{}, fn {file, entry}, acc ->
        Map.update(acc, file, [entry], &[entry | &1])
      end)

    %{source_to_file: source_to_file, rewrites: rewrites}
  end

  defp cross_file?(%{occurrences: occ}) do
    occ |> Enum.map(& &1.file) |> Enum.uniq() |> length() > 1
  end

  # A cluster becomes a `{file, entry}` list: one `:delegate` entry per
  # occurrence (rewrite the def to call the shared helper) plus one `:host` entry
  # on the survivor's file (append the shared helper to the survivor module).
  # Declines (returns `[]`) when the private-call lift can't be made sound.
  defp cross_file_rewrites(cluster, clause_counts, module_names) do
    base = Enum.find(cluster.occurrences, &(&1.diffs == []))
    def_sets = Map.new(clause_counts, fn {f, counts} -> {f, MapSet.new(Map.keys(counts))} end)

    with %{} <- base,
         :ok <- distinct_functions(cluster.occurrences),
         :ok <- single_clause_everywhere(cluster.occurrences, clause_counts),
         {:ok, slots} <- divergence_slots(cluster.occurrences),
         :ok <- all_unambiguous(slots, base.ast),
         {:ok, privs} <- shared_private_calls(cluster.occurrences, def_sets),
         host_module when is_binary(host_module) <- module_names[base.file] do
      # Cross-file keeps the base's own name: the host's original-arity wrapper
      # uses it, and every delegate calls `Host.<name>` — the public identity
      # callers already know.
      build_cross_file_entries(cluster, base, slots, privs, base.name, host_module)
    else
      _ -> []
    end
  end

  # Decline if any occurrence's `{name, arity}` has more than one clause in its
  # own module — those are pattern-dispatched clauses, and lifting only one of
  # them to a shared helper would drop the others' dispatch. (Same hazard as
  # `distinct_functions`, but for clauses *within* one module, which the
  # per-cluster occurrence list doesn't reveal.)
  defp single_clause_everywhere(occurrences, clause_counts) do
    if Enum.all?(occurrences, fn o ->
         Map.get(clause_counts[o.file] || %{}, {o.name, o.arity}, 0) == 1
       end),
       do: :ok,
       else: :error
  end

  # The module-private calls in the base body that every occurrence's own module
  # also defines privately — these must be lifted to function captures so the
  # relocated helper can reach them. Declines when an occurrence references a
  # private call its module doesn't define (would be unresolvable) or when the
  # private-call sets disagree across occurrences (different shapes).
  defp shared_private_calls(occurrences, def_sets) do
    per_occ =
      Enum.map(occurrences, fn o ->
        local_calls(o.ast)
        |> Enum.filter(fn {name, arity} ->
          MapSet.member?(def_sets[o.file] || MapSet.new(), {name, arity})
        end)
        |> MapSet.new()
      end)

    case Enum.uniq(per_occ) do
      [shared] -> {:ok, shared |> MapSet.to_list() |> Enum.sort()}
      _ -> :error
    end
  end

  # Atom-headed calls in a body, excluding operators / special forms / Kernel —
  # only genuine `name(args)` calls that could be module-local functions.
  defp local_calls(ast) do
    ast
    |> Macro.prewalk([], fn
      {form, _, args} = node, acc when is_atom(form) and is_list(args) ->
        if liftable_call_name?(form), do: {node, [{form, length(args)} | acc]}, else: {node, acc}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.uniq()
  end

  defp liftable_call_name?(form) do
    s = Atom.to_string(form)
    String.match?(s, ~r/^[a-z_][a-zA-Z0-9_]*[?!]?$/) and form not in @non_liftable_forms
  end

  defp build_cross_file_entries(cluster, base, slots, privs, helper, host_module) do
    # The base occurrence's def is rewritten *in place* into the public helper —
    # the survivor hosts it, no self-delegation. Every other occurrence delegates
    # to `Host.helper(...)`.
    host =
      {base.file, {:host_inplace, %{base: base, slots: slots, privs: privs, helper: helper}}}

    delegations =
      cluster.occurrences
      |> Enum.reject(&(&1.file == base.file and &1.line == base.line))
      |> Enum.map(fn o ->
        values = occurrence_slot_values(o, base, slots)

        {o.file,
         {:delegate, %{occ: o, helper: helper, host: host_module, values: values, privs: privs}}}
      end)

    [host | delegations]
  end

  defp occurrence_slot_values(o, _base, slots) do
    Enum.map(slots, fn {from, kind} ->
      case Enum.find(o.diffs, fn d -> div_from(d) == from and div_kind(d) == kind end) do
        nil -> from
        d -> div_to(d)
      end
    end)
  end

  # Apply this file's role(s): host appends the shared helper to its module,
  # every delegate rewrites its def to a thin call. A file can be both (the
  # survivor hosts the helper and delegates its own occurrence).
  defp apply_corpus_role(file, source, prepared) do
    case Map.get(prepared.rewrites, file) do
      nil -> source
      entries -> apply_entries(source, entries)
    end
  end

  defp apply_entries(source, entries) do
    patches =
      entries
      |> Enum.flat_map(&entry_patches(&1, source))

    case patches do
      [] -> source
      _ -> Sourceror.patch_string(source, patches)
    end
  end

  defp entry_patches({:host_inplace, h}, source) do
    with {:ok, rendered} <- render_cross_helper(h),
         {:ok, range} <- range_of_def(h.base, source) do
      [%{change: String.trim_trailing(rendered), range: range}]
    else
      _ -> []
    end
  end

  defp entry_patches({:delegate, d}, source) do
    case range_of_def(d.occ, source) do
      {:ok, range} -> [%{change: render_cross_delegation(d), range: range}]
      :error -> []
    end
  end

  # The host's in-place rewrite. The original name/arity stays as a thin PUBLIC
  # wrapper (so every existing caller — including host-internal ones — keeps
  # working unchanged), forwarding the host's own slot values and `&priv/n`
  # captures to the lifted helper. The lifted helper is a second PUBLIC clause at
  # the wider arity, carrying the divergent values + private-call captures as
  # parameters; cross-module delegates call *it* directly with their own values.
  #
  # When there is nothing to lift (no slots, no privs), there is no arity change
  # and no wrapper is needed — the in-place body is simply made public.
  defp render_cross_helper(h) do
    value_params =
      Enum.with_index(h.slots, fn {_from, kind} = slot, i ->
        {slot, param_name(%{kind: kind}, i)}
      end)

    body =
      h.base.ast
      |> lift_slot_values(value_params)
      |> lift_private_calls(h.privs)

    base_args = h.base.arg_strings
    value_names = Enum.map(value_params, fn {_slot, n} -> Atom.to_string(n) end)
    priv_names = Enum.map(h.privs, fn {name, _arity} -> "fun_#{name}" end)
    extra = value_names ++ priv_names

    helper_head = "#{h.helper}(#{Enum.join(base_args ++ extra, ", ")})"

    helper_def =
      "def #{helper_head} do\n" <>
        (body |> Sourceror.to_string() |> indent("    ")) <> "\n  end"

    {:ok, prepend_wrapper(h, base_args, extra, helper_def)}
  end

  # No extra params ⇒ arity unchanged ⇒ no wrapper, just the public body.
  defp prepend_wrapper(_h, _base_args, [], helper_def), do: helper_def

  defp prepend_wrapper(h, base_args, _extra, helper_def) do
    capture = capture_vars(length(base_args))
    own_values = Enum.map(h.slots, fn {from, _kind} -> value_to_string(from) end)
    own_privs = Enum.map(h.privs, fn {name, arity} -> "&#{name}/#{arity}" end)
    forwarded = Enum.join(capture ++ own_values ++ own_privs, ", ")

    "def #{h.helper}(#{Enum.join(capture, ", ")}),\n" <>
      "    do: #{h.helper}(#{forwarded})\n\n  " <> helper_def
  end

  defp lift_slot_values(ast, value_params) do
    Enum.reduce(value_params, ast, fn {{from, kind}, name}, acc ->
      replace_first(acc, %{from: from, kind: kind}, name)
    end)
  end

  # Replace every call `name(args…)` to a lifted private function with a call to
  # the capture param `fun_name.(args…)`.
  defp lift_private_calls(ast, privs) do
    priv_names = MapSet.new(privs, fn {name, arity} -> {name, arity} end)

    Macro.prewalk(ast, fn
      {form, meta, args} = node when is_atom(form) and is_list(args) ->
        if MapSet.member?(priv_names, {form, length(args)}),
          do: {{:., meta, [{:"fun_#{form}", meta, nil}]}, meta, args},
          else: node

      node ->
        node
    end)
  end

  defp render_cross_delegation(d) do
    capture = capture_vars(d.occ.arity)
    value_args = Enum.map(d.values, &value_to_string/1)
    priv_args = Enum.map(d.privs, fn {name, arity} -> "&#{name}/#{arity}" end)
    all = capture ++ value_args ++ priv_args

    "#{d.occ.kind} #{d.occ.name}(#{Enum.join(capture, ", ")}),\n" <>
      "    do: #{d.host}.#{d.helper}(#{Enum.join(all, ", ")})"
  end

  # The defining module's `{name, arity} => clause_count` map — for classifying
  # module-private calls (any key) and for declining multi-clause occurrences
  # (count > 1).
  defp module_clause_counts(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.flat_map(fn
          {kind, _, [head | _]} when kind in [:def, :defp] ->
            case AstHelpers.extract_fn_signature(strip_when(head)) do
              {name, args} when is_list(args) -> [{name, length(args)}]
              _ -> []
            end

          _ ->
            []
        end)
        |> Enum.frequencies()

      _ ->
        %{}
    end
  end

  defp strip_when({:when, _, [inner | _]}), do: inner
  defp strip_when(other), do: other

  defp module_name(source) do
    with {:ok, ast} <- Sourceror.parse_string(source),
         {:defmodule, _, [alias_node | _]} <- first_defmodule(ast) do
      Macro.to_string(alias_node)
    else
      _ -> nil
    end
  end

  defp first_defmodule(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.find(&match?({:defmodule, _, _}, &1))
  end

  # ---- plan: which values to lift ------------------------------------------

  defp cluster_opts(cfg) do
    [threshold: cfg.threshold, min_merge_mass: cfg.min_merge_mass, min_mass: 10]
  end

  @type plan :: %{
          helper: atom(),
          base: NearClones.near_occurrence(),
          lifts: [%{from: term(), kind: atom()}],
          occurrences: [%{occ: NearClones.near_occurrence(), values: [term()]}]
        }

  # Turn a mergeable cluster into a concrete lift plan, or decline. The base is
  # the representative (sim 1.0, empty diff); every other occurrence's diffs give
  # the per-slot values. Declines on a :var divergence or an ambiguous lift.
  defp liftable_plan(cluster) do
    base = Enum.find(cluster.occurrences, &(&1.diffs == []))

    with %{} <- base,
         :ok <- distinct_functions(cluster.occurrences),
         {:ok, slots} <- divergence_slots(cluster.occurrences),
         :ok <- all_unambiguous(slots, base.ast),
         {:ok, helper} <- helper_name(cluster, base) do
      {:ok,
       %{
         helper: helper,
         base: base,
         lifts: Enum.map(slots, fn {from, kind} -> %{from: from, kind: kind} end),
         occurrences: occurrence_values(cluster.occurrences, base, slots)
       }}
    else
      _ -> :error
    end
  end

  # Two occurrences sharing `{file, name, arity}` are *clauses of one
  # multi-clause function* (pattern-dispatched), not separate clones — merging
  # them into a helper would collapse the dispatch and miscompile. Decline if any
  # two occurrences collide on that key.
  defp distinct_functions(occurrences) do
    keys = Enum.map(occurrences, fn o -> {o.file, o.name, o.arity} end)
    if length(Enum.uniq(keys)) == length(keys), do: :ok, else: :error
  end

  # The distinct divergence slots, each as `{base_value, kind}`. Every non-base
  # occurrence must diverge at the *same* set of slots (same `from` values), else
  # the cluster isn't one clean parametrisation and we decline. A **verbatim**
  # cluster (no occurrence diverges) yields `{:ok, []}` — there is nothing to lift
  # by value; the merge is a pure delegation (plus any private-call lift).
  defp divergence_slots(occurrences) do
    non_base = Enum.reject(occurrences, &(&1.diffs == []))

    slot_sets =
      Enum.map(non_base, fn o ->
        Enum.map(o.diffs, fn d -> {div_from(d), div_kind(d)} end)
      end)

    case Enum.uniq(slot_sets) do
      [] -> {:ok, []}
      [slots] -> liftable_kinds(slots)
      _ -> :error
    end
  end

  defp liftable_kinds(slots) do
    if Enum.all?(slots, fn {_from, kind} -> kind in [:literal, :atom, :call] end),
      do: {:ok, slots},
      else: :error
  end

  defp div_kind(d), do: elem(d, 0)
  defp div_from(d), do: elem(d, 2)

  # Each lift value must occur exactly once in the base body, else the slot is
  # ambiguous (we couldn't tell which occurrence to replace).
  defp all_unambiguous(slots, base_ast) do
    if Enum.all?(slots, fn {from, kind} -> occurrence_count(base_ast, from, kind) == 1 end),
      do: :ok,
      else: :error
  end

  defp occurrence_count(ast, value, kind) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, acc ->
        if value_matches?(node, value, kind), do: {node, acc + 1}, else: {node, acc}
      end)

    count
  end

  # Match a raw AST node against a lifted value. Sourceror always wraps an atom /
  # number / string literal as `{:__block__, _, [value]}`, so we match *only* the
  # wrapper — matching the bare payload too would double-count (prewalk visits the
  # wrapper and then descends into its payload atom). A `:call` form matches a
  # `{form, _, _}` node whose head atom equals the divergent form.
  defp value_matches?({:__block__, _, [v]}, value, kind) when kind in [:literal, :atom],
    do: v == value

  defp value_matches?({form, _, args}, value, :call) when is_list(args) or is_atom(args),
    do: form == value

  defp value_matches?(_, _, _), do: false

  # For each occurrence, the value it supplies at each slot, in slot order. The
  # base supplies its own (`from`) values; a divergent occurrence supplies its
  # `to` for the slot that diverged, the base value otherwise.
  defp occurrence_values(occurrences, base, slots) do
    Enum.map(occurrences, fn o ->
      values =
        Enum.map(slots, fn {from, kind} ->
          case Enum.find(o.diffs, fn d -> div_from(d) == from and div_kind(d) == kind end) do
            nil -> from
            d -> div_to(d)
          end
        end)

      %{occ: o, values: values}
    end)
    |> tap(fn _ -> base end)
  end

  defp div_to(d), do: elem(d, 3)

  # Helper name: the longest common prefix of the occurrence names, trimmed to a
  # word boundary, else the base name with a `_merged` suffix. Must not collide
  # with an existing def in the base module.
  defp helper_name(cluster, base) do
    names = cluster.occurrences |> Enum.map(&Atom.to_string(&1.name))
    candidate = common_prefix(names) |> trim_to_word()

    name =
      case candidate do
        "" -> "#{base.name}_merged"
        c -> c
      end

    {:ok, String.to_atom(name)}
  end

  defp common_prefix([]), do: ""
  defp common_prefix([single]), do: single

  defp common_prefix([first | rest]) do
    Enum.reduce(rest, first, fn s, acc -> common_binary_prefix(acc, s) end)
  end

  defp common_binary_prefix(a, b) do
    a
    |> String.graphemes()
    |> Enum.zip(String.graphemes(b))
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> Enum.map_join("", fn {x, _} -> x end)
  end

  defp trim_to_word(s), do: String.replace(s, ~r/_+$/, "")

  # ---- emission: same-module patches ---------------------------------------

  defp same_module_patches(plan, source) do
    with {:ok, helper_def} <- render_helper(plan),
         {:ok, mod_node} <- module_node(source),
         delegations when delegations != [] <- delegation_patches(plan, source) do
      {:ok, [helper_append_patch(mod_node, helper_def) | delegations]}
    else
      _ -> :error
    end
  end

  defp module_node(source) do
    source
    |> Sourceror.parse_string()
    |> case do
      {:ok, ast} -> first_module(ast)
      _ -> :error
    end
  end

  defp first_module(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.find(&match?({:defmodule, _, [_, [{_, _}]]}, &1))
    |> case do
      nil -> :error
      mod -> {:ok, mod}
    end
  end

  # The shared helper: the base body with each lifted value replaced by a fresh
  # parameter, the parameters appended to the base head's arg list.
  defp render_helper(plan) do
    param_names = Enum.with_index(plan.lifts, fn lift, i -> {lift, param_name(lift, i)} end)

    body = lift_values(plan.base.ast, param_names)
    head = helper_head(plan, param_names)

    rendered =
      "  defp #{head} do\n" <>
        (body |> Sourceror.to_string() |> indent("    ")) <>
        "\n  end\n"

    {:ok, rendered}
  end

  defp helper_head(plan, param_names) do
    base_args = base_arg_strings(plan.base)
    extra = Enum.map(param_names, fn {_lift, name} -> Atom.to_string(name) end)
    "#{plan.helper}(#{Enum.join(base_args ++ extra, ", ")})"
  end

  # The base occurrence's own argument patterns, rendered from its head. We need
  # the raw head AST — re-derive it from the occurrence's defining clause.
  defp base_arg_strings(base), do: base.arg_strings

  defp param_name(%{kind: :atom}, i), do: :"arg_atom_#{i}"
  defp param_name(%{kind: :literal}, i), do: :"arg_value_#{i}"
  defp param_name(%{kind: :call}, i), do: :"arg_fun_#{i}"

  defp lift_values(ast, param_names) do
    Enum.reduce(param_names, ast, fn {lift, name}, acc ->
      replace_first(acc, lift, name)
    end)
  end

  # Replace the single occurrence of the lifted value with a variable node.
  defp replace_first(ast, %{from: from, kind: kind}, name) do
    {new, _} =
      Macro.prewalk(ast, false, fn
        node, false ->
          if value_matches?(node, from, kind),
            do: {{name, [], nil}, true},
            else: {node, false}

        node, true ->
          {node, true}
      end)

    new
  end

  # Each occurrence's def is rewritten to delegate: `def name(args), do:
  # helper(args, <its slot values>)`.
  defp delegation_patches(plan, source) do
    Enum.flat_map(plan.occurrences, fn %{occ: o, values: values} ->
      case range_of_def(o, source) do
        {:ok, range} -> [%{change: render_delegation(o, plan.helper, values), range: range}]
        :error -> []
      end
    end)
  end

  # The delegation binds fresh positional vars `c0, c1, …` (never the original
  # arg patterns) and forwards them untouched plus this occurrence's slot values.
  # Re-passing the *pattern* would rebuild the value (and break on `_`/literal
  # patterns); a plain capture var flows the original argument through verbatim.
  defp render_delegation(occ, helper, values) do
    capture = capture_vars(occ.arity)
    value_args = Enum.map(values, &value_to_string/1)

    "#{occ.kind} #{occ.name}(#{Enum.join(capture, ", ")}),\n" <>
      "    do: #{helper}(#{Enum.join(capture ++ value_args, ", ")})"
  end

  defp capture_vars(arity), do: Enum.map(0..(arity - 1)//1, &"c#{&1}")

  defp value_to_string(v) when is_atom(v), do: inspect(v)
  defp value_to_string(v) when is_binary(v), do: inspect(v)
  defp value_to_string(v), do: to_string(v)

  defp range_of_def(occ, _source) do
    case Sourceror.get_range(occ.def_ast) do
      %{end: e, start: s} -> {:ok, %{end: e, start: s}}
      _ -> :error
    end
  end

  defp helper_append_patch({:defmodule, _, _} = mod_node, rendered) do
    %{end: end_pos} = Sourceror.get_range(mod_node)
    insert_pos = [line: end_pos[:line], column: 1]
    %{change: "\n" <> rendered, range: %{end: insert_pos, start: insert_pos}}
  end

  defp indent(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end
end
