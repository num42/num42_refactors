defmodule Num42.RefactorCase do
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
      import Num42.RefactorCase
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

  # Collapse every whitespace run to a single space and trim. Preserves
  # token boundaries (`def foo` stays distinct from `deffoo`) while
  # making the comparison agnostic to indentation, blank lines, and
  # trailing newlines.
  defp squeeze(source),
    do:
      source
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
end
