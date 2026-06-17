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

    test "declines a subtree that carries a slot entry away from its parent component" do
      # the <div> wraps a slot entry <:left> whose parent <.split> is OUTSIDE
      # the <div>; cutting the <div> orphans the slot -> "invalid slot entry"
      src =
        wrap("""
            <.split>
              <div class="panel">
                <:left>
                  <p>{@a}</p>
                  <p>{@b}</p>
                  <p>{@c}</p>
                  <span>{@d}</span>
                </:left>
              </div>
            </.split>
        """)

      div = Enum.find(find(src), fn c -> c.tag == "div" end)
      if div, do: refute(div.accepted)
    end

    test "declines a subtree that reads @inner_block (the implicit default slot)" do
      # render_slot(@inner_block) cannot be declared as `attr :inner_block`, and
      # the slot's content lives at the call site, not inside the cut
      src =
        wrap("""
            <section class="wrap">
              <h2>{@title}</h2>
              <div class="body">
                <p>{@lead}</p>
                {render_slot(@inner_block)}
                <footer>{@note}</footer>
              </div>
            </section>
        """)

      refute Enum.any?(find(src), fn c -> c.accepted and "inner_block" in c.assigns end)
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
      src = big_card_src()
      assert R.transform(src, []) == src
    end
  end

  describe "transform/2 — rewrite (enabled)" do
    test "extracts the accepted subtree into a private component and calls it" do
      out = R.transform(big_card_src(), enabled: true)

      # a new private component was planted
      assert out =~ ~r/defp \w+\(assigns\) do/
      # with attr declarations for the read assigns
      assert out =~ ~r/attr :report_name/
      # and the call site invokes it, forwarding assigns
      assert out =~ ~r/<\.\w+ [^>]*report_name=\{@report_name\}/
      # the original inline <dl> markup moved out of render/0's body into the
      # new component (render/0 is the first ~H, the component the second)
      refute render_body(out) =~ "<dl>"
    end

    test "the rewritten source is syntactically valid Elixir" do
      out = R.transform(big_card_src(), enabled: true)
      assert parses?(out), "rewritten source must parse:\n#{out}"
    end

    test "is idempotent — a second pass changes nothing" do
      once = R.transform(big_card_src(), enabled: true)
      twice = R.transform(once, enabled: true)
      assert once == twice
    end
  end

  describe "transform/2 — multiple disjoint cuts (Slice 5)" do
    test "extracts every disjoint cohesive subtree in one sigil" do
      out = R.transform(two_panel_src(), enabled: true)

      # two private components were planted, one per panel
      defs = Regex.scan(~r/defp (\w+)\(assigns\) do/, out) |> Enum.map(fn [_, n] -> n end)
      assert length(defs) == 2, "expected two extracted components, got: #{inspect(defs)}"

      # both panels' inline markup left the render body
      refute render_body(out) =~ "<dt>Period</dt>"
      refute render_body(out) =~ "<dt>Latitude</dt>"

      # two distinct invocation call sites remain in the render body
      assert render_body(out) =~ ~r/<\.\w+ [^>]*report_name=/
      assert render_body(out) =~ ~r/<\.\w+ [^>]*location_name=/
    end

    test "the multi-cut rewrite is syntactically valid and idempotent" do
      once = R.transform(two_panel_src(), enabled: true)
      assert parses?(once), "rewritten source must parse:\n#{once}"
      assert R.transform(once, enabled: true) == once
    end

    test "never picks both an outer subtree and one nested inside it" do
      # the <main> wraps both panels and would itself be a candidate; choosing it
      # AND a panel inside it would double-cut overlapping bytes. Disjoint only.
      out = R.transform(two_panel_src(), enabled: true)
      # the render body must still parse — overlapping cuts corrupt byte slices
      assert parses?(out)
      # main itself was not extracted wholesale (panels were, individually)
      defs = Regex.scan(~r/defp (\w+)\(assigns\) do/, out) |> Enum.map(fn [_, n] -> n end)
      assert length(defs) == 2
    end
  end

  describe "transform/2 — conservative attr-type inference (Slice 6)" do
    test "an assign iterated via :for is typed :list, not :any" do
      out = R.transform(list_panel_src(), enabled: true)
      assert out =~ ~r/attr :rows, :list/
      refute out =~ ~r/attr :rows, :any/
    end

    test "an assign consumed by Enum.* is typed :list" do
      out = R.transform(enum_panel_src(), enabled: true)
      assert out =~ ~r/attr :entries, :list/
    end

    test "non-iterated assigns stay :any (no unsafe guessing)" do
      out = R.transform(list_panel_src(), enabled: true)
      # @label is plain interpolation; its runtime type is unknown -> :any
      assert out =~ ~r/attr :label, :any/
    end

    test "the typed rewrite still parses and is idempotent" do
      once = R.transform(list_panel_src(), enabled: true)
      assert parses?(once)
      assert R.transform(once, enabled: true) == once
    end

    test "a string-concatenated assign is typed :string" do
      out = R.transform(usage_panel_src(), enabled: true)
      assert out =~ ~r/attr :greeting, :string/
    end

    test "a `String.*`-consumed assign is typed :string" do
      out = R.transform(usage_panel_src(), enabled: true)
      assert out =~ ~r/attr :title, :string/
    end

    test "a `not @x` gated assign is typed :boolean" do
      out = R.transform(usage_panel_src(), enabled: true)
      assert out =~ ~r/attr :collapsed, :boolean/
    end

    test "a bare-interpolated assign in the same cut stays :any (no false type)" do
      out = R.transform(usage_panel_src(), enabled: true)
      # @subtitle is plain {@subtitle}; nothing pins its type
      assert out =~ ~r/attr :subtitle, :any/
      refute out =~ ~r/attr :subtitle, :(string|boolean|integer|list)/
    end

    test "conflicting evidence falls back to :any (never a wrong type)" do
      out = R.transform(conflict_panel_src(), enabled: true)
      # @data is iterated (:list) AND string-concatenated (:string) -> :any
      assert out =~ ~r/attr :data, :any/
      refute out =~ ~r/attr :data, :(list|string)/
    end
  end

  # ---- helpers --------------------------------------------------------------

  defp big_card_src do
    wrap("""
        <main>
          <header>
            <h1>{@page_title}</h1>
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
          </section>
        </main>
    """)
  end

  defp two_panel_src do
    wrap("""
        <main>
          <header>
            <h1>{@page_title}</h1>
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
          </section>
          <section class="location-card">
            <h2>{@location_name}</h2>
            <dl>
              <dt>Latitude</dt>
              <dd>{@latitude}</dd>
              <dt>Longitude</dt>
              <dd>{@longitude}</dd>
              <dt>Altitude</dt>
              <dd>{@altitude}</dd>
              <dt>Accuracy</dt>
              <dd>{@accuracy}</dd>
            </dl>
          </section>
        </main>
    """)
  end

  defp list_panel_src do
    wrap("""
        <main>
          <header>
            <h1>{@page_title}</h1>
          </header>
          <section class="rows-card">
            <h2>{@label}</h2>
            <table>
              <tbody>
                <tr :for={row <- @rows} class="row">
                  <td>{row.name}</td>
                  <td>{row.qty}</td>
                  <td>{row.price}</td>
                  <td>{row.total}</td>
                </tr>
              </tbody>
            </table>
          </section>
        </main>
    """)
  end

  defp enum_panel_src do
    wrap("""
        <main>
          <header>
            <h1>{@page_title}</h1>
          </header>
          <section class="entries-card">
            <h2>{@heading}</h2>
            <p>{@subheading}</p>
            <ul>
              <li>Count: {Enum.count(@entries)}</li>
              <li :for={e <- @entries} class="entry">
                <span>{e.label}</span>
                <span>{e.value}</span>
                <span>{e.unit}</span>
                <span>{e.note}</span>
              </li>
            </ul>
          </section>
        </main>
    """)
  end

  defp usage_panel_src do
    wrap("""
        <main>
          <header>
            <h1>{@page_title}</h1>
          </header>
          <section class="usage-card">
            <h2>{String.upcase(@title)}</h2>
            <p class="subtitle">{@subtitle}</p>
            <p class="greeting">{@greeting <> "!"}</p>
            <div class="body">
              <p :if={not @collapsed}>Some details below.</p>
              <p>More details here.</p>
              <p>Even more details.</p>
              <p>Yet another paragraph.</p>
              <p>And one final line.</p>
            </div>
          </section>
        </main>
    """)
  end

  defp conflict_panel_src do
    wrap("""
        <main>
          <header>
            <h1>{@page_title}</h1>
          </header>
          <section class="conflict-card">
            <h2>{@heading}</h2>
            <p class="lead">A list rendered two ways below.</p>
            <ul>
              <li :for={d <- @data} class="entry">
                <span>{d.label}</span>
                <span>{d.value}</span>
                <span>{d.note}</span>
              </li>
            </ul>
            <p class="caption">{@data <> " (joined)"}</p>
            <footer class="meta">
              <span>End of list.</span>
            </footer>
          </section>
        </main>
    """)
  end

  defp render_body(out) do
    # crude: the text between the first ~H""" and its closing """
    case Regex.run(~r/~H"""(.*?)"""/s, out) do
      [_, body] -> body
      _ -> out
    end
  end

  # Phoenix.Component isn't loaded in this test env, so a full compile would
  # fail on `use Phoenix.Component` regardless of the rewrite. Parse instead:
  # this catches the rewrite's own syntax errors (broken heredoc, unbalanced
  # ~H, malformed attr lines) without the Phoenix dependency.
  defp parses?(src) do
    match?({:ok, _}, Code.string_to_quoted(src))
  end
end
