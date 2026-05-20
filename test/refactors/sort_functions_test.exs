defmodule Num42.Refactors.Refactors.SortFunctionsTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.SortFunctions

  @subject SortFunctions

  describe "rewrites" do
    test "sorts a contiguous def group alphabetically" do
      before_source = """
      defmodule Foo do
        def beta, do: :b
        def alpha, do: :a
        def gamma, do: :g
      end
      """

      result = apply_refactor(@subject, before_source)

      # Order: alpha < beta < gamma must hold in the result.
      a_idx = :binary.match(result, "def alpha") |> elem(0)
      b_idx = :binary.match(result, "def beta") |> elem(0)
      g_idx = :binary.match(result, "def gamma") |> elem(0)

      assert a_idx < b_idx
      assert b_idx < g_idx
    end

    test "keeps multi-clause functions together when sorting" do
      before_source = """
      defmodule Foo do
        def beta(:a), do: :a
        def beta(:b), do: :b
        def alpha, do: :a
      end
      """

      result = apply_refactor(@subject, before_source)

      # alpha must come before both beta clauses.
      alpha_idx = :binary.match(result, "def alpha") |> elem(0)
      beta_a_idx = :binary.match(result, "def beta(:a)") |> elem(0)
      beta_b_idx = :binary.match(result, "def beta(:b)") |> elem(0)

      assert alpha_idx < beta_a_idx
      # Multi-clause beta clauses stay contiguous and ordered.
      assert beta_a_idx < beta_b_idx
    end
  end

  describe "leaves alone" do
    test "already sorted" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def alpha, do: :a
        def beta, do: :b
        def gamma, do: :g
      end
      """)
    end

    test "single function" do
      assert_unchanged(@subject, """
      defmodule Foo do
        def only, do: :ok
      end
      """)
    end

    test "no defmodule wrapper" do
      assert_unchanged(@subject, "x = 1\n")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      defmodule Foo do
        def beta, do: :b
        def alpha, do: :a
      end
      """)
    end
  end

  describe "HEEx-first ordering" do
    test "lifts ~H-bearing defs to the top of the module" do
      before_source = """
      defmodule MyLive do
        def mount(_params, _session, socket), do: {:ok, socket}

        def render_item(assigns) do
          ~H"<li>{@item}</li>"
        end

        def render(assigns) do
          ~H"<ul></ul>"
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      render_idx = :binary.match(result, "def render(") |> elem(0)
      render_item_idx = :binary.match(result, "def render_item(") |> elem(0)
      mount_idx = :binary.match(result, "def mount(") |> elem(0)

      assert render_idx < mount_idx
      assert render_item_idx < mount_idx
      # Within the HEEx group: alphabetical -> render before render_item.
      assert render_idx < render_item_idx
    end

    test "multi-clause function lands in HEEx group when any clause renders ~H" do
      before_source = """
      defmodule MyLive do
        def handle_event("x", _, socket), do: {:noreply, socket}

        def card(%{kind: :a} = assigns) do
          ~H"<div>a</div>"
        end

        def card(assigns) do
          assigns
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      card_a_idx = :binary.match(result, "def card(%{kind:") |> elem(0)
      card_default_idx = :binary.match(result, "def card(assigns)") |> elem(0)
      handle_idx = :binary.match(result, "def handle_event") |> elem(0)

      # Both card clauses lift to top together; their relative order
      # is preserved (catch-all stays below the specific clause).
      assert card_a_idx < handle_idx
      assert card_default_idx < handle_idx
      assert card_a_idx < card_default_idx
    end

    test "attr/slot decorators travel with their function component" do
      before_source = """
      defmodule MyComponents do
        attr :name, :string, required: true

        def b(assigns) do
          ~H"<span>b {@name}</span>"
        end

        attr :title, :string, required: true
        slot :inner_block, required: true

        def a(assigns) do
          ~H"<div>a {@title}<%= render_slot(@inner_block) %></div>"
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      a_idx = :binary.match(result, "def a(") |> elem(0)
      b_idx = :binary.match(result, "def b(") |> elem(0)
      attr_title_idx = :binary.match(result, ":title") |> elem(0)
      slot_inner_idx = :binary.match(result, ":inner_block") |> elem(0)
      attr_name_idx = :binary.match(result, ":name") |> elem(0)

      # Sorted alphabetically: a before b.
      assert a_idx < b_idx
      # attr/slot for `a` must be glued above `def a(`.
      assert attr_title_idx < a_idx
      assert slot_inner_idx < a_idx
      # attr for `b` must be glued above `def b(`.
      assert attr_name_idx < b_idx
      # And the decorators of `a` come before those of `b` (since `a` moved up).
      assert attr_title_idx < attr_name_idx
    end

    test "non-HEEx region terminator (defstruct) still splits regions" do
      before_source = """
      defmodule MyLive do
        def mount(_, _, socket), do: {:ok, socket}

        defstruct [:x]

        def render(assigns) do
          ~H"<ul></ul>"
        end
      end
      """

      # `defstruct` separates the two functions into independent regions,
      # neither of which has 2+ blocks — so nothing to sort.
      assert_unchanged(@subject, before_source)
    end
  end
end
