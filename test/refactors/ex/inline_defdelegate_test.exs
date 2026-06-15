defmodule Number42.Refactors.Ex.InlineDefdelegateTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.InlineDefdelegate

  @subject InlineDefdelegate

  # Cross-file refactor: it inspects every input source, finds resolvable
  # `defdelegate`s, rewrites their in-corpus call sites to hit the target
  # module directly, and removes the delegate when it is effectively
  # private with zero remaining corpus callers. We feed the corpus-wide
  # plan to transform/2 via opts[:prepared] — the same shape prepare/1
  # produces in production. `enabled: true` is required (default-OFF).

  defp prepared(sources), do: InlineDefdelegate.build_plan(sources, enabled: true)

  defp on(plan), do: [prepared: plan, enabled: true]

  # Target modules must be present in the corpus so the delegate's `to:`
  # resolves to a module we can see (the resolvability guard). Realistic
  # corpora always include the implementation module.
  defp parser_target do
    {"parser.ex",
     """
     defmodule MyApp.Deep.Parser do
       def parse(input), do: {:parsed, input}
     end
     """}
  end

  defp mod_target do
    {"mod.ex",
     """
     defmodule MyApp.Deep.Mod do
       def bar(a), do: {:bar, a}
     end
     """}
  end

  describe "slice 1 — call-site rewrite, alias-aware" do
    test "no alias on the caller -> fully-qualified target call" do
      facade = """
      defmodule MyApp.Facade do
        defdelegate parse(input), to: MyApp.Deep.Parser
      end
      """

      caller = """
      defmodule MyApp.Caller do
        alias MyApp.Facade

        def run(data), do: Facade.parse(data)
      end
      """

      plan = prepared([{"facade.ex", facade}, {"caller.ex", caller}, parser_target()])

      expected_caller = """
      defmodule MyApp.Caller do
        alias MyApp.Facade

        def run(data), do: MyApp.Deep.Parser.parse(data)
      end
      """

      assert_rewrites(@subject, caller, expected_caller, on(plan))
    end

    test "caller aliases the target -> short alias form" do
      facade = """
      defmodule MyApp.Facade do
        defdelegate parse(input), to: MyApp.Deep.Parser
      end
      """

      caller = """
      defmodule MyApp.Caller do
        alias MyApp.Facade
        alias MyApp.Deep.Parser

        def run(data), do: Facade.parse(data)
      end
      """

      plan = prepared([{"facade.ex", facade}, {"caller.ex", caller}, parser_target()])

      expected_caller = """
      defmodule MyApp.Caller do
        alias MyApp.Facade
        alias MyApp.Deep.Parser

        def run(data), do: Parser.parse(data)
      end
      """

      assert_rewrites(@subject, caller, expected_caller, on(plan))
    end

    test "fully-qualified call to the facade is also rewritten" do
      facade = """
      defmodule MyApp.Facade do
        defdelegate parse(input), to: MyApp.Deep.Parser
      end
      """

      caller = """
      defmodule MyApp.Caller do
        def run(data), do: MyApp.Facade.parse(data)
      end
      """

      plan = prepared([{"facade.ex", facade}, {"caller.ex", caller}, parser_target()])

      expected_caller = """
      defmodule MyApp.Caller do
        def run(data), do: MyApp.Deep.Parser.parse(data)
      end
      """

      assert_rewrites(@subject, caller, expected_caller, on(plan))
    end
  end

  describe "slice 2 — removal of the now-unused private-ish delegate" do
    test "delegate in a deep/leaf module with 0 corpus callers -> removed" do
      helper = """
      defmodule MyApp.Deep.Internal.Helper do
        defdelegate parse(input), to: MyApp.Deep.Parser
      end
      """

      caller = """
      defmodule MyApp.Deep.Internal.Caller do
        def run(data), do: MyApp.Deep.Internal.Helper.parse(data)
      end
      """

      plan = prepared([{"helper.ex", helper}, {"caller.ex", caller}, parser_target()])

      expected_helper = """
      defmodule MyApp.Deep.Internal.Helper do
      end
      """

      expected_caller = """
      defmodule MyApp.Deep.Internal.Caller do
        def run(data), do: MyApp.Deep.Parser.parse(data)
      end
      """

      assert_rewrites(@subject, helper, expected_helper, on(plan))
      assert_rewrites(@subject, caller, expected_caller, on(plan))
    end

    test "deep module with a bare local self-call to the delegate -> kept" do
      # `wrap/1` calls `parse(data)` unqualified, resolving to the
      # delegate locally. The rewrite only touches qualified references,
      # so removing the delegate would orphan that self-call → keep it.
      helper = """
      defmodule MyApp.Deep.Internal.Helper do
        defdelegate parse(input), to: MyApp.Deep.Parser

        def wrap(data), do: parse(data)
      end
      """

      plan = prepared([{"helper.ex", helper}, parser_target()])

      assert_unchanged(@subject, helper, on(plan))
    end

    test "public boundary module (Facade/Context) -> calls inlined, delegate kept" do
      facade = """
      defmodule MyApp.Accounts do
        defdelegate parse(input), to: MyApp.Deep.Parser
      end
      """

      caller = """
      defmodule MyApp.Caller do
        def run(data), do: MyApp.Accounts.parse(data)
      end
      """

      plan = prepared([{"facade.ex", facade}, {"caller.ex", caller}, parser_target()])

      expected_caller = """
      defmodule MyApp.Caller do
        def run(data), do: MyApp.Deep.Parser.parse(data)
      end
      """

      assert_unchanged(@subject, facade, on(plan))
      assert_rewrites(@subject, caller, expected_caller, on(plan))
    end
  end

  describe "slice 3 — as: rename" do
    test "call site uses the target name, not the delegate name" do
      facade = """
      defmodule MyApp.Deep.Internal.Facade do
        defdelegate foo(a), to: MyApp.Deep.Mod, as: :bar
      end
      """

      caller = """
      defmodule MyApp.Caller do
        alias MyApp.Deep.Mod

        def run(x), do: MyApp.Deep.Internal.Facade.foo(x)
      end
      """

      plan = prepared([{"facade.ex", facade}, {"caller.ex", caller}, mod_target()])

      expected_caller = """
      defmodule MyApp.Caller do
        alias MyApp.Deep.Mod

        def run(x), do: Mod.bar(x)
      end
      """

      assert_rewrites(@subject, caller, expected_caller, on(plan))
    end
  end

  describe "slice 4 — skips" do
    test "multi-form keyword-list defdelegate is skipped" do
      facade = """
      defmodule MyApp.Deep.Internal.Facade do
        defdelegate [foo: 1, bar: 2], to: MyApp.Deep.Mod
      end
      """

      caller = """
      defmodule MyApp.Caller do
        def run(x), do: MyApp.Deep.Internal.Facade.foo(x)
      end
      """

      plan = prepared([{"facade.ex", facade}, {"caller.ex", caller}, mod_target()])

      assert_unchanged(@subject, facade, on(plan))
      assert_unchanged(@subject, caller, on(plan))
    end

    test "dynamic dispatch via &name/arity capture of the delegate -> skip whole delegate" do
      facade = """
      defmodule MyApp.Deep.Internal.Facade do
        defdelegate parse(input), to: MyApp.Deep.Parser
      end
      """

      caller = """
      defmodule MyApp.Caller do
        def run(list), do: Enum.map(list, &MyApp.Deep.Internal.Facade.parse/1)
      end
      """

      plan = prepared([{"facade.ex", facade}, {"caller.ex", caller}, parser_target()])

      assert_unchanged(@subject, facade, on(plan))
      assert_unchanged(@subject, caller, on(plan))
    end

    test "apply/3 dispatch to the delegate -> skip whole delegate" do
      facade = """
      defmodule MyApp.Deep.Internal.Facade do
        defdelegate parse(input), to: MyApp.Deep.Parser
      end
      """

      caller = """
      defmodule MyApp.Caller do
        def run(data), do: apply(MyApp.Deep.Internal.Facade, :parse, [data])
      end
      """

      plan = prepared([{"facade.ex", facade}, {"caller.ex", caller}, parser_target()])

      assert_unchanged(@subject, facade, on(plan))
      assert_unchanged(@subject, caller, on(plan))
    end

    test "unresolvable target (absent from corpus) -> skip" do
      facade = """
      defmodule MyApp.Deep.Internal.Facade do
        defdelegate parse(input), to: SomeLib.External.Parser
      end
      """

      caller = """
      defmodule MyApp.Caller do
        def run(data), do: MyApp.Deep.Internal.Facade.parse(data)
      end
      """

      plan = prepared([{"facade.ex", facade}, {"caller.ex", caller}])

      assert_unchanged(@subject, facade, on(plan))
      assert_unchanged(@subject, caller, on(plan))
    end

    test "name clash: same name/arity defined locally in the caller -> skip that call site" do
      facade = """
      defmodule MyApp.Deep.Internal.Facade do
        defdelegate parse(input), to: MyApp.Deep.Parser
      end
      """

      caller = """
      defmodule MyApp.Caller do
        def local(data), do: parse(data)
        def parse(x), do: {:local, x}
        def remote(data), do: MyApp.Deep.Internal.Facade.parse(data)
      end
      """

      plan = prepared([{"facade.ex", facade}, {"caller.ex", caller}, parser_target()])

      expected_caller = """
      defmodule MyApp.Caller do
        def local(data), do: parse(data)
        def parse(x), do: {:local, x}
        def remote(data), do: MyApp.Deep.Parser.parse(data)
      end
      """

      assert_rewrites(@subject, caller, expected_caller, on(plan))
    end
  end

  describe "idempotence and compilation" do
    test "second pass is a no-op and rewritten corpus compiles" do
      helper = """
      defmodule MyApp.Deep.Internal.Helper do
        defdelegate parse(input), to: MyApp.Deep.Parser
      end
      """

      caller = """
      defmodule MyApp.Deep.Internal.Caller do
        alias MyApp.Deep.Parser

        def run(data), do: MyApp.Deep.Internal.Helper.parse(data)
      end
      """

      target = """
      defmodule MyApp.Deep.Parser do
        def parse(input), do: {:parsed, input}
      end
      """

      plan =
        prepared([
          {"helper.ex", helper},
          {"caller.ex", caller},
          {"target.ex", target}
        ])

      assert_idempotent(@subject, caller, on(plan))
      assert_idempotent(@subject, helper, on(plan))

      rewritten_caller = apply_refactor(@subject, caller, on(plan))
      rewritten_helper = apply_refactor(@subject, helper, on(plan))

      assert_compiles(target <> "\n" <> rewritten_helper <> "\n" <> rewritten_caller)
    end
  end

  describe "default-OFF" do
    test "without enabled: true, transform/2 is a no-op even with a plan" do
      facade = """
      defmodule MyApp.Deep.Internal.Facade do
        defdelegate parse(input), to: MyApp.Deep.Parser
      end
      """

      caller = """
      defmodule MyApp.Caller do
        def run(data), do: MyApp.Deep.Internal.Facade.parse(data)
      end
      """

      plan = prepared([{"facade.ex", facade}, {"caller.ex", caller}, parser_target()])

      assert_unchanged(@subject, caller, prepared: plan)
      assert_unchanged(@subject, facade, prepared: plan)
    end
  end
end
