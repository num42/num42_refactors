defmodule Number42.Refactors.Ex.LiftUntypedParamToStructPatternTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.LiftUntypedParamToStructPattern, as: Subject

  # `[{path, source}]` from `[{module_name, body}]`.
  defp sources(modules) do
    Enum.map(modules, fn {name, body} ->
      {"lib/" <> Macro.underscore(name) <> ".ex", "defmodule #{name} do\n#{body}end\n"}
    end)
  end

  # Two structs the inference can resolve against, sharing `id`/`name`
  # (so `id+name` alone is ambiguous, but a distinctive field pins one).
  defp struct_defs do
    {"Schemas",
     """
       defmodule Position do
         defstruct [:id, :name, :parent_id]
       end

       defmodule Item do
         defstruct [:id, :name, :sku]
       end
     """}
  end

  defp plan(modules), do: Subject.build_plan(sources([struct_defs() | modules]))

  describe "struct index" do
    test "reads defstruct field lists project-wide" do
      idx = plan([]).structs
      assert MapSet.equal?(idx[Position], MapSet.new([:id, :name, :parent_id]))
      assert MapSet.equal?(idx[Item], MapSet.new([:id, :name, :sku]))
    end

    test "reads defstruct keyword form (a: 1, b: 2)" do
      idx =
        Subject.build_plan(sources([{"K", "  defstruct foo: 1, bar: nil\n"}])).structs

      assert MapSet.equal?(idx[K], MapSet.new([:foo, :bar]))
    end
  end

  describe "lifting on a unique field-set match" do
    test "a distinctive field set pins one struct and lifts the head" do
      # parent_id + name: only Position has both (Item has name, no parent_id)
      src = "defmodule R do\n  def f(r), do: {r.parent_id, r.name}\nend\n"
      idx = plan([]).structs

      assert_rewrites(
        Subject,
        src,
        "defmodule R do\n  def f(%Position{} = r), do: {r.parent_id, r.name}\nend\n",
        prepared: %{structs: idx}
      )
    end

    test "a single accessed field is too thin to pin a struct (declined)" do
      # parent_id alone fits only Position, but one generic field is not
      # enough proof — the min_fields floor declines it
      src = "defmodule R do\n  def f(r), do: r.parent_id\nend\n"
      assert_unchanged(Subject, src, prepared: %{structs: plan([]).structs})

      assert %{reason: :too_few_fields} =
               Enum.find(
                 plan([{"R", "  def f(r), do: r.parent_id\n"}]).declined,
                 &(&1.name == :f)
               )
    end

    test "the body is left untouched, only the head changes" do
      src = "defmodule R do\n  def f(r), do: %{out: r.sku, n: r.name}\nend\n"
      out = Subject.transform(src, prepared: %{structs: plan([]).structs})

      assert out =~ "def f(%Item{} = r)"
      assert out =~ "%{out: r.sku, n: r.name}"
    end

    test "nested-alias structs resolve to their full name" do
      idx =
        Subject.build_plan(
          sources([{"Catalog.Widget", "  defstruct [:gadget_id, :widget_label]\n"}])
        ).structs

      src = "defmodule R do\n  def f(r), do: {r.gadget_id, r.widget_label}\nend\n"

      assert Subject.transform(src, prepared: %{structs: idx}) =~ "def f(%Catalog.Widget{} = r)"
    end
  end

  describe "lifting via an existing @spec" do
    test "@spec naming the arg type wins, even when fields would be ambiguous" do
      # id+name fits both Position and Item, but the spec says Item
      src =
        "defmodule R do\n  @spec f(Item.t()) :: any()\n  def f(r), do: {r.id, r.name}\nend\n"

      assert Subject.transform(src, prepared: %{structs: plan([]).structs}) =~
               "def f(%Item{} = r)"
    end

    test "a spec naming a non-struct type (term()) does not lift via spec" do
      # term() is not a struct; falls through to field inference, which
      # is ambiguous here (id+name) → declined
      src = "defmodule R do\n  @spec f(term()) :: any()\n  def f(r), do: {r.id, r.name}\nend\n"

      assert_unchanged(Subject, src, prepared: %{structs: plan([]).structs})
    end
  end

  describe "declines (the inference guard)" do
    test "an ambiguous field set (fits >=2 structs) is left alone" do
      # id+name fits both Position and Item
      src = "defmodule R do\n  def f(r), do: {r.id, r.name}\nend\n"
      assert_unchanged(Subject, src, prepared: %{structs: plan([]).structs})

      assert %{reason: :ambiguous_struct} =
               Enum.find(
                 plan([{"R", "  def f(r), do: {r.id, r.name}\n"}]).declined,
                 &(&1.name == :f)
               )
    end

    test "a field set fitting NO struct is left alone (the projection acid test)" do
      # distance/grandparent_name belong to no struct — the search-projection
      # case: the value is a map, lifting to a struct would break at runtime
      src =
        "defmodule S do\n  def to_result(r), do: %{t: r.name, d: r.distance, g: r.grandparent_name}\nend\n"

      assert_unchanged(Subject, src, prepared: %{structs: plan([]).structs})

      assert %{reason: :no_struct_fits} =
               Enum.find(
                 plan([
                   {"S", "  def to_result(r), do: %{d: r.distance, g: r.grandparent_name}\n"}
                 ]).declined,
                 &(&1.name == :to_result)
               )
    end

    test "a param passed whole into another call is left alone" do
      # the helper might read fields we can't see → field set incomplete
      src = "defmodule R do\n  def f(r), do: helper(r)\nend\n"
      assert_unchanged(Subject, src, prepared: %{structs: plan([]).structs})
    end

    test "a builder reading the param into a struct literal is left alone" do
      # row_to_X(row) building %Y{a: row.a, b: row.b}: `row` is the source
      # projection feeding the build, not %Y{} itself — its fields coincide
      # with the struct's only because the build needs exactly those.
      src =
        "defmodule R do\n  def row_to_pos(row), do: %Position{id: row.id, name: row.name, parent_id: row.parent_id}\nend\n"

      assert_unchanged(Subject, src, prepared: %{structs: plan([]).structs})

      assert %{reason: :builds_struct_from_param} =
               Enum.find(
                 plan([
                   {"R",
                    "  def row_to_pos(row), do: %Position{id: row.id, name: row.name, parent_id: row.parent_id}\n"}
                 ]).declined,
                 &(&1.name == :row_to_pos)
               )
    end

    test "an @spec still lifts even when the body builds a struct from the param" do
      # the binding @spec overrides the builder guard
      src =
        "defmodule R do\n  @spec build(Position.t()) :: map()\n  def build(p), do: %OtherThing{a: p.id, b: p.name}\nend\n"

      assert Subject.transform(src, prepared: %{structs: plan([]).structs}) =~
               "def build(%Position{} = p)"
    end

    test "a param piped into a call is left alone" do
      src = "defmodule R do\n  def f(r), do: r |> serialize()\nend\n"
      assert_unchanged(Subject, src, prepared: %{structs: plan([]).structs})
    end

    test "a param with no field access is left alone" do
      src = "defmodule R do\n  def f(r), do: r\nend\n"
      assert_unchanged(Subject, src, prepared: %{structs: plan([]).structs})
    end

    test "an already-typed param is left alone" do
      src = "defmodule R do\n  def f(%Position{} = r), do: r.parent_id\nend\n"
      assert_unchanged(Subject, src, prepared: %{structs: plan([]).structs})
    end

    test "an underscore-prefixed param is never lifted" do
      src = "defmodule R do\n  def f(_r), do: 1\nend\n"
      assert_unchanged(Subject, src, prepared: %{structs: plan([]).structs})
    end

    test "clauses inferring different structs decline (divergent)" do
      # clause 1 reads parent_id (Position), clause 2 reads sku (Item) →
      # the position would diverge, so it's not lifted
      src =
        "defmodule R do\n  def f(r) when is_nil(r.parent_id), do: r.parent_id\n  def f(r), do: r.sku\nend\n"

      assert_unchanged(Subject, src, prepared: %{structs: plan([]).structs})
    end
  end

  describe "consistency" do
    test "the lifted output compiles" do
      idx =
        Subject.build_plan(sources([{"Widget", "  defstruct [:gizmo, :doohickey]\n"}])).structs

      lifted =
        Subject.transform(
          "defmodule Widget do\n  defstruct [:gizmo, :doohickey]\nend\n\ndefmodule R do\n  def describe(w), do: {w.gizmo, w.doohickey}\nend\n",
          prepared: %{structs: idx}
        )

      assert lifted =~ "def describe(%Widget{} = w)"
      assert_compiles(lifted)
    end

    test "is idempotent" do
      idx = plan([]).structs
      src = "defmodule R do\n  def f(r), do: r.parent_id\nend\n"
      assert_idempotent(Subject, src, prepared: %{structs: idx})
    end
  end

  describe "transform/2" do
    test "is a no-op without a prepared plan" do
      src = "defmodule R do\n  def f(r), do: r.parent_id\nend\n"
      assert Subject.transform(src, []) == src
    end
  end

  describe "report/1" do
    test "lists liftable params with their inference source" do
      report = Subject.report(plan([{"R", "  def f(r), do: {r.parent_id, r.name}\n"}]))
      assert report =~ "R.f/1 (r) -> %Position{} (via fields)"
    end

    test "empty plan reports nothing to lift" do
      assert Subject.report(%{lifts: []}) == "no untyped params to lift"
    end
  end
end
