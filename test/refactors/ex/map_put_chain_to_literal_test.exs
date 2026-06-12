defmodule Number42.Refactors.Ex.MapPutChainToLiteralTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.MapPutChainToLiteral

  @subject MapPutChainToLiteral

  describe "collapses Map.put rebind chains into a literal" do
    test "rewrites a %{}-seeded chain followed by the bound variable" do
      before_source = """
      defmodule M do
        def build_payload(user) do
          payload = %{}
          payload = Map.put(payload, :id, user.id)
          payload = Map.put(payload, :name, user.name)
          payload = Map.put(payload, "email", user.email)
          payload
        end
      end
      """

      expected = """
      defmodule M do
        def build_payload(user) do
          %{
            id: user.id,
            name: user.name,
            "email" => user.email
          }
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "rewrites a chain when the last Map.put is the tail expression" do
      before_source = """
      defmodule M do
        def build_payload(user) do
          payload = %{}
          payload = Map.put(payload, :id, user.id)
          payload = Map.put(payload, :name, user.name)
        end
      end
      """

      expected = """
      defmodule M do
        def build_payload(user) do
          %{
            id: user.id,
            name: user.name
          }
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "idempotence" do
    test "applying twice equals applying once" do
      before_source = """
      defmodule M do
        def build_payload(user) do
          payload = %{}
          payload = Map.put(payload, :id, user.id)
          payload = Map.put(payload, :name, user.name)
          payload
        end
      end
      """

      assert_idempotent(@subject, before_source)
    end
  end

  describe "skips" do
    test "leaves an interleaved read alone" do
      source = """
      defmodule M do
        def build_payload(user) do
          payload = %{}
          payload = Map.put(payload, :id, user.id)
          log(payload)
          payload = Map.put(payload, :name, user.name)
          payload
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves a bare read alone when more rebinds follow" do
      source = """
      defmodule M do
        def build_payload(user) do
          payload = %{}
          payload = Map.put(payload, :id, user.id)
          payload
          payload = Map.put(payload, :name, user.name)
          payload
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "leaves a mixed rebind chain alone" do
      source = """
      defmodule M do
        def build_payload(user) do
          payload = %{}
          payload = Map.put(payload, :id, user.id)
          payload = normalize(payload)
          payload = Map.put(payload, :name, user.name)
          payload
        end
      end
      """

      assert_unchanged(@subject, source)
    end
  end
end
