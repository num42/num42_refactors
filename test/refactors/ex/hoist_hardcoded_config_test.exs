defmodule Number42.Refactors.Ex.HoistHardcodedConfigTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.HoistHardcodedConfig

  @subject HoistHardcodedConfig

  describe "rewrites" do
    test "hoists an inline URL literal into a @module_attribute" do
      before_source = """
      defmodule Client do
        def call do
          get("https://api.example.com/v1")
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ ~s(@default_url "https://api.example.com/v1")
      assert result =~ "get(@default_url)"
      refute result =~ ~s|get("https://api.example.com/v1")|
    end

    test "hoists an absolute filesystem path into a @module_attribute" do
      before_source = """
      defmodule Loader do
        def read do
          File.read("/etc/myapp/config.toml")
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ ~s("/etc/myapp/config.toml")
      assert result =~ "@"
      assert result =~ "File.read(@"
      refute result =~ ~s|File.read("/etc/myapp/config.toml")|
    end

    test "collapses multiple occurrences of the same literal into one attribute" do
      before_source = """
      defmodule Client do
        def a, do: get("https://api.example.com")
        def b, do: post("https://api.example.com")
      end
      """

      result = apply_refactor(@subject, before_source)

      assert length(String.split(result, ~s(@default_url "https://api.example.com"))) == 2
      assert result =~ "get(@default_url)"
      assert result =~ "post(@default_url)"
    end

    test "uses the keyword key as the attribute name" do
      before_source = """
      defmodule Client do
        def opts do
          [base_url: "https://api.example.com"]
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ ~s(@base_url "https://api.example.com")
      assert result =~ "base_url: @base_url"
    end

    test "gives two distinct URLs two distinct attributes" do
      before_source = """
      defmodule Client do
        def a, do: get("https://api.one.com")
        def b, do: get("https://api.two.com")
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ ~s(@default_url "https://api.one.com")
      assert result =~ ~s(@default_url_2 "https://api.two.com")
      assert result =~ "get(@default_url)"
      assert result =~ "get(@default_url_2)"
    end

    test "output compiles" do
      before_source = """
      defmodule Client do
        def call, do: String.upcase("https://api.example.com/v1")
      end
      """

      result = apply_refactor(@subject, before_source)
      assert_compiles(result)
    end
  end

  describe "leaves unrelated code alone" do
    test "ignores a plain non-config string" do
      assert_unchanged(@subject, """
      defmodule M do
        def greet, do: "hello world"
      end
      """)
    end

    test "ignores a relative path" do
      assert_unchanged(@subject, """
      defmodule M do
        def path, do: "config/dev.exs"
      end
      """)
    end

    test "does not re-hoist an already hoisted literal" do
      assert_unchanged(@subject, """
      defmodule Client do
        @default_url "https://api.example.com"

        def call, do: get(@default_url)
      end
      """)
    end

    test "ignores a config string used in a guard" do
      assert_unchanged(@subject, """
      defmodule M do
        def check(x) when x == "https://api.example.com", do: :ok
      end
      """)
    end

    test "ignores a config string in a pattern match (function head)" do
      assert_unchanged(@subject, """
      defmodule M do
        def handle("https://api.example.com"), do: :ok
      end
      """)
    end
  end

  describe "idempotent" do
    test "running twice equals running once for a URL literal" do
      assert_idempotent(@subject, """
      defmodule Client do
        def call, do: get("https://api.example.com/v1")
      end
      """)
    end

    test "running twice equals running once for multiple distinct URLs" do
      assert_idempotent(@subject, """
      defmodule Client do
        def a, do: get("https://api.one.com")
        def b, do: get("https://api.two.com")
      end
      """)
    end

    test "running twice equals running once for an absolute path" do
      assert_idempotent(@subject, """
      defmodule Loader do
        def read, do: File.read("/etc/myapp/config.toml")
      end
      """)
    end
  end
end
