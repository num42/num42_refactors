defmodule Number42.Refactors.SemanticTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Semantic

  describe "classify/1 parity with the Python Model2Vec POC" do
    # Ground truth = the verb the static-embedding classifier assigns. These
    # are synonym words the @verb_rules stem table does NOT enumerate, so the
    # model is what reaches the bucket — its exclusive contribution. Words the
    # table already owns (tally, sum, sanitize as full stems) are covered there
    # and never reach the classifier.
    @model_cases %{
      "accumulate_rows" => :compute,
      "consolidate_totals" => :compute,
      "reload_brands" => :fetch,
      "finalize_draft" => :normalize,
      "analyze_spread" => :compute
    }

    for {call, expected} <- @model_cases do
      test "#{call} -> #{expected}" do
        assert {:ok, unquote(expected), score} = Semantic.classify(unquote(call))
        assert score > 0.0
      end
    end
  end

  describe "classify/1 confidence gate" do
    test "semantically empty names return :unknown (keep _block fallback)" do
      assert Semantic.classify("do_thing") == :unknown
      assert Semantic.classify("process") == :unknown
      assert Semantic.classify("handle_stuff") == :unknown
    end

    test "unknown vocabulary returns :unknown, never crashes" do
      assert Semantic.classify("xyzzy_frobnicate") == :unknown
    end
  end

  describe "classify/1 basics" do
    test "strips the module segment of a dotted call" do
      assert {:ok, :compute, _} = Semantic.classify("Reports.aggregate_totals")
    end

    test "labels/0 exposes the closed bucket set" do
      labels = Semantic.labels()
      assert :compute in labels
      assert :fetch in labels
      assert length(labels) == 10
    end
  end
end
