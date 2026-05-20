defmodule Num42.Refactors.Refactors.TryRescueWithSafeAlternativeTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.TryRescueWithSafeAlternative

  @subject TryRescueWithSafeAlternative

  # The refactor only fires when the rescue clause uses a wildcard
  # pattern (`_` or `_foo`). A typed rescue (`KeyError -> ...`) is
  # left alone — the typed catch is a meaningful narrowing the
  # rewrite wouldn't preserve.
  describe "rewrites" do
    test "try/rescue with wildcard around Map.fetch! becomes Map.get" do
      before_source = """
      try do
        Map.fetch!(map, :k)
      rescue
        _ -> :default
      end
      """

      assert_rewrites(@subject, before_source, "Map.get(map, :k, :default)")
    end

    test "try/rescue with wildcard around Keyword.fetch! becomes Keyword.get" do
      before_source = """
      try do
        Keyword.fetch!(opts, :k)
      rescue
        _ -> :default
      end
      """

      assert_rewrites(@subject, before_source, "Keyword.get(opts, :k, :default)")
    end

    test "underscore-prefixed binding is treated as wildcard" do
      before_source = """
      try do
        Map.fetch!(map, :k)
      rescue
        _e -> :default
      end
      """

      assert_rewrites(@subject, before_source, "Map.get(map, :k, :default)")
    end
  end

  describe "leaves alone" do
    test "typed rescue (KeyError) is left alone" do
      assert_unchanged(@subject, """
      try do
        Map.fetch!(map, :k)
      rescue
        KeyError -> :default
      end
      """)
    end

    test "try/rescue around something other than Map/Keyword.fetch!" do
      assert_unchanged(@subject, """
      try do
        do_risky_thing()
      rescue
        _ -> :default
      end
      """)
    end

    test "try/rescue with multiple rescue clauses" do
      assert_unchanged(@subject, """
      try do
        Map.fetch!(map, :k)
      rescue
        _ -> :default
        RuntimeError -> :other
      end
      """)
    end

    test "already Map.get with default" do
      assert_unchanged(@subject, "Map.get(map, :k, :default)")
    end

    test "try-body wraps Map.fetch! in `||` — left alone" do
      # `Map.fetch!(m, :k) || :fallback` is a `||` expression with the
      # fetch! as one operand; the whole thing isn't the bare
      # `Map.fetch!/2` call shape the refactor matches. Skip rather
      # than guess what the safe rewrite should be.
      assert_unchanged(@subject, """
      try do
        Map.fetch!(map, :k) || :fallback
      rescue
        _ -> :default
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      try do
        Map.fetch!(map, :k)
      rescue
        _ -> :default
      end
      """)
    end
  end
end
