defmodule Number42.Refactors.Ex.ReduceToNamedAggregateTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ReduceToNamedAggregate

  @subject ReduceToNamedAggregate

  describe "group_by" do
    test "Map.update list-cons (explicit fold fun) -> Enum.group_by/2" do
      assert_rewrites(
        @subject,
        """
        Enum.reduce(orders, %{}, fn order, acc ->
          Map.update(acc, order.customer_id, [order], fn existing -> [order | existing] end)
        end)
        """,
        "Enum.group_by(orders, fn order -> order.customer_id end)"
      )
    end

    test "Map.update list-cons (capture fold fun) -> Enum.group_by/2" do
      assert_rewrites(
        @subject,
        """
        Enum.reduce(orders, %{}, fn order, acc ->
          Map.update(acc, order.customer_id, [order], &[order | &1])
        end)
        """,
        "Enum.group_by(orders, fn order -> order.customer_id end)"
      )
    end

    test "grouped value differs from element -> Enum.group_by/3 with value fun" do
      assert_rewrites(
        @subject,
        """
        Enum.reduce(orders, %{}, fn order, acc ->
          Map.update(acc, order.customer_id, [order.total], &[order.total | &1])
        end)
        """,
        "Enum.group_by(orders, fn order -> order.customer_id end, fn order -> order.total end)"
      )
    end

    test "pipe form -> piped Enum.group_by" do
      assert_rewrites(
        @subject,
        """
        orders
        |> Enum.reduce(%{}, fn order, acc ->
          Map.update(acc, order.customer_id, [order], &[order | &1])
        end)
        """,
        "orders |> Enum.group_by(fn order -> order.customer_id end)"
      )
    end
  end

  describe "frequencies_by" do
    test "Map.update +1 (capture) -> Enum.frequencies_by/2" do
      assert_rewrites(
        @subject,
        """
        Enum.reduce(events, %{}, fn event, acc ->
          Map.update(acc, event.type, 1, &(&1 + 1))
        end)
        """,
        "Enum.frequencies_by(events, fn event -> event.type end)"
      )
    end

    test "Map.update +1 (explicit fold fun) -> Enum.frequencies_by/2" do
      assert_rewrites(
        @subject,
        """
        Enum.reduce(events, %{}, fn event, acc ->
          Map.update(acc, event.type, 1, fn c -> c + 1 end)
        end)
        """,
        "Enum.frequencies_by(events, fn event -> event.type end)"
      )
    end
  end

  describe "product_by" do
    test "acc * value -> Enum.product_by/2" do
      assert_rewrites(
        @subject,
        "Enum.reduce(factors, 1, fn factor, acc -> acc * factor.weight end)",
        "Enum.product_by(factors, fn factor -> factor.weight end)"
      )
    end

    test "value * acc (commutative) -> Enum.product_by/2" do
      assert_rewrites(
        @subject,
        "Enum.reduce(factors, 1, fn factor, acc -> factor.weight * acc end)",
        "Enum.product_by(factors, fn factor -> factor.weight end)"
      )
    end
  end

  describe "leaves alone" do
    test "the sum case (owned by EnumReduceToSum)" do
      assert_unchanged(@subject, "Enum.reduce(items, 0, fn item, acc -> acc + item.qty end)")
    end

    test "the Map.put map-build case (owned by ReduceMapPut)" do
      assert_unchanged(
        @subject,
        "Enum.reduce(batch, %{}, fn event, acc -> Map.put(acc, event.id, event) end)"
      )
    end

    test "non-empty-map seed for group_by (would drop existing entries)" do
      assert_unchanged(
        @subject,
        """
        Enum.reduce(orders, existing, fn order, acc ->
          Map.update(acc, order.customer_id, [order], &[order | &1])
        end)
        """
      )
    end

    test "wrong seed for product (semantic difference)" do
      assert_unchanged(
        @subject,
        "Enum.reduce(factors, 2, fn factor, acc -> acc * factor.weight end)"
      )
    end

    test "ambiguous body: extra statement before the Map.update" do
      assert_unchanged(
        @subject,
        """
        Enum.reduce(events, %{}, fn event, acc ->
          IO.inspect(event)
          Map.update(acc, event.type, 1, &(&1 + 1))
        end)
        """
      )
    end

    test "frequencies default mismatch (default is not 1)" do
      assert_unchanged(
        @subject,
        """
        Enum.reduce(events, %{}, fn event, acc ->
          Map.update(acc, event.type, 0, &(&1 + 1))
        end)
        """
      )
    end

    test "group_by seed-elem differs from cons-elem (not a clean group_by)" do
      assert_unchanged(
        @subject,
        """
        Enum.reduce(orders, %{}, fn order, acc ->
          Map.update(acc, order.customer_id, [order.id], &[order | &1])
        end)
        """
      )
    end

    test "constant key not referencing the element" do
      assert_unchanged(
        @subject,
        """
        Enum.reduce(events, %{}, fn event, acc ->
          Map.update(acc, :total, 1, &(&1 + 1))
        end)
        """
      )
    end

    test "already Enum.group_by" do
      assert_unchanged(@subject, "Enum.group_by(orders, & &1.customer_id)")
    end

    test "already Enum.frequencies_by" do
      assert_unchanged(@subject, "Enum.frequencies_by(events, & &1.type)")
    end
  end

  describe "idempotent" do
    test "group_by runs twice equals once" do
      assert_idempotent(
        @subject,
        """
        Enum.reduce(orders, %{}, fn order, acc ->
          Map.update(acc, order.customer_id, [order], &[order | &1])
        end)
        """
      )
    end

    test "frequencies_by runs twice equals once" do
      assert_idempotent(
        @subject,
        """
        Enum.reduce(events, %{}, fn event, acc ->
          Map.update(acc, event.type, 1, &(&1 + 1))
        end)
        """
      )
    end

    test "product_by runs twice equals once" do
      assert_idempotent(
        @subject,
        "Enum.reduce(factors, 1, fn factor, acc -> acc * factor.weight end)"
      )
    end
  end

  describe "assert_compiles" do
    test "group_by output compiles" do
      out =
        apply_refactor(@subject, """
        defmodule M do
          def f(orders) do
            Enum.reduce(orders, %{}, fn order, acc ->
              Map.update(acc, order.customer_id, [order], &[order | &1])
            end)
          end
        end
        """)

      assert_compiles(out)
    end

    test "frequencies_by output compiles" do
      out =
        apply_refactor(@subject, """
        defmodule M do
          def f(events) do
            Enum.reduce(events, %{}, fn event, acc ->
              Map.update(acc, event.type, 1, &(&1 + 1))
            end)
          end
        end
        """)

      assert_compiles(out)
    end

    test "product_by output compiles" do
      out =
        apply_refactor(@subject, """
        defmodule M do
          def f(factors) do
            Enum.reduce(factors, 1, fn factor, acc -> acc * factor.weight end)
          end
        end
        """)

      assert_compiles(out)
    end
  end
end
