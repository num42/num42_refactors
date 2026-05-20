defmodule Num42.Refactors.Refactors.UseMapJoinTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.UseMapJoin

  @subject UseMapJoin

  describe "rewrites" do
    test "Enum.map(coll, fun) |> Enum.join(sep) -> Enum.map_join(coll, sep, fun)" do
      assert_rewrites(
        @subject,
        "list |> Enum.map(&to_string/1) |> Enum.join(\", \")",
        "Enum.map_join(list, \", \", &to_string/1)"
      )
    end

    test "non-pipe nested form" do
      assert_rewrites(
        @subject,
        "Enum.join(Enum.map(list, &to_string/1), \", \")",
        "Enum.map_join(list, \", \", &to_string/1)"
      )
    end
  end

  describe "leaves alone" do
    test "Enum.join without an upstream Enum.map" do
      assert_unchanged(@subject, "Enum.join(list, \", \")")
    end

    test "Enum.map without a downstream Enum.join" do
      assert_unchanged(@subject, "Enum.map(list, &to_string/1)")
    end

    test "already Enum.map_join" do
      assert_unchanged(@subject, "Enum.map_join(list, \", \", &to_string/1)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, "list |> Enum.map(&to_string/1) |> Enum.join(\", \")")
    end
  end

  describe "nested map/join pipes (regression)" do
    # `Macro.prewalker/1` yields both the outer and the inner pipe when
    # they nest: the outer `outer_coll |> Enum.map(fn x -> inner_pipe end)
    # |> Enum.join(sep)` matches, and so does the inner `inner_coll |>
    # Enum.map(...) |> Enum.join(...)` inside the lambda body. Submitting
    # both patches to `Sourceror.patch_string/2` produced overlapping
    # ranges, and the outer patch silently swallowed bytes that the
    # inner patch had already consumed — corrupting whatever followed
    # the outer pipe (typically a comment on the next line).
    test "rewrites the inner pipe and leaves the file parseable" do
      source = """
      defmodule Sample do
        def foo(helpers) do
          rendered =
            helpers
            |> Enum.map(&render_helper/1)
            |> Enum.map(fn block ->
              block
              |> String.split("\\n")
              |> Enum.map(fn line -> "  " <> line end)
              |> Enum.join("\\n")
            end)
            |> Enum.join("\\n\\n")

          # Insert just before the module's closing `end`.
          rendered
        end
      end
      """

      result = apply_refactor(@subject, source)

      assert {:ok, _ast} = Code.string_to_quoted(result), """
      UseMapJoin produced unparseable source.

      --- before ---
      #{source}
      --- after ---
      #{result}
      """

      assert String.contains?(result, "module's closing `end`"), """
      UseMapJoin clobbered the trailing comment.

      --- after ---
      #{result}
      """
    end
  end
end
