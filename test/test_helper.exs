# `assert_compiles/1` calls `Code.compile_string/1`, which mutates the
# global BEAM module namespace. Test sources share generic module names
# (`M`, `A`, `B`), so two async tests compiling at once can purge each
# other's module mid-flight. This Agent serializes compile+purge into one
# critical section; see `Number42.RefactorCase.assert_compiles/1`.
{:ok, _} = Agent.start_link(fn -> nil end, name: Number42.RefactorCase.CompileLock)

ExUnit.start()
