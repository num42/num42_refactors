defmodule Number42.Refactors.Ex.ExtractParametricClone.ExtractArgBindingTest do
  use ExUnit.Case, async: true

  alias Number42.Refactors.Ex.ExtractParametricClone

  defp parse_arg(src) do
    # Wrap in a function head so we can pull out the single argument.
    "def f(#{src}), do: :ok"
    |> Sourceror.parse_string!()
    |> case do
      {:def, _, [{:f, _, [arg]}, _]} -> arg
    end
  end

  describe "extract_arg_binding/1 — plain bare var" do
    test "x → {:ok, :x}" do
      assert {:ok, :x} = ExtractParametricClone.extract_arg_binding(parse_arg("x"))
    end

    test "scope → {:ok, :scope}" do
      assert {:ok, :scope} = ExtractParametricClone.extract_arg_binding(parse_arg("scope"))
    end

    test "_underscore → :error (unbound)" do
      assert :error = ExtractParametricClone.extract_arg_binding(parse_arg("_"))
    end

    test "_ignored → :error (unbound, leading underscore)" do
      assert :error = ExtractParametricClone.extract_arg_binding(parse_arg("_ignored"))
    end
  end

  describe "extract_arg_binding/1 — pattern = var (right side bare)" do
    test "%Scope{} = scope → {:ok, :scope}" do
      assert {:ok, :scope} =
               ExtractParametricClone.extract_arg_binding(parse_arg("%Scope{} = scope"))
    end

    test "%Scope{user_id: id} = scope → {:ok, :scope}" do
      assert {:ok, :scope} =
               ExtractParametricClone.extract_arg_binding(
                 parse_arg("%Scope{user_id: id} = scope")
               )
    end

    test "%{key: x} = m → {:ok, :m}" do
      assert {:ok, :m} = ExtractParametricClone.extract_arg_binding(parse_arg("%{key: x} = m"))
    end

    test "{:ok, x} = result → {:ok, :result}" do
      assert {:ok, :result} =
               ExtractParametricClone.extract_arg_binding(parse_arg("{:ok, x} = result"))
    end

    test "[h | t] = list → {:ok, :list}" do
      assert {:ok, :list} =
               ExtractParametricClone.extract_arg_binding(parse_arg("[h | t] = list"))
    end

    test "_ = scope → {:ok, :scope}" do
      assert {:ok, :scope} = ExtractParametricClone.extract_arg_binding(parse_arg("_ = scope"))
    end
  end

  describe "extract_arg_binding/1 — var = pattern (left side bare)" do
    test "scope = %Scope{} → {:ok, :scope}" do
      assert {:ok, :scope} =
               ExtractParametricClone.extract_arg_binding(parse_arg("scope = %Scope{}"))
    end

    test "m = %{key: x} → {:ok, :m}" do
      assert {:ok, :m} = ExtractParametricClone.extract_arg_binding(parse_arg("m = %{key: x}"))
    end

    test "scope = _ → {:ok, :scope}" do
      assert {:ok, :scope} = ExtractParametricClone.extract_arg_binding(parse_arg("scope = _"))
    end
  end

  describe "extract_arg_binding/1 — rejected forms" do
    test "default arg `x \\\\ 1` → :error" do
      assert :error = ExtractParametricClone.extract_arg_binding(parse_arg("x \\\\ 1"))
    end

    test "atom literal `:ok` → :error (no binding)" do
      assert :error = ExtractParametricClone.extract_arg_binding(parse_arg(":ok"))
    end

    test "integer literal `42` → :error" do
      assert :error = ExtractParametricClone.extract_arg_binding(parse_arg("42"))
    end

    test "string literal `\"foo\"` → :error" do
      assert :error = ExtractParametricClone.extract_arg_binding(parse_arg("\"foo\""))
    end

    test "bare struct `%Scope{}` (no binding) → :error" do
      assert :error = ExtractParametricClone.extract_arg_binding(parse_arg("%Scope{}"))
    end

    test "bare tuple `{:ok, x}` (no `= var`) → :error" do
      assert :error = ExtractParametricClone.extract_arg_binding(parse_arg("{:ok, x}"))
    end

    test "both sides bare vars `a = b` → {:ok, :a} (left wins, deterministic)" do
      # Edge case: both are bindings. Pick the left one — by convention,
      # Elixir treats the LHS as the assigned name in `=`.
      assert {:ok, :a} = ExtractParametricClone.extract_arg_binding(parse_arg("a = b"))
    end
  end
end
