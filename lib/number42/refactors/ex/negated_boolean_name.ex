defmodule Number42.Refactors.Ex.NegatedBooleanName do
  @moduledoc """
  Renames awkwardly-negated local bindings to their positive antonym.

      defmodule M do
        def go(cs) do
          not_valid = cs.errors != []
          not_valid
        end
      end
      ↓
      defmodule M do
        def go(cs) do
          invalid = cs.errors != []
          invalid
        end
      end

  A binding named `not_<stem>` reads worse than the single-word
  antonym the language already has (`not_valid` → `invalid`,
  `not_enabled` → `disabled`). The rename patches the binding site and
  every reference of that name inside the same function clause body.

  ## How the new name is chosen

  Via `IdentifierExpansion.negate/2`:

  1. A project `known` override on the *full* binding name wins
     (`not_ready` → `pending`).
  2. Otherwise the `not_` prefix is stripped to the stem and the stem
     is negated. A *clean* antonym (one the antonym map supplies, e.g.
     `valid` → `invalid`) becomes the new name. A *synthetic* fallback
     (`negate("found")` → `not_found`, `negate("ready")` → `un_ready`)
     means there is no real antonym — the bare stem (`found`, `ready`)
     is used instead, which still removes the `not_` noise.

  ## Scope

  Only `=`-bindings introduced inside a `def`/`defp` body. Function
  parameters are out of scope — renaming a parameter is an API change
  and the caller's argument name is unrelated. References are renamed
  within the clause that binds them.

  ## Skip conditions

  - **No negated name.** The binding is not a `not_<stem>` form.
  - **No-op.** Stripping/negating produces the same name.
  - **Collision.** The target name is already bound or referenced as a
    free variable elsewhere in the same body — renaming would merge two
    distinct bindings.

  ## Idempotence

  After the rewrite the binding is the positive form, which no longer
  matches the `not_<stem>` candidate filter. A second pass finds
  nothing to rename.
  """

  use Number42.Refactors.Refactor

  alias Number42.Refactors.Analysis.IdentifierExpansion
  alias Sourceror.Patch

  @negation_prefixes ~w(not un in dis)

  @impl Number42.Refactors.Refactor
  def description, do: "Rename negated local bindings (`not_valid`) to their antonym (`invalid`)"

  @impl Number42.Refactors.Refactor
  def explanation do
    """
    A binding named `not_valid` double-encodes a negative: the reader
    parses `not`, then `valid`, then inverts. The language already has
    the word — `invalid`, `disabled`, `absent` — and a single positive
    token reads in one step. Stripping the `not_` noise (when no clean
    antonym exists) is the conservative fallback. Limited to local
    bindings so no public name or caller contract changes.
    """
  end

  @impl Number42.Refactors.Refactor
  def transform(source, opts) do
    known = Keyword.get(opts, :known, %{})

    Sourceror.parse_string(source) |> apply_patches(source, known)
  end

  @impl Number42.Refactors.Refactor
  def patches(ast, _source, opts) do
    known = Keyword.get(opts, :known, %{})
    build_patches(ast, known)
  end

  defp apply_patches({:ok, ast}, source, known),
    do: ast |> build_patches(known) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source, _known), do: source

  defp patch_or_passthrough([], source), do: source
  defp patch_or_passthrough(patches, source), do: Sourceror.patch_string(source, patches)

  defp build_patches(ast, known) do
    ast
    |> Macro.prewalker()
    |> Enum.flat_map(&clause_patches(&1, known))
  end

  defp clause_patches({kind, _, [head, body_kw]}, known)
       when def_kind?(kind) and is_list(body_kw) do
    {_name, params} = head |> strip_when() |> signature()
    body = Keyword.values(body_kw)
    param_names = collect_var_names(params)

    body
    |> renamable_bindings(known)
    |> reject_collisions(body, param_names)
    |> Enum.flat_map(&rename_patches(&1, body))
  end

  defp clause_patches(_, _), do: []

  defp signature({name, _, args}) when is_atom(name) and is_list(args), do: {name, args}
  defp signature({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {name, []}
  defp signature(_), do: {nil, []}

  defp strip_when({:when, _, [head | _]}), do: head
  defp strip_when(head), do: head

  # Bindings in the body whose name negates to a different name.
  # Returns `[{old_atom, new_atom}]`, deduped to the first occurrence.
  defp renamable_bindings(body, known) do
    body
    |> binding_names()
    |> Enum.flat_map(&rename_target(&1, known))
    |> Enum.uniq_by(fn {old, _new} -> old end)
  end

  defp binding_names(body) do
    body
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {:=, _, [lhs, _rhs]} -> collect_var_names([lhs])
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp rename_target(old_atom, known) do
    old = Atom.to_string(old_atom)

    case positive_name(old, known) do
      ^old -> []
      new -> [{old_atom, String.to_atom(new)}]
    end
  end

  # The positive form of a negated name, or the name itself when it is
  # not negated. Project `known` override on the full name wins.
  defp positive_name(old, known) when is_map_key(known, old), do: Map.fetch!(known, old)

  defp positive_name("not_" <> stem, _known) when stem != "" do
    case IdentifierExpansion.negate(stem) do
      synthetic when synthetic == "not_" <> stem -> stem
      antonym -> if clean_antonym?(antonym, stem), do: antonym, else: stem
    end
  end

  defp positive_name(old, _known), do: old

  # A clean antonym is a real word, not the morphological `<prefix>_<stem>`
  # fallback (`un_ready`, `dis_able`). Map antonyms (`invalid`,
  # `inactive`, `disabled`) carry no underscore seam and pass.
  defp clean_antonym?(antonym, stem) do
    not Enum.any?(@negation_prefixes, &(antonym == "#{&1}_#{stem}"))
  end

  # Drop renames whose target name already lives in the same body —
  # either as another binding or as a free reference. Merging two names
  # would change behaviour.
  defp reject_collisions(renames, body, param_names) do
    occupied =
      body
      |> Enum.reduce(MapSet.new(param_names), fn expr, acc ->
        MapSet.union(acc, used_var_names(expr))
      end)

    Enum.reject(renames, fn {_old, new} -> MapSet.member?(occupied, new) end)
  end

  defp rename_patches({old_atom, new_atom}, body) do
    new = Atom.to_string(new_atom)

    body
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(&var_node_patch(&1, old_atom, new))
  end

  defp var_node_patch({name, _meta, ctx} = node, name, new) when is_atom(ctx),
    do: [Patch.replace(node, new)]

  defp var_node_patch(_, _name, _new), do: []

  defp collect_var_names(ast) do
    ast
    |> List.wrap()
    |> Enum.flat_map(&Macro.prewalker/1)
    |> Enum.flat_map(fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> [name]
      _ -> []
    end)
    |> Enum.uniq()
  end
end
