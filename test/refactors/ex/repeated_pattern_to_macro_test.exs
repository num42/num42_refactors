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

    test "functions with parameters are skipped (only zero-arity)" do
      source = """
      defmodule WithArgs do
        def red(x), do: {x, "red"}
        def green(x), do: {x, "green"}
        def blue(x), do: {x, "blue"}
      end
      """

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

    test "bodies that reference variables are skipped" do
      source = """
      defmodule Dynamic do
        def red(x), do: x + 1
        def green(x), do: x + 2
        def blue(x), do: x + 3
      end
      """

      # Carries params → arity > 0 → skipped (only zero-arity collapses).
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
