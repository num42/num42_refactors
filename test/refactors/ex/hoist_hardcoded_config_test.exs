defmodule Number42.Refactors.Ex.HoistHardcodedConfigTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.HoistHardcodedConfig

  @subject HoistHardcodedConfig

  describe "rewrites" do
    test "names a hoisted URL after its host and path" do
      before_source = """
      defmodule Client do
        def call do
          fetch("https://api.example.com/v1")
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ ~s(@api_example_v1_url "https://api.example.com/v1")
      assert result =~ "fetch(@api_example_v1_url)"
      refute result =~ ~s|fetch("https://api.example.com/v1")|
    end

    test "names a hoisted filesystem path after its segments" do
      before_source = """
      defmodule Loader do
        def read do
          File.read("/etc/myapp/config.toml")
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ ~s(@etc_myapp_config_toml_path "/etc/myapp/config.toml")
      assert result =~ "File.read(@etc_myapp_config_toml_path)"
      refute result =~ ~s|File.read("/etc/myapp/config.toml")|
    end

    test "collapses multiple occurrences of the same literal into one attribute" do
      before_source = """
      defmodule Client do
        def a, do: fetch("https://api.example.com")
        def b, do: send_to("https://api.example.com")
      end
      """

      result = apply_refactor(@subject, before_source)

      assert length(String.split(result, ~s(@api_example_url "https://api.example.com"))) == 2
      assert result =~ "fetch(@api_example_url)"
      assert result =~ "send_to(@api_example_url)"
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

    test "gives two distinct URLs two distinct content-derived attributes" do
      before_source = """
      defmodule Client do
        def a, do: fetch("https://api.one.com")
        def b, do: fetch("https://api.two.com")
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ ~s(@api_one_url "https://api.one.com")
      assert result =~ ~s(@api_two_url "https://api.two.com")
      assert result =~ "fetch(@api_one_url)"
      assert result =~ "fetch(@api_two_url)"
      refute result =~ "_url_2"
    end

    test "keyword key still beats the content-derived name" do
      before_source = """
      defmodule Client do
        def opts do
          [website_url: "https://brand.de/imprint"]
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ ~s(@website_url "https://brand.de/imprint")
      assert result =~ "website_url: @website_url"
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

    test "ignores route paths in router DSL calls" do
      assert_unchanged(@subject, """
      defmodule MyAppWeb.Router do
        def routes do
          get("/downloads/latest.zip", FileController, :download)
          live("/users/settings/confirm", UserLive.Settings, :confirm)
          post("/users/log-in.json", UserSessionController, :create)
        end
      end
      """)
    end

    test "ignores the socket path in an endpoint" do
      assert_unchanged(@subject, """
      defmodule MyAppWeb.Endpoint do
        def conf do
          socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
        end
      end
      """)
    end

    test "ignores route patterns with :params anywhere" do
      assert_unchanged(@subject, """
      defmodule M do
        def route, do: build("/users/:id/settings.html")
      end
      """)
    end

    test "leaves the second of two distinct values colliding on a name inline" do
      before_source = """
      defmodule Loader do
        def a, do: File.read("/etc/myapp/config.toml")
        def b, do: File.read("/etc/myapp-config.toml")
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ ~s(@etc_myapp_config_toml_path "/etc/myapp/config.toml")
      assert result =~ ~s|File.read("/etc/myapp-config.toml")|
      refute result =~ "_path_2"
    end

    test "skips a literal whose derived name would be meaningless" do
      assert_unchanged(@subject, """
      defmodule M do
        def call, do: fetch("https://127.0.0.1/2/3")
      end
      """)
    end
  end

  describe "cond / case branches" do
    test "hoists a config string shared across all case branch bodies into one attribute" do
      before_source = """
      defmodule Client do
        def call(env) do
          case env do
            :prod -> String.upcase("https://api.example.com/v1")
            :staging -> String.downcase("https://api.example.com/v1")
          end
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert length(String.split(result, ~s(@api_example_v1_url "https://api.example.com/v1"))) ==
               2

      assert result =~ "String.upcase(@api_example_v1_url)"
      assert result =~ "String.downcase(@api_example_v1_url)"
      refute result =~ ~s|String.upcase("https://api.example.com/v1")|
      assert_compiles(result)
    end

    test "hoists a config string shared across all cond arms into one attribute" do
      before_source = """
      defmodule Client do
        def call(x) do
          cond do
            x > 0 -> String.upcase("https://api.example.com/v1")
            x < 0 -> String.downcase("https://api.example.com/v1")
            true -> String.trim("https://api.example.com/v1")
          end
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert length(String.split(result, ~s(@api_example_v1_url "https://api.example.com/v1"))) ==
               2

      assert result =~ "String.upcase(@api_example_v1_url)"
      assert result =~ "String.downcase(@api_example_v1_url)"
      assert result =~ "String.trim(@api_example_v1_url)"
      assert_compiles(result)
    end

    test "still hoists a config string present in only one branch body" do
      before_source = """
      defmodule Client do
        def call(x) do
          case x do
            :a -> String.upcase("https://api.example.com/v1")
            :b -> :noop
          end
        end
      end
      """

      result = apply_refactor(@subject, before_source)

      assert result =~ ~s(@api_example_v1_url "https://api.example.com/v1")
      assert result =~ "String.upcase(@api_example_v1_url)"
      assert_compiles(result)
    end

    test "leaves a config string used as a case clause-head pattern inline" do
      assert_unchanged(@subject, """
      defmodule M do
        def call(x) do
          case x do
            "https://api.example.com/a" -> 1
            "https://api.example.com/b" -> 2
          end
        end
      end
      """)
    end

    test "leaves a non-config string shared across all branches inline" do
      assert_unchanged(@subject, """
      defmodule M do
        def call(x) do
          case x do
            :a -> log("hello world")
            :b -> warn("hello world")
          end
        end
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

    test "running twice equals running once for a string shared across all branches" do
      assert_idempotent(@subject, """
      defmodule Client do
        def call(x) do
          case x do
            :a -> fetch("https://api.example.com/v1")
            :b -> log("https://api.example.com/v1")
          end
        end
      end
      """)
    end
  end
end
