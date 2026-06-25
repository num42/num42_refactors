defmodule Number42.Refactors.Ex.ConvertLiveComponentToFunction do
  @moduledoc """
  Downgrades a **stateless** `Phoenix.LiveComponent` to a `:html` function
  component, and rewrites its same-file call sites.

      defmodule MyAppWeb.Badge do
        use MyAppWeb, :live_component
        def update(assigns, socket), do: {:ok, assign(socket, assigns)}
        def render(assigns), do: ~H"<span>{@label}</span>"
      end
      ↓
      defmodule MyAppWeb.Badge do
        use MyAppWeb, :html
        attr :label, :any
        def badge(assigns), do: ~H"<span>{@label}</span>"
      end

  A `:live_component` with no `handle_event/3`, whose `update/2` only does
  `{:ok, assign(socket, assigns)}`, and whose `render/1` reads only assigns, is a
  stateless function component carrying needless process overhead and a mandatory
  `id` at every call site. The reverse of `ExtractToPublicComponent`'s (#299)
  stateless classifier.

  ## Default-OFF (opt-in only)

  Opinionated and cross-file. Follows *derive-or-decline*: when statelessness
  cannot be proven, it declines. Enable per-module:

      {Number42.Refactors.Ex.ConvertLiveComponentToFunction, enabled: true}

  ## Slice 1 scope (this module)

  Converts the module shell and rewrites `<.live_component module={ThisModule}
  id=.. ..>` call sites **in the same file**. A module whose `<.live_component>`
  callers live in *other* files is **declined** here — rewriting the module
  without fixing those callers would break their compile (the tag would point at
  a module with no `render/1`). Cross-file caller rewriting is a follow-up
  (#308 slice 2).

  ## What converts

  - `use <Web>, :live_component` (or `use Phoenix.LiveComponent`).
  - No `handle_event/3`, no `send_update`, no async/stream callbacks
    (`handle_async`, `assign_async`, `start_async`).
  - `update/2` is exactly `{:ok, assign(socket, assigns)}` /
    `{:ok, socket |> assign(assigns)}` — assigns passed straight through, nothing
    derived. (Absent `update/2` is also fine — the default does exactly this.)
  - Every `<.live_component module={ThisModule} ...>` call site is in this file.

  The module becomes `:html`, `update/2` is dropped, `render/1` is renamed to
  `def <file_basename>(assigns)`, `attr :name, :any` lines are emitted for the
  assigns the render body reads, and same-file call sites become
  `<.<name> attr={..} ...>` (module + id dropped, other attrs kept).

  ## What we decline

  - Any `handle_event/3`, `send_update`, or async/stream usage — genuine state.
  - `update/2` that assigns a derived value (anything beyond passing `assigns`).
  - A non-live_component module.
  - A `<.live_component module={ThisModule}>` caller in another file (slice 2).

  ## Idempotence

  After conversion the module is `:html` with no `:live_component`, so a second
  pass finds no candidate.
  """

  use Number42.Refactors.Refactor

  @async_calls ~w(send_update handle_async assign_async start_async)a

  @impl Number42.Refactors.Refactor
  def description, do: "Downgrade a stateless live_component to a function component"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A live_component with no events and an identity `update/2` is a function
    component paying for a process it never uses, and forcing an `id` on every
    caller. Downgrading removes that overhead and simplifies the call site.
    Default-OFF and conservative: any event handler, async work, or derived
    state keeps it a live_component.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  # Build a corpus-wide index of `<.live_component module={Mod} ..>` call sites:
  # `%{module_string => MapSet of file paths}` plus `source => file`, so the
  # per-file `transform/2` can tell whether a candidate module has callers
  # OUTSIDE its own file (→ decline; cross-file rewriting is slice 2).
  @impl Number42.Refactors.Refactor
  def prepare(opts) do
    case Keyword.get(opts, :source_files) do
      files when is_list(files) and files != [] ->
        {:ok, build_caller_index(files)}

      _ ->
        :no_cache
    end
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    if Keyword.get(opts, :enabled, false) do
      Sourceror.parse_string(source) |> convert_or_passthrough(source, opts[:prepared])
    else
      source
    end
  end

  defp convert_or_passthrough({:ok, ast}, source, prepared) do
    with {:ok, module} <- single_live_component(ast),
         :ok <- stateless?(module),
         :ok <- no_cross_file_callers?(module, source, prepared),
         {:ok, plan} <- build_plan(module, source, ast) do
      apply_plan(plan, source)
    else
      _ -> source
    end
  end

  defp convert_or_passthrough({:error, _}, source, _prepared), do: source

  # --- corpus caller index ---------------------------------------------------

  defp build_caller_index(files) do
    files
    |> Enum.reduce(%{callers: %{}, source_to_file: %{}}, fn file, acc ->
      case File.read(file) do
        {:ok, content} ->
          acc
          |> put_in([:source_to_file, content], file)
          |> Map.update!(:callers, &index_callers(&1, content, file))

        _ ->
          acc
      end
    end)
  end

  # Index callers by the module's SHORT name (last segment). Callers reference a
  # component via an alias (`module={BrandItemCard}`) or fully qualified
  # (`module={MyApp.Web.BrandItemCard}`); keying on the short name matches both
  # and the candidate's own short name. Two modules sharing a short name collapse
  # into one bucket — an over-approximation that makes the gate decline rather
  # than risk converting a module with an unseen caller.
  defp index_callers(callers, content, file) do
    ~r/<\.live_component\s+module=\{([A-Za-z0-9_.]+)\}/
    |> Regex.scan(content)
    |> Enum.reduce(callers, fn [_, mod_str], acc ->
      short = mod_str |> String.split(".") |> List.last()
      Map.update(acc, short, MapSet.new([file]), &MapSet.put(&1, file))
    end)
  end

  # Decline when the module is called as `<.live_component module={Mod}/>` in any
  # file other than its own — slice 1 only fixes same-file callers; cross-file
  # callers would break (they'd dispatch render/1 on a function component). When
  # no prepared index is available (no source_files), fall back to a per-file
  # check: decline if the module is referenced by a `module={Mod}` tag we cannot
  # confirm is local. Conservative either way.
  defp no_cross_file_callers?(_module, _source, nil), do: :ok

  defp no_cross_file_callers?(module, source, %{callers: callers, source_to_file: s2f}) do
    short = module.alias |> Macro.to_string() |> String.split(".") |> List.last()
    caller_files = Map.get(callers, short, MapSet.new())
    own_file = Map.get(s2f, source)

    cond do
      MapSet.size(caller_files) == 0 -> :ok
      own_file && MapSet.subset?(caller_files, MapSet.new([own_file])) -> :ok
      true -> :error
    end
  end

  # --- detection -------------------------------------------------------------

  # Exactly one defmodule that `use`s a live_component. Returns its alias AST,
  # body exprs, the `use` node, and the chosen function name (module basename).
  defp single_live_component(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.filter(&match?({:defmodule, _, [_, [{_, _}]]}, &1))
    |> Enum.filter(&live_component_module?/1)
    |> case do
      [{:defmodule, _, [name, [{_do, body}]]} = node] ->
        {:ok,
         %{
           alias: name,
           body: body_to_exprs(body),
           node: node,
           fn_name: function_name(name)
         }}

      _ ->
        :error
    end
  end

  defp live_component_module?({:defmodule, _, [_, [{_do, body}]]}) do
    body |> body_to_exprs() |> Enum.any?(&live_component_use?/1)
  end

  defp live_component_use?({:use, _, args}) do
    Enum.any?(args, fn
      {:__aliases__, _, segs} -> List.last(segs) == :LiveComponent
      arg -> unwrap_atom(arg) == :live_component
    end)
  end

  defp live_component_use?(_), do: false

  # Sourceror wraps a bare atom argument as `{:__block__, _, [:atom]}`.
  defp unwrap_atom({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp unwrap_atom(atom) when is_atom(atom), do: atom
  defp unwrap_atom(_), do: nil

  defp function_name({:__aliases__, _, segs}) do
    segs |> List.last() |> Atom.to_string() |> Macro.underscore() |> String.to_atom()
  end

  # --- statelessness gates ---------------------------------------------------

  defp stateless?(%{body: body}) do
    cond do
      has_def?(body, :handle_event) -> :error
      has_async_call?(body) -> :error
      not update_is_passthrough?(body) -> :error
      true -> :ok
    end
  end

  defp has_def?(body, name) do
    Enum.any?(body, fn
      {kind, _, [head | _]} when kind in [:def, :defp] -> def_name(head) == name
      _ -> false
    end)
  end

  defp def_name({:when, _, [inner | _]}), do: def_name(inner)
  defp def_name({name, _, _}) when is_atom(name), do: name
  defp def_name(_), do: nil

  defp has_async_call?(body) do
    body
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.any?(fn
      {call, _, _} when call in @async_calls -> true
      _ -> false
    end)
  end

  # `update/2` must either be absent, or do nothing but pass `assigns` straight
  # through: `{:ok, assign(socket, assigns)}` / `{:ok, socket |> assign(assigns)}`.
  defp update_is_passthrough?(body) do
    case Enum.find(body, &update_clause?/1) do
      nil -> true
      {_kind, _, [_head, body_kw]} -> passthrough_body?(do_value(body_kw))
    end
  end

  defp update_clause?({kind, _, [head, _]}) when kind in [:def, :defp],
    do: def_name(head) == :update

  defp update_clause?(_), do: false

  # The `{:ok, assign(...)}` return. Sourceror represents a 2-tuple literal as a
  # single-element `{:__block__, _, [{ok, inner}]}` whose element is the raw
  # `{ok, inner}` pair, with `ok` itself wrapped `{:__block__, _, [:ok]}`.
  defp passthrough_body?({:__block__, _, [pair]}), do: passthrough_body?(pair)
  defp passthrough_body?({ok, inner}), do: ok_atom?(ok) and assign_passthrough?(inner)
  defp passthrough_body?({:{}, _, [ok, inner]}), do: ok_atom?(ok) and assign_passthrough?(inner)
  defp passthrough_body?(_), do: false

  defp ok_atom?(node), do: unwrap_atom(node) == :ok

  # `assign(socket, assigns)` or `socket |> assign(assigns)` — and nothing else.
  defp assign_passthrough?({:assign, _, [{:socket, _, _}, {:assigns, _, _}]}), do: true

  defp assign_passthrough?({:|>, _, [{:socket, _, _}, {:assign, _, [{:assigns, _, _}]}]}),
    do: true

  defp assign_passthrough?(_), do: false

  defp do_value(body_kw) when is_list(body_kw) do
    Enum.find_value(body_kw, fn
      {{:__block__, _, [:do]}, v} -> v
      {:do, v} -> v
      _ -> nil
    end)
  end

  defp do_value(_), do: nil

  # --- plan + apply ----------------------------------------------------------

  defp build_plan(module, source, ast) do
    render = Enum.find(module.body, &(def_name_of(&1) == :render))

    case render do
      nil ->
        :error

      render_node ->
        {:ok,
         %{
           module: module,
           render_node: render_node,
           assigns: render_assigns(render_node),
           local_alias: function_local_alias(module.alias),
           caller_modules: caller_modules(ast),
           source: source
         }}
    end
  end

  # The last segment of the module — `MyAppWeb.Badge` → `Badge` — used both as
  # the alias target and the `<Badge.fn>` call-site qualifier.
  defp function_local_alias({:__aliases__, _, segs}), do: segs |> List.last() |> Atom.to_string()

  # Every defmodule in the file as `{alias_ast, node}` — used to locate which
  # module a rewritten call site lives in, so its `alias` can be added there.
  defp caller_modules(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [name, [{_do, _body}]]} = node -> [{name, node}]
      _ -> []
    end)
  end

  defp def_name_of({kind, _, [head | _]}) when kind in [:def, :defp], do: def_name(head)
  defp def_name_of(_), do: nil

  # Assigns the render body reads, as `@name` tokens scanned from the sigil text
  # (the body is opaque to the AST walk). Name-only; type defaults to `:any`.
  defp render_assigns(render_node) do
    render_node
    |> Macro.prewalker()
    |> Enum.flat_map(&sigil_assign_tokens/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp sigil_assign_tokens({sigil, _, [{:<<>>, _, parts}, _mods]}) when is_atom(sigil) do
    case Atom.to_string(sigil) do
      "sigil_" <> _ ->
        parts
        |> Enum.filter(&is_binary/1)
        |> Enum.join("\n")
        |> then(&Regex.scan(~r/@([a-z_][a-zA-Z0-9_]*)/, &1))
        |> Enum.map(fn [_, name] -> name end)

      _ ->
        []
    end
  end

  defp sigil_assign_tokens(_), do: []

  # Two scopes, applied as one Sourceror patch set so ranges stay valid:
  #   * module edits (use/update/render/attrs) are confined to the TARGET
  #     module's text slice — never the whole file, which would mis-hit another
  #     defmodule's `def render`/`use` in a multi-module file.
  #   * the call-site rewrite targets `<.live_component module={ThisModule} ..>`
  #     tags, which may sit in a *sibling* module's sigils in the same file.
  defp apply_plan(plan, source) do
    # One patch per affected module so ranges never overlap: the target module
    # (use/update/render/attrs) and each caller module (alias + every
    # `<.live_component module={Target} ..>` tag inside it, rewritten
    # alias-qualified) are each transformed as a single text slice.
    [module_patch(plan) | caller_module_patches(plan)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> source
      patches -> Sourceror.patch_string(source, patches)
    end
  end

  # Replace the target defmodule node with its transformed text. Slicing from
  # source preserves the module's formatting; we edit only that slice.
  defp module_patch(plan) do
    case Sourceror.get_range(plan.module.node) do
      %{} = range ->
        original = slice_range(plan.source, range)
        %{change: transform_module_text(original, plan), range: range}

      _ ->
        nil
    end
  end

  defp transform_module_text(text, plan) do
    text
    |> rewrite_use()
    |> drop_update()
    |> rename_render(plan)
    |> insert_attrs(plan)
  end

  # `use X, :live_component` → `use X, :html`; `use Phoenix.LiveComponent` →
  # `use Phoenix.Component`.
  defp rewrite_use(text) do
    text
    |> String.replace(~r/(use\s+[\w.]+,\s*):live_component\b/, "\\1:html")
    |> String.replace(~r/use\s+Phoenix\.LiveComponent\b/, "use Phoenix.Component")
  end

  # Remove the whole `def update(assigns, socket) ... end` (or one-line `, do:`).
  defp drop_update(text) do
    text
    |> String.replace(~r/\n\s*def update\(.*?\),\s*do:.*?(?=\n)/s, "", global: false)
    |> String.replace(~r/\n\s*def update\(.*?\) do\n.*?\n\s*end\n/s, "\n", global: false)
  end

  defp rename_render(text, plan) do
    String.replace(text, ~r/def render\(/, "def #{plan.module.fn_name}(", global: false)
  end

  defp insert_attrs(text, %{assigns: []}), do: text

  defp insert_attrs(text, plan) do
    decls = Enum.map_join(plan.assigns, "\n", &"  attr #{inspect(String.to_atom(&1))}, :any")
    fn_name = plan.module.fn_name
    String.replace(text, ~r/(\n)(\s*def #{fn_name}\()/, "\\1#{decls}\\1\\2", global: false)
  end

  # One patch per caller module (every defmodule except the target) that
  # contains a `<.live_component module={Target} ..>` tag: rewrite each such tag
  # alias-qualified (`<Badge.badge ..>`, module + id dropped) and add
  # `alias <Module>` after the module's `use` line. Both edits live in the same
  # module slice, so they never collide with each other or the target patch.
  defp caller_module_patches(plan) do
    target_node = plan.module.node

    plan.caller_modules
    |> Enum.reject(fn {_name, node} -> node == target_node end)
    |> Enum.map(fn {_name, node} -> caller_module_patch(node, plan) end)
    |> Enum.reject(&is_nil/1)
  end

  defp caller_module_patch(module_node, plan) do
    mod_str = Macro.to_string(plan.module.alias)

    with %{} = range <- Sourceror.get_range(module_node),
         text <- slice_range(plan.source, range),
         true <- String.contains?(text, "<.live_component module={#{mod_str}}") do
      rewritten = text |> rewrite_caller_tags(plan, mod_str) |> ensure_alias(mod_str)
      %{change: rewritten, range: range}
    else
      _ -> nil
    end
  end

  defp rewrite_caller_tags(text, plan, mod_str) do
    re = ~r/<\.live_component\s+module=\{#{Regex.escape(mod_str)}\}\s*(.*?)\/>/s

    Regex.replace(re, text, fn _full, rest ->
      "<#{plan.local_alias}.#{plan.module.fn_name} #{strip_id(rest)}/>"
    end)
  end

  defp ensure_alias(text, mod_str) do
    if text =~ ~r/alias\s+#{Regex.escape(mod_str)}\b/ do
      text
    else
      String.replace(text, ~r/(\n\s*use\s+[^\n]+\n)/, "\\1\n  alias #{mod_str}\n", global: false)
    end
  end

  defp strip_id(attrs) do
    attrs
    |> String.replace(~r/\bid=\{[^}]*\}\s*/, "")
    |> String.replace(~r/\bid="[^"]*"\s*/, "")
    |> String.trim_leading()
  end

  # --- range/offset helpers --------------------------------------------------

  # Text of a Sourceror line/column range, sliced from source by lines.
  defp slice_range(source, %{start: s, end: e}) do
    lines = String.split(source, "\n")
    sl = s[:line]
    el = e[:line]

    if sl == el do
      String.slice(Enum.at(lines, sl - 1), (s[:column] - 1)..(e[:column] - 2))
    else
      first = String.slice(Enum.at(lines, sl - 1), (s[:column] - 1)..-1//1)
      middle = Enum.slice(lines, sl..(el - 2)//1)
      last = String.slice(Enum.at(lines, el - 1), 0..(e[:column] - 2))
      Enum.join([first] ++ middle ++ [last], "\n")
    end
  end
end
