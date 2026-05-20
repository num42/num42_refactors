defmodule Num42.Refactors.Refactors.UtcNowTruncateTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.UtcNowTruncate

  @subject UtcNowTruncate

  describe "rewrites — pipe form" do
    test "DateTime.utc_now() |> DateTime.truncate(:second) -> DateTime.utc_now(:second)" do
      assert_rewrites(
        @subject,
        "DateTime.utc_now() |> DateTime.truncate(:second)",
        "DateTime.utc_now(:second)"
      )
    end

    test "NaiveDateTime works the same" do
      assert_rewrites(
        @subject,
        "NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:millisecond)",
        "NaiveDateTime.utc_now(:millisecond)"
      )
    end
  end

  describe "rewrites — nested form" do
    test "DateTime.truncate(DateTime.utc_now(), :second) -> DateTime.utc_now(:second)" do
      assert_rewrites(
        @subject,
        "DateTime.truncate(DateTime.utc_now(), :second)",
        "DateTime.utc_now(:second)"
      )
    end

    test "NaiveDateTime nested form" do
      assert_rewrites(
        @subject,
        "NaiveDateTime.truncate(NaiveDateTime.utc_now(), :millisecond)",
        "NaiveDateTime.utc_now(:millisecond)"
      )
    end
  end

  describe "leaves alone" do
    test "truncate with non-utc_now arg" do
      assert_unchanged(@subject, "DateTime.truncate(some_dt, :second)")
    end

    test "pipe with non-truncate" do
      assert_unchanged(@subject, "DateTime.utc_now() |> DateTime.add(1, :second)")
    end

    test "module mismatch (DateTime utc_now -> NaiveDateTime truncate)" do
      assert_unchanged(@subject, "DateTime.utc_now() |> NaiveDateTime.truncate(:second)")
    end

    test "utc_now with timezone arg (different signature)" do
      assert_unchanged(
        @subject,
        ~S{DateTime.utc_now("Europe/Berlin") |> DateTime.truncate(:second)}
      )
    end

    test "already rewritten form" do
      assert_unchanged(@subject, "DateTime.utc_now(:second)")
    end
  end

  describe "idempotent" do
    test "pipe form" do
      assert_idempotent(@subject, "DateTime.utc_now() |> DateTime.truncate(:second)")
    end

    test "nested form" do
      assert_idempotent(@subject, "DateTime.truncate(DateTime.utc_now(), :second)")
    end
  end
end
