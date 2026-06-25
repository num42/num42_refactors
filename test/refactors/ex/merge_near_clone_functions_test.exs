defmodule Number42.Refactors.Ex.MergeNearCloneFunctionsTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Ex.MergeNearCloneFunctions, as: Merge

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
      tmp = System.tmp_dir!()
      uniq = System.unique_integer([:positive])
      a = Path.join(tmp, "a_#{uniq}.ex")
      b = Path.join(tmp, "b_#{uniq}.ex")

      File.write!(a, ~S'''
      defmodule A do
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
      defmodule B do
        def render(rows) do
          rows
          |> Enum.map(fn r -> %{id: r.id, text: fmt(r.value), kind: :row} end)
          |> Enum.sort_by(& &1.id)
          |> Enum.take(50)
        end

        defp fmt(v), do: "B:#{v}"
      end
      ''')

      on_exit(fn ->
        File.rm(a)
        File.rm(b)
      end)

      {:ok, a: a, b: b}
    end

    test "host keeps an original-arity wrapper; clone delegates with its own private", ctx do
      {:ok, prepared} =
        Merge.prepare(source_files: [ctx.a, ctx.b], min_merge_mass: 0, threshold: 0.85)

      out_a = Merge.transform(File.read!(ctx.a), enabled: true, prepared: prepared)
      out_b = Merge.transform(File.read!(ctx.b), enabled: true, prepared: prepared)

      # One of the two is the host (in-place wrapper + lifted helper), the other
      # delegates qualified. Identify by which gained a `fun_fmt` param.
      {host, clone} = if out_a =~ "fun_fmt", do: {out_a, out_b}, else: {out_b, out_a}

      assert compiles?(host)
      assert compiles?(clone)

      # host: original-arity wrapper forwarding its own &fmt/1 + the lifted clause
      assert host =~ ~r/def render\(c0\),\s*\n\s*do: render\(c0, &fmt\/1\)/
      assert host =~ ~r/def render\(rows, fun_fmt\)/
      assert host =~ "fun_fmt.(r.value)"

      # clone: delegates to the host module's lifted arity, passing ITS own &fmt/1
      assert clone =~ ~r/def render\(c0\),\s*\n\s*do: [A-Z]\w*\.render\(c0, &fmt\/1\)/
    end

    test "a multi-clause function is never cross-file merged", ctx do
      # Give B's `render` a second clause → it must not be merged (dispatch).
      File.write!(ctx.b, ~S'''
      defmodule B do
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
end
