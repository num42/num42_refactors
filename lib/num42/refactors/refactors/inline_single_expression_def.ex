defmodule Num42.Refactors.Refactors.InlineSingleExpressionDef do
  @moduledoc """
  Collapses `def`/`defp` bodies that contain exactly one expression
  into the `do:` keyword form.

      def foo(x, y) do
        bar(x, y)
      end
      ↓
      def foo(x, y), do: x |> bar(y)

      def reformat_after? do
        true
      end
      ↓
      def reformat_after?, do: true

  ## What we accept

  - `def` and `defp` only — `defmacro`/`defmacrop` are out of scope.
  - No `when`-guard on the head — guarded heads tend to grow long and
    look bad on a single line.
  - Body must be a **single expression**: either bare, or a
    `__block__` wrapping exactly one child.
  - Body shape determines how it's emitted:
    * Pipe (`a |> b() |> c()`) → emitted verbatim after `do:`.
    * Local call `bar(x, y)` (≥1 arg) → rewritten to a pipe
      `x |> bar(y)`.
    * Qualified call `Mod.fun(x, y, z)` (≥1 arg) → rewritten to a pipe
      `x |> Mod.fun(y, z)`.
    * 0-arity call `init()` / `Map.new()` → emitted inline (nothing
      to pipe with).
    * Literal-like (atom, integer, float, boolean, nil, string,
      list, tuple, map, struct, bare variable, `&capture/N`) →
      emitted inline.

  ## What we skip

  - Bodies that are or **contain** a special form anywhere inside:
    `case`, `cond`, `if`, `unless`, `with`, `try`, `for`, `fn`,
    `quote`, `receive`. These are `do/end` block constructs, and
    they don't survive the rewrite to `do:` form — the inner `do`
    reopens block syntax inside what's supposed to be a keyword-form
    body, and the formatter can't re-parse the result. The
    `&capture/N` shorthand is fine and still rewrites.
  - Bodies that are heredoc strings (`\"""...\"""`). Forcing them into
    `do:` form mangles the multi-line layout into a `\\n`-escaped
    one-liner. Single-line strings (`"hello"`) still rewrite.
  - Bodies that are a sigil call (`~H\"""...\"""`, `~S"..."`, ...).
    Multi-line sigils have the same heredoc problem; the formatter's
    parsing of the rewritten one-liner can also re-escape embedded
    interpolations and produce invalid syntax.
  - `def` heads with `rescue`/`catch`/`after`/`else` branches.
    Inlining only the `:do` arm would silently drop the others — a
    semantics-breaking rewrite.
  - Bodies with two or more statements.
  - Already in keyword `do:` form (idempotence).

  ## Idempotence

  The keyword `do:` form has `format: :keyword` on the `:do` block
  in Sourceror's AST and the outer `def` meta lacks `:do`/`:end`
  positions; we use that as the gate. After rewriting, a second pass
  finds the new shape and skips.
  """

  use Num42.Refactors.Refactor

  alias Sourceror.Patch

  @impl Num42.Refactors.Refactor
  def description, do: "Collapse single-expression def/defp body to `do:` form"

  @impl Num42.Refactors.Refactor
  def priority, do: 50

  @impl Num42.Refactors.Refactor
  def explanation do
    """
    A `def` whose body is a single expression doesn't need `do ... end`
    scaffolding. The keyword `do:` form puts the head and the body on
    one line, which makes one-liner helpers (delegations, literals,
    short pipes) read at a glance instead of requiring three lines of
    vertical space. For multi-arg calls we also rewrite to a pipe so
    the first argument leads — `x |> Map.put(:k, y)` is the common
    Elixir reading order for "transform x".
    """
  end

  @impl Num42.Refactors.Refactor
  def reformat_after?, do: true

  @impl Num42.Refactors.Refactor
  def transform(source, _opts), do: Sourceror.parse_string(source) |> apply_patches(source)

  defp build_patches(ast),
    do:
      ast
      |> Macro.prewalker()
      |> Enum.flat_map(&maybe_patch/1)

  defp maybe_patch({kind, meta, [head, body_kw]} = node)
       when kind in [:def, :defp] and is_list(body_kw) do
    with true <- block_form?(meta),
         false <- has_when_guard?(head),
         true <- only_do_branch?(body_kw),
         {:ok, body} <- fetch_do_body(body_kw),
         {:ok, single} <- single_expression(body),
         false <- heredoc_body?(body),
         false <- sigil_body?(single),
         false <- special_form?(single),
         false <- contains_block_construct?(single),
         false <- binding_macro_call?(single),
         {:ok, replacement} <- render_inline(kind, head, single) do
      [Patch.replace(node, replacement)]
    else
      _ -> []
    end
  end

  defp maybe_patch(_), do: []

  defp block_form?(meta) when is_list(meta) do
    Keyword.has_key?(meta, :do) or Keyword.has_key?(meta, :end)
  end

  defp block_form?(_), do: false

  defp has_when_guard?({:when, _, _}), do: true
  defp has_when_guard?(_), do: false

  # `def f do ... rescue ... end` parses as a body keyword with both
  # `:do` and `:rescue` keys (also `:catch`, `:after`, `:else`).
  # Inlining only the `:do` arm would silently drop the others — a
  # semantics-breaking rewrite. Only proceed when `:do` is the sole
  # branch.
  defp only_do_branch?(body_kw) do
    body_kw
    |> Enum.all?(fn
      {{:__block__, _, [:do]}, _} -> true
      {:do, _} -> true
      _ -> false
    end)
  end

  defp fetch_do_body(body_kw) do
    body_kw
    |> Enum.find_value(:error, fn
      {{:__block__, _, [:do]}, value} -> {:ok, value}
      {:do, value} -> {:ok, value}
      _ -> nil
    end)
    |> case do
      :error -> :error
      {:ok, _} = ok -> ok
    end
  end

  defp single_expression({:__block__, _, [single]}), do: {:ok, single}
  defp single_expression({:__block__, _, _}), do: :skip
  defp single_expression(other), do: {:ok, other}

  defp render_inline(kind, head, body) do
    head_text = Sourceror.to_string(head)
    body_text = render_body(body)
    {:ok, "#{kind} #{head_text}, do: #{body_text}"}
  end

  # Pipe stays as-is.
  defp render_body({:|>, _, _} = pipe), do: Sourceror.to_string(pipe)

  # Multi-arg local or qualified call → pipe the first arg.
  defp render_body({callee, meta, args} = call) when is_list(args) and args != [] do
    if pipeable_call?(call) do
      [first | rest] = args
      piped = {:|>, [], [first, {callee, meta, rest}]}
      Sourceror.to_string(piped)
    else
      Sourceror.to_string(call)
    end
  end

  defp render_body(other), do: Sourceror.to_string(other)

  # A "pipeable call" is a regular function/macro call where the
  # callee is either a bare local name or a `Module.fun` chain. We
  # explicitly exclude operators (which share AST shape with calls)
  # and special forms (case/cond/if/...).
  defp pipeable_call?({{:., _, [_callee, fun]}, _, _}) when is_atom(fun), do: true

  defp pipeable_call?({name, _, args}) when is_atom(name) and is_list(args) do
    not Macro.operator?(name, length(args)) and not special_form_name?(name)
  end

  defp pipeable_call?(_), do: false

  # `f(x in Source, ...)` — first arg is a binding form (Ecto's
  # `from(i in Item, where: …)`, custom query/comprehension macros).
  # The `in` is a binding operator the receiving macro introspects;
  # it does not survive any rewrite that pulls it out of the
  # argument list. Two ways the inline rewrite would corrupt it:
  #   - Pipe form: `(i in Item) |> from(where: …)` — pipe can't
  #     carry the binding through the macro's pattern match.
  #   - Keyword `do:` form: `def all, do: from(i in Item, …)` —
  #     parses, but multi-arg query macros tend to be multi-line
  #     and don't read well on one keyword line.
  # Either way the right call is to leave the whole def alone.
  defp binding_macro_call?({{:., _, [_, fun]}, _, [first | _]})
       when is_atom(fun),
       do: binding_first_arg?(first)

  defp binding_macro_call?({name, _, [first | _] = args})
       when is_atom(name) and is_list(args),
       do: binding_first_arg?(first)

  defp binding_macro_call?(_), do: false

  defp binding_first_arg?({:in, _, [_, _]}), do: true
  defp binding_first_arg?(_), do: false

  # Skip when the body is a heredoc-delimited string. Sourceror keeps the
  # delimiter in meta of the wrapping `__block__`; we check before
  # `single_expression/1` would strip that wrapper. Distinguishes
  # `"""..."""` (skip) from `"..."` (rewrite as `do: "..."`).
  defp heredoc_body?({:__block__, meta, [bin]}) when is_binary(bin) and is_list(meta) do
    Keyword.get(meta, :delimiter) == ~s(""")
  end

  defp heredoc_body?(_), do: false

  # Skip when the body is a sigil call (`~H"""..."""`, `~S"..."`, etc.).
  # Sourceror's `to_string` round-trips the sigil correctly, but the
  # post-format pass parses the rewritten source through
  # `Code.format_string!/2`, which mishandles complex sigil contents
  # inside a `do:` keyword (HEEx with embedded `#{}` interpolations
  # gets re-escaped). Sigils are also typically multi-line and don't
  # belong on a single `do:` line anyway.
  defp sigil_body?({sigil_name, _, [{:<<>>, _, _}, _modifiers]}) when is_atom(sigil_name) do
    sigil_name |> Atom.to_string() |> String.starts_with?("sigil_")
  end

  defp sigil_body?(_), do: false

  # A body contains a "block construct" when any sub-node is a `do/end`
  # special form: `fn`, `case`, `cond`, `if`, `unless`, `with`, `try`,
  # `receive`, `for`, `quote`. These shapes can appear inside a pipe
  # (e.g. `... |> case do ... end`) but they don't survive the rewrite
  # to `do:` form: the formatter can't re-parse a `do: ... case do
  # ... end` body, since `do:` is a keyword and the inner `do` reopens
  # block syntax. Skip the whole def in that case.
  defp contains_block_construct?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {name, _, _}
      when name in [:fn, :case, :cond, :if, :unless, :with, :try, :receive, :for, :quote] ->
        true

      _ ->
        false
    end)
  end

  defp special_form_name?(name),
    do:
      name in [
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
        :with,
        :__block__,
        :<<>>,
        :%{},
        :%,
        :{},
        :__aliases__
      ]

  defp apply_patches({:ok, ast}, source), do: build_patches(ast) |> patch_or_passthrough(source)

  defp apply_patches({:error, _}, source), do: source

  defp patch_or_passthrough([], source), do: source

  defp patch_or_passthrough(patches, source), do: source |> Sourceror.patch_string(patches)
end
