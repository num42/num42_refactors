defmodule Number42.RefactorCase do
  @moduledoc """
  Test helper for refactor module smoke tests.

  Each refactor under `dev/refactors/refactors/` should have one test
  file under `test/refactors/` that uses this case. Tests apply the
  refactor in **isolation** (not via the full pipeline) so a failure
  points at one specific module.

  ## What we test

  - **rewrites** — minimal antipattern → expected replacement
  - **idempotent** — running the refactor twice equals running once,
    and conformant code is left alone
  - **leaves unrelated code alone** — non-matching snippets pass through

  ## What we don't test

  - Pipeline interactions (covered implicitly by `mix refactor`)
  - The post-refactor `mix format` pass — we compare raw refactor
    output, otherwise format normalization can hide real bugs.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Number42.RefactorCase
    end
  end

  @doc """
  Apply a single refactor to `source` and return the rewritten string.

  Calls `transform/2` directly — exactly one pass of one module,
  without the engine's fixpoint loop or cross-refactor pipeline.
  """
  @spec apply_refactor(module(), String.t(), keyword()) :: String.t()
  def apply_refactor(module, source, opts \\ []) do
    Code.ensure_loaded!(module)

    if function_exported?(module, :transform, 2) do
      module.transform(source, opts)
    else
      flunk("#{inspect(module)} does not implement transform/2")
    end
  end

  @doc """
  Assert idempotence: applying the refactor twice yields the same
  result as applying it once (whitespace-agnostic).
  """
  @spec assert_idempotent(module(), String.t(), keyword()) :: :ok
  def assert_idempotent(module, source, opts \\ []) do
    once = apply_refactor(module, source, opts)
    twice = apply_refactor(module, once, opts)

    assert squeeze(once) == squeeze(twice), """
    Refactor #{inspect(module)} is not idempotent.

    --- after first pass ---
    #{once}
    --- after second pass ---
    #{twice}
    """
  end

  @doc """
  Assert that `module` rewrites `before_source` to `expected`.

  Comparison is **whitespace-agnostic**: every whitespace run (spaces,
  tabs, newlines) is stripped before comparison. That keeps the test
  source readable (use heredocs with natural indentation) and saves us
  from running `mix format` in the test path. Failure messages still
  show the raw before/expected/actual so diffs stay debuggable.
  """
  @spec assert_rewrites(module(), String.t(), String.t(), keyword()) :: :ok
  def assert_rewrites(module, before_source, expected, opts \\ []) do
    actual = apply_refactor(module, before_source, opts)

    assert squeeze(actual) == squeeze(expected), """
    Refactor #{inspect(module)} did not produce the expected output.

    --- before ---
    #{before_source}
    --- expected ---
    #{expected}
    --- actual ---
    #{actual}
    """
  end

  @doc """
  Assert that `module` leaves `source` unchanged (whitespace-agnostic).

  Use for both already-conformant code and code the refactor explicitly
  should not touch (e.g. an excluded namespace).
  """
  @spec assert_unchanged(module(), String.t(), keyword()) :: :ok
  def assert_unchanged(module, source, opts \\ []) do
    actual = apply_refactor(module, source, opts)

    assert squeeze(actual) == squeeze(source), """
    Refactor #{inspect(module)} unexpectedly modified the source.

    --- before ---
    #{source}
    --- after ---
    #{actual}
    """
  end

  @doc """
  Return the list of `{visibility, name, arity}` definition groups in
  `source` whose clauses are **not** contiguous.

  The Elixir compiler emits *"clauses with the same name and arity
  (number of arguments) should be grouped together"* when a function's
  clauses are interrupted by another definition. We detect the same
  condition by parsing the source and walking the top-level `def`/`defp`
  nodes in order: a group is non-contiguous when clauses sharing the
  same `{visibility, name, arity}` reappear after a different definition
  has been seen in between.

  This is a pure, deterministic, side-effect-free check — unlike
  `Code.compile_string/1`, it never loads or purges modules and so
  cannot pollute concurrently-running async tests.
  """
  @spec ungrouped_clauses(String.t()) :: [{:def | :defp, atom(), non_neg_integer()}]
  def ungrouped_clauses(source) do
    source
    |> def_keys_in_order()
    |> detect_ungrouped()
  end

  defp def_keys_in_order(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.flat_map(fn
          {:defmodule, _, [_name, [{_do, body}]]} -> top_level_def_keys(body)
          _ -> []
        end)

      {:error, _} ->
        []
    end
  end

  defp top_level_def_keys({:__block__, _, exprs}), do: Enum.flat_map(exprs, &def_key/1)
  defp top_level_def_keys(expr), do: def_key(expr)

  defp def_key({vis, _, [head | _]}) when vis in [:def, :defp] do
    case def_name_arity(head) do
      {name, arity} -> [{vis, name, arity}]
      :error -> []
    end
  end

  defp def_key(_), do: []

  defp def_name_arity({:when, _, [head | _]}), do: def_name_arity(head)
  defp def_name_arity({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {name, 0}

  defp def_name_arity({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp def_name_arity(_), do: :error

  # Walk the ordered keys; a group is non-contiguous if we encounter a
  # key, then a *different* key, then that first key again.
  defp detect_ungrouped(keys) do
    keys
    |> Enum.reduce({nil, MapSet.new(), MapSet.new()}, fn key, {prev, seen, bad} ->
      bad = if key != prev and MapSet.member?(seen, key), do: MapSet.put(bad, key), else: bad
      {key, MapSet.put(seen, key), bad}
    end)
    |> elem(2)
    |> MapSet.to_list()
  end

  @doc """
  Assert that `source` compiles as real Elixir.

  Some refactors split or rewrite function heads; a structurally valid
  diff can still emit code the compiler rejects (e.g. default arguments
  declared in more than one clause). This compiles the rewritten string
  and fails with the captured compiler error if it doesn't.
  """
  @spec assert_compiles(String.t()) :: :ok
  def assert_compiles(source) do
    # Compile + purge mutate the global module namespace, so they must run
    # as one critical section — async tests reuse module names like `M`.
    # CompileLock (started in test_helper) serializes them. `:infinity`:
    # compiling untrusted refactor output can outrun the default timeout.
    # The compile error is captured and returned, then flunked here in the
    # test process — flunking inside the Agent would crash the lock.
    case Agent.get(__MODULE__.CompileLock, fn _ -> compile_and_purge(source) end, :infinity) do
      :ok ->
        :ok

      {:error, error} ->
        flunk("""
        Refactor output does not compile.

        --- error ---
        #{Exception.message(error)}
        --- source ---
        #{source}
        """)
    end
  end

  defp compile_and_purge(source) do
    Code.compile_string(source)
    :ok
  rescue
    error -> {:error, error}
  after
    purge_compiled_modules(source)
  end

  defp purge_compiled_modules(source) do
    ~r/^\s*defmodule\s+([A-Z][\w.]*)/m
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.each(fn [name] ->
      module = Module.concat([name])
      :code.purge(module)
      :code.delete(module)
    end)
  end

  defp squeeze(source),
    do:
      source
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
end
