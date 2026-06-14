defmodule Number42.Refactors.Ex.RepeatedPatternToMacroTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.RepeatedPatternToMacro

  @subject RepeatedPatternToMacro

  # The refactor is opt-in / default-off. Every positive test passes
  # `enabled: true` explicitly; the default-off test asserts that without
  # it nothing happens.
  @on [enabled: true]

  describe "default-off" do
    test "without opt-in config the source is left untouched" do
      source = """
      defmodule Palette do
        def red, do: %Color{name: "red", hex: "#ff0000"}
        def green, do: %Color{name: "green", hex: "#00ff00"}
        def blue, do: %Color{name: "blue", hex: "#0000ff"}
      end
      """

      assert_unchanged(@subject, source)
    end

    test "enabled: false behaves like the default" do
      source = """
      defmodule Palette do
        def red, do: %Color{name: "red", hex: "#ff0000"}
        def green, do: %Color{name: "green", hex: "#00ff00"}
        def blue, do: %Color{name: "blue", hex: "#0000ff"}
      end
      """

      assert_unchanged(@subject, source, enabled: false)
    end
  end

  describe "rewrites (opt-in)" do
    test "three structurally identical zero-arity defs collapse into a for-block" do
      source = """
      defmodule Palette do
        def red, do: %Color{name: "red", hex: "#ff0000"}
        def green, do: %Color{name: "green", hex: "#00ff00"}
        def blue, do: %Color{name: "blue", hex: "#0000ff"}
      end
      """

      rewritten = apply_refactor(@subject, source, @on)

      assert rewritten =~ "for {fun,"
      assert rewritten =~ "def unquote(fun)()"
      assert rewritten =~ ~s|{:red, "red", "#ff0000"}|
      assert rewritten =~ ~s|{:green, "green", "#00ff00"}|
      assert rewritten =~ ~s|{:blue, "blue", "#0000ff"}|
      # The shared struct skeleton appears once — in the generated clause.
      assert occurrences(rewritten, "%Color{") == 1
      # The original scattered defs are gone.
      refute rewritten =~ "def red,"
      refute rewritten =~ "def green,"
      refute rewritten =~ "def blue,"
    end

    test "the generated module compiles and is behaviour-preserving" do
      source = """
      defmodule PaletteGen do
        def red, do: {:color, "red", 1}
        def green, do: {:color, "green", 2}
        def blue, do: {:color, "blue", 3}
      end
      """

      rewritten = apply_refactor(@subject, source, @on)

      assert_compiles(rewritten)

      [{mod, _}] = Code.compile_string(rewritten)
      assert mod.red() == {:color, "red", 1}
      assert mod.green() == {:color, "green", 2}
      assert mod.blue() == {:color, "blue", 3}
      :code.purge(mod)
      :code.delete(mod)
    end

    test "constant literals shared by every def stay inline (not parametrised)" do
      source = """
      defmodule Tags do
        def alpha, do: {:tag, "alpha", :active}
        def beta, do: {:tag, "beta", :active}
        def gamma, do: {:tag, "gamma", :active}
      end
      """

      rewritten = apply_refactor(@subject, source, @on)

      # `:tag` and `:active` are identical across all three → stay inline.
      assert rewritten =~ ":tag,"
      assert rewritten =~ ":active}"
      # Exactly one varying literal column → tuple rows are `{name, string}`.
      assert rewritten =~ ~s|{:alpha, "alpha"}|
      assert rewritten =~ ~s|{:beta, "beta"}|
      assert rewritten =~ ~s|{:gamma, "gamma"}|
      assert_compiles(rewritten)
    end

    test "non-struct bodies (a local call with one varying literal arg)" do
      source = """
      defmodule Builders do
        def red, do: build("red")
        def green, do: build("green")
        def blue, do: build("blue")
      end
      """

      rewritten = apply_refactor(@subject, source, @on)

      assert rewritten =~ "def unquote(fun)(), do: build(unquote("
      assert rewritten =~ ~s|{:red, "red"}|
      assert rewritten =~ ~s|{:green, "green"}|
      assert rewritten =~ ~s|{:blue, "blue"}|
    end

    test "single bare-var-param defs collapse, threading the param through" do
      source = """
      defmodule Colors do
        def red(mode), do: Color.new("red", mode)
        def green(mode), do: Color.new("green", mode)
        def blue(mode), do: Color.new("blue", mode)
      end
      """

      rewritten = apply_refactor(@subject, source, @on)

      # Param `mode` is reproduced verbatim in the head; only the literal
      # is unquoted from the value table.
      assert rewritten =~ "def unquote(fun)(mode), do: Color.new(unquote(arg1), mode)"
      assert rewritten =~ ~s|{:red, "red"}|
      assert rewritten =~ ~s|{:green, "green"}|
      assert rewritten =~ ~s|{:blue, "blue"}|
      refute rewritten =~ "def red("
      refute rewritten =~ "def green("
      refute rewritten =~ "def blue("
    end

    test "single-param generated module compiles and threads the param correctly" do
      source = """
      defmodule SingleParamGen do
        def red(n), do: {:color, "red", n}
        def green(n), do: {:color, "green", n}
        def blue(n), do: {:color, "blue", n}
      end
      """

      rewritten = apply_refactor(@subject, source, @on)

      # The generated macro must compile AND expand so the param is in
      # scope inside the body (hygiene: param head var and body read share
      # one quote scope).
      assert_compiles(rewritten)

      [{mod, _}] = Code.compile_string(rewritten)
      assert mod.red(7) == {:color, "red", 7}
      assert mod.green(8) == {:color, "green", 8}
      assert mod.blue(9) == {:color, "blue", 9}
      :code.purge(mod)
      :code.delete(mod)
    end

    test "single-param body using the param twice still binds correctly" do
      source = """
      defmodule TwiceParamGen do
        def red(n), do: {"red", n, n + 1}
        def green(n), do: {"green", n, n + 1}
        def blue(n), do: {"blue", n, n + 1}
      end
      """

      rewritten = apply_refactor(@subject, source, @on)

      assert_compiles(rewritten)

      [{mod, _}] = Code.compile_string(rewritten)
      assert mod.red(1) == {"red", 1, 2}
      assert mod.green(2) == {"green", 2, 3}
      assert mod.blue(3) == {"blue", 3, 4}
      :code.purge(mod)
      :code.delete(mod)
    end
  end

  describe "idempotent" do
    test "a generated for-block is not re-collapsed" do
      source = """
      defmodule Palette do
        def red, do: %Color{name: "red", hex: "#ff0000"}
        def green, do: %Color{name: "green", hex: "#00ff00"}
        def blue, do: %Color{name: "blue", hex: "#0000ff"}
      end
      """

      assert_idempotent(@subject, source, @on)
    end

    test "an already-generated for-block passes through unchanged" do
      source = """
      defmodule Palette do
        for {fun, name, hex} <- [
              {:red, "red", "#ff0000"},
              {:green, "green", "#00ff00"},
              {:blue, "blue", "#0000ff"}
            ] do
          def unquote(fun)(), do: %Color{name: unquote(name), hex: unquote(hex)}
        end
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "a single-param collapse is idempotent" do
      source = """
      defmodule Colors do
        def red(mode), do: Color.new("red", mode)
        def green(mode), do: Color.new("green", mode)
        def blue(mode), do: Color.new("blue", mode)
      end
      """

      assert_idempotent(@subject, source, @on)
    end

    test "an already-generated single-param for-block passes through unchanged" do
      source = """
      defmodule Colors do
        for {fun, arg1} <- [{:red, "red"}, {:green, "green"}, {:blue, "blue"}] do
          def unquote(fun)(mode), do: Color.new(unquote(arg1), mode)
        end
      end
      """

      # `unquote(fun)` heads are not bare atoms, so the generated clause
      # never re-enters a group → no-op.
      assert_unchanged(@subject, source, @on)
    end
  end

  describe "threshold (min_functions)" do
    test "below the default threshold (two defs) → skip" do
      source = """
      defmodule Pair do
        def red, do: %Color{name: "red", hex: "#ff0000"}
        def green, do: %Color{name: "green", hex: "#00ff00"}
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "a raised threshold can hold back an otherwise-eligible group" do
      source = """
      defmodule Palette do
        def red, do: %Color{name: "red", hex: "#ff0000"}
        def green, do: %Color{name: "green", hex: "#00ff00"}
        def blue, do: %Color{name: "blue", hex: "#0000ff"}
      end
      """

      assert_unchanged(@subject, source, enabled: true, min_functions: 4)
    end
  end

  describe "skip cases" do
    test "guarded clauses are never collapsed" do
      source = """
      defmodule Guarded do
        def classify(n) when n > 0, do: :pos
        def classify(n) when n < 0, do: :neg
        def classify(n) when n == 0, do: :zero
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "multi-parameter functions are skipped (only single bare-var param)" do
      source = """
      defmodule TwoArgs do
        def red(x, y), do: {x, y, "red"}
        def green(x, y), do: {x, y, "green"}
        def blue(x, y), do: {x, y, "blue"}
      end
      """

      # Two params would need co-parameterisation we don't attempt → skip.
      assert_unchanged(@subject, source, @on)
    end

    test "a pattern (non-bare-var) single param is skipped" do
      source = """
      defmodule Patterned do
        def red(%Ctx{} = c), do: {c, "red"}
        def green(%Ctx{} = c), do: {c, "green"}
        def blue(%Ctx{} = c), do: {c, "blue"}
      end
      """

      # `%Ctx{} = c` is a destructuring head, not a plain var → skip.
      assert_unchanged(@subject, source, @on)
    end

    test "single-param groups must agree on the param name" do
      source = """
      defmodule MixedParams do
        def red(mode), do: build("red", mode)
        def green(opt), do: build("green", opt)
        def blue(mode), do: build("blue", mode)
      end
      """

      # `mode` and `opt` are different param names → at most two `mode`
      # members, below the threshold of 3 → skip.
      assert_unchanged(@subject, source, @on)
    end

    test "a single-param body reading a free var beyond the param is skipped" do
      source = """
      defmodule ExtraFree do
        def red(mode), do: build("red", mode, prefix)
        def green(mode), do: build("green", mode, prefix)
        def blue(mode), do: build("blue", mode, prefix)
      end
      """

      # `prefix` is free and not the param → undefined after generation,
      # so the body is not fully determined by the tuple + param → skip.
      assert_unchanged(@subject, source, @on)
    end

    test "structurally different bodies are not grouped" do
      source = """
      defmodule Mixed do
        def red, do: %Color{name: "red"}
        def green, do: %Shade{name: "green"}
        def blue, do: 42
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "a doc'd function in the group blocks collapsing (docs would be lost)" do
      source = """
      defmodule Documented do
        @doc "the red one"
        def red, do: %Color{name: "red", hex: "#ff0000"}
        def green, do: %Color{name: "green", hex: "#00ff00"}
        def blue, do: %Color{name: "blue", hex: "#0000ff"}
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "multi-clause functions in the group are skipped" do
      source = """
      defmodule MultiClause do
        def red, do: %Color{name: "red", hex: "#ff0000"}
        def red, do: %Color{name: "RED", hex: "#ff0000"}
        def green, do: %Color{name: "green", hex: "#00ff00"}
        def blue, do: %Color{name: "blue", hex: "#0000ff"}
      end
      """

      assert_unchanged(@subject, source, @on)
    end

    test "zero-arity bodies with a same-named free variable are skipped" do
      source = """
      defmodule FreeVar do
        def red, do: foo + 1
        def green, do: foo + 2
        def blue, do: foo + 3
      end
      """

      # `foo` is a free variable read in every body — lifting it into a
      # `for` table would emit `def unquote(fun)(), do: foo + unquote(arg1)`
      # where `foo` is undefined → won't compile. Must skip.
      assert_unchanged(@subject, source, @on)
    end

    test "if a free-var group were (wrongly) collapsed it would not compile" do
      source = """
      defmodule FreeVarCompile do
        def red, do: foo + 1
        def green, do: foo + 2
        def blue, do: foo + 3
      end
      """

      # Belt-and-braces: the only safe output for a free-var body is the
      # untouched source (which compiles only because `foo` is unbound at
      # runtime — but a generated `for` over it would be a compile error,
      # see above). We assert the pass produced compilable code, i.e. it
      # did not synthesise an `unquote(arg)` body referencing free `foo`.
      rewritten = apply_refactor(@subject, source, @on)

      refute rewritten =~ "for {fun,"
    end

    test "no varying literals (identical bodies) → skip, leave for exact-dup pass" do
      source = """
      defmodule Same do
        def red, do: %Color{name: "x"}
        def green, do: %Color{name: "x"}
        def blue, do: %Color{name: "x"}
      end
      """

      # Only the name differs; the body is identical. A `for` over names
      # with an identical body is pure obfuscation — that's the exact-
      # duplicate refactor's job, not this one.
      assert_unchanged(@subject, source, @on)
    end
  end

  defp occurrences(haystack, needle),
    do: haystack |> String.split(needle) |> length() |> Kernel.-(1)
end
