defmodule Number42.Refactors.Ex.LiftWithIntoPipelineTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.LiftWithIntoPipeline

  @subject LiftWithIntoPipeline

  describe "rewrites" do
    test "single <- with single transforming body becomes a pipe-via-case" do
      # The pipe-via-case form must include a passthrough arm to preserve
      # the original `with` semantics: `with` falls through unmatched
      # values, but `|> case` without a catch-all would crash.
      assert_rewrites(
        @subject,
        """
        with {:ok, consolidated} <- consolidate_rows(rows) do
          {:ok, preview_consolidated_rows(consolidated, building_id)}
        end
        """,
        """
        rows
        |> consolidate_rows()
        |> case do
          {:ok, consolidated} ->
            {:ok, preview_consolidated_rows(consolidated, building_id)}

          other ->
            other
        end
        """
      )
    end
  end

  describe "leaves alone" do
    test "multi-statement body — pipe can't host statements" do
      assert_unchanged(@subject, """
      with {:ok, collection} <- repo.insert(changeset) do
        repo.update_all(query, set: [item_collection_id: collection.id])
        {:ok, collection}
      end
      """)
    end

    test "body doesn't reference the bound variable — no flow to lift" do
      assert_unchanged(@subject, """
      with {:ok, _} <- check() do
        {:ok, :done}
      end
      """)
    end

    test "two or more <- clauses — defer to other refactors" do
      assert_unchanged(@subject, """
      with {:ok, x} <- foo(),
           {:ok, y} <- bar(x) do
        {:ok, y}
      end
      """)
    end

    test "with has an else block — skip" do
      assert_unchanged(@subject, """
      with {:ok, x} <- foo() do
        bar(x)
      else
        {:error, e} -> {:error, e}
      end
      """)
    end

    test "RHS is `||` — operator can't be split into a pipe stage" do
      # `{:ok, x} <- (fetch_a() || fetch_b())` parses with the `||` as
      # the RHS top-level call. Splitting it into `fetch_a() |> ||(fetch_b())`
      # produces invalid syntax — `||` is not a callable name.
      assert_unchanged(@subject, """
      with {:ok, x} <- fetch_a() || fetch_b() do
        bar(x)
      end
      """)
    end

    test "RHS is `&&` — same operator hazard as `||`" do
      assert_unchanged(@subject, """
      with {:ok, x} <- check_a() && check_b() do
        bar(x)
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, """
      with {:ok, consolidated} <- consolidate_rows(rows) do
        {:ok, preview_consolidated_rows(consolidated, building_id)}
      end
      """)
    end
  end
end
