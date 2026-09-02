defmodule Number42.Refactors.Ex.ExtractStringBindingToAttribute do
  @moduledoc """
  Hoists an inline string binding into a `@module_attribute` named after
  the function it came from.

      defmodule M do
        defp on_apply_user_email_result(user) do
          info = "Ein Link wurde versendet."
          notify(user, info)
        end
      end
      ↓
      defmodule M do
        @apply_user_email_result_info_text "Ein Link wurde versendet."

        defp on_apply_user_email_result(user) do
          info = @apply_user_email_result_info_text
          notify(user, info)
        end
      end

  A user-facing string buried in a function body is invisible to anyone
  scanning the module for the copy it emits, and two clauses drift apart
  the moment one of them is edited. Lifting it to an attribute puts every
  such string at the top of the module under a name that says where it is
  used.

  ## Naming

  `<function name minus short segments>_<binding>_text` — segments of two
  characters or fewer (`on`, `do`, `to`) carry no meaning in the constant
  name and are dropped.

  ## Configuring `min_length`

      configured_modules: [
        {Number42.Refactors.Ex.ExtractStringBindingToAttribute, min_length: 30}
      ]

  ## Skip conditions

  - **Short strings** — below `min_length` (default `16`) the literal
    reads fine where it stands.
  - **Interpolation** — an interpolated string is built per call, not a
    constant.
  - **Name collisions** — a derived name that an attribute already uses,
    or that two clauses claim for different values, is left alone rather
    than suffixed: the second name would say the same thing as the first
    and no longer identify its site.
  - **Outside a function** — a binding with no enclosing `def` has no
    function name to borrow.
  - **Nested modules and quote bodies** — an attribute hoisted out of
    either resolves in the wrong module.

  ## Idempotence

  After the rewrite the right-hand side is `@name`, no longer a string
  literal, so the second pass finds no candidates.
  """

  use Number42.Refactors.Refactor

  alias Sourceror.Patch

  @default_min_length 16
  @short_segment_length 2

  @impl Number42.Refactors.Refactor
  def description, do: "Hoist an inline string binding into a function-named `@module_attribute`"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A string assigned inside a function body is copy that no reader finds
    by scanning the module, and duplicating it across clauses invites the
    two to drift. Naming it `@<function>_<binding>_text` gives the text
    one definition at the top of the module and keeps the call site
    readable.
    """
  end

  @impl Number42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    min_length = Keyword.get(opts, :min_length, @default_min_length)
    Sourceror.parse_string(source) |> apply_patches(source, min_length)
  end

  defp apply_patches({:ok, ast}, source, min_length),
    do: ast |> build_patches(min_length) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source, _min_length), do: source

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp build_patches(ast, min_length) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:defmodule, _, [_name, [{_do, body}]]} -> module_patches(body, min_length)
      _ -> []
    end)
  end

  defp module_patches(body, min_length) do
    exprs =
      body |> body_to_exprs() |> Enum.map(&prune_nested_modules/1) |> Enum.map(&prune_quotes/1)

    exprs
    |> Enum.flat_map(&candidates_in_function(&1, min_length))
    |> Enum.group_by(& &1.name)
    |> Enum.reject(fn {name, hits} -> collides?(name, hits, exprs) end)
    |> Enum.sort_by(fn {_name, hits} -> hits |> hd() |> position() end)
    |> emit_patches(exprs)
  end

  # Only a binding inside a `def`/`defp` can borrow that function's name,
  # so the walk starts at the definition rather than at every `=`.
  defp candidates_in_function({kind, _, [head, [{_do, body}]]}, min_length)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    case function_name(head) do
      {:ok, fn_name} -> body |> string_bindings(min_length) |> Enum.map(&named(&1, fn_name))
      :error -> []
    end
  end

  defp candidates_in_function(_expr, _min_length), do: []

  defp function_name({:when, _, [head | _]}), do: function_name(head)
  defp function_name({name, _, _args}) when is_atom(name), do: {:ok, name}
  defp function_name(_head), do: :error

  defp string_bindings(body, min_length) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:=, _, [{binding, _, ctx}, {:__block__, _, [text]} = node]}
      when is_atom(binding) and is_atom(ctx) and is_binary(text) ->
        hoistable_binding(binding, text, node, min_length)

      _ ->
        []
    end)
  end

  defp hoistable_binding(binding, text, node, min_length) do
    if String.length(text) >= min_length,
      do: [%{binding: binding, text: text, node: node}],
      else: []
  end

  defp named(candidate, fn_name),
    do: Map.put(candidate, :name, attribute_name(fn_name, candidate.binding))

  defp attribute_name(fn_name, binding) do
    fn_name
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.reject(&(String.length(&1) <= @short_segment_length))
    |> Kernel.++([Atom.to_string(binding), "text"])
    |> Enum.join("_")
  end

  # A name that means two things is worse than the inline literal it
  # would replace, so a clash with an existing attribute or between
  # clauses disagreeing on the value drops the whole group.
  defp collides?(name, hits, exprs) do
    name in existing_attribute_names(exprs) or
      hits |> Enum.map(& &1.text) |> Enum.uniq() |> length() > 1
  end

  defp existing_attribute_names(exprs) do
    exprs
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {:@, _, [{name, _, [_value]}]} when is_atom(name) -> [Atom.to_string(name)]
      _ -> []
    end)
  end

  defp prune_nested_modules(expr) do
    Macro.prewalk(expr, fn
      {:defmodule, _, _} -> {:__pruned__, [], nil}
      node -> node
    end)
  end

  # An attribute hoisted out of a quote body resolves at expansion time
  # in the calling module, where it does not exist.
  defp prune_quotes(expr) do
    Macro.prewalk(expr, fn
      {:quote, _, _} -> {:__pruned__, [], nil}
      node -> node
    end)
  end

  defp emit_patches([], _exprs), do: []

  defp emit_patches(groups, exprs),
    do: binding_patches(groups) ++ [attribute_block_patch(groups, exprs)]

  defp binding_patches(groups) do
    Enum.flat_map(groups, fn {name, hits} ->
      Enum.map(hits, fn %{node: node} -> Patch.replace(node, "@#{name}") end)
    end)
  end

  defp attribute_block_patch(groups, exprs) do
    line = exprs |> hd() |> line_of()

    text =
      Enum.map_join(groups, "\n", fn {name, [hit | _]} -> "@#{name} #{inspect(hit.text)}" end)

    range = %{start: [line: line, column: 1], end: [line: line, column: 1]}
    Patch.new(range, text <> "\n\n", false)
  end

  defp position(%{node: {_, meta, _}}),
    do: {Keyword.get(meta, :line, 0), Keyword.get(meta, :column, 0)}
end
