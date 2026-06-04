defmodule Number42.Refactors.Ex.SortFunctionsTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.SortFunctions

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

  describe "attached attributes travel with their function" do
    test "@impl true stays glued to its def when the def moves" do
      # `@impl true` is meaningful relative to the def directly
      # below it — moving the def without the attribute would
      # silently re-target the `@impl` at whatever happens to land
      # next, which is a silent compile-time warning at best and a
      # semantic regression at worst.
      before_source = """
      defmodule M do
        use GenServer

        @impl true
        def init(state), do: {:ok, state}

        def helper(x), do: x

        @impl true
        def handle_call(_msg, _from, state), do: {:reply, :ok, state}
      end
      """

      result = apply_refactor(@subject, before_source)

      # Each @impl true must end up directly above its original def.
      assert result =~ ~r/@impl true\s*\n\s*def handle_call/
      assert result =~ ~r/@impl true\s*\n\s*def init/

      # `helper` carries no @impl and must NOT acquire one.
      refute result =~ ~r/@impl true\s*\n\s*def helper/
    end

    test "@doc and @spec travel together with the def" do
      before_source = """
      defmodule M do
        @doc "beta docs"
        @spec beta() :: :b
        def beta, do: :b

        @doc "alpha docs"
        @spec alpha() :: :a
        def alpha, do: :a
      end
      """

      result = apply_refactor(@subject, before_source)

      a_idx = :binary.match(result, "def alpha") |> elem(0)
      b_idx = :binary.match(result, "def beta") |> elem(0)
      assert a_idx < b_idx

      # Each def's @doc and @spec must sit directly above it,
      # preserving original block contents byte-for-byte aside from
      # block ordering.
      assert result =~ ~r/@doc "alpha docs"\s*\n\s*@spec alpha\(\)\s*::\s*:a\s*\n\s*def alpha/
      assert result =~ ~r/@doc "beta docs"\s*\n\s*@spec beta\(\)\s*::\s*:b\s*\n\s*def beta/
    end

    test "plain public helper sorts ahead of @impl callbacks, attributes stay attached" do
      # Source order: init (@impl), helper (plain), handle_call (@impl).
      # New convention (issue #12 b): plain public API is grouped ahead
      # of @impl behaviour callbacks, so the order is helper, then the
      # callbacks alphabetised (handle_call, init). The two @impl
      # attributes must still follow their original defs, not whatever
      # def takes their slot.
      before_source = """
      defmodule M do
        @impl true
        def init(state), do: {:ok, state}

        def helper(x), do: x

        @impl true
        def handle_call(_msg, _from, state), do: {:reply, :ok, state}
      end
      """

      result = apply_refactor(@subject, before_source)

      # Final order: helper (plain public) < handle_call < init (callbacks).
      h_idx = :binary.match(result, "def helper") |> elem(0)
      hc_idx = :binary.match(result, "def handle_call") |> elem(0)
      i_idx = :binary.match(result, "def init") |> elem(0)
      assert h_idx < hc_idx
      assert hc_idx < i_idx

      # Each @impl must still be directly above the def it was
      # originally attached to.
      assert result =~ ~r/@impl true\s*\n\s*def handle_call/
      assert result =~ ~r/@impl true\s*\n\s*def init/
      refute result =~ ~r/@impl true\s*\n\s*def helper/
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

  describe "section comments survive (issue #12 a)" do
    test "a `# ---` divider is preserved and stays heading its section" do
      before_source = """
      defmodule M do
        use GenServer

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

        # --- GenServer callbacks ---

        @impl true
        def init(state), do: {:ok, state}

        @impl true
        def handle_call(:get, _from, state), do: {:reply, state, state}
      end
      """

      result = apply_refactor(@subject, before_source)

      # The divider must NOT be deleted...
      assert result =~ "# --- GenServer callbacks ---"

      divider_idx = :binary.match(result, "# --- GenServer callbacks ---") |> elem(0)
      start_link_idx = :binary.match(result, "def start_link") |> elem(0)
      handle_idx = :binary.match(result, "def handle_call") |> elem(0)
      init_idx = :binary.match(result, "def init") |> elem(0)

      # ...and must act as a section anchor: it stays below the public
      # API and above the callbacks it heads, never dragged into the
      # middle of a group as a clause moves.
      assert start_link_idx < divider_idx
      assert divider_idx < handle_idx
      assert divider_idx < init_idx
      # Within the section, the callbacks still sort alphabetically.
      assert handle_idx < init_idx
    end

    test "multiple dividers each stay anchoring their own section" do
      before_source = """
      defmodule M do
        use GenServer

        def start_link(opts), do: opts

        # --- GenServer callbacks ---

        @impl true
        def init(state), do: {:ok, state}

        @impl true
        def handle_call(:get, _from, state), do: {:reply, state, state}

        # --- Private helpers ---

        defp load_configs(tid), do: tid
        defp helper(x), do: x
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ "# --- GenServer callbacks ---"
      assert result =~ "# --- Private helpers ---"

      cb_idx = :binary.match(result, "# --- GenServer callbacks ---") |> elem(0)
      priv_idx = :binary.match(result, "# --- Private helpers ---") |> elem(0)
      init_idx = :binary.match(result, "def init") |> elem(0)
      helper_idx = :binary.match(result, "defp helper") |> elem(0)

      # Each section sorts independently; the dividers stay between the
      # sections in source order.
      assert cb_idx < init_idx
      assert init_idx < priv_idx
      assert priv_idx < helper_idx
    end

    test "an already-sectioned, within-section-sorted module is left unchanged" do
      # Idempotency on the conformant shape the refactor produces:
      # sections present, each section sorted, public before private.
      assert_unchanged(@subject, """
      defmodule M do
        use GenServer

        def start_link(opts), do: opts

        # --- GenServer callbacks ---

        @impl true
        def handle_call(:get, _from, state), do: {:reply, state, state}

        @impl true
        def init(state), do: {:ok, state}
      end
      """)
    end
  end

  describe "public/private + callback grouping (issue #12 b)" do
    test "@impl callbacks group together, not interleaved with plain public defs" do
      before_source = """
      defmodule M do
        def start_link(opts), do: opts

        @impl true
        def init(state), do: {:ok, state}

        def get_tid(pid), do: pid

        @impl true
        def handle_call(:get, _from, state), do: {:reply, state, state}
      end
      """

      result = apply_refactor(@subject, before_source)

      get_tid_idx = :binary.match(result, "def get_tid") |> elem(0)
      start_link_idx = :binary.match(result, "def start_link") |> elem(0)
      init_idx = :binary.match(result, "def init") |> elem(0)
      handle_idx = :binary.match(result, "def handle_call") |> elem(0)

      # Plain public defs (get_tid, start_link) must NOT be interleaved
      # with the @impl callbacks (handle_call, init): every plain public
      # def comes before every callback (or every callback before every
      # plain public def) — i.e. the two groups are contiguous, not mixed.
      plain = [get_tid_idx, start_link_idx]
      callbacks = [handle_idx, init_idx]

      assert Enum.max(plain) < Enum.min(callbacks) or
               Enum.max(callbacks) < Enum.min(plain),
             "plain public defs and @impl callbacks must not interleave"
    end

    test "defp stays after every def (public before private)" do
      before_source = """
      defmodule M do
        defp zeta_helper(x), do: x
        def alpha, do: zeta_helper(1)
        defp beta_helper(y), do: y
      end
      """

      result = apply_refactor(@subject, before_source)

      alpha_idx = :binary.match(result, "def alpha") |> elem(0)
      beta_idx = :binary.match(result, "defp beta_helper") |> elem(0)
      zeta_idx = :binary.match(result, "defp zeta_helper") |> elem(0)

      assert alpha_idx < beta_idx
      assert alpha_idx < zeta_idx
    end
  end

  describe "clause contiguity holds in all cases (issue #12 c)" do
    test "sorting never wedges a function between same name/arity clauses split by an attribute" do
      # A constant attribute (`@threshold`) sits between two clauses of
      # `run/1`. This is legal and warning-free input. The attribute
      # splits the module into regions; the lower region is
      # `[run(list), dispatch]`. Sorting it alphabetically previously
      # moved `dispatch/1` ABOVE `run(list)`, wedging it between the two
      # `run/1` clauses and producing the compiler warning
      # "clauses with the same name and arity should be grouped together".
      before_source = """
      defmodule M do
        def run([]), do: :empty

        @threshold 5

        def run(list), do: length(list)
        def dispatch(x), do: x
      end
      """

      # Sanity: the input's clauses are already grouped (no warning).
      assert ungrouped_clauses(before_source) == []

      result = apply_refactor(@subject, before_source)

      assert ungrouped_clauses(result) == [],
             """
             Refactor split same name/arity clauses apart:
             #{result}
             """
    end

    test "split clauses are left in place rather than reordered" do
      # When clauses of one function span two regions, the refactor must
      # not reorder either region (doing so risks separating the
      # clauses). The whole module passes through unchanged.
      assert_unchanged(@subject, """
      defmodule M do
        def run([]), do: :empty

        @threshold 5

        def run(list), do: length(list)
        def dispatch(x), do: x
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
