defmodule Number42.Refactors.Ex.CssClassClusterCorrectionTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.CssClassClusterCorrection, as: Correction

  @subject Correction

  # Detection is the whole problem — the suite is deliberately negative-heavy.
  # Like the other corpus-wide refactors it builds a model in prepare/1 and
  # threads it through transform/2; tests build the model from in-memory
  # sources and pass it as `prepared:`.

  # A file with `n` elements all carrying the convention class set, used to
  # manufacture strong support cheaply.
  defp convention_file(class, n) do
    rows = for _ <- 1..n, do: ~s|      <div class="#{class}">x</div>|

    """
    defmodule Conv do
      use Phoenix.Component
      def render(assigns) do
        ~H\"\"\"
    #{Enum.join(rows, "\n")}
        \"\"\"
      end
    end
    """
  end

  defp outlier_file(class) do
    """
    defmodule Page do
      use Phoenix.Component
      def render(assigns) do
        ~H\"\"\"
          <div class="#{class}">x</div>
        \"\"\"
      end
    end
    """
  end

  defp model(sources, opts \\ []), do: Correction.build_model(sources, opts)

  describe "default-OFF (opt-in only)" do
    test "without enabled: true, prepare is :no_cache and transform is a no-op" do
      assert Correction.prepare([]) == :no_cache

      outlier = outlier_file("mt1 pb3 gap2")
      built = model([{"lib/conv.ex", convention_file("mt1 pb2 gap2", 12)}])
      assert_unchanged(@subject, outlier, prepared: built)
    end

    test "with enabled but no model (nil prepared), transform is a no-op" do
      assert_unchanged(@subject, outlier_file("mt1 pb3 gap2"), enabled: true, prepared: nil)
    end
  end

  describe "outlier detection (Slice 3)" do
    test "flags a class set one token off from a strong convention" do
      built = model([{"lib/conv.ex", convention_file("mt1 pb2 gap2", 12)}])
      [c] = Correction.corrections(built, outlier_file("mt1 pb3 gap2"))

      assert c.bad == :pb3
      assert c.good == :pb2
      assert c.classes == MapSet.new([:mt1, :pb3, :gap2])
    end

    test "no correction when the deviation is more than one token off" do
      built = model([{"lib/conv.ex", convention_file("mt1 pb2 gap2", 12)}])
      assert Correction.corrections(built, outlier_file("mt1 pb3 gap4")) == []
    end

    test "no correction across utility families (pb3 vs flex is not a typo)" do
      built = model([{"lib/conv.ex", convention_file("mt1 pb2 gap2", 12)}])
      assert Correction.corrections(built, outlier_file("mt1 flex gap2")) == []
    end

    test "no correction below the support threshold" do
      built = model([{"lib/conv.ex", convention_file("mt1 pb2 gap2", 3)}])
      assert Correction.corrections(built, outlier_file("mt1 pb3 gap2")) == []
    end

    test "no correction when the deviation itself recurs strongly (intentional one-off)" do
      built =
        model([
          {"lib/conv.ex", convention_file("mt1 pb2 gap2", 12)},
          {"lib/tight.ex", convention_file("mt1 pb3 gap2", 12)}
        ])

      assert Correction.corrections(built, outlier_file("mt1 pb3 gap2")) == []
    end
  end

  describe "rewrite (Slice 3 — end to end)" do
    test "corrects the lone deviating token, preserving the others" do
      built = model([{"lib/conv.ex", convention_file("mt1 pb2 gap2", 12)}])

      before = outlier_file("mt1 pb3 gap2")
      after_src = apply_refactor(@subject, before, enabled: true, prepared: built)

      # Substring assertions, not assert_compiles: Phoenix.Component is not a
      # dep of this library, so an ~H sigil cannot be compiled here (same as
      # the HeexAttributeBundleToComponent suite).
      assert after_src =~ ~s|class="mt1 pb2 gap2"|
      refute after_src =~ "pb3"
    end

    test "is idempotent — a corrected site matches the convention and is left alone" do
      built = model([{"lib/conv.ex", convention_file("mt1 pb2 gap2", 12)}])
      assert_idempotent(@subject, outlier_file("mt1 pb3 gap2"), enabled: true, prepared: built)
    end

    test "leaves an already-conformant site unchanged" do
      built = model([{"lib/conv.ex", convention_file("mt1 pb2 gap2", 12)}])
      assert_unchanged(@subject, outlier_file("mt1 pb2 gap2"), enabled: true, prepared: built)
    end

    test "leaves an unrelated class set unchanged" do
      built = model([{"lib/conv.ex", convention_file("mt1 pb2 gap2", 12)}])

      assert_unchanged(@subject, outlier_file("flex items-center"),
        enabled: true,
        prepared: built
      )
    end
  end

  describe "corpus scoping" do
    test "test/ and dev/ sources do not seed conventions" do
      built =
        model([
          {"test/page_test.exs", convention_file("mt1 pb2 gap2", 12)},
          {"dev/seed.ex", convention_file("mt1 pb2 gap2", 12)}
        ])

      assert Correction.corrections(built, outlier_file("mt1 pb3 gap2")) == []
    end
  end
end
