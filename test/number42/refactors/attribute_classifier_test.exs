defmodule Number42.Refactors.AttributeClassifierTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Analysis.AttributeClassifier

  describe "classify/1 — real adjectives" do
    # Parity with the trained Python model. Synonyms generalize to their class.
    @cases %{
      "active" => :active,
      "archived" => :inactive,
      "deleted" => :deleted,
      "pending" => :pending,
      "public" => :visible,
      "old" => :stale,
      "visibility" => :visible
    }

    for {field, expected} <- @cases do
      test "#{field} -> #{expected}" do
        assert {:ok, unquote(expected)} = AttributeClassifier.classify(unquote(field))
      end
    end
  end

  describe "classify/1 — :none default" do
    test "ordinary field names are not attributes" do
      assert AttributeClassifier.classify("position") == :none
      assert AttributeClassifier.classify("item") == :none
      assert AttributeClassifier.classify("winner") == :none
      assert AttributeClassifier.classify("manufacturer") == :none
    end

    test "a field outside the lexicon returns :none, never crashes" do
      assert AttributeClassifier.classify("xyzzy") == :none
    end
  end
end
