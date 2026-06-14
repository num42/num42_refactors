defmodule Number42.Refactors.Ex.DropTrailingReturnBindingTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.DropTrailingReturnBinding

  @subject DropTrailingReturnBinding

  describe "rewrites" do
    test "defp body: drops the return shim" do
      before_source = """
      defp something(some) do
        x = prep(some)
        result = compute(x)
        result
      end
      """

      after_source = """
      defp something(some) do
        x = prep(some)
        compute(x)
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "def body: drops the return shim" do
      before_source = """
      def run(arg) do
        out = handle(arg)
        out
      end
      """

      after_source = """
      def run(arg) do
        handle(arg)
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "fn body: drops the return shim" do
      before_source = """
      fn x ->
        y = transform(x)
        y
      end
      """

      after_source = """
      fn x ->
        transform(x)
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "case arm body: drops the return shim" do
      before_source = """
      case input do
        :a ->
          v = build(:a)
          v

        _ ->
          other()
      end
      """

      after_source = """
      case input do
        :a ->
          build(:a)

        _ ->
          other()
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "impure / side-effecting rhs still rewrites" do
      before_source = """
      def persist(attrs) do
        record = Repo.insert!(attrs)
        record
      end
      """

      after_source = """
      def persist(attrs) do
        Repo.insert!(attrs)
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "leaves alone" do
    test "binding variable is also read earlier in the block" do
      assert_unchanged(@subject, """
      def f(x) do
        result = compute(x)
        log(result)
        result
      end
      """)
    end

    test "pattern-match LHS is kept" do
      assert_unchanged(@subject, """
      def f(x) do
        {:ok, v} = fetch(x)
        v
      end
      """)
    end

    test "struct-pattern LHS is kept" do
      assert_unchanged(@subject, """
      def f(x) do
        %User{} = u = load(x)
        u
      end
      """)
    end

    test "return var differs from bound var" do
      assert_unchanged(@subject, """
      def f(x) do
        a = compute(x)
        b
      end
      """)
    end

    test "single-statement block has nothing to drop" do
      assert_unchanged(@subject, """
      def f(x) do
        compute(x)
      end
      """)
    end

    test "binding variable appears in its own rhs" do
      assert_unchanged(@subject, """
      def f(result) do
        result = wrap(result)
        result
      end
      """)
    end

    test "last statement is a call, not a bare var" do
      assert_unchanged(@subject, """
      def f(x) do
        result = compute(x)
        finish(result)
      end
      """)
    end
  end

  describe "idempotent" do
    test "second pass is a no-op after dropping a shim" do
      assert_idempotent(@subject, """
      def f(x) do
        result = compute(x)
        result
      end
      """)
    end

    test "already-clean body is unchanged" do
      assert_idempotent(@subject, """
      def f(x) do
        compute(x)
      end
      """)
    end
  end
end
