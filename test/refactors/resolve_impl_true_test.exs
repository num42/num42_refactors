defmodule Num42.Refactors.Refactors.ResolveImplTrueTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.ResolveImplTrue

  @subject ResolveImplTrue

  # Real modules used as fixtures for BEAM lookup. The refactor reads
  # `defmodule X.Y.Z` from the source, resolves it to an atom, and
  # calls `__info__(:attributes)` on the loaded module — so the module
  # in the source string MUST match a module that's actually compiled.

  defmodule SingleBehaviourFixture do
    use GenServer
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call(_msg, _from, state), do: {:reply, :ok, state}
  end

  defmodule NoBehaviourFixture do
    def hello, do: :world
  end

  defmodule UnknownCallbackFixture do
    use GenServer
    @impl true
    def init(state), do: {:ok, state}
    def helper(x), do: x
  end

  describe "rewrites — single behaviour" do
    test "@impl true on a GenServer callback resolves to @impl GenServer" do
      assert_rewrites(
        @subject,
        ~s'''
        defmodule Num42.Refactors.Refactors.ResolveImplTrueTest.SingleBehaviourFixture do
          use GenServer
          @impl true
          def init(state), do: {:ok, state}
          @impl true
          def handle_call(_msg, _from, state), do: {:reply, :ok, state}
        end
        ''',
        ~s'''
        defmodule Num42.Refactors.Refactors.ResolveImplTrueTest.SingleBehaviourFixture do
          use GenServer
          @impl GenServer
          def init(state), do: {:ok, state}
          @impl GenServer
          def handle_call(_msg, _from, state), do: {:reply, :ok, state}
        end
        '''
      )
    end

    test "@impl true on defp also resolves" do
      # `defp` callbacks aren't a thing in Elixir, but the refactor
      # should still walk past `defp` without crashing — `@impl true`
      # in front of a `defp` is malformed input but we leave it alone
      # rather than blow up.
      assert_unchanged(@subject, ~s'''
      defmodule Num42.Refactors.Refactors.ResolveImplTrueTest.SingleBehaviourFixture do
        use GenServer
        @impl true
        defp helper(x), do: x
      end
      ''')
    end
  end

  describe "leaves alone" do
    test "module without @behaviour or use stays put" do
      assert_unchanged(@subject, ~s'''
      defmodule Num42.Refactors.Refactors.ResolveImplTrueTest.NoBehaviourFixture do
        def hello, do: :world
      end
      ''')
    end

    test "@impl true on a function not declared by any behaviour stays put (per-site)" do
      # `helper/1` is not a GenServer callback. `init/1` IS, so its
      # `@impl true` MUST be rewritten — but `helper/1`'s must not.
      # This proves the skip is per-site, not per-module.
      assert_rewrites(
        @subject,
        ~s'''
        defmodule Num42.Refactors.Refactors.ResolveImplTrueTest.UnknownCallbackFixture do
          use GenServer
          @impl true
          def init(state), do: {:ok, state}
          @impl true
          def helper(x), do: x
        end
        ''',
        ~s'''
        defmodule Num42.Refactors.Refactors.ResolveImplTrueTest.UnknownCallbackFixture do
          use GenServer
          @impl GenServer
          def init(state), do: {:ok, state}
          @impl true
          def helper(x), do: x
        end
        '''
      )
    end

    test "@impl already names a behaviour stays put" do
      assert_unchanged(@subject, ~s'''
      defmodule Num42.Refactors.Refactors.ResolveImplTrueTest.SingleBehaviourFixture do
        use GenServer
        @impl GenServer
        def init(state), do: {:ok, state}
      end
      ''')
    end

    test "@impl false stays put" do
      assert_unchanged(@subject, ~s'''
      defmodule Num42.Refactors.Refactors.ResolveImplTrueTest.SingleBehaviourFixture do
        use GenServer
        @impl false
        def init(state), do: {:ok, state}
      end
      ''')
    end

    test "module not loaded / does not exist — skip whole module" do
      assert_unchanged(@subject, ~s'''
      defmodule SomeUnknownModuleThatDoesNotExist.At.All do
        @behaviour GenServer
        @impl true
        def init(state), do: {:ok, state}
      end
      ''')
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(@subject, ~s'''
      defmodule Num42.Refactors.Refactors.ResolveImplTrueTest.SingleBehaviourFixture do
        use GenServer
        @impl true
        def init(state), do: {:ok, state}
      end
      ''')
    end
  end
end
