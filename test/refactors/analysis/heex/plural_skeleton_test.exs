defmodule Number42.Refactors.Analysis.Heex.PluralSkeletonTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Analysis.Heex.{PluralSkeleton, Tree}

  defp parse(body) do
    {:ok, [n]} = Tree.parse_body(body)
    n
  end

  describe "of/1 — shaped vs amorphous" do
    test "a subtree with no repetition is amorphous" do
      n = parse(~S|<div><section><h1>Title</h1><p>{@a}</p></section></div>|)
      assert {_sig, :amorphous} = PluralSkeleton.of(n)
    end

    test "a subtree with >=2 structurally-equal same-tag children is shaped" do
      n = parse(~S|<ul><li>{@a}</li><li>{@b}</li></ul>|)
      assert {_sig, :shaped} = PluralSkeleton.of(n)
    end

    test "two same-tag children with DIFFERENT structure stay amorphous" do
      # <div><h3> vs <div><p> are not equal -> not a plural group
      n = parse(~S|<section><div><h3>A</h3></div><div><p>{@b}</p></div></section>|)
      assert {_sig, :amorphous} = PluralSkeleton.of(n)
    end
  end

  describe "of/1 — skeleton signature" do
    test "pluralises a group of structurally-equal children" do
      # both <li> equal -> `li` collapses to plural `lis`
      n = parse(~S|<ul><li><a href={@x}>{@a}</a></li><li><a href={@y}>{@b}</a></li></ul>|)
      assert {sig, :shaped} = PluralSkeleton.of(n)
      assert sig == "ul>lis>a"
    end

    test "the classic data table skeleton" do
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

      assert {sig, :shaped} = PluralSkeleton.of(n)
      # thead's single tr has plural th; tbody's plural tr each has plural td
      assert sig =~ "ths"
      assert sig =~ "tds"
    end

    test "drops singleton wrapper branches that lead to no plural" do
      # the <header> branch has no repetition -> pruned; only the <ul>lis survives
      n =
        parse(~S"""
        <section>
          <header><h1>Title</h1></header>
          <ul><li>{@a}</li><li>{@b}</li></ul>
        </section>
        """)

      assert {sig, :shaped} = PluralSkeleton.of(n)
      refute sig =~ "header"
      assert sig =~ "lis"
    end

    test "keeps the path down to a nested plural" do
      n =
        parse(~S"""
        <div>
          <div>
            <button>{@a}</button>
            <button>{@b}</button>
          </div>
        </div>
        """)

      assert {sig, :shaped} = PluralSkeleton.of(n)
      assert sig == "div>div>buttons"
    end

    test "unequal siblings are listed individually, not pluralised" do
      n =
        parse(~S"""
        <div>
          <ul><li>{@a}</li><li>{@b}</li></ul>
          <ol><li>{@c}</li><li>{@d}</li></ol>
        </div>
        """)

      assert {sig, :shaped} = PluralSkeleton.of(n)
      assert sig =~ "ul>lis"
      assert sig =~ "ol>lis"
      assert sig =~ ";"
    end

    test "component tags keep their dot name" do
      n = parse(~S|<div><.link>{@a}</.link><.link>{@b}</.link></div>|)
      assert {sig, :shaped} = PluralSkeleton.of(n)
      assert sig == "div>.links"
    end

    test "is deterministic and idempotent" do
      n = parse(~S|<ul><li>{@a}</li><li>{@b}</li><li>{@c}</li></ul>|)
      assert PluralSkeleton.of(n) == PluralSkeleton.of(n)
    end
  end

  describe "of/1 — :for directives are runtime plurals" do
    test "a single element with :for is a plural of its tag" do
      # `<tr :for={row <- @rows}>` renders N rows — one tree node, but the
      # strongest possible plural signal. It must pluralise to `trs`.
      n = parse(~S|<tbody><tr :for={row <- @rows}><td>{row}</td></tr></tbody>|)
      assert {sig, :shaped} = PluralSkeleton.of(n)
      assert sig == "tbody>trs>td"
    end

    test "the real dynamic data table (thead :for + tbody :for)" do
      n =
        parse(~S"""
        <table>
          <thead><tr><th :for={col <- @col}>{col.label}</th></tr></thead>
          <tbody><tr :for={row <- @rows}><td>{row.a}</td><td>{row.b}</td></tr></tbody>
        </table>
        """)

      assert {sig, :shaped} = PluralSkeleton.of(n)
      assert sig =~ "ths"
      assert sig =~ "trs"
    end

    test "an <%= for %> block over a single element pluralises that element" do
      n =
        parse(~S"""
        <ul>
          <%= for item <- @items do %>
            <li>{item}</li>
          <% end %>
        </ul>
        """)

      assert {sig, :shaped} = PluralSkeleton.of(n)
      assert sig =~ "lis"
    end
  end
end
