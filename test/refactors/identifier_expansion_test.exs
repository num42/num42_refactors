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

    test "verb-shaped head fires PP even without pp_verbs config (normalize ends in -ize)" do
      candidates = [{"normalize_keys", :enclosing_fn}]
      opts = default_opts()
      # `normalize` has a verb-shaped suffix (-ize), so PP fires
      # automatically. AstHelpers.maybe_past_participle/4 covers this.
      assert {:ok, "normalized_key"} = IdentifierExpansion.resolve("nk", candidates, opts)
    end

    test "non-verb-shaped head without pp_verbs → no PP, plain singularization" do
      candidates = [{"fetch_changesets", :rhs_call}]
      opts = default_opts()
      # `fetch` doesn't have a verb-shaped suffix → no PP.
      assert {:ok, "changeset"} = IdentifierExpansion.resolve("cs", candidates, opts)
    end

    test "merge ends in `e` and is in pp_verbs → PP fires" do
      candidates = [{"merge_changesets", :rhs_call}]
      opts = %{default_opts() | pp_verbs: MapSet.new(["merge"])}
      assert {:ok, "merged_changeset"} = IdentifierExpansion.resolve("cs", candidates, opts)
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
  # negate/1, negate/2 — antonym derivation
  # -------------------------------------------------------------------

  describe "negate/1 — built-in antonym map" do
    test "valid → invalid" do
      assert "invalid" = IdentifierExpansion.negate("valid")
    end

    test "authorized → unauthorized" do
      assert "unauthorized" = IdentifierExpansion.negate("authorized")
    end

    test "enabled → disabled" do
      assert "disabled" = IdentifierExpansion.negate("enabled")
    end

    test "present → absent" do
      assert "absent" = IdentifierExpansion.negate("present")
    end

    test "map is bidirectional: invalid → valid" do
      assert "valid" = IdentifierExpansion.negate("invalid")
    end

    test "map is bidirectional: disabled → enabled" do
      assert "enabled" = IdentifierExpansion.negate("disabled")
    end

    test "map is bidirectional: absent → present" do
      assert "present" = IdentifierExpansion.negate("absent")
    end
  end

  describe "negate/1 — morphological prefix rules" do
    test "not_x strips to x (involutive)" do
      assert "found" = IdentifierExpansion.negate("not_found")
    end

    test "x gains not_ when no map/other rule fires" do
      # `found` is not in the map and has no strippable prefix →
      # the not_-rule is the round-trip partner of not_found → found.
      assert "not_found" = IdentifierExpansion.negate("found")
    end

    test "un-prefix strips: unlocked → locked" do
      assert "locked" = IdentifierExpansion.negate("unlocked")
    end

    test "dis-prefix strips: disconnected → connected" do
      assert "connected" = IdentifierExpansion.negate("disconnected")
    end
  end

  describe "negate/1 — is_/has_ predicate handling" do
    test "is_valid → is_invalid (negates the predicate stem, keeps is_)" do
      assert "is_invalid" = IdentifierExpansion.negate("is_valid")
    end

    test "has_value → has_no_value" do
      assert "has_no_value" = IdentifierExpansion.negate("has_value")
    end
  end

  describe "negate/1 — fallback" do
    test "unknown word gains un_ prefix" do
      assert "un_frobnicate" = IdentifierExpansion.negate("frobnicate")
    end
  end

  describe "negate/2 — .refactor.exs override" do
    test "opts[:known] override beats built-in map" do
      opts = %{known: %{"valid" => "bogus"}}
      assert "bogus" = IdentifierExpansion.negate("valid", opts)
    end

    test "falls through to built-in when key absent from override" do
      opts = %{known: %{"other" => "x"}}
      assert "invalid" = IdentifierExpansion.negate("valid", opts)
    end
  end

  # -------------------------------------------------------------------
  # synth_compound_name/4 — mechanical fragment merge (moved from AstHelpers)
  # -------------------------------------------------------------------

  describe "synth_compound_name/4" do
    test "joins all four parts with underscores" do
      assert "handle_mount_load_impl" =
               IdentifierExpansion.synth_compound_name("handle", "mount", "load", "impl")
    end

    test "host alone with scrutinee single-token" do
      assert "host_fetch" = IdentifierExpansion.synth_compound_name("", "host", "fetch", "")
    end

    test "drops host when scrutinee has 2+ subtokens" do
      assert "fetch_user_by_id" =
               IdentifierExpansion.synth_compound_name("", "host", "fetch_user_by_id", "")
    end

    test "drops host when scrutinee 2+ but keeps prefix" do
      assert "handle_fetch_user_by_id" =
               IdentifierExpansion.synth_compound_name("handle", "host", "fetch_user_by_id", "")
    end

    test "overlap merge at prefix-host boundary" do
      assert "handle_request_fetch" =
               IdentifierExpansion.synth_compound_name("handle", "handle_request", "fetch", "")
    end

    test "overlap merge at host-scrutinee boundary (single-token scrutinee keeps host)" do
      # scrutinee = single token "load" → host kept; tail of host overlaps scrut head
      assert "host_load" =
               IdentifierExpansion.synth_compound_name("", "host_load", "load", "")
    end

    test "overlap merge at body-suffix boundary" do
      assert "handle_request" =
               IdentifierExpansion.synth_compound_name("handle", "request", "request", "")
    end

    test "[a,b,c] + [b,c,d] = [a,b,c,d]" do
      assert "a_b_c_d" = IdentifierExpansion.synth_compound_name("a_b_c", "b_c_d", "", "")
    end

    test "[a] + [a] = [a]" do
      assert "a" = IdentifierExpansion.synth_compound_name("a", "a", "", "")
    end

    test "[a,b] + [c,d] = [a,b,c,d] (no overlap)" do
      assert "a_b_c_d" = IdentifierExpansion.synth_compound_name("a_b", "c_d", "", "")
    end

    test "empty parts collapse cleanly (no leading/trailing underscores)" do
      assert "host_fetch" = IdentifierExpansion.synth_compound_name("", "host", "fetch", "")
      assert "host_fetch" = IdentifierExpansion.synth_compound_name(nil, "host", "fetch", nil)
    end

    test "all empty -> empty string" do
      assert "" = IdentifierExpansion.synth_compound_name("", "", "", "")
    end

    test "atoms accepted as well as strings" do
      assert "handle_mount_load" =
               IdentifierExpansion.synth_compound_name(:handle, :mount, :load, "")
    end

    test "scrutinee 2+ and prefix overlaps scrutinee head" do
      # prefix=[handle], host=[anything], scrut=[handle, request, fetch]
      # → host dropped, prefix merges with scrut head
      assert "handle_request_fetch" =
               IdentifierExpansion.synth_compound_name(
                 "handle",
                 "anything",
                 "handle_request_fetch",
                 ""
               )
    end

    test "suffix overlaps end of body" do
      # body ends with "fetch", suffix starts with "fetch" → only one
      assert "host_fetch_impl" =
               IdentifierExpansion.synth_compound_name("", "host", "fetch", "fetch_impl")
    end
  end

  # -------------------------------------------------------------------
  # generate_function_name/3 — semantic naming entry point
  # -------------------------------------------------------------------

  describe "generate_function_name/3 — call-derived (no family)" do
    test "operation + multi-token noun drops host" do
      assert "handle_fetch_user_by_id" =
               IdentifierExpansion.generate_function_name("handle", "fetch_user_by_id")
    end

    test "single-token noun keeps host from opts" do
      assert "handle_host_fetch" =
               IdentifierExpansion.generate_function_name("handle", "fetch", %{host: "host"})
    end

    test "empty noun falls back to operation + host" do
      assert "extracted_render_row" =
               IdentifierExpansion.generate_function_name("extracted", "", %{host: "render_row"})
    end

    test "strips ?/! markers off inputs" do
      assert "handle_host_valid" =
               IdentifierExpansion.generate_function_name("handle", "valid?", %{host: "host"})
    end
  end

  describe "generate_function_name/3 — pattern-derived (result family)" do
    test "result-family clauses yield on_<noun>_result, dropping operation" do
      clauses = [
        {:->, [], [[{:__block__, [], [{:ok, {:value, [], nil}}]}], {:value, [], nil}]},
        {:->, [], [[{:__block__, [], [:error]}], {:default, [], nil}]}
      ]

      assert "on_fetch_result" =
               IdentifierExpansion.generate_function_name("handle", "fetch", %{
                 host: "host",
                 clauses: clauses
               })
    end
  end

  # -------------------------------------------------------------------
  # pattern_family_suffix/1 — clause-family recognition
  # -------------------------------------------------------------------

  describe "pattern_family_suffix/1" do
    test "empty clause list → nil" do
      assert nil == IdentifierExpansion.pattern_family_suffix([])
    end

    test "all :ok/:error clauses (one tagged) → result" do
      clauses = [
        {:->, [], [[{:__block__, [], [{:ok, {:v, [], nil}}]}], {:v, [], nil}]},
        {:->, [], [[{:__block__, [], [:error]}], {:d, [], nil}]}
      ]

      assert "result" = IdentifierExpansion.pattern_family_suffix(clauses)
    end

    test "non-result clauses → nil" do
      clauses = [
        {:->, [], [[{:__block__, [], [:other]}], {:v, [], nil}]}
      ]

      assert nil == IdentifierExpansion.pattern_family_suffix(clauses)
    end
  end

  # -------------------------------------------------------------------
  # derive_constant_name/2 — names for hoisted constants
  # -------------------------------------------------------------------

  describe "derive_constant_name/2 — key-derived (config strings)" do
    test "uses opts[:key] as the constant name" do
      assert "base_url" =
               IdentifierExpansion.derive_constant_name("https://api.example.com", %{
                 key: "base_url"
               })
    end

    test "key as atom is accepted" do
      assert "timeout" =
               IdentifierExpansion.derive_constant_name(5000, %{key: :timeout})
    end

    test "strips ?/! marker off the key" do
      assert "enabled" =
               IdentifierExpansion.derive_constant_name(true, %{key: "enabled?"})
    end

    test "a key with no letters is rejected, not emitted raw" do
      # A bare `:` or all-punctuation key would yield an uncompilable
      # `@:_parts` / `@%%%`. With nothing to sanitize into a stem, the
      # value falls through to a valid name.
      assert "int_4" = IdentifierExpansion.derive_constant_name(4, %{key: ":"})
      assert "int_4" = IdentifierExpansion.derive_constant_name(4, %{key: "%%%"})
    end

    test "a sanitizable key is normalized to a valid stem" do
      assert "weird_name" = IdentifierExpansion.derive_constant_name(4, %{key: "weird-name"})
      assert "foo_bar" = IdentifierExpansion.derive_constant_name(4, %{key: ":foo bar"})
    end
  end

  describe "derive_constant_name/2 — well-known math values" do
    test "pi" do
      assert "pi" = IdentifierExpansion.derive_constant_name(3.141592653589793, %{})
    end

    test "e (Euler)" do
      assert "e" = IdentifierExpansion.derive_constant_name(2.718281828459045, %{})
    end
  end

  describe "derive_constant_name/2 — type-based fallback" do
    test "url-shaped string → content-derived name from host + path" do
      assert "example_url" =
               IdentifierExpansion.derive_constant_name("https://example.com", %{})

      assert "api_example_v1_url" =
               IdentifierExpansion.derive_constant_name("https://api.example.com/v1", %{})
    end

    test "absolute path → content-derived name from segments" do
      assert "etc_myapp_config_toml_path" =
               IdentifierExpansion.derive_constant_name("/etc/myapp/config.toml", %{})
    end

    test "url with nothing nameable → default_url" do
      assert "default_url" =
               IdentifierExpansion.derive_constant_name("https://127.0.0.1", %{})
    end

    test "plain string → default_string" do
      assert "default_string" =
               IdentifierExpansion.derive_constant_name("hello", %{})
    end

    test "float → default_float" do
      assert "default_float" = IdentifierExpansion.derive_constant_name(0.5, %{})
    end
  end

  describe "derive_constant_name/2 — universal well-known integers (Bug 3)" do
    test "1024 → kibi" do
      assert "kibi" = IdentifierExpansion.derive_constant_name(1024, %{})
    end

    test "255 → max_byte" do
      assert "max_byte" = IdentifierExpansion.derive_constant_name(255, %{})
    end

    test "65535 → max_word" do
      assert "max_word" = IdentifierExpansion.derive_constant_name(65_535, %{})
    end

    test "360 → degrees_full" do
      assert "degrees_full" = IdentifierExpansion.derive_constant_name(360, %{})
    end
  end

  # A temporal/relative signal in the surrounding context (one that is
  # NOT itself a recognized `@context_stems` entry, so it does not win as
  # a name on its own) licenses the contextual well-known names. A key
  # always wins outright (it *is* the name), so these gate-tests use a
  # bare temporal-flavoured `context`.
  describe "derive_constant_name/2 — contextual well-known integers need a temporal signal" do
    test "1000 → kilo under a temporal context" do
      assert "kilo" = IdentifierExpansion.derive_constant_name(1000, %{context: "sleep_duration"})
    end

    test "60 → seconds_per_minute under a temporal context" do
      assert "seconds_per_minute" =
               IdentifierExpansion.derive_constant_name(60, %{context: "sleep_duration"})
    end

    test "3600 → seconds_per_hour under a temporal context" do
      assert "seconds_per_hour" =
               IdentifierExpansion.derive_constant_name(3600, %{context: "expiry"})
    end

    test "86400 → seconds_per_day under a temporal context" do
      assert "seconds_per_day" =
               IdentifierExpansion.derive_constant_name(86_400, %{context: "cookie_age"})
    end

    test "100 → percent under a relative context" do
      assert "percent" = IdentifierExpansion.derive_constant_name(100, %{context: "share_pct"})
    end
  end

  describe "derive_constant_name/2 — millisecond multiples need a temporal signal (Bug 3)" do
    test "5000 → timeout_5s_ms under a temporal context" do
      assert "timeout_5s_ms" =
               IdentifierExpansion.derive_constant_name(5000, %{context: "sleep_duration"})
    end

    test "30000 → timeout_30s_ms under a temporal context" do
      assert "timeout_30s_ms" =
               IdentifierExpansion.derive_constant_name(30_000, %{context: "sleep_duration"})
    end
  end

  describe "derive_constant_name/2 — value-in-name fallback (Bug 3)" do
    test "an arbitrary integer encodes its value, not magic_number" do
      assert "int_42" = IdentifierExpansion.derive_constant_name(42, %{})
    end

    test "negative integers stay valid identifiers" do
      assert "int_neg_7" = IdentifierExpansion.derive_constant_name(-7, %{})
    end
  end

  describe "derive_constant_name/2 — call-context axis (Aufgabe 4)" do
    test "slice/length call names a max-length constant" do
      assert "max_slice" =
               IdentifierExpansion.derive_constant_name(200, %{context: "slice"})
    end

    test "key still beats context" do
      assert "limit" =
               IdentifierExpansion.derive_constant_name(200, %{key: "limit", context: "slice"})
    end

    test "context falls back to value when it derives nothing useful" do
      assert "int_200" =
               IdentifierExpansion.derive_constant_name(200, %{context: "foo"})
    end
  end

  describe "derive_constant_name/2 — key beats well-known value" do
    test "explicit key wins over pi-recognition" do
      assert "ratio" =
               IdentifierExpansion.derive_constant_name(3.141592653589793, %{key: "ratio"})
    end
  end

  describe "derive_constant_name/2 — clause-head axis" do
    test "function name + string pattern names the constant" do
      assert "image_width_md" =
               IdentifierExpansion.derive_constant_name(80, %{
                 clause: {"image_width", "md"}
               })
    end

    test "function name + atom pattern names the constant" do
      assert "icon_size_large" =
               IdentifierExpansion.derive_constant_name(96, %{
                 clause: {"icon_size", :large}
               })
    end

    test "clause beats well-known value (60 is not always seconds_per_minute)" do
      assert "grid_columns_wide" =
               IdentifierExpansion.derive_constant_name(60, %{
                 clause: {"grid_columns", "wide"}
               })
    end

    test "key still beats clause" do
      assert "limit" =
               IdentifierExpansion.derive_constant_name(80, %{
                 key: "limit",
                 clause: {"image_width", "md"}
               })
    end

    test "clause beats call-context" do
      assert "image_width_md" =
               IdentifierExpansion.derive_constant_name(80, %{
                 context: "slice",
                 clause: {"image_width", "md"}
               })
    end

    test "non-identifier pattern is sanitized to a valid stem" do
      assert "padding_2xl" =
               IdentifierExpansion.derive_constant_name(80, %{
                 clause: {"padding", "2xl"}
               })
    end

    test "numeric pattern falls back to the function name alone" do
      assert "level_color" =
               IdentifierExpansion.derive_constant_name(80, %{
                 clause: {"level_color", 3}
               })
    end
  end

  describe "derive_constant_name/2 — context-dependent well-known gating" do
    test "60 without a temporal signal is not seconds_per_minute" do
      assert "int_60" = IdentifierExpansion.derive_constant_name(60, %{})
    end

    test "60 with a temporal context is seconds_per_minute" do
      assert "seconds_per_minute" =
               IdentifierExpansion.derive_constant_name(60, %{context: "sleep_duration"})
    end

    test "100 without a relative signal is not percent" do
      assert "int_100" = IdentifierExpansion.derive_constant_name(100, %{})
    end

    test "100 under a percent-ish context is percent" do
      assert "percent" =
               IdentifierExpansion.derive_constant_name(100, %{context: "share_pct"})
    end

    test "3600 without a temporal signal stays a value name" do
      assert "int_3600" = IdentifierExpansion.derive_constant_name(3600, %{})
    end

    test "3600 with a temporal context is seconds_per_hour" do
      assert "seconds_per_hour" =
               IdentifierExpansion.derive_constant_name(3600, %{context: "expiry"})
    end

    test "a millimeter max(2000) is not a millisecond timeout" do
      assert "int_2000" =
               IdentifierExpansion.derive_constant_name(2000, %{context: "max"})
    end

    test "2000 under a temporal context is a millisecond timeout" do
      assert "timeout_2s_ms" =
               IdentifierExpansion.derive_constant_name(2000, %{context: "sleep_duration"})
    end

    test "universally-unambiguous well-known values still fire without a signal" do
      assert "kibi" = IdentifierExpansion.derive_constant_name(1024, %{})
      assert "max_byte" = IdentifierExpansion.derive_constant_name(255, %{})
      assert "degrees_full" = IdentifierExpansion.derive_constant_name(360, %{})
      assert "max_word" = IdentifierExpansion.derive_constant_name(65_535, %{})
    end

    test "clause pattern counts as the naming signal but not as a temporal one" do
      assert "image_width_md" =
               IdentifierExpansion.derive_constant_name(60, %{clause: {"image_width", "md"}})
    end
  end

  describe "nameable?/2 — value-only fallback detection" do
    test "a value-only int fallback is not meaningful" do
      refute IdentifierExpansion.nameable?(42, %{})
    end

    test "a negative value-only int fallback is not meaningful" do
      refute IdentifierExpansion.nameable?(-7, %{})
    end

    test "default_float fallback is not meaningful" do
      refute IdentifierExpansion.nameable?(0.123_45, %{})
    end

    test "default_string fallback is not meaningful" do
      refute IdentifierExpansion.nameable?("hello", %{})
    end

    test "a key-derived name is meaningful" do
      assert IdentifierExpansion.nameable?(42, %{key: "limit"})
    end

    test "a clause-derived name is meaningful" do
      assert IdentifierExpansion.nameable?(42, %{clause: {"image_width", "md"}})
    end

    test "a universal well-known integer is meaningful without a signal" do
      assert IdentifierExpansion.nameable?(1024, %{})
    end

    test "a contextual well-known integer is meaningful only with a temporal signal" do
      refute IdentifierExpansion.nameable?(3600, %{})
      assert IdentifierExpansion.nameable?(3600, %{context: "expiry"})
    end

    test "a content-derived url is meaningful" do
      assert IdentifierExpansion.nameable?("https://api.example.com/v1", %{})
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
