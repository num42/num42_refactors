defmodule Number42.Refactors.Ex.ManualTapToTapTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ManualTapToTap

  @subject ManualTapToTap

  describe "rewrites" do
    test "then/2 form returning its input" do
      assert_rewrites(
        @subject,
        "value |> then(fn x -> log(x); x end)",
        "value |> tap(fn x -> log(x) end)"
      )
    end

    test "immediately-applied lambda form" do
      assert_rewrites(
        @subject,
        "value |> (fn x -> Logger.info(inspect(x)); x end).()",
        "value |> tap(fn x -> Logger.info(inspect(x)) end)"
      )
    end

    test "multi-statement side-effect body keeps every statement" do
      assert_rewrites(
        @subject,
        """
        value
        |> then(fn x ->
          log(x)
          validate!(x)
          x
        end)
        """,
        "value |> tap(fn x -> log(x) validate!(x) end)"
      )
    end

    test "multi-stage pipe keeps the chain" do
      assert_rewrites(
        @subject,
        "source |> build() |> then(fn x -> notify(x); x end)",
        "source |> build() |> tap(fn x -> notify(x) end)"
      )
    end
  end

  describe "leaves alone" do
    test "body returns a derived value, not the param" do
      assert_unchanged(@subject, "value |> then(fn x -> transform(x) end)")
    end

    test "last expression is a call on the param, not the bare param" do
      assert_unchanged(@subject, "value |> then(fn x -> log(x); f(x) end)")
    end

    test "identity-only body (no side effect)" do
      assert_unchanged(@subject, "value |> then(fn x -> x end)")
    end

    test "parameter is shadowed before the final reference" do
      assert_unchanged(@subject, "value |> (fn x -> x = f(); x end).()")
    end

    test "parameter is rebound by a later statement before the final x" do
      assert_unchanged(@subject, "value |> then(fn x -> log(x); x = g(x); x end)")
    end

    test "multi-arg lambda" do
      assert_unchanged(@subject, "value |> then(fn x, y -> log(x, y); x end)")
    end

    test "multi-clause lambda" do
      assert_unchanged(
        @subject,
        "value |> then(fn :a -> log(:a); :a\n :b -> log(:b); :b end)"
      )
    end

    test "destructuring param" do
      assert_unchanged(@subject, "value |> then(fn {a, _} -> log(a); a end)")
    end

    test "underscore param" do
      assert_unchanged(@subject, "value |> then(fn _ -> log(:noop); :noop end)")
    end

    test "already tap/2" do
      assert_unchanged(@subject, "value |> tap(fn x -> log(x) end)")
    end
  end

  describe "idempotent" do
    test "running twice equals running once on then/2 form" do
      assert_idempotent(@subject, "value |> then(fn x -> log(x); x end)")
    end

    test "running twice equals running once on immediately-applied form" do
      assert_idempotent(@subject, "value |> (fn x -> log(x); x end).()")
    end
  end
end
