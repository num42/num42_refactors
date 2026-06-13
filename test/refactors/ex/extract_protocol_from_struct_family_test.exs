defmodule Number42.Refactors.Ex.ExtractProtocolFromStructFamilyTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractProtocolFromStructFamily, as: Subject

  # `[{path, source}]` from `[{module_name, body}]`.
  defp sources(modules) do
    Enum.map(modules, fn {name, body} ->
      {"lib/" <> Macro.underscore(name) <> ".ex", "defmodule #{name} do\n#{body}end\n"}
    end)
  end

  # Detection-only assertions run dry so they never touch the filesystem.
  defp detect(modules, opts \\ []) do
    Subject.build_plan(sources(modules), Keyword.put(opts, :dry_run, true))
  end

  describe "detection" do
    test "a function over 3 distinct structs is a candidate" do
      plan =
        detect([
          {"Label",
           """
             def label(%Brand{} = b), do: b.name
             def label(%Item{} = i), do: i.title
             def label(%Asset{} = a), do: a.filename
           """}
        ])

      assert [%{name: :label, arity: 1, structs: structs}] = plan.candidates
      assert structs == [Asset, Brand, Item]
      assert plan.rejected == []
    end

    test "candidates may span several modules but are not synthesized" do
      plan =
        detect([
          {"A", "  def render(%Box{} = b), do: b\n"},
          {"B", "  def render(%Circle{} = c), do: c\n"},
          {"C", "  def render(%Line{} = l), do: l\n"}
        ])

      assert [%{name: :render, structs: [Box, Circle, Line]}] = plan.candidates
      # clauses scattered across modules can't source one protocol
      assert [%{name: :render, reason: :cross_module}] = plan.skipped
      assert plan.synthesized == []
    end

    test "the dispatch struct may be matched with field destructuring" do
      plan =
        detect([
          {"Label",
           """
             def label(%Brand{name: n}), do: n
             def label(%Item{title: t}), do: t
             def label(%Asset{file: f}), do: f
           """}
        ])

      assert [%{name: :label, structs: [Asset, Brand, Item]}] = plan.candidates
    end

    test "nested-alias struct modules resolve to their full name" do
      plan =
        detect([
          {"L",
           """
             def f(%Catalog.Brand{} = b), do: b
             def f(%Catalog.Item{} = i), do: i
             def f(%Shared.Asset{} = a), do: a
           """}
        ])

      assert [%{name: :f, structs: structs}] = plan.candidates
      assert structs == [Catalog.Brand, Catalog.Item, Shared.Asset]
    end
  end

  describe "form-equality guards" do
    test "5 clauses over ONE struct is a single-struct overload, not a candidate" do
      plan =
        detect([
          {"Asset",
           """
             def image_url(%Asset{} = a), do: a.url
             def image_url(%Asset{} = a, :thumb), do: a.thumb
             def image_url(%Asset{} = a, :full), do: a.full
           """}
        ])

      assert plan.candidates == []
      # both arities pattern-match exactly one struct; the multi-clause
      # one is flagged as the overload trap the docs warn about.
      assert Enum.all?(plan.rejected, &(&1.structs == [Asset]))
      assert %{reason: :single_struct_overload} = Enum.find(plan.rejected, &(&1.arity == 2))
    end

    test "2 distinct structs is below the default floor of 3" do
      plan =
        detect([
          {"L",
           """
             def list(%Foo{} = f), do: f
             def list(%Bar{} = b), do: b
           """}
        ])

      assert plan.candidates == []
      assert [%{name: :list, structs: [Bar, Foo], reason: :below_min_structs}] = plan.rejected
    end

    test ":min_structs lowers the floor" do
      plan =
        detect(
          [
            {"L",
             """
               def list(%Foo{} = f), do: f
               def list(%Bar{} = b), do: b
             """}
          ],
          min_structs: 2
        )

      assert [%{name: :list, structs: [Bar, Foo]}] = plan.candidates
      assert plan.rejected == []
    end
  end

  describe "non-candidates" do
    test "private defs are ignored — a protocol is a public surface" do
      plan =
        detect([
          {"L",
           """
             defp build(%Foo{} = f), do: f
             defp build(%Bar{} = b), do: b
             defp build(%Baz{} = z), do: z
           """}
        ])

      assert plan.candidates == []
      assert plan.rejected == []
    end

    test "non-struct first args contribute nothing" do
      plan =
        detect([
          {"L",
           """
             def f(%{a: 1} = m), do: m
             def f(x) when is_integer(x), do: x
             def f([h | _]), do: h
           """}
        ])

      assert plan.candidates == []
      assert plan.rejected == []
    end

    test "a struct in a non-dispatch position is ignored by default" do
      plan =
        detect([
          {"L",
           """
             def f(ctx, %Brand{} = b), do: {ctx, b}
             def f(ctx, %Item{} = i), do: {ctx, i}
             def f(ctx, %Asset{} = a), do: {ctx, a}
           """}
        ])

      assert plan.candidates == []
    end

    test ":dispatch_arg points the report at a consistent later position" do
      plan =
        detect(
          [
            {"L",
             """
               def f(ctx, %Brand{} = b), do: {ctx, b}
               def f(ctx, %Item{} = i), do: {ctx, i}
               def f(ctx, %Asset{} = a), do: {ctx, a}
             """}
          ],
          dispatch_arg: 1
        )

      assert [%{name: :f, arity: 2, structs: [Asset, Brand, Item]}] = plan.candidates
    end

    test "test/ and dev/ sources are excluded" do
      plan =
        Subject.build_plan(
          [
            {"test/some_test.exs",
             "defmodule T do\n  def f(%A{} = a), do: a\n  def f(%B{} = b), do: b\n  def f(%C{} = c), do: c\nend\n"}
          ],
          dry_run: true
        )

      assert plan.candidates == []
    end

    test "unparseable sources are skipped, not raised" do
      plan = Subject.build_plan([{"lib/broken.ex", "defmodule Broken do def ("}], dry_run: true)
      assert plan.candidates == []
    end
  end

  describe "synthesis" do
    test "a single-module candidate synthesizes a protocol named after the function" do
      plan =
        detect([
          {"Catalog.Labeling",
           """
             def label(%Brand{} = b), do: b.name
             def label(%Item{} = i), do: i.title
             def label(%Asset{} = a), do: a.filename
           """}
        ])

      assert [syn] = plan.synthesized
      assert syn.protocol == Catalog.Labelable
      assert syn.source_module == Catalog.Labeling
      assert syn.structs == [Asset, Brand, Item]
      assert syn.name_shift?
    end

    test "the rendered protocol declares one def head and one defimpl per struct" do
      [syn] = synthesize_one_protocol()

      assert syn.rendered =~ "defprotocol Catalog.Labelable do"
      assert syn.rendered =~ "def label(data)"
      assert syn.rendered =~ "defimpl Catalog.Labelable, for: Brand do"
      assert syn.rendered =~ "defimpl Catalog.Labelable, for: Item do"
      assert syn.rendered =~ "defimpl Catalog.Labelable, for: Asset do"
      # the migrated clause body rides along verbatim
      assert syn.rendered =~ "def label(%Brand{} = b), do: b.name"
    end

    test "the rendered protocol + impls compile against real structs" do
      # Unique struct + protocol names: assert_compiles loads the rendered
      # modules, and `defprotocol` modules outlive the test's purge — a
      # shared name would make the synthesizer's `Code.ensure_loaded?`
      # collision guard skip a later test.
      tag = System.unique_integer([:positive])

      [syn] =
        synthesize([
          {"Catalog.Labeling#{tag}",
           """
             def stamp(%Brand#{tag}{} = b), do: b.name
             def stamp(%Item#{tag}{} = i), do: i.title
             def stamp(%Asset#{tag}{} = a), do: a.file
           """}
        ])

      prelude = """
      defmodule Brand#{tag} do
        defstruct [:name]
      end

      defmodule Item#{tag} do
        defstruct [:title]
      end

      defmodule Asset#{tag} do
        defstruct [:file]
      end
      """

      assert_compiles(prelude <> "\n" <> syn.rendered)
    end

    test "an agreed @spec is lifted to the protocol with the dispatch type as t()" do
      {_source, plan} =
        prepared("""
        defmodule Catalog.Labeling do
          @spec label(term()) :: String.t()
          def label(%Brand{} = b), do: b.name
          def label(%Item{} = i), do: i.title
          def label(%Asset{} = a), do: a.filename
        end
        """)

      assert [syn] = plan.synthesized
      assert syn.rendered =~ "@spec label(t()) :: String.t()"
    end

    test "a missing spec falls back to a broad term() callback" do
      [syn] = synthesize_one_protocol()
      assert syn.rendered =~ "@spec label(t()) :: term()"
    end

    test "the protocol name passes -able forms through and trims trailing e" do
      [render] =
        synthesize([
          {"Geo.Rendering",
           """
             def render(%Box{} = b), do: b
             def render(%Circle{} = c), do: c
             def render(%Line{} = l), do: l
           """}
        ])

      assert render.protocol == Geo.Renderable
    end

    test "dry_run populates the plan but writes nothing" do
      tmp = tmp_dir()
      path = Path.join(tmp, "lib/catalog/labeling.ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, labeling_source())

      plan = Subject.build_plan([{path, labeling_source()}], write_root: tmp, dry_run: true)

      assert [_] = plan.synthesized
      refute File.exists?(Path.join(tmp, "lib/catalog/labelable.ex"))
    end

    test "prepare writes the protocol file next to the source layout" do
      tmp = tmp_dir()
      path = Path.join(tmp, "lib/catalog/labeling.ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, labeling_source())

      assert {:ok, plan} = Subject.prepare(paths: [path], write_root: tmp)
      assert [%{path: written}] = plan.synthesized
      assert written == Path.join(tmp, "lib/catalog/labelable.ex")
      assert File.exists?(written)
      assert File.read!(written) =~ "defprotocol Catalog.Labelable"
    end
  end

  describe "transform/2 — clause removal" do
    test "removes the migrated clauses (and their @spec) from the source module" do
      {source, plan} = prepared(labeling_source())
      out = Subject.transform(source, prepared: plan)

      refute out =~ "def label(%Brand{}"
      refute out =~ "def label(%Item{}"
      refute out =~ "def label(%Asset{}"
      # the orphaned @spec for the migrated function goes too
      refute out =~ "@spec label"
      # untouched siblings remain
      assert out =~ "def other(x), do: x"
    end

    test "is a no-op without a prepared plan" do
      assert Subject.transform(labeling_source(), []) == labeling_source()
    end

    test "is a no-op when nothing was synthesized" do
      assert Subject.transform("defmodule M do\n  def f(x), do: x\nend\n",
               prepared: %{synthesized: []}
             ) ==
               "defmodule M do\n  def f(x), do: x\nend\n"
    end
  end

  describe "transform/2 — call-site rewrite (Slice 3)" do
    test "static calls to the source module shift to the protocol on a name shift" do
      source = """
      defmodule Catalog.Labeling do
        @spec label(term()) :: String.t()
        def label(%Brand{} = b), do: b.name
        def label(%Item{} = i), do: i.title
        def label(%Asset{} = a), do: a.filename

        def show(x), do: Catalog.Labeling.label(x)
      end
      """

      {_src, plan} = prepared(source)
      out = Subject.transform(source, prepared: plan)

      assert out =~ "def show(x), do: Catalog.Labelable.label(x)"
      refute out =~ "Catalog.Labeling.label(x)"
    end

    test "calls to a same-named, different-arity function are left alone" do
      source = """
      defmodule Catalog.Labeling do
        def label(%Brand{} = b), do: b.name
        def label(%Item{} = i), do: i.title
        def label(%Asset{} = a), do: a.filename

        def show(x, opts), do: Catalog.Labeling.label(x, opts)
      end
      """

      {_src, plan} = prepared(source)
      out = Subject.transform(source, prepared: plan)

      # label/2 is not the migrated label/1 — its call site stays put
      assert out =~ "Catalog.Labeling.label(x, opts)"
    end
  end

  describe "report/1" do
    test "summarizes synthesized protocols" do
      plan = detect([{"Catalog.Labeling", labeling_clauses()}])

      assert Subject.report(plan) =~
               "extracted protocols:\n  Catalog.Labelable (label/1) over 3 structs: Asset, Brand, Item"
    end

    test "lists cross-module candidates under not-rewritten" do
      plan =
        detect([
          {"A", "  def render(%Box{} = b), do: b\n"},
          {"B", "  def render(%Circle{} = c), do: c\n"},
          {"C", "  def render(%Line{} = l), do: l\n"}
        ])

      assert Subject.report(plan) =~ "render/1 over 3 structs (cross_module)"
    end

    test "empty plan reports no candidates" do
      assert Subject.report(%{synthesized: [], skipped: [], name_families: []}) ==
               "no protocol candidates"
    end
  end

  describe "name-family hints" do
    test "a suffix family converging on one struct is a hint" do
      plan =
        detect([
          {"S",
           """
             def position_to_result(r), do: %Result{type: :position, id: r.id}
             def item_to_result(r), do: %Result{type: :item, id: r.id}
             def brand_to_result(r), do: %Result{type: :brand, id: r.id}
           """}
        ])

      assert [%{stem: :to_result, position: :suffix, signature: {:struct, Result}} = fam] =
               plan.name_families

      assert fam.members == [:brand_to_result, :item_to_result, :position_to_result]
      # name families are NOT struct-dispatch candidates
      assert plan.candidates == []
    end

    test "a prefix family converging on one call is a hint" do
      plan =
        detect([
          {"S",
           """
             def subscribe_items(s), do: PubSub.subscribe(MyApp.PubSub, items_topic())
             def subscribe_brands(s), do: PubSub.subscribe(MyApp.PubSub, brands_topic())
             def subscribe_assets(s), do: PubSub.subscribe(MyApp.PubSub, assets_topic())
           """}
        ])

      assert [%{stem: :subscribe, position: :prefix, signature: {:call, :subscribe}}] =
               plan.name_families
    end

    test "a CRUD name family with DIVERGENT bodies does not converge" do
      plan =
        detect([
          {"S",
           """
             def delete_asset(a), do: Repo.delete(a)
             def delete_brand(b), do: Multi.new() |> Multi.delete(:b, b)
             def delete_item(i), do: broadcast_deleted(i)
           """}
        ])

      # same `delete` stem, three different operations → no family
      assert plan.name_families == []
    end

    test "a pipe converges on its right end" do
      plan =
        detect([
          {"S",
           """
             def asset_to_result(r), do: r |> base() |> render_card(:asset)
             def item_to_result(r), do: r |> base() |> render_card(:item)
             def brand_to_result(r), do: r |> base() |> render_card(:brand)
           """}
        ])

      assert [%{stem: :to_result, signature: {:call, :render_card}}] = plan.name_families
    end

    test "bodies ending in a language construct (case/if/~H) never converge" do
      plan =
        detect([
          {"S",
           """
             def render_item(assigns), do: ~H"<div>item</div>"
             def render_brand(assigns), do: ~H"<div>brand</div>"
             def render_asset(assigns), do: ~H"<div>asset</div>"
             def pick_item(x), do: case x do _ -> 1 end
             def pick_brand(x), do: case x do _ -> 2 end
             def pick_asset(x), do: case x do _ -> 3 end
           """}
        ])

      assert plan.name_families == []
    end

    test "defp members count for name families (hand-rolled helpers are private)" do
      plan =
        detect([
          {"S",
           """
             defp a_to_result(r), do: %Result{id: r.id}
             defp b_to_result(r), do: %Result{id: r.id}
             defp c_to_result(r), do: %Result{id: r.id}
           """}
        ])

      assert [%{stem: :to_result, signature: {:struct, Result}}] = plan.name_families
    end

    test ":min_family raises the floor" do
      modules = [
        {"S",
         """
           def a_to_result(r), do: %Result{id: r.id}
           def b_to_result(r), do: %Result{id: r.id}
           def c_to_result(r), do: %Result{id: r.id}
         """}
      ]

      assert [_] = detect(modules, min_family: 3).name_families
      assert [] = detect(modules, min_family: 4).name_families
    end

    test "families converging on a GENERIC op (where/all/reduce) are filtered out" do
      plan =
        detect([
          {"S",
           """
             def maybe_filter_brand(q), do: q |> where([x], x.brand)
             def maybe_filter_item(q), do: q |> where([x], x.item)
             def maybe_filter_asset(q), do: q |> where([x], x.asset)
           """}
        ])

      # all converge on `where`, but `where` is plumbing, not a contract
      assert plan.name_families == []
    end

    test "a sub-family subsumed by a larger one (same signature) is dropped" do
      plan =
        detect([
          {"S",
           """
             def subscribe_items(s), do: PubSub.subscribe(P, items_topic())
             def subscribe_brands(s), do: PubSub.subscribe(P, brands_topic())
             def subscribe_assets(s), do: PubSub.subscribe(P, assets_topic())
             def subscribe_item_assets(s), do: PubSub.subscribe(P, ia_topic())
             def subscribe_item_brands(s), do: PubSub.subscribe(P, ib_topic())
           """}
        ])

      # `subscribe_item` (subset of `subscribe`, same call) is not reported separately
      stems = Enum.map(plan.name_families, & &1.stem)
      assert :subscribe in stems
      refute :subscribe_item in stems
    end

    test "generic verb stems (get/list/to/...) are stopword-filtered" do
      plan =
        detect([
          {"S",
           """
             def get_asset(r), do: Repo.get(Asset, r)
             def get_brand(r), do: Repo.get(Brand, r)
             def get_item(r), do: Repo.get(Item, r)
           """}
        ])

      # `get` is a stopword stem even though the bodies converge on Repo.get
      refute Enum.any?(plan.name_families, &(&1.stem == :get))
    end
  end

  # --- shared fixtures ---

  defp labeling_clauses do
    """
      def label(%Brand{} = b), do: b.name
      def label(%Item{} = i), do: i.title
      def label(%Asset{} = a), do: a.filename
    """
  end

  defp labeling_source do
    """
    defmodule Catalog.Labeling do
    #{labeling_clauses()}
      def other(x), do: x
    end
    """
  end

  defp synthesize_one_protocol do
    synthesize([{"Catalog.Labeling", labeling_clauses()}])
  end

  defp synthesize(modules) do
    detect(modules).synthesized
  end

  # Build a real on-disk source so spec/path derivation has a file to read,
  # then return `{source_string, plan}` for transform/2 tests.
  defp prepared(source) do
    tmp = tmp_dir()
    path = Path.join(tmp, "lib/catalog/labeling.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)

    plan = Subject.build_plan([{path, source}], write_root: tmp, dry_run: true)
    {source, plan}
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "protofam_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
