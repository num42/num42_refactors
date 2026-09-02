defmodule Number42.Refactors.Ex.ExtractStringBindingToAttributeTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.ExtractStringBindingToAttribute

  @subject ExtractStringBindingToAttribute

  describe "rewrites" do
    test "hoists an inline string binding into a function-named attribute" do
      before_source = ~S'''
      defmodule M do
        defp on_apply_user_email_result({:ok, applied_user}, actor, socket) do
          info = "Ein Link zur Bestätigung wurde an die neue Adresse versendet."
          notify(actor, applied_user, socket, info)
        end
      end
      '''

      after_source = ~S'''
      defmodule M do
        @apply_user_email_result_info_text "Ein Link zur Bestätigung wurde an die neue Adresse versendet."

        defp on_apply_user_email_result({:ok, applied_user}, actor, socket) do
          info = @apply_user_email_result_info_text
          notify(actor, applied_user, socket, info)
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source)
    end

    test "clauses sharing a name and a value collapse onto one attribute" do
      before_source = ~S'''
      defmodule M do
        defp on_result(:ok) do
          message = "Der Vorgang wurde erfolgreich abgeschlossen."
          log(message)
        end

        defp on_result(:retry) do
          message = "Der Vorgang wurde erfolgreich abgeschlossen."
          retry(message)
        end
      end
      '''

      after_source = ~S'''
      defmodule M do
        @result_message_text "Der Vorgang wurde erfolgreich abgeschlossen."

        defp on_result(:ok) do
          message = @result_message_text
          log(message)
        end

        defp on_result(:retry) do
          message = @result_message_text
          retry(message)
        end
      end
      '''

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "leaves alone" do
    test "a name already taken by an existing attribute" do
      source = ~S'''
      defmodule M do
        @result_info_text "Schon vergeben."

        defp on_result(arg) do
          info = "Ein Link zur Bestätigung wurde versendet."
          {arg, info}
        end
      end
      '''

      assert_unchanged(@subject, source)
    end

    test "clauses that derive the same name from different values" do
      source = ~S'''
      defmodule M do
        defp on_result(:ok) do
          info = "Der Vorgang wurde erfolgreich abgeschlossen."
          log(info)
        end

        defp on_result(:error) do
          info = "Der Vorgang konnte nicht abgeschlossen werden."
          log(info)
        end
      end
      '''

      assert_unchanged(@subject, source)
    end

    test "a short string reads fine inline" do
      source = ~S'''
      defmodule M do
        defp on_result(arg) do
          info = "kurz"
          {arg, info}
        end
      end
      '''

      assert_unchanged(@subject, source)
    end

    test "an interpolated string is not a constant" do
      source = ~S'''
      defmodule M do
        defp on_result(arg) do
          info = "Der Vorgang #{arg} wurde erfolgreich abgeschlossen."
          info
        end
      end
      '''

      assert_unchanged(@subject, source)
    end

    test "a binding outside any function has no function name to borrow" do
      source = ~S'''
      defmodule M do
        @moduledoc "Ein Modul, das nichts weiter tut als hier zu stehen."
      end
      '''

      assert_unchanged(@subject, source)
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      source = ~S'''
      defmodule M do
        defp on_apply_user_email_result(actor) do
          info = "Ein Link zur Bestätigung wurde an die neue Adresse versendet."
          {actor, info}
        end
      end
      '''

      assert_idempotent(@subject, source)
    end
  end
end
