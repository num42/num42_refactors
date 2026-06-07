defmodule Number42.Refactors.HelperNamingTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.HelperNaming

  # Parse a block of statements into the AST list HelperNaming expects.
  # A single statement parses to a bare node, multiple to a `__block__`.
  defp stmts(src) do
    case Code.string_to_quoted!("(\n#{src}\n)") do
      {:__block__, _, exprs} -> exprs
      single -> [single]
    end
  end

  defp name(host, live_out, src, params \\ [], existing \\ [], opts \\ []) do
    HelperNaming.name(host, live_out, stmts(src), params, MapSet.new(existing), opts)
  end

  describe "verb + object" do
    test "fetch verb from get_field + two meaningful live-outs" do
      assert {:ok, :fetch_mass_type_and_unit} =
               name(:validate, [:mass_type, :unit], """
               mass_type = get_field(changeset, :mass_type)
               unit = get_field(changeset, :unit)
               """)
    end

    test "fetch verb from a Repo.list call + single live-out" do
      assert {:ok, :fetch_brands} =
               name(:load_brands, [:brands], """
               scope = socket.assigns.current_scope
               brands = Repo.all(query(scope))
               """)
    end

    test "validate verb from add_error" do
      assert {:ok, :validate_changeset} =
               name(:check, [:changeset], """
               changeset = add_error(cs, :field, "bad")
               """)
    end

    test "build verb from a changeset call" do
      assert {:ok, :build_record} =
               name(:make, [:record], """
               record = Item.changeset(%Item{}, attrs)
               """)
    end

    test "the verb prefix wins over a bare object name" do
      # A pipe ending in `Enum.filter` is not a verb in the table; the
      # producing call here is `list_*` → fetch.
      assert {:ok, :fetch_rows} =
               name(:prepare, [:rows], """
               rows = list_rows(scope)
               """)
    end
  end

  describe "object only (no inferable verb)" do
    test "two meaningful live-outs join with _and_" do
      assert {:ok, :source_and_formula} =
               name(:validate, [:source, :formula], """
               source = field(cs, :source)
               formula = field(cs, :formula)
               """)
    end

    test "two non-boilerplate live-outs join standalone" do
      assert {:ok, :children_and_count} =
               name(:browse, [:children, :count], """
               children = pick(node)
               count = size(node)
               """)
    end
  end

  describe "boilerplate carriers" do
    test "scope is dropped, the remaining object rides the verb" do
      # `{scope, filters}`: scope dropped, `fetch` from `get_filters` →
      # `fetch_filters` (a standalone `filters` would shadow the live-out).
      assert {:ok, :fetch_filters} =
               name(:browse, [:scope, :filters], """
               scope = cs.scope
               filters = get_filters(params)
               """)
    end

    test "no verb and a single surviving object → host fallback (no shadow)" do
      # `parse` is not a verb; standalone `filters` would shadow → fallback.
      assert {:ok, :browse_block} =
               name(:browse, [:scope, :filters], """
               scope = cs.scope
               filters = parse(params)
               """)
    end
  end

  describe "shadow safety" do
    test "a candidate equal to a live-out name is rejected" do
      # Single live-out `total`; `total` would shadow at the call site,
      # and no verb is inferable from `+`, so it falls back.
      assert {:ok, :run_block} =
               name(:run, [:total], """
               base = fetch(order)
               total = base + 1
               """)
    end

    test "a candidate equal to a parameter name is rejected" do
      # The result name `source_and_formula` collides with a parameter →
      # fallback.
      assert {:ok, :run_block} =
               name(
                 :run,
                 [:source, :formula],
                 """
                 source = first(source_and_formula)
                 formula = second(source_and_formula)
                 """,
                 [:source_and_formula]
               )
    end
  end

  describe "fallback" do
    test "all-boolean live-outs yield no object → host fallback" do
      assert {:ok, :gate_block} =
               name(:gate, [:ready?, :stale?], """
               ready? = check(state)
               stale? = stale(state)
               """)
    end

    test "a caller-supplied fallback is used as last resort" do
      assert {:ok, :report_phase_2} =
               name(:report, [], "format(adjusted)", [], [], fallback: :report_phase_2)
    end

    test "skips when even the fallback collides with an existing def" do
      assert :skip =
               name(:run, [:total], "total = base + 1", [], [:run_block])
    end
  end

  describe "suffixed/2 — bang-safe" do
    test "keeps a trailing bang at the end" do
      assert HelperNaming.suffixed(:verify!, "_block") == :verify_block!
    end

    test "keeps a trailing question mark at the end" do
      assert HelperNaming.suffixed(:valid?, "_phase_1") == :valid_phase_1?
    end

    test "plain name just appends" do
      assert HelperNaming.suffixed(:report, "_phase_2") == :report_phase_2
    end
  end
end
