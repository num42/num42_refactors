defmodule Number42.Refactors.Ex.ExtractHeexComponentBySeamTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Ex.ExtractHeexComponentBySeam, as: R

  # compact fixtures: relax size gates so the seam/leak/free-var logic is what's
  # under test, not the production size threshold (calibrated to >=10n/>=12L).
  defp find(src), do: R.find_candidates(src, min_nodes: 5, min_lines: 4)

  defp wrap(body) do
    """
    defmodule Demo do
      use Phoenix.Component

      def render(assigns) do
        ~H\"\"\"
    #{body}
        \"\"\"
      end
    end
    """
  end

  describe "find_candidates/1 — detection" do
    test "finds a large cohesive subtree with a clean assign seam" do
      src =
        wrap("""
            <div>
              <h1>{@title}</h1>
              <section class="card">
                <p>{@summary}</p>
                <ul>
                  <li>{@detail_a}</li>
                  <li>{@detail_b}</li>
                  <li>{@detail_c}</li>
                </ul>
              </section>
            </div>
        """)

      cands = find(src)
      assert Enum.any?(cands, fn c -> c.assigns != [] and c.free_vars == [] end)
    end

    test "declines a subtree whose assigns leak heavily to siblings" do
      # @shared is read both inside the candidate and in a sibling -> high leak
      src =
        wrap("""
            <div>
              <section class="a">
                <p>{@shared}</p>
                <p>{@shared}</p>
                <p>{@a1}</p>
              </section>
              <aside>{@shared}</aside>
            </div>
        """)

      cands = find(src)
      # the <section> reads @shared,@a1; @shared also outside -> leak 0.5 > 0.25
      refute Enum.any?(cands, fn c -> "section" == c.tag and c.accepted end)
    end

    test "declines a subtree with a free non-assign variable (unsafe cut)" do
      src =
        wrap("""
            <ul>
              <%= for item <- @items do %>
                <li>
                  <span>{item.name}</span>
                  <span>{item.detail}</span>
                  <span>{@suffix}</span>
                </li>
              <% end %>
            </ul>
        """)

      cands = find(src)
      # the <li> alone is unsafe (free `item`); only the whole for-block is safe
      li = Enum.find(cands, fn c -> c.tag == "li" end)
      if li, do: refute(li.accepted)
    end

    test "accepts a whole for-block (generator bound internally)" do
      src =
        wrap("""
            <ul>
              <%= for item <- @items do %>
                <li>
                  <span>{item.name}</span>
                  <span>{item.detail}</span>
                  <span>{@suffix}</span>
                </li>
              <% end %>
            </ul>
        """)

      cands = find(src)
      block = Enum.find(cands, fn c -> c.kind == :eex_block end)
      assert block && block.free_vars == []
    end

    test "declines a subtree that is itself a single component invocation" do
      src =
        wrap("""
            <div>
              <.live_component module={Foo} id="x" a={@a} b={@b} c={@c} d={@d} e={@e} />
            </div>
        """)

      cands = find(src)
      refute Enum.any?(cands, fn c -> c.accepted and String.starts_with?(c.tag, ".") end)
    end
  end

  describe "production thresholds (default gates, no opts)" do
    test "a genuinely large cohesive subtree clears the >=10n/>=12L default gate" do
      # A realistic card-sized panel: big enough that the indirection pays off,
      # with a clean assign seam disjoint from the surrounding header.
      src =
        wrap("""
            <main>
              <header>
                <h1>{@page_title}</h1>
                <span>{@breadcrumb}</span>
              </header>
              <section class="report-card">
                <h2>{@report_name}</h2>
                <dl>
                  <dt>Period</dt>
                  <dd>{@period_label}</dd>
                  <dt>Total</dt>
                  <dd>{@total_amount}</dd>
                  <dt>Average</dt>
                  <dd>{@average_amount}</dd>
                  <dt>Peak</dt>
                  <dd>{@peak_amount}</dd>
                </dl>
                <footer>
                  <p>{@report_footnote}</p>
                </footer>
              </section>
            </main>
        """)

      # default gates — NO opts override
      cands = R.find_candidates(src)
      section = Enum.find(cands, fn c -> c.tag == "section" end)

      assert section, "the large <section> must survive the production size gate"
      assert section.nodes >= 10
      assert section.lines >= 12
      assert section.accepted
      assert section.leak == 0.0
      assert section.free_vars == []
      # the report assigns are the seam; page_title/breadcrumb stay in the header
      assert "report_name" in section.assigns
      refute "page_title" in section.assigns
    end

    test "the same subtree below the default line gate is not a candidate" do
      # one-liner-dense version: many nodes but few lines -> below >=12L
      src = wrap(~s|<section><b>{@a}</b><b>{@b}</b><b>{@c}</b><b>{@d}</b><b>{@e}</b></section>|)
      assert Enum.find(R.find_candidates(src), fn c -> c.tag == "section" end) == nil
    end
  end

  describe "behaviour" do
    test "transform is a no-op unless enabled" do
      src = wrap("<div><p>{@a}</p><p>{@b}</p><p>{@c}</p></div>")
      assert R.transform(src, []) == src
    end

    test "transform is a no-op even when enabled (rewrite is Slice 4)" do
      src = wrap("<div><p>{@a}</p><p>{@b}</p><p>{@c}</p></div>")
      assert R.transform(src, enabled: true) == src
    end
  end
end
