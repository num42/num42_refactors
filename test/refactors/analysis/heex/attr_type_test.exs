defmodule Number42.Refactors.Analysis.Heex.AttrTypeTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Analysis.Heex.{AttrType, Tree}

  defp infer(assign, body) do
    {:ok, nodes} = Tree.parse_body(body)
    AttrType.infer(assign, nodes)
  end

  describe "motif / structural role" do
    test "an assign that is the source of a :for directive is :list" do
      assert infer("rows", ~S|<tr :for={row <- @rows}><td>{row.x}</td></tr>|) == :list
    end

    test "an assign iterated by an EEx for-block is :list" do
      body = """
      <ul>
        <%= for item <- @items do %>
          <li>{item.name}</li>
        <% end %>
      </ul>
      """

      assert infer("items", body) == :list
    end

    test "an assign passed first to Enum.* is :list" do
      assert infer("entries", ~S|<p>{Enum.count(@entries)}</p>|) == :list
    end

    test "an assign passed first to Stream.* is :list" do
      assert infer("rows", ~S|<p>{Stream.map(@rows, & &1.id)}</p>|) == :list
    end

    test "the :for generator var itself (not the source assign) is not typed" do
      # `row` is a binder, `@rows` is the source — `row` is not an assign at all
      assert infer("row", ~S|<tr :for={row <- @rows}><td>{row.x}</td></tr>|) == :any
    end
  end

  describe "signature / usage" do
    test "an assign behind unary `not` is :boolean" do
      assert infer("hidden", ~S|<div :if={not @hidden}>x</div>|) == :boolean
    end

    test "an assign behind `!` is :boolean" do
      assert infer("hidden", ~S|<div :if={!@hidden}>x</div>|) == :boolean
    end

    test "an assign string-concatenated on the left is :string" do
      assert infer("name", ~S|<span>{@name <> "!"}</span>|) == :string
    end

    test "an assign string-concatenated on the right is :string" do
      assert infer("name", ~S|<span>{"hi " <> @name}</span>|) == :string
    end

    test "an assign passed first to String.* is :string" do
      assert infer("title", ~S|<h1>{String.upcase(@title)}</h1>|) == :string
    end
  end

  describe "conservative bias — :any" do
    test "bare interpolation proves nothing" do
      assert infer("label", ~S|<span>{@label}</span>|) == :any
    end

    test "an attribute value proves nothing" do
      assert infer("cls", ~S|<div class={@cls}>x</div>|) == :any
    end

    test "a bare `:if={@flag}` truthiness gate is too weak (any truthy value)" do
      assert infer("flag", ~S|<div :if={@flag}>x</div>|) == :any
    end

    test "a comparison against a literal does not type the assign" do
      assert infer("status", ~S|<div :if={@status == :ok}>x</div>|) == :any
    end

    test "arithmetic does not type the assign (integer vs float unresolved)" do
      assert infer("count", ~S|<span>{@count + 1}</span>|) == :any
    end

    test "conflicting strong signals fall back to :any" do
      # @x is both iterated (:list) and string-concatenated (:string) -> conflict
      body = """
      <div>
        <p :for={i <- @x}>{i}</p>
        <span>{@x <> "!"}</span>
      </div>
      """

      assert infer("x", body) == :any
    end

    test "an unread assign yields :any" do
      assert infer("absent", ~S|<span>{@present}</span>|) == :any
    end
  end
end
