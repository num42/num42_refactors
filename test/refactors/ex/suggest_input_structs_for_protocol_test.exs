defmodule Number42.Refactors.Ex.SuggestInputStructsForProtocolTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.SuggestInputStructsForProtocol, as: Subject

  # `[{path, source}]` from `[{module_name, body}]`.
  defp sources(modules) do
    Enum.map(modules, fn {name, body} ->
      {"lib/" <> Macro.underscore(name) <> ".ex", "defmodule #{name} do\n#{body}end\n"}
    end)
  end

  defp suggest(modules, opts \\ []) do
    Subject.build_plan(sources(modules), opts)
  end

  # The issue's #1 candidate: 7 `*_to_result/1` functions each building one
  # `%Result{}` from disjoint `r.<field>` access sets on a bare map arg.
  defp search_module do
    {"Search",
     """
       defp position_to_result(r) do
         %Result{distance: r.distance, id: r.id, title: r.name,
                 subtitle: build_breadcrumb(r.grandparent_name, r.parent_name),
                 type: :position, url: "/positions/\#{r.id}"}
       end

       defp item_to_result(r) do
         %Result{distance: r.distance, id: r.id, title: r.name,
                 article_number: r.article_number, position_name: r.position_name,
                 preview_asset_id: r.preview_asset_id,
                 short_description: r.short_description, type: :item}
       end

       defp brand_to_result(r) do
         %Result{distance: r.distance, id: r.id, name: r.name,
                 logo_asset_id: r.logo_asset_id, type: :brand}
       end

       defp mass_to_result(r) do
         %Result{distance: r.distance, id: r.id, key: r.key,
                 label: r.label, source: r.source, type: :mass}
       end
     """}
  end

  describe "family location" do
    test "locates a *_to_X name family that builds the same struct from a bare map" do
      plan = suggest([search_module()])

      assert [proposal] = plan.proposals
      assert proposal.stem == :to_result
      assert proposal.target == Result
      # default protocol is the stem noun adjectivized; the domain noun
      # (`Searchable`) is a human finalize step via :protocol
      assert proposal.protocol == Resultable
    end

    test "ignores a name family that does not converge on a struct build" do
      plan =
        suggest([
          {"S",
           """
             defp subscribe_items(s), do: PubSub.subscribe(P, items_topic())
             defp subscribe_brands(s), do: PubSub.subscribe(P, brands_topic())
             defp subscribe_assets(s), do: PubSub.subscribe(P, assets_topic())
           """}
        ])

      assert plan.proposals == []
    end

    test "skips a family whose argument is already a struct — that is stage 2's job" do
      plan =
        suggest([
          {"S",
           """
             defp position_to_result(%PositionHit{} = r), do: %Result{id: r.id}
             defp item_to_result(%ItemHit{} = r), do: %Result{id: r.id}
             defp brand_to_result(%BrandHit{} = r), do: %Result{id: r.id}
           """}
        ])

      assert plan.proposals == []
    end
  end

  describe "field inference (body-only)" do
    test "infers each member's field set from its r.<field> accesses" do
      [proposal] = suggest([search_module()]).proposals
      members = Map.new(proposal.members, &{&1.discriminator, &1})

      assert members["position"].fields ==
               [:distance, :grandparent_name, :id, :name, :parent_name]

      assert members["item"].fields ==
               [
                 :article_number,
                 :distance,
                 :id,
                 :name,
                 :position_name,
                 :preview_asset_id,
                 :short_description
               ]

      assert members["brand"].fields == [:distance, :id, :logo_asset_id, :name]
    end

    test "field sets are per-member disjoint beyond the shared core" do
      [proposal] = suggest([search_module()]).proposals
      position = Enum.find(proposal.members, &(&1.discriminator == "position"))

      # join/compute fields no entity struct carries are still inferred from the body
      assert :grandparent_name in position.fields
      assert :parent_name in position.fields
    end
  end

  describe "shared compute-field flagging (distance)" do
    test "fields read by EVERY member are flagged, not folded into each struct" do
      [proposal] = suggest([search_module()]).proposals

      assert :distance in proposal.shared_fields
      assert :id in proposal.shared_fields
      # `name` is read by most members but NOT mass_to_result, so it is
      # entity data, not a shared compute column
      refute :name in proposal.shared_fields
    end

    test "shared compute fields are excluded from each member's struct field list" do
      [proposal] = suggest([search_module()]).proposals
      brand = Enum.find(proposal.members, &(&1.discriminator == "brand"))

      refute :distance in brand.struct_fields
      assert :logo_asset_id in brand.struct_fields
    end
  end

  describe "naming (output contract for stage 2)" do
    test "discriminator → struct name with a configurable suffix" do
      [proposal] = suggest([search_module()]).proposals
      names = Enum.map(proposal.members, & &1.struct)

      assert PositionSearchHit in names
      assert ItemSearchHit in names
      assert BrandSearchHit in names
    end

    test ":struct_suffix overrides the struct name suffix" do
      [proposal] = suggest([search_module()], struct_suffix: "Hit").proposals
      names = Enum.map(proposal.members, & &1.struct)

      assert PositionHit in names
      assert ItemHit in names
    end

    test ":protocol overrides the derived protocol name" do
      [proposal] = suggest([search_module()], protocol: Catalog.Searchable).proposals
      assert proposal.protocol == Catalog.Searchable
    end
  end

  describe "rendered proposal" do
    test "renders one defstruct per member, the defprotocol, and per-struct defimpls" do
      [proposal] = suggest([search_module()]).proposals
      r = proposal.rendered

      assert r =~ "defstruct"
      assert r =~ "defmodule PositionSearchHit do"
      assert r =~ "defmodule ItemSearchHit do"
      assert r =~ "defmodule BrandSearchHit do"

      assert r =~ "defprotocol Resultable do"
      assert r =~ "def to_result(data)"

      assert r =~ "defimpl Resultable, for: PositionSearchHit do"
      assert r =~ "defimpl Resultable, for: ItemSearchHit do"
      assert r =~ "defimpl Resultable, for: BrandSearchHit do"
    end

    test "the def heads pattern-match the suggested structs (stage-2 dispatch contract)" do
      [proposal] = suggest([search_module()]).proposals

      assert proposal.rendered =~ "def to_result(%PositionSearchHit{} = r)"
      assert proposal.rendered =~ "def to_result(%ItemSearchHit{} = r)"
    end

    test "the rendered structs declare their inferred non-shared fields" do
      [proposal] = suggest([search_module()]).proposals
      # brand's struct keeps logo_asset_id/name but not the shared distance/id
      assert proposal.rendered =~ "defstruct [:logo_asset_id, :name]"
    end

    test "the rendered proposal mentions the shared compute fields as a flag" do
      [proposal] = suggest([search_module()]).proposals
      assert proposal.rendered =~ "distance"
      # rendered as a human note, not a struct field
      assert proposal.rendered =~ ~r/shared.*compute|compute.*shared/i
    end

    test "the rendered proposal compiles as real Elixir" do
      [proposal] = suggest([search_module()]).proposals
      assert_compiles(proposal.rendered)
    end
  end

  describe "stage-2 hand-off contract" do
    test "feeding the rendered structs back through stage 2 yields a struct-dispatch candidate" do
      [proposal] = suggest([search_module()]).proposals

      # Build the def heads stage 2 would see once the human lifts the inputs.
      heads =
        Enum.map_join(proposal.members, "\n", fn m ->
          "  def to_result(%#{inspect(m.struct)}{} = r), do: %Result{id: r.id}"
        end)

      stage2 =
        Number42.Refactors.Ex.ExtractProtocolFromStructFamily.build_plan(
          [{"lib/searchable_impls.ex", "defmodule SearchableImpls do\n#{heads}\nend\n"}],
          dry_run: true,
          min_structs: 3
        )

      assert [%{name: :to_result, structs: structs}] = stage2.candidates
      assert proposal.members |> Enum.map(& &1.struct) |> Enum.sort() == structs
    end
  end

  describe "transform/2 — detector never patches code" do
    test "is a no-op: a detector never rewrites the source it scans" do
      source = "defmodule Search do\n  defp position_to_result(r), do: %Result{id: r.id}\nend\n"
      assert Subject.transform(source, []) == source
    end

    test "is a no-op even with a prepared plan" do
      modules = [search_module()]
      {:ok, plan} = Subject.prepare(paths: source_paths(modules))
      source = "defmodule Anything do\n  def f(x), do: x\nend\n"
      assert Subject.transform(source, prepared: plan) == source
    end
  end

  describe "report/1" do
    test "summarizes a proposal: family, target, protocol, members, shared fields" do
      plan = suggest([search_module()])
      report = Subject.report(plan)

      assert report =~ "to_result"
      assert report =~ "Resultable"
      assert report =~ "PositionSearchHit"
      assert report =~ "distance"
    end

    test "an empty plan reports no suggestions" do
      assert Subject.report(%{proposals: []}) == "no input-struct suggestions"
    end
  end

  defp source_paths(modules) do
    modules
    |> sources()
    |> Enum.map(fn {path, src} ->
      File.mkdir_p!(Path.dirname(Path.join(System.tmp_dir!(), path)))
      full = Path.join(System.tmp_dir!(), path)
      File.write!(full, src)
      on_exit(fn -> File.rm_rf!(full) end)
      full
    end)
  end
end
