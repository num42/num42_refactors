defmodule Number42.Refactors.Ex.RelocateMisplacedFunctionTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.RelocateMisplacedFunction

  @subject RelocateMisplacedFunction

  # RelocateMisplacedFunction is a real move-method refactor with a
  # graph constraint. Like ExtractSharedModule it has a disk side-effect:
  # prepare/1 appends the moved function to the target module's file.
  # Tests run in a per-test tmp_dir and pass `:write_root` so writes are
  # contained.

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "relocate_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp prepared(sources, opts),
    do: RelocateMisplacedFunction.build_plan(sources, opts)

  # The relocation appends the moved function to the *existing* target
  # file on disk. In production that file is already on disk; here we
  # materialize the source strings under `tmp` (mirroring `write_root`)
  # before planning so `append_to_target/4` has a file to append into.
  defp materialize(sources, tmp) do
    Enum.each(sources, fn {rel, src} ->
      path = Path.join(tmp, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, src)
    end)

    sources
  end

  describe "default-OFF (opt-in only)" do
    test "without enabled: true, prepare is :no_cache and transform is a no-op", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def brand_label(%B{} = brand) do
          B.name(brand) <> " (" <> B.code(brand) <> ")"
        end
      end
      """

      b = struct_b()
      paths = materialize([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], tmp)

      # prepare/1 must not touch disk when disabled.
      assert RelocateMisplacedFunction.prepare(source_files: Enum.map(paths, &elem(&1, 0))) ==
               :no_cache

      # transform/2 leaves the source untouched even with a real plan,
      # as long as enabled: true is absent.
      plan = prepared(paths, write_root: tmp)
      assert_unchanged(@subject, a, prepared: plan)
    end
  end

  describe "rewrites — feature-envy move" do
    test "moves an envious function into its target module and delegates", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def brand_label(%B{} = brand) do
          B.name(brand) <> " (" <> B.code(brand) <> ")"
        end
      end
      """

      b = """
      defmodule MyApp.B do
        defstruct [:name, :code]

        def name(%__MODULE__{name: n}), do: n
        def code(%__MODULE__{code: c}), do: c
      end
      """

      caller = """
      defmodule MyApp.Caller do
        alias MyApp.A

        def render(brand), do: A.brand_label(brand)
      end
      """

      paths =
        materialize(
          [{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}, {"lib/my_app/caller.ex", caller}],
          tmp
        )

      plan = prepared(paths, write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan, enabled: true)
      # The host keeps a deprecated defdelegate to the target.
      assert result_a =~ "defdelegate brand_label(brand), to: MyApp.B"
      # The moved body was the only user of `alias MyApp.B`; the delegate
      # uses the fully-qualified name, so the now-dead alias is pruned (#381).
      refute result_a =~ "alias MyApp.B"

      result_caller = apply_refactor(@subject, caller, prepared: plan, enabled: true)
      # The call site now points at the target module.
      assert result_caller =~ "MyApp.B.brand_label(brand)"
      refute result_caller =~ "A.brand_label"
      # `alias MyApp.A` only served the redirected call → pruned (#381).
      refute result_caller =~ "alias MyApp.A"

      target_source = File.read!(Path.join(tmp, "lib/my_app/b.ex"))
      # The moved body keeps its struct pattern, and the host's `B`
      # alias is fully qualified so it resolves inside the target.
      assert target_source =~ "def brand_label(%MyApp.B{} = brand)"
      assert target_source =~ "MyApp.B.name(brand)"

      # The whole rewritten corpus compiles together.
      assert_compiles(result_a <> "\n" <> target_source <> "\n" <> result_caller)
    end

    test "host file with no other content is rewritten to just the delegate", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def describe(%B{} = b) do
          B.name(b) <> B.code(b)
        end
      end
      """

      b = """
      defmodule MyApp.B do
        defstruct [:name, :code]

        def name(%__MODULE__{name: n}), do: n
        def code(%__MODULE__{code: c}), do: c
      end
      """

      paths = materialize([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], tmp)
      plan = prepared(paths, write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan, enabled: true)
      assert result_a =~ "defdelegate describe(b), to: MyApp.B"
      refute result_a =~ "B.name(b)"

      target_source = File.read!(Path.join(tmp, "lib/my_app/b.ex"))
      assert target_source =~ "def describe(%MyApp.B{} = b)"
    end
  end

  describe "rewrites — pipe and capture call sites" do
    # An envious function in A that B can host, plus callers using the
    # pipe / capture shapes. Reused across the shape tests below.
    defp shape_sources do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def brand_label(%B{} = brand) do
          B.name(brand) <> " (" <> B.code(brand) <> ")"
        end
      end
      """

      b = """
      defmodule MyApp.B do
        defstruct [:name, :code]

        def name(%__MODULE__{name: n}), do: n
        def code(%__MODULE__{code: c}), do: c
      end
      """

      {a, b}
    end

    test "pipe-form call site is qualified to the target module", %{tmp: tmp} do
      {a, b} = shape_sources()

      caller = """
      defmodule MyApp.Caller do
        alias MyApp.A

        def render(brand), do: brand |> A.brand_label()
      end
      """

      paths =
        materialize(
          [{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}, {"lib/my_app/caller.ex", caller}],
          tmp
        )

      plan = prepared(paths, write_root: tmp)

      result_caller = apply_refactor(@subject, caller, prepared: plan, enabled: true)
      assert result_caller =~ "brand |> MyApp.B.brand_label()"
      refute result_caller =~ "A.brand_label"
    end

    test "capture-with-arity call site (&A.fn/1) is qualified", %{tmp: tmp} do
      {a, b} = shape_sources()

      caller = """
      defmodule MyApp.Caller do
        alias MyApp.A

        def labels(brands), do: Enum.map(brands, &A.brand_label/1)
      end
      """

      paths =
        materialize(
          [{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}, {"lib/my_app/caller.ex", caller}],
          tmp
        )

      plan = prepared(paths, write_root: tmp)

      result_caller = apply_refactor(@subject, caller, prepared: plan, enabled: true)
      assert result_caller =~ "&MyApp.B.brand_label/1"
      refute result_caller =~ "&A.brand_label"
    end

    test "capture-body call site (&A.fn(&1)) is qualified", %{tmp: tmp} do
      {a, b} = shape_sources()

      caller = """
      defmodule MyApp.Caller do
        alias MyApp.A

        def labels(brands), do: Enum.map(brands, &A.brand_label(&1))
      end
      """

      paths =
        materialize(
          [{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}, {"lib/my_app/caller.ex", caller}],
          tmp
        )

      plan = prepared(paths, write_root: tmp)

      result_caller = apply_refactor(@subject, caller, prepared: plan, enabled: true)
      assert result_caller =~ "&MyApp.B.brand_label(&1)"
      refute result_caller =~ "&A.brand_label"
    end

    test "all three shapes in one file are rewritten and the corpus compiles", %{tmp: tmp} do
      {a, b} = shape_sources()

      caller = """
      defmodule MyApp.Caller do
        alias MyApp.A

        def via_pipe(brand), do: brand |> A.brand_label()
        def via_capture(brands), do: Enum.map(brands, &A.brand_label/1)
        def via_capture_body(brands), do: Enum.map(brands, &A.brand_label(&1))
      end
      """

      paths =
        materialize(
          [{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}, {"lib/my_app/caller.ex", caller}],
          tmp
        )

      plan = prepared(paths, write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan, enabled: true)
      result_caller = apply_refactor(@subject, caller, prepared: plan, enabled: true)
      target_source = File.read!(Path.join(tmp, "lib/my_app/b.ex"))

      assert result_caller =~ "brand |> MyApp.B.brand_label()"
      assert result_caller =~ "&MyApp.B.brand_label/1"
      assert result_caller =~ "&MyApp.B.brand_label(&1)"
      refute result_caller =~ "A.brand_label"

      assert_compiles(result_a <> "\n" <> target_source <> "\n" <> result_caller)
    end
  end

  describe "alias with :as resolves at the call site" do
    # Regression for #198: `alias MyApp.A, as: Host` wraps the `:as`
    # keyword key as `{:__block__, _, [:as]}`. `collect_aliases/1` must
    # unwrap that, otherwise the alias is never recorded and every
    # call-site rewrite shape (direct, pipe, capture) misses the host.
    test "direct call via :as alias is qualified to the target", %{tmp: tmp} do
      {a, b} = shape_sources()

      caller = """
      defmodule MyApp.Caller do
        alias MyApp.A, as: Host

        def render(brand), do: Host.brand_label(brand)
      end
      """

      paths =
        materialize(
          [{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}, {"lib/my_app/caller.ex", caller}],
          tmp
        )

      plan = prepared(paths, write_root: tmp)

      result_caller = apply_refactor(@subject, caller, prepared: plan, enabled: true)
      assert result_caller =~ "MyApp.B.brand_label(brand)"
      refute result_caller =~ "Host.brand_label"
    end

    test "pipe and capture call sites via :as alias are qualified", %{tmp: tmp} do
      {a, b} = shape_sources()

      caller = """
      defmodule MyApp.Caller do
        alias MyApp.A, as: Host

        def via_pipe(brand), do: brand |> Host.brand_label()
        def via_capture(brands), do: Enum.map(brands, &Host.brand_label/1)
        def via_capture_body(brands), do: Enum.map(brands, &Host.brand_label(&1))
      end
      """

      paths =
        materialize(
          [{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}, {"lib/my_app/caller.ex", caller}],
          tmp
        )

      plan = prepared(paths, write_root: tmp)

      result_caller = apply_refactor(@subject, caller, prepared: plan, enabled: true)
      assert result_caller =~ "brand |> MyApp.B.brand_label()"
      assert result_caller =~ "&MyApp.B.brand_label/1"
      assert result_caller =~ "&MyApp.B.brand_label(&1)"
      refute result_caller =~ "Host.brand_label"
    end
  end

  describe "configurable min_envy_refs" do
    test "min_envy_refs: 1 relocates a thin forwarder the default leaves alone", %{tmp: tmp} do
      # A single reference to B: at the default threshold of 2 this is
      # mere delegation and stays put; lowering the threshold to 1 makes
      # it a relocation candidate.
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def forward(brand), do: B.name(brand)
      end
      """

      b = struct_b()
      paths = materialize([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], tmp)

      # Default threshold (2): no move.
      default_plan = prepared(paths, write_root: tmp)
      assert_unchanged(@subject, a, prepared: default_plan, enabled: true)
      refute File.read!(Path.join(tmp, "lib/my_app/b.ex")) =~ "def forward"

      # Lowered threshold (1): the forwarder relocates.
      plan = prepared(paths, write_root: tmp, min_envy_refs: 1)
      result_a = apply_refactor(@subject, a, prepared: plan, enabled: true)
      assert result_a =~ "defdelegate forward(brand), to: MyApp.B"

      target_source = File.read!(Path.join(tmp, "lib/my_app/b.ex"))
      assert target_source =~ "def forward(brand), do: MyApp.B.name(brand)"
    end

    test "min_envy_refs: 3 leaves a two-reference body the default relocates", %{tmp: tmp} do
      # Two references to B: relocated at the default threshold of 2, but
      # raising the threshold to 3 keeps it in place.
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def describe(%B{} = b) do
          B.name(b) <> B.code(b)
        end
      end
      """

      b = struct_b()
      paths = materialize([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], tmp)

      # Raised threshold (3): no move.
      plan = prepared(paths, write_root: tmp, min_envy_refs: 3)
      assert_unchanged(@subject, a, prepared: plan, enabled: true)
      refute File.read!(Path.join(tmp, "lib/my_app/b.ex")) =~ "def describe"
    end

    test "non-positive min_envy_refs falls back to the default", %{tmp: tmp} do
      # A single reference: with the default of 2 it stays. A bogus
      # threshold (0) must not silently lower the bar — it falls back to
      # the default, so the forwarder is still left alone.
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def forward(brand), do: B.name(brand)
      end
      """

      b = struct_b()
      paths = materialize([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], tmp)

      plan = prepared(paths, write_root: tmp, min_envy_refs: 0)
      assert_unchanged(@subject, a, prepared: plan, enabled: true)
      refute File.read!(Path.join(tmp, "lib/my_app/b.ex")) =~ "def forward"
    end
  end

  describe "idempotence" do
    test "second pass after move is a no-op", %{tmp: tmp} do
      # The host already delegates; the target already owns the function.
      # The `alias MyApp.B` the moved body needed is gone — the delegate
      # references `MyApp.B` fully-qualified, so the first pass prunes the
      # now-dead alias (#381) and the second pass has nothing left to do.
      a_after = """
      defmodule MyApp.A do
        defdelegate brand_label(brand), to: MyApp.B
      end
      """

      b_after = """
      defmodule MyApp.B do
        defstruct [:name, :code]

        def name(%__MODULE__{name: n}), do: n
        def code(%__MODULE__{code: c}), do: c

        def brand_label(%B{} = brand) do
          B.name(brand) <> " (" <> B.code(brand) <> ")"
        end
      end
      """

      caller_after = """
      defmodule MyApp.Caller do
        def render(brand), do: MyApp.B.brand_label(brand)
      end
      """

      paths = [
        {"lib/my_app/a.ex", a_after},
        {"lib/my_app/b.ex", b_after},
        {"lib/my_app/caller.ex", caller_after}
      ]

      plan = prepared(paths, write_root: tmp)

      assert_unchanged(@subject, a_after, prepared: plan, enabled: true)
      assert_unchanged(@subject, b_after, prepared: plan, enabled: true)
      assert_unchanged(@subject, caller_after, prepared: plan, enabled: true)
    end
  end

  describe "skips" do
    test "function referencing a host private member is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def label(%B{} = brand) do
          B.name(brand) <> suffix()
        end

        defp suffix, do: "!"
      end
      """

      b = struct_b()
      plan = prepared([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan, enabled: true)
      refute File.exists?(Path.join(tmp, "lib/my_app/b.ex"))
    end

    test "function referencing __MODULE__ of the host is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def label(%B{} = brand) do
          B.name(brand) <> inspect(__MODULE__)
        end
      end
      """

      b = struct_b()
      plan = prepared([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan, enabled: true)
    end

    test "function referencing a host module attribute is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        @sep " - "

        def label(%B{} = brand) do
          B.name(brand) <> @sep <> B.code(brand)
        end
      end
      """

      b = struct_b()
      plan = prepared([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan, enabled: true)
    end

    test "name clash of same arity in target is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def name(%B{} = brand) do
          B.code(brand) <> B.code(brand)
        end
      end
      """

      # B already defines name/1.
      b = struct_b()
      plan = prepared([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan, enabled: true)
    end

    test "would-be cycle (target already references host) is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def label(%B{} = brand) do
          B.name(brand) <> B.code(brand)
        end

        def helper(x), do: x
      end
      """

      # B references A → moving label into B keeps A.helper around and A
      # would delegate to B, but B already depends on A: a cycle risk.
      b = """
      defmodule MyApp.B do
        defstruct [:name, :code]

        def name(%__MODULE__{name: n}), do: MyApp.A.helper(n)
        def code(%__MODULE__{code: c}), do: c
      end
      """

      plan = prepared([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan, enabled: true)
    end

    test "dynamic apply of the function makes the move unsafe", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def label(%B{} = brand) do
          B.name(brand) <> B.code(brand)
        end
      end
      """

      caller = """
      defmodule MyApp.Caller do
        def render(brand), do: apply(MyApp.A, :label, [brand])
      end
      """

      b = struct_b()

      plan =
        prepared(
          [
            {"lib/my_app/a.ex", a},
            {"lib/my_app/b.ex", b},
            {"lib/my_app/caller.ex", caller}
          ],
          write_root: tmp
        )

      assert_unchanged(@subject, a, prepared: plan, enabled: true)
    end

    test "function with no envied module reference is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        def add(x, y) do
          x + y + 1
        end
      end
      """

      plan = prepared([{"lib/my_app/a.ex", a}], write_root: tmp)
      assert_unchanged(@subject, a, prepared: plan, enabled: true)
    end

    test "function envying two different modules equally is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B
        alias MyApp.C

        def combine(b, c) do
          B.name(b) <> C.name(c)
        end
      end
      """

      b = struct_b()

      c = """
      defmodule MyApp.C do
        defstruct [:name]
        def name(%__MODULE__{name: n}), do: n
      end
      """

      plan =
        prepared(
          [{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}, {"lib/my_app/c.ex", c}],
          write_root: tmp
        )

      assert_unchanged(@subject, a, prepared: plan, enabled: true)
    end

    test "target module not present in corpus is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def label(%B{} = brand) do
          B.name(brand) <> B.code(brand)
        end
      end
      """

      # No file defines MyApp.B — we cannot append into a module we
      # cannot see.
      plan = prepared([{"lib/my_app/a.ex", a}], write_root: tmp)
      assert_unchanged(@subject, a, prepared: plan, enabled: true)
    end

    # Regression for #373: `mount/3`, `handle_event/3`, `render/1`, … are
    # framework callbacks. Their arity is externally imposed and they depend
    # on the host's `use ..., :live_view` context; relocating one into a plain
    # module strips that context and breaks compile. Never a candidate, even
    # when the body references another module enough to look envious.
    test "framework callback (handle_event/3) is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.A do
        alias MyApp.B

        def handle_event("save", params, socket) do
          B.persist(params)
          B.notify(socket)
        end
      end
      """

      b = """
      defmodule MyApp.B do
        def persist(p), do: p
        def notify(s), do: s
      end
      """

      plan = prepared([{"lib/my_app/a.ex", a}, {"lib/my_app/b.ex", b}], write_root: tmp)
      # Declined: the host keeps the callback, no delegate is emitted, and
      # nothing is appended to a target file.
      assert_unchanged(@subject, a, prepared: plan, enabled: true)
    end

    # Regression for #373: a function calling `Repo.get_by(Asset, …)` twice
    # envies `Repo` by reference count, but `Repo` (a `use Ecto.Repo` module)
    # is a data-access boundary, not a domain home — appending a domain
    # function there is meaningless and, for a generated module, uncompilable.
    # An infra (`use Ecto.Repo`/`GenServer`/…) target is declined.
    test "infra-module target (use Ecto.Repo) is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.Assets do
        alias MyApp.Repo
        alias MyApp.Asset

        def get_by_slug_or_id(x) do
          Repo.get_by(Asset, slug: x) || Repo.get_by(Asset, id: x)
        end
      end
      """

      repo = """
      defmodule MyApp.Repo do
        use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
      end
      """

      plan =
        prepared([{"lib/my_app/assets.ex", a}, {"lib/my_app/repo.ex", repo}], write_root: tmp)

      assert_unchanged(@subject, a, prepared: plan, enabled: true)
    end

    # Regression for #373: the body uses `from(e in schema, …)` — the
    # `Ecto.Query.from/1` macro, in scope only because the *host* does
    # `import Ecto.Query`. The target lacks that import, so the relocated
    # body would not compile (`undefined variable "e"`). Declined.
    test "body using a host-only imported macro is left alone", %{tmp: tmp} do
      a = """
      defmodule MyApp.Backfill do
        import Ecto.Query
        alias MyApp.Embeddable

        def purge(schema) do
          Embeddable.repo().update_all(from(e in schema, where: not is_nil(e.embedding)),
            set: [embedding: nil]
          )
        end
      end
      """

      b = """
      defmodule MyApp.Embeddable do
        def repo, do: MyApp.Repo
        def schemas, do: []
      end
      """

      plan =
        prepared([{"lib/my_app/backfill.ex", a}, {"lib/my_app/embeddable.ex", b}],
          write_root: tmp,
          min_envy_refs: 1
        )

      assert_unchanged(@subject, a, prepared: plan, enabled: true)
    end

    # Regression for #373: the target module lives at a non-conventional path
    # (`lib/my_app/live/cursor.ex`, not the `lib/my_app/cursor.ex` its module
    # name implies). The append must find the *real* file; otherwise the def
    # never lands and the host is left delegating to a function the target
    # never defines. With no def landing the whole relocation is declined.
    test "target at a non-conventional path still receives the def", %{tmp: tmp} do
      a = """
      defmodule MyApp.Source do
        alias MyApp.Cursor

        def resolve(%Cursor{} = c, limit) do
          Cursor.decode(c) |> Cursor.take(limit)
        end
      end
      """

      # Module MyApp.Cursor, but on disk under a `live/` subdir.
      cursor = """
      defmodule MyApp.Cursor do
        defstruct [:offset]
        def decode(c), do: c
        def take(c, _n), do: c
      end
      """

      paths =
        materialize(
          [{"lib/my_app/source.ex", a}, {"lib/my_app/live/cursor.ex", cursor}],
          tmp
        )

      plan = prepared(paths, write_root: tmp)

      result_a = apply_refactor(@subject, a, prepared: plan, enabled: true)
      assert result_a =~ "defdelegate resolve(c, limit), to: MyApp.Cursor"

      # The def landed in the REAL file, not a convention-guessed path.
      target_source = File.read!(Path.join(tmp, "lib/my_app/live/cursor.ex"))
      assert target_source =~ "def resolve(%MyApp.Cursor{} = c, limit)"
      refute File.exists?(Path.join(tmp, "lib/my_app/cursor.ex"))
    end
  end

  defp struct_b do
    """
    defmodule MyApp.B do
      defstruct [:name, :code]

      def name(%__MODULE__{name: n}), do: n
      def code(%__MODULE__{code: c}), do: c
    end
    """
  end
end
