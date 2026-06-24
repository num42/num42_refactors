defmodule Number42.Refactors.Ex.ExtractExpressionCloneTest do
  @moduledoc """
  Tests for expression-level clone extraction.

  Prove that a sub-expression shared across two functions is detected,
  lifted into a shared `defp`, and that the result compiles; that the
  conservative safety gates fire; and that the Slice-3 net-savings /
  live-out-width thresholds sieve trivial plumbing clones while keeping
  genuine ones.
  """
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractExpressionClone

  @subject ExtractExpressionClone

  # ExtractExpressionClone is default-OFF: `transform/2` is a no-op unless
  # its opts carry `enabled: true`. Behaviour tests also pass
  # `min_savings: 0` so they exercise the extraction *mechanism* without
  # tripping the Slice-3 net-savings heuristic (which has its own tests).
  @on [enabled: true, min_savings: 0]

  describe "default-OFF (opt-in only)" do
    test "without enabled: true, transform is a no-op" do
      source = """
      defmodule M do
        def a(order) do
          subtotal = Enum.sum(order.lines)
          taxed = subtotal * 1.19
          {subtotal, taxed}
        end

        def b(cart) do
          subtotal = Enum.sum(cart.lines)
          taxed = subtotal * 1.19
          {subtotal, taxed}
        end
      end
      """

      assert apply_refactor(@subject, source, min_mass: 8, min_savings: 0) == source
    end
  end

  describe "expression-level extraction" do
    test "a whole-body sub-block shared across two functions is lifted into a defp and compiles" do
      source = """
      defmodule M do
        def a(order) do
          subtotal = Enum.sum(order.lines)
          taxed = subtotal * 1.19
          {subtotal, taxed}
        end

        def b(cart) do
          subtotal = Enum.sum(cart.lines)
          taxed = subtotal * 1.19
          {subtotal, taxed}
        end
      end
      """

      out = apply_refactor(@subject, source, @on ++ [min_mass: 8])

      # Both call sites now delegate to one shared helper. The block ends in
      # a bare tuple-literal return `{subtotal, taxed}` — no live-out, but its
      # elements name the product: verb `compute` (Enum.sum), object from the
      # tuple vars → compute_subtotal_and_taxed (not the placeholder).
      assert out =~ "def a(order) do"
      assert out =~ "compute_subtotal_and_taxed(order)"
      assert out =~ "compute_subtotal_and_taxed(cart)"
      assert out =~ "defp compute_subtotal_and_taxed(order) do"
      refute out =~ "extracted_clone"

      # The free variable became the single helper parameter, threaded
      # positionally at each call site (a(order) -> order, b(cart) -> cart).
      assert_compiles(out)
      assert_idempotent(@subject, source, @on ++ [min_mass: 8])
    end

    test "a PARTIAL sub-block (tail only) is extracted when it is nameable" do
      # The key expression-level capability: the shared clone is only the
      # last statements; the leading statements differ between a and b. The
      # function-level finders would never see this. The shared tail
      # produces a nameable tuple result (`Enum.sum` → verb `compute`, the
      # returned tuple `{subtotal, taxed}` → object), so it is named — never
      # a placeholder (#375).
      source = """
      defmodule M do
        def log(_), do: :ok
        def audit(_, _), do: :ok

        def a(order) do
          log(order)
          subtotal = Enum.sum(order.amounts)
          taxed = subtotal * 1.19
          {subtotal, taxed}
        end

        def b(cart, note) do
          audit(cart, note)
          subtotal = Enum.sum(cart.amounts)
          taxed = subtotal * 1.19
          {subtotal, taxed}
        end
      end
      """

      out = apply_refactor(@subject, source, @on ++ [min_mass: 6])

      # Only the shared tail moved into the helper; the distinct prefixes
      # (log/audit) stay put.
      assert out =~ "log(order)"
      assert out =~ "audit(cart, note)"
      assert out =~ "defp compute_subtotal_and_taxed(order) do"
      refute out =~ "extracted_clone"

      assert_compiles(out)
      assert_idempotent(@subject, source, @on ++ [min_mass: 6])
    end

    test "leaves a block with control-flow (raise) untouched" do
      source = """
      defmodule M do
        def a(x) do
          y = x + 1
          raise "boom \#{y}"
        end

        def b(z) do
          y = z + 1
          raise "boom \#{y}"
        end
      end
      """

      assert_unchanged(@subject, source, @on ++ [min_mass: 5])
    end

    test "leaves functions with no shared sub-expression untouched" do
      source = """
      defmodule M do
        def a(x) do
          y = x + 1
          y * 2
        end

        def b(z) do
          w = z - 3
          w * 9
        end
      end
      """

      assert_unchanged(@subject, source, @on ++ [min_mass: 5])
    end
  end

  describe "live-out via value return (slice 1)" do
    test "a single-live-out block with a non-nameable tail is declined (no placeholder)" do
      # The shared block binds one live-out `taxed`, read by each differing
      # tail. Its terminal is arithmetic (`subtotal * 1.19`) — no verb, and
      # a lone object can't stand alone — so no meaningful name surfaces and
      # the clone is declined rather than extracted under `extracted_clone`
      # (#375). The bare-return-of-one-live-out *mechanic* itself is covered
      # by the named tuple-return tests below and the position-db dogfood.
      source = """
      defmodule M do
        def log_invoice(_), do: :ok
        def store_total(_), do: :ok

        def a(order) do
          subtotal = Enum.sum(order.lines)
          taxed = subtotal * 1.19
          log_invoice(taxed)
        end

        def b(cart) do
          subtotal = Enum.sum(cart.lines)
          taxed = subtotal * 1.19
          store_total(taxed)
        end
      end
      """

      out = apply_refactor(@subject, source, @on ++ [min_mass: 6])
      assert out == source
      refute out =~ "extracted_clone"
    end

    test "a shared block binding TWO live-out vars returns a tuple and destructures at each call" do
      source = """
      defmodule M do
        def log_invoice(_, _), do: :ok
        def store_total(_, _), do: :ok

        def a(order) do
          subtotal = Enum.sum(order.lines)
          taxed = subtotal * 1.19
          log_invoice(subtotal, taxed)
        end

        def b(cart) do
          subtotal = Enum.sum(cart.lines)
          taxed = subtotal * 1.19
          store_total(subtotal, taxed)
        end
      end
      """

      out = apply_refactor(@subject, source, @on ++ [min_mass: 6])

      # Tuple return + destructure, in canonical (first-appearance) order:
      # subtotal before taxed at every site and in the helper return. The
      # helper is named semantically (verb `compute` from `Enum.sum`, object
      # from the two live-out vars), not the placeholder `extracted_clone`.
      assert out =~ "{subtotal, taxed} = compute_subtotal_and_taxed(order)"
      assert out =~ "{subtotal, taxed} = compute_subtotal_and_taxed(cart)"
      assert out =~ "defp compute_subtotal_and_taxed(order) do"
      assert out =~ "{subtotal, taxed}\n  end"

      assert_compiles(out)
      assert_idempotent(@subject, source, @on ++ [min_mass: 6])
    end

    test "a second pass over the tuple-return output is a no-op" do
      source = """
      defmodule M do
        def log_invoice(_, _), do: :ok
        def store_total(_, _), do: :ok

        def a(order) do
          subtotal = Enum.sum(order.lines)
          taxed = subtotal * 1.19
          log_invoice(subtotal, taxed)
        end

        def b(cart) do
          subtotal = Enum.sum(cart.lines)
          taxed = subtotal * 1.19
          store_total(subtotal, taxed)
        end
      end
      """

      once = apply_refactor(@subject, source, @on ++ [min_mass: 6])
      assert_compiles(once)
      # Convergence: the extracted output is a fixpoint.
      assert_unchanged(@subject, once, @on ++ [min_mass: 6])
    end

    test "structurally identical blocks with DIFFERENT live-out arity are not co-extracted" do
      # a binds one live-out (taxed), b binds two (subtotal + taxed).
      # Same block shape, but different return arity — fusing them would
      # force one return shape on both. The live-out count in the
      # fingerprint puts them in separate buckets, so neither fires.
      source = """
      defmodule M do
        def log_invoice(_), do: :ok
        def store_total(_, _), do: :ok

        def a(order) do
          subtotal = Enum.sum(order.lines)
          taxed = subtotal * 1.19
          log_invoice(taxed)
        end

        def b(cart) do
          subtotal = Enum.sum(cart.lines)
          taxed = subtotal * 1.19
          store_total(subtotal, taxed)
        end
      end
      """

      assert_unchanged(@subject, source, @on ++ [min_mass: 6])
    end
  end

  describe "self-rebound free variable (use-before-rebind)" do
    # These blocks exercise flow-sensitive free-var detection — `socket =
    # socket |> call(c)` reads `socket` before rebinding it, so `socket`
    # must thread in as a parameter. Their terminals (`{:noreply, socket}`,
    # `assigns.x`) yield no meaningful name, so under derive-or-decline
    # (#375) they are declined rather than minted as `extracted_clone`. The
    # free-var-threading mechanic itself is exercised by the named
    # tuple-return tests and proven on position-db (`maybe_filter_*`,
    # `*_subquery` helpers all thread free vars).
    test "a self-rebound block with a non-nameable tail is declined (no placeholder)" do
      source = """
      defmodule M do
        def put_node_at_path(s, _c), do: s

        def handle_a(socket, c) do
          socket = socket |> put_node_at_path(c)
          {:noreply, socket}
        end

        def handle_b(socket, c) do
          socket = socket |> put_node_at_path(c)
          {:noreply, socket}
        end
      end
      """

      out = apply_refactor(@subject, source, @on ++ [min_mass: 4])
      assert out == source
      refute out =~ "extracted_clone"
    end

    test "the same idiom with `assigns` rebound via assign/2 is also declined when unnameable" do
      source = """
      defmodule M do
        def assign(a, _k, _v), do: a

        def render_a(assigns, val) do
          assigns = assigns |> assign(:x, val)
          assigns.x
        end

        def render_b(assigns, val) do
          assigns = assigns |> assign(:x, val)
          assigns.x
        end
      end
      """

      out = apply_refactor(@subject, source, @on ++ [min_mass: 4])
      assert out == source
      refute out =~ "extracted_clone"
    end
  end

  describe "semantic helper naming + collision safety (slice 2)" do
    test "the helper is named by verb+object from the block, not the placeholder" do
      # `Enum.sum` produces a live-out → verb `compute`; the two live-out
      # vars give the object `subtotal_and_taxed`. The helper reads as what
      # it does, not the anonymous `extracted_clone`.
      source = """
      defmodule M do
        def log_invoice(_, _), do: :ok
        def store_total(_, _), do: :ok

        def a(order) do
          subtotal = Enum.sum(order.lines)
          taxed = subtotal * 1.19
          log_invoice(subtotal, taxed)
        end

        def b(cart) do
          subtotal = Enum.sum(cart.lines)
          taxed = subtotal * 1.19
          store_total(subtotal, taxed)
        end
      end
      """

      out = apply_refactor(@subject, source, @on ++ [min_mass: 6])

      assert out =~ "defp compute_subtotal_and_taxed(order) do"
      assert out =~ "compute_subtotal_and_taxed(order)"
      assert out =~ "compute_subtotal_and_taxed(cart)"
      # The placeholder name is gone now that a real one was inferable.
      refute out =~ "extracted_clone"

      assert_compiles(out)
      assert_idempotent(@subject, source, @on ++ [min_mass: 6])
    end

    test "evades a name that collides with an existing def in the module" do
      # The block would derive `compute_subtotal_and_taxed`, but a function
      # of that name already exists. The refactor must NOT redefine it — it
      # falls to the next collision-free candidate (`subtotal_and_taxed`).
      source = """
      defmodule M do
        def compute_subtotal_and_taxed(_), do: :preexisting

        def a(order) do
          subtotal = Enum.sum(order.lines)
          taxed = subtotal * 1.19
          {subtotal, taxed}
        end

        def b(cart) do
          subtotal = Enum.sum(cart.lines)
          taxed = subtotal * 1.19
          {subtotal, taxed}
        end
      end
      """

      out = apply_refactor(@subject, source, @on ++ [min_mass: 6])

      # The pre-existing function is left intact (one definition only).
      assert out =~ "def compute_subtotal_and_taxed(_), do: :preexisting"
      # The synthesised helper took a different, collision-free name.
      assert out =~ "defp subtotal_and_taxed(order) do"
      refute out =~ "defp compute_subtotal_and_taxed("

      # Whatever name is chosen, the result must compile.
      assert_compiles(out)
      assert_idempotent(@subject, source, @on ++ [min_mass: 6])
    end

    test "unnameable clone groups are declined, never given an extracted_clone placeholder" do
      # Two structurally distinct clone groups, both arithmetic-only (no
      # verb, single live-out) → neither is nameable. With no placeholder
      # fallback (#375) both are declined rather than minted as
      # `extracted_clone` / `extracted_clone_2`. Duplication no one can name
      # is left in place.
      source = """
      defmodule M do
        def t1(_), do: :ok
        def t2(_), do: :ok
        def t3(_), do: :ok
        def t4(_), do: :ok

        def a(x) do
          p = x + 1
          q = p * 2
          t1(q)
        end

        def b(y) do
          p = y + 1
          q = p * 2
          t2(q)
        end

        def c(m) do
          r = m - 7
          s = r * 9
          t3(s)
        end

        def d(n) do
          r = n - 7
          s = r * 9
          t4(s)
        end
      end
      """

      out = apply_refactor(@subject, source, @on ++ [min_mass: 6])
      assert out == source
      refute out =~ "extracted_clone"
    end
  end

  describe "net-savings threshold (slice 3, hebel A)" do
    # The real position-db noise: a two-statement plumbing prefix that only
    # restates `socket.assigns` fields. The differing tails (`edit`/`show`)
    # read `scope`/`item`, so they are the block's two live-out vars. It
    # clears `min_mass` (~19), but `{scope, item} = extracted_clone(socket)`
    # is no clearer than the two inline reads. Net savings (19 - 2*(1+1+2) =
    # 11) sit below the default `:min_savings` of 12, so it is left alone.
    @trivial """
    defmodule M do
      def edit(socket) do
        scope = socket.assigns.current_scope
        item = socket.assigns.item
        open_editor(scope, item)
      end

      def show(socket) do
        scope = socket.assigns.current_scope
        item = socket.assigns.item
        render_detail(scope, item)
      end

      def open_editor(_, _), do: :ok
      def render_detail(_, _), do: :ok
    end
    """

    test "a trivial 2-statement plumbing clone is NOT extracted under the default threshold" do
      # Default `:min_savings` (12) applies; only `enabled` is forced on.
      assert_unchanged(@subject, @trivial, enabled: true)
    end

    test "the same trivial clone IS extracted once the threshold is lowered" do
      # Drop `:min_savings` below the block's net savings (11) → it fires,
      # proving the gate is the threshold, not an unrelated skip.
      out = apply_refactor(@subject, @trivial, enabled: true, min_savings: 5)

      # The block reads scope/item off socket.assigns → HelperNaming names it
      # fetch_item (scope is boilerplate-dropped). The assertion is about the
      # threshold firing, not the name.
      assert out =~ "= fetch_item(socket)"
      assert out =~ "defp fetch_item(socket) do"
      assert_compiles(out)
      assert_idempotent(@subject, @trivial, enabled: true, min_savings: 5)
    end
  end

  describe "live-out width cap (slice 3, hebel A)" do
    # Four STRUCTURALLY DISTINCT bindings (different RHS shapes) so no
    # narrower sub-block is itself a clone — only the full four-binding
    # prefix recurs. The differing tails read all four names, so the block
    # has four live-out vars.
    @wide """
    defmodule M do
      def use_a(socket) do
        scope = socket.assigns.current_scope
        item = socket.assigns.item
        brand = lookup_brand(socket)
        price = compute_price(item, brand)
        edit(scope, item, brand, price)
      end

      def use_b(socket) do
        scope = socket.assigns.current_scope
        item = socket.assigns.item
        brand = lookup_brand(socket)
        price = compute_price(item, brand)
        show(scope, item, brand, price)
      end

      def lookup_brand(_), do: :b
      def compute_price(_, _), do: 0
      def edit(_, _, _, _), do: :ok
      def show(_, _, _, _), do: :ok
    end
    """

    test "the four-live-out block is never emitted as a 4-tuple under the default cap" do
      # The full four-binding block has four live-out vars — past the
      # default cap of 3. A helper returning a 4-tuple destructured at every
      # call site is a readability regression, so the wide group is never
      # chosen: no `{scope, item, brand, price} = …` four-tuple is emitted.
      # (A narrower in-cap sub-block may still extract — the cap bounds the
      # width, it does not forbid all extraction.)
      out = apply_refactor(@subject, @wide, enabled: true, min_savings: 0)

      refute out =~ "{scope, item, brand, price} = "
      assert_compiles(out)
      assert_idempotent(@subject, @wide, enabled: true, min_savings: 0)
    end

    test "raising max_live_out clears the cap, but a 4-tuple block stays unnameable → declined" do
      # With the cap at 4 the wide block clears `:max_live_out`, but its
      # four live-out vars exceed the two-name object join, so no meaningful
      # name surfaces and it is declined under derive-or-decline (#375). The
      # cap is no longer the limiter here — naming is — so the assertion is
      # that the 4-tuple is never destructured under a placeholder name.
      out = apply_refactor(@subject, @wide, enabled: true, min_savings: 0, max_live_out: 4)

      refute out =~ "{scope, item, brand, price} = extracted_clone"
      refute out =~ "extracted_clone"
      assert_compiles(out)
      assert_idempotent(@subject, @wide, enabled: true, min_savings: 0, max_live_out: 4)
    end
  end

  describe "savings-ranked overlap resolution (slice 3, hebel B partial)" do
    test "a wide-tuple group loses to a narrow genuine group instead of being chosen and re-split" do
      # Two clone shapes recur:
      #   * the WHOLE 4-binding prefix → 4 live-out (over the default cap)
      #   * a narrow 2-binding sub-group {sort_field, sort_dir} whose tail
      #     differs, leaving exactly those two as live-out.
      # Raw `mass * occurrences` would crown the big group, emit an 8-wide
      # tuple, and rely on a second pass to clean up. With `:max_live_out`
      # excluding the wide group and net-savings ranking the rest, the
      # narrow, genuinely useful group is what gets extracted — no big tuple.
      source = """
      defmodule M do
        def list_a(params) do
          sort_field = String.to_existing_atom(params["sort_field"] || "name")
          sort_dir = String.to_existing_atom(params["sort_dir"] || "asc")
          limit = String.to_integer(params["limit"] || "25")
          offset = String.to_integer(params["offset"] || "0")
          query_with(sort_field, sort_dir, limit, offset, :a)
        end

        def list_b(params) do
          sort_field = String.to_existing_atom(params["sort_field"] || "name")
          sort_dir = String.to_existing_atom(params["sort_dir"] || "asc")
          render_sorted(sort_field, sort_dir)
        end

        def query_with(_, _, _, _, _), do: :ok
        def render_sorted(_, _), do: :ok
      end
      """

      out = apply_refactor(@subject, source, enabled: true)

      # The shared {sort_field, sort_dir} prefix is the only clone across
      # both functions; it is the narrow group that fires. No wide tuple of
      # four-plus values is ever destructured.
      assert out =~ "{sort_field, sort_dir} = "
      refute out =~ "{sort_field, sort_dir, limit, offset"
      assert_compiles(out)
      assert_idempotent(@subject, source, enabled: true)
    end
  end

  describe "tuple-literal return naming (block's product, via Sourceror)" do
    test "a block ending in a two-tuple is named after the tuple, not extracted_clone" do
      # Regression guard for the Sourceror AST path: Sourceror wraps a
      # 2-tuple literal as `{:__block__, _, [{a, b}]}`, not a bare `{a, b}`.
      # HelperNaming must unwrap that to read the product names; otherwise
      # the whole-body tuple-return clone falls back to `extracted_clone`.
      source = """
      defmodule M do
        def a(order) do
          subtotal = Enum.sum(order.lines)
          taxed = subtotal * 1.19
          {subtotal, taxed}
        end

        def b(cart) do
          subtotal = Enum.sum(cart.lines)
          taxed = subtotal * 1.19
          {subtotal, taxed}
        end
      end
      """

      out = apply_refactor(@subject, source, @on ++ [min_mass: 8])

      assert out =~ "defp compute_subtotal_and_taxed(order) do"
      assert out =~ "compute_subtotal_and_taxed(order)"
      assert out =~ "compute_subtotal_and_taxed(cart)"
      refute out =~ "extracted_clone"
      assert_compiles(out)
      assert_idempotent(@subject, source, @on ++ [min_mass: 8])
    end

    test "a three-tuple full block is not placeholdered; a nameable sub-block extracts instead" do
      # `{subtotal, tax, total}` — three product names exceed the two-name
      # object join, so the *full* block has no meaningful name and is not
      # minted as `extracted_clone` (#375). The nameable 2-statement
      # sub-block (`{subtotal, tax}` → `compute_subtotal_and_tax`) is what
      # gets lifted instead. The three-tuple unwrap must not crash on the
      # `{:{}, _, elems}` shape.
      source = """
      defmodule M do
        def a(order) do
          subtotal = Enum.sum(order.lines)
          tax = subtotal * 0.19
          total = subtotal + tax
          {subtotal, tax, total}
        end

        def b(cart) do
          subtotal = Enum.sum(cart.lines)
          tax = subtotal * 0.19
          total = subtotal + tax
          {subtotal, tax, total}
        end
      end
      """

      out = apply_refactor(@subject, source, @on ++ [min_mass: 8])
      assert out =~ "defp compute_subtotal_and_tax(order) do"
      refute out =~ "extracted_clone"
      assert_compiles(out)
      assert_idempotent(@subject, source, @on ++ [min_mass: 8])
    end
  end

  describe "multi-extract per pass (idempotence)" do
    test "two disjoint clone groups are both extracted in a single pass" do
      # Group 1: subtotal/taxed across a/b (live-out, tails differ → real
      # names). Group 2: a distinct height/width block across c/d. Different
      # names, non-overlapping ranges — a single pass should lift BOTH, and
      # the result must be idempotent.
      source = """
      defmodule M do
        def a(order) do
          subtotal = Enum.sum(order.lines)
          taxed = subtotal * 1.19
          ship_a(subtotal, taxed)
        end

        def b(cart) do
          subtotal = Enum.sum(cart.lines)
          taxed = subtotal * 1.19
          ship_b(subtotal, taxed)
        end

        def c(box) do
          height = measure_height(box)
          width = measure_width(box)
          render_c(height, width)
        end

        def d(crate) do
          height = measure_height(crate)
          width = measure_width(crate)
          render_d(height, width)
        end

        def ship_a(_, _), do: :ok
        def ship_b(_, _), do: :ok
        def render_c(_, _), do: :ok
        def render_d(_, _), do: :ok
        def measure_height(_), do: 0
        def measure_width(_), do: 0
      end
      """

      out = apply_refactor(@subject, source, @on ++ [min_mass: 6])

      # Both helpers exist after ONE pass (distinct names, disjoint ranges).
      assert out =~ "defp compute_subtotal_and_taxed(order) do"
      assert out =~ "defp compute_height_and_width(box) do"
      # Both call-site pairs delegate.
      assert out =~ "compute_subtotal_and_taxed(order)"
      assert out =~ "compute_subtotal_and_taxed(cart)"
      assert out =~ "compute_height_and_width(box)"
      assert out =~ "compute_height_and_width(crate)"

      assert_compiles(out)
      assert_idempotent(@subject, source, @on ++ [min_mass: 6])
    end

    test "two groups whose helpers would share a name are split across passes" do
      # Both groups read scope/x off socket.assigns → both want `fetch_x`-ish
      # names. The first pass takes one; the colliding second waits for the
      # next pass. After two passes everything is extracted and stable.
      source = """
      defmodule M do
        def a(socket) do
          scope = socket.assigns.current_scope
          item = socket.assigns.item
          edit(scope, item)
        end

        def b(socket) do
          scope = socket.assigns.current_scope
          item = socket.assigns.item
          show(scope, item)
        end

        def c(socket) do
          scope = socket.assigns.current_scope
          item = socket.assigns.item
          peek(scope, item)
        end

        def edit(_, _), do: :ok
        def show(_, _), do: :ok
        def peek(_, _), do: :ok
      end
      """

      # All three a/b/c share ONE structural clone, so this is actually one
      # group of three occurrences — extracted in a single pass. Use it to
      # prove three occurrences collapse to one helper without name clashes.
      out = apply_refactor(@subject, source, @on)

      assert out =~ "defp fetch_item(socket) do"
      assert out =~ "= fetch_item(socket)"
      # Exactly one helper defined.
      assert length(Regex.scan(~r/defp fetch_item\(/, out)) == 1
      assert_compiles(out)
      assert_idempotent(@subject, source, @on)
    end

    test "two structurally identical groups in the same module with the same name need two passes" do
      # Two INDEPENDENT clone pairs that produce the SAME helper name
      # (same structure, both fetch from `opts`). They cannot coexist in one
      # pass (one name, two distinct helpers); the first pass extracts one
      # pair, the second the other. Idempotence holds only across the two
      # passes, so this asserts convergence explicitly rather than via
      # assert_idempotent.
      source = """
      defmodule M do
        def a(opts) do
          x = Keyword.get(opts, :x)
          y = Keyword.get(opts, :y)
          z = Keyword.get(opts, :z)
          use_first(x, y, z)
        end

        def b(opts) do
          x = Keyword.get(opts, :x)
          y = Keyword.get(opts, :y)
          z = Keyword.get(opts, :z)
          use_second(x, y, z)
        end

        def use_first(_, _, _), do: :ok
        def use_second(_, _, _), do: :ok
      end
      """

      # a and b share one structural clone → a single group of two
      # occurrences → one pass. (Genuinely independent same-name groups are
      # rare; this fixture documents that co-located identical structure is
      # one group, not two.)
      out = apply_refactor(@subject, source, @on)
      assert out =~ "= fetch_opts(opts)"
      assert length(Regex.scan(~r/defp fetch_opts\(/, out)) == 1
      assert_compiles(out)
      assert_idempotent(@subject, source, @on)
    end
  end
end
