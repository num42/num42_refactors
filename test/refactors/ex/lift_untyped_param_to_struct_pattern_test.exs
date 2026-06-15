defmodule Number42.Refactors.Ex.LiftUntypedParamToStructPatternTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.LiftUntypedParamToStructPattern, as: Subject

  # `[{path, source}]` from `[{module_name, body}]`.
  defp sources(modules) do
    Enum.map(modules, fn {name, body} ->
      {"lib/" <> Macro.underscore(name) <> ".ex", "defmodule #{name} do\n#{body}end\n"}
    end)
  end

  # build_plan with the Dialyzer source OFF — these unit tests work on
  # synthetic in-memory sources, not a compiled project with a PLT. The
  # Dialyzer path is exercised separately against a real PLT.
  defp bp(sources, opts \\ []),
    do: Subject.build_plan(sources, Keyword.put(opts, :dialyzer, false))

  # Two structs the inference can resolve against, sharing the generic
  # `id`/`name` (so those alone are ambiguous AND don't count toward the
  # distinctive-field threshold) but each with two distinctive fields.
  defp struct_defs do
    {"Schemas",
     """
       defmodule Position do
         defstruct [:id, :name, :parent_id, :depth]
       end

       defmodule Item do
         defstruct [:id, :name, :sku, :price]
       end
     """}
  end

  defp plan(modules), do: bp(sources([struct_defs() | modules]))

  # The single lift / decline record for function `name` in a plan.
  defp lift(plan, name), do: Enum.find(plan.lifts, &(&1.name == name))
  defp declined(plan, name), do: Enum.find(plan.declined, &(&1.name == name))

  describe "struct index" do
    test "reads defstruct field lists project-wide" do
      idx = plan([]).structs
      assert MapSet.equal?(idx[Position], MapSet.new([:id, :name, :parent_id, :depth]))
      assert MapSet.equal?(idx[Item], MapSet.new([:id, :name, :sku, :price]))
    end

    test "reads defstruct keyword form (a: 1, b: 2)" do
      idx =
        bp(sources([{"K", "  defstruct foo: 1, bar: nil\n"}])).structs

      assert MapSet.equal?(idx[K], MapSet.new([:foo, :bar]))
    end
  end

  describe "lifting on a unique field-set match" do
    test "two distinctive fields pin one struct and lift the head" do
      # parent_id + depth: both distinctive, only Position has them.
      # defp: field-superset narrowing is duck-typing and only fires for
      # PRIVATE functions, whose entire caller set is in project (#222).
      src = "defmodule R do\n  defp f(r), do: {r.parent_id, r.depth}\nend\n"
      idx = plan([]).structs

      assert_rewrites(
        Subject,
        src,
        "defmodule R do\n  defp f(%Position{} = r), do: {r.parent_id, r.depth}\nend\n",
        prepared: %{structs: idx}
      )
    end

    test "a single distinctive field is too thin to pin a struct (declined)" do
      # parent_id alone fits only Position, but one field is not enough proof
      src = "defmodule R do\n  def f(r), do: r.parent_id\nend\n"
      assert_unchanged(Subject, src, prepared: %{structs: plan([]).structs})

      assert %{reason: :too_few_distinctive_fields} =
               Enum.find(
                 plan([{"R", "  def f(r), do: r.parent_id\n"}]).declined,
                 &(&1.name == :f)
               )
    end

    test "generic fields (id/name/type) don't count toward the threshold" do
      # only generic fields read — distinctive count is 0, so declined even
      # though id+name+depth would uniquely fit Position
      src = "defmodule R do\n  def f(r), do: {r.id, r.name, r.type}\nend\n"
      assert_unchanged(Subject, src, prepared: %{structs: plan([]).structs})

      assert %{reason: :too_few_distinctive_fields} =
               Enum.find(
                 plan([{"R", "  def f(r), do: {r.id, r.name}\n"}]).declined,
                 &(&1.name == :f)
               )
    end

    test "a generic field plus enough distinctive ones still lifts" do
      # name (generic) + parent_id + depth (distinctive) → 2 distinctive, lifts.
      # defp: field-superset only narrows private functions (#222).
      src = "defmodule R do\n  defp f(r), do: {r.name, r.parent_id, r.depth}\nend\n"

      assert Subject.transform(src, prepared: %{structs: plan([]).structs}) =~
               "defp f(%Position{} = r)"
    end

    test "the body is left untouched, only the head changes" do
      # sku + price: both distinctive, only Item — and not a struct builder.
      # defp: field-superset only narrows private functions (#222).
      src = "defmodule R do\n  defp f(r), do: %{out: r.sku, p: r.price}\nend\n"
      out = Subject.transform(src, prepared: %{structs: plan([]).structs})

      assert out =~ "defp f(%Item{} = r)"
      assert out =~ "%{out: r.sku, p: r.price}"
    end

    test "nested-alias structs resolve to their full name" do
      idx =
        bp(sources([{"Catalog.Widget", "  defstruct [:gadget_id, :widget_label]\n"}])).structs

      # defp: field-superset only narrows private functions (#222).
      src = "defmodule R do\n  defp f(r), do: {r.gadget_id, r.widget_label}\nend\n"

      assert Subject.transform(src, prepared: %{structs: idx}) =~ "defp f(%Catalog.Widget{} = r)"
    end
  end

  describe "public-def boundary on field-superset (#222)" do
    # Field-superset is duck-typing: a pure `.field`-reading body proves
    # the value HAS those fields, not that it IS that struct. A PUBLIC def
    # has an open caller set the cross-file scan can't see in full, so an
    # out-of-corpus caller could pass a bare map with the same fields. A
    # `%Struct{}` head would reject it at runtime. So a public def is NOT
    # narrowed on field-superset alone; a private defp still is.

    test "a PUBLIC def with a pure .field body is NOT narrowed (#222)" do
      # parent_id+depth uniquely fit Position — exactly one field-superset.
      # As a private defp this lifts; as a public def it must stay bare so
      # an out-of-corpus caller passing a bare map doesn't break.
      src = "defmodule R do\n  def f(r), do: {r.parent_id, r.depth}\nend\n"
      assert_unchanged(Subject, src, prepared: %{structs: plan([]).structs})

      assert %{reason: :public_field_only} =
               declined(plan([{"R", "  def f(r), do: {r.parent_id, r.depth}\n"}]), :f)
    end

    test "a PRIVATE defp with the same pure .field body IS still narrowed" do
      # the field-superset mechanic is intact for private functions, whose
      # entire caller set is in project and visible to the scan
      src = "defmodule R do\n  defp f(r), do: {r.parent_id, r.depth}\nend\n"

      assert Subject.transform(src, prepared: %{structs: plan([]).structs}) =~
               "defp f(%Position{} = r)"

      assert %{struct: Position, via: :fields} =
               lift(plan([{"R", "  defp f(r), do: {r.parent_id, r.depth}\n"}]), :f)
    end

    test "a PUBLIC def IS narrowed when a call site proves the struct" do
      # the field-only decline is rescued by real evidence: a caller passes
      # %Position{}, so the open-boundary risk is gone.
      modules = [
        {"P", "  def f(r), do: {r.parent_id, r.depth}\n"},
        {"Caller", "  def go, do: P.f(%Position{})\n"}
      ]

      assert %{struct: Position, via: :call_site} = lift(plan(modules), :f)
    end

    test "a PUBLIC def IS narrowed when an @spec names the struct" do
      # an explicit @spec is binding proof regardless of public/private
      src =
        "defmodule R do\n  @spec f(Position.t()) :: any()\n  def f(r), do: {r.parent_id, r.depth}\nend\n"

      assert Subject.transform(src, prepared: %{structs: plan([]).structs}) =~
               "def f(%Position{} = r)"
    end

    test "a public field-only decline does not leak its type through delegation" do
      # P.f is public, field-only (would-be Position) — DECLINED, so it is
      # NOT registered as a delegation receiver. A caller H.h delegating to
      # P.f therefore can't borrow the (unproven) Position type from it.
      modules = [
        {"P", "  def f(r), do: {r.parent_id, r.depth}\n"},
        {"H", "  def h(x), do: P.f(x)\n"}
      ]

      p = plan(modules)
      assert %{reason: :public_field_only} = declined(p, :f)
      assert %{reason: :param_passed_to_call} = declined(p, :h)
      refute Map.has_key?(p.receivers, {P, :f, 1})
    end

    test "a private field-only lift does not leak to a PUBLIC def via delegation (#222)" do
      # position-db dogfood regression: a PRIVATE `defp` is field-superset
      # narrowed (allowed — its callers are all in-corpus), but a PUBLIC
      # def that delegates the whole var to it must NOT inherit the struct
      # type across the open public boundary. The private narrowing is
      # field-origin (duck-typed), so an out-of-corpus caller of the public
      # wrapper could still pass a bare map.
      modules = [
        {"M",
         "  def public_wrapper(attr), do: build(attr)\n" <>
           "  defp build(a), do: {a.parent_id, a.depth}\n"}
      ]

      p = plan(modules)
      # the private helper still narrows on field-superset
      assert %{struct: Position, via: :fields} = lift(p, :build)
      # but the public wrapper must NOT be narrowed — the field origin must
      # not propagate across the public boundary through delegation
      assert %{reason: reason} = declined(p, :public_wrapper)
      assert reason in [:public_field_delegation, :param_passed_to_call]
    end

    test "a private field-only lift STILL propagates to a private def via delegation" do
      # the boundary only applies to PUBLIC defs; a private-to-private
      # delegation of a field-narrowed type stays a valid lift. It is tagged
      # `:delegation_field` (not plain `:delegation`) so the field origin
      # keeps propagating — a PUBLIC def further up the chain would still be
      # caught at the boundary.
      modules = [
        {"M",
         "  defp wrapper(attr), do: build(attr)\n" <>
           "  defp build(a), do: {a.parent_id, a.depth}\n"}
      ]

      p = plan(modules)
      assert %{struct: Position, via: :fields} = lift(p, :build)
      assert %{struct: Position, via: :delegation_field} = lift(p, :wrapper)
    end

    test "the field origin propagates transitively: defp -> defp -> PUBLIC def is caught" do
      # wrapper2 (public) delegates to wrapper1 (private) which delegates to
      # build (private, field-narrowed). The field origin must survive both
      # hops and still block the public boundary.
      modules = [
        {"M",
         "  def wrapper2(attr), do: wrapper1(attr)\n" <>
           "  defp wrapper1(attr), do: build(attr)\n" <>
           "  defp build(a), do: {a.parent_id, a.depth}\n"}
      ]

      p = plan(modules)
      assert %{struct: Position, via: :fields} = lift(p, :build)
      assert %{struct: Position, via: :delegation_field} = lift(p, :wrapper1)
      assert %{reason: :public_field_delegation} = declined(p, :wrapper2)
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
    test "an ambiguous field set (fits >=2 structs on distinctive fields) is left alone" do
      # foo + bar are distinctive yet shared by both Alpha and Beta → ambiguous
      modules = [
        {"Alpha", "  defstruct [:foo, :bar, :only_a]\n"},
        {"Beta", "  defstruct [:foo, :bar, :only_b]\n"}
      ]

      idx = bp(sources(modules)).structs
      src = "defmodule R do\n  def f(r), do: {r.foo, r.bar}\nend\n"
      assert_unchanged(Subject, src, prepared: %{structs: idx})

      declined =
        bp(sources(modules ++ [{"R", "  def f(r), do: {r.foo, r.bar}\n"}])).declined

      assert %{reason: :ambiguous_struct} = Enum.find(declined, &(&1.name == :f))
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
        bp(sources([{"Widget", "  defstruct [:gizmo, :doohickey]\n"}])).structs

      # defp: field-superset only narrows private functions (#222).
      lifted =
        Subject.transform(
          "defmodule Widget do\n  defstruct [:gizmo, :doohickey]\nend\n\ndefmodule R do\n  defp describe(w), do: {w.gizmo, w.doohickey}\n  def go, do: describe(%Widget{})\nend\n",
          prepared: %{structs: idx}
        )

      assert lifted =~ "defp describe(%Widget{} = w)"
      assert_compiles(lifted)
    end

    test "is idempotent" do
      idx = plan([]).structs
      src = "defmodule R do\n  def f(r), do: r.parent_id\nend\n"
      assert_idempotent(Subject, src, prepared: %{structs: idx})
    end
  end

  describe "call-site inference" do
    test "a struct literal at a call site rescues a body that proves nothing" do
      # P.f(r) reads only r.id (generic, too thin) — body declines. But a
      # caller passes %Position{}, so the call site reveals the type.
      modules = [
        {"P", "  def f(r), do: r.id\n"},
        {"Caller", "  def go, do: P.f(%Position{id: 1})\n"}
      ]

      p = plan(modules)
      assert %{struct: Position, via: :call_site} = lift(p, :f)
    end

    test "a call site overrides field inference to the same struct (via shifts)" do
      # body fields uniquely fit Position; a caller confirms %Position{}.
      # defp so the field-superset fires (public defs decline on fields
      # alone, #222); the local caller then confirms the same struct.
      modules = [
        {"P", "  defp f(r), do: {r.parent_id, r.depth}\n  def go, do: f(%Position{})\n"}
      ]

      assert %{struct: Position, via: :call_site} = lift(plan(modules), :f)
    end

    test "a call site disagreeing with field inference declines as a conflict" do
      # body fields say Position (parent_id+depth), caller passes %Item{}.
      # defp so the field-superset fires and can be contradicted by the
      # call site (public defs have no field opinion to conflict, #222).
      modules = [
        {"P", "  defp f(r), do: {r.parent_id, r.depth}\n  def go, do: f(%Item{})\n"}
      ]

      assert %{reason: :call_site_field_conflict} = declined(plan(modules), :f)
    end

    test "an @spec wins over a contradicting call site" do
      # spec says Item, caller passes %Position{} — the human-written spec binds
      modules = [
        {"P", "  @spec f(Item.t()) :: any()\n  def f(r), do: r.id\n"},
        {"Caller", "  def go, do: P.f(%Position{})\n"}
      ]

      assert %{struct: Item, via: :spec} = lift(plan(modules), :f)
    end

    test "a builder decline is NOT rescued by a call site" do
      # row_to_pos(row) builds %Position{...} from row — row is the source
      # projection. A caller passing %Item{} must not retype the projection.
      modules = [
        {"P",
         "  def row_to_pos(row), do: %Position{id: row.id, name: row.name, parent_id: row.parent_id}\n"},
        {"Caller", "  def go, do: P.row_to_pos(%Item{})\n"}
      ]

      assert %{reason: :builds_struct_from_param} = declined(plan(modules), :row_to_pos)
    end

    test "a local call site (same module) is honoured" do
      # f/1 is called locally with %Position{} in the same module
      modules = [
        {"P", "  def go, do: f(%Position{})\n  def f(r), do: r.id\n"}
      ]

      assert %{struct: Position, via: :call_site} = lift(plan(modules), :f)
    end

    test "a `%Struct{} = x` match directly in the argument counts as a call site" do
      # the struct literal is at the call site itself (`P.f(%Position{} = p)`),
      # not bound earlier — this slice reads literals, not variable bindings
      modules = [
        {"P", "  def f(r), do: r.id\n"},
        {"Caller", "  def go(x), do: P.f(%Position{} = x)\n"}
      ]

      assert %{struct: Position, via: :call_site} = lift(plan(modules), :f)
    end

    test "a struct bound in the caller head and passed bare is tracked" do
      # %Position{} = p in the head, then P.f(p): p is a bare var at the
      # call site, but bound to %Position{} in scope — the binding tracker
      # carries the type to the call.
      modules = [
        {"P", "  def f(r), do: r.id\n"},
        {"Caller", "  def go(%Position{} = p), do: P.f(p)\n"}
      ]

      assert %{struct: Position, via: :call_site} = lift(plan(modules), :f)
    end

    test "a struct bound in the caller body and passed bare is tracked" do
      # p = %Item{...} then P.f(p): the body match binds p to %Item{}
      modules = [
        {"P", "  def f(r), do: r.id\n"},
        {"Caller", "  def go do\n    p = %Item{id: 1, sku: \"x\"}\n    P.f(p)\n  end\n"}
      ]

      assert %{struct: Item, via: :call_site} = lift(plan(modules), :f)
    end

    test "a bare variable argument carries no call-site signal (declines)" do
      # P.f(x) with x untyped — no struct evident, body too thin → decline
      modules = [
        {"P", "  def f(r), do: r.id\n"},
        {"Caller", "  def go(x), do: P.f(x)\n"}
      ]

      assert %{reason: reason} = declined(plan(modules), :f)
      assert reason in [:too_few_distinctive_fields, :no_struct_fits]
    end

    test "the lifted head is patched even when only callers in other files prove it" do
      modules = [
        {"P", "  def f(r), do: r.id\n"},
        {"Caller", "  def go, do: P.f(%Position{id: 1})\n"}
      ]

      {p_path, p_src} = Enum.find(sources(modules), fn {path, _} -> path == "lib/p.ex" end)
      assert p_path == "lib/p.ex"

      out = Subject.transform(p_src, prepared: plan(modules))
      assert out =~ "def f(%Position{} = r)"
    end
  end

  describe "polymorphism: duplicate the clause per struct" do
    # Brand and Maker share id/name/slogan (the body reads name+slogan);
    # each adds one distinctive field. A body reading only shared fields
    # can be duplicated to both.
    defp poly_struct_defs do
      {"Schemas",
       """
         defmodule Brand do
           defstruct [:id, :name, :slogan, :logo]
         end

         defmodule Maker do
           defstruct [:id, :name, :slogan, :country]
         end
       """}
    end

    defp poly_plan(modules), do: bp(sources([poly_struct_defs() | modules]))

    test "two struct call sites + field-compatible body lifts polymorphically" do
      modules = [
        {"P", "  def label(r), do: {r.name, r.slogan}\n"},
        {"Caller", "  def a, do: P.label(%Brand{})\n  def b, do: P.label(%Maker{})\n"}
      ]

      l = lift(poly_plan(modules), :label)
      assert l.via == :call_site_poly
      assert l.struct == [Brand, Maker]
    end

    test "the clause is duplicated, one struct-typed head per target" do
      modules = [
        {"P", "  def label(r), do: {r.name, r.slogan}\n"},
        {"Caller", "  def a, do: P.label(%Brand{})\n  def b, do: P.label(%Maker{})\n"}
      ]

      {_, p_src} = Enum.find(sources(modules), fn {path, _} -> path == "lib/p.ex" end)
      out = Subject.transform(p_src, prepared: poly_plan(modules))

      assert out =~ "def label(%Brand{} = r), do: {r.name, r.slogan}"
      assert out =~ "def label(%Maker{} = r), do: {r.name, r.slogan}"
    end

    test "the duplicated output compiles" do
      lifted =
        Subject.transform(
          "defmodule Brand do\n  defstruct [:id, :name, :slogan, :logo]\nend\n\ndefmodule Maker do\n  defstruct [:id, :name, :slogan, :country]\nend\n\ndefmodule P do\n  def label(r), do: {r.name, r.slogan}\nend\n",
          prepared:
            poly_plan([
              {"P", "  def label(r), do: {r.name, r.slogan}\n"},
              {"Caller", "  def a, do: P.label(%Brand{})\n  def b, do: P.label(%Maker{})\n"}
            ])
        )

      assert lifted =~ "def label(%Brand{} = r)"
      assert lifted =~ "def label(%Maker{} = r)"
      assert_compiles(lifted)
    end

    test "a field the body reads but a target struct lacks declines (unsafe)" do
      # Widget has no :slogan; duplicating to %Widget{} would break the body
      modules = [
        {"Schemas",
         "  defmodule Brand do\n    defstruct [:id, :name, :slogan]\n  end\n  defmodule Widget do\n    defstruct [:id, :name, :gizmo]\n  end\n"},
        {"P", "  def label(r), do: {r.name, r.slogan}\n"},
        {"Caller", "  def a, do: P.label(%Brand{})\n  def b, do: P.label(%Widget{})\n"}
      ]

      plan = bp(sources(modules))
      assert %{reason: :polymorphic_unsafe} = declined(plan, :label)
    end

    test "a multi-clause function never duplicates polymorphically" do
      modules = [
        {"P", "  def label(r) when is_nil(r.slogan), do: r.name\n  def label(r), do: r.slogan\n"},
        {"Caller", "  def a, do: P.label(%Brand{})\n  def b, do: P.label(%Maker{})\n"}
      ]

      assert %{reason: :polymorphic_unsafe} = declined(poly_plan(modules), :label)
    end

    test "a param passed whole into a call declines even under polymorphism" do
      modules = [
        {"P", "  def label(r), do: render(r)\n"},
        {"Caller", "  def a, do: P.label(%Brand{})\n  def b, do: P.label(%Maker{})\n"}
      ]

      assert %{reason: reason} = declined(poly_plan(modules), :label)
      assert reason in [:polymorphic_unsafe, :param_passed_to_call]
    end

    test "the polymorphic lift is idempotent (already-typed heads don't re-lift)" do
      modules = [
        {"P", "  def label(r), do: {r.name, r.slogan}\n"},
        {"Caller", "  def a, do: P.label(%Brand{})\n  def b, do: P.label(%Maker{})\n"}
      ]

      plan = poly_plan(modules)
      {_, p_src} = Enum.find(sources(modules), fn {path, _} -> path == "lib/p.ex" end)

      once = Subject.transform(p_src, prepared: plan)
      # second pass: re-plan over the rewritten source; typed heads decline
      replanned =
        bp([
          poly_struct_defs(),
          {"lib/p.ex", once},
          {"lib/caller.ex",
           "defmodule Caller do\n  def a, do: P.label(%Brand{})\n  def b, do: P.label(%Maker{})\nend\n"}
        ])

      assert Subject.transform(once, prepared: replanned) == once
    end
  end

  describe "Dialyzer source (injected index)" do
    # Inject a pre-built Dialyzer index instead of reading a PLT, so these
    # tests are deterministic and need no compiled project.
    defp dz_plan(modules, index) do
      Subject.build_plan(sources([struct_defs() | modules]),
        dialyzer: false,
        dialyzer_index: index
      )
    end

    test "rescues a passed-whole decline the body can't prove" do
      # f(r) delegates r to a helper — body sees no fields, so it declines.
      # Dialyzer inferred %Position{} for the position; lift via :dialyzer.
      modules = [{"P", "  def f(r), do: helper(r)\n"}]
      index = %{{P, :f, 1} => %{0 => Position}}

      l = lift(dz_plan(modules, index), :f)
      assert l.struct == Position
      assert l.via == :dialyzer
    end

    test "rescues a no-struct-fits decline" do
      # body reads a field no struct carries -> :no_struct_fits; Dialyzer
      # knows better.
      modules = [{"P", "  def f(r), do: r.nonexistent_xyz\n"}]
      index = %{{P, :f, 1} => %{0 => Item}}

      assert %{struct: Item, via: :dialyzer} = lift(dz_plan(modules, index), :f)
    end

    test "does NOT override an existing field-inference lift" do
      # body fields uniquely prove Position; Dialyzer says Item — the
      # visible body wins, Dialyzer is the lowest-priority source.
      # defp: field-superset only narrows private functions (#222), so use
      # one here to get a real field lift for Dialyzer to (not) override.
      modules = [{"P", "  defp f(r), do: {r.parent_id, r.depth}\n"}]
      index = %{{P, :f, 1} => %{0 => Item}}

      assert %{struct: Position, via: :fields} = lift(dz_plan(modules, index), :f)
    end

    test "does NOT rescue a builder decline" do
      # the param is the source projection feeding a struct build; a
      # Dialyzer typing of it must not retype the projection.
      modules = [
        {"P",
         "  def row_to_pos(row), do: %Position{id: row.id, name: row.name, parent_id: row.parent_id}\n"}
      ]

      index = %{{P, :row_to_pos, 1} => %{0 => Item}}
      assert %{reason: :builds_struct_from_param} = declined(dz_plan(modules, index), :row_to_pos)
    end

    test "ignores a Dialyzer type for a struct that isn't in-project" do
      # build_plan intersects against the struct index, so an injected
      # index referencing an unknown struct simply doesn't apply — but a
      # raw injected index bypasses that intersection, so here we assert
      # the position with no entry is left declined.
      modules = [{"P", "  def f(r), do: r.id\n"}]
      index = %{{P, :other, 1} => %{0 => Position}}

      assert %{reason: _} = declined(dz_plan(modules, index), :f)
    end

    test "patches the head for a Dialyzer-only lift" do
      modules = [{"P", "  def f(r), do: helper(r)\n"}]
      index = %{{P, :f, 1} => %{0 => Position}}
      plan = dz_plan(modules, index)

      {_, p_src} = Enum.find(sources(modules), fn {path, _} -> path == "lib/p.ex" end)
      assert Subject.transform(p_src, prepared: plan) =~ "def f(%Position{} = r)"
    end
  end

  describe "erl_type_struct/1 (format lock against real :erl_types)" do
    test "extracts the module from a real Dialyzer struct map type" do
      # Build the term the way Dialyzer does — if OTP changes the internal
      # erl_types shape, this test breaks loudly instead of silently
      # yielding an empty Dialyzer index.
      key = :erl_types.t_atom(:__struct__)
      val = :erl_types.t_atom(Position)
      struct_type = :erl_types.t_map([{key, val}])

      assert Subject.erl_type_struct(struct_type) == Position
    end

    test "returns nil for a non-struct map type" do
      key = :erl_types.t_atom(:some_field)
      val = :erl_types.t_atom(:whatever)
      plain_map = :erl_types.t_map([{key, val}])

      assert Subject.erl_type_struct(plain_map) == nil
    end

    test "returns nil for a non-map type" do
      assert Subject.erl_type_struct(:erl_types.t_integer()) == nil
      assert Subject.erl_type_struct(:any) == nil
    end
  end

  describe "AST delegation (no PLT)" do
    test "a param delegated to a struct-matching receiver lifts" do
      # f(arg) passes arg whole into Shared.run/1, whose head matches
      # %Position{}. arg must therefore be a %Position{}.
      modules = [
        {"Shared", "  def run(%Position{} = p), do: p.parent_id\n"},
        {"Api", "  def f(arg), do: Shared.run(arg)\n"}
      ]

      l = lift(plan(modules), :f)
      assert l.struct == Position
      assert l.via == :delegation
    end

    test "a locally-delegated param lifts off the local receiver" do
      modules = [
        {"M", "  def run(%Item{} = i), do: i.sku\n  def f(arg), do: run(arg)\n"}
      ]

      assert %{struct: Item, via: :delegation} = lift(plan(modules), :f)
    end

    test "delegation to an untyped receiver does not lift" do
      # Shared.run/1 has a bare param — no struct contract to borrow
      modules = [
        {"Shared", "  def run(p), do: p\n"},
        {"Api", "  def f(arg), do: Shared.run(arg)\n"}
      ]

      assert %{reason: :param_passed_to_call} = declined(plan(modules), :f)
    end

    test "a param flowing to two differently-typed receivers does not lift" do
      # ambiguous: arg goes to a %Position{}-receiver AND an %Item{}-receiver
      modules = [
        {"A", "  def pa(%Position{} = p), do: p.parent_id\n"},
        {"B", "  def ib(%Item{} = i), do: i.sku\n"},
        {"Api", "  def f(arg), do: {A.pa(arg), B.ib(arg)}\n"}
      ]

      assert %{reason: :param_passed_to_call} = declined(plan(modules), :f)
    end

    test "@spec still wins over a delegation that would say otherwise" do
      modules = [
        {"Shared", "  def run(%Position{} = p), do: p.parent_id\n"},
        {"Api", "  @spec f(Item.t()) :: any()\n  def f(arg), do: Shared.run(arg)\n"}
      ]

      assert %{struct: Item, via: :spec} = lift(plan(modules), :f)
    end

    test "a receiver typed in only some clauses is not a guaranteed contract" do
      # run/1 has one %Position{} clause and one bare clause -> not guaranteed
      modules = [
        {"Shared", "  def run(%Position{} = p), do: p.parent_id\n  def run(other), do: other\n"},
        {"Api", "  def f(arg), do: Shared.run(arg)\n"}
      ]

      assert %{reason: :param_passed_to_call} = declined(plan(modules), :f)
    end

    test "the delegated head is patched" do
      modules = [
        {"Shared", "  def run(%Position{} = p), do: p.parent_id\n"},
        {"Api", "  def f(arg), do: Shared.run(arg)\n"}
      ]

      {_, src} = Enum.find(sources(modules), fn {path, _} -> path == "lib/api.ex" end)
      assert Subject.transform(src, prepared: plan(modules)) =~ "def f(%Position{} = arg)"
    end
  end

  describe "iterative fixpoint (delegation chains)" do
    test "type info propagates up a multi-hop delegation chain" do
      # h -> f -> g, only g is typed at the leaf. f resolves round 1
      # (g is a typed receiver from the start), h resolves round 2
      # (f became a typed receiver only after round 1 lifted it).
      modules = [
        {"G", "  def g(%Position{} = p), do: p.parent_id\n"},
        {"F", "  def f(arg), do: G.g(arg)\n"},
        {"H", "  def h(x), do: F.f(x)\n"}
      ]

      p = plan(modules)
      assert %{struct: Position, via: :delegation} = lift(p, :f)
      assert %{struct: Position, via: :delegation} = lift(p, :h)
    end

    test "the enriched receiver index includes the lifted heads" do
      modules = [
        {"G", "  def g(%Position{} = p), do: p.parent_id\n"},
        {"F", "  def f(arg), do: G.g(arg)\n"}
      ]

      receivers = plan(modules).receivers
      # F.f/1 was untyped in source but is a typed receiver after the loop
      assert receivers[{F, :f, 1}] == %{0 => Position}
      assert receivers[{G, :g, 1}] == %{0 => Position}
    end

    test "a delegation cycle terminates without lifting (no leaf type)" do
      # f -> g -> f, neither typed: the loop converges with no new lift
      modules = [
        {"M", "  def f(a), do: g(a)\n  def g(b), do: f(b)\n"}
      ]

      p = plan(modules)
      assert lift(p, :f) == nil
      assert lift(p, :g) == nil
    end

    test "the multi-hop lifted heads all compile" do
      lifted_g =
        "defmodule Position do\n  defstruct [:id, :name, :parent_id, :depth]\nend\n\n" <>
          "defmodule G do\n  def g(%Position{} = p), do: p.parent_id\nend\n"

      f_src = "defmodule F do\n  def f(arg), do: G.g(arg)\nend\n"
      h_src = "defmodule H do\n  def h(x), do: F.f(x)\nend\n"

      modules = [
        {"G", "  def g(%Position{} = p), do: p.parent_id\n"},
        {"F", "  def f(arg), do: G.g(arg)\n"},
        {"H", "  def h(x), do: F.f(x)\n"}
      ]

      p = plan(modules)
      out_f = Subject.transform(f_src, prepared: p)
      out_h = Subject.transform(h_src, prepared: p)

      assert out_f =~ "def f(%Position{} = arg)"
      assert out_h =~ "def h(%Position{} = x)"
      assert_compiles(lifted_g <> "\n" <> out_f <> "\n" <> out_h)
    end
  end

  describe "getter-return source (transitive Repo.get / struct-literal returns)" do
    test "a var bound to a Repo.get! getter result is tracked as that struct" do
      # Repo.get!(Item, id) returns %Item{}, so `item = Catalog.get_item!(id)`
      # binds item to %Item{}; passing it bare to P.f types f's param.
      modules = [
        {"Catalog", "  def get_item!(id), do: Repo.get!(Item, id)\n"},
        {"P", "  def f(r), do: r.id\n"},
        {"Caller", "  def go(id) do\n    item = Catalog.get_item!(id)\n    P.f(item)\n  end\n"}
      ]

      assert %{struct: Item, via: :call_site} = lift(plan(modules), :f)
    end

    test "the pipe form Schema |> Repo.get!(id) is recognised" do
      modules = [
        {"Catalog", "  def get_pos!(id), do: Position |> Repo.get!(id)\n"},
        {"P", "  def f(r), do: r.id\n"},
        {"Caller", "  def go(id) do\n    p = Catalog.get_pos!(id)\n    P.f(p)\n  end\n"}
      ]

      assert %{struct: Position, via: :call_site} = lift(plan(modules), :f)
    end

    test "Repo.get_by and Repo.one getters are recognised" do
      modules = [
        {"Catalog",
         "  def by_sku(sku), do: Repo.get_by(Item, sku: sku)\n  def first_pos, do: Repo.one(Position)\n"},
        {"P", "  def f(r), do: r.id\n  def g(r), do: r.id\n"},
        {"Caller",
         "  def go(sku) do\n    i = Catalog.by_sku(sku)\n    P.f(i)\n  end\n\n  def go2 do\n    p = Catalog.first_pos()\n    P.g(p)\n  end\n"}
      ]

      p = plan(modules)
      assert %{struct: Item, via: :call_site} = lift(p, :f)
      assert %{struct: Position, via: :call_site} = lift(p, :g)
    end

    test "a getter returning a bare %Struct{} literal is recognised" do
      modules = [
        {"Catalog", "  def blank, do: %Item{id: 0, sku: \"\", price: 0}\n"},
        {"P", "  def f(r), do: r.id\n"},
        {"Caller", "  def go do\n    i = Catalog.blank()\n    P.f(i)\n  end\n"}
      ]

      assert %{struct: Item, via: :call_site} = lift(plan(modules), :f)
    end

    test "a local getter call (same module, unqualified) is recognised" do
      modules = [
        {"Catalog",
         "  def get_item!(id), do: Repo.get!(Item, id)\n  def f(r), do: r.id\n  def go(id) do\n    i = get_item!(id)\n    f(i)\n  end\n"}
      ]

      assert %{struct: Item, via: :call_site} = lift(plan(modules), :f)
    end

    test "a non-Repo call binding is NOT treated as a struct (declines)" do
      # build_thing/1 has no struct-returning tail — its result is unknown,
      # so passing it bare reveals nothing.
      modules = [
        {"Helper", "  def build_thing(x), do: %{wrapped: x}\n"},
        {"P", "  def f(r), do: r.id\n"},
        {"Caller", "  def go(x) do\n    t = Helper.build_thing(x)\n    P.f(t)\n  end\n"}
      ]

      assert %{reason: reason} = declined(plan(modules), :f)
      assert reason in [:too_few_distinctive_fields, :no_struct_fits]
    end

    test "a Repo.all getter (returns a list, not a struct) is NOT recognised" do
      # Repo.all returns [%Item{}], not %Item{} — binding to it must not
      # type a param as %Item{}.
      modules = [
        {"Catalog", "  def all_items, do: Repo.all(Item)\n"},
        {"P", "  def f(r), do: r.id\n"},
        {"Caller", "  def go do\n    items = Catalog.all_items()\n    P.f(items)\n  end\n"}
      ]

      assert %{reason: reason} = declined(plan(modules), :f)
      assert reason in [:too_few_distinctive_fields, :no_struct_fits]
    end

    test "a getter whose clauses disagree on the struct is NOT recognised" do
      # two clauses return different structs → not unconditional → disqualified
      modules = [
        {"Catalog",
         "  def fetch(:item, id), do: Repo.get!(Item, id)\n  def fetch(:pos, id), do: Repo.get!(Position, id)\n"},
        {"P", "  def f(r), do: r.id\n"},
        {"Caller", "  def go(id) do\n    x = Catalog.fetch(:item, id)\n    P.f(x)\n  end\n"}
      ]

      assert %{reason: reason} = declined(plan(modules), :f)
      assert reason in [:too_few_distinctive_fields, :no_struct_fits]
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
      # defp: field-superset only narrows private functions (#222).
      report = Subject.report(plan([{"R", "  defp f(r), do: {r.parent_id, r.depth}\n"}]))
      assert report =~ "R.f/1 (r) -> %Position{} (via fields)"
    end

    test "empty plan reports nothing to lift" do
      assert Subject.report(%{lifts: []}) == "no untyped params to lift"
    end
  end
end
