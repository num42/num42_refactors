defmodule Number42.Refactors.Ex.ExpandShortFormBindingsTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Engine
  alias Number42.Refactors.Ex.ExpandShortFormBindings

  @subject ExpandShortFormBindings

  @pp_verbs ~w(normalize validate parse merge update create)

  describe "known mapping (from opts)" do
    test "single-binding rewrite using opts[:known]" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(custom_function) do
            org_id = custom_function.organization_id
            do_thing(org_id)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(custom_function) do
            organization_id = custom_function.organization_id
            do_thing(organization_id)
          end
        end
        ''',
        known: %{"org_id" => "organization_id"}
      )
    end

    test "without opts[:known], unmapped name stays put" do
      # `xyz_id` is short by length-rule but the smart matchers find
      # no candidate, and the empty `@known` default means it stays.
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(arg) do
          xyz_id = arg.id
          do_thing(xyz_id)
        end
      end
      ''')
    end
  end

  describe "RHS-based singularization" do
    test "bi = build_brand_item(...) -> brand_item" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(attrs) do
            bi = build_brand_item(attrs)
            persist(bi)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(attrs) do
            brand_item = build_brand_item(attrs)
            persist(brand_item)
          end
        end
        '''
      )
    end

    test "pl = Pricing.get_price_list(id) -> price_list (multi-subtoken tail)" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(id) do
            pl = Pricing.get_price_list(id)
            render(pl)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(id) do
            price_list = Pricing.get_price_list(id)
            render(price_list)
          end
        end
        '''
      )
    end

    test "single-letter via RHS: s = Atom.to_string(name) -> string" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(name) do
            s = Atom.to_string(name)
            String.starts_with?(s, "_")
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(name) do
            string = Atom.to_string(name)
            String.starts_with?(string, "_")
          end
        end
        '''
      )
    end

    test "trailing plural -> singular: pls = list_price_lists() -> price_list" do
      # `p` latches on `price` (earliest subtoken starting with p),
      # `l` and `s` appear in the rest. tail=[price, lists]; lists
      # singularizes to list. tail_compound=price_list.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go do
            pls = list_price_lists()
            Enum.count(pls)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go do
            price_list = list_price_lists()
            Enum.count(price_list)
          end
        end
        '''
      )
    end

    test "RHS that is a pipe takes the LAST stage" do
      # `cs = x |> build_changeset()` — extract_call_name unwraps the
      # pipe, takes `build_changeset`. `c` latches on `changeset`
      # (earliest subtoken starting with c), `s` appears in
      # `changeset`. tail=[changeset] -> "changeset".
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(x) do
            cs = x |> build_changeset()
            persist(cs)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(x) do
            changeset = x |> build_changeset()
            persist(changeset)
          end
        end
        '''
      )
    end
  end

  describe "RHS past-participle promotion" do
    test "nk = normalize_keys(m) -> normalized_key (with pp_verbs config)" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(m) do
            nk = normalize_keys(m)
            persist(nk)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(m) do
            normalized_key = normalize_keys(m)
            persist(normalized_key)
          end
        end
        ''',
        pp_verbs: @pp_verbs
      )
    end

    test "without pp_verbs config, PP still fires when head has a verb-shaped suffix" do
      # `normalize` ends in `-ize`, a regular English verb-forming
      # suffix, so PP promotion fires without needing `pp_verbs`:
      # `normalize_keys → normalized_key`. Verbs without a verb-shaped
      # suffix (parse, fetch, merge, build, ...) require explicit
      # `pp_verbs` opt-in (see other tests).
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(m) do
            nk = normalize_keys(m)
            persist(nk)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(m) do
            normalized_key = normalize_keys(m)
            persist(normalized_key)
          end
        end
        '''
      )
    end

    test "PP doesn't fire when verb doesn't end in `e` (irregulars)" do
      # `build` is plausibly a verb but irregular; we don't risk
      # `builtd` so even if listed, the `-e` guard skips it. Result:
      # plain singularized tail. `cs` latches on `changesets`,
      # tail=[changesets], head=[build]. PP would fire (build is
      # listed, tail singularized) but build doesn't end in `e`.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(attrs) do
            cs = build_changesets(attrs)
            persist(cs)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(attrs) do
            changeset = build_changesets(attrs)
            persist(changeset)
          end
        end
        ''',
        pp_verbs: ~w(build normalize)
      )
    end

    test "PP doesn't fire when tail wasn't plural" do
      # `render_node` (n=1, tail=[node]). singularize(`node`) = `node`,
      # no change -> no PP. Result: plain `node`.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(ast) do
            n = render_node(ast)
            wrap(n)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(ast) do
            node = render_node(ast)
            wrap(node)
          end
        end
        ''',
        pp_verbs: ~w(render normalize)
      )
    end
  end

  describe "compound-context match (no RHS hit)" do
    test "fb matches enclosing module compound `FormulaBuilder`" do
      # No RHS hit (fb gets bound to a literal); fb compound-matches
      # the module name `MyApp.FormulaBuilder` -> `formula_builder`.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule MyApp.FormulaBuilder do
          def go do
            fb = %{}
            wrap(fb)
          end
        end
        ''',
        ~S'''
        defmodule MyApp.FormulaBuilder do
          def go do
            formula_builder = %{}
            wrap(formula_builder)
          end
        end
        '''
      )
    end

    test "single-letter shorts NEVER match via compound context" do
      # Module = `MyApp.Color`. `c = ...` initial-matches `color`,
      # but the compound-context path forbids length-1 shorts. Without
      # a meaningful RHS, the binding stays.
      assert_unchanged(@subject, ~S'''
      defmodule MyApp.Color do
        def go(value) do
          c = value * 0.5
          wrap(c)
        end
      end
      ''')
    end
  end

  describe "whitelist" do
    test "whitelisted single-letter `a` is not renamed" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def go(socket) do
            a = socket.assigns
            wrap(a)
          end
        end
        ''',
        whitelist: ~w(a)a
      )
    end

    test "whitelisted prefix `idx_*` is not renamed" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def go(rows) do
            idx_map = Enum.with_index(rows)
            wrap(idx_map)
          end
        end
        ''',
        whitelist: ~w(idx)a
      )
    end

    test "extra opts[:whitelist] entries are honoured on top of defaults" do
      # `oz` is NOT in the default whitelist (project-specific). Without
      # the opt, `oz = build_oz_chain()` would resolve via the RHS and
      # rename. With the opt, it stays as-is.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def go(input) do
            oz = build_oz_chain(input)
            wrap(oz)
          end
        end
        ''',
        whitelist: [:oz]
      )
    end
  end

  describe "skip conditions" do
    test "rebound name in same function body is left alone" do
      # `cs` is bound twice; renaming would require scope analysis we
      # don't do.
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(attrs) do
          cs = build_changeset(attrs)
          cs = put_extra(cs)
          persist(cs)
        end
      end
      ''')
    end

    test "long form would shadow a lambda param -> skip" do
      # `rt = return_type_for_item(...)` sits inside `fn item -> ... end`.
      # The RHS-based resolver could pick `item` (it's the lambda
      # param's own name and a strong locality match), but renaming
      # `rt` to `item` would shadow the lambda parameter — silently
      # swallowing the param's value. Lambda params count as occupied
      # names just like function params and body bindings.
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(items, cat, assigns) do
          items
          |> Enum.map(fn item ->
            rt = return_type_for_item(cat, item, assigns)
            {rt, Map.put(item, :category, cat)}
          end)
          |> Enum.sort_by(fn {rt, m} ->
            {type_sort_key(rt), String.downcase(m.label || "")}
          end)
        end
      end
      ''')
    end

    test "long form already used as parameter -> skip" do
      # The function takes `changeset` as a parameter, so renaming
      # `cs` to `changeset` would shadow.
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(changeset) do
          cs = build_changeset(changeset)
          merge(cs, changeset)
        end
      end
      ''')
    end

    test "long form already exists as another binding -> skip" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(x) do
          changeset = something(x)
          cs = build_changeset(x)
          merge(changeset, cs)
        end
      end
      ''')
    end

    test "RHS is HEEx sigil — left alone (no usable signal in sigil_H call)" do
      # `cs = ~H"..."` parses as `cs = {:sigil_H, _, [...]}`. The
      # RHS-based name resolver looks for a function-like call on the
      # RHS to infer a long form; the sigil call carries no semantic
      # signal we'd want to promote (and any latch on `:sigil_H` would
      # produce noise). Conservative skip.
      assert_unchanged(@subject, ~S'''
      defmodule M do
        use Phoenix.Component

        def render(assigns) do
          cs = ~H"<span>{@changeset.id}</span>"
          cs
        end
      end
      ''')
    end

    test "def heads are not bindings (the param `cs` stays cs)" do
      # `def foo(cs)` is a parameter, not a `=` binding. No rewrite.
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(cs) do
          merge(cs)
        end
      end
      ''')
    end
  end

  describe "engine: skip_in_modules" do
    test "engine bails out when source defines a skipped module" do
      # Engine-level skip: even though `c = some_call()` would
      # normally rewrite via RHS, the file declares a skipped module
      # and we leave it alone wholesale.
      source = ~S'''
      defmodule MyApp.Color do
        def go(value) do
          c = compute_color(value)
          c
        end
      end
      '''

      result =
        Engine.apply_one(
          @subject,
          source,
          configured_modules: [{@subject, skip_in_modules: [MyApp.Color]}]
        )

      assert result == source
    end

    test "engine still rewrites when the skipped list does not contain the module" do
      source = ~S'''
      defmodule MyApp.Other do
        def go(name) do
          s = Atom.to_string(name)
          s
        end
      end
      '''

      result =
        Engine.apply_one(
          @subject,
          source,
          configured_modules: [{@subject, skip_in_modules: [MyApp.Color]}]
        )

      assert result =~ "string = Atom.to_string"
    end
  end

  describe "idempotent" do
    test "running twice equals running once" do
      assert_idempotent(
        @subject,
        ~S'''
        defmodule M do
          def go(custom_function) do
            org_id = custom_function.organization_id
            do_thing(org_id)
          end
        end
        ''',
        known: %{"org_id" => "organization_id"}
      )
    end
  end

  describe "lambda params" do
    test "single-clause lambda: rb matches outer param `reference_buildings`" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(reference_buildings) do
            Enum.map(reference_buildings, fn rb -> rb.id end)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(reference_buildings) do
            Enum.map(reference_buildings, fn reference_building -> reference_building.id end)
          end
        end
        '''
      )
    end

    test "lambda param stays when outer scope already has the long name" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(reference_buildings, reference_building) do
          Enum.map(reference_buildings, fn rb -> {rb, reference_building} end)
        end
      end
      ''')
    end

    test "multi-clause lambda is skipped" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(reference_buildings) do
          Enum.map(reference_buildings, fn
            %{kind: :a} = rb -> rb.id
            %{kind: :b} = rb -> rb.id + 1
          end)
        end
      end
      ''')
    end

    test "underscore lambda params are not renamed" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(reference_buildings) do
          Enum.map(reference_buildings, fn _rb -> :ok end)
        end
      end
      ''')
    end
  end

  describe "for-comprehension generators" do
    test "bare-var generator: rbip <- record.reference_building_item_positions" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(reference_building) do
            for rbip <- reference_building.reference_building_item_positions do
              rbip.id
            end
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(reference_building) do
            for reference_building_item_position <- reference_building.reference_building_item_positions do
              reference_building_item_position.id
            end
          end
        end
        '''
      )
    end

    test "map-key pattern: ip in `%{item_position: ip} <- list` -> item_position" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(list) do
            for %{item_position: ip} <- list do
              ip.id
            end
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(list) do
            for %{item_position: item_position} <- list do
              item_position.id
            end
          end
        end
        '''
      )
    end

    test "alias pattern: rbip in `%{} = rbip <- list` -> reference_building_item_position" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(list) do
            for %{} = rbip <- list.reference_building_item_positions do
              rbip.id
            end
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(list) do
            for %{} = reference_building_item_position <- list.reference_building_item_positions do
              reference_building_item_position.id
            end
          end
        end
        '''
      )
    end

    test "generator renames apply to following filter clauses too" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(list) do
            for %{item_position: ip} <- list, not is_nil(ip) do
              ip.id
            end
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(list) do
            for %{item_position: item_position} <- list, not is_nil(item_position) do
              item_position.id
            end
          end
        end
        '''
      )
    end

    test "underscore generator vars are not renamed" do
      assert_unchanged(@subject, ~S'''
      defmodule M do
        def go(list) do
          for _rb <- list, do: :ok
        end
      end
      ''')
    end
  end

  describe "stress: lambda params and for-comprehension generators" do
    test "expands rb (lambda param), rbip and ip (for-generator patterns)" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule MyApp.ReferenceBuildings do
          @zero Decimal.new(0)

          def build_ref_value_maps(reference_buildings) do
            reference_buildings
            |> Enum.map(fn rb ->
              ref_values =
                for %{item_position: ip} = rbip <- rb.reference_building_item_positions,
                    not is_nil(ip) do
                  {ip.item.id, rbip.ref_value || @zero}
                end
                |> Map.new()

              {rb.id, ref_values}
            end)
            |> Map.new()
          end
        end
        ''',
        ~S'''
        defmodule MyApp.ReferenceBuildings do
          @zero Decimal.new(0)

          def build_ref_value_maps(reference_buildings) do
            reference_buildings
            |> Enum.map(fn reference_building ->
              ref_values =
                for %{item_position: item_position} = reference_building_item_position <- reference_building.reference_building_item_positions,
                    not is_nil(item_position) do
                  {item_position.item.id, reference_building_item_position.ref_value || @zero}
                end
                |> Map.new()

              {reference_building.id, ref_values}
            end)
            |> Map.new()
          end
        end
        '''
      )
    end
  end

  describe "real-world false positives from dry-run" do
    # These are concrete renames the refactor produced on the
    # position-db codebase that came out wrong. Each test pins the
    # corrected behavior in place so we don't regress.

    test "deps = formula_dependencies(...) stays put (deps is a readable plural)" do
      # `deps` is a 4-char `-s` plural of the 3-char `dep`. After the
      # digraph-aware classifier, `deps` is not cryptic. The binding
      # stays as `deps`. Even if `dep` is in the `known` map, the
      # word-as-a-whole short check rules first.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def go(formula) do
            deps = formula_dependencies(formula)
            persist(deps)
          end
        end
        ''',
        pp_verbs: @pp_verbs
      )
    end

    test "deps = extract_mass_deps(f) stays put" do
      # Same as above — `deps` is no longer cryptic. The risk that PP
      # would have fired on the head (`mass` is a noun) is also gone
      # since the binding itself isn't a rename candidate.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def go(f) do
            deps = extract_mass_deps(f)
            persist(deps)
          end
        end
        ''',
        pp_verbs: @pp_verbs
      )
    end

    test "attrs = parse_csv_attributes(row) does NOT become csved_attribute" do
      # head=[parse, csv]. Last head token `csv` is an acronym, no
      # verb suffix, not in pp_verbs. PP must not fire.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(row) do
            attrs = parse_csv_attributes(row["attributes"])
            wrap(attrs)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(row) do
            attribute = parse_csv_attributes(row["attributes"])
            wrap(attribute)
          end
        end
        ''',
        pp_verbs: @pp_verbs
      )
    end

    test "rows = parse_sheet_rows(raw) stays put (rows is a readable plural)" do
      # `rows` is a conventional plural of `row`. After the digraph-
      # aware short check, `rows` is no longer cryptic, so the
      # binding stays put. No risk of `sheeted_row` either.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def go(raw) do
            rows = parse_sheet_rows(raw)
            wrap(rows)
          end
        end
        ''',
        pp_verbs: @pp_verbs
      )
    end

    test "strings = parse_shared_strings(x) stays put (short matches RHS subtoken)" do
      # `strings` appears verbatim as a subtoken of the RHS source
      # token `parse_shared_strings` — the author already wrote the
      # binding name from that token. Renaming to `string` would
      # invert the cardinality. The (now-moot) PP risk on the head
      # `shared` is also avoided as a side effect.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def go(x) do
            strings = parse_shared_strings(x)
            wrap(strings)
          end
        end
        ''',
        pp_verbs: @pp_verbs
      )
    end

    test "args = ... in indexed_args/1 — `indexed_args` param does NOT become indexeded_args" do
      # Parameter-rename path: function head is `indexed_args(args)`.
      # If the param rename ever promotes `args` via PP using the
      # function name as head, `indexed` already ends in `-ed` so we
      # must NOT produce `indexeded`. Lives in params-refactor but
      # the underlying guard sits in ast_helpers shared with bindings.
      # Here we cover the body-binding path: pinned to no false PP.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          defp indexed_args(args) do
            args |> Enum.with_index() |> Enum.map(fn {a, i} -> {[:args, i], a} end)
          end
        end
        ''',
        whitelist: ~w(args opts rows cols attrs)a,
        pp_verbs: @pp_verbs
      )
    end

    test "brand! = Pricing.get_brand!(...) strips the bang from the binding name" do
      # Bang functions encode the `raise on miss` convention via a
      # trailing `!` on the function name, but `!` is not legal in a
      # variable name. The rename target must drop the bang.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(scope, id) do
            b = Pricing.get_brand!(scope, id)
            wrap(b)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(scope, id) do
            brand = Pricing.get_brand!(scope, id)
            wrap(brand)
          end
        end
        ''',
        pp_verbs: @pp_verbs
      )
    end

    test "stats = compute_stats(...) does NOT singularize to `stat`" do
      # `stats` is a 4-char `-s` plural. It's a real word (statistics),
      # not a cryptic short. The refactor must leave it alone.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def go(rows, group_by) do
            stats = compute_stats(rows, group_by)
            wrap(stats)
          end
        end
        ''',
        pp_verbs: @pp_verbs
      )
    end

    test "paths = socket.assigns.file_paths does NOT singularize to `path`" do
      # `paths` is a 4-char `-s` plural assigned from a `.file_paths`
      # collection. Singularizing it to `path` would lie about the type.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def go(socket) do
            paths = socket.assigns.file_paths
            Enum.each(paths, &cleanup/1)
          end
        end
        ''',
        pp_verbs: @pp_verbs
      )
    end

    test "keys/pids/urls/ints — 4-char `-s` plurals are not cryptic" do
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def go(map, registry) do
            keys = Map.keys(map)
            pids = Registry.list(registry)
            urls = collect_urls(map)
            ints = parse_ints(map)
            wrap({keys, pids, urls, ints})
          end
        end
        ''',
        pp_verbs: @pp_verbs
      )
    end

    test "args/opts/rows/cols/attrs are whitelisted plural conventions" do
      # These are conventional Elixir plural shortnames. Even when a
      # known-mapping or compound-context would resolve them, the
      # whitelist keeps them as-is.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule MyApp.AttributeMap do
          def go(opts, rows, cols, attrs, args) do
            wrap({opts, rows, cols, attrs, args})
          end
        end
        ''',
        whitelist: ~w(args opts rows cols attrs)a,
        pp_verbs: @pp_verbs
      )
    end

    test "cs in non-changeset context — body has no changeset/cast/change call" do
      # `cs` is in the project's `known` map as `changeset`, but the
      # binding is plainly a joined string. We accept this is a known
      # tradeoff of `known` (explicit > smart) — the test pins the
      # current behavior so changes to `known`-handling get visibility.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(cases) do
            cs = Enum.map_join(cases, ", ", fn c -> "#{c}" end)
            "#{cs}!"
          end
        end
        ''',
        ~S'''
        defmodule M do
          def go(cases) do
            changeset = Enum.map_join(cases, ", ", fn c -> "#{c}" end)
            "#{changeset}!"
          end
        end
        ''',
        known: %{"cs" => "changeset"},
        pp_verbs: @pp_verbs
      )
    end

    test "ids = ...selected_price_list_ids stays put (short is a subtoken of RHS)" do
      # Regression from position-db: `ids` (3 chars, cryptic by length)
      # was being renamed to `id` because the singularize step on the
      # `..._ids` RHS produced `id` as a candidate. But the author
      # already wrote `ids` deliberately as the conventional plural of
      # the source field `..._ids`. When the short binding appears
      # verbatim as a subtoken of the RHS source token, that's a clear
      # signal that the binding is a legitimate variation, not an
      # abbreviation — keep it.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def handle_event(_event, _params, socket) do
            ids = socket.assigns.selected_price_list_ids

            if some_id in ids do
              {:noreply, socket}
            else
              new_ids = ids ++ [some_id]
              {:noreply, socket |> assign(:selected_price_list_ids, new_ids)}
            end
          end
        end
        ''',
        pp_verbs: @pp_verbs
      )
    end

    test "rename of a binding that shadows a param keeps the RHS reference intact" do
      # Regression from position-db's `Items.search_item_positions_excluding`:
      # the body opens with `search_term = String.trim(search_term)`,
      # which shadows the function parameter `search_term`. Elsewhere
      # in the module a local helper takes `str`, so the call-site
      # signal resolves `search_term` to `str`. Renaming every
      # occurrence naively produces `str = String.trim(str)` — `str`
      # is undefined on the RHS, since the parameter is still called
      # `search_term`. We must rename the LHS plus every reference
      # *after* the shadow point, leaving the shadowed RHS reference
      # (and any earlier references) as the original parameter name.
      #
      # `str` is whitelisted so that the call-site signal classes
      # `escape_like/1`'s parameter as a valid long form — that's the
      # configuration shape that exposed the bug in position-db.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def search(search_term) do
            search_term = String.trim(search_term)

            if search_term == "" do
              []
            else
              escape_like(search_term)
            end
          end

          defp escape_like(str), do: str
        end
        ''',
        ~S'''
        defmodule M do
          def search(search_term) do
            str = String.trim(search_term)

            if str == "" do
              []
            else
              escape_like(str)
            end
          end

          defp escape_like(str), do: str
        end
        ''',
        whitelist: [:str]
      )
    end

    test "ids = list_of_ids stays put (short matches an unrelated context subtoken)" do
      # Same principle generalized: any compound-context source that
      # already contains `ids` as a subtoken is evidence the author's
      # choice is intentional. Renaming `ids` to `id` would invert the
      # cardinality (collection → element) — far worse than leaving the
      # 3-char name alone.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def go(payload) do
            ids = payload.user_ids
            do_thing(ids)
          end
        end
        ''',
        pp_verbs: @pp_verbs
      )
    end
  end

  describe "Ecto from/in binding: schema is the strongest signal" do
    test "from(bi in BrandItem, ...) renames bi to brand_item across the body" do
      # The author's `from(bi in BrandItem, ...)` is an explicit
      # statement that `bi` represents a `BrandItem` row. That's the
      # strongest local signal we can get — stronger than function
      # parameters or module tokens. So `bi` becomes `brand_item`
      # everywhere in the body, including inside the `from()` macro
      # and any downstream lambda that re-binds it.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def load(item_ids, brand_ids) do
            from(bi in BrandItem,
              where: bi.item_id in ^item_ids and bi.brand_id in ^brand_ids
            )
            |> Repo.all()
            |> Map.new(fn bi -> {{bi.item_id, bi.brand_id}, bi} end)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def load(item_ids, brand_ids) do
            from(brand_item in BrandItem,
              where: brand_item.item_id in ^item_ids and brand_item.brand_id in ^brand_ids
            )
            |> Repo.all()
            |> Map.new(fn brand_item -> {{brand_item.item_id, brand_item.brand_id}, brand_item} end)
          end
        end
        '''
      )
    end

    test "from-schema beats a conflicting function-param signal" do
      # Without the from/in signal, the `bi`-initials-match against
      # the `brand_ids` parameter would steer the rename to
      # `brand_id`. With the schema present, the schema wins.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def load(brand_ids) do
            from(bi in BrandItem, where: bi.brand_id in ^brand_ids)
            |> Repo.all()
            |> Enum.map(fn bi -> bi.id end)
          end
        end
        ''',
        ~S'''
        defmodule M do
          def load(brand_ids) do
            from(brand_item in BrandItem, where: brand_item.brand_id in ^brand_ids)
            |> Repo.all()
            |> Enum.map(fn brand_item -> brand_item.id end)
          end
        end
        '''
      )
    end
  end

  describe "call-site signal: argument-to-local-function" do
    test "short binding passed as 1st arg to a local function takes that param's long name" do
      # When a short-form binding is passed as an argument to a
      # locally-defined function whose corresponding parameter has a
      # long, descriptive name, that param name is the strongest
      # signal we have for the binding's intended long form — stronger
      # than guessing from module/function tokens.
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(bis) do
            Enum.map(bis, fn bi ->
              load_brand_item(bi)
            end)
          end

          defp load_brand_item(brand_item), do: brand_item
        end
        ''',
        ~S'''
        defmodule M do
          def go(bis) do
            Enum.map(bis, fn brand_item ->
              load_brand_item(brand_item)
            end)
          end

          defp load_brand_item(brand_item), do: brand_item
        end
        '''
      )
    end

    test "skips multi-clause functions where only the catch-all clause is bare-var" do
      # Regression from position-db's `Configurator.AST.Humanizer.walk/1`:
      # multiple clauses with destructuring patterns plus a final
      # `defp walk(other), do: ...` catch-all. Only the catch-all
      # clause has a bare-var param, so a naive "all bare-var clauses
      # agree on `other`" check falsely concludes that position 0 is
      # always called `other`. That made every caller's `ast` binding
      # get renamed to `other` — including the literal `ast =
      # normalize_keys(ast)` whose Fn parameter was also `ast` (only
      # the body got patched, leaving an undefined-variable error).
      #
      # The fix: the index entry only stands when EVERY clause at that
      # position is a bare var.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def go(ast) when is_map(ast) do
            ast = normalize_keys(ast)
            walk(ast)
          end

          defp normalize_keys(%{} = m), do: m
          defp walk(%{type: :literal, value: v}), do: v
          defp walk(%{type: :operator} = node), do: node
          defp walk(other), do: inspect(other)
        end
        '''
      )
    end

    test "skips when multiple call sites disagree on the param name" do
      # If `bi` flows into two different local functions whose
      # respective params disagree (`brand_item` vs `building_item`),
      # the call-site signal is ambiguous — fall back to other signals
      # or skip rather than picking one arbitrarily.
      assert_unchanged(
        @subject,
        ~S'''
        defmodule M do
          def go(items) do
            Enum.map(items, fn bi ->
              do_one(bi)
              do_other(bi)
            end)
          end

          defp do_one(brand_item), do: brand_item
          defp do_other(building_item), do: building_item
        end
        '''
      )
    end

    test "call-site signal works for `=` bindings, not just lambda params" do
      assert_rewrites(
        @subject,
        ~S'''
        defmodule M do
          def go(arg) do
            bi = fetch(arg)
            load_brand_item(bi)
          end

          defp fetch(x), do: x
          defp load_brand_item(brand_item), do: brand_item
        end
        ''',
        ~S'''
        defmodule M do
          def go(arg) do
            brand_item = fetch(arg)
            load_brand_item(brand_item)
          end

          defp fetch(x), do: x
          defp load_brand_item(brand_item), do: brand_item
        end
        '''
      )
    end
  end
end
