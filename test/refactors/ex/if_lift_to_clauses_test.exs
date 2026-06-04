defmodule Number42.Refactors.Ex.IfLiftToClausesTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.IfLiftToClauses

  @subject IfLiftToClauses

  describe "guard-form lifts" do
    test "is_*(param) → guard + catch-all" do
      before_source = """
      defmodule M do
        def f(x) do
          if is_atom(x) do
            :atom
          else
            :other
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(x) when is_atom(x), do: :atom
        def f(_), do: :other
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "length(xs) > 0 → BIF guard" do
      before_source = """
      defmodule M do
        def f(xs) do
          if length(xs) > 0 do
            :nonempty
          else
            :empty
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(xs) when length(xs) > 0, do: :nonempty
        def f(_), do: :empty
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "map_size(m) == 0 → BIF guard" do
      before_source = """
      defmodule M do
        def f(m) do
          if map_size(m) == 0 do
            :empty
          else
            :full
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(m) when map_size(m) == 0, do: :empty
        def f(_), do: :full
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "param != [] → guard on param" do
      before_source = """
      defmodule M do
        def f(xs) do
          if xs != [] do
            :some
          else
            :none
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(xs) when xs != [], do: :some
        def f(_), do: :none
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "param in [literals] → guard" do
      before_source = """
      defmodule M do
        def f(k) do
          if k in [:a, :b] do
            :match
          else
            :other
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(k) when k in [:a, :b], do: :match
        def f(_), do: :other
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "bare param truthy → `not in [nil, false]` guard" do
      before_source = """
      defmodule M do
        def f(current_scope) do
          if current_scope do
            :auth
          else
            :guest
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(current_scope) when current_scope not in [nil, false], do: :auth
        def f(_), do: :guest
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "param == literal lifts (pattern in head)" do
    test "param == :atom (param on left)" do
      before_source = """
      defmodule M do
        def f(x) do
          if x == :ok do
            :a
          else
            :b
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(:ok), do: :a
        def f(_), do: :b
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "literal == param (literal on left)" do
      before_source = """
      defmodule M do
        def f(x) do
          if :ok == x do
            :a
          else
            :b
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(:ok), do: :a
        def f(_), do: :b
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "field-chain lifts (map pattern in head)" do
    test "param.field truthy → map pattern + guard on bound var" do
      before_source = """
      defmodule M do
        def f(changeset) do
          if changeset.valid? do
            :ok
          else
            :err
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(%{valid?: valid?}) when valid? not in [nil, false], do: :ok
        def f(_), do: :err
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "param.field == literal → map pattern with literal value (no guard)" do
      before_source = """
      defmodule M do
        def f(socket) do
          if socket.assigns.option == :new do
            :a
          else
            :b
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(%{assigns: %{option: :new}}), do: :a
        def f(_), do: :b
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "deeply nested param.a.b.c.d truthy" do
      before_source = """
      defmodule M do
        def on_mount(:require_unlocked, _params, _session, socket) do
          if socket.assigns.current_scope.user.is_locked do
            :locked
          else
            :ok
          end
        end
      end
      """

      expected = """
      defmodule M do
        def on_mount(:require_unlocked, _params, _session, %{assigns: %{current_scope: %{user: %{is_locked: is_locked}}}}) when is_locked not in [nil, false], do: :locked
        def on_mount(:require_unlocked, _params, _session, _), do: :ok
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "bracket access treated like dot access" do
      before_source = """
      defmodule M do
        def f(socket) do
          if socket.assigns[:trimmed?] do
            :yes
          else
            :no
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(%{assigns: %{trimmed?: trimmed?}}) when trimmed? not in [nil, false], do: :yes
        def f(_), do: :no
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "pin lifts" do
    test "bare_param == other_bare_param → pin on the second" do
      # Not really liftable to pattern — both sides are bare params,
      # neither side has a field. Skip in v1 (no field to put pattern on).
      source = """
      defmodule M do
        def f(a, b) do
          if a == b do
            :eq
          else
            :neq
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "field_chain == bare_param → pin in field-chain pattern" do
      before_source = """
      defmodule M do
        def f(node, id) do
          if node.id == id do
            :match
          else
            :nope
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(%{id: id2}, id) when id2 == id, do: :match
        def f(_, _), do: :nope
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "bare_param == field_chain → pin from bare into field-chain pattern" do
      before_source = """
      defmodule M do
        def f(query, socket) do
          if query == socket.assigns.query do
            :same
          else
            :diff
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(query, %{assigns: %{query: query2}}) when query == query2, do: :same
        def f(_, _), do: :diff
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "two field-chains == each other → bind on left, pin on right" do
      before_source = """
      defmodule M do
        def f(building, socket) do
          if building.id == socket.assigns.building.id do
            :match
          else
            :nope
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(%{id: id}, %{assigns: %{building: %{id: id2}}}) when id == id2, do: :match
        def f(_, _), do: :nope
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "compound conditions (and / && / not)" do
    test "and combines two field patterns (different params)" do
      before_source = """
      defmodule M do
        def f(socket) do
          if socket.assigns.has_more and socket.assigns.loading do
            :a
          else
            :b
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(%{assigns: %{has_more: has_more, loading: loading}}) when has_more not in [nil, false] and loading not in [nil, false], do: :a
        def f(_), do: :b
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "and with `not` on one operand" do
      before_source = """
      defmodule M do
        def f(socket) do
          if socket.assigns.has_more and not socket.assigns.loading do
            :a
          else
            :b
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(%{assigns: %{has_more: has_more, loading: loading}}) when has_more not in [nil, false] and not (loading not in [nil, false]), do: :a
        def f(_), do: :b
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "&& with field truthy + field literal-eq" do
      before_source = """
      defmodule M do
        def f(conn) do
          if conn.assigns.current_scope && conn.assigns.user_id == 1 do
            :a
          else
            :b
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(%{assigns: %{current_scope: current_scope, user_id: 1}}) when current_scope not in [nil, false], do: :a
        def f(_), do: :b
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "if without else (assumes else: nil)" do
    test "single-branch if lifts with nil else" do
      before_source = """
      defmodule M do
        def f(x) do
          if is_atom(x) do
            :atom
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(x) when is_atom(x), do: :atom
        def f(_), do: nil
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "single-branch if with field pattern" do
      before_source = """
      defmodule M do
        def f(changeset) do
          if changeset.valid? do
            :ok
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(%{valid?: valid?}) when valid? not in [nil, false], do: :ok
        def f(_), do: nil
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "catch-all preserves param names referenced in else-body" do
    test "else-body uses param → catch-all keeps name bound" do
      before_source = """
      defmodule M do
        def f(x) do
          if is_atom(x) do
            :atom
          else
            inspect(x)
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(x) when is_atom(x), do: :atom
        def f(x), do: inspect(x)
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "else-body uses one param, not the other" do
      before_source = """
      defmodule M do
        def f(x, ctx) do
          if is_atom(x) do
            :atom
          else
            log(ctx)
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(x, _ctx) when is_atom(x), do: :atom
        def f(_x, ctx), do: log(ctx)
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "multi-clause lifts (replace-in-place)" do
    test "if/else clause is the last of its name/arity group" do
      before_source = """
      defmodule M do
        def f(:special), do: :s

        def f(x) do
          if is_atom(x) do
            :a
          else
            :b
          end
        end
      end
      """

      expected = """
      defmodule M do
        def f(:special), do: :s

        def f(x) when is_atom(x), do: :a
        def f(_), do: :b
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "if/else clause sits between other clauses" do
      before_source = """
      defmodule M do
        def f(:first), do: :one

        def f(x) do
          if is_atom(x) do
            :a
          else
            :b
          end
        end

        def f(:last), do: :z
      end
      """

      expected = """
      defmodule M do
        def f(:first), do: :one

        def f(x) when is_atom(x), do: :a
        def f(_), do: :b

        def f(:last), do: :z
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "if/else clause is the first of its name/arity group" do
      before_source = """
      defmodule M do
        def f(x) do
          if is_atom(x) do
            :a
          else
            :b
          end
        end

        def f(:tail), do: :t
      end
      """

      expected = """
      defmodule M do
        def f(x) when is_atom(x), do: :a
        def f(_), do: :b

        def f(:tail), do: :t
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "only the if/else clause is replaced, siblings untouched" do
      before_source = """
      defmodule M do
        def handle_event("a", _params, socket), do: {:noreply, socket}

        def handle_event("b", params, socket) do
          if socket.assigns.has_more do
            {:noreply, load_more(socket, params)}
          else
            {:noreply, socket}
          end
        end

        def handle_event("c", _params, socket), do: {:noreply, socket}
      end
      """

      expected = """
      defmodule M do
        def handle_event("a", _params, socket), do: {:noreply, socket}

        def handle_event("b", params, %{assigns: %{has_more: has_more}} = socket) when has_more not in [nil, false], do: {:noreply, load_more(socket, params)}
        def handle_event("b", _params, socket), do: {:noreply, socket}

        def handle_event("c", _params, socket), do: {:noreply, socket}
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "leaves alone (skip cases)" do
    test "body has statements before the if" do
      source = """
      defmodule M do
        def f(x) do
          log(x)
          if is_atom(x) do
            :a
          else
            :b
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "body has statements after the if" do
      source = """
      defmodule M do
        def f(x) do
          if is_atom(x) do
            :a
          else
            :b
          end
          |> log()
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "def with when-guard" do
      source = """
      defmodule M do
        def f(x) when is_integer(x) do
          if x == 0 do
            :zero
          else
            :nonzero
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "defmacro is out of scope" do
      source = """
      defmodule M do
        defmacro f(x) do
          if is_atom(x) do
            :a
          else
            :b
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "user-defined function call in condition" do
      source = """
      defmodule M do
        def f(asset) do
          if Asset.pdf?(asset) do
            :pdf
          else
            :other
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "in with non-literal RHS" do
      source = """
      defmodule M do
        def f(scope, id) do
          if id in visible_ids(scope) do
            :visible
          else
            :hidden
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "if-let assignment" do
      source = """
      defmodule M do
        def f(conn) do
          if token = get_session(conn, :user_token) do
            verify(token)
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "disjunction (or) is not lifted in v1" do
      source = """
      defmodule M do
        def f(socket) do
          if socket.assigns.selected or socket.assigns.viewed do
            :a
          else
            :b
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "|| disjunction is not lifted in v1" do
      source = """
      defmodule M do
        def f(socket) do
          if socket.assigns.selected || socket.assigns.viewed do
            :a
          else
            :b
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "param is already a pattern, not a bare variable (skip)" do
      # Same scenario as above but the if/else-clause itself has a
      # non-bare param — must skip regardless of sibling clauses.
      source = """
      defmodule M do
        def f(:special), do: :s

        def f(%{key: val}) do
          if is_atom(val) do
            :a
          else
            :b
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "param is already a pattern, not a bare variable" do
      source = """
      defmodule M do
        def f(%{key: val}) do
          if is_atom(val) do
            :a
          else
            :b
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "condition uses pipe" do
      source = """
      defmodule M do
        def f(xs) do
          if xs |> Enum.empty?() do
            :empty
          else
            :nonempty
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "condition contains anonymous fn" do
      source = """
      defmodule M do
        def f(xs) do
          if Enum.any?(xs, fn x -> x > 0 end) do
            :y
          else
            :n
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "field chain compared against non-bare, non-field value" do
      source = """
      defmodule M do
        def f(x) do
          if x.field == compute(x) do
            :a
          else
            :b
          end
        end
      end
      """

      assert_unchanged(@subject, source)
    end

    test "keyword `do:` form also lifts when body is a single if" do
      # `def f(x), do: if(...)` — the if is still a single body expression,
      # so it lifts the same way as the block form.
      before_source = ~S"""
      defmodule M do
        def f(x), do: if(is_atom(x), do: :a, else: :b)
      end
      """

      expected = """
      defmodule M do
        def f(x) when is_atom(x), do: :a
        def f(_), do: :b
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end
  end

  describe "default arguments (\\\\) — emit a header clause" do
    test "single trailing default → header clause + two impl clauses without default" do
      before_source = ~S"""
      defmodule M do
        def f(x, opts \\ []) do
          if is_atom(x) do
            {:atom, opts}
          else
            {:other, opts}
          end
        end
      end
      """

      expected = ~S"""
      defmodule M do
        def f(x, opts \\ [])
        def f(x, opts) when is_atom(x), do: {:atom, opts}
        def f(_x, opts), do: {:other, opts}
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "default unused in either branch → header keeps default, impl clauses underscore it" do
      before_source = ~S"""
      defmodule M do
        def f(x, opts \\ []) do
          if is_atom(x) do
            :atom
          else
            :other
          end
        end
      end
      """

      expected = ~S"""
      defmodule M do
        def f(x, opts \\ [])
        def f(x, _opts) when is_atom(x), do: :atom
        def f(_, _), do: :other
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "multiple defaults at arbitrary positions (issue #7 repro)" do
      before_source = ~S"""
      defmodule M do
        def overall_score(category_grades, scale \\ default_scale(), impact_map \\ %{}) do
          if category_grades == [] do
            {0, "F"}
          else
            score = compute(category_grades, impact_map)
            {score, grade_letter(score, scale)}
          end
        end
      end
      """

      expected = ~S"""
      defmodule M do
        def overall_score(category_grades, scale \\ default_scale(), impact_map \\ %{})

        def overall_score([], _scale, _impact_map), do: {0, "F"}

        def overall_score(category_grades, scale, impact_map) do
          score = compute(category_grades, impact_map)
          {score, grade_letter(score, scale)}
        end
      end
      """

      assert_rewrites(@subject, before_source, expected)
    end

    test "output actually compiles (the core bug — defaults declared once)" do
      before_source = ~S"""
      defmodule CompileCheckOne do
        def overall_score(category_grades, scale \\ [], impact_map \\ %{}) do
          if category_grades == [] do
            {0, "F"}
          else
            score = round(length(category_grades) / map_size(impact_map))
            {score, hd(scale)}
          end
        end
      end
      """

      out = apply_refactor(@subject, before_source)

      assert_compiles(out)
    end

    test "output compiles when a default sits before a non-default param" do
      before_source = ~S"""
      defmodule CompileCheckTwo do
        def g(opts \\ [], x) do
          if is_atom(x) do
            {:atom, opts}
          else
            {:other, opts}
          end
        end
      end
      """

      out = apply_refactor(@subject, before_source)

      assert_compiles(out)
    end
  end

  describe "default arguments — idempotent" do
    test "header clause + impl clauses pass through unchanged" do
      source = ~S"""
      defmodule M do
        def f(x, opts \\ [])
        def f(x, opts) when is_atom(x), do: {:atom, opts}
        def f(x, opts), do: {:other, opts}
      end
      """

      assert_idempotent(@subject, source)
    end

    test "lift-then-relift on a defaulted function stays stable" do
      source = ~S"""
      defmodule M do
        def f(x, opts \\ []) do
          if is_atom(x) do
            {:atom, opts}
          else
            {:other, opts}
          end
        end
      end
      """

      assert_idempotent(@subject, source)
    end
  end

  describe "idempotent" do
    test "is_* guard lift" do
      source = """
      defmodule M do
        def f(x) do
          if is_atom(x) do
            :a
          else
            :b
          end
        end
      end
      """

      assert_idempotent(@subject, source)
    end

    test "field pattern lift" do
      source = """
      defmodule M do
        def f(changeset) do
          if changeset.valid? do
            :ok
          else
            :err
          end
        end
      end
      """

      assert_idempotent(@subject, source)
    end

    test "pin lift" do
      source = """
      defmodule M do
        def f(node, id) do
          if node.id == id do
            :match
          else
            :nope
          end
        end
      end
      """

      assert_idempotent(@subject, source)
    end

    test "compound lift" do
      source = """
      defmodule M do
        def f(socket) do
          if socket.assigns.has_more and not socket.assigns.loading do
            :a
          else
            :b
          end
        end
      end
      """

      assert_idempotent(@subject, source)
    end

    test "no-else lift" do
      source = """
      defmodule M do
        def f(x) do
          if is_atom(x) do
            :atom
          end
        end
      end
      """

      assert_idempotent(@subject, source)
    end

    test "already-lifted code passes through unchanged" do
      source = """
      defmodule M do
        def f(x) when is_atom(x), do: :atom
        def f(_), do: :other
      end
      """

      assert_idempotent(@subject, source)
    end
  end
end
