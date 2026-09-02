defmodule Number42.Refactors.Ex.MergeNearCloneFunctionsTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Ex.MergeNearCloneFunctions, as: Merge
  alias Number42.Refactors.Ex.NearClones

  defp run(src, opts \\ []) do
    opts = Keyword.merge([enabled: true, threshold: 0.7, min_merge_mass: 0], opts)
    Merge.transform(src, opts)
  end

  defp compiles?(src), do: match?({:ok, _}, Code.string_to_quoted(src))

  describe "same-module merge — value lift" do
    @two_unit_fns ~S'''
    defmodule M do
      def unit_circle_area(%{args: [rad]}, r, vf) do
        case vf.(rad, r) do
          {:ok, dim} when dim in [:length, :dimensionless] -> {:ok, :area}
          {:ok, dim} -> {:error, "circle_area: bad dim"}
          {:error, _} = err -> err
        end
      end

      def unit_circle_circumference(%{args: [rad]}, r, vf) do
        case vf.(rad, r) do
          {:ok, dim} when dim in [:length, :dimensionless] -> {:ok, :length}
          {:ok, dim} -> {:error, "circle_circumference: bad dim"}
          {:error, _} = err -> err
        end
      end
    end
    '''

    test "two near-clone siblings collapse into one parametrised helper" do
      out = run(@two_unit_fns)

      refute out == @two_unit_fns
      assert compiles?(out)
      # one shared helper appears …
      assert out =~ ~r/defp unit_circle\(/
      # … and both originals now delegate to it
      assert out =~
               ~r/def unit_circle_area\(c0, c1, c2\),\s*\n\s*do: unit_circle\(c0, c1, c2, :area,/

      assert out =~
               ~r/def unit_circle_circumference\(c0, c1, c2\),\s*\n\s*do: unit_circle\(c0, c1, c2, :length,/
    end

    test "the divergent values become the trailing helper params, body uses them" do
      out = run(@two_unit_fns)

      assert out =~ ~r/defp unit_circle\(%\{args: \[rad\]\}, r, vf, arg_\w+_0, arg_\w+_1\)/
      assert out =~ "{:ok, arg_atom_0}"
      assert out =~ "{:error, arg_value_1}"
      # the concrete divergent values no longer appear in the helper body
      refute out =~ ~r/defp unit_circle.*:area/s
    end

    test "delegations forward the original args untouched via capture vars" do
      out = run(@two_unit_fns)
      # not re-passing the %{args: [rad]} pattern — a plain capture var
      assert out =~ "def unit_circle_area(c0, c1, c2)"
      refute out =~ "do: unit_circle(%{args: [rad]}"
    end
  end

  describe "decline gates" do
    test "a lone function (no twin) is left untouched" do
      src = ~S'''
      defmodule M do
        def only(%{args: [rad]}, r, vf) do
          case vf.(rad, r) do
            {:ok, dim} -> {:ok, dim}
            {:error, _} = err -> err
          end
        end
      end
      '''

      assert run(src) == src
    end

    test "a structural divergence declines (extra statement)" do
      src = ~S'''
      defmodule M do
        def a(x, vf) do
          y = vf.(x)
          z = y + 1
          {:ok, z, :a}
        end

        def b(x, vf) do
          y = vf.(x)
          z = y + 1
          logged = log(z)
          {:ok, z, :b, logged}
        end
      end
      '''

      assert run(src) == src
    end

    test "an ambiguous lift value declines (the divergent value occurs twice)" do
      # The literal 1.19 diverges to 1.07 — but it appears TWICE in the body, so
      # the lifted value can't be located to a single slot → decline.
      src = ~S'''
      defmodule M do
        def a(x, y) do
          left = x * 1.19
          right = y * 1.19
          {left, right, :a}
        end

        def b(x, y) do
          left = x * 1.07
          right = y * 1.07
          {left, right, :b}
        end
      end
      '''

      assert run(src) == src
    end

    test "below the min_merge_mass floor declines (trivial one-liner ×N)" do
      src = ~S'''
      defmodule M do
        def show_a(socket, cs), do: {:noreply, assign(socket, form: cs, kind: :a)}
        def show_b(socket, cs), do: {:noreply, assign(socket, form: cs, kind: :b)}
      end
      '''

      assert run(src, min_merge_mass: 40) == src
    end
  end

  describe "idempotence" do
    test "a second run is a no-op" do
      once = run(@two_unit_fns)
      twice = run(once)
      assert twice == once
    end
  end

  describe "default-OFF" do
    test "without enabled: true the source is untouched" do
      assert Merge.transform(@two_unit_fns, threshold: 0.7, min_merge_mass: 0) == @two_unit_fns
    end
  end

  describe "cross-file merge" do
    # Two modules with a verbatim-clone function whose body calls a *private*
    # helper (`fmt/1`) defined differently in each module. The host keeps an
    # original-arity wrapper passing its own `&fmt/1`; the clone delegates to the
    # host's lifted arity passing ITS own `&fmt/1`. So each runs its own private.
    setup do
      root = Path.join(System.tmp_dir!(), "merge_#{System.unique_integer([:positive])}")
      dir = Path.join([root, "lib", "app", "views"])
      File.mkdir_p!(dir)
      a = Path.join(dir, "a.ex")
      b = Path.join(dir, "b.ex")
      helper = Path.join([root, "lib", "app", "views", "helper.ex"])

      File.write!(a, ~S'''
      defmodule App.Views.A do
        def render(rows) do
          rows
          |> Enum.map(fn r -> %{id: r.id, text: fmt(r.value), kind: :row} end)
          |> Enum.sort_by(& &1.id)
          |> Enum.take(50)
        end

        defp fmt(v), do: "A:#{v}"
      end
      ''')

      File.write!(b, ~S'''
      defmodule App.Views.B do
        def render(rows) do
          rows
          |> Enum.map(fn r -> %{id: r.id, text: fmt(r.value), kind: :row} end)
          |> Enum.sort_by(& &1.id)
          |> Enum.take(50)
        end

        defp fmt(v), do: "B:#{v}"
      end
      ''')

      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, a: a, b: b, root: root, helper: helper}
    end

    test "the body moves to the LCP helper module and both clones delegate", ctx do
      {:ok, prepared} =
        Merge.prepare(
          source_files: [ctx.a, ctx.b],
          min_merge_mass: 0,
          threshold: 0.85,
          write_root: ctx.root
        )

      out_a = Merge.transform(File.read!(ctx.a), enabled: true, prepared: prepared)
      out_b = Merge.transform(File.read!(ctx.b), enabled: true, prepared: prepared)

      assert compiles?(out_a)
      assert compiles?(out_b)

      # Neither module keeps the body; both call the helper with their own &fmt/1.
      for out <- [out_a, out_b] do
        refute out =~ "Enum.sort_by"
        assert out =~ ~r/def render\(c0\),\s*\n\s*do: App\.Views\.Helper\.render\(c0, &fmt\/1\)/
      end

      # The helper lands on the least common denominator of both module names.
      assert File.exists?(ctx.helper)
      helper = File.read!(ctx.helper)
      assert compiles?(helper)
      assert helper =~ "defmodule App.Views.Helper do"
      assert helper =~ ~r/def render\(rows, fun_fmt\)/
      assert helper =~ "fun_fmt.(r.value)"
    end

    test "a second cluster is appended to the helper module that already exists", ctx do
      File.write!(ctx.helper, """
      defmodule App.Views.Helper do
        def already_here, do: :ok
      end
      """)

      {:ok, prepared} =
        Merge.prepare(
          source_files: [ctx.a, ctx.b],
          min_merge_mass: 0,
          threshold: 0.85,
          write_root: ctx.root
        )

      assert prepared.rewrites != %{}

      helper = File.read!(ctx.helper)
      assert compiles?(helper)
      assert helper =~ "def already_here, do: :ok"
      assert helper =~ ~r/def render\(rows, fun_fmt\)/
    end

    test "dry_run emits nothing to disk", ctx do
      {:ok, _prepared} =
        Merge.prepare(
          source_files: [ctx.a, ctx.b],
          min_merge_mass: 0,
          threshold: 0.85,
          write_root: ctx.root,
          dry_run: true
        )

      refute File.exists?(ctx.helper)
    end

    test "a multi-clause function is never cross-file merged", ctx do
      # Give B's `render` a second clause → it must not be merged (dispatch).
      File.write!(ctx.b, ~S'''
      defmodule App.Views.B do
        def render([]), do: []

        def render(rows) do
          rows
          |> Enum.map(fn r -> %{id: r.id, text: fmt(r.value), kind: :row} end)
          |> Enum.sort_by(& &1.id)
          |> Enum.take(50)
        end

        defp fmt(v), do: "B:#{v}"
      end
      ''')

      {:ok, prepared} =
        Merge.prepare(source_files: [ctx.a, ctx.b], min_merge_mass: 0, threshold: 0.85)

      assert prepared.rewrites == %{}
    end
  end

  describe "same-module merge — :max_mass" do
    # Two structurally identical bodies, each far past the 120-node default cap.
    defp big_pair(a_literal, b_literal) do
      steps =
        1..40
        |> Enum.map_join("\n", fn i ->
          "      |> Enum.map(fn x -> x * #{i} + acc end)"
        end)

      """
      defmodule M do
        def wide_a(rows, acc) do
          rows
      #{steps}
          |> Enum.take(#{a_literal})
        end

        def wide_b(rows, acc) do
          rows
      #{steps}
          |> Enum.take(#{b_literal})
        end
      end
      """
    end

    test "bodies past the default node cap are left untouched" do
      src = big_pair(10, 20)

      assert run(src) == src
    end

    test "raising :max_mass lets the clustering see them at all" do
      src = big_pair(10, 20)
      opts = [threshold: 0.7, min_merge_mass: 0, min_mass: 10]

      assert NearClones.from_sources([{"_", src}], opts ++ [max_mass: 120]) == []

      assert [%{mass: mass, mergeable: true}] =
               NearClones.from_sources([{"_", src}], opts ++ [max_mass: 4_000])

      assert mass > 120
    end
  end

  describe "cross-file merge — configured helper target" do
    setup do
      root = Path.join(System.tmp_dir!(), "merge_cfg_#{System.unique_integer([:positive])}")
      dir = Path.join([root, "apps", "web", "lib", "web", "views"])
      File.mkdir_p!(dir)
      a = Path.join(dir, "a.ex")
      b = Path.join(dir, "b.ex")

      File.write!(a, ~S'''
      defmodule Web.Views.A do
        def render(rows) do
          rows
          |> Enum.map(fn r -> %{id: r.id, text: r.value, kind: :row} end)
          |> Enum.sort_by(& &1.id)
          |> Enum.take(50)
        end
      end
      ''')

      File.write!(b, ~S'''
      defmodule Web.Views.B do
        def render(rows) do
          rows
          |> Enum.map(fn r -> %{id: r.id, text: r.value, kind: :row} end)
          |> Enum.sort_by(& &1.id)
          |> Enum.take(50)
        end
      end
      ''')

      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, a: a, b: b, root: root}
    end

    defp prepare(ctx, extra) do
      {:ok, prepared} =
        Merge.prepare(
          [source_files: [ctx.a, ctx.b], min_merge_mass: 0, threshold: 0.85, write_root: ctx.root] ++
            extra
        )

      prepared
    end

    test "a matching glob replaces the LCP prefix, keeping its last segment", ctx do
      prepare(ctx, helper_module_globs: [{"apps/web/**", "Web.Helpers"}])

      path = Path.join([ctx.root, "apps", "web", "lib", "web", "helpers", "views.ex"])
      assert File.exists?(path)
      assert File.read!(path) =~ "defmodule Web.Helpers.Views do"
    end

    test "without a matching glob the LCP rule still applies", ctx do
      prepare(ctx, helper_module_globs: [{"apps/other/**", "Other.Helpers"}])

      path = Path.join([ctx.root, "apps", "web", "lib", "web", "views", "helper.ex"])
      assert File.exists?(path)
      assert File.read!(path) =~ "defmodule Web.Views.Helper do"
    end

    test "clones without a common module prefix land in the configured default" do
      root = Path.join(System.tmp_dir!(), "merge_def_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([root, "lib", "alpha"]))
      File.mkdir_p!(Path.join([root, "lib", "beta"]))
      a = Path.join([root, "lib", "alpha", "a.ex"])
      b = Path.join([root, "lib", "beta", "b.ex"])
      on_exit(fn -> File.rm_rf!(root) end)

      body = """
        def render(rows) do
          rows
          |> Enum.map(fn r -> %{id: r.id, text: r.value, kind: :row} end)
          |> Enum.sort_by(& &1.id)
          |> Enum.take(50)
        end
      """

      File.write!(a, "defmodule Alpha do\n" <> body <> "end\n")
      File.write!(b, "defmodule Beta do\n" <> body <> "end\n")

      {:ok, prepared} =
        Merge.prepare(
          source_files: [a, b],
          min_merge_mass: 0,
          threshold: 0.85,
          write_root: root,
          default_helper_module: "Shared.Helper"
        )

      assert prepared.rewrites != %{}
      # `shared_module_path/3` derives only the top-level segment from the existing
      # layout, so the configured module keeps its name but lands under `lib/alpha`.
      path = Path.join([root, "lib", "alpha", "helper.ex"])
      assert File.exists?(path)
      assert File.read!(path) =~ "defmodule Shared.Helper do"
    end

    test "clones without a common prefix and no default still decline" do
      root = Path.join(System.tmp_dir!(), "merge_nodef_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([root, "lib", "alpha"]))
      File.mkdir_p!(Path.join([root, "lib", "beta"]))
      a = Path.join([root, "lib", "alpha", "a.ex"])
      b = Path.join([root, "lib", "beta", "b.ex"])
      on_exit(fn -> File.rm_rf!(root) end)

      body = """
        def render(rows) do
          rows
          |> Enum.map(fn r -> %{id: r.id, text: r.value, kind: :row} end)
          |> Enum.sort_by(& &1.id)
          |> Enum.take(50)
        end
      """

      File.write!(a, "defmodule Alpha do\n" <> body <> "end\n")
      File.write!(b, "defmodule Beta do\n" <> body <> "end\n")

      {:ok, prepared} =
        Merge.prepare(source_files: [a, b], min_merge_mass: 0, threshold: 0.85, write_root: root)

      assert prepared.rewrites == %{}
    end
  end
end
