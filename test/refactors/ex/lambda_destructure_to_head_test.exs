defmodule Number42.Refactors.Ex.LambdaDestructureToHeadTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.LambdaDestructureToHead

  @subject LambdaDestructureToHead

  describe "rewrites — lambda head lift" do
    test "tuple destructure of the param moves into the head" do
      assert_rewrites(
        @subject,
        """
        Enum.map(pairs, fn pair ->
          {key, value} = pair
          process(key, value)
        end)
        """,
        "Enum.map(pairs, fn {key, value} -> process(key, value) end)"
      )
    end

    test "map destructure moves into the head" do
      assert_rewrites(
        @subject,
        """
        Enum.each(users, fn user ->
          %{id: id, name: name} = user
          notify(id, name)
        end)
        """,
        "Enum.each(users, fn %{id: id, name: name} -> notify(id, name) end)"
      )
    end

    test "struct destructure moves into the head" do
      assert_rewrites(
        @subject,
        """
        Enum.map(items, fn item ->
          %Item{sku: sku} = item
          lookup(sku)
        end)
        """,
        "Enum.map(items, fn %Item{sku: sku} -> lookup(sku) end)"
      )
    end

    test "several trailing statements are kept" do
      assert_rewrites(
        @subject,
        """
        Enum.map(pairs, fn pair ->
          {a, b} = pair
          x = a + b
          x * 2
        end)
        """,
        """
        Enum.map(pairs, fn {a, b} ->
          x = a + b
          x * 2
        end)
        """
      )
    end

    test "standalone lambda outside any host fn is lifted too" do
      assert_rewrites(
        @subject,
        """
        fn point ->
          {x, y} = point
          dist(x, y)
        end
        """,
        "fn {x, y} -> dist(x, y) end"
      )
    end
  end

  describe "rewrites — for comprehension generator lift" do
    test "single generator destructure moves onto the <-" do
      assert_rewrites(
        @subject,
        """
        for pair <- pairs do
          {key, value} = pair
          process(key, value)
        end
        """,
        """
        for {key, value} <- pairs do
          process(key, value)
        end
        """
      )
    end

    test "the matched generator among several is the one lifted" do
      assert_rewrites(
        @subject,
        """
        for a <- as, b <- bs do
          {k, v} = b
          f(a, k, v)
        end
        """,
        """
        for a <- as, {k, v} <- bs do
          f(a, k, v)
        end
        """
      )
    end
  end

  describe "leaves alone" do
    test "param re-used as a whole after the destructure" do
      assert_unchanged(@subject, """
      Enum.map(pairs, fn pair ->
        {key, value} = pair
        store(pair, key, value)
      end)
      """)
    end

    test "param destructured twice (re-use counts the second match)" do
      assert_unchanged(@subject, """
      Enum.map(pairs, fn pair ->
        {a, _} = pair
        {_, b} = pair
        f(a, b)
      end)
      """)
    end

    test "no destructure — first statement is an ordinary binding" do
      assert_unchanged(@subject, """
      Enum.map(nums, fn n ->
        doubled = n * 2
        doubled + 1
      end)
      """)
    end

    test "bare rename is not a destructure" do
      assert_unchanged(@subject, """
      Enum.map(xs, fn x ->
        y = x
        y + 1
      end)
      """)
    end

    test "already lifted head pattern" do
      assert_unchanged(@subject, "Enum.map(pairs, fn {key, value} -> process(key, value) end)")
    end

    test "already lifted for generator" do
      assert_unchanged(@subject, """
      for {key, value} <- pairs do
        process(key, value)
      end
      """)
    end

    test "destructure is not the first statement" do
      assert_unchanged(@subject, """
      Enum.map(pairs, fn pair ->
        log(:start)
        {a, b} = pair
        f(a, b)
      end)
      """)
    end

    test "for where the param is shared by another clause" do
      assert_unchanged(@subject, """
      for pair <- pairs, valid?(pair) do
        {k, v} = pair
        f(k, v)
      end
      """)
    end

    test "pattern re-binds the param's own name" do
      assert_unchanged(@subject, """
      Enum.map(pairs, fn pair ->
        {pair, rest} = pair
        f(pair, rest)
      end)
      """)
    end
  end

  describe "idempotent" do
    test "lambda lift run twice equals once" do
      assert_idempotent(@subject, """
      Enum.map(pairs, fn pair ->
        {key, value} = pair
        process(key, value)
      end)
      """)
    end

    test "for lift run twice equals once" do
      assert_idempotent(@subject, """
      for pair <- pairs do
        {key, value} = pair
        process(key, value)
      end
      """)
    end

    test "nested lambdas both lift across passes" do
      source = """
      Enum.map(rows, fn row ->
        {a, b} = row
        Enum.map(a, fn pair ->
          {k, v} = pair
          g(k, v, b)
        end)
      end)
      """

      assert_idempotent(@subject, source)
    end
  end

  describe "compiles" do
    test "lifted lambda is valid Elixir" do
      lifted =
        apply_refactor(@subject, """
        defmodule M do
          def run(pairs) do
            Enum.map(pairs, fn pair ->
              {key, value} = pair
              process(key, value)
            end)
          end

          defp process(k, v), do: {k, v}
        end
        """)

      assert_compiles(lifted)
    end

    test "lifted for comprehension is valid Elixir" do
      lifted =
        apply_refactor(@subject, """
        defmodule N do
          def run(pairs) do
            for pair <- pairs do
              {key, value} = pair
              {value, key}
            end
          end
        end
        """)

      assert_compiles(lifted)
    end
  end
end
