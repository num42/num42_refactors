defmodule Number42.Refactors.Analysis.IdentifierCompressionTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Analysis.IdentifierCompression, as: IC

  describe "parts/1" do
    test "splits on word boundaries and keeps the sigil apart" do
      assert IC.parts("node_search_other_nodes!") ==
               {["node", "search", "other", "nodes"], "!"}
    end

    test "a plain name has no sigil" do
      assert IC.parts("build_serie_match_conditions") ==
               {["build", "serie", "match", "conditions"], ""}
    end

    test "camel case counts as a word boundary too" do
      assert IC.parts("buildSerieMatch") == {["build", "serie", "match"], ""}
    end

    test "a question mark is a sigil like the bang" do
      assert IC.parts("valid_for_current_user?") ==
               {["valid", "for", "current", "user"], "?"}
    end
  end

  describe "compress/3 — the trigger" do
    test "leaves a name with fewer than five parts alone" do
      assert IC.compress("build_match_conditions_binding", %{}) == :keep
    end

    test "acts from five parts up" do
      assert {:ok, _} = IC.compress("build_serie_match_conditions_match_fields", %{})
    end
  end

  describe "compress/3 — dedupe after stemming" do
    test "drops a token whose stem already occurred" do
      assert {:ok, "build_match_conditions_binding"} =
               IC.compress("build_serie_match_conditions_match_binding", %{})
    end

    test "singular and plural of one word count as one token" do
      assert {:ok, name} = IC.compress("load_position_children_positions_map_binding", %{})
      refute name =~ ~r/position.*position/
    end
  end

  describe "compress/3 — positional immunity" do
    test "the first and last token always survive" do
      assert {:ok, name} = IC.compress("build_x_of_the_serie_conditions", %{})
      assert String.starts_with?(name, "build")
      assert String.ends_with?(name, "conditions")
    end

    test "before a sigil the second-to-last token survives too" do
      assert {:ok, name} = IC.compress("valid_in_the_x_current_user?", %{})
      assert name =~ "current_user?"
    end
  end

  describe "compress/3 — filler and cryptic tokens go first" do
    test "generic filler carries no meaning and is dropped" do
      assert {:ok, "build_serie_conditions"} =
               IC.compress("build_the_serie_data_value_conditions", %{})
    end

    test "a cryptic short token in the middle is dropped" do
      assert {:ok, name} = IC.compress("build_serie_x_qq_match_conditions", %{})
      refute name =~ "_x_"
      refute name =~ "qq"
    end
  end

  describe "compress/3 — corpus frequency" do
    test "a token carried by nearly every identifier is dropped first" do
      corpus = %{"binding" => 40, "serie" => 1, "match" => 2, "conditions" => 3}

      assert {:ok, name} =
               IC.compress("build_serie_match_conditions_binding_fields", corpus, corpus_size: 40)

      refute name =~ "binding"
      assert name =~ "serie"
    end

    test "without corpus data the order falls back to the token's own information" do
      assert {:ok, name} = IC.compress("build_serie_match_conditions_binding_fields", %{})
      assert IC.parts(name) |> elem(0) |> length() <= 4
    end
  end

  describe "compress/3 — invariants" do
    test "never drops below two tokens" do
      assert {:ok, name} = IC.compress("a_the_of_and_for_b", %{})
      assert IC.parts(name) |> elem(0) |> length() >= 2
    end

    test "the result keeps the original token order" do
      assert {:ok, name} = IC.compress("build_serie_match_conditions_match_fields", %{})
      {parts, _} = IC.parts(name)
      {original, _} = IC.parts("build_serie_match_conditions_match_fields")
      assert parts == Enum.filter(Enum.uniq(original), &(&1 in parts))
    end

    test "the sigil survives the compression" do
      assert {:ok, name} = IC.compress("has_the_serie_data_match_conditions?", %{})
      assert String.ends_with?(name, "?")
    end

    test "is idempotent — a compressed name compresses to itself" do
      assert {:ok, once} = IC.compress("build_serie_match_conditions_match_fields", %{})
      assert IC.compress(once, %{}) == :keep
    end
  end

  describe "corpus/1" do
    test "counts in how many identifiers each token appears" do
      corpus = IC.corpus(["build_serie_match", "build_match_conditions"])

      assert corpus["build"] == 2
      assert corpus["match"] == 2
      assert corpus["serie"] == 1
    end

    test "counts an identifier once per token, not per occurrence" do
      assert IC.corpus(["match_match_match"])["match"] == 1
    end
  end
end
