defmodule Number42.Refactors.Ex.ExtractExpressionCloneTest do
  @moduledoc """
  PROTOTYPE tests for expression-level clone extraction.

  Focus of the PoC (not a full suite): prove that a sub-expression shared
  across two functions is detected, lifted into a shared `defp`, and that
  the result compiles; plus that the conservative safety gates fire.
  """
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractExpressionClone

  @subject ExtractExpressionClone

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

      out = apply_refactor(@subject, source, min_mass: 8)

      # Both call sites now delegate to one shared helper.
      assert out =~ "def a(order) do"
      assert out =~ "extracted_clone(order)"
      assert out =~ "extracted_clone(cart)"
      assert out =~ "defp extracted_clone(order) do"

      # The free variable became the single helper parameter, threaded
      # positionally at each call site (a(order) -> order, b(cart) -> cart).
      assert_compiles(out)
      assert_idempotent(@subject, source, min_mass: 8)
    end

    test "a PARTIAL sub-block (tail only) is extracted even when prefixes differ" do
      # The key expression-level capability: the shared clone is only the
      # last two statements; the leading statements differ between a and b.
      # The function-level finders would never see this.
      source = """
      defmodule M do
        def log(_), do: :ok
        def audit(_, _), do: :ok
        def shipping(o), do: o.ship

        def a(order) do
          log(order)
          base = order.amount
          base * 1.19 + shipping(order)
        end

        def b(cart, note) do
          audit(cart, note)
          base = cart.amount
          base * 1.19 + shipping(cart)
        end
      end
      """

      out = apply_refactor(@subject, source, min_mass: 6)

      # Only the shared tail moved into the helper; the distinct prefixes
      # (log/audit) stay put.
      assert out =~ "log(order)"
      assert out =~ "audit(cart, note)"
      assert out =~ "defp extracted_clone(order) do"
      assert out =~ "base = order.amount"
      refute out =~ "defp extracted_clone(cart)"

      assert_compiles(out)
      assert_idempotent(@subject, source, min_mass: 6)
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

      assert_unchanged(@subject, source, min_mass: 5)
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

      assert_unchanged(@subject, source, min_mass: 5)
    end
  end

  describe "live-out via value return (slice 1)" do
    test "a shared block binding ONE live-out var returns it bare and destructures at each call" do
      # The shared block is the first two statements; the tails differ
      # (log_invoice vs store_total) so the clone is the prefix only, and
      # the bound `taxed` is read by each differing tail — a single
      # live-out, returned bare.
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

      out = apply_refactor(@subject, source, min_mass: 6)

      # Bare return, not a tuple — one live-out var.
      assert out =~ "taxed = extracted_clone(order)"
      assert out =~ "taxed = extracted_clone(cart)"
      assert out =~ "defp extracted_clone(order) do"
      refute out =~ "{taxed} = extracted_clone"
      # Differing tails stay put; the helper hands `taxed` back to them.
      assert out =~ "log_invoice(taxed)"
      assert out =~ "store_total(taxed)"

      assert_compiles(out)
      assert_idempotent(@subject, source, min_mass: 6)
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

      out = apply_refactor(@subject, source, min_mass: 6)

      # Tuple return + destructure, in canonical (first-appearance) order:
      # subtotal before taxed at every site and in the helper return.
      assert out =~ "{subtotal, taxed} = extracted_clone(order)"
      assert out =~ "{subtotal, taxed} = extracted_clone(cart)"
      assert out =~ "defp extracted_clone(order) do"
      assert out =~ "{subtotal, taxed}\n  end"

      assert_compiles(out)
      assert_idempotent(@subject, source, min_mass: 6)
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

      once = apply_refactor(@subject, source, min_mass: 6)
      assert_compiles(once)
      # Convergence: the extracted output is a fixpoint.
      assert_unchanged(@subject, once, min_mass: 6)
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

      assert_unchanged(@subject, source, min_mass: 6)
    end
  end
end
