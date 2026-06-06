defmodule Number42.Refactors.Ex.DebugInspectCleanupTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.DebugInspectCleanup

  @subject DebugInspectCleanup

  describe "rewrites — default target dbg/1" do
    test "direct IO.inspect/1 call becomes dbg" do
      assert_rewrites(
        @subject,
        "defmodule M do\n  def run(x) do\n    IO.inspect(x)\n  end\nend",
        "defmodule M do\n  def run(x) do\n    dbg(x)\n  end\nend"
      )
    end

    test "IO.inspect with options drops the options" do
      assert_rewrites(
        @subject,
        "defmodule M do\n  def run(x) do\n    IO.inspect(x, label: \"foo\")\n  end\nend",
        "defmodule M do\n  def run(x) do\n    dbg(x)\n  end\nend"
      )
    end

    test "piped IO.inspect becomes piped dbg" do
      assert_rewrites(
        @subject,
        "defmodule M do\n  def run(x) do\n    x |> IO.inspect()\n  end\nend",
        "defmodule M do\n  def run(x) do\n    x |> dbg()\n  end\nend"
      )
    end

    test "piped IO.inspect with options drops the options" do
      assert_rewrites(
        @subject,
        ~s/defmodule M do\n  def run(x) do\n    x |> IO.inspect(label: "bar")\n  end\nend/,
        "defmodule M do\n  def run(x) do\n    x |> dbg()\n  end\nend"
      )
    end
  end

  describe "rewrites — Logger.debug target" do
    test "direct IO.inspect becomes Logger.debug(inspect(x))" do
      assert_rewrites(
        @subject,
        "defmodule M do\n  def run(x) do\n    IO.inspect(x)\n  end\nend",
        "defmodule M do\n  def run(x) do\n    Logger.debug(inspect(x))\n  end\nend",
        target: :logger
      )
    end
  end

  describe "skips — Logger calls are never touched" do
    test "leaves Logger.debug untouched" do
      assert_unchanged(
        @subject,
        "defmodule M do\n  def run(x) do\n    Logger.debug(x)\n  end\nend"
      )
    end

    test "leaves Logger.info untouched" do
      assert_unchanged(
        @subject,
        "defmodule M do\n  def run(x) do\n    Logger.info(x)\n  end\nend"
      )
    end

    test "leaves Logger.error untouched" do
      assert_unchanged(
        @subject,
        "defmodule M do\n  def run(x) do\n    Logger.error(x)\n  end\nend"
      )
    end
  end

  describe "skips — unrelated code" do
    test "leaves a plain call untouched" do
      assert_unchanged(@subject, "defmodule M do\n  def run(x) do\n    process(x)\n  end\nend")
    end

    test "leaves IO.puts untouched" do
      assert_unchanged(@subject, "defmodule M do\n  def run(x) do\n    IO.puts(x)\n  end\nend")
    end
  end

  describe "idempotence" do
    test "a second pass over dbg output is a no-op" do
      assert_unchanged(@subject, "defmodule M do\n  def run(x) do\n    dbg(x)\n  end\nend")
    end
  end
end
