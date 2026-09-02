defmodule Number42.Refactors.EnginePrepareCacheTest do
  # Not async: the prepared-plan cache lives in :persistent_term, which is
  # global, and the counter agent is registered by name.
  use ExUnit.Case, async: false

  alias Number42.Refactors.Engine

  defmodule CountingPrepare do
    use Number42.Refactors.Refactor

    @counter __MODULE__.Counter

    def start_counter do
      case Agent.start_link(fn -> 0 end, name: @counter) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> Agent.update(@counter, fn _ -> 0 end) && pid
      end
    end

    def count, do: Agent.get(@counter, & &1)

    @impl Number42.Refactors.Refactor
    def description, do: "test double that records how often prepare/1 ran"

    @impl Number42.Refactors.Refactor
    def explanation, do: "test double"

    @impl Number42.Refactors.Refactor
    def prepare(_opts) do
      Agent.update(@counter, &(&1 + 1))
      {:ok, :plan}
    end

    @impl Number42.Refactors.Refactor
    def transform(source, _opts), do: source
  end

  setup do
    CountingPrepare.start_counter()
    Engine.invalidate_prepared_cache()
    on_exit(&Engine.invalidate_prepared_cache/0)
    :ok
  end

  describe "prepared-plan cache key" do
    test "prepare/1 runs once across files — the per-file :path is not part of the key" do
      source = "defmodule A do\n  def x, do: 1\nend\n"

      for path <- ["lib/a.ex", "lib/b.ex", "lib/c.ex"] do
        Engine.apply_one(CountingPrepare, source, path: path)
      end

      assert CountingPrepare.count() == 1
    end

    test "a genuinely different corpus-wide option still rebuilds the plan" do
      source = "defmodule A do\n  def x, do: 1\nend\n"

      for paths <- [["lib/a.ex"], ["lib/b.ex"]] do
        Engine.apply_one(CountingPrepare, source,
          configured_modules: [{CountingPrepare, paths: paths}]
        )
      end

      assert CountingPrepare.count() == 2
    end
  end
end
