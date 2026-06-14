defmodule Number42.Refactors.Ex.ExtractPrimitiveToStructTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractPrimitiveToStruct, as: Subject

  # transform/2 opts: always enabled (default-OFF is a separate test), with
  # an optional pre-built struct index and threshold threaded through
  # `prepared` exactly as the engine does.
  defp opts(extra \\ []) do
    prepared = %{
      structs: Keyword.get(extra, :structs, %{}),
      min_occurrences: Keyword.get(extra, :min_occurrences, 3)
    }

    [enabled: true, prepared: prepared]
  end

  defp plan(src, extra \\ []) do
    Subject.build_plan([{"lib/m.ex", src}], extra)
  end

  defp extraction(plan, name), do: Enum.find(plan.extractions, &(&1.name == name))
  defp declined(plan, reason), do: Enum.find(plan.declined, &(&1.reason == reason))

  describe "default-OFF gate" do
    test "without enabled: true the source is untouched even for a clear shape" do
      src = """
      defmodule Geo do
        def a({lat, lng}), do: lat
        def b({lat, lng}), do: lng
        def c({lat, lng}), do: {lat, lng}
      end
      """

      assert_unchanged(Subject, src, prepared: %{structs: %{}, min_occurrences: 3})
    end
  end

  describe "tuple extraction (positionally consistent, >= K)" do
    test "three consistent heads extract a struct and rewrite heads + call sites" do
      src = """
      defmodule Geo do
        def distance({lat1, lng1}, {lat2, lng2}), do: hypot(lat1, lng1, lat2, lng2)
        def origin({lat, lng}), do: base(lat, lng)
        def shift({lat, lng}), do: base(lat, lng)
        def make, do: distance({52.5, 13.4}, {48.1, 11.6})
      end
      """

      out = Subject.transform(src, opts())

      assert out =~ "defmodule Coord do"
      assert out =~ "defstruct [:lat, :lng]"
      assert out =~ "def distance(%Coord{lat: lat1, lng: lng1}, %Coord{lat: lat2, lng: lng2})"
      assert out =~ "def origin(%Coord{lat: lat, lng: lng})"
      assert out =~ "distance(%Coord{lat: 52.5, lng: 13.4}, %Coord{lat: 48.1, lng: 11.6})"
    end

    test "numeric suffixes share a stem (lat1/lat2 agree with lat)" do
      src = """
      defmodule Geo do
        def a({lat1, lng1}), do: [lat1, lng1]
        def b({lat2, lng2}), do: [lat2, lng2]
        def c({lat, lng}), do: [lat, lng]
      end
      """

      p = plan(src)
      assert %{kind: :tuple, ordered_fields: [:lat, :lng], count: 3} = extraction(p, "Coord")
    end

    test "the output compiles" do
      src = """
      defmodule Geo do
        def distance({lat1, lng1}, {lat2, lng2}), do: {lat1, lng1, lat2, lng2}
        def origin({lat, lng}), do: {lat, lng}
        def shift({lat, lng}), do: {lat, lng}
      end
      """

      assert_compiles(Subject.transform(src, opts()))
    end

    test "construction rewrite is provable-dataflow only: an unrelated value tuple is left alone" do
      # `distance/2` is typed at both positions, so its call site rewrites.
      # The bare `{a, b}` returned by `pair/2` flows nowhere typed, so it is
      # NOT reshaped — no arity-guessing.
      src = """
      defmodule Geo do
        def distance({lat1, lng1}, {lat2, lng2}), do: {lat1, lng1, lat2, lng2}
        def origin({lat, lng}), do: {lat, lng}
        def shift({lat, lng}), do: {lat, lng}
        def pair(a, b), do: {a, b}
        def call, do: distance({1.0, 2.0}, {3.0, 4.0})
      end
      """

      out = Subject.transform(src, opts())

      assert out =~ "distance(%Coord{lat: 1.0, lng: 2.0}, %Coord{lat: 3.0, lng: 4.0})"
      # pair/2's return tuple is untouched — it doesn't flow into a typed position
      assert out =~ "def pair(a, b), do: {a, b}"
    end
  end

  describe "map extraction (exact key-set match)" do
    test "three heads with the same key set extract a struct" do
      src = """
      defmodule People do
        def greet(%{name: n, age: a}), do: [n, a]
        def label(%{name: n, age: a}), do: [n, a]
        def show(%{name: n, age: a}), do: [n, a]
      end
      """

      out = Subject.transform(src, opts())

      assert out =~ "defmodule Person do"
      assert out =~ "defstruct [:name, :age]" or out =~ "defstruct [:age, :name]"
      assert out =~ "%Person{name: n, age: a}"
      assert_compiles(out)
    end

    test "subset/superset key sets are DIFFERENT types — no merge in v1" do
      # {name, age} appears 2x, {name, age, email} appears 2x; neither
      # reaches K=3 on its own, and they are never merged.
      src = """
      defmodule People do
        def a(%{name: n, age: g}), do: [n, g]
        def b(%{name: n, age: g}), do: [n, g]
        def c(%{name: n, age: g, email: e}), do: [n, g, e]
        def d(%{name: n, age: g, email: e}), do: [n, g, e]
      end
      """

      assert_unchanged(Subject, src, opts())
    end

    test "exact superset reaching K extracts only that exact set" do
      src = """
      defmodule People do
        def a(%{name: n, age: g, email: e}), do: [n, g, e]
        def b(%{name: n, age: g, email: e}), do: [n, g, e]
        def c(%{name: n, age: g, email: e}), do: [n, g, e]
        def d(%{name: n, age: g}), do: [n, g]
      end
      """

      p = plan(src)
      ext = Enum.find(p.extractions, &(&1.kind == :map))
      assert MapSet.equal?(ext.fields, MapSet.new([:name, :age, :email]))
      # the 2-field {name, age} (1x) never extracted
      assert Enum.count(p.extractions, &(&1.kind == :map)) == 1
    end
  end

  describe "naming policy" do
    test "dictionary match: x/y -> Point" do
      src = """
      defmodule G do
        def a({x, y}), do: [x, y]
        def b({x, y}), do: [x, y]
        def c({x, y}), do: [x, y]
      end
      """

      assert %{name: "Point"} = extraction(plan(src), "Point")
      assert Subject.transform(src, opts()) =~ "defmodule Point do"
    end

    test "fallback name + TODO when the dictionary misses" do
      src = """
      defmodule G do
        def a({foo, bar}), do: [foo, bar]
        def b({foo, bar}), do: [foo, bar]
        def c({foo, bar}), do: [foo, bar]
      end
      """

      out = Subject.transform(src, opts())

      assert out =~ "defmodule ExtractedStruct1 do"
      assert out =~ "# TODO: rename"
      assert out =~ "%ExtractedStruct1{foo: foo, bar: bar}"
      assert_compiles(out)
    end

    test "fallback skips a name already taken by a project module" do
      src = """
      defmodule G do
        def a({foo, bar}), do: [foo, bar]
        def b({foo, bar}), do: [foo, bar]
        def c({foo, bar}), do: [foo, bar]
      end
      """

      structs = %{ExtractedStruct1 => MapSet.new([:other])}
      out = Subject.transform(src, opts(structs: structs))
      assert out =~ "defmodule ExtractedStruct2 do"
    end
  end

  describe "leaves alone — false-positive guards" do
    test "tagged tuples {:ok, _} / {:error, _} are never extracted" do
      src = """
      defmodule M do
        def a({:ok, v}), do: v
        def b({:ok, v}), do: v
        def c({:ok, v}), do: v
        def d({:error, r}), do: r
        def e({:error, r}), do: r
        def f({:error, r}), do: r
      end
      """

      assert_unchanged(Subject, src, opts())
      assert plan(src).extractions == []
    end

    test "a one-off transient tuple (below K) is left alone" do
      src = """
      defmodule M do
        def split({head, tail}), do: {head, tail}
      end
      """

      assert_unchanged(Subject, src, opts())
    end

    test "positionally INCONSISTENT heads decline (the anti-swap guard)" do
      # {lat, lng} twice, then {lng, lat} once — same arity, opposite
      # meaning. Extracting would silently swap fields. Must decline.
      src = """
      defmodule Geo do
        def a({lat, lng}), do: [lat, lng]
        def b({lat, lng}), do: [lat, lng]
        def c({lng, lat}), do: [lat, lng]
      end
      """

      assert_unchanged(Subject, src, opts())
      assert %{reason: :inconsistent_positions} = declined(plan(src), :inconsistent_positions)
    end

    test "non-injective positions (same stem twice) decline" do
      src = """
      defmodule Geo do
        def a({x, x2}), do: [x, x2]
        def b({x, x2}), do: [x, x2]
        def c({x, x2}), do: [x, x2]
      end
      """

      assert_unchanged(Subject, src, opts())
      assert declined(plan(src), :non_injective_positions)
    end

    test "a tuple literal flowing into a stdlib tuple API (Keyword.put) declines" do
      # The arity-2 shape is consumed by Keyword.put as a raw {k, v} pair —
      # wrapping it in a struct would break the keyword-list contract.
      src = """
      defmodule M do
        def a({key, val}), do: [key, val]
        def b({key, val}), do: [key, val]
        def c({key, val}), do: [key, val]
        def store(kw, key, val), do: Keyword.put(kw, {key, val})
      end
      """

      assert_unchanged(Subject, src, opts())
      assert declined(plan(src), :stdlib_tuple_consumer)
    end

    test "a shape that already matches an existing struct is not re-extracted" do
      src = """
      defmodule Geo do
        def a({lat, lng}), do: [lat, lng]
        def b({lat, lng}), do: [lat, lng]
        def c({lat, lng}), do: [lat, lng]
      end
      """

      structs = %{ExistingCoord => MapSet.new([:lat, :lng])}
      assert_unchanged(Subject, src, opts(structs: structs))
      assert declined(plan(src, structs: %{}), :already_a_struct) == nil
      # with the struct injected into build_plan, it declines:
      p =
        Subject.build_plan([
          {"lib/m.ex", src},
          {"lib/x.ex", "defmodule ExistingCoord do\n defstruct [:lat, :lng]\nend\n"}
        ])

      assert declined(p, :already_a_struct)
    end

    test "arity-1 tuples and bare-var params are ignored" do
      src = """
      defmodule M do
        def a(point), do: point
        def b(point), do: point
        def c(point), do: point
      end
      """

      assert_unchanged(Subject, src, opts())
    end
  end

  describe "idempotence" do
    test "applying twice equals applying once (tuple)" do
      src = """
      defmodule Geo do
        def distance({lat1, lng1}, {lat2, lng2}), do: {lat1, lng1}
        def origin({lat, lng}), do: [lat, lng]
        def shift({lat, lng}), do: [lat, lng]
      end
      """

      assert_idempotent(Subject, src, opts())
    end

    test "applying twice equals applying once (map)" do
      src = """
      defmodule People do
        def a(%{name: n, age: g}), do: [n, g]
        def b(%{name: n, age: g}), do: [n, g]
        def c(%{name: n, age: g}), do: [n, g]
      end
      """

      assert_idempotent(Subject, src, opts())
    end

    test "already-conformant code (no bare shapes) is left alone" do
      src = """
      defmodule Geo do
        def origin(%Coord{lat: lat, lng: lng}), do: [lat, lng]
      end
      """

      assert_unchanged(Subject, src, opts(structs: %{Coord => MapSet.new([:lat, :lng])}))
    end
  end

  describe "compilation safety on every extraction path" do
    test "map extraction output compiles" do
      src = """
      defmodule People do
        def greet(%{name: n, age: a}), do: {n, a}
        def label(%{name: n, age: a}), do: {n, a}
        def show(%{name: n, age: a}), do: {n, a}
      end
      """

      assert_compiles(Subject.transform(src, opts()))
    end

    test "3-tuple extraction output compiles" do
      src = """
      defmodule Space do
        def a({x, y, z}), do: [x, y, z]
        def b({x, y, z}), do: [x, y, z]
        def c({x, y, z}), do: [x, y, z]
      end
      """

      out = Subject.transform(src, opts())
      assert out =~ "defmodule Point3D do"
      assert_compiles(out)
    end

    test "fallback-named extraction output compiles" do
      src = """
      defmodule M do
        def a({alpha, beta}), do: [alpha, beta]
        def b({alpha, beta}), do: [alpha, beta]
        def c({alpha, beta}), do: [alpha, beta]
      end
      """

      assert_compiles(Subject.transform(src, opts()))
    end
  end
end
