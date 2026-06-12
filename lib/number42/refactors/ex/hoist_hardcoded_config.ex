defmodule Number42.Refactors.Ex.HoistHardcodedConfig do
  @moduledoc """
  Hoists inline configuration-shaped string literals — URLs, absolute
  filesystem paths — out of function bodies into a `@module_attribute`
  at the top of the module.

      defmodule Client do
        def call, do: get("https://api.example.com/v1")
      end
      ↓
      defmodule Client do
        @default_url "https://api.example.com/v1"

        def call, do: get(@default_url)
      end

  ## What counts as config-shaped

  - A URL: starts with `http://`, `https://`, `ftp://`, `ws://`.
  - An absolute filesystem path: starts with `/` (`/etc/...`,
    `/var/run/app.sock`, …).

  Plain strings, relative paths (`config/dev.exs`), and any other free
  text are left untouched.

  ## Naming

  The attribute name comes from `IdentifierExpansion.derive_constant_name/2`:
  a `key: "https://…"` keyword literal becomes `@key`; otherwise the name
  is derived from the value's content — `https://api.example.com/v1` ->
  `@api_example_v1_url`, `/etc/myapp/config.toml` ->
  `@etc_myapp_config_toml_path`. A literal with nothing nameable (a bare
  IP, all-numeric segments) derives a placeholder name and is left
  inline rather than hoisted under a meaningless `@default_*`. Every
  occurrence of the *same* literal collapses to a single attribute; two
  *distinct* literals that derive the *same* name don't get suffixed —
  the first is hoisted, the rest stay inline.

  ## What it deliberately does not do

  - It only hoists into a module attribute. It never generates
    `Application.get_env/2` runtime config — that's an architectural
    choice, not a mechanical rewrite.
  - It skips literals where a `@attribute` is not a valid substitution:
    guard expressions, function-head patterns, and the value of an
    existing module-attribute definition (so an already-hoisted literal
    is not hoisted again — the idempotence guarantee).
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @url_schemes ["http://", "https://", "ftp://", "ws://"]

  # Phoenix router/endpoint macros whose leading string argument is a
  # route pattern, not a config value.
  @router_dsl ~w(get post put patch delete options head live socket forward match resource resources)a

  @impl Number42.Refactors.Refactor
  def description, do: "Inline URL/absolute-path string literal -> @module_attribute"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A URL or absolute path buried in a function body is invisible config:
    it can't be overridden, it's easy to miss, and the same endpoint
    re-typed in three functions is three places to update. Lifting it
    into a single `@module_attribute` names the value, gathers it at the
    module top, and gives later runtime-config migrations one obvious
    seam. This rewrite only hoists into an attribute; promoting to
    `Application.get_env/2` stays a deliberate human decision.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)
  defp apply_patches({:error, _}, source), do: source

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp build_patches(ast), do: find_module(ast) |> patches_for_module()

  defp patches_for_module(nil), do: []

  defp patches_for_module({body_exprs, insert_line}) do
    existing = existing_attr_names(body_exprs)

    body_exprs
    |> collect_hoistables()
    |> assign_names(existing)
    |> emit_patches(insert_line)
  end

  # ---------------------------------------------------------------
  # Module shell — body expressions plus the line to insert at.
  # ---------------------------------------------------------------

  defp find_module({:defmodule, _, [_name, [{_do, body}]]}) do
    exprs = body_to_exprs(body)
    {prefix, _rest} = Enum.split_while(exprs, &prefix_node?/1)
    {exprs, insert_line(prefix, body)}
  end

  defp find_module(_), do: nil

  defp prefix_node?({:@, _, _}), do: true
  defp prefix_node?({:use, _, _}), do: true
  defp prefix_node?({:import, _, _}), do: true
  defp prefix_node?({:require, _, _}), do: true
  defp prefix_node?({:alias, _, _}), do: true
  defp prefix_node?({:behaviour, _, _}), do: true
  defp prefix_node?(_), do: false

  defp insert_line([], {:__block__, _, [first | _]}), do: line_of(first)
  defp insert_line([], single), do: line_of(single)

  defp insert_line(prefix, _body),
    do: List.last(prefix) |> end_of_expression_line() |> Kernel.+(1)

  defp existing_attr_names(exprs) do
    exprs
    |> Enum.flat_map(fn
      {:@, _, [{name, _, [_value]}]} when is_atom(name) -> [Atom.to_string(name)]
      _ -> []
    end)
    |> MapSet.new()
  end

  # ---------------------------------------------------------------
  # Collection — context-aware walk yielding hoistable literals.
  # ---------------------------------------------------------------

  defp collect_hoistables(exprs), do: Enum.flat_map(exprs, &walk(&1, nil))

  # `@attr value` — the value is an attribute definition, never a
  # hoist site (idempotence: an already-hoisted literal stays put).
  defp walk({:@, _, [{name, _, [_value]}]}, _key) when is_atom(name), do: []

  # `def`/`defp`/`defmacro` head + body: the head is a pattern (skip),
  # only the body is walked.
  defp walk({def_kind, _, [_head, [{_do, body}]]}, _key) when def_or_macro_kind?(def_kind) do
    walk(body, nil)
  end

  # `when` guard: both sides are non-hoist contexts (guard + head).
  defp walk({:when, _, _}, _key), do: []

  # Quoted code targets another module; leave it alone.
  defp walk({:quote, _, _}, _key), do: []

  # Hoistable config literal.
  defp walk({:__block__, meta, [value]} = node, key) when is_binary(value) do
    if config_shaped?(value), do: [%{value: value, key: key, node: {node, meta}}], else: []
  end

  # `key: value` keyword pair — thread the key so the name can use it.
  defp walk({{:__block__, _, [key]}, value}, _key) when is_atom(key) do
    walk(value, Atom.to_string(key))
  end

  defp walk({left, right}, _key), do: walk(left, nil) ++ walk(right, nil)

  # Router/endpoint DSL call (`get "/path", …`, `socket "/path", …`): the
  # leading string is a route *pattern*, not config. Skip the first arg,
  # walk the rest — a real config literal in a later arg still hoists.
  defp walk({form, _meta, [route | rest]}, _key)
       when is_atom(form) and rest != [] do
    if router_dsl?(form), do: walk_args(rest), else: walk_args([route | rest])
  end

  defp walk({_form, _meta, args}, _key) when is_list(args), do: walk_args(args)
  defp walk(list, _key) when is_list(list), do: walk_args(list)
  defp walk(_leaf, _key), do: []

  defp walk_args(args), do: Enum.flat_map(args, &walk(&1, nil))

  # A bare scheme (`"http://"`) or root (`"/"`) is a string-matching
  # fragment, not a config value — both shapes require *content* before
  # they're worth hoisting: a host after `scheme://`, and a multi-segment
  # or extension-bearing body after the leading `/`.
  @url_regex ~r{\A[a-z][a-z0-9+.\-]*://[^\s]+\z}
  @path_regex ~r{\A/[^\s/]+(?:/[^\s/]+)+\z|\A/[^\s/]+\.[^\s/]+\z}

  defp config_shaped?(value),
    do: not route_pattern?(value) and (url?(value) or absolute_path?(value))

  defp url?(value),
    do: String.starts_with?(value, @url_schemes) and Regex.match?(@url_regex, value)

  defp absolute_path?(value), do: Regex.match?(@path_regex, value)

  defp router_dsl?(form), do: form in @router_dsl

  # A `:param` or `*glob` segment marks a route pattern, never a literal
  # config path — even outside a recognized DSL call.
  defp route_pattern?(value), do: value =~ ~r{/[:*]}

  # ---------------------------------------------------------------
  # Naming — one attribute per distinct value, collisions suffixed.
  # ---------------------------------------------------------------

  defp assign_names(hoistables, existing) do
    taken = Map.new(existing, &{&1, nil})

    hoistables
    |> Enum.group_by(& &1.value)
    |> Enum.sort_by(fn {_value, [%{node: {_n, meta}} | _]} -> Keyword.get(meta, :line, 0) end)
    |> Enum.reduce({[], taken}, &assign_group/2)
    |> elem(0)
    |> Enum.reverse()
  end

  @meaningless_names ~w(default_url default_string default_float constant)

  defp assign_group({value, occurrences}, {acc, taken}) do
    base = derive_constant_name(value, %{key: name_key(occurrences)})

    cond do
      base in @meaningless_names ->
        {acc, taken}

      true ->
        case resolve_collision(base, taken, on_collision: :skip) do
          {:ok, name} ->
            group = %{name: name, value: value, occurrences: occurrences}
            {[group | acc], Map.put(taken, name, nil)}

          :skip ->
            {acc, taken}
        end
    end
  end

  defp name_key(occurrences) do
    Enum.find_value(occurrences, fn %{key: key} -> key end)
  end

  # ---------------------------------------------------------------
  # Patches — one insert for all new attributes, replace every site.
  # ---------------------------------------------------------------

  defp emit_patches([], _insert_line), do: []

  defp emit_patches(groups, insert_line) do
    [insert_patch(groups, insert_line) | Enum.flat_map(groups, &replace_patches/1)]
  end

  defp insert_patch(groups, insert_line) do
    text = Enum.map_join(groups, "\n", &attr_definition/1) <> "\n"
    range = %{start: [line: insert_line, column: 1], end: [line: insert_line, column: 1]}
    Patch.new(range, text, false)
  end

  defp attr_definition(%{name: name, value: value}), do: ~s(@#{name} #{inspect(value)})

  defp replace_patches(%{name: name, occurrences: occurrences}) do
    Enum.map(occurrences, fn %{node: {node, _meta}} -> Patch.replace(node, "@#{name}") end)
  end
end
