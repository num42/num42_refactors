defmodule Number42.Refactors.Ex.MapGetUnsafePassTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.MapGetUnsafePass

  @subject MapGetUnsafePass

  describe "rewrites" do
    test "Map.get(x, :k, nil) -> Map.get(x, :k)" do
      assert_rewrites(@subject, "Map.get(x, :k, nil)", "Map.get(x, :k)")
    end

    test "Keyword.get(x, :k, nil) -> Keyword.get(x, :k)" do
      assert_rewrites(@subject, "Keyword.get(x, :k, nil)", "Keyword.get(x, :k)")
    end

    test "pipe form: x |> Map.get(:k, nil) -> x |> Map.get(:k)" do
      assert_rewrites(@subject, "x |> Map.get(:k, nil)", "x |> Map.get(:k)")
    end

    test "pipe form: x |> Keyword.get(:k, nil) -> x |> Keyword.get(:k)" do
      assert_rewrites(@subject, "x |> Keyword.get(:k, nil)", "x |> Keyword.get(:k)")
    end

    test "string key works too" do
      assert_rewrites(@subject, ~s|Map.get(x, "k", nil)|, ~s|Map.get(x, "k")|)
    end

    test "variable key works too" do
      assert_rewrites(@subject, "Map.get(x, key, nil)", "Map.get(x, key)")
    end
  end

  describe "leaves alone" do
    test "Map.get with non-nil default" do
      assert_unchanged(@subject, "Map.get(x, :k, :default)")
    end

    test "Map.get with empty list default" do
      assert_unchanged(@subject, "Map.get(x, :k, [])")
    end

    test "Map.get with arity 2 (no default)" do
      assert_unchanged(@subject, "Map.get(x, :k)")
    end

    test "Map.fetch (different function)" do
      assert_unchanged(@subject, "Map.fetch(x, :k)")
    end

    test "other module's get" do
      assert_unchanged(@subject, "MyMap.get(x, :k, nil)")
    end
  end

  describe "idempotent" do
    test "rewrites only once" do
      assert_idempotent(@subject, "Map.get(x, :k, nil)")
    end

    test "already rewritten" do
      assert_idempotent(@subject, "Map.get(x, :k)")
    end
  end
end
