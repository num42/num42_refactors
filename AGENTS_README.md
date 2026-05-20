# AGENTS_README — Briefing für AI-Agents

Dieses Dokument richtet sich an AI-Agents (Claude Code, Cursor, Aider,
Codex, etc.), die in diesem Repo arbeiten. Es fasst zusammen, was du
wissen musst, **bevor** du Code anfasst — Architektur, Konventionen,
verbindliche Workflows, häufige Fallen, was zu tun und zu lassen ist.

Wenn du nur eine Sache liest, lies [§4 Goldene Regeln](#4-goldene-regeln).

---

## Inhalt

1. [Was ist dieses Repo?](#1-was-ist-dieses-repo)
2. [Repo-Karte](#2-repo-karte)
3. [Setup, das du brauchst](#3-setup-das-du-brauchst)
4. [Goldene Regeln](#4-goldene-regeln)
5. [Workflow: einen Refactor-Bug fixen](#5-workflow-einen-refactor-bug-fixen)
6. [Workflow: einen neuen Refactor schreiben](#6-workflow-einen-neuen-refactor-schreiben)
7. [Test-Konventionen](#7-test-konventionen)
8. [AST-Fallen und Lösungen](#8-ast-fallen-und-lösungen)
9. [Commits, Pre-commit, PRs](#9-commits-pre-commit-prs)
10. [Was du NICHT tun sollst](#10-was-du-nicht-tun-sollst)
11. [Schnell-Nachschlagewerk: Module & Verantwortlichkeiten](#11-schnell-nachschlagewerk-module--verantwortlichkeiten)
12. [Wenn du nicht weiterkommst](#12-wenn-du-nicht-weiterkommst)

---

## 1. Was ist dieses Repo?

`number42_refactors` ist eine **Elixir-Library**, die als
`only: [:dev, :test], runtime: false`-Dependency in andere Elixir-Projekte
eingebunden wird. Sie liefert:

- einen Mix-Task `mix refactor`, der konfigurierbare AST-Rewrites
  über das Konsumenten-Repo laufen lässt.
- einen Mix-Task `mix refactor.heex_clones`, der HEEx-Klone reportet.
- ein Behaviour `Number42.Refactors.Refactor` für eigene Refactors.
- ~60 mitgelieferte Refactors in `lib/number42/refactors/ex/` und
  `lib/number42/refactors/heex/`.

**Was die Library NICHT ist:**

- kein Formatter — Formatieren macht `mix format`. Wir liefern nur den
  semantischen Rewrite.
- kein Linter — Stilhinweise und Warnungen sind Sache von Credo /
  Dialyzer.
- kein Runtime-Code. Es gibt keine Application, keinen Supervisor, keine
  Datenbank, kein Web-Layer. `application/0` registriert nur `:logger`
  als extra-application, sonst nichts.
- kein Phoenix-, kein Ecto-, kein LiveView-Code im Sinne von echten
  Abhängigkeiten. Phoenix-Form-Helper o.ä. tauchen nur **als
  Eingabe-Material** in HEEx-Refactors auf, nicht als Dependency.

Konsequenz: Wenn du etwas wie „mock the database“ oder „add a LiveView
component“ siehst, ist das hier fehl am Platz. Diese Library hat keine.

## 2. Repo-Karte

```
.
├── README.md                       # für menschliche Nutzer
├── AGENTS_README.md                # dieses Dokument
├── CHANGELOG.md                    # Keep-a-Changelog
├── LICENSE                         # MIT
├── mix.exs                         # Versions-Pin: Elixir ~> 1.18; deps siehe unten
├── mix.lock
├── devenv.nix                      # Dev-Shell (Elixir 1.19/OTP 28, Pre-commit-Hook)
├── devenv.yaml / devenv.lock       # devenv-State
├── .envrc                          # direnv → devenv
├── .formatter.exs                  # mix format-Inputs
├── .credo.exs                      # Credo-Config (strict, max_nesting: 3)
├── .dialyzer_ignore.exs            # leer; hier landen False Positives
├── .gitignore
├── .github/
│   ├── workflows/
│   │   ├── ci.yml                  # test matrix 1.18+27 / 1.19+28
│   │   ├── credo.yml               # --min-priority=high
│   │   ├── dialyzer.yml            # mit PLT-Cache
│   │   ├── security.yml            # mix deps.audit
│   │   └── auto-merge-dependabot.yml
│   ├── actions/setup-elixir/       # Composite-Action (Beam + Caches)
│   └── dependabot.yml              # wöchentliche Mix- & Action-Updates
├── lib/
│   ├── mix/tasks/
│   │   ├── refactor.ex             # der Haupt-Mix-Task (mix help refactor)
│   │   ├── refactor.heex_clones.ex # HEEx-Klone-Bericht
│   │   └── refactor/shared.ex      # gemeinsamer expand_inputs-Helfer
│   └── number42/refactors/
│       ├── engine.ex               # Pipeline-Driver, fixpoint loop, prepare-Cache
│       ├── refactor.ex             # Behaviour + `__using__` Makro
│       ├── ast_helpers.ex          # zentrale Helfer — VOR Eigenbau lesen
│       ├── ast_diff.ex             # Diff-Helfer für --log und Tests
│       ├── ex/<name>.ex            # die ~60 Refactor-Module (auch die HEEx-Refactors)
│       └── heex/                   # HEEx-Helfer: Tree, Fingerprint, Normalizer, Clones
│                                   # (KEINE Refactors hier — nur Tooling für die HEEx-Refactors)
├── test/
│   ├── test_helper.exs
│   ├── support/refactor_case.ex    # Number42.RefactorCase: assert_rewrites etc.
│   └── refactors/
│       ├── ast_helpers_test.exs
│       ├── ast_diff_test.exs
│       ├── engine_priority_test.exs
│       ├── ex/<name>_test.exs      # 1:1 zu lib/.../ex/<name>.ex
│       └── heex/                   # Tests für die HEEx-Helfer-Module
└── priv/plts/                      # Dialyzer-PLT (gitignored)
```

Erwartete 1:1-Abbildung:

```
# Refactors:
lib/number42/refactors/ex/<name>.ex     ⇄   test/refactors/ex/<name>_test.exs

# Interne HEEx-Helfer (kein Behaviour, nur Library-Tooling):
lib/number42/refactors/heex/<name>.ex   ⇄   test/refactors/heex/<name>_test.exs
```

Hinweis: Auch die **HEEx-Refactors** (`ExtractHeexExactClone`,
`ExtractHeexFor`) liegen unter `lib/number42/refactors/ex/`, nicht
unter `heex/` — das `heex/`-Unterverzeichnis enthält nur die
Library-Helfer (Tree, Fingerprint, Normalizer, Clones), die diese
Refactors benutzen.

Wenn du einen Refactor anlegst, der diese Symmetrie verletzt — ohne
Test oder mit falschem Test-Pfad — fixe es, bevor du committest.

## 3. Setup, das du brauchst

Vor jedem `mix`-Befehl: **du musst im Dev-Shell sein.**
Mix kommt aus `devenv.nix`, nicht aus dem System.

- Bist du in einer interaktiven Shell, in der `direnv` aktiv ist?
  Dann sollte alles laufen.
- Wenn `mix: command not found`: erst `direnv reload`, dann `devenv shell`.
- Wenn das nicht reicht: `rm -rf .direnv .devenv` → `direnv reload`.
- Nur dann `mix deps.get && mix compile`.

Versionen (siehe `devenv.nix`): **Elixir 1.19, Erlang/OTP 28** lokal.
CI testet **`1.18 + 27`** und **`1.19 + 28`** parallel — Code muss auf
beiden grün sein.

## 4. Goldene Regeln

Diese gelten ohne Ausnahmen.

1. **TDD ist Pflicht.** Test zuerst, RED, dann Implementation, GREEN.
   `assert_idempotent` in jeder Refactor-Test-Datei. Idempotenz ist
   kein Nice-to-have — der Engine hat eine Fixpoint-Schleife.
2. **`mix format` läuft vor `git add`.** Nie unformatierten Code stagen.
   Der pre-commit-Hook prüft `--check-formatted` und rollt den Commit
   sonst zurück.
3. **Lies `lib/number42/refactors/ast_helpers.ex` vor jedem neuen
   Refactor.** Helper wie `bare_var`, `body_to_exprs`,
   `clip_end_for_boolish_tail`, `var_ref?`, `unwrap_block`, `slice_node`
   und Konsorten sind schon da — und automatisch importiert durch
   `use Number42.Refactors.Refactor`. Lokale Funktionen mit dem
   gleichen Namen schlagen die Kompilation tot.
4. **Refactors sind semantik-bewahrend.** Wenn ein Rewrite das Verhalten
   ändern könnte, lieber skippen statt raten. Ambivalent → Input
   unverändert zurückgeben.
5. **Nur Refactor + Test committen.** Smoke-Tests, die die Library
   gegen sich selbst laufen lassen, werden mit
   `git checkout -- lib/ test/` verworfen, bevor du `git add` machst.
   Diese „Selbstanwendung“-Outputs gehören nie in einen Commit.
6. **Keine Refactoring-Pläne, Specs, Notes oder Markdown-Drafts ins
   Repo.** `.claude/` ist gitignored und privat. Wenn der User eine
   Doku-Datei (z.B. dieses `AGENTS_README.md`) explizit anfordert,
   commit sie — sonst halte Planungs-Markdown in deinem Arbeits-Kontext,
   nicht im Working Tree.
7. **Vor jedem Commit lokal:**
    ```sh
    mix format
    mix compile --warnings-as-errors
    mix test
    ```
   Wenn das alles grün ist, läuft der pre-commit-Hook beim ersten
   Versuch durch.
8. **Tests testen unseren Code, nicht Sourceror.** Wenn ein Test bei
   einem Sourceror-Bump ohne unsere Änderung bricht, testet er die
   Library, nicht uns — neu fassen oder löschen.
9. **Skippen statt raten.** Mehrdeutige AST-Muster (Pin-Variablen,
   konfliktierende Multi-Behaviours, fehlende Source-Slices) führen
   zum No-op, nicht zur Heuristik.
10. **Frag NICHT, lauf NICHT** `mix refactor --auto` über das eigene
    Repo, ohne dass der User es explizit will. Der Task committet
    eigenständig.

## 5. Workflow: einen Refactor-Bug fixen

Reproduktion → Test → Fix → Verifikation. Konkret:

1. **AST der Eingabe inspizieren.** Schneller als der Refactor-Code:

    ```sh
    mix run --no-start -e '
      src = "DEIN_BUGGY_BEISPIEL"
      {:ok, ast} = Sourceror.parse_string(src)
      IO.inspect(ast, limit: :infinity)
    '
    ```

   Hier findest du heraus, ob Literale gewrapped sind, ob ein Operator
   da ist, wo du eine Variable erwartet hast, ob `def` vs. `defp` den
   Match beeinflusst.

2. **Failing Test schreiben.** In der dazugehörigen
   `test/refactors/<area>/<name>_test.exs` einen
   `assert_rewrites` / `assert_unchanged` / `assert_idempotent`-Case
   anlegen, der das Bug-Verhalten festhält.

    ```sh
    mix test test/refactors/<area>/<name>_test.exs --trace
    ```

   Erwartete Farbe: **rot**.

3. **Engine-Isolation testen.** Wenn der Bug eventuell durch
   Pipeline-Interaktion entstand, prüf, ob er beim Single-Refactor
   auch auftritt:

    ```sh
    mix refactor --only <Name> --dry-run lib/path/to/file.ex
    ```

4. **Fixen.** Erst `ast_helpers.ex` ansehen, ob ein Helper schon
   existiert. Dann den Refactor in `lib/number42/refactors/ex/<name>.ex`
   anpassen. Halte Patches minimal, kein „while we're here“-Refactor.

5. **Idempotenz prüfen.** Wenn der Bug daher kam, dass der Refactor
   nochmal zubeißt, schreib zusätzlich einen `assert_idempotent`-Case.

6. **Test grün, Suite grün.**

    ```sh
    mix test test/refactors/<area>/<name>_test.exs --trace
    mix test
    ```

7. **Pre-commit-Triade lokal.**

    ```sh
    mix format
    mix compile --warnings-as-errors
    mix test
    ```

8. **Nur Refactor + Test stagen.**

    ```sh
    git status
    git add lib/number42/refactors/<area>/<name>.ex \
            test/refactors/<area>/<name>_test.exs
    git commit -m "fix: <name> — <kurze beschreibung>"
    ```

## 6. Workflow: einen neuen Refactor schreiben

1. **Vorlage wählen.** Match dein Shape an einen existierenden Refactor:
   - 1:1 deklaratives Pattern: `MapNewToPipe`, `EnumIntoToMapNew`.
   - Single-Pass-Walker mit Kontext-Flags: `ExtractToPipeline`,
     `ExtractSocketToPipe`.
   - Modul-skopiert (braucht Tabelle aus BEAM/AST): `ResolveImplTrue`,
     `AliasOrder`.
   - Cross-Node-Koordination (Block extrahieren + Sibling einfügen):
     `ExtractCaseToHelper`, `ExtractHeexFor`.
   - Voller Node-Replace: `IdentityPassthrough`, `CaseTrueFalse`.

2. **AST-Probe.** Wie in §5 — `mix run --no-start -e '...IO.inspect...'`.
3. **Test zuerst** in `test/refactors/<area>/<name>_test.exs`
   (`use Number42.RefactorCase, async: true`). Drei Sektionen:
   `describe "rewrites"`, `describe "leaves alone"`, `describe "idempotent"`.
   Lass den Test RED werden.
4. **Refactor-Modul** in `lib/number42/refactors/ex/<name>.ex`
   (auch HEEx-Refactors leben dort — `heex/` ist nur Library-Tooling):

    ```elixir
    defmodule Number42.Refactors.Ex.MyRule do
      use Number42.Refactors.Refactor

      @impl true
      def description, do: "Was er macht — eine Zeile."

      @impl true
      def explanation, do: """
      Langform, warum dieser Rewrite korrekt und sinnvoll ist.
      Wird in `mix refactor --log` gedruckt.
      """

      @impl true
      def priority, do: 150          # nur überschreiben, wenn du Reihenfolge brauchst

      @impl true
      def reformat_after?, do: true  # fast immer true für Rewrites

      @impl true
      def transform(source, _opts) do
        source
        |> Sourceror.parse_string()
        |> apply_patches(source)
      end

      # ...
    end
    ```

   Auto-Discovery passiert über das `is_refactor`-Attribut, das das
   `__using__`-Makro setzt — `use Number42.Refactors.Refactor` reicht.

5. **Test GREEN.** Suite GREEN.
6. **Optional Smoke-Test gegen die Library selbst:**

    ```sh
    mix refactor --only MyRule --dry-run
    ```

   Wenn etwas Komisches passiert, fixen oder explizit dokumentieren.
   **Output verwerfen** vor Commit: `git checkout -- lib/ test/`.

7. **Modul in `mix.exs`-`groups_for_modules`** in die passende
   Sektion eintragen, damit `mix docs` ihn gruppiert.

8. Pre-commit-Triade, dann `git add` nur für die neue Datei + Test +
   `mix.exs`-Änderung.

## 7. Test-Konventionen

- `Number42.RefactorCase` aus `test/support/refactor_case.ex` gibt dir
  `assert_rewrites/3,4`, `assert_unchanged/2,3`, `assert_idempotent/2,3`.
- Vergleich ist **whitespace-agnostic** — Heredocs in natürlicher
  Einrückung sind explizit erwünscht.
- `async: true` ist Standard. Es gibt keinen geteilten Zustand, der das
  verbietet.
- Jeder Test pro Refactor kommt in **ein** File. Mehrere Test-Files für
  denselben Refactor sind ein Code-Smell.
- Pro Refactor mindestens **ein** `assert_idempotent`-Case. Ohne ist die
  Sicherung gegen Fixpoint-Loops weg.
- Nicht testen: dass `Sourceror.parse_string` parsen kann, dass
  `Patch.replace` ersetzt, dass `Code.format_string!` formatieren kann.
  Das ist Framework, nicht unser Code.

## 8. AST-Fallen und Lösungen

Diese kommen so oft vor, dass man sie auswendig lernen sollte. Bei
jedem neuen Refactor: checkliste durchgehen.

### 8.1 Sourceror wrappt Literale

`true`, `false`, `nil`, Atome, Ints, Floats kommen unter Sourceror als
`{:__block__, _, [literal]}`, unter `Code.string_to_quoted` aber als
bare Werte. Pattern-Match beide Formen, sonst greifst du danebenseiten
inkonsistent.

```elixir
defp nil_literal?(nil),                    do: true
defp nil_literal?({:__block__, _, [nil]}), do: true
defp nil_literal?(_),                      do: false
```

### 8.2 Sourceror überzieht die Range von boolishen Schlussliteralen um 1

Wenn das rechteste Blatt deiner Range `true`, `false` oder `nil` ist,
frisst `Patch.replace` das Folgezeichen (oft Newline oder Komma).
Helfer: `clip_end_for_boolish_tail/2` aus `AstHelpers`.

### 8.3 Funktions-Köpfe sehen aus wie Calls

```elixir
{:def, _, [{:foo, _, [x, y]}, body_kw]}
```

Das `{:foo, _, [x, y]}` matcht jedes generische Local-Call-Pattern.
**`def`/`defp`/`defmacro`/`defmacrop` immer explizit behandeln**:
Kopf überspringen, ins Body-Keyword reinwalken — dort sitzen
`do:`, `rescue:`, `catch:`, `else:`, `after:`. Nicht nur `do:`.

### 8.4 Operatoren teilen die AST-Form mit Calls

`{:=, _, [lhs, rhs]}` und `{:foo, _, [x, y]}` sind strukturell
identisch. Wenn du ein generisches Call-Pattern matchst, mit
`Macro.operator?(name, arity)` guarden.

### 8.5 No-rewrite-Zonen für Pipes

In **Pipe-RHS** (`|>`), in **`&`-Capture-Bodies**, hinter **`^`-Pin**,
und an Operanden von `pipe_unsafe_op?`-Operatoren (siehe `AstHelpers`)
**keine** neuen Pipes einführen — die Präzedenz dreht sich, der Code
wird semantisch anders oder invalid. Vorbild für den Kontext-Flag-Walk:
`ExtractToPipeline`.

### 8.6 `Sourceror.to_string/1` duplicates Kommentare

Sourceror legt führende und folgende Kommentare in
`:leading_comments` / `:trailing_comments` der Node-Meta ab. Wenn du
einen bestehenden Subtree wiederverwendest und durch `to_string/1`
schickst, kriegst du die Kommentare nochmal — und die gepatchte Range
enthielt sie schon. Resultat: Duplikat. Lösung:

```elixir
defp render_clean(ast), do: ast |> strip_comments() |> Sourceror.to_string()

defp strip_comments(ast) do
  Macro.prewalk(ast, fn
    {form, meta, args} when is_list(meta) ->
      {form,
       meta |> Keyword.put(:leading_comments, []) |> Keyword.put(:trailing_comments, []),
       args}

    other -> other
  end)
end
```

Whitespace-agnostische Tests verstecken diesen Bug. Schreib einen
Fixture-Test mit führendem Kommentar und assert, dass das Output **eine**
Kopie davon hat.

### 8.7 `reformat_after?, do: true` ist fast immer richtig

Sourceror und `Macro.to_string` emittieren oft Whitespace, das `mix
format` aufräumt. Ohne `reformat_after?` blieben Diffs unschön. Aber:
das Format-Followup baut **keine Pipe-Ketten** wieder auf, die du
flach gemacht hast. Wenn dein Replacement eine Pipe enthalten muss,
schreib sie als **eine** Expression (ohne Mehrfachpipe), bevor sie
re-serialisiert wird.

## 9. Commits, Pre-commit, PRs

**Reihenfolge:**

1. `mix format`
2. `mix compile --warnings-as-errors`
3. `mix test`
4. `git status` — schau, was modifiziert wurde
5. `git add <konkrete dateien>` — kein `git add -A`, kein `.`
6. `git commit -m "..."` (siehe Format unten)

**Commit-Message-Format** (Conventional Commits):

```
<type>: <kurze beschreibung>

[längere erklärung wenn nötig]
```

Typen, die hier vorkommen: `feat`, `fix`, `refactor`, `test`, `docs`,
`chore`, `style`, `ci`. Schau in `git log` für den lokalen Stil.

**`--no-verify`** ist die letzte Option. Wenn der Hook aus
Infrastruktur-Gründen (Nix-Cache-Permissions, devenv-Reload) hängt,
darfst du ihn bypassen — aber:

- die Pre-commit-Triade muss vorher manuell grün sein,
- der User muss informiert werden, warum,
- die Ursache muss zeitnah behoben werden, nicht permanent umgangen.

**Per PR / Branch:**

- Eine Änderung pro PR, klein und reversibel.
- Bei Bugs: Fix gehört in den PR, der den Bug eingeführt hat, wenn der
  noch offen ist (stacked-PR-Bugfix-Rebase).
- Niemals `git push --force` auf `main`.
- Nie auf `main` direkt committen — alles über PR.

## 10. Was du NICHT tun sollst

- **Nicht** Phoenix-/Ecto-/LiveView-Code einbauen. Diese Library hat
  keine. Wenn ein Refactor Phoenix-Form-Helper sieht, ist das
  Konsumenten-Code, nicht hier.
- **Nicht** im Smoke-Test-Modus die eigene Library committen. Nach
  `mix refactor --only X` über `lib/` und `test/` **immer**
  `git checkout -- lib/ test/`, bevor `git add`.
- **Nicht** Tests anlegen, die Sourceror-Verhalten prüfen. Wir testen
  unsere Rewrites, nicht Library-Internals.
- **Nicht** Mocks für „die Datenbank“ oder „den Webserver“ basteln. Es
  gibt keine.
- **Nicht** `.refactor.exs` in dieses Repo committen. Die Library hat
  keine — sie ist Library, kein Konsument.
- **Nicht** den `.devenv*`/`.direnv`/`.claude/`-State committen — alles
  in `.gitignore`.
- **Nicht** unformatierten Code stagen. `mix format` zuerst.
- **Nicht** Refactors schreiben, die nicht idempotent sind. Fixpoint
  läuft endlos.
- **Nicht** `Number42.Refactors.AstHelpers` reimplementieren. Erst
  lesen, dann ergänzen, wenn was wirklich fehlt.
- **Nicht** Planungs-Markdown, Specs, Drafts, Activity-Logs ins
  Working Tree legen. `.claude/` ist privat. Wenn etwas committed
  werden soll, fragt der User explizit (so wie für `README.md`,
  `AGENTS_README.md`, `CHANGELOG.md`).
- **Nicht** `mix refactor --auto` ohne explizite Anweisung. Der Task
  legt Commits selbständig an — das überrascht den User negativ.
- **Nicht** Helfer in ein neues Modul auslagern, wenn nur ein
  Refactor sie nutzt. `AstHelpers` ist für **geteilte** Logik mit
  identischer Semantik. Per-Refactor-Helper bleiben lokal.

## 11. Schnell-Nachschlagewerk: Module & Verantwortlichkeiten

| Modul | Datei | Verantwortung |
| --- | --- | --- |
| `Mix.Tasks.Refactor` | `lib/mix/tasks/refactor.ex` | CLI: Config laden, Inputs expandieren, `--auto`/`--check`/`--step-by-step`/`--test`-Driver, Follow-up `mix format`. |
| `Mix.Tasks.Refactor.HeexClones` | `lib/mix/tasks/refactor.heex_clones.ex` | HEEx-Klone-Report in drei Modi (`exact`, `class_stripped`, `attrs_stripped`). |
| `Mix.Tasks.Refactor.Shared` | `lib/mix/tasks/refactor/shared.ex` | Gemeinsamer `expand_inputs`-Helfer. |
| `Number42.Refactors.Engine` | `lib/number42/refactors/engine.ex` | Pure Library. Refactor-Discovery, Sortierung nach Priority, Fixpoint-Loop (max 5 Pässe), `prepare/1`-Cache via `:persistent_term`, `skip_in_modules`. Kein I/O. |
| `Number42.Refactors.Refactor` | `lib/number42/refactors/refactor.ex` | Behaviour + `__using__`-Makro. Setzt `is_refactor`-Attribut, importiert `AstHelpers`. |
| `Number42.Refactors.AstHelpers` | `lib/number42/refactors/ast_helpers.ex` | Zentrale AST-Prädikate, Compound-Name-Heuristiken für `ExpandShortForm*`. **Lies das, bevor du Helfer baust.** |
| `Number42.Refactors.AstDiff` | `lib/number42/refactors/ast_diff.ex` | Diff-Helfer für `--log`-Ausgabe und Test-Failure-Messages. |
| `Number42.Refactors.Heex.{Tree,Fingerprint,Normalizer,Clones}` | `lib/number42/refactors/heex/*.ex` | HEEx-Subbaum-Modell, Strukturhashing und Klon-Detection. |
| `Number42.Refactors.Ex.*` | `lib/number42/refactors/ex/*.ex` | Die ~60 Refactors. Eine Verantwortung pro Modul. |
| `Number42.RefactorCase` | `test/support/refactor_case.ex` | Gemeinsame Test-Helfer (`assert_rewrites`, `assert_unchanged`, `assert_idempotent`). |

**Behaviour-Callbacks im Überblick (`Number42.Refactors.Refactor`):**

| Callback | Pflicht? | Default | Zweck |
| --- | --- | --- | --- |
| `transform(source, opts)` | Ja | — | Rewrite. Idempotent, semantik-bewahrend. |
| `description/0` | Ja | — | Einzeiler für Hilfe und Logs. |
| `explanation/0` | Optional | `description/0` | Langform-Rationale für `--log`. |
| `priority/0` | Optional | `100` | Reihenfolge. Höher läuft früher. |
| `reformat_after?/0` | Optional | `false` | Triggert `mix format` als Follow-up. |
| `prepare/1` | Optional | nicht aufgerufen | Einmal-Plan pro Engine-Run, gecacht. Für teure Cross-Refactor-Daten. |

## 12. Wenn du nicht weiterkommst

- **AST unklar:** `mix run --no-start -e 'IO.inspect Sourceror.parse_string("..."), limit: :infinity'`.
- **Helper unklar:** `lib/number42/refactors/ast_helpers.ex` lesen.
  Funktion `bare_var`, `body_to_exprs`, `clip_end_for_boolish_tail` etc.
  sind dort gut dokumentiert.
- **Refactor-Vorbild gesucht:** §6, „Vorlage wählen“ — das passende
  Beispiel aus `lib/number42/refactors/ex/` öffnen.
- **Engine-Verhalten unklar:** `lib/number42/refactors/engine.ex` ist
  ~300 Zeilen mit ausführlichen Modul- und Funktionsdoc-Strings —
  Fixpoint-Loop, Priority-Resolution, `prepare`-Cache sind dort
  beschrieben.
- **`mix help refactor`** für die offizielle Beschreibung der CLI-Flags.
- **Tests laufen nicht / `mix`-Befehl unbekannt:** Du bist nicht im
  Dev-Shell. Siehe §3.
- **Pre-commit blockiert:** §9. Erst Triade manuell grün, dann erneut
  committen.

Wenn nach 15 Minuten konkret-debuggen kein Fortschritt da ist, **frag
den User**, statt zu spekulieren oder zu raten.

---

Letzte Aktualisierung: 2026-05-20.
Wenn du diese Datei verlängerst, kürze gleichzeitig — sie ist nur
nützlich, solange sie kurz genug zum Lesen bleibt.
