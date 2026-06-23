defmodule Number42.Refactors.Ex.UnwrapSpanInHeadingTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.UnwrapSpanInHeading

  @subject UnwrapSpanInHeading

  # Enabled by default and takes no opts; kept named for call-shape uniformity.
  @enabled []

  describe "enabled by default" do
    test "unwraps with no enable opt" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule MyView do
          def title(assigns) do
            ~H"""
            <h1><span>Dashboard</span></h1>
            """
          end
        end
        ''',
        ~S'''
        defmodule MyView do
          def title(assigns) do
            ~H"""
            <h1>Dashboard</h1>
            """
          end
        end
        ''',
        []
      )
    end
  end

  describe "unwraps bare span" do
    test "in h1" do
      before_source = ~S'''
      defmodule MyView do
        def title(assigns) do
          ~H"""
          <h1><span>Dashboard</span></h1>
          """
        end
      end
      '''

      after_source = ~S'''
      defmodule MyView do
        def title(assigns) do
          ~H"""
          <h1>Dashboard</h1>
          """
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source, @enabled)
    end

    test "in each of h1..h6" do
      for level <- 1..6 do
        tag = "h#{level}"

        before_source = """
        defmodule MyView do
          def title(assigns) do
            ~H\"\"\"
            <#{tag}><span>Heading</span></#{tag}>
            \"\"\"
          end
        end
        """

        after_source = """
        defmodule MyView do
          def title(assigns) do
            ~H\"\"\"
            <#{tag}>Heading</#{tag}>
            \"\"\"
          end
        end
        """

        assert_rewrites(@subject, before_source, after_source, @enabled)
      end
    end

    test "in header" do
      before_source = ~S'''
      defmodule MyView do
        def head(assigns) do
          ~H"""
          <header><span>Welcome</span></header>
          """
        end
      end
      '''

      after_source = ~S'''
      defmodule MyView do
        def head(assigns) do
          ~H"""
          <header>Welcome</header>
          """
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source, @enabled)
    end

    test "nested deeper inside the heading" do
      before_source = ~S'''
      defmodule MyView do
        def title(assigns) do
          ~H"""
          <h2><small><span>note</span></small></h2>
          """
        end
      end
      '''

      after_source = ~S'''
      defmodule MyView do
        def title(assigns) do
          ~H"""
          <h2><small>note</small></h2>
          """
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source, @enabled)
    end

    test "span wrapping an interpolation" do
      before_source = ~S'''
      defmodule MyView do
        def title(assigns) do
          ~H"""
          <h1><span>{@title}</span></h1>
          """
        end
      end
      '''

      after_source = ~S'''
      defmodule MyView do
        def title(assigns) do
          ~H"""
          <h1>{@title}</h1>
          """
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source, @enabled)
    end
  end

  describe "hoists class onto parent" do
    test "sole-child span with class onto bare h1" do
      before_source = ~S'''
      defmodule MyView do
        def title(assigns) do
          ~H"""
          <h1><span class="title">Dashboard</span></h1>
          """
        end
      end
      '''

      after_source = ~S'''
      defmodule MyView do
        def title(assigns) do
          ~H"""
          <h1 class="title">Dashboard</h1>
          """
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source, @enabled)
    end
  end

  describe "leaves alone" do
    test "span outside any heading/header" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule MyView do
          def body(assigns) do
            ~H"""
            <p><span>plain</span></p>
            """
          end
        end
        ''',
        @enabled
      )
    end

    test "span carrying a non-class attribute" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule MyView do
          def title(assigns) do
            ~H"""
            <h1><span id="t" aria-label="x">Dashboard</span></h1>
            """
          end
        end
        ''',
        @enabled
      )
    end

    test "span with dynamic class expression" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule MyView do
          def title(assigns) do
            ~H"""
            <h1><span class={@cls}>Dashboard</span></h1>
            """
          end
        end
        ''',
        @enabled
      )
    end

    test "classed span that is not the sole child of the heading" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule MyView do
          def title(assigns) do
            ~H"""
            <h1>Hello <span class="title">Dashboard</span></h1>
            """
          end
        end
        ''',
        @enabled
      )
    end

    test "classed span when parent heading already has a class" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule MyView do
          def title(assigns) do
            ~H"""
            <h1 class="big"><span class="title">Dashboard</span></h1>
            """
          end
        end
        ''',
        @enabled
      )
    end

    test "no heading at all" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule MyView do
          def body(assigns) do
            ~H"""
            <div>plain text</div>
            """
          end
        end
        ''',
        @enabled
      )
    end
  end

  describe "idempotent" do
    test "bare span unwrap, running twice equals once" do
      assert_idempotent(
        @subject,
        ~S'''
        defmodule MyView do
          def title(assigns) do
            ~H"""
            <h1><span>Dashboard</span></h1>
            """
          end
        end
        ''',
        @enabled
      )
    end

    test "class-hoist unwrap, running twice equals once" do
      assert_idempotent(
        @subject,
        ~S'''
        defmodule MyView do
          def title(assigns) do
            ~H"""
            <h1><span class="title">Dashboard</span></h1>
            """
          end
        end
        ''',
        @enabled
      )
    end
  end
end
