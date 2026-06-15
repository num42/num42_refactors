defmodule Number42.Refactors.Ex.ExtractSharedModuleFixpointReproTest do
  use Number42.RefactorCase, async: false

  alias Number42.Refactors.Ex.ExtractSharedModule

  @subject ExtractSharedModule

  # #226 repro: run ExtractSharedModule in a true fixpoint loop, rebuilding
  # the plan from the *whole rewritten world* between passes — including the
  # freshly written `*.Shared` host file. This is what `mix refactor` does on
  # repeated `-yta` passes. The in-repo idempotence test only checks that an
  # already-delegated source stays unchanged; it never re-reads the written
  # host and re-runs the planner against it.

  setup do
    tmp = Path.join(System.tmp_dir!(), "esm_fixpoint_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  # One pass over the whole world: build a plan from all current sources,
  # apply it to every file, then re-read any host files written to disk and
  # fold them into the next world. Returns the new {path, source} list.
  defp pass(sources, tmp) do
    plan = ExtractSharedModule.build_plan(sources, min_mass: 5, write_root: tmp)

    rewritten =
      Enum.map(sources, fn {path, src} ->
        {path, apply_refactor(@subject, src, prepared: plan)}
      end)

    # Pick up any *.Shared host files the planner wrote to disk and treat
    # them as part of the world (the real engine globs lib/ on every pass).
    written =
      Path.join(tmp, "lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.map(fn p -> {Path.relative_to(p, tmp), File.read!(p)} end)

    merge_world(rewritten, written)
  end

  defp merge_world(rewritten, written) do
    by_path = Map.new(rewritten)

    extra =
      written
      |> Enum.reject(fn {path, _} -> Map.has_key?(by_path, path) end)

    rewritten ++ extra
  end

  defp count_defdelegate(source, name) do
    source
    |> String.split("\n")
    |> Enum.count(&String.contains?(&1, "defdelegate #{name}"))
  end

  test "fixpoint: second pass does not re-extract the written Shared host", %{tmp: tmp} do
    a = """
    defmodule MyApp.Items.New do
      def collect_parent_ids(tree) do
        tree
        |> Map.get(:children, [])
        |> Enum.flat_map(&Map.get(&1, :ids, []))
        |> Enum.uniq()
      end
    end
    """

    b = """
    defmodule MyApp.Items.Show do
      def collect_parent_ids(tree) do
        tree
        |> Map.get(:children, [])
        |> Enum.flat_map(&Map.get(&1, :ids, []))
        |> Enum.uniq()
      end
    end
    """

    world0 = [{"lib/my_app/items/new.ex", a}, {"lib/my_app/items/show.ex", b}]

    world1 = pass(world0, tmp)
    world2 = pass(world1, tmp)
    world3 = pass(world2, tmp)

    # The host file after pass 1 vs after pass 3 must be byte-identical:
    # no accumulating defdelegate clauses, no leftover local def.
    host_after = fn world ->
      world
      |> Enum.find(fn {path, _} -> String.contains?(path, "shared.ex") end)
      |> case do
        {_path, src} -> src
        nil -> nil
      end
    end

    h1 = host_after.(world1)
    h3 = host_after.(world3)

    # Convergence: world2 == world3 (whitespace-insensitive per file).
    norm = fn world -> world |> Enum.sort() |> Enum.map(fn {p, s} -> {p, squeeze(s)} end) end

    assert norm.(world2) == norm.(world3),
           "world did not converge — pass 3 differs from pass 2 (non-idempotent)"

    # The host must not grow duplicate delegations across passes.
    if h1 && h3 do
      assert count_defdelegate(h1, "collect_parent_ids") ==
               count_defdelegate(h3, "collect_parent_ids"),
             "host accumulated defdelegate clauses across passes"
    end

    # Each loser keeps exactly one delegation, not N.
    Enum.each(world3, fn {path, src} ->
      unless String.contains?(path, "shared.ex") do
        assert count_defdelegate(src, "collect_parent_ids") <= 1,
               "#{path} accumulated multiple delegations: \n#{src}"
      end
    end)
  end

  defp squeeze(s), do: s |> String.replace(~r/\s+/, " ") |> String.trim()
end
