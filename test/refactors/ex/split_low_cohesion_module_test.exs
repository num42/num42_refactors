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

  # A clean two-island god module: an account-registration cluster and a
  # dashboard-rendering cluster that never call across. Two concerns with
  # *distinct, rich vocabulary* — so the VocabularyClassifier scores it
  # god-like (p ≈ 0.84) and it clears the split gate. (A toy module with a
  # tiny repeated vocabulary scores single-concern and is declined, which
  # is the #258 fix; fixtures must look like real god modules.)
  defp two_island_module do
    """
    defmodule MyApp.Acc do
      def create_user(signup_form), do: signup_form |> validate_user() |> persist_user()
      defp validate_user(form), do: %{login: String.downcase(form.email), secret: hash_password(form.password)}
      defp hash_password(plaintext), do: :crypto.hash(:sha256, plaintext)
      defp persist_user(credentials), do: Map.merge(credentials, %{created: now(), role: default_role()})
      defp now, do: :calendar.universal_time()
      defp default_role, do: :member

      def charge(checkout), do: checkout |> authorize() |> settle()
      defp authorize(cart), do: %{amount: total_cents(cart), processor: choose_gateway(cart)}
      defp total_cents(cart), do: Enum.reduce(cart.items, 0, fn item, sum -> sum + item.price end)
      defp choose_gateway(cart), do: if cart.currency == :eur, do: :stripe, else: :adyen
      defp settle(charge), do: Map.put(charge, :receipt, build_invoice(charge))
      defp build_invoice(charge), do: %{ref: charge.processor, paid: charge.amount}
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

    # Regression for #247: a cluster dominated by a predicate (`?`) or
    # bang (`!`) function camelized straight to an invalid module alias
    # (`ShapeMatch?`), so the emitted `defmodule` failed to compile.
    test "predicate/bang dominant function yields a valid submodule name", %{tmp: tmp} do
      src = """
      defmodule MyApp.Shapes do
        def shape_match?(a), do: a |> normalize_shape() |> compare_shape()
        defp normalize_shape(a), do: a
        defp compare_shape(a), do: same_dims?(a)
        defp same_dims?(a), do: a

        def render!(c), do: c |> layout() |> paint()
        defp layout(c), do: c
        defp paint(c), do: finalize(c)
        defp finalize(c), do: c
      end
      """

      paths = materialize([{"lib/my_app/shapes.ex", src}], tmp)
      # Mechanics test (submodule naming), not detection — bypass the
      # vocabulary gate so the toy fixture reaches the split path.
      built = plan(paths, tmp, vocab_split_threshold: 0.0)

      assert map_size(built.splits) == 1

      moved_mods = for {_h, s} <- built.splits, c <- s.moved, do: c.module

      # No derived submodule name carries `?`/`!` punctuation.
      Enum.each(moved_mods, fn mod ->
        refute inspect(mod) =~ ~r/[?!]/, "submodule name has illegal punctuation: #{inspect(mod)}"
      end)

      home = apply_refactor(@subject, src, prepared: built, enabled: true)
      moved = moved_sources(tmp, ["lib/my_app/shapes.ex"])
      assert_compiles(home <> "\n" <> moved)
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
      # Mechanics test (cross-cluster promotion/requalify), not detection.
      built = plan(paths, tmp, vocab_split_threshold: 0.0)

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
      # Mechanics test (cross-submodule promotion/requalify), not detection.
      built = plan(paths, tmp, vocab_split_threshold: 0.0)

      assert map_size(built.splits) == 1
      assert length(built.splits[MyApp.MovedToMoved].moved) == 2

      home = apply_refactor(@subject, src, prepared: built, enabled: true)
      moved = moved_sources(tmp, ["lib/my_app/moved_to_moved.ex"])

      assert_compiles(home <> "\n" <> moved)
    end

    # The bug report's shape, frozen as a fixture (NOT the live
    # community_detection.ex — that would re-break on every rewrite of it):
    # a graph-detection module that splits into a "build" cluster and a
    # "score" cluster, where the build cluster's private helper calls a
    # private helper that lands in the score cluster. The boundary-crossing
    # private call must be promoted to `def` and qualified to its submodule,
    # or compilation fails with `undefined function`.
    test "the CommunityDetection self-dogfood case compiles", %{tmp: tmp} do
      src = """
      defmodule MyApp.GraphCluster do
        # build cluster: assemble a weighted adjacency from raw edges
        def build_adjacency(nodes, edges), do: nodes |> seed_nodes() |> absorb_edges(edges)
        defp seed_nodes(nodes), do: Map.new(nodes, fn vertex -> {vertex, %{}} end)
        defp absorb_edges(adjacency, edges), do: Enum.reduce(edges, adjacency, &insert_edge/2)
        defp insert_edge({{origin, target}, weight}, adjacency), do: link_pair(adjacency, origin, target, weight)
        defp link_pair(adjacency, origin, target, weight), do: normalize_weight(adjacency, origin, target, weight)

        # score cluster: compute modularity over a partition
        def modularity(partition, edges), do: partition |> tally_communities(edges) |> sum_contributions()
        defp tally_communities(partition, edges), do: Enum.map(partition, fn community -> community_score(community, edges) end)
        defp community_score(community, edges), do: intra_density(community, edges)
        defp intra_density(community, edges), do: incident_fraction(community, edges)
        defp sum_contributions(scores), do: Enum.sum(scores)
        defp incident_fraction(community, edges), do: {community, edges}

        # the boundary-crossing private call: a build helper reaches into
        # the score cluster's private helper.
        defp normalize_weight(adjacency, origin, target, weight), do: incident_fraction({adjacency, origin, target}, weight)
      end
      """

      paths = materialize([{"lib/my_app/graph_cluster.ex", src}], tmp)
      built = plan(paths, tmp, vocab_split_threshold: 0.0)

      assert map_size(built.splits) == 1

      home = apply_refactor(@subject, src, prepared: built, enabled: true)
      moved = moved_sources(tmp, ["lib/my_app/graph_cluster.ex"])

      combined = home <> "\n" <> moved

      # Wherever the cut falls, the boundary-crossing private call is
      # qualified across the module boundary (either home→submodule or
      # submodule→home) and its callee promoted from `defp` to `def`. The
      # cut here promotes `normalize_weight` and qualifies the call to it.
      assert combined =~ ~r/MyApp\.GraphCluster(\.\w+)?\.normalize_weight\(/
      assert combined =~ ~r/\bdef normalize_weight\(/
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

  describe "vocabulary gate — convergence (issue #258)" do
    # The root of #258: modularity is relative, so the splitter re-splits
    # its own freshly-created submodules forever. A submodule is a single
    # concern with a concentrated vocabulary; the classifier scores it low
    # and declines, so the fixpoint converges. See `VocabularyClassifier`.
    test "a single-concern module (concentrated vocabulary) is NOT split", %{tmp: tmp} do
      # Two non-communicating islands (clean seam, high modularity) but a
      # tiny, heavily-repeated vocabulary — the shape of a split artefact.
      concentrated = """
      defmodule MyApp.Conc do
        def a1(x), do: x |> a2() |> a3()
        defp a2(x), do: a4(x)
        defp a3(x), do: x
        defp a4(x), do: x

        def b1(x), do: x |> b2() |> b3()
        defp b2(x), do: b4(x)
        defp b3(x), do: x
        defp b4(x), do: x
      end
      """

      paths = materialize([{"lib/my_app/conc.ex", concentrated}], tmp)
      built = plan(paths, tmp)

      assert built.splits == %{}
      assert_unchanged(@subject, concentrated, prepared: built, enabled: true)
      assert Enum.any?(built.declined, &(&1.reason =~ "vocabulary"))
    end

    test "the vocabulary threshold is configurable (0.0 disables the gate)", %{tmp: tmp} do
      concentrated = """
      defmodule MyApp.Conc do
        def a1(x), do: x |> a2() |> a3()
        defp a2(x), do: a4(x)
        defp a3(x), do: x
        defp a4(x), do: x

        def b1(x), do: x |> b2() |> b3()
        defp b2(x), do: b4(x)
        defp b3(x), do: x
        defp b4(x), do: x
      end
      """

      paths = materialize([{"lib/my_app/conc.ex", concentrated}], tmp)

      # Gate on (default): declined. Gate off (0.0): splits.
      assert plan(paths, tmp).splits == %{}
      assert map_size(plan(paths, tmp, vocab_split_threshold: 0.0).splits) == 1
    end

    test "a real god module clears the gate and still splits", %{tmp: tmp} do
      src = two_island_module()
      paths = materialize([{"lib/my_app/acc.ex", src}], tmp)

      # Default threshold — the rich-vocabulary fixture is split-worthy.
      assert map_size(plan(paths, tmp).splits) == 1
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
      # Tests the shared-@attr guard specifically — bypass the vocabulary
      # gate so this toy fixture reaches that guard.
      built = plan(paths, tmp, vocab_split_threshold: 0.0)

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
      # Tests the shared-@attr guard specifically — bypass the vocabulary
      # gate so this toy fixture reaches that guard rather than declining
      # earlier on vocabulary.
      built = plan(paths, tmp, vocab_split_threshold: 0.0)

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
