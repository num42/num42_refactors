defmodule Number42.Refactors.EngineCorpusTest do
  # The corpus cache lives in `:persistent_term`, which is global state.
  # These tests write files and invalidate that cache, so they must not run
  # alongside anything else touching it.
  use ExUnit.Case, async: false

  alias Number42.Refactors.Engine

  setup do
    dir = Path.join(System.tmp_dir!(), "n42_corpus_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf(dir)
      Engine.invalidate_prepared_cache()
    end)

    Engine.invalidate_prepared_cache()
    {:ok, dir: dir}
  end

  defp write(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  describe "corpus/1" do
    test "returns source and parsed AST per path", %{dir: dir} do
      path = write(dir, "a.ex", "defmodule A do\n  def x, do: 1\nend\n")

      corpus = Engine.corpus([path])

      assert {source, ast} = Map.fetch!(corpus, path)
      assert source =~ "defmodule A"
      refute is_nil(ast)
    end

    test "nil paths yield an empty corpus" do
      assert Engine.corpus(nil) == %{}
    end

    test "de-duplicates repeated paths", %{dir: dir} do
      path = write(dir, "a.ex", "defmodule A do\nend\n")

      assert Engine.corpus([path, path, path]) |> map_size() == 1
    end

    test "an unreadable path is omitted rather than raising", %{dir: dir} do
      good = write(dir, "a.ex", "defmodule A do\nend\n")
      missing = Path.join(dir, "does_not_exist.ex")

      corpus = Engine.corpus([good, missing])

      assert Map.has_key?(corpus, good)
      refute Map.has_key?(corpus, missing)
    end

    test "an unparsable path keeps its source with a nil AST", %{dir: dir} do
      # Source is still useful to a caller doing text-level work, and
      # omitting it would make the caller re-read the file it just paid for.
      path = write(dir, "broken.ex", "defmodule Broken do\n  def (((\nend\n")

      assert {source, nil} = Engine.corpus([path]) |> Map.fetch!(path)
      assert source =~ "Broken"
    end
  end

  describe "corpus_sources/1" do
    test "returns only the sources", %{dir: dir} do
      a = write(dir, "a.ex", "defmodule A do\nend\n")
      b = write(dir, "b.ex", "defmodule B do\nend\n")

      sources = Engine.corpus_sources([a, b])

      assert Map.fetch!(sources, a) =~ "defmodule A"
      assert Map.fetch!(sources, b) =~ "defmodule B"
    end

    test "is served from the same cached read as corpus/1", %{dir: dir} do
      path = write(dir, "a.ex", "defmodule A do\nend\n")

      Engine.corpus([path])
      File.write!(path, "defmodule Rewritten do\nend\n")

      # No invalidation, so the cached snapshot still stands.
      assert Engine.corpus_sources([path]) |> Map.fetch!(path) =~ "defmodule A"
    end
  end

  # This is the property the whole change hinges on. A corpus snapshot that
  # outlives a write would make a later refactor plan against pre-rewrite
  # source — wrong output, no crash, no signal. The corpus must therefore
  # expire exactly where the prepared-plan cache does.
  describe "cache lifetime" do
    test "a second call within one run reuses the snapshot", %{dir: dir} do
      path = write(dir, "a.ex", "defmodule A do\nend\n")
      Engine.corpus([path])

      File.write!(path, "defmodule Rewritten do\nend\n")

      assert {source, _ast} = Engine.corpus([path]) |> Map.fetch!(path)
      assert source =~ "defmodule A", "expected the cached snapshot, not a re-read"
    end

    test "invalidate_prepared_cache/0 drops the corpus too", %{dir: dir} do
      path = write(dir, "a.ex", "defmodule A do\nend\n")
      Engine.corpus([path])

      File.write!(path, "defmodule Rewritten do\nend\n")
      Engine.invalidate_prepared_cache()

      assert {source, _ast} = Engine.corpus([path]) |> Map.fetch!(path)

      assert source =~ "defmodule Rewritten",
             "the corpus must re-read after invalidation, or step-by-step mode plans against stale source"
    end

    test "the re-read after invalidation also refreshes the AST", %{dir: dir} do
      path = write(dir, "a.ex", "defmodule A do\n  def x, do: 1\nend\n")
      {_, first_ast} = Engine.corpus([path]) |> Map.fetch!(path)

      File.write!(path, "defmodule A do\n  def y, do: 2\nend\n")
      Engine.invalidate_prepared_cache()

      {_, second_ast} = Engine.corpus([path]) |> Map.fetch!(path)

      refute first_ast == second_ast,
             "a stale AST is the same bug as a stale source, one layer down"
    end

    test "distinct path sets are cached independently", %{dir: dir} do
      a = write(dir, "a.ex", "defmodule A do\nend\n")
      b = write(dir, "b.ex", "defmodule B do\nend\n")

      assert Engine.corpus([a]) |> map_size() == 1
      assert Engine.corpus([a, b]) |> map_size() == 2
      assert Engine.corpus([a]) |> map_size() == 1
    end
  end

  describe "sharing" do
    test "one read serves every caller of the same path set", %{dir: dir} do
      path = write(dir, "a.ex", "defmodule A do\nend\n")

      # Prime the cache, then make the file unreadable. Any caller that
      # re-read from disk would now see nothing; a shared cache still
      # answers. This stands in for "N refactors, one parse".
      Engine.corpus([path])
      File.rm!(path)

      assert Engine.corpus([path]) |> Map.has_key?(path)
      assert Engine.corpus_sources([path]) |> Map.has_key?(path)
    end
  end
end
