defmodule Number42.Refactors.IdentifierExpansionTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.IdentifierExpansion

  # -------------------------------------------------------------------
  # latch_match/2 — core matcher
  # -------------------------------------------------------------------

  describe "latch_match/2 — happy paths" do
    test "initials-of-all match" do
      assert {:ok, 0, 2} = IdentifierExpansion.latch_match("bi", ~w(brand item))
    end

    test "single initial + subsequence in tail" do
      assert {:ok, 0, 1} = IdentifierExpansion.latch_match("cs", ~w(changeset))
    end

    test "partial initial match starting mid-list" do
      assert {:ok, 1, 1} = IdentifierExpansion.latch_match("cs", ~w(build changeset))
    end

    test "no match" do
      assert :error = IdentifierExpansion.latch_match("xyz", ~w(build changeset))
    end

    test "empty short" do
      assert :error = IdentifierExpansion.latch_match("", ~w(anything))
    end

    test "empty subtokens" do
      assert :error = IdentifierExpansion.latch_match("ab", [])
    end
  end

  describe "latch_match/2 — subsequence-in-tail detection" do
    test "exposes whether tail-match used subsequence (consumed_via_subsequence_in_tail?)" do
      # `ast ↔ asset`: a-init, then `st` must scan past `s,s,e` (skips 2)
      # in `sset` — that's subsequence, not contiguous prefix.
      assert true = IdentifierExpansion.consumed_via_subsequence_in_tail?("ast", ~w(asset))
    end

    test "contiguous tail match is not subsequence" do
      # `cs ↔ changeset`: c-init, then `s` lands at pos 5 in `hangeset`.
      # Single remaining char → trivially contiguous, not "subsequence-with-skips".
      # We treat single-char tail as contiguous (no skips to count).
      assert false == IdentifierExpansion.consumed_via_subsequence_in_tail?("cs", ~w(changeset))
    end

    test "pure initials match is not subsequence" do
      assert false == IdentifierExpansion.consumed_via_subsequence_in_tail?("bi", ~w(brand item))
    end
  end

  # -------------------------------------------------------------------
  # score_latch/4 — base scoring with source-trust
  # -------------------------------------------------------------------

  describe "score_latch/4 — happy paths" do
    test "initials-of-all with strong source → 100" do
      latch = {:ok, 0, 2}
      assert 100 = IdentifierExpansion.score_latch(latch, "bi", ~w(brand item), :alias)
    end

    test "initials-of-subset with strong source → 80" do
      latch = {:ok, 0, 2}
      assert 80 = IdentifierExpansion.score_latch(latch, "fb", ~w(formula builder node), :alias)
    end

    test "single initial + 1 tail char (2 chars in subtoken) → 100 (cs ↔ changeset)" do
      latch = {:ok, 0, 1}
      assert 100 = IdentifierExpansion.score_latch(latch, "cs", ~w(changeset), :alias)
    end

    test "single initial + 1 tail char → 100 (oz ↔ organization)" do
      # 2 chars in subtoken `organization` → under threshold → ok.
      latch = {:ok, 0, 1}
      assert 100 = IdentifierExpansion.score_latch(latch, "oz", ~w(organization), :alias)
    end

    test "3 chars in one subtoken with vowel → 0 (ast ↔ asset)" do
      # `a,s,t` contributed to `asset`. `a` is vowel → reject.
      latch = {:ok, 0, 1}
      assert 0 = IdentifierExpansion.score_latch(latch, "ast", ~w(asset), :alias)
    end

    test "3 chars in one subtoken with vowel → 0 (ref ↔ reference_building)" do
      # `r,e,f` contributed to `reference`. `e` is vowel → reject.
      latch = {:ok, 0, 1}

      assert 0 =
               IdentifierExpansion.score_latch(latch, "ref", ~w(reference building), :alias)
    end

    test "3+ chars in one subtoken, all consonants → 100 (mngr ↔ manager)" do
      # `m,n,g,r` all consonants → consonant-only abbreviation, accept.
      latch = {:ok, 0, 1}
      assert 100 = IdentifierExpansion.score_latch(latch, "mngr", ~w(manager), :alias)
    end

    test "3+ chars in one subtoken, all consonants → 100 (brnd ↔ brand)" do
      latch = {:ok, 0, 1}
      assert 100 = IdentifierExpansion.score_latch(latch, "brnd", ~w(brand), :alias)
    end

    test "no match → 0" do
      assert 0 = IdentifierExpansion.score_latch(:error, "xyz", ~w(anything), :alias)
    end
  end

  describe "score_latch/4 — weak source requires short >= 3 chars (Bug-Klasse 2)" do
    test "2-char short against weak source → 0 (even if initials-of-all)" do
      # `id ↔ [item, discontinuation]` — 2 chars hit all initials,
      # but weak source (local def name) must be rejected.
      latch = {:ok, 0, 2}

      assert 0 =
               IdentifierExpansion.score_latch(latch, "id", ~w(item discontinuation), :local_def)
    end

    test "2-char short against weak source body_binding → 0" do
      latch = {:ok, 0, 2}

      assert 0 =
               IdentifierExpansion.score_latch(latch, "is", ~w(image signer), :body_binding)
    end

    test "2-char short against strong source (alias) → still scored" do
      # If user explicitly aliases `BrandItem`, `bi` may resolve via it.
      latch = {:ok, 0, 2}
      assert 100 = IdentifierExpansion.score_latch(latch, "bi", ~w(brand item), :alias)
    end

    test "3-char short against weak source with non-suffix tail → 0 (run ↔ runner)" do
      # `runner` ends with `er`, not `un` → suffix rule rejects.
      latch = {:ok, 0, 1}
      assert 0 = IdentifierExpansion.score_latch(latch, "run", ~w(runner), :local_def)
    end
  end

  # -------------------------------------------------------------------
  # resolve/3 — full pipeline with all gates
  # -------------------------------------------------------------------

  describe "resolve/3 — happy paths" do
    test "resolves `cs` to `changeset` via RHS-call (strong source)" do
      candidates = [{"build_changeset", :rhs_call}]
      opts = default_opts()
      assert {:ok, "changeset"} = IdentifierExpansion.resolve("cs", candidates, opts)
    end

    test "resolves `bi` to `brand_item` via aliased module" do
      candidates = [{"brand_item", :alias}]
      opts = default_opts()
      assert {:ok, "brand_item"} = IdentifierExpansion.resolve("bi", candidates, opts)
    end

    test "uses known mapping when present, bypassing heuristic" do
      candidates = [{"item_discontinuation", :local_def}]
      opts = %{default_opts() | known: %{"id" => "identifier"}}
      assert {:ok, "identifier"} = IdentifierExpansion.resolve("id", candidates, opts)
    end

    test "returns :skip when no candidate scores above threshold" do
      candidates = [{"asset_preview", :local_def}]
      opts = default_opts()
      assert :skip = IdentifierExpansion.resolve("ast", candidates, opts)
    end

    test "respects whitelist (short token stays)" do
      candidates = [{"context", :alias}]
      opts = %{default_opts() | whitelist: MapSet.new([:ctx])}
      assert :skip = IdentifierExpansion.resolve("ctx", candidates, opts)
    end

    test "respects stop_words (short token stays)" do
      candidates = [{"image_signer", :local_def}]
      opts = default_opts()
      assert :skip = IdentifierExpansion.resolve("is", candidates, opts)
    end
  end

  # -------------------------------------------------------------------
  # BUG 1A — Inflection-Symmetrie self-reference
  # -------------------------------------------------------------------

  describe "resolve/3 — Bug 1A: inflection-symmetrische self-reference" do
    test "`op` does not latch to its own enclosing fn `operator_with_placeholders` (plural self)" do
      candidates = [{"operator_with_placeholders", :local_def}]
      opts = %{default_opts() | self: "operator_with_placeholders"}
      assert :skip = IdentifierExpansion.resolve("op", candidates, opts)
    end

    test "`op` does not latch to singularized form of self" do
      candidates = [{"operator_with_placeholder", :local_def}]
      opts = %{default_opts() | self: "operator_with_placeholders"}
      assert :skip = IdentifierExpansion.resolve("op", candidates, opts)
    end

    test "`op` does not latch to pluralized form of self" do
      candidates = [{"operator_with_placeholders", :local_def}]
      opts = %{default_opts() | self: "operator_with_placeholder"}
      assert :skip = IdentifierExpansion.resolve("op", candidates, opts)
    end

    test "exact-match self is rejected" do
      candidates = [{"build", :local_def}]
      opts = %{default_opts() | self: "build"}
      assert :skip = IdentifierExpansion.resolve("b", candidates, opts)
    end
  end

  # -------------------------------------------------------------------
  # BUG 1B — Subtoken-Überlapp mit self, scope-aware
  # -------------------------------------------------------------------

  describe "resolve/3 — Bug 1B: subtoken-overlap with self" do
    test "subtoken overlap with self, in scope_callables → hard reject" do
      # `ap` would latch to `apply`, but `apply` is in Kernel (scope) and
      # `apply_changes` is the enclosing fn. Hard reject.
      candidates = [{"apply_template", :alias}]

      opts = %{
        default_opts()
        | self: "apply_changes",
          scope_callables: MapSet.new(["apply"])
      }

      assert :skip = IdentifierExpansion.resolve("ap", candidates, opts)
    end

    test "subtoken overlap with self, not in scope → -20 penalty, still passes if base high" do
      # `ap ↔ [apply, template]`: 1 initial (`a`), tail `p` lands in
      # `apply`. build_long picks just `apply`. long = `apply`.
      # self = `apply_changes`. Subtokens overlap on `apply`.
      # `apply` NOT in scope_callables → -20 = 80. At threshold.
      candidates = [{"apply_template", :alias}]
      opts = %{default_opts() | self: "apply_changes"}
      assert {:ok, "apply"} = IdentifierExpansion.resolve("ap", candidates, opts)
    end

    test "subtoken overlap with self, not in scope, base too low → :skip" do
      # `r ↔ [renderer]`: 1 initial, tail `enderer` not suffix... wait `r` is
      # 1 char, no tail. starts_hit=1, subtoken_count=1, tail empty → 100.
      # Long = `renderer`. self = `render_template`. Subtokens of long
      # `[renderer]` vs self `[render, template]` — disjoint. No penalty.
      # Should resolve. But 1-char short is too risky; this stays an edge
      # case the standalone-word demotion and stop-words usually cover.
      candidates = [{"renderer", :local_def}]
      opts = %{default_opts() | self: "render_template"}
      # 1-char short against weak source → trust gate kicks in (length < 3).
      assert :skip = IdentifierExpansion.resolve("r", candidates, opts)
    end
  end

  # -------------------------------------------------------------------
  # BUG 2 — cross-token subsequence (ast → asset_preview, id → item_disc...)
  # -------------------------------------------------------------------

  describe "resolve/3 — Bug 2: in-subtoken contribution rule rejects coincidence matches" do
    test "`ast` does NOT latch to `asset_preview` (3 chars in `asset`, contains vowel)" do
      candidates = [{"asset_preview", :local_def}]
      opts = default_opts()
      assert :skip = IdentifierExpansion.resolve("ast", candidates, opts)
    end

    test "`id` does NOT latch to `item_discontinuation` (weak source, 2-char short)" do
      # Weak-source + 2-char-short → trust gate → score 0.
      candidates = [{"infer_with_item_discontinuation", :local_def}]
      opts = default_opts()
      assert :skip = IdentifierExpansion.resolve("id", candidates, opts)
    end

    test "`oz` DOES latch to `organization` heuristically (2 chars in subtoken, generally OK)" do
      # Project-specific blocking (e.g. position-db's `oz` = Ordnungszahl)
      # must use the `known` map or `whitelist` to override.
      candidates = [{"organization", :alias}]
      opts = default_opts()
      assert {:ok, "organization"} = IdentifierExpansion.resolve("oz", candidates, opts)
    end

    test "`oz` can be locked via `known` mapping" do
      candidates = [{"organization", :alias}]
      opts = %{default_opts() | known: %{"oz" => "ordnungszahl"}}
      assert {:ok, "ordnungszahl"} = IdentifierExpansion.resolve("oz", candidates, opts)
    end

    test "`ref` does NOT latch to `reference_building_item_position` (3 chars with vowel)" do
      candidates = [{"reference_building_item_position", :local_def}]
      opts = default_opts()
      assert :skip = IdentifierExpansion.resolve("ref", candidates, opts)
    end

    test "`mngr` DOES latch to `manager` (consonant-only abbreviation)" do
      candidates = [{"manager", :alias}]
      opts = default_opts()
      assert {:ok, "manager"} = IdentifierExpansion.resolve("mngr", candidates, opts)
    end
  end

  # -------------------------------------------------------------------
  # BUG 3 — standalone-word demotion
  # -------------------------------------------------------------------

  describe "resolve/3 — Bug 3: standalone-word demotion via module_subtokens" do
    test "`run` does NOT latch when `run` is a standalone subtoken in the module" do
      candidates = [{"runner", :local_def}]

      opts = %{
        default_opts()
        | module_subtokens: MapSet.new(["run", "poll", "cycle", "schedules"])
      }

      assert :skip = IdentifierExpansion.resolve("run", candidates, opts)
    end

    test "`get` does NOT latch when it appears as standalone subtoken" do
      candidates = [{"getter_callback", :local_def}]
      opts = %{default_opts() | module_subtokens: MapSet.new(["get", "user", "by", "id"])}
      assert :skip = IdentifierExpansion.resolve("get", candidates, opts)
    end

    test "short not in module_subtokens → resolves normally" do
      candidates = [{"changeset", :alias}]
      opts = %{default_opts() | module_subtokens: MapSet.new(["other", "tokens"])}
      assert {:ok, "changeset"} = IdentifierExpansion.resolve("cs", candidates, opts)
    end
  end

  # -------------------------------------------------------------------
  # Mixed scenarios — multiple candidates, scoring picks best
  # -------------------------------------------------------------------

  describe "resolve/3 — multiple candidates" do
    test "picks highest-scoring candidate" do
      candidates = [
        {"build_changeset", :local_def},
        {"changeset", :alias}
      ]

      opts = default_opts()
      result = IdentifierExpansion.resolve("cs", candidates, opts)
      # Either is fine semantically; both should score well. Just no skip.
      assert {:ok, "changeset"} = result
    end

    test "weak source filtered out, strong source wins" do
      candidates = [
        {"item_discontinuation", :local_def},
        {"item_db", :alias}
      ]

      opts = default_opts()
      # `id` 2-char: local_def weak → 0. alias strong → ok.
      # `id ↔ [item, db]`: i-init item, d-init db → 2/2 → 100. Accept.
      assert {:ok, "item_db"} = IdentifierExpansion.resolve("id", candidates, opts)
    end
  end

  # -------------------------------------------------------------------
  # PP-Promotion (past-participle) — used by Params and Bindings
  # -------------------------------------------------------------------

  describe "resolve/3 — PP promotion" do
    test "nk ↔ normalize_keys with PP verbs → normalized_key" do
      candidates = [{"normalize_keys", :enclosing_fn}]
      opts = %{default_opts() | pp_verbs: MapSet.new(["normalize", "validate"])}
      assert {:ok, "normalized_key"} = IdentifierExpansion.resolve("nk", candidates, opts)
    end

    test "without pp_verbs configured → no PP, plain singularization" do
      candidates = [{"normalize_keys", :enclosing_fn}]
      opts = default_opts()
      # `nk ↔ [normalize, keys]`: 2 initials → 100. build_long = normalize_key.
      assert {:ok, "normalize_key"} = IdentifierExpansion.resolve("nk", candidates, opts)
    end

    test "PP verb but last token not plural → no PP" do
      candidates = [{"normalize_key", :enclosing_fn}]
      opts = %{default_opts() | pp_verbs: MapSet.new(["normalize"])}
      # `nk ↔ [normalize, key]`: 2 initials → 100. last `key` not plural,
      # no PP fires. build_long = normalize_key.
      assert {:ok, "normalize_key"} = IdentifierExpansion.resolve("nk", candidates, opts)
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp default_opts do
    %{
      self: nil,
      module_subtokens: MapSet.new(),
      scope_callables: MapSet.new(),
      whitelist: MapSet.new(),
      stop_words: MapSet.new([:do, :if, :is, :in, :it, :for, :and, :or, :not]),
      known: %{},
      pp_verbs: MapSet.new(),
      min_score: 80
    }
  end
end
