defmodule Number42.Refactors.Ex.SplitLowCohesionModuleTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.SplitLowCohesionModule

  @subject SplitLowCohesionModule

  # SplitLowCohesionModule is the most destructive refactor in the
  # catalogue: it splits a god module into submodules. Detection is the
  # whole problem — the suite is deliberately negative-heavy. Like
  # RelocateMisplacedFunction / ExtractSharedModule it has a disk
  # side-effect (prepare/1 writes the moved-cluster files), so tests run
  # in a per-test tmp_dir and pass `:write_root` to contain writes.

  setup do
    tmp = Path.join(System.tmp_dir!(), "split_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp materialize(sources, tmp) do
    Enum.each(sources, fn {rel, src} ->
      path = Path.join(tmp, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, src)
    end)

    sources
  end

  defp plan(sources, tmp, opts \\ []) do
    SplitLowCohesionModule.build_plan(sources, Keyword.put(opts, :write_root, tmp))
  end

  # Only the files the refactor *newly wrote* — exclude the materialized
  # originals so `assert_compiles(home <> moved)` does not double-define
  # the home module (the on-disk original is never rewritten in place;
  # `transform/2` returns the rewritten home string).
  defp moved_sources(tmp, original_rels) do
    originals = MapSet.new(original_rels, &Path.join(tmp, &1))

    Path.wildcard(Path.join(tmp, "lib/**/*.ex"))
    |> Enum.reject(&MapSet.member?(originals, &1))
    |> Enum.map_join("\n\n", &File.read!/1)
  end

  # A clean two-island god module: a "create_user" cluster and a
  # "charge" cluster that never call across. Eight functions clears the
  # min-module-functions floor.
  defp two_island_module do
    """
    defmodule MyApp.Acc do
      def create_user(a), do: a |> validate_user() |> persist_user()
      defp validate_user(a), do: a
      defp persist_user(a), do: store_user(a)
      defp store_user(a), do: a

      def charge(c), do: c |> authorize() |> settle()
      defp authorize(c), do: c
      defp settle(c), do: ledger(c)
      defp ledger(c), do: c
    end
    """
  end

  describe "default-OFF (opt-in only)" do
    test "without enabled: true, prepare is :no_cache and transform is a no-op", %{tmp: tmp} do
      src = two_island_module()
      paths = materialize([{"lib/my_app/acc.ex", src}], tmp)

      assert SplitLowCohesionModule.prepare(source_files: Enum.map(paths, &elem(&1, 0))) ==
               :no_cache

      built = plan(paths, tmp)
      assert_unchanged(@subject, src, prepared: built)
    end

    test "prepare does not write any file when disabled", %{tmp: tmp} do
      src = two_island_module()
      materialize([{"lib/my_app/acc.ex", src}], tmp)

      assert SplitLowCohesionModule.prepare(
               source_files: [Path.join(tmp, "lib/my_app/acc.ex")],
               write_root: tmp
             ) == :no_cache

      assert Path.wildcard(Path.join(tmp, "lib/my_app/acc/*.ex")) == []
    end
  end

  describe "rewrites — clean two-island split" do
    test "splits into a home module + one submodule, with a delegate", %{tmp: tmp} do
      src = two_island_module()
      paths = materialize([{"lib/my_app/acc.ex", src}], tmp)
      built = plan(paths, tmp)

      # Exactly one module split, into exactly one moved submodule.
      assert map_size(built.splits) == 1
      split = built.splits[MyApp.Acc]
      assert length(split.moved) == 1

      home = apply_refactor(@subject, src, prepared: built, enabled: true)
      moved = moved_sources(tmp, ["lib/my_app/acc.ex"])

      # The home module keeps a delegate for the moved public function
      # and the moved submodule defines it.
      assert home =~ "defdelegate"
      assert moved =~ "defmodule MyApp.Acc."

      # Both still expose create_user/1 and charge/1 between them.
      combined = home <> moved
      assert combined =~ "def create_user"
      assert combined =~ "def charge"

      # The whole rewritten corpus compiles together.
      assert_compiles(home <> "\n" <> moved)
    end

    test "moved submodule carries its private helpers", %{tmp: tmp} do
      src = two_island_module()
      paths = materialize([{"lib/my_app/acc.ex", src}], tmp)
      built = plan(paths, tmp)

      _home = apply_refactor(@subject, src, prepared: built, enabled: true)
      moved = moved_sources(tmp, ["lib/my_app/acc.ex"])

      # Whichever cluster moved, its private helpers travel with it so
      # the submodule is self-contained (no dangling calls).
      assert_compiles(
        apply_refactor(@subject, src, prepared: built, enabled: true) <> "\n" <> moved
      )
    end

    test "rewrites cross-file call sites to the new submodule", %{tmp: tmp} do
      src = two_island_module()

      caller = """
      defmodule MyApp.Web do
        alias MyApp.Acc

        def signup(a), do: Acc.create_user(a)
        def pay(c), do: MyApp.Acc.charge(c)
      end
      """

      paths =
        materialize([{"lib/my_app/acc.ex", src}, {"lib/my_app/web.ex", caller}], tmp)

      built = plan(paths, tmp)
      split = built.splits[MyApp.Acc]
      [moved_mod] = Enum.map(split.moved, & &1.module)

      result_caller = apply_refactor(@subject, caller, prepared: built, enabled: true)

      # The call to whichever function moved now targets the submodule.
      assert result_caller =~ "#{inspect(moved_mod)}."

      home = apply_refactor(@subject, src, prepared: built, enabled: true)
      moved = moved_sources(tmp, ["lib/my_app/acc.ex", "lib/my_app/web.ex"])
      assert_compiles(home <> "\n" <> moved <> "\n" <> result_caller)
    end
  end

  describe "rewrites — cross-cluster private calls (requalify)" do
    # The community partition cuts by communication *density*, not by
    # call reachability — so a cluster boundary can fall between two
    # private functions that call each other. The emitter must promote
    # the callee to `def` and qualify the call site, in every direction,
    # or the output fails to compile with `undefined function`.

    # A moved cluster calls a private function that stays in the HOME
    # module. The home `defp` must be promoted to `def` (remote-callable)
    # and the moved body must qualify the call to the home module.
    test "moved → home: home defp callee is promoted, call qualified", %{tmp: tmp} do
      src = """
      defmodule MyApp.MovedToHome do
        def alpha(x), do: x |> a1() |> a2()
        defp a1(x), do: a3(x)
        defp a2(x), do: a3(x)
        defp a3(x), do: bridge(x)

        def beta(y), do: y |> b1() |> b2()
        defp b1(y), do: b3(y)
        defp b2(y), do: b3(y)
        defp b3(y), do: y
        defp bridge(z), do: b1(z)
      end
      """

      paths = materialize([{"lib/my_app/moved_to_home.ex", src}], tmp)
      built = plan(paths, tmp)

      assert map_size(built.splits) == 1

      home = apply_refactor(@subject, src, prepared: built, enabled: true)
      moved = moved_sources(tmp, ["lib/my_app/moved_to_home.ex"])

      # bridge stays home and is reached from the moved cluster, so it is
      # promoted to a public def and the moved body calls MyApp.MovedToHome.bridge.
      assert_compiles(home <> "\n" <> moved)
      refute moved =~ "MyApp.MovedToHome.MyApp"
    end

    # Two clusters both move out, and a function in one calls a private
    # function in the other. The callee is promoted to `def` in its
    # submodule and the caller's body qualifies the call to that submodule.
    test "moved → moved: cross-submodule private callee promoted + qualified", %{tmp: tmp} do
      src = """
      defmodule MyApp.MovedToMoved do
        def p1(x), do: x |> h1() |> h2()
        def p2(x), do: x |> h1() |> h2()
        defp h1(x), do: h2(x)
        defp h2(x), do: x

        def go_a(x), do: x |> a1() |> a2()
        defp a1(x), do: a2(x)
        defp a2(x), do: cross_to_b(x)

        defp go_b(x), do: x |> b1() |> b2()
        defp b1(x), do: b2(x)
        defp b2(x), do: x
        defp cross_to_b(x), do: b1(x)
      end
      """

      paths = materialize([{"lib/my_app/moved_to_moved.ex", src}], tmp)
      built = plan(paths, tmp)

      assert map_size(built.splits) == 1
      assert length(built.splits[MyApp.MovedToMoved].moved) == 2

      home = apply_refactor(@subject, src, prepared: built, enabled: true)
      moved = moved_sources(tmp, ["lib/my_app/moved_to_moved.ex"])

      assert_compiles(home <> "\n" <> moved)
    end

    # The real bug report: CommunityDetection itself splits into .Detect
    # and .BestMerge, with greedy_merge (Detect) → best_merge (BestMerge)
    # and detect (Detect) → total_weight (home). Must compile.
    test "the CommunityDetection self-dogfood case compiles", %{tmp: tmp} do
      src = File.read!(Path.join(File.cwd!(), "lib/number42/refactors/community_detection.ex"))
      rel = "lib/number42/refactors/community_detection.ex"
      paths = materialize([{rel, src}], tmp)
      built = plan(paths, tmp)

      assert map_size(built.splits) == 1

      home = apply_refactor(@subject, src, prepared: built, enabled: true)
      moved = moved_sources(tmp, [rel])

      combined = home <> "\n" <> moved

      # The boundary-crossing call greedy_merge → best_merge is now
      # qualified to the submodule, and best_merge is promoted to def.
      assert combined =~ ~r/CommunityDetection\.BestMerge\.best_merge\(/
      assert combined =~ ~r/\bdef best_merge\(/
      # Compilation is the real proof: no `undefined function` survives.
      assert_compiles(combined)
    end

    # A clean two-island split has NO cross-cluster private calls, so the
    # requalify pass must leave intra-cluster private calls untouched: the
    # moved submodule keeps its helpers private and unqualified.
    test "self-contained split is not over-qualified", %{tmp: tmp} do
      src = two_island_module()
      paths = materialize([{"lib/my_app/acc.ex", src}], tmp)
      built = plan(paths, tmp)

      home = apply_refactor(@subject, src, prepared: built, enabled: true)
      moved = moved_sources(tmp, ["lib/my_app/acc.ex"])

      # No call inside the moved submodule is qualified with the home
      # module path — intra-cluster calls stay bare.
      refute moved =~ "MyApp.Acc.store_user"
      refute moved =~ "MyApp.Acc.ledger"
      refute moved =~ "MyApp.Acc.validate_user"
      # And the moved submodule keeps a private helper (nothing promoted).
      assert moved =~ "defp"

      assert_compiles(home <> "\n" <> moved)
    end
  end

  describe "idempotence" do
    test "applying the split twice with a fixed plan is stable", %{tmp: tmp} do
      src = two_island_module()
      paths = materialize([{"lib/my_app/acc.ex", src}], tmp)
      built = plan(paths, tmp)

      assert_idempotent(@subject, src, prepared: built, enabled: true)
    end
  end

  describe "leaves alone — ambiguous blob (the core safety rule)" do
    test "a tangled blob with no community structure is NOT split", %{tmp: tmp} do
      # Every function calls a central hub and its neighbours: dense,
      # interconnected, no clean seam. Modularity stays ~0 → decline.
      blob = """
      defmodule MyApp.Blob do
        def a(x), do: hub(x) + b(x)
        def b(x), do: hub(x) + c(x)
        def c(x), do: hub(x) + d(x)
        def d(x), do: hub(x) + a(x)
        def e(x), do: hub(x) + a(x) + b(x) + c(x) + d(x)
        defp hub(x), do: x
      end
      """

      paths = materialize([{"lib/my_app/blob.ex", blob}], tmp)
      built = plan(paths, tmp)

      assert built.splits == %{}
      assert_unchanged(@subject, blob, prepared: built, enabled: true)

      # And the decline is recorded with a reason for --dry-run review.
      assert Enum.any?(built.declined, &(&1.module == MyApp.Blob))
      assert SplitLowCohesionModule.report(built) =~ "MyApp.Blob"
    end

    test "a star graph (one hub everything calls) is NOT split", %{tmp: tmp} do
      star = """
      defmodule MyApp.Star do
        def a(x), do: core(x)
        def b(x), do: core(x)
        def c(x), do: core(x)
        def d(x), do: core(x)
        def e(x), do: core(x)
        defp core(x), do: x
      end
      """

      paths = materialize([{"lib/my_app/star.ex", star}], tmp)
      built = plan(paths, tmp)

      assert built.splits == %{}
      assert_unchanged(@subject, star, prepared: built, enabled: true)
    end
  end

  describe "leaves alone — false-positive guards" do
    test "module with @behaviour keeps its callbacks together (decline)", %{tmp: tmp} do
      src = """
      defmodule MyApp.Server do
        @behaviour GenServer

        def create_user(a), do: a |> validate_user() |> persist_user()
        defp validate_user(a), do: a
        defp persist_user(a), do: a

        def charge(c), do: c |> authorize() |> settle()
        defp authorize(c), do: c
        defp settle(c), do: c
      end
      """

      paths = materialize([{"lib/my_app/server.ex", src}], tmp)
      built = plan(paths, tmp)

      assert built.splits == %{}
      assert_unchanged(@subject, src, prepared: built, enabled: true)
      assert Enum.any?(built.declined, &(&1.reason =~ "behaviour"))
    end

    test "module with @impl callbacks is NOT split", %{tmp: tmp} do
      src = """
      defmodule MyApp.Impl do
        @impl true
        def init(a), do: a |> validate_user() |> persist_user()
        defp validate_user(a), do: a
        defp persist_user(a), do: a

        def charge(c), do: c |> authorize() |> settle()
        defp authorize(c), do: c
        defp settle(c), do: c
      end
      """

      paths = materialize([{"lib/my_app/impl.ex", src}], tmp)
      built = plan(paths, tmp)

      assert built.splits == %{}
      assert_unchanged(@subject, src, prepared: built, enabled: true)
    end

    test "module with `use X` (possible macro codegen) is NOT split", %{tmp: tmp} do
      src = """
      defmodule MyApp.Live do
        use MyApp.SomeMacro

        def create_user(a), do: a |> validate_user() |> persist_user()
        defp validate_user(a), do: a
        defp persist_user(a), do: a

        def charge(c), do: c |> authorize() |> settle()
        defp authorize(c), do: c
        defp settle(c), do: c
      end
      """

      paths = materialize([{"lib/my_app/live.ex", src}], tmp)
      built = plan(paths, tmp)

      assert built.splits == %{}
      assert_unchanged(@subject, src, prepared: built, enabled: true)
      assert Enum.any?(built.declined, &(&1.reason =~ "use X"))
    end

    test "a @attr read in both clusters is NOT split", %{tmp: tmp} do
      # @sep is read by a function in each island → splitting orphans it.
      src = """
      defmodule MyApp.Shared do
        @sep " - "

        def create_user(a), do: a |> validate_user() |> persist_user()
        defp validate_user(a), do: a <> @sep
        defp persist_user(a), do: a

        def charge(c), do: c |> authorize() |> settle()
        defp authorize(c), do: c <> @sep
        defp settle(c), do: c
      end
      """

      paths = materialize([{"lib/my_app/shared.ex", src}], tmp)
      built = plan(paths, tmp)

      assert built.splits == %{}
      assert_unchanged(@subject, src, prepared: built, enabled: true)
      assert Enum.any?(built.declined, &(&1.reason =~ "@attr"))
    end

    test "a @attr read only inside the cluster that would MOVE is NOT split", %{tmp: tmp} do
      # @factor is read solely by the charge island. Moving that island
      # to a submodule would silently re-resolve @factor to nil there —
      # compiles, but semantically wrong. The guard must decline.
      src = """
      defmodule MyApp.AttrEdge do
        @factor 2

        def create_user(a), do: a |> validate_user() |> persist_user()
        defp validate_user(a), do: a
        defp persist_user(a), do: store_user(a)
        defp store_user(a), do: a

        def charge(c), do: c |> authorize() |> settle()
        defp authorize(c), do: c * @factor
        defp settle(c), do: ledger(c)
        defp ledger(c), do: c
      end
      """

      paths = materialize([{"lib/my_app/attr_edge.ex", src}], tmp)
      built = plan(paths, tmp)

      assert built.splits == %{}
      assert_unchanged(@subject, src, prepared: built, enabled: true)
      assert Enum.any?(built.declined, &(&1.reason =~ "@attr"))
    end

    test "a %__MODULE__{} struct read across clusters is NOT split", %{tmp: tmp} do
      src = """
      defmodule MyApp.Struct do
        defstruct [:name, :amount]

        def create_user(%__MODULE__{} = s), do: s |> validate_user() |> persist_user()
        defp validate_user(s), do: s
        defp persist_user(s), do: s

        def charge(%__MODULE__{} = s), do: s |> authorize() |> settle()
        defp authorize(s), do: s
        defp settle(s), do: s
      end
      """

      paths = materialize([{"lib/my_app/struct.ex", src}], tmp)
      built = plan(paths, tmp)

      assert built.splits == %{}
      assert_unchanged(@subject, src, prepared: built, enabled: true)
    end

    test "dynamic apply/3 in a body (incomplete call-graph) is NOT split", %{tmp: tmp} do
      src = """
      defmodule MyApp.Dyn do
        def create_user(a, f), do: apply(__MODULE__, f, [a])
        defp validate_user(a), do: a
        defp persist_user(a), do: a

        def charge(c), do: c |> authorize() |> settle()
        defp authorize(c), do: c
        defp settle(c), do: c
      end
      """

      paths = materialize([{"lib/my_app/dyn.ex", src}], tmp)
      built = plan(paths, tmp)

      assert built.splits == %{}
      assert_unchanged(@subject, src, prepared: built, enabled: true)
      assert Enum.any?(built.declined, &(&1.reason =~ "apply"))
    end

    test "an external dynamic-apply caller makes the split unsafe (decline)", %{tmp: tmp} do
      src = two_island_module()

      caller = """
      defmodule MyApp.Web do
        def go(a), do: apply(MyApp.Acc, :charge, [a])
      end
      """

      paths = materialize([{"lib/my_app/acc.ex", src}, {"lib/my_app/web.ex", caller}], tmp)
      built = plan(paths, tmp)

      # Either charge moved (then the apply caller is unsafe → no split)
      # or it stayed home. In both cases the apply guard keeps the corpus
      # safe: if charge is a moved public, the whole split is dropped.
      moved_publics =
        built.splits
        |> Map.values()
        |> Enum.flat_map(fn s -> Enum.flat_map(s.moved, &MapSet.to_list(&1.public_keys)) end)

      refute {:charge, 1} in moved_publics
      assert_unchanged(@subject, src, prepared: built, enabled: true)
    end

    test "a module too small to split is left alone", %{tmp: tmp} do
      src = """
      defmodule MyApp.Tiny do
        def a(x), do: helper(x)
        defp helper(x), do: x
        def b(y), do: y
      end
      """

      paths = materialize([{"lib/my_app/tiny.ex", src}], tmp)
      built = plan(paths, tmp)

      assert built.splits == %{}
      assert_unchanged(@subject, src, prepared: built, enabled: true)
      assert Enum.any?(built.declined, &(&1.reason =~ "too few functions"))
    end

    test "a derived submodule that already exists in the corpus is not overwritten", %{tmp: tmp} do
      src = two_island_module()
      paths_only = [{"lib/my_app/acc.ex", src}]
      built_preview = plan(paths_only, tmp, dry_run: true)
      [existing_mod] = built_preview.splits[MyApp.Acc].moved |> Enum.map(& &1.module)

      # Materialize a real module at the derived submodule name so the
      # split must back off rather than clobber it.
      collide = """
      defmodule #{inspect(existing_mod)} do
        def something(x), do: x
      end
      """

      rel =
        "lib/" <>
          (existing_mod |> Module.split() |> Enum.map_join("/", &Macro.underscore/1)) <> ".ex"

      paths = materialize([{"lib/my_app/acc.ex", src}, {rel, collide}], tmp)

      built = plan(paths, tmp)

      assert built.splits == %{}
      assert_unchanged(@subject, src, prepared: built, enabled: true)
    end
  end

  describe "report" do
    test "summarises splits and declines", %{tmp: tmp} do
      good = two_island_module()
      blob = "defmodule MyApp.B do\n  def x(a), do: a\nend\n"

      paths = materialize([{"lib/my_app/acc.ex", good}, {"lib/my_app/b.ex", blob}], tmp)
      built = plan(paths, tmp)

      report = SplitLowCohesionModule.report(built)
      assert report =~ "split modules:"
      assert report =~ "considered but declined:"
    end
  end
end
