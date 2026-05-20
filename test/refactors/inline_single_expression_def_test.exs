defmodule Num42.Refactors.Refactors.InlineSingleExpressionDefTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.InlineSingleExpressionDef

  @subject InlineSingleExpressionDef

  describe "rewrites — single function call body" do
    test "local call with multiple args becomes pipe + do:" do
      before_source = """
      def foo(x, y) do
        bar(x, y)
      end
      """

      after_source = "def foo(x, y), do: x |> bar(y)"

      assert_rewrites(@subject, before_source, after_source)
    end

    test "local call with one arg becomes pipe + do:" do
      before_source = """
      def foo(x) do
        bar(x)
      end
      """

      after_source = "def foo(x), do: x |> bar()"

      assert_rewrites(@subject, before_source, after_source)
    end

    test "qualified call (Module.fun) becomes pipe + do:" do
      before_source = """
      def foo(x, y) do
        Map.put(x, :k, y)
      end
      """

      after_source = "def foo(x, y), do: x |> Map.put(:k, y)"

      assert_rewrites(@subject, before_source, after_source)
    end

    test "0-arity local call becomes inline do: (no pipe)" do
      before_source = """
      def init do
        start_link()
      end
      """

      after_source = "def init, do: start_link()"

      assert_rewrites(@subject, before_source, after_source)
    end

    test "0-arity qualified call becomes inline do:" do
      before_source = """
      def empty do
        Map.new()
      end
      """

      after_source = "def empty, do: Map.new()"

      assert_rewrites(@subject, before_source, after_source)
    end

    test "defp also handled" do
      before_source = """
      defp normalize(user, opts) do
        build_changeset(user, opts, validate: true)
      end
      """

      after_source =
        "defp normalize(user, opts), do: user |> build_changeset(opts, validate: true)"

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "rewrites — pipe body" do
    test "existing pipe becomes do:" do
      before_source = """
      def render(steps) do
        steps
        |> Enum.map(&Sourceror.to_string/1)
        |> Enum.join("\\n")
      end
      """

      after_source =
        "def render(steps), do: steps |> Enum.map(&Sourceror.to_string/1) |> Enum.join(\"\\n\")"

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "rewrites — literal-like body" do
    test "atom literal becomes do:" do
      before_source = """
      def kind do
        :scalar
      end
      """

      after_source = "def kind, do: :scalar"

      assert_rewrites(@subject, before_source, after_source)
    end

    test "boolean literal becomes do:" do
      before_source = """
      def reformat_after? do
        true
      end
      """

      after_source = "def reformat_after?, do: true"

      assert_rewrites(@subject, before_source, after_source)
    end

    test "integer literal becomes do:" do
      before_source = """
      def answer do
        42
      end
      """

      after_source = "def answer, do: 42"

      assert_rewrites(@subject, before_source, after_source)
    end

    test "empty map literal becomes do:" do
      before_source = """
      def empty_table do
        %{}
      end
      """

      after_source = "def empty_table, do: %{}"

      assert_rewrites(@subject, before_source, after_source)
    end

    test "non-empty list literal becomes do:" do
      before_source = """
      def defaults do
        [1, 2, 3]
      end
      """

      after_source = "def defaults, do: [1, 2, 3]"

      assert_rewrites(@subject, before_source, after_source)
    end

    test "bare variable becomes do:" do
      before_source = """
      def foo(x) do
        x
      end
      """

      after_source = "def foo(x), do: x"

      assert_rewrites(@subject, before_source, after_source)
    end

    test "low-precedence body (||) is safe in do: keyword form" do
      # `do: x || y` parses as `[do: (x || y)]` — the keyword colon
      # binds the whole expression, no re-association vs. the outer
      # `def` call. Pin the behaviour so a future "wrap parens"
      # tweak doesn't quietly emit `do: (x || y)`.
      before_source = """
      def foo(x, y) do
        x || y
      end
      """

      after_source = "def foo(x, y), do: x || y"

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "leaves alone — multi-statement bodies" do
    test "two statements skipped" do
      assert_unchanged(@subject, """
      def foo(x) do
        y = x + 1
        bar(y)
      end
      """)
    end
  end

  describe "leaves alone — block constructs" do
    test "case skipped" do
      assert_unchanged(@subject, """
      def classify(x) do
        case x do
          :a -> 1
          :b -> 2
        end
      end
      """)
    end

    test "if skipped" do
      assert_unchanged(@subject, """
      def foo(x) do
        if x, do: :a, else: :b
      end
      """)
    end

    test "with skipped" do
      assert_unchanged(@subject, """
      def foo(x) do
        with {:ok, v} <- fetch(x), do: v
      end
      """)
    end

    test "cond skipped" do
      assert_unchanged(@subject, """
      def foo(x) do
        cond do
          x > 0 -> :pos
          true -> :other
        end
      end
      """)
    end

    test "try skipped" do
      assert_unchanged(@subject, """
      def foo(x) do
        try do
          dangerous(x)
        rescue
          _ -> :err
        end
      end
      """)
    end

    test "fn skipped" do
      assert_unchanged(@subject, """
      def make do
        fn x -> x + 1 end
      end
      """)
    end
  end

  describe "leaves alone — pipe body containing a block construct" do
    test "pipe ending in `case do ... end`" do
      assert_unchanged(@subject, """
      def filename_stem(name) do
        name
        |> to_string()
        |> case do
          "" -> "default"
          n -> n
        end
      end
      """)
    end

    test "pipe with `if do ... end`" do
      assert_unchanged(@subject, """
      def maybe_log(x) do
        x
        |> tap(fn v -> if v, do: log(v) end)
      end
      """)
    end

    test "call wrapped in `with do ... end`" do
      assert_unchanged(@subject, """
      def fetch_user(id) do
        with {:ok, u} <- repo_get(id), do: u
      end
      """)
    end
  end

  describe "leaves alone — body contains a lambda" do
    test "pipe with fn lambda inside" do
      assert_unchanged(@subject, """
      def map_them(xs) do
        xs |> Enum.map(fn x -> x + 1 end)
      end
      """)
    end

    test "call with fn lambda arg" do
      assert_unchanged(@subject, """
      def filter_them(xs) do
        Enum.filter(xs, fn x -> x > 0 end)
      end
      """)
    end

    test "but `&capture/N` is fine and still rewrites" do
      before_source = """
      def upcase_all(xs) do
        Enum.map(xs, &String.upcase/1)
      end
      """

      after_source = "def upcase_all(xs), do: xs |> Enum.map(&String.upcase/1)"

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "rewrites — composite literal-likes" do
    test "interpolated string is rewritten without pipe" do
      before_source = ~S'''
      def msg(format) do
        "Antwort als #{format} kam nicht zurück"
      end
      '''

      after_source = ~S|def msg(format), do: "Antwort als #{format} kam nicht zurück"|

      assert_rewrites(@subject, before_source, after_source)
    end

    test "map literal with computed values is rewritten" do
      before_source = """
      def env do
        %{a: 1, b: 2}
      end
      """

      after_source = "def env, do: %{a: 1, b: 2}"

      assert_rewrites(@subject, before_source, after_source)
    end

    test "tuple literal is rewritten" do
      before_source = """
      def pair(x) do
        {:ok, x}
      end
      """

      after_source = "def pair(x), do: {:ok, x}"

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "leaves alone — sigil body" do
    test "~H heredoc sigil skipped" do
      assert_unchanged(@subject, ~S'''
      def render(assigns) do
        ~H"""
        <div>hello</div>
        """
      end
      ''')
    end

    test "~S single-line sigil skipped" do
      assert_unchanged(@subject, ~S'''
      def label do
        ~S"foo|bar"
      end
      ''')
    end
  end

  describe "leaves alone — def with rescue/catch/after" do
    test "def with rescue branch skipped" do
      assert_unchanged(@subject, """
      def fetch(id) do
        {:ok, get!(id)}
      rescue
        Ecto.NoResultsError -> :error
      end
      """)
    end

    test "def with catch branch skipped" do
      assert_unchanged(@subject, """
      def safe(x) do
        risky(x)
      catch
        :exit, _ -> :err
      end
      """)
    end

    test "def with after branch skipped" do
      assert_unchanged(@subject, """
      def with_lock do
        do_work()
      after
        release_lock()
      end
      """)
    end
  end

  describe "leaves alone — heredoc body" do
    test "heredoc skipped" do
      assert_unchanged(@subject, ~S'''
      def explanation do
        """
        A long
        multi-line
        explanation.
        """
      end
      ''')
    end

    test "single-line string still rewrites" do
      before_source = """
      def greeting do
        "hello"
      end
      """

      after_source = ~s(def greeting, do: "hello")

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "leaves alone — out of scope" do
    test "def with when guard skipped" do
      assert_unchanged(@subject, """
      def foo(x) when is_list(x) do
        bar(x, :tag)
      end
      """)
    end

    test "defmacro skipped" do
      assert_unchanged(@subject, """
      defmacro foo(x) do
        bar(x)
      end
      """)
    end

    test "defmacrop skipped" do
      assert_unchanged(@subject, """
      defmacrop foo(x) do
        bar(x)
      end
      """)
    end

    test "already in do: keyword form" do
      assert_unchanged(@subject, "def foo(x), do: bar(x)")
    end

    test "already in do: keyword form with pipe" do
      assert_unchanged(@subject, "def foo(x), do: x |> bar()")
    end

    test "already in do: keyword form with literal" do
      assert_unchanged(@subject, "def foo, do: :scalar")
    end
  end

  describe "leaves alone — call whose first arg is an `x in Y` binding" do
    # `from(i in Item, where: …)` is `Ecto.Query.from/2`. The first arg
    # is a binding expression `i in Item`, not a value — extracting it
    # into a pipe (`(i in Item) |> from(...)`) is syntactically valid
    # but semantically wrong: `from` is a macro that introspects its
    # arg shape, and pipes don't survive that. Skip the whole rewrite.
    test "Ecto from(i in Item, …) skipped" do
      assert_unchanged(@subject, """
      def all do
        from(i in Item, where: i.active == true, select: i.id)
      end
      """)
    end

    test "Ecto from(i in Item) (single-arg) skipped" do
      assert_unchanged(@subject, """
      def all do
        from(i in Item)
      end
      """)
    end

    # Generalize: any call whose first arg is `x in Y` is a binding
    # form (could be `from`, a user macro, etc.). Leave as-is.
    test "generic call with `in`-binding first arg skipped" do
      assert_unchanged(@subject, """
      def q do
        my_macro(x in Source, opt: 1)
      end
      """)
    end
  end

  describe "idempotent" do
    test "single call body" do
      assert_idempotent(@subject, """
      def foo(x, y) do
        bar(x, y)
      end
      """)
    end

    test "pipe body" do
      assert_idempotent(@subject, """
      def render(steps) do
        steps
        |> Enum.map(&f/1)
        |> Enum.join()
      end
      """)
    end

    test "literal body" do
      assert_idempotent(@subject, """
      def kind do
        :scalar
      end
      """)
    end

    test "block body unchanged" do
      assert_idempotent(@subject, """
      def classify(x) do
        case x do
          :a -> 1
          :b -> 2
        end
      end
      """)
    end

    test "from(i in …) body unchanged across passes" do
      assert_idempotent(@subject, """
      def all do
        from(i in Item, where: i.active == true)
      end
      """)
    end
  end
end
