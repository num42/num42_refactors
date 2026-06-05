defmodule Number42.Refactors.BlockSegmentationTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.BlockSegmentation

  # Parse a `do … end` block body into the list of statement ASTs that
  # BlockSegmentation operates on — mirrors how a refactor hands it the
  # body of a function.
  defp body_exprs(code) do
    {:ok, ast} = Sourceror.parse_string(code)

    case ast do
      {:__block__, _, exprs} -> exprs
      single -> [single]
    end
  end

  defp names(mapset), do: mapset |> MapSet.to_list() |> Enum.sort()

  describe "segment/1 — per-statement reads/writes" do
    test "a binding reads its RHS free vars and writes its LHS name" do
      [seg] =
        BlockSegmentation.segment(body_exprs("subtotal = sum_lines(order)"))

      assert seg.index == 0
      # call name `sum_lines` parses as a call (args present), not a var read
      assert names(seg.reads) == [:order]
      assert names(seg.writes) == [:subtotal]
    end

    test "chains threads writes of earlier statements into reads of later" do
      segs =
        BlockSegmentation.segment(
          body_exprs("""
          subtotal = sum_lines(order)
          tax = subtotal * rate
          total = subtotal + tax
          """)
        )

      assert Enum.map(segs, & &1.index) == [0, 1, 2]

      assert names(Enum.at(segs, 0).writes) == [:subtotal]
      assert names(Enum.at(segs, 1).reads) == [:rate, :subtotal]
      assert names(Enum.at(segs, 1).writes) == [:tax]
      assert names(Enum.at(segs, 2).reads) == [:subtotal, :tax]
      assert names(Enum.at(segs, 2).writes) == [:total]
    end

    test "a non-binding tail statement writes nothing, reads its free vars" do
      [seg] = BlockSegmentation.segment(body_exprs("format(total, tax)"))

      # `format` is the call name, not a var read; only the args are reads
      assert names(seg.reads) == [:tax, :total]
      assert MapSet.size(seg.writes) == 0
    end

    test "a tuple-pattern binding writes every bound name" do
      [seg] = BlockSegmentation.segment(body_exprs("{a, b} = phase(x)"))

      assert names(seg.writes) == [:a, :b]
      assert names(seg.reads) == [:x]
    end

    test "carries the original statement AST through unchanged" do
      [stmt] = exprs = body_exprs("total = subtotal + tax")
      [seg] = BlockSegmentation.segment(exprs)

      assert seg.ast == stmt
    end
  end

  describe "carriers/1 — values flowing across statements" do
    test "a name written then read later is a carrier" do
      carriers =
        "subtotal = sum_lines(order)\ntax = subtotal * rate"
        |> body_exprs()
        |> BlockSegmentation.segment()
        |> BlockSegmentation.carriers()

      assert names(carriers) == [:subtotal]
    end

    test "a name written but never read later is not a carrier" do
      carriers =
        "subtotal = sum_lines(order)\ntax = rate * 2"
        |> body_exprs()
        |> BlockSegmentation.segment()
        |> BlockSegmentation.carriers()

      assert names(carriers) == []
    end

    test "multiple carriers when several writes are read downstream" do
      carriers =
        """
        subtotal = sum_lines(order)
        tax = subtotal * rate
        total = subtotal + tax
        """
        |> body_exprs()
        |> BlockSegmentation.segment()
        |> BlockSegmentation.carriers()

      assert names(carriers) == [:subtotal, :tax]
    end
  end

  describe "live_out/2 — carriers crossing a cut at index k" do
    setup do
      segs =
        """
        subtotal = sum_lines(order)
        tax = subtotal * rate
        total = subtotal + tax
        format(total, tax)
        """
        |> body_exprs()
        |> BlockSegmentation.segment()

      {:ok, segs: segs}
    end

    test "names written at/before the cut and read after it", %{segs: segs} do
      # cut after statement 0: subtotal is written before, read after
      assert names(BlockSegmentation.live_out(segs, 1)) == [:subtotal]
    end

    test "wider cut accumulates more live-out names", %{segs: segs} do
      # cut after statements 0..1: subtotal and tax both read after
      assert names(BlockSegmentation.live_out(segs, 2)) == [:subtotal, :tax]
    end

    test "cut after the last work-producing statement", %{segs: segs} do
      # cut after statements 0..2: total + tax read by the tail
      assert names(BlockSegmentation.live_out(segs, 3)) == [:tax, :total]
    end
  end

  describe "group_phases/2 — segmenting into low-carrier phases" do
    test "splits at the narrowest data-flow boundary" do
      segs =
        """
        subtotal = sum_lines(order)
        discount = lookup_discount(order)
        net = subtotal - discount
        tax = net * rate
        total = net + tax
        """
        |> body_exprs()
        |> BlockSegmentation.segment()

      phases = BlockSegmentation.group_phases(segs, min_statements_per_phase: 2, min_phases: 2)

      assert length(phases) >= 2
      # every phase is a contiguous, non-empty run of segments
      assert Enum.all?(phases, fn p -> p != [] end)
      # phases partition the segments in order
      flattened = Enum.flat_map(phases, fn p -> Enum.map(p, & &1.index) end)
      assert flattened == Enum.to_list(0..(length(segs) - 1))
    end

    test "respects min_statements_per_phase — no phase shorter than the floor" do
      segs =
        """
        a = f(x)
        b = g(a)
        c = h(b)
        d = i(c)
        """
        |> body_exprs()
        |> BlockSegmentation.segment()

      phases = BlockSegmentation.group_phases(segs, min_statements_per_phase: 2, min_phases: 2)

      assert Enum.all?(phases, fn p -> length(p) >= 2 end)
    end

    test "returns a single phase when no clean cut meets the constraints" do
      segs =
        """
        a = f(x)
        b = g(a, x)
        """
        |> body_exprs()
        |> BlockSegmentation.segment()

      phases = BlockSegmentation.group_phases(segs, min_statements_per_phase: 2, min_phases: 2)

      assert length(phases) == 1
    end
  end
end
