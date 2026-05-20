defmodule Num42.Refactors.Refactors.ExtractInlineBlockTest do
  use Num42.RefactorCase, async: true

  alias Num42.Refactors.Refactors.ExtractInlineBlock

  @subject ExtractInlineBlock

  describe "rewrites" do
    test "shared trailing statement-sequence becomes a private helper" do
      source = """
      defmodule MyApp.Sender do
        def send_email(user, payload) do
          envelope = build_envelope(user)
          formatted = format_payload(payload)
          enriched = attach_metadata(envelope, formatted)
          dispatch(enriched)
          :ok
        end

        def send_sms(user, payload) do
          envelope = build_envelope(user)
          formatted = format_payload(payload)
          enriched = attach_metadata(envelope, formatted)
          dispatch(enriched)
          :ok
        end
      end
      """

      expected = """
      defmodule MyApp.Sender do
        def send_email(user, payload) do
          extracted_block(user, payload)
        end

        def send_sms(user, payload) do
          extracted_block(user, payload)
        end

        defp extracted_block(user, payload) do
          envelope = build_envelope(user)
          formatted = format_payload(payload)
          enriched = attach_metadata(envelope, formatted)
          dispatch(enriched)
          :ok
        end
      end
      """

      assert_rewrites(@subject, source, expected, min_mass: 5)
    end

    test "block with one free var threads it through the helper signature" do
      source = """
      defmodule MyApp.Multi do
        def first(state) do
          a = compute(state)
          b = transform(a)
          finalize(b)
        end

        def second(state) do
          a = compute(state)
          b = transform(a)
          finalize(b)
        end
      end
      """

      expected = """
      defmodule MyApp.Multi do
        def first(state) do
          extracted_block(state)
        end

        def second(state) do
          extracted_block(state)
        end

        defp extracted_block(state) do
          a = compute(state)
          b = transform(a)
          finalize(b)
        end
      end
      """

      assert_rewrites(@subject, source, expected, min_mass: 5)
    end
  end

  describe "skips" do
    test "below min_mass — micro-clones not worth extracting" do
      source = """
      defmodule MyApp.Tiny do
        def foo(x) do
          x + 1
        end

        def bar(x) do
          x + 1
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 50)
    end

    test "single function body — no clone, nothing to extract" do
      source = """
      defmodule MyApp.Solo do
        def lonely(x) do
          a = compute(x)
          b = transform(a)
          finalize(b)
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 5)
    end

    test "free var not in function params — bail out (closure over outer scope)" do
      source = """
      defmodule MyApp.Closure do
        @config :foo

        def first(state) do
          tail = handle(state, @config)
          tail
        end

        def second(other) do
          tail = handle(other, @config)
          tail
        end
      end
      """

      assert_unchanged(@subject, source, min_mass: 5)
    end
  end

  describe "idempotence" do
    test "rewriting twice yields the same result" do
      source = """
      defmodule MyApp.Sender do
        def send_email(user, payload) do
          envelope = build_envelope(user)
          formatted = format_payload(payload)
          enriched = attach_metadata(envelope, formatted)
          dispatch(enriched)
          :ok
        end

        def send_sms(user, payload) do
          envelope = build_envelope(user)
          formatted = format_payload(payload)
          enriched = attach_metadata(envelope, formatted)
          dispatch(enriched)
          :ok
        end
      end
      """

      assert_idempotent(@subject, source, min_mass: 5)
    end
  end
end
