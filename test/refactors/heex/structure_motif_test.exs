defmodule Number42.Refactors.Heex.StructureMotifTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Heex.{StructureMotif, Tree}

  defp parse(body) do
    {:ok, [n]} = Tree.parse_body(body)
    n
  end

  describe "classify/1 — recognised motifs" do
    test "a thead+tbody table is a data_table" do
      n =
        parse(~S"""
        <table>
          <thead><tr><th>A</th><th>B</th></tr></thead>
          <tbody>
            <tr><td>{@a}</td><td>{@b}</td></tr>
            <tr><td>{@c}</td><td>{@d}</td></tr>
          </tbody>
        </table>
        """)

      assert StructureMotif.classify(n) == {:ok, :data_table}
    end

    test "a select with repeated options is a select_field" do
      n =
        parse(~S"""
        <select name="x">
          <option>{@a}</option>
          <option>{@b}</option>
          <option>{@c}</option>
        </select>
        """)

      assert StructureMotif.classify(n) == {:ok, :select_field}
    end

    test "repeated links are a nav_list" do
      n =
        parse(~S"""
        <div>
          <.link navigate={@a}>{@a}</.link>
          <.link navigate={@b}>{@b}</.link>
          <.link navigate={@c}>{@c}</.link>
        </div>
        """)

      assert StructureMotif.classify(n) == {:ok, :nav_list}
    end

    test "repeated buttons are a button_group" do
      n =
        parse(~S"""
        <div>
          <button>{@a}</button>
          <button>{@b}</button>
        </div>
        """)

      assert StructureMotif.classify(n) == {:ok, :button_group}
    end

    test "repeated list items are an item_list" do
      n =
        parse(~S"""
        <ul>
          <li>{@a}</li>
          <li>{@b}</li>
          <li>{@c}</li>
        </ul>
        """)

      assert StructureMotif.classify(n) == {:ok, :item_list}
    end

    test "a repeated card class is a card_grid" do
      n =
        parse(~S"""
        <div>
          <div class="card shadow"><h3>{@a}</h3></div>
          <div class="card shadow"><h3>{@b}</h3></div>
          <div class="card shadow"><h3>{@c}</h3></div>
        </div>
        """)

      assert StructureMotif.classify(n) == {:ok, :card_grid}
    end
  end

  describe "classify/1 — unknown" do
    test "a generic div>divs wrapper is unknown" do
      n =
        parse(~S"""
        <div>
          <div><span>{@a}</span></div>
          <div><span>{@b}</span></div>
        </div>
        """)

      assert StructureMotif.classify(n) == :unknown
    end

    test "an amorphous subtree with no repetition is unknown" do
      n = parse(~S|<div><section><h1>Title</h1><p>{@a}</p></section></div>|)
      assert StructureMotif.classify(n) == :unknown
    end
  end

  describe "classify/1 — determinism" do
    test "is deterministic and idempotent" do
      n =
        parse(~S"""
        <select><option>{@a}</option><option>{@b}</option></select>
        """)

      assert StructureMotif.classify(n) == StructureMotif.classify(n)
    end
  end
end
