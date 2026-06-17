defmodule Number42.Refactors.Heex.ComponentNamingTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Heex.{ComponentNaming, Tree}

  defp parse(body) do
    {:ok, [n]} = Tree.parse_body(body)
    n
  end

  describe "derive/2 — naming source chain" do
    test "1. semantic tag wins when present" do
      n = parse(~S|<section class="x"><p>{@a}</p></section>|)
      assert ComponentNaming.derive(n, []) == :section
    end

    test "2. class-hint noun when tag is generic" do
      n = parse(~S|<div class="user-card shadow"><p>{@a}</p></div>|)
      assert ComponentNaming.derive(n, []) == :card
    end

    test "3. heading text when no semantic tag / class hint" do
      n = parse(~S|<div><h2>Order Summary</h2><p>{@a}</p></div>|)
      assert ComponentNaming.derive(n, []) == :order_summary
    end

    test "4. gettext literal when no heading" do
      n = parse(~S|<div><b>{gettext("Weekly Module Breakdown")}</b><p>{@a}</p></div>|)
      assert ComponentNaming.derive(n, []) == :weekly_module_breakdown
    end

    test "5. dominant assign when nothing else" do
      n = parse(~S|<div><p>{@weekly_data}</p><span>{@weekly_data}</span><i>{@other}</i></div>|)
      assert ComponentNaming.derive(n, []) == :weekly_data
    end

    test "falls back to a generic name when no source yields anything" do
      n = parse(~S|<div><p>{1 + 1}</p></div>|)
      assert ComponentNaming.derive(n, []) == :component
    end

    test "disambiguates against taken names with a numeric suffix" do
      n = parse(~S|<section><p>{@a}</p></section>|)
      assert ComponentNaming.derive(n, [:section]) == :section_2
      assert ComponentNaming.derive(n, [:section, :section_2]) == :section_3
    end

    test "semantic tag beats class hint beats heading (priority order)" do
      n = parse(~S|<section class="user-card"><h2>Profile</h2><p>{@a}</p></section>|)
      assert ComponentNaming.derive(n, []) == :section
    end
  end
end
