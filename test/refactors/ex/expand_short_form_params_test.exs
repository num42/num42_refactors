defmodule Number42.Refactors.Ex.ExpandShortFormParamsTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Engine
  alias Number42.Refactors.Ex.ExpandShortFormParams

  @subject ExpandShortFormParams

  @pp_verbs ~w(normalize validate parse merge update create)

  describe "known mapping (from opts)" do
    test "explicit known mapping wins over heuristics" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(org_id) do
            do_thing(org_id)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(organization_id) do
            do_thing(organization_id)
          end
        end
        ''',
        known: %{"org_id" => "organization_id"}
      )
    end

    test "without opts[:known], unmapped name with no other signal stays put" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(xyz) do
          do_thing(xyz)
        end
      end
      ''')
    end
  end

  describe "alias-based resolution" do
    test "param resolves via module alias (cs ↔ Ecto.Changeset)" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          alias Ecto.Changeset

          def go(cs) do
            Changeset.apply_changes(cs)
          end
        end
        ''',
        ~S'''
        defmodule M do
          alias Ecto.Changeset

          def go(changeset) do
            Changeset.apply_changes(changeset)
          end
        end
        '''
      )
    end

    test "param resolves via multi-subtoken alias (fb ↔ FormulaBuilder)" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          alias MyApp.FormulaBuilder

          def go(fb) do
            FormulaBuilder.render(fb)
          end
        end
        ''',
        ~S'''
        defmodule M do
          alias MyApp.FormulaBuilder

          def go(formula_builder) do
            FormulaBuilder.render(formula_builder)
          end
        end
        '''
      )
    end
  end

  describe "module-name compound resolution" do
    test "param resolves via enclosing module compound" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule MyApp.FormulaBuilder do
          def render(fb, assigns) do
            wrap(fb, assigns)
          end
        end
        ''',
        ~S'''
        defmodule MyApp.FormulaBuilder do
          def render(formula_builder, assigns) do
            wrap(formula_builder, assigns)
          end
        end
        '''
      )
    end
  end

  describe "struct-pattern resolution" do
    test "%Changeset{} = cs is a strong signal -> changeset" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(%Ecto.Changeset{} = cs) do
            persist(cs)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(%Ecto.Changeset{} = changeset) do
            persist(changeset)
          end
        end
        '''
      )
    end
  end

  describe "plural -s rule" do
    test "trailing s → resolve singular form, then pluralize result" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          alias MyApp.FormulaBuilder

          def go(fbs) do
            Enum.each(fbs, &FormulaBuilder.render/1)
          end
        end
        ''',
        ~S'''
        defmodule M do
          alias MyApp.FormulaBuilder

          def go(formula_builders) do
            Enum.each(formula_builders, &FormulaBuilder.render/1)
          end
        end
        '''
      )
    end

    test "single-letter-with-s does NOT trigger plural rule (no real signal)" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(xs) do
          Enum.each(xs, &do_thing/1)
        end
      end
      ''')
    end
  end

  describe "function-name compound resolution" do
    test "param resolves via enclosing function name" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def render_formula_builder(fb) do
            wrap(fb)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def render_formula_builder(formula_builder) do
            wrap(formula_builder)
          end
        end
        '''
      )
    end
  end

  describe "skip conditions" do
    test "multi-clause function is left alone" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        alias Ecto.Changeset

        def go(nil), do: :empty
        def go(cs), do: Changeset.apply_changes(cs)
      end
      ''')
    end

    test "underscore-prefixed param is left alone" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        alias Ecto.Changeset

        def go(_cs) do
          :ok
        end
      end
      ''')
    end

    test "whitelisted short like `idx` is not renamed" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(idx, list) do
          Enum.at(list, idx)
        end
      end
      ''')
    end

    test "long-form already used as another param -> skip" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        alias Ecto.Changeset

        def go(cs, changeset) do
          merge(cs, changeset)
        end
      end
      ''')
    end

    test "long-form already used as a body binding -> skip" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        alias Ecto.Changeset

        def go(cs) do
          changeset = something()
          merge(cs, changeset)
        end
      end
      ''')
    end

    test "no signal anywhere -> skip" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(zq) do
          do_thing(zq)
        end
      end
      ''')
    end

    test "HEEx body references the renamed param — sigil is patched too" do
      # Without textual sigil-patching, the AST walker renames `dep`
      # to `dependency` in the function head and any AST refs, but
      # the `{dep.value}` reference inside the `~H` sigil stays
      # behind — produces non-compiling code. Mirrors the same fix
      # ExpandShortFormFunctions ships for HEEx renames.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          use Phoenix.Component

          def render(dep) do
            ~H"<span>{dep.value}</span>"
          end
        end
        ''',
        ~S'''
        defmodule M do
          use Phoenix.Component

          def render(dependency) do
            ~H"<span>{dependency.value}</span>"
          end
        end
        ''',
        known: %{"dep" => "dependency"}
      )
    end
  end

  describe "engine: skip_in_modules" do
    test "engine bails out when source defines a skipped module" do
      source = ~S'''
      defmodule MyApp.Color do
        def to_hex(c) do
          format(c)
        end
      end
      '''

      result =
        Engine.apply_one(
          @subject,
          source,
          configured_modules: [{@subject, skip_in_modules: [MyApp.Color]}]
        )

      assert result == source
    end
  end

  describe "configurable whitelist (opts[:whitelist])" do
    test "extra whitelist entry is honoured on top of defaults" do
      # `oz` is NOT in the default whitelist (it's project-specific).
      # Without the opt, `oz` would be considered short and the resolver
      # could match it against the alias compound. With the opt, it's
      # skipped entirely.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          alias MyApp.Positions.Position

          def go(oz) do
            Position.classify(oz)
          end
        end
        ''',
        whitelist: [:oz]
      )
    end

    test "string entries in opts[:whitelist] are accepted" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          alias MyApp.Positions.Position

          def go(oz) do
            Position.classify(oz)
          end
        end
        ''',
        whitelist: ["oz"]
      )
    end
  end

  describe "schema-field protection (via prepare/1)" do
    test "param matching a known schema field is left alone" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          alias Ecto.Changeset

          def go(cs) do
            Changeset.apply_changes(cs)
          end
        end
        ''',
        prepared: %{
          schema_fields: MapSet.new(["cs"]),
          schema_subtokens: MapSet.new(["cs"])
        }
      )
    end

    test "schema_fields entry beats heuristic on otherwise-short bare name" do
      # `oz` is short and would otherwise resolve nowhere → no change
      # anyway. The schema_fields entry guarantees the skip explicitly
      # so the assertion is meaningful even when context is rich.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          alias MyApp.Positions.Position

          def go(oz) do
            Position.classify(oz)
          end
        end
        ''',
        prepared: %{
          schema_fields: MapSet.new(["oz"]),
          schema_subtokens: MapSet.new(["oz"])
        }
      )
    end
  end

  describe "past-participle promotion" do
    test "verb-headed compound promotes to past participle when configured" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def normalize_keys(nk) do
            persist(nk)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def normalize_keys(normalized_key) do
            persist(normalized_key)
          end
        end
        ''',
        pp_verbs: @pp_verbs
      )
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(
        @subject,
        ~S'''
        defmodule M do
          alias Ecto.Changeset

          def go(cs) do
            Changeset.apply_changes(cs)
          end
        end
        '''
      )
    end
  end
end
