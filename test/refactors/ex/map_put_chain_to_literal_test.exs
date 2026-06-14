defmodule Number42.Refactors.Ex.MapPutChainToLiteralTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.MapPutChainToLiteral

  @mod MapPutChainToLiteral

  describe "collapses %{}-seeded Map.put chains" do
    test "atom-key chain ending in a read becomes a bare keyword-style literal" do
      before = """
      def build_payload(user) do
        payload = %{}
        payload = Map.put(payload, :id, user.id)
        payload = Map.put(payload, :name, user.name)
        payload = Map.put(payload, :email, user.email)
        payload
      end
      """

      expected = """
      def build_payload(user) do
        %{id: user.id, name: user.name, email: user.email}
      end
      """

      assert_rewrites(@mod, before, expected)
    end

    test "two-put chain with trailing read collapses to bare literal" do
      before = """
      m = %{}
      m = Map.put(m, :a, 1)
      m = Map.put(m, :b, 2)
      m
      """

      expected = """
      %{a: 1, b: 2}
      """

      assert_rewrites(@mod, before, expected)
    end

    test "chain that is the block tail (no trailing read) collapses to bare literal" do
      before = """
      def build do
        acc = %{}
        acc = Map.put(acc, :x, 1)
        acc = Map.put(acc, :y, 2)
      end
      """

      expected = """
      def build do
        %{x: 1, y: 2}
      end
      """

      assert_rewrites(@mod, before, expected)
    end

    test "duplicate keys keep last-write-wins order" do
      before = """
      m = %{}
      m = Map.put(m, :a, 1)
      m = Map.put(m, :a, 2)
      m
      """

      expected = """
      %{a: 1, a: 2}
      """

      assert_rewrites(@mod, before, expected)
    end

    test "dynamic (variable) key renders all-arrow literal" do
      before = """
      m = %{}
      m = Map.put(m, k, v)
      m = Map.put(m, :b, 2)
      m
      """

      expected = """
      %{k => v, :b => 2}
      """

      assert_rewrites(@mod, before, expected)
    end

    test "string keys render all-arrow literal" do
      before = ~S'''
      m = %{}
      m = Map.put(m, "a", 1)
      m = Map.put(m, "b", 2)
      m
      '''

      expected = ~S'''
      %{"a" => 1, "b" => 2}
      '''

      assert_rewrites(@mod, before, expected)
    end
  end

  describe "leaves alone" do
    test "interleaved read of the chain variable between puts" do
      source = """
      m = %{}
      m = Map.put(m, :a, 1)
      IO.inspect(m)
      m = Map.put(m, :b, 2)
      m
      """

      assert_unchanged(@mod, source)
    end

    test "value that depends on the chain variable" do
      source = """
      m = %{}
      m = Map.put(m, :a, 1)
      m = Map.put(m, :b, map_size(m))
      m
      """

      assert_unchanged(@mod, source)
    end

    test "chain variable used again after the trailing read" do
      source = """
      m = %{}
      m = Map.put(m, :a, 1)
      m = Map.put(m, :b, 2)
      send(self(), m)
      log(m)
      """

      assert_unchanged(@mod, source)
    end

    test "mixed chain with a non-Map.put step (PipelineFromRebindChain territory)" do
      source = """
      m = %{}
      m = Map.put(m, :a, 1)
      m = Map.merge(m, other)
      m
      """

      assert_unchanged(@mod, source)
    end

    test "chain not seeded by an empty map" do
      source = """
      m = %{existing: true}
      m = Map.put(m, :a, 1)
      m = Map.put(m, :b, 2)
      m
      """

      assert_unchanged(@mod, source)
    end

    test "single Map.put after seed (no chain of two)" do
      source = """
      m = %{}
      m = Map.put(m, :a, 1)
      m
      """

      assert_unchanged(@mod, source)
    end

    test "Map.put_new conditional build stays a chain" do
      source = """
      m = %{}
      m = Map.put_new(m, :a, 1)
      m = Map.put_new(m, :b, 2)
      m
      """

      assert_unchanged(@mod, source)
    end

    test "rebinds of a different variable" do
      source = """
      m = %{}
      n = Map.put(m, :a, 1)
      n = Map.put(n, :b, 2)
      n
      """

      assert_unchanged(@mod, source)
    end

    test "already a map literal" do
      source = """
      m = %{a: 1, b: 2}
      """

      assert_unchanged(@mod, source)
    end
  end

  describe "idempotence and compilation" do
    test "idempotent on a collapsible chain" do
      source = """
      def build(user) do
        m = %{}
        m = Map.put(m, :id, user.id)
        m = Map.put(m, :name, user.name)
        m
      end
      """

      assert_idempotent(@mod, source)
    end

    test "output compiles" do
      source = """
      defmodule M do
        def build(user) do
          m = %{}
          m = Map.put(m, :id, user.id)
          m = Map.put(m, :name, user.name)
          m
        end

        def dyn(k, v) do
          m = %{}
          m = Map.put(m, k, v)
          m = Map.put(m, :b, 2)
          m
        end
      end
      """

      assert_compiles(apply_refactor(@mod, source))
    end
  end
end
