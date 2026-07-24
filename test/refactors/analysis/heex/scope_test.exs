defmodule Number42.Refactors.Analysis.Heex.ScopeTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Analysis.Heex.{Scope, Tree}

  defp parse(body) do
    {:ok, [n]} = Tree.parse_body(body)
    n
  end

  describe "free_nonassign_vars/1" do
    test "a subtree reading only @assigns has no free vars" do
      n = parse(~S|<div class={@cls}><span>{@name}</span></div>|)
      assert Scope.free_nonassign_vars(n) == MapSet.new()
    end

    test "a whole for-block is safe — its generator var is bound internally" do
      n =
        parse("""
        <ul>
          <%= for item <- @items do %>
            <li>{item.name}</li>
          <% end %>
        </ul>
        """)

      assert Scope.free_nonassign_vars(n) == MapSet.new()
    end

    test "a for-block child referencing the generator var IS free when cut alone" do
      # the <li> alone, lifted out of its enclosing for, loses `item`
      whole =
        parse("""
        <ul>
          <%= for item <- @items do %>
            <li>{item.name}</li>
          <% end %>
        </ul>
        """)

      {:element, "ul", _, [block], _} = whole
      {:eex_block, _hdr, [li], _} = block

      assert Scope.free_nonassign_vars(li) == MapSet.new(["item"])
    end

    test "a :let-bound var is free when its binding parent is not included" do
      whole = parse(~S|<.form :let={f} for={@cs}><input value={f[:x]} /></.form>|)
      {:element, ".form", _, [input], _} = whole

      assert Scope.free_nonassign_vars(input) == MapSet.new(["f"])
    end

    test "a :let binding covers its children when the whole form is the subtree" do
      whole = parse(~S|<.form :let={f} for={@cs}><input value={f[:x]} /></.form>|)
      assert Scope.free_nonassign_vars(whole) == MapSet.new()
    end

    test "function call targets are not free vars" do
      n = parse(~S|<div>{humanize(@status)}</div>|)
      assert Scope.free_nonassign_vars(n) == MapSet.new()
    end

    test "bitstring type specifiers (`x :: binary`) are not free vars" do
      n = parse(~S|<div>{case @kind do <<v::binary>> -> v end}</div>|)
      # `v` is bound by the pattern, `binary` is a type specifier — neither free
      assert Scope.free_nonassign_vars(n) == MapSet.new()
    end

    test "local assignment in a sibling does not leak into a cut that uses it" do
      # `<% total = @a + @b %>` binds `total`; a sibling using {total} is free
      # when cut without the binder.
      n = parse(~S|<span>{total}</span>|)
      assert Scope.free_nonassign_vars(n) == MapSet.new(["total"])
    end

    test "a `:for=` directive binds its generator var for the element's children" do
      # Phoenix inline comprehension: `:for={row <- @rows}` on <tr> binds `row`
      # for the <tr> subtree exactly like `<%= for %>`. The whole <table> is safe.
      n =
        parse("""
        <table>
          <tr :for={row <- @rows}>
            <td>{row.name}</td>
            <td>{row.qty}</td>
          </tr>
        </table>
        """)

      assert Scope.free_nonassign_vars(n) == MapSet.new()
    end

    test "a `:for=` element cut without its own directive scope is fine (directive travels with it)" do
      # the <tr> carries its own :for directive, so lifting the <tr> keeps `row`
      # bound — not free.
      whole =
        parse("""
        <table>
          <tr :for={row <- @rows}>
            <td>{row.name}</td>
          </tr>
        </table>
        """)

      {:element, "table", _, [tr], _} = whole
      assert Scope.free_nonassign_vars(tr) == MapSet.new()
    end

    test "a child of a `:for=` element IS free when cut below the directive" do
      whole =
        parse("""
        <table>
          <tr :for={row <- @rows}>
            <td>{row.name}</td>
          </tr>
        </table>
        """)

      {:element, "table", _, [tr], _} = whole
      {:element, "tr", _, [td], _} = tr
      assert Scope.free_nonassign_vars(td) == MapSet.new(["row"])
    end

    test "nested for binders accumulate down the tree" do
      n =
        parse("""
        <div>
          <%= for row <- @rows do %>
            <%= for cell <- row.cells do %>
              <td>{cell}{row.id}</td>
            <% end %>
          <% end %>
        </div>
        """)

      assert Scope.free_nonassign_vars(n) == MapSet.new()
    end
  end
end
