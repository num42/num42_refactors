defmodule Number42.Refactors.Ex.ExtractBehaviourFromAdapterFamilyTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractBehaviourFromAdapterFamily, as: Subject

  @subject Subject

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "extract_behaviour_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp unique_ns, do: "BehFam#{System.unique_integer([:positive])}"

  # `[{module_name_string, body}]` → `{combined_compile_source, [{path, source}]}`
  defp fixture(modules) do
    combined =
      Enum.map_join(modules, "\n", fn {name, body} ->
        "defmodule #{name} do\n#{body}end\n"
      end)

    sources =
      Enum.map(modules, fn {name, body} ->
        {"lib/" <> Macro.underscore(name) <> ".ex", "defmodule #{name} do\n#{body}end\n"}
      end)

    {combined, sources}
  end

  # An extra source file that dispatches each `{fun, arity}` through a
  # dynamic receiver, so the family it belongs to clears the dispatch
  # requirement. Not compiled — only parsed by the dispatch scanner.
  defp dispatch_source(funs) do
    calls =
      Enum.map_join(funs, "\n", fn {name, arity} ->
        args = Enum.map_join(1..arity//1, ", ", fn i -> "a#{i}" end)
        "    mod.#{name}(#{args})"
      end)

    {"lib/dispatch_site.ex",
     "defmodule DispatchSite do\n  def run(mod#{dispatch_args(funs)}) do\n#{calls}\n  end\nend\n"}
  end

  defp dispatch_args(funs) do
    max_arity = funs |> Enum.map(fn {_n, a} -> a end) |> Enum.max(fn -> 0 end)
    if max_arity == 0, do: "", else: ", " <> Enum.map_join(1..max_arity//1, ", ", &"a#{&1}")
  end

  # Append a dispatch site for `funs` to a fixture's source list.
  defp with_dispatch({combined, sources}, funs) do
    {combined, sources ++ [dispatch_source(funs)]}
  end

  # Compile fixture modules and put their beams on the code path so
  # `Code.Typespec.fetch_specs/1` can read them back. `mix test` runs
  # with `debug_info: false` as a runtime compiler option, which would
  # strip the chunk fetch_specs reads — flip it on for the fixture
  # compile, serialized through CompileLock (compiler options are
  # global state).
  defp compile_fixtures(source, tmp) do
    beam_dir = Path.join(tmp, "ebin")
    File.mkdir_p!(beam_dir)

    compiled =
      Agent.get(
        Number42.RefactorCase.CompileLock,
        fn _ ->
          previous = Code.compiler_options()[:debug_info]
          Code.put_compiler_option(:debug_info, true)

          try do
            Code.compile_string(source)
          after
            Code.put_compiler_option(:debug_info, previous)
          end
        end,
        :infinity
      )

    for {mod, bin} <- compiled, do: File.write!(Path.join(beam_dir, "#{mod}.beam"), bin)
    Code.append_path(beam_dir)

    mods = Enum.map(compiled, fn {mod, _bin} -> mod end)

    on_exit(fn ->
      Code.delete_path(beam_dir)

      Enum.each(mods, fn mod ->
        :code.purge(mod)
        :code.delete(mod)
      end)
    end)

    mods
  end

  defp adapter_family(ns) do
    [
      {"#{ns}.Mailers.SmtpAdapter",
       """
         @spec send_message(binary(), keyword()) :: :ok
         def send_message(_to, _opts), do: :ok
         def configure(opts) when is_list(opts), do: {:ok, opts}
         def configure(_opts), do: :error
       """},
      {"#{ns}.Mailers.SendgridAdapter",
       """
         @spec send_message(binary(), keyword()) :: :ok
         def send_message(_to, _opts), do: :ok
         def configure(_opts), do: :ok
       """}
    ]
  end

  describe "detection" do
    test "pairs share the introspected subset; siblings outrank same-depth strangers", %{
      tmp: tmp
    } do
      ns = unique_ns()

      {combined, sources} =
        fixture([
          {"#{ns}.Adapters.Smtp",
           """
             def send_message(_to, _body), do: :ok
             def configure(_opts), do: :ok
           """},
          {"#{ns}.Adapters.Sendgrid",
           """
             def send_message(_to, _body), do: :ok
             def configure(_opts), do: :ok
           """},
          {"#{ns}.Workers.Cleanup",
           """
             def send_message(_to, _body), do: :ok
           """}
        ])

      mods = compile_fixtures(combined, tmp)
      plan = Subject.build_plan(mods, sources, write_root: tmp, dry_run: true)

      [top, second, third] = plan.pairs

      assert top.a == Module.concat([ns, "Adapters", "Sendgrid"])
      assert top.b == Module.concat([ns, "Adapters", "Smtp"])
      assert top.shared == [configure: 1, send_message: 2]
      assert top.score == 50
      assert top.siblings?
      assert top.jaccard == 1.0

      for pair <- [second, third] do
        assert pair.shared == [send_message: 2]
        refute pair.siblings?
        assert pair.same_depth?
        assert pair.score == 25
      end
    end

    test "callbacks of an already implemented behaviour are excluded", %{tmp: tmp} do
      ns = unique_ns()

      {combined, sources} =
        fixture([
          {"#{ns}.Port",
           """
             @callback ping(term()) :: :ok
           """},
          {"#{ns}.Adapters.A",
           """
             @behaviour #{ns}.Port
             @impl true
             def ping(_x), do: :ok
           """},
          {"#{ns}.Adapters.B",
           """
             @behaviour #{ns}.Port
             @impl true
             def ping(_x), do: :ok
           """}
        ])

      mods = compile_fixtures(combined, tmp)
      plan = Subject.build_plan(mods, sources, write_root: tmp, dry_run: true)

      assert plan.pairs == []
      assert plan.families == []
    end

    test "functions missing from the source (macro-generated) don't count", %{tmp: tmp} do
      ns = unique_ns()

      # Compiled surface has both functions; the source files only show
      # one — the other simulates a `use`-injected definition.
      combined = """
      defmodule #{ns}.Adapters.A do
        def visible(_x), do: :ok
        def injected(_x), do: :ok
      end

      defmodule #{ns}.Adapters.B do
        def visible(_x), do: :ok
        def injected(_x), do: :ok
      end
      """

      sources = [
        {"lib/" <> Macro.underscore("#{ns}.Adapters.A") <> ".ex",
         "defmodule #{ns}.Adapters.A do\n  def visible(_x), do: :ok\nend\n"},
        {"lib/" <> Macro.underscore("#{ns}.Adapters.B") <> ".ex",
         "defmodule #{ns}.Adapters.B do\n  def visible(_x), do: :ok\nend\n"}
      ]

      mods = compile_fixtures(combined, tmp)
      plan = Subject.build_plan(mods, sources, write_root: tmp, dry_run: true)

      assert [%{shared: [visible: 1]}] = plan.pairs
    end

    test "defdelegates don't count as implemented functions", %{tmp: tmp} do
      ns = unique_ns()

      # Both modules expose `relay/1` only via `defdelegate` — a call site
      # not yet rewritten, not a real implementation. Only the genuine
      # `def handle/1` they share may form a pair; the delegated function
      # must not inflate the surface.
      {combined, sources} =
        fixture([
          {"#{ns}.Adapters.A",
           """
             defdelegate relay(x), to: Kernel, as: :inspect
             def handle(_x), do: :ok
           """},
          {"#{ns}.Adapters.B",
           """
             defdelegate relay(x), to: Kernel, as: :inspect
             def handle(_x), do: :ok
           """}
        ])

      mods = compile_fixtures(combined, tmp)
      plan = Subject.build_plan(mods, sources, write_root: tmp, dry_run: true)

      assert [%{shared: [handle: 1]}] = plan.pairs
    end

    test "a family without a polymorphic call site is not extracted", %{tmp: tmp} do
      ns = unique_ns()

      # Three modules share `get/1` — formally a family, but nothing in the
      # sources calls `get/1` through a dynamic receiver. Form alone does
      # not justify a behaviour.
      {combined, sources} =
        fixture([
          {"#{ns}.Stores.A", "  def get(_x), do: :ok\n"},
          {"#{ns}.Stores.B", "  def get(_x), do: :ok\n"},
          {"#{ns}.Stores.C", "  def get(_x), do: :ok\n"}
        ])

      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, require_dispatch: true)

      assert [_, _, _] = plan.pairs
      assert plan.families == []
    end

    test "a dynamic call site justifies the family", %{tmp: tmp} do
      ns = unique_ns()

      # Same three stores, plus a router that picks a store at runtime and
      # dispatches `get/1` through the variable — that is the polymorphic
      # use a behaviour exists for.
      {combined, sources} =
        fixture([
          {"#{ns}.Stores.A", "  def get(_x), do: :ok\n"},
          {"#{ns}.Stores.B", "  def get(_x), do: :ok\n"},
          {"#{ns}.Stores.C", "  def get(_x), do: :ok\n"}
        ])
        |> with_dispatch(get: 1)

      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, require_dispatch: true)

      assert [%{callbacks: [get: 1], members: [_, _, _]}] = plan.families
    end

    test "apply/3 with a non-literal arg list dispatches at any arity", %{tmp: tmp} do
      ns = unique_ns()

      {combined, base_sources} =
        fixture([
          {"#{ns}.Stores.A", "  def fetch(_x), do: :ok\n"},
          {"#{ns}.Stores.B", "  def fetch(_x), do: :ok\n"},
          {"#{ns}.Stores.C", "  def fetch(_x), do: :ok\n"}
        ])

      # apply(mod, :fetch, args) — args is a variable, so the arity is
      # unknown; it must still match `fetch/1`.
      apply_site =
        {"lib/router.ex",
         "defmodule Router do\n  def run(mod, args), do: apply(mod, :fetch, args)\nend\n"}

      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, base_sources ++ [apply_site],
          write_root: tmp,
          dry_run: true,
          require_dispatch: true
        )

      assert [%{callbacks: [fetch: 1]}] = plan.families
    end

    test "a static call site does not justify the family", %{tmp: tmp} do
      ns = unique_ns()

      {combined, base_sources} =
        fixture([
          {"#{ns}.Stores.A", "  def get(_x), do: :ok\n"},
          {"#{ns}.Stores.B", "  def get(_x), do: :ok\n"},
          {"#{ns}.Stores.C", "  def get(_x), do: :ok\n"}
        ])

      # A fully-qualified call names its target directly — no behaviour
      # needed, so it must not count as dispatch evidence.
      static_site =
        {"lib/caller.ex", "defmodule Caller do\n  def run, do: #{ns}.Stores.A.get(:x)\nend\n"}

      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, base_sources ++ [static_site],
          write_root: tmp,
          dry_run: true,
          require_dispatch: true
        )

      assert plan.families == []
    end

    test "a framework receiver does not count as dispatch", %{tmp: tmp} do
      ns = unique_ns()

      {combined, base_sources} =
        fixture([
          {"#{ns}.Stores.A", "  def all, do: :ok\n"},
          {"#{ns}.Stores.B", "  def all, do: :ok\n"},
          {"#{ns}.Stores.C", "  def all, do: :ok\n"}
        ])

      # `repo.all()` is an Ecto call that merely shares the name `all/0`
      # with the family — it must not justify the behaviour.
      repo_site = {"lib/loader.ex", "defmodule Loader do\n  def run(repo), do: repo.all()\nend\n"}

      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, base_sources ++ [repo_site],
          write_root: tmp,
          dry_run: true,
          require_dispatch: true
        )

      assert plan.families == []
    end

    test "overlapping families keep the higher-ranked one and report the conflict", %{tmp: tmp} do
      ns = unique_ns()

      # Two distinct shared sets within the same dominant group, both
      # containing Hub and overlapping on `send_message`: the larger set
      # wins, the smaller is reported as an impl conflict.
      {combined, sources} =
        fixture([
          {"#{ns}.Adapters.Hub",
           """
             def send_message(_to, _body), do: :ok
             def configure(_opts), do: :ok
             def ping(_x), do: :ok
           """},
          {"#{ns}.Adapters.SmtpAdapter",
           """
             def send_message(_to, _body), do: :ok
             def configure(_opts), do: :ok
           """},
          {"#{ns}.Adapters.PingAdapter",
           """
             def send_message(_to, _body), do: :ok
             def ping(_x), do: :ok
           """}
        ])

      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, require_dispatch: false)

      assert [%{callbacks: [configure: 1, send_message: 2]}] = plan.families

      # Seeding per dispatched callback yields more overlapping candidates;
      # every family sharing both a member and a callback with the winner
      # is reported as an impl conflict.
      reasons = Enum.map(plan.skipped, & &1.reason)
      assert Enum.all?(reasons, &(&1 == :impl_conflict))
      conflict_sets = Enum.map(plan.skipped, & &1.callbacks)
      assert [ping: 1, send_message: 2] in conflict_sets
    end

    test "erlang modules and protocols are skipped" do
      assert Subject.introspect([:lists, Enumerable]) == %{}
    end

    test "min_callbacks and min_modules stay hard floors above the substance rule", %{tmp: tmp} do
      ns = unique_ns()
      {combined, sources} = fixture(adapter_family(ns))
      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, min_callbacks: 3)

      assert [_pair] = plan.pairs
      assert plan.families == []

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, min_modules: 3)

      assert plan.families == []
    end

    test "substance rule: one shared callback needs three modules", %{tmp: tmp} do
      ns = unique_ns()

      two = """
      defmodule #{ns}.Two.A do
        def only(_x), do: :ok
      end

      defmodule #{ns}.Two.B do
        def only(_x), do: :ok
      end
      """

      mods = compile_fixtures(two, tmp)

      sources =
        for m <- mods,
            do:
              {"lib/" <> Macro.underscore(inspect(m)) <> ".ex",
               "defmodule #{inspect(m)} do\n  def only(_x), do: :ok\nend\n"}

      # 1 callback × 2 modules → below the bar
      plan = Subject.build_plan(mods, sources, write_root: tmp, dry_run: true)
      assert [_pair] = plan.pairs
      assert plan.families == []
    end

    test "substance rule: two shared callbacks qualify at two modules", %{tmp: tmp} do
      ns = unique_ns()
      {combined, sources} = fixture(adapter_family(ns))
      mods = compile_fixtures(combined, tmp)

      # 2 callbacks × 2 modules → qualifies
      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, require_dispatch: false)

      assert [%{callbacks: [configure: 1, send_message: 2]}] = plan.families
    end
  end

  describe "optional callbacks" do
    test "a majority-shared function becomes an optional callback", %{tmp: tmp} do
      ns = unique_ns()

      # The only set all four share exactly is `get/1` → the seed. Three of
      # four also expose `all/0`, so the family absorbs them and `all/0`
      # (> 50%) becomes optional. `extra/0` sits at one member (<= 50%) and
      # is left out entirely.
      {combined, sources} =
        fixture([
          {"#{ns}.Stores.A", "  def get(_x), do: :ok\n  def all, do: :ok\n"},
          {"#{ns}.Stores.B", "  def get(_x), do: :ok\n  def all, do: :ok\n"},
          {"#{ns}.Stores.C", "  def get(_x), do: :ok\n  def all, do: :ok\n"},
          {"#{ns}.Stores.D", "  def get(_x), do: :ok\n  def extra, do: :ok\n"}
        ])
        |> with_dispatch(get: 1)

      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, require_dispatch: true)

      assert [family] = plan.families
      assert family.callbacks == [get: 1]
      assert [{:all, 0}] = Enum.map(family.optional, fn {cb, _} -> cb end)
      assert [{{:all, 0}, optional_members}] = family.optional
      assert length(optional_members) == 3
      assert length(family.members) == 4
    end

    test "the rendered behaviour declares @optional_callbacks", %{tmp: tmp} do
      ns = unique_ns()

      {combined, sources} =
        fixture([
          {"#{ns}.Stores.A", "  def get(_x), do: :ok\n  def all, do: :ok\n"},
          {"#{ns}.Stores.B", "  def get(_x), do: :ok\n  def all, do: :ok\n"},
          {"#{ns}.Stores.C", "  def get(_x), do: :ok\n"}
        ])
        |> with_dispatch(get: 1)

      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, require_dispatch: true)

      assert [family] = plan.families
      assert family.rendered =~ "@callback get(term()) :: term()"
      assert family.rendered =~ "@callback all() :: term()"
      assert family.rendered =~ "@optional_callbacks [all: 0]"
    end

    test "only members implementing an optional callback get @impl for it", %{tmp: tmp} do
      ns = unique_ns()

      {combined, sources} =
        fixture([
          {"#{ns}.Stores.A", "  def get(_x), do: :ok\n  def all, do: :ok\n"},
          {"#{ns}.Stores.B", "  def get(_x), do: :ok\n  def all, do: :ok\n"},
          {"#{ns}.Stores.C", "  def get(_x), do: :ok\n"}
        ])
        |> with_dispatch(get: 1)

      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, require_dispatch: true)

      a = plan.implementations[Module.concat([ns, "Stores", "A"])]
      c = plan.implementations[Module.concat([ns, "Stores", "C"])]

      assert {:all, 0} in Enum.flat_map(a.families, & &1.callbacks)
      refute {:all, 0} in Enum.flat_map(c.families, & &1.callbacks)
    end
  end

  describe "behaviour synthesis" do
    test "synthesizes a behaviour with spec-derived and broad fallback callbacks", %{tmp: tmp} do
      ns = unique_ns()
      {combined, sources} = fixture(adapter_family(ns))
      mods = compile_fixtures(combined, tmp)

      plan = Subject.build_plan(mods, sources, write_root: tmp, require_dispatch: false)

      behaviour = Module.concat([ns, "Mailers", "AdapterBehaviour"])
      assert [%{behaviour: ^behaviour} = family] = plan.families
      assert family.callbacks == [configure: 1, send_message: 2]

      assert family.path ==
               Path.join(tmp, "lib/#{Macro.underscore(ns)}/mailers/adapter_behaviour.ex")

      # agreed @spec across members → spec-derived callback
      assert family.rendered =~ "@callback send_message(binary(), keyword()) :: :ok"
      # no @spec anywhere → broad fallback
      assert family.rendered =~ "@callback configure(term()) :: term()"

      assert File.read!(family.path) == family.rendered
      assert Map.keys(plan.implementations) |> Enum.sort() == Enum.sort(mods)

      assert %{families: [%{behaviour: ^behaviour, callbacks: [configure: 1, send_message: 2]}]} =
               plan.implementations[hd(Enum.sort(mods))]
    end

    test "conflicting specs fall back to the broad callback", %{tmp: tmp} do
      ns = unique_ns()

      {combined, sources} =
        fixture([
          {"#{ns}.Adapters.FooAdapter",
           """
             @spec ping(integer()) :: :ok
             def ping(_x), do: :ok
           """},
          {"#{ns}.Adapters.BarAdapter",
           """
             @spec ping(binary()) :: :ok
             def ping(_x), do: :ok
           """},
          {"#{ns}.Adapters.BazAdapter",
           """
             @spec ping(atom()) :: :ok
             def ping(_x), do: :ok
           """}
        ])

      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, require_dispatch: false)

      assert [family] = plan.families
      assert family.rendered =~ "@callback ping(term()) :: term()"
    end

    test "spec-local types are qualified to their origin so the behaviour compiles", %{tmp: tmp} do
      ns = unique_ns()

      # Both members agree on the spec shape but express it through a
      # module-local @type. Copied verbatim into the behaviour module
      # that type would dangle — it must be qualified back to its origin.
      {combined, sources} =
        fixture([
          {"#{ns}.AST.Humanizer",
           """
             @type attribute :: {atom(), term()}
             @spec classify(attribute()) :: :ok
             def classify(_a), do: :ok
             @spec transform(attribute(), keyword()) :: attribute()
             def transform(a, _opts), do: a
           """},
          {"#{ns}.AST.Tokenizer",
           """
             @type attribute :: {atom(), term()}
             @spec classify(attribute()) :: :ok
             def classify(_a), do: :ok
             @spec transform(attribute(), keyword()) :: attribute()
             def transform(a, _opts), do: a
           """}
        ])

      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, require_dispatch: false)

      assert [family] = plan.families
      # the local type is qualified to whichever member is canonical
      assert family.rendered =~ ~r/@callback classify\(#{ns}\.AST\.\w+\.attribute\(\)\) :: :ok/

      assert family.rendered =~
               ~r/transform\(#{ns}\.AST\.\w+\.attribute\(\), keyword\(\)\) ::\s*#{ns}\.AST\.\w+\.attribute\(\)/

      # and it actually compiles (the original crash was a dangling type)
      fresh = String.replace(family.rendered, ns, unique_ns())
      assert_compiles(fresh)
    end

    test "dry_run populates the plan but writes nothing", %{tmp: tmp} do
      ns = unique_ns()
      {combined, sources} = fixture(adapter_family(ns))
      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, require_dispatch: false)

      assert [family] = plan.families
      refute File.exists?(family.path)
    end

    test "rebuilding the plan after the write is stable", %{tmp: tmp} do
      ns = unique_ns()
      {combined, sources} = fixture(adapter_family(ns))
      mods = compile_fixtures(combined, tmp)

      plan1 = Subject.build_plan(mods, sources, write_root: tmp, require_dispatch: false)
      plan2 = Subject.build_plan(mods, sources, write_root: tmp, require_dispatch: false)

      assert [family1] = plan1.families
      assert [family2] = plan2.families
      assert family1.behaviour == family2.behaviour
      assert File.read!(family2.path) == family2.rendered
    end

    test "naming collision with a loaded module skips the family", %{tmp: tmp} do
      ns = unique_ns()
      {combined, sources} = fixture(adapter_family(ns))

      mods =
        compile_fixtures(combined <> "\ndefmodule #{ns}.Mailers.AdapterBehaviour do\nend\n", tmp)

      family_mods = Enum.reject(mods, &(&1 == Module.concat([ns, "Mailers", "AdapterBehaviour"])))

      plan =
        Subject.build_plan(family_mods, sources,
          write_root: tmp,
          dry_run: true,
          require_dispatch: false
        )

      assert plan.families == []
      assert [%{reason: :naming_collision}] = plan.skipped
    end

    test "a foreign file at the target path skips the family", %{tmp: tmp} do
      ns = unique_ns()
      {combined, sources} = fixture(adapter_family(ns))
      mods = compile_fixtures(combined, tmp)

      target = Path.join(tmp, "lib/#{Macro.underscore(ns)}/mailers/adapter_behaviour.ex")
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, "defmodule Unrelated do\nend\n")

      plan = Subject.build_plan(mods, sources, write_root: tmp, require_dispatch: false)

      assert plan.families == []
      assert [%{reason: :naming_collision}] = plan.skipped
      assert File.read!(target) =~ "Unrelated"
    end

    test "members sitting directly under the app root form no family", %{tmp: tmp} do
      ns = unique_ns()

      # Both members live at `<ns>.Smtp` / `<ns>.Sendgrid` — directly
      # under the app root, no sub-namespace. Two bare-root members are
      # below the large-group bar, so no behaviour is created at all.
      {combined, sources} =
        fixture([
          {"#{ns}.Smtp",
           """
             def send_message(_to, _body), do: :ok
             def configure(_opts), do: :ok
           """},
          {"#{ns}.Sendgrid",
           """
             def send_message(_to, _body), do: :ok
             def configure(_opts), do: :ok
           """}
        ])

      mods = compile_fixtures(combined, tmp)
      plan = Subject.build_plan(mods, sources, write_root: tmp, dry_run: true)

      assert [%{shared: [configure: 1, send_message: 2]}] = plan.pairs
      assert plan.families == []
    end

    test "a large bare-root family is accepted and named under the root", %{tmp: tmp} do
      ns = unique_ns()

      # Four modules directly under the app root sharing one genuine
      # `authorize/2` — no sub-namespace dominates, but the root group
      # clears the large-group bar, so the behaviour lands under the root.
      {combined, sources} =
        fixture(
          for seg <- ~w(Assets Items Positions Settings) do
            {"#{ns}.#{seg}", "  def authorize(_action, _user), do: :ok\n"}
          end
        )

      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, require_dispatch: false)

      assert [%{callbacks: [authorize: 2], members: members, behaviour: behaviour}] =
               plan.families

      assert length(members) == 4
      # Named directly under the app root — no sub-namespace segment.
      assert Module.split(behaviour) == [ns, "AuthorizerBehaviour"]
    end

    test "a path-group tie resolves to the largest group when it is large enough", %{tmp: tmp} do
      ns = unique_ns()

      # Two equal-size sub-namespace groups (`Alpha.*` and `Beta.*`, four
      # each) sharing `cast/1`. A strict tie check would skip the family;
      # instead the bar-clearing groups break the tie alphabetically —
      # `Alpha` wins, `Beta` is dropped.
      alpha = for seg <- ~w(A B C D), do: {"#{ns}.Alpha.#{seg}", "  def cast(_x), do: :ok\n"}
      beta = for seg <- ~w(E F G H), do: {"#{ns}.Beta.#{seg}", "  def cast(_x), do: :ok\n"}

      {combined, sources} = fixture(alpha ++ beta)
      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, require_dispatch: false)

      assert [%{callbacks: [cast: 1], members: members, root_path: ["Alpha"]}] = plan.families
      assert length(members) == 4
      assert Enum.all?(members, &(Module.split(&1) |> Enum.at(1) == "Alpha"))
    end

    test "a path-group tie below the bar is skipped", %{tmp: tmp} do
      ns = unique_ns()

      # Two groups of three: each clears the lone-callback substance rule
      # on its own, but neither reaches the large-group bar, so the tie
      # stays unresolved and no behaviour is created.
      alpha = for seg <- ~w(A B C), do: {"#{ns}.Alpha.#{seg}", "  def cast(_x), do: :ok\n"}
      beta = for seg <- ~w(D E F), do: {"#{ns}.Beta.#{seg}", "  def cast(_x), do: :ok\n"}

      {combined, sources} = fixture(alpha ++ beta)
      mods = compile_fixtures(combined, tmp)
      plan = Subject.build_plan(mods, sources, write_root: tmp, dry_run: true)

      assert plan.families == []
    end

    test "a single shared function names the behaviour after its object", %{tmp: tmp} do
      ns = unique_ns()

      # one shared callback → needs three members to qualify
      {combined, sources} =
        fixture([
          {"#{ns}.Adapters.Smtp",
           """
             def send_message(_to, _body), do: :ok
           """},
          {"#{ns}.Adapters.Sendgrid",
           """
             def send_message(_to, _body), do: :ok
           """},
          {"#{ns}.Adapters.Ses",
           """
             def send_message(_to, _body), do: :ok
           """}
        ])

      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, require_dispatch: false)

      assert [%{behaviour: behaviour}] = plan.families
      # send_message → verb phrase → named after the object "message"
      assert behaviour == Module.concat([ns, "Adapters", "MessageBehaviour"])
    end

    test "a lone verb callback yields an agent-noun name", %{tmp: tmp} do
      ns = unique_ns()

      {combined, sources} =
        fixture([
          {"#{ns}.Adapters.A", "  def render(_x), do: :ok\n"},
          {"#{ns}.Adapters.B", "  def render(_x), do: :ok\n"},
          {"#{ns}.Adapters.C", "  def render(_x), do: :ok\n"}
        ])

      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, require_dispatch: false)

      assert [%{behaviour: behaviour}] = plan.families
      assert behaviour == Module.concat([ns, "Adapters", "RendererBehaviour"])
    end
  end

  describe "transform/2" do
    setup %{tmp: tmp} do
      ns = unique_ns()
      {combined, sources} = fixture(adapter_family(ns))
      mods = compile_fixtures(combined, tmp)

      plan =
        Subject.build_plan(mods, sources, write_root: tmp, dry_run: true, require_dispatch: false)

      [{_path, smtp_source} | _] = sources
      {:ok, ns: ns, plan: plan, smtp_source: smtp_source, sources: sources}
    end

    test "inserts @behaviour and @impl true without disturbing attributes", %{
      ns: ns,
      plan: plan,
      smtp_source: smtp_source
    } do
      expected = """
      defmodule #{ns}.Mailers.SmtpAdapter do
        @behaviour #{ns}.Mailers.AdapterBehaviour

        @spec send_message(binary(), keyword()) :: :ok
        @impl true
        def send_message(_to, _opts), do: :ok
        @impl true
        def configure(opts) when is_list(opts), do: {:ok, opts}
        def configure(_opts), do: :error
      end
      """

      assert_rewrites(@subject, smtp_source, expected, prepared: plan)
    end

    test "is idempotent", %{plan: plan, smtp_source: smtp_source} do
      assert_idempotent(@subject, smtp_source, prepared: plan)
    end

    # assert_rewrites squeezes whitespace — this one pins the exact
    # indentation (Sourceror's patch auto-indent would double it).
    test "inserted attributes keep the module's indentation", %{ns: ns, plan: plan} do
      source = """
      defmodule #{ns}.Mailers.SendgridAdapter do
        @spec send_message(binary(), keyword()) :: :ok
        def send_message(_to, _opts), do: :ok
        def configure(_opts), do: :ok
      end
      """

      assert apply_refactor(@subject, source, prepared: plan) == """
             defmodule #{ns}.Mailers.SendgridAdapter do
               @behaviour #{ns}.Mailers.AdapterBehaviour

               @spec send_message(binary(), keyword()) :: :ok
               @impl true
               def send_message(_to, _opts), do: :ok
               @impl true
               def configure(_opts), do: :ok
             end
             """
    end

    test "transformed members and the rendered behaviour compile together", %{
      ns: ns,
      plan: plan,
      sources: sources
    } do
      assert [family] = plan.families

      transformed =
        Enum.map_join(sources, "\n", fn {_path, src} ->
          apply_refactor(@subject, src, prepared: plan)
        end)

      # fresh namespace → no module redefinition warnings from the
      # already-compiled fixtures
      fresh = String.replace(family.rendered <> "\n" <> transformed, ns, unique_ns())
      assert_compiles(fresh)
    end

    test "member of two families gets grouped @behaviour lines and stays idempotent", %{
      tmp: tmp
    } do
      ns = unique_ns()

      # Hub is a member of two distinct families (each two callbacks, so
      # each clears the substance rule); both families' dominant group is
      # `Core`, so both behaviours root there and attach to Hub. The
      # shared callbacks are disjoint, so both annotate.
      {combined, sources} =
        fixture([
          {"#{ns}.Core.Hub",
           """
             def open(_x), do: :ok
             def close(_x), do: :ok
             def read(_x), do: :ok
             def write(_x), do: :ok
           """},
          {"#{ns}.Core.GatePeer",
           """
             def open(_x), do: :ok
             def close(_x), do: :ok
           """},
          {"#{ns}.Core.StreamPeer",
           """
             def read(_x), do: :ok
             def write(_x), do: :ok
           """}
        ])
        |> with_dispatch(open: 1, close: 1, read: 1, write: 1)

      mods = compile_fixtures(combined, tmp)
      plan = Subject.build_plan(mods, sources, write_root: tmp, dry_run: true)

      assert length(plan.families) == 2
      [{_path, hub_source} | _] = sources

      hub_impls = plan.implementations[Module.concat([ns, "Core", "Hub"])]
      assert length(hub_impls.families) == 2

      result = apply_refactor(@subject, hub_source, prepared: plan)

      # both behaviours land under Core, grouped before the first @impl
      assert result |> String.split("@behaviour") |> length() == 3
      assert result |> String.split("@impl true") |> hd() =~ ~r/@behaviour.*@behaviour/s
      assert length(String.split(result, "@impl true")) == 5
      assert_idempotent(@subject, hub_source, prepared: plan)
    end

    test "leaves non-members alone", %{plan: plan} do
      source = """
      defmodule TotallyUnrelated do
        def send_message(_to, _opts), do: :ok
      end
      """

      assert_unchanged(@subject, source, prepared: plan)
    end

    test "annotates pre-existing callbacks so @impl stays all-or-nothing", %{tmp: tmp} do
      ns = unique_ns()

      # A behaviour the members already implement (its callback resolves
      # unambiguously). Once we mark `changeset/3` with @impl, Elixir's
      # all-or-nothing rule demands @impl on `scope/3` too — the patcher
      # must annotate it with its origin behaviour.
      prelude = """
      defmodule #{ns}.Scoped do
        @callback scope(term(), term(), term()) :: term()
      end
      """

      {family_src, sources} =
        fixture([
          {"#{ns}.Schema.Mass",
           """
             @behaviour #{ns}.Scoped
             def scope(q, _s, _p), do: q
             def changeset(_a, _b, _c), do: :ok
             def normalize(x), do: x
           """},
          {"#{ns}.Schema.Option",
           """
             @behaviour #{ns}.Scoped
             def scope(q, _s, _p), do: q
             def changeset(_a, _b, _c), do: :ok
             def normalize(x), do: x
           """}
        ])

      mods = compile_fixtures(prelude <> "\n" <> family_src, tmp)
      family_mods = Enum.reject(mods, &(&1 == Module.concat([ns, "Scoped"])))

      plan =
        Subject.build_plan(family_mods, sources,
          write_root: tmp,
          dry_run: true,
          require_dispatch: false
        )

      assert [family] = plan.families
      [{_path, mass_source} | _] = sources

      result = apply_refactor(@subject, mass_source, prepared: plan)

      # extracted callback → @impl true; pre-existing scope/3 → @impl Scoped
      assert result =~ "@impl true\n  def changeset"
      assert result =~ "@impl #{ns}.Scoped\n  def scope"

      # the whole thing compiles with NO all-or-nothing @impl warning —
      # render the synthesized behaviour and the prelude alongside it.
      fresh =
        String.replace(prelude <> "\n" <> family.rendered <> "\n" <> result, ns, unique_ns())

      assert_compiles(fresh)
    end

    test "no-ops without a prepared plan" do
      source = """
      defmodule Whatever do
        def f(_x), do: :ok
      end
      """

      assert_unchanged(@subject, source)
    end
  end

  describe "prepare/1" do
    test "builds the plan from explicit modules and on-disk paths", %{tmp: tmp} do
      ns = unique_ns()
      {combined, sources} = fixture(adapter_family(ns)) |> with_dispatch(send_message: 2)
      mods = compile_fixtures(combined, tmp)

      paths =
        for {rel_path, src} <- sources do
          abs = Path.join(tmp, rel_path)
          File.mkdir_p!(Path.dirname(abs))
          File.write!(abs, src)
          abs
        end

      assert {:ok, plan} =
               Subject.prepare(modules: mods, paths: paths, write_root: tmp, dry_run: true)

      assert [%{behaviour: behaviour}] = plan.families
      assert behaviour == Module.concat([ns, "Mailers", "AdapterBehaviour"])

      # absolute member paths under tmp → derived path stays under tmp
      assert [family] = plan.families
      assert String.starts_with?(family.path, tmp)
    end
  end
end
