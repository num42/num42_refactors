defmodule Number42.Refactors.Ex.RemoveDeadPrivateFunctionTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.RemoveDeadPrivateFunction

  @subject RemoveDeadPrivateFunction

  describe "rewrites — canonical dead-code elimination" do
    test "deletes a private function with no call site" do
      before_source = """
      defmodule M do
        def used, do: helper_a()
        defp helper_a, do: :ok
        defp helper_b, do: :never_called
      end
      """

      after_source = """
      defmodule M do
        def used, do: helper_a()
        defp helper_a, do: :ok
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "deletes the dead defp's attached @doc and @spec" do
      before_source = """
      defmodule M do
        def used, do: :ok

        @doc false
        @spec dead(integer()) :: integer()
        defp dead(x), do: x * 2
      end
      """

      after_source = """
      defmodule M do
        def used, do: :ok
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "deletes a whole transitive-dead cluster in one pass" do
      before_source = """
      defmodule M do
        def used, do: :ok
        defp dead_a, do: dead_b()
        defp dead_b, do: :unreachable
      end
      """

      after_source = """
      defmodule M do
        def used, do: :ok
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end

    test "deletes all clauses of a multi-clause dead defp" do
      before_source = """
      defmodule M do
        def used, do: :ok
        defp dead(:a), do: 1
        defp dead(:b), do: 2
      end
      """

      after_source = """
      defmodule M do
        def used, do: :ok
      end
      """

      assert_rewrites(@subject, before_source, after_source)
    end
  end

  describe "leaves live functions alone" do
    test "keeps a defp called directly" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used, do: helper()
          defp helper, do: :ok
        end
        """
      )
    end

    test "keeps a defp referenced only via a capture &name/arity" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used, do: Enum.map([1, 2], &double/1)
          defp double(x), do: x * 2
        end
        """
      )
    end

    test "keeps a defp reachable transitively from a public def" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used, do: mid()
          defp mid, do: leaf()
          defp leaf, do: :ok
        end
        """
      )
    end

    # A defp with a default arg is callable at every arity from its
    # required count to its declared count. `build/2` calls it at /2;
    # the definition is /3. Reachability must register both arities, or
    # the live function is wrongly deleted (taking its recursive helper
    # with it) and the caller no longer compiles.
    test "keeps a defp called at a lower arity than declared (default arg)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def build(id, parent_map) do
            ancestry = build_ancestry(id, parent_map)
            ancestry ++ [id]
          end

          defp build_ancestry(id, parent_map, acc \\\\ []),
            do: parent_map |> Map.get(id) |> recurse_or_done(acc, parent_map)

          defp recurse_or_done(nil, acc, _parent_map), do: acc
          defp recurse_or_done(pid, acc, parent_map),
            do: build_ancestry(pid, parent_map, [pid | acc])
        end
        """
      )
    end

    # Two definition groups of the same name answer the same callable
    # arity: `slug_url/2` (its own body calls private helpers) and a
    # `slug_url(slug, w \\\\ nil, ...)` default-arg clause. Indexing the
    # call graph by `{name, arity}` once collided — the second group
    # overwrote the first — so the helpers reached only from the `/2`
    # body looked dead and were deleted, breaking compilation. Both
    # groups' call edges must survive. Regression: position-db MediaUrl
    # after SplitPipeableResponsibilities split slug_url/2.
    test "keeps helpers reached from one of two same-name groups sharing an arity" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def slug_url(slug, opts) when is_list(opts) do
            {h, w} = slug_url_phase_1(opts)
            slug_url_phase_2(h, w, slug)
          end

          def slug_url(slug, width \\\\ nil, height \\\\ nil),
            do: gen_url(slug, width, height)

          defp slug_url_phase_1(opts), do: {opts[:h], opts[:w]}
          defp slug_url_phase_2(h, w, slug), do: gen_url(slug, w, h)
          defp gen_url(_s, _w, _h), do: :ok
        end
        """
      )
    end

    # A defp called from the compile-time body of a `defmacro` — before
    # the `quote do` — runs at macro-expansion time. The reachability
    # scan must register that call, or the live helper is deleted and the
    # macro no longer compiles (`undefined function build_embedding_text/2`).
    # Regression: position-db PositionDb.Search.Embeddable.
    test "keeps a defp called from a defmacro body before the quote" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used, do: :ok

          defmacro __using__(opts) do
            fields = Keyword.fetch!(opts, :fields)
            text_ast = build_embedding_text(fields, " — ")

            quote do
              unquote(text_ast)
            end
          end

          defp build_embedding_text(fields, joiner) when is_list(fields) and is_binary(joiner) do
            quote do
              Enum.join(unquote(Macro.escape(fields)), unquote(Macro.escape(joiner)))
            end
          end
        end
        """
      )
    end

    test "keeps a defp called only from a defmacrop body" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used, do: :ok

          defmacrop gen do
            ast = builder()

            quote do
              unquote(ast)
            end
          end

          defp builder, do: quote(do: :ok)
        end
        """
      )
    end

    # A defp referenced only from inside a HEEx `~H` sigil. Sourceror
    # keeps the sigil content as an unparsed string literal, so the call
    # graph never sees the call. Deleting the helper breaks compilation
    # (`undefined function format_datetime/1`).
    # Regression: position-db PositionDbWeb.Components.RelativeTime.
    test "keeps a defp referenced only inside a ~H sigil" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def render(assigns) do
            ~H"""
            <span>{format_datetime(@datetime)}</span>
            """
          end

          defp format_datetime(d), do: d
        end
        '''
      )
    end

    test "keeps a defp reached via __MODULE__.fn() inside a quote block" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used, do: :ok

          defmacro gen do
            quote do
              unquote(__MODULE__).runtime_helper()
            end
          end

          defp runtime_helper, do: :ok
        end
        """
      )
    end

    test "keeps a defp reached via a fully-qualified self-call" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used, do: :ok
          def trampoline, do: M.target()
          defp target, do: :ok
        end
        """
      )
    end

    test "keeps every defp when a quote block dispatches dynamically" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used, do: :ok

          defmacro gen(name) do
            quote do
              unquote(name)()
            end
          end

          defp maybe_target, do: :ok
        end
        """
      )
    end

    test "keeps all defps when a dynamic apply is reachable" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def used(name), do: apply(__MODULE__, name, [])
          defp maybe_target, do: :ok
        end
        """
      )
    end

    test "leaves a public def alone even if uncalled (external contract)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          def public_api, do: :ok
        end
        """
      )
    end

    test "skips a module with no public def (roots unknown)" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          defp only_private, do: :ok
        end
        """
      )
    end

    # Regression for #251: `use PatchRefactor` injects
    # `__patch_refactor_apply__/2`, whose body calls `build_patches/1`.
    # That call lives in the macro expansion, not the source, so the
    # local call graph sees `build_patches/1` as dead — but deleting it
    # breaks compilation. An opaque `use` must keep every private.
    test "keeps every defp when an opaque use injects callers" do
      assert_unchanged(
        @subject,
        """
        defmodule M do
          use Number42.Refactors.PatchRefactor

          def description, do: "x"

          defp build_patches(ast), do: walk(ast)
          defp walk(ast), do: ast
        end
        """
      )
    end

    # The library's own `use Number42.Refactors.Refactor` only injects
    # `@behaviour`/`import`/an attribute — no caller of a local private —
    # so it stays inert and genuine dead code is still removed.
    test "still removes dead code under the inert Refactor use" do
      assert_rewrites(
        @subject,
        """
        defmodule M do
          use Number42.Refactors.Refactor

          def transform(s, _), do: live(s)
          defp live(s), do: s
          defp dead, do: :gone
        end
        """,
        """
        defmodule M do
          use Number42.Refactors.Refactor

          def transform(s, _), do: live(s)
          defp live(s), do: s
        end
        """
      )
    end
  end

  describe "idempotence" do
    test "stable after removing one dead function" do
      assert_idempotent(
        @subject,
        """
        defmodule M do
          def used, do: helper_a()
          defp helper_a, do: :ok
          defp helper_b, do: :dead
        end
        """
      )
    end

    test "output still compiles" do
      source = """
      defmodule RemoveDeadPrivateFunctionCompileCheck do
        def used, do: helper()
        defp helper, do: :ok
        defp dead, do: :gone
      end
      """

      assert_compiles(apply_refactor(@subject, source))
    end
  end
end
