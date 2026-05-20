defmodule Number42.Refactors.Ex.ExtractParametricCloneTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractParametricClone

  @subject ExtractParametricClone

  describe "intra-module concentration" do
    test "two clones differing in a single string literal collapse into a helper" do
      source = """
      defmodule MyApp.Time do
        def format_until(t) do
          "until " <> Calendar.strftime(t, "%H:%M")
        end

        def format_ago(t) do
          "ago " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      sources = [{"lib/my_app/time.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)

      rewritten = @subject.transform(source, prepared: plan)

      # The helper body should be present.
      assert rewritten =~ "defp"
      # Both clones' bodies should now be one-line wrappers.
      assert String.contains?(rewritten, "until ")
      assert String.contains?(rewritten, "ago ")
      # The shared concatenation logic should appear exactly once
      # (in the helper, not in either caller).
      occurrences =
        rewritten
        |> String.split("Calendar.strftime")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 1,
             "expected helper to host the only Calendar.strftime call, got #{occurrences} occurrences\n#{rewritten}"
    end
  end

  describe "skip cases" do
    test "single occurrence — nothing to extract" do
      source = """
      defmodule MyApp.Single do
        def only(x), do: "until " <> Calendar.strftime(x, "%H:%M")
      end
      """

      sources = [{"lib/my_app/single.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)

      assert_unchanged(@subject, source, prepared: plan)
    end

    test "below min_mass threshold — skipped" do
      source = """
      defmodule MyApp.Tiny do
        def a, do: 1
        def b, do: 2
      end
      """

      sources = [{"lib/my_app/tiny.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 25)

      assert_unchanged(@subject, source, prepared: plan)
    end
  end

  describe "regression — multiple clone groups in same module" do
    # When two clone groups land in the same module, their helpers must
    # get distinct names (synth_helper_name might pick the same base for
    # both groups). resolve_collision/3 walks `_2`, `_3`, ...

    test "two distinct skeletons hashing to the same synthesised name → suffix" do
      # Both pairs resolve to base name "call_shared" (or similar) but
      # have different skeletons → must produce two helpers, named
      # uniquely.
      source = """
      defmodule MyApp.AST do
        def call_a(x), do: %{type: :a, key: x}
        def call_b(x), do: %{type: :b, key: x}
        def call_c(x, y), do: %{type: :c, left: x, right: y}
        def call_d(x, y), do: %{type: :d, left: x, right: y}
      end
      """

      sources = [{"lib/ast.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 3)
      result = @subject.transform(source, prepared: plan)

      # Each clone group should have its own helper. Collect distinct
      # helper-name occurrences in the rewritten source.
      defp_names =
        Regex.scan(~r/defp\s+(\w+_shared)\(/, result, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()

      assert length(defp_names) >= 2, """
      Expected at least 2 distinct helpers, got #{length(defp_names)}: #{inspect(defp_names)}
      result:
      #{result}
      """
    end
  end

  describe "regression — Sourceror map atom-key formatting" do
    # When rendering a helper body, atom-keyed maps must keep
    # `%{key: val}` syntax (NOT `%{:key => val}`). The :format meta
    # carries that info; we must not strip it before to_string.

    test "atom-keyed map in helper body keeps shorthand syntax" do
      source = """
      defmodule MyApp.Tag do
        def tag_a(x), do: %{type: :alpha, value: x}
        def tag_b(x), do: %{type: :beta, value: x}
      end
      """

      sources = [{"lib/tag.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 3)
      result = @subject.transform(source, prepared: plan)

      # No `:type =>` arrow syntax should leak into the output.
      refute result =~ ":type =>", """
      Helper body uses `%{:type => …}` arrow syntax instead of
      shorthand. Output:
      #{result}
      """
    end
  end

  describe "regression — when-guard clauses skipped" do
    # Heads with `when`-guards can't be extracted naively: the helper
    # would inherit the guard or lose it. v1 simply skips.

    test "two clones whose heads have `when`-guards → not extracted" do
      source = """
      defmodule MyApp.Pred do
        def pred_a(x) when is_atom(x), do: %{type: :a, value: x}
        def pred_b(x) when is_atom(x), do: %{type: :b, value: x}
      end
      """

      sources = [{"lib/pred.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 3)

      assert_unchanged(@subject, source, prepared: plan)
    end
  end

  describe "regression — multi-line body uses do/end (not single-line do:)" do
    # Sourceror renders block bodies as multiple statements separated by
    # newlines. The helper must wrap them in `do … end`, not in a single
    # `, do: …` form.

    test "block body lands in do/end form, not single-line do:" do
      source = """
      defmodule MyApp.Format do
        def format_a(t) do
          x = "alpha"
          x <> Calendar.strftime(t, "%H:%M")
        end

        def format_b(t) do
          x = "beta"
          x <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      sources = [{"lib/format.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)
      result = @subject.transform(source, prepared: plan)

      assert result =~ "defp ", "expected a defp helper to be inserted\n#{result}"

      # The helper itself (which has a multi-statement body) must be in
      # do/end form. Single-line `defp ... do: x = "alpha"\n   x <>` is
      # invalid.
      helper_block =
        result
        |> String.split("\n")
        |> Enum.drop_while(&(not String.starts_with?(String.trim(&1), "defp shared")))
        |> Enum.take(6)
        |> Enum.join("\n")

      refute helper_block =~ ~r/defp shared\w+\([^)]*\),\s*do:/, """
      Multi-line helper body was rendered with single-line `do:`.
      Helper block:
      #{helper_block}
      """
    end
  end

  describe "regression — cross-file clone with :intra winner" do
    # When a clone group has 2 occurrences in module A and 1 in module B,
    # `pick_target` returns `{:intra, A}`. The single occurrence in B
    # must NOT receive a rewrite that calls a non-existent helper —
    # cross-file rewrite would need an `import` plus path-aware emit.
    # First iteration: skip B entirely.

    test "lonely clone in a different module is left alone" do
      source_a = """
      defmodule MyApp.Hub do
        def hub_a(x), do: %{type: :alpha, value: x}
        def hub_b(x), do: %{type: :beta, value: x}
      end
      """

      source_b = """
      defmodule MyApp.Spoke do
        def spoke(x), do: %{type: :gamma, value: x}
      end
      """

      sources = [
        {"lib/hub.ex", source_a},
        {"lib/spoke.ex", source_b}
      ]

      plan = ExtractParametricClone.build_plan(sources, min_mass: 3)

      # Hub: gets a helper + 2 rewrites.
      result_a = @subject.transform(source_a, prepared: plan)
      assert result_a =~ ~r/defp\s+\w+_shared/, "Hub should get a helper"

      # Spoke: must be unchanged — no helper, no rewrite.
      assert_unchanged(@subject, source_b, prepared: plan)
    end
  end

  describe "idempotence" do
    test "running the refactor twice yields the same result" do
      source = """
      defmodule MyApp.Time do
        def format_until(t) do
          "until " <> Calendar.strftime(t, "%H:%M")
        end

        def format_ago(t) do
          "ago " <> Calendar.strftime(t, "%H:%M")
        end
      end
      """

      sources = [{"lib/my_app/time.ex", source}]

      once =
        @subject.transform(source,
          prepared: ExtractParametricClone.build_plan(sources, min_mass: 5)
        )

      sources_2 = [{"lib/my_app/time.ex", once}]

      twice =
        @subject.transform(once,
          prepared: ExtractParametricClone.build_plan(sources_2, min_mass: 5)
        )

      assert_unchanged_strings(once, twice)
    end
  end

  describe "inner-bound variable holes — robustness" do
    # Regression sentinel: clones that bind locals via `with`/`fn`
    # patterns should also be classified inner-bound, not just `case`.

    test "with-pattern-bound vars stay local in helper" do
      source = """
      defmodule MyApp.With do
        def fetch_a(id) do
          with {:ok, user_a} <- lookup(id, :a) do
            transform(user_a)
          end
        end

        def fetch_b(id) do
          with {:ok, user_b} <- lookup(id, :b) do
            transform(user_b)
          end
        end
      end
      """

      sources = [{"lib/my_app/with.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)
      result = @subject.transform(source, prepared: plan)

      assert result =~ "defp", "expected helper to be emitted\n#{result}"

      lines = String.split(result, "\n")
      caller_a = lines |> Enum.find(&String.contains?(&1, "fetch_a(id)"))
      caller_b = lines |> Enum.find(&String.contains?(&1, "fetch_b(id)"))

      assert caller_a, "expected fetch_a caller in output\n#{result}"
      assert caller_b, "expected fetch_b caller in output\n#{result}"

      refute caller_a =~ ~r/(?<!:)\buser_a\b/,
             "fetch_a call-site must not reference inner-bound `user_a`\n#{caller_a}"

      refute caller_b =~ ~r/(?<!:)\buser_b\b/,
             "fetch_b call-site must not reference inner-bound `user_b`\n#{caller_b}"
    end
  end

  describe "inner-bound variable holes" do
    # Regression: aggressive parametrisation broke clones whose
    # divergent-name vars were bound *inside* the body (case/with/fn
    # pattern). Promoting `slug`/`use` to a helper param produces a
    # call-site `helper(changeset, slug)` where `slug` is undefined.
    # The fix: unify the locally-bound var to a uniform name in the
    # helper body — don't promote to a param.

    test "case-pattern-bound divergent vars stay local in helper, not in call-site" do
      source = """
      defmodule MyApp.Norm do
        def normalize_a(changeset) do
          case fetch(changeset, :slug) do
            slug when is_binary(slug) -> store(changeset, :slug, kebab(slug))
            _ -> changeset
          end
        end

        def normalize_b(changeset) do
          case fetch(changeset, :use) do
            use_val when is_binary(use_val) -> store(changeset, :use, kebab(use_val))
            _ -> changeset
          end
        end
      end
      """

      sources = [{"lib/my_app/norm.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)
      result = @subject.transform(source, prepared: plan)

      # Helper must be emitted.
      assert result =~ "defp", "expected helper to be emitted\n#{result}"

      # The two callers must NOT pass the locally-bound `slug` /
      # `use_val` vars at the call-site (those names exist only inside
      # the case-pattern, which the helper now owns). Match each
      # generated def line and check no bare `slug` / `use_val`
      # variable reference appears as a positional arg.
      lines = String.split(result, "\n")
      caller_a = lines |> Enum.find(&String.contains?(&1, "normalize_a(changeset)"))
      caller_b = lines |> Enum.find(&String.contains?(&1, "normalize_b(changeset)"))

      assert caller_a, "expected normalize_a caller in output\n#{result}"
      assert caller_b, "expected normalize_b caller in output\n#{result}"

      # Match a `slug` / `use_val` token *not* preceded by `:` (which
      # would make it an atom literal — those are fine).
      refute caller_a =~ ~r/(?<!:)\bslug\b/,
             "normalize_a call-site must not reference `slug` var\n#{caller_a}"

      refute caller_b =~ ~r/(?<!:)\buse_val\b/,
             "normalize_b call-site must not reference `use_val` var\n#{caller_b}"

      # The atom-key holes (`:slug` vs `:use`) ARE legitimate params —
      # those values exist at the call-site (they're literals).
      assert result =~ ~r/:slug/, "atom-key `:slug` must still appear"
      assert result =~ ~r/:use/, "atom-key `:use` must still appear"
    end
  end

  describe "complex hole parametrisation" do
    test "function-call divergence is parametrised, not rejected" do
      source = """
      defmodule MyApp.Complex do
        def upcase_then_pad(x) do
          x |> String.upcase() |> String.pad_leading(10, " ")
        end

        def downcase_then_pad(x) do
          x |> String.downcase() |> String.pad_leading(10, " ")
        end
      end
      """

      sources = [{"lib/my_app/complex.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)
      result = @subject.transform(source, prepared: plan)

      assert result =~ "defp", "expected helper to be emitted"
      # The two divergent subtrees `String.upcase(x)` / `String.downcase(x)`
      # become a helper parameter — its concrete value is passed at each
      # call-site. (Pipes get inlined before AstDiff, so the literal text
      # is the call form, not the pipe form.)
      assert result =~ "String.upcase(x)"
      assert result =~ "String.downcase(x)"
      # `pad_leading(…, 10, " ")` appears exactly once in the helper body.
      occurrences = result |> String.split("pad_leading") |> length() |> Kernel.-(1)

      assert occurrences == 1,
             "expected pad_leading once in helper, got #{occurrences}\n#{result}"
    end

    test "divergent variable refs are parametrised" do
      source = """
      defmodule MyApp.VarDiff do
        def with_left(x, y) do
          [x, x, x] |> Enum.map(&Integer.to_string/1) |> Enum.join(",")
        end

        def with_right(x, y) do
          [y, y, y] |> Enum.map(&Integer.to_string/1) |> Enum.join(",")
        end
      end
      """

      sources = [{"lib/my_app/var_diff.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)
      result = @subject.transform(source, prepared: plan)

      assert result =~ "defp"
      # Helper takes the divergent value as a param. After pipe-inlining
      # the helper body contains `Enum.join(Enum.map(…, &Integer.to_string/1), ",")`
      # — `Integer.to_string` should appear exactly once.
      occurrences =
        result |> String.split("Integer.to_string") |> length() |> Kernel.-(1)

      assert occurrences == 1
    end

    test "diverging keyword key inside Ecto-style call is parametrised" do
      # Letting the compiler decide: even structural divergences (keyword
      # key) get parametrised. If Ecto.Query rejects at compile time, that
      # is the user's concern — we don't pre-filter.
      source = """
      defmodule MyApp.Queries do
        defp items_select do
          from(i in Item,
            left_join: ip in assoc(i, :item_positions),
            select: i.id
          )
        end

        defp items_order do
          from(i in Item,
            left_join: ip in assoc(i, :item_positions),
            order_by: i.id
          )
        end
      end
      """

      sources = [{"lib/queries.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)
      result = @subject.transform(source, prepared: plan)

      assert result =~ "defp", "expected helper to be emitted (no longer rejected)"
    end

    test "divergent module-attribute refs are parametrised" do
      source = """
      defmodule MyApp.AttrDiff do
        @max 99
        @min 0

        def upper(x) do
          if x > @max, do: @max, else: x + 1
        end

        def lower(x) do
          if x > @min, do: @min, else: x + 1
        end
      end
      """

      sources = [{"lib/my_app/attr_diff.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)
      result = @subject.transform(source, prepared: plan)

      assert result =~ "defp"
      # Both attrs still appear at the call-sites (passed as args).
      assert result =~ "@max"
      assert result =~ "@min"
    end
  end

  describe "pattern-match argument heads" do
    test "two clones with `%Struct{} = var` head are extracted" do
      source = """
      defmodule MyApp.Patterns do
        def label_a(%Scope{} = scope) do
          "until " <> Calendar.strftime(scope.time, "%H:%M")
        end

        def label_b(%Scope{} = scope) do
          "ago " <> Calendar.strftime(scope.time, "%H:%M")
        end
      end
      """

      sources = [{"lib/my_app/patterns.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)

      rewritten = @subject.transform(source, prepared: plan)

      assert rewritten =~ "defp", "expected a private helper to be emitted"

      # Both call-sites must keep their full pattern-match heads
      # so external callers see the same signature.
      assert rewritten =~ "label_a(%Scope{} = scope)"
      assert rewritten =~ "label_b(%Scope{} = scope)"

      # Helper takes the bare var (no pattern-match in helper signature).
      refute rewritten =~ ~r/defp\s+\w+\(%Scope\{\}/,
             "helper signature must not include the pattern, only the bare var"

      # Calendar.strftime appears exactly once (in helper).
      occurrences =
        rewritten |> String.split("Calendar.strftime") |> length() |> Kernel.-(1)

      assert occurrences == 1, "expected one Calendar.strftime, got #{occurrences}\n#{rewritten}"
    end

    test "clones with `%Struct{key: x} = var` head are extracted" do
      source = """
      defmodule MyApp.Patterns2 do
        def a(%Scope{user_id: uid} = scope) do
          "x " <> Calendar.strftime(scope.t, "%H:%M") <> inspect(uid)
        end

        def b(%Scope{user_id: uid} = scope) do
          "y " <> Calendar.strftime(scope.t, "%H:%M") <> inspect(uid)
        end
      end
      """

      sources = [{"lib/my_app/patterns2.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)
      rewritten = @subject.transform(source, prepared: plan)

      assert rewritten =~ "defp", "expected helper"
      assert rewritten =~ "a(%Scope{user_id: uid} = scope)"
      assert rewritten =~ "b(%Scope{user_id: uid} = scope)"
    end

    test "clones with `var = pattern` head (left-bare form) are extracted" do
      source = """
      defmodule MyApp.Patterns3 do
        def a(scope = %Scope{}) do
          "x " <> Calendar.strftime(scope.t, "%H:%M")
        end

        def b(scope = %Scope{}) do
          "y " <> Calendar.strftime(scope.t, "%H:%M")
        end
      end
      """

      sources = [{"lib/my_app/patterns3.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)
      rewritten = @subject.transform(source, prepared: plan)

      assert rewritten =~ "defp"

      occurrences =
        rewritten |> String.split("Calendar.strftime") |> length() |> Kernel.-(1)

      assert occurrences == 1
    end

    test "single occurrence with pattern head — nothing to extract" do
      source = """
      defmodule MyApp.Single2 do
        def only(%Scope{} = scope) do
          "x " <> Calendar.strftime(scope.t, "%H:%M")
        end
      end
      """

      sources = [{"lib/my_app/single2.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)
      assert_unchanged(@subject, source, prepared: plan)
    end

    test "two holes with identical per-clone values collapse into one helper param" do
      # The maybe_normalize_slug / maybe_normalize_use clones bind the
      # same atom (`:slug` / `:use`) at two positions. Without dedup we
      # would emit `helper(changeset, :slug, :slug)` — two params with
      # identical call-site values. Dedup must collapse this into ONE
      # param, so the call-site is `helper(changeset, :slug)`.
      source = """
      defmodule MyApp.DedupHoles do
        defp maybe_normalize_slug(changeset) do
          case get_change(changeset, :slug) do
            slug when is_binary(slug) -> put_change(changeset, :slug, normalize(slug))
            _ -> changeset
          end
        end

        defp maybe_normalize_use(changeset) do
          case get_change(changeset, :use) do
            use when is_binary(use) -> put_change(changeset, :use, normalize(use))
            _ -> changeset
          end
        end

        defp normalize(s), do: String.downcase(s)
      end
      """

      sources = [{"lib/my_app/dedup_holes.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)
      result = @subject.transform(source, prepared: plan)

      # Call sites: helper(changeset, :slug)  — exactly ONE divergent arg, not two.
      # Match a `…_shared(changeset, :slug)` call where the third arg is
      # NOT a comma — i.e. the call has only two args after `(`.
      refute result =~ ~r/\w+_shared\(changeset,\s*:slug\s*,\s*:slug\)/,
             "expected hole-dedup: identical values across clones should collapse to ONE param. Got two:\n#{result}"

      refute result =~ ~r/\w+_shared\(changeset,\s*:use\s*,\s*:use\)/,
             "expected hole-dedup for the :use clone too\n#{result}"

      assert result =~ ~r/\w+_shared\(changeset,\s*:slug\)/,
             "expected `…_shared(changeset, :slug)` call:\n#{result}"

      assert result =~ ~r/\w+_shared\(changeset,\s*:use\)/,
             "expected `…_shared(changeset, :use)` call:\n#{result}"
    end

    test "outer-hole helper params reuse the original variable name from the first clone" do
      # When two clones differ only in which scope-level variable they
      # pass to the inner call, the helper param should be named after
      # that variable in the first clone — not `param_0`.
      source = """
      defmodule MyApp.OuterNames do
        def with_left(x, y) do
          [x, x, x] |> Enum.map(&Integer.to_string/1) |> Enum.join(",")
        end

        def with_right(x, y) do
          [y, y, y] |> Enum.map(&Integer.to_string/1) |> Enum.join(",")
        end
      end
      """

      sources = [{"lib/my_app/outer_names.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)
      result = @subject.transform(source, prepared: plan)

      refute result =~ "param_0",
             "expected helper param to use a real var name from the first clone, not `param_0`:\n#{result}"
    end

    test "inner-bound helper locals reuse the original variable name from the first clone" do
      # The case-pattern var that all clones bind to the same name (`hit`)
      # — the helper should use `hit` inside its body, not `local_0`.
      source = """
      defmodule MyApp.InnerNames do
        def left(items) do
          case Enum.find(items, &match?({:left, _}, &1)) do
            {:left, hit} -> {:ok, hit}
            nil -> :error
          end
        end

        def right(items) do
          case Enum.find(items, &match?({:right, _}, &1)) do
            {:right, hit} -> {:ok, hit}
            nil -> :error
          end
        end
      end
      """

      sources = [{"lib/my_app/inner_names.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)
      result = @subject.transform(source, prepared: plan)

      refute result =~ "local_0",
             "expected helper to keep the original `hit` name from the first clone, not `local_0`:\n#{result}"
    end

    test "pipe-RHS function call gets parametrised — emitted helper must compile" do
      # The hazard: when the divergent piece sits at the RHS of `|>`,
      # naive emission turns the pipe into `param_0 |> param_1` where
      # `param_1` is a bare var the compiler rejects (pipe RHS must be
      # a function call, not a var).
      source = """
      defmodule MyApp.PipeRhs do
        alias MyApp.Building
        alias MyApp.BuildingItem

        def update_building(scope, building, attrs) do
          case building
               |> Building.changeset(attrs, scope)
               |> Repo.update() do
            {:ok, b} -> {:ok, b}
            {:error, cs} -> {:error, cs}
          end
        end

        def update_building_item(scope, building_item, attrs) do
          case building_item
               |> BuildingItem.changeset(attrs, scope)
               |> Repo.update() do
            {:ok, b} -> {:ok, b}
            {:error, cs} -> {:error, cs}
          end
        end
      end
      """

      sources = [{"lib/my_app/pipe_rhs.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)
      rewritten = @subject.transform(source, prepared: plan)

      # The output must be syntactically valid Elixir — Code.string_to_quoted!
      # raises if the helper body contains `param_X |> param_Y` (bare var on RHS).
      assert {:ok, _} = Code.string_to_quoted(rewritten),
             "rewritten code is not valid Elixir:\n#{rewritten}"

      # And the helper body must NOT contain `... |> param_<N>` — that
      # is the precise compile-error pattern the bug produces.
      refute rewritten =~ ~r/\|>\s+param_\d/,
             "helper body has a bare param on pipe RHS:\n#{rewritten}"
    end

    test "Ecto.from clauses are skipped — bind-vars and keyword keys cannot be parametrised" do
      # The hazard: `from(bind in Schema, ...)` puts the bind name on
      # the LHS of `in` (compile-time atom only) and uses keyword keys
      # the macro needs at compile time. Parametrising any of those
      # produces an AST the formatter / Ecto reject. The whole clause
      # must be skipped, not partially extracted.
      source = """
      defmodule MyApp.WithFromClauses do
        defp brand_items_query do
          from(bi in BrandItem,
            join: b in assoc(bi, :brand),
            order_by: bi.id
          )
        end

        defp brand_discontinuations_query do
          from(bd in BrandDiscontinuation,
            join: b in assoc(bd, :brand),
            order_by: bd.id
          )
        end
      end
      """

      sources = [{"lib/my_app/with_from_clauses.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)

      # Skip means: nothing changes, no helper emitted.
      assert_unchanged(@subject, source, prepared: plan)
    end

    test "default-arg syntax is still rejected even alongside pattern-head support" do
      source = """
      defmodule MyApp.Defaults do
        def a(x \\\\ 1) do
          "x " <> Calendar.strftime(x, "%H:%M")
        end

        def b(x \\\\ 1) do
          "y " <> Calendar.strftime(x, "%H:%M")
        end
      end
      """

      sources = [{"lib/my_app/defaults.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 5)
      assert_unchanged(@subject, source, prepared: plan)
    end
  end

  defp assert_unchanged_strings(a, b) do
    sa = a |> String.replace(~r/\s+/, " ") |> String.trim()
    sb = b |> String.replace(~r/\s+/, " ") |> String.trim()

    assert sa == sb, """
    Expected idempotence, got divergent output.

    --- first pass ---
    #{a}
    --- second pass ---
    #{b}
    """
  end

  describe "regression — Shared module imports must not be unused" do
    # Real-world bug from the Phase-4 smoke run: source modules carry
    # `import MyAppWeb.CoreComponents` (a wide macro import they
    # need for HEEx templates). When ParametricClone extracts a clone
    # that does NOT call any function from `CoreComponents`, the import
    # is still copied into the freshly written `*.Shared` module —
    # producing `unused import` warnings (which break `--warnings-as-errors`
    # builds).
    #
    # The Shared module body should only carry imports that the migrated
    # body actually needs.
    test "drops imports from Shared that the migrated body does not reference" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "extract_parametric_unused_import_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      a = """
      defmodule MyApp.Components.A do
        import MyAppWeb.CoreComponents

        def cuboid_color(item) do
          case item.color do
            nil ->
              "#808080"

            color_str ->
              color_atom = String.to_existing_atom(color_str)

              case MyApp.ItemTypes.ColorPalette.get(color_atom) do
                %{hex: hex} -> hex
                _ -> "#808080"
              end
          end
        end
      end
      """

      b = """
      defmodule MyApp.Components.B do
        import MyAppWeb.CoreComponents

        def cuboid_color(item) do
          case item.color do
            nil ->
              "#808080"

            color_str ->
              color_atom = String.to_existing_atom(color_str)

              case MyApp.ItemTypes.ColorPalette.get(color_atom) do
                %{hex: hex} -> hex
                _ -> "#808080"
              end
          end
        end
      end
      """

      sources = [
        {"lib/my_app/components/a.ex", a},
        {"lib/my_app/components/b.ex", b}
      ]

      _plan = ExtractParametricClone.build_plan(sources, min_mass: 5, write_root: tmp)

      shared_path = Path.join(tmp, "lib/my_app/components/shared.ex")
      assert File.exists?(shared_path), "shared module should have been written"

      shared_source = File.read!(shared_path)

      refute shared_source =~ ~r/^\s*import\s+MyAppWeb\.CoreComponents\s*$/m, """
      shared module carries an unused `import MyAppWeb.CoreComponents`
      (the migrated body never calls a CoreComponents function). The
      stray import becomes an `unused import` warning under
      `--warnings-as-errors`.

      shared:
      #{shared_source}
      """
    end
  end

  describe "regression — map-keys are not parametrisable holes" do
    # Real-world bug from xml_importer.ex: two `defp build_*` helpers
    # that both build a small attribute-map but with different keys
    # (`%{id: …, name: a["name"], logo_asset_id: a["logo-asset-id"]}`
    # vs `%{id: …, mass_id: a["mass-id"], asset_id: a["asset-id"]}`)
    # were collapsed into a single helper parametrised over the map
    # keys themselves — producing
    # `build_brand_shared(a, :mass_id, "mass-id", :asset_id, "asset-id")`.
    # The "shared" name carries the loser's domain (Brand) into a body
    # that's now also called for mass-assets, and the parameter names
    # (`name`, `logo_asset_id`) actively mislead readers about the
    # callsite's semantics.
    #
    # Map keys (atoms on the LHS of `:` / `=>`) are almost always
    # semantically load-bearing. Parametrising over them is a category
    # error — refuse the consolidation.
    test "two helpers that only differ in map-keys are NOT consolidated" do
      source = """
      defmodule MyApp.Importer do
        defp build_brand(a) do
          %{id: a["id"], name: a["name"], logo_asset_id: a["logo-asset-id"]}
        end

        defp build_mass_asset(a) do
          %{id: a["id"], mass_id: a["mass-id"], asset_id: a["asset-id"]}
        end
      end
      """

      sources = [{"lib/my_app/importer.ex", source}]
      plan = ExtractParametricClone.build_plan(sources, min_mass: 3)

      rewritten = @subject.transform(source, prepared: plan)

      # Both helpers must keep their original bodies — no wrapping into
      # a parametrised `build_*_shared/N` that takes the map keys as
      # arguments.
      assert rewritten =~ ~r/defp build_brand\(a\) do\s+%\{id: a\["id"\], name:/, """
      `build_brand/1` was rewritten — but its only "clone" is
      `build_mass_asset/1`, which differs only in the *map keys*. The
      consolidation produces semantically misleading code. Result:
      #{rewritten}
      """

      assert rewritten =~ ~r/defp build_mass_asset\(a\) do\s+%\{id: a\["id"\], mass_id:/, """
      `build_mass_asset/1` was rewritten by parametric consolidation
      with `build_brand/1`. Map-keys (`:name`/`:mass_id`,
      `:logo_asset_id`/`:asset_id`) are semantically load-bearing and
      must not be parametrised. Result:
      #{rewritten}
      """

      # And no `_shared` helper should have been synthesised for this
      # consolidation.
      refute rewritten =~ ~r/build_brand_shared\(/, """
      a `build_brand_shared/N` helper was synthesised — the refactor
      collapsed two semantically distinct functions. Result:
      #{rewritten}
      """
    end
  end
end
