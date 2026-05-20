defmodule Num42.Refactors.Refactors.RejectIsNilTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.RejectIsNil

  @subject RejectIsNil

  describe "rewrites" do
    test "Enum.filter(list, fn x -> not is_nil(x) end) -> Enum.reject(&is_nil/1)" do
      assert_rewrites(
        @subject,
        "Enum.filter(list, fn x -> not is_nil(x) end)",
        "Enum.reject(list, &is_nil/1)"
      )
    end

    test "filter with capture form &(not is_nil(&1))" do
      assert_rewrites(
        @subject,
        "Enum.filter(list, &(not is_nil(&1)))",
        "Enum.reject(list, &is_nil/1)"
      )
    end

    test "Enum.reject(list, fn x -> is_nil(x) end) -> Enum.reject(&is_nil/1)" do
      assert_rewrites(
        @subject,
        "Enum.reject(list, fn x -> is_nil(x) end)",
        "Enum.reject(list, &is_nil/1)"
      )
    end

    test "filter checking inequality with nil also rewrites" do
      # The refactor accepts `x != nil` as semantically equivalent to
      # `not is_nil(x)`. Document that here so a future change that
      # tightens the matcher doesn't quietly drop this case.
      assert_rewrites(
        @subject,
        "Enum.filter(list, fn x -> x != nil end)",
        "Enum.reject(list, &is_nil/1)"
      )
    end
  end

  describe "leaves alone" do
    test "filter with a non-nil predicate" do
      assert_unchanged(@subject, "Enum.filter(list, fn x -> x > 0 end)")
    end

    test "already canonical Enum.reject(&is_nil/1)" do
      assert_unchanged(@subject, "Enum.reject(list, &is_nil/1)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "Enum.filter(list, fn x -> not is_nil(x) end)")
    end
  end
end
