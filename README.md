# Number42.Refactors

AST-based refactor engine for Elixir — pluggable, idempotent,
semantics-preserving rewrites driven by [Sourceror][sourceror].

> Status: pre-release. Extracted from an internal project; the public
> API is settling. Expect cosmetic changes before `v1.0`.

- **Was es ist:** ein Mix-Task plus ~60 modulare Refactors, die deinen
  Code automatisch in idiomatisches Elixir umschreiben (`Enum.into → Map.new`,
  `length(x) == 0 → x == []`, geteilte HEEx-Klone in `CoreComponents` ziehen, …).
- **Was es nicht ist:** kein Formatter (das macht `mix format`), kein Linter
  (das macht Credo), kein Compiler-Plugin. Jeder Refactor ist eine reine
  String-Transformation `source → source`, getrieben von Sourceror.
- **Wer es nutzt:** als Library-Dependency in Elixir-Projekten
  (`only: [:dev, :test], runtime: false`) — Endprodukt sind Git-Diffs, kein
  Laufzeitverhalten.

---

## Inhalt

- [Installation](#installation)
- [Quickstart](#quickstart)
- [Konfiguration: `.refactor.exs`](#konfiguration-refactorexs)
- [Was steckt drin?](#was-steckt-drin)
- [Lokale Entwicklung](#lokale-entwicklung)
- [Testen](#testen)
- [Bugfixing-Workflow](#bugfixing-workflow)
- [Einen eigenen Refactor schreiben](#einen-eigenen-refactor-schreiben)
- [Architektur in 5 Minuten](#architektur-in-5-minuten)
- [CI & Quality Gates](#ci--quality-gates)
- [Release & Versionierung](#release--versionierung)
- [Troubleshooting](#troubleshooting)
- [Lizenz](#lizenz)

---

## Installation

```elixir
def deps do
  [
    {:number42_refactors, "~> 0.1", only: [:dev, :test], runtime: false}
  ]
end
```

Dann `mix deps.get` — und unten unter
[Konfiguration](#konfiguration-refactorexs) eine `.refactor.exs` anlegen,
sonst weigert sich der Task.

## Quickstart

```sh
mix refactor                     # alle Refactors anwenden, in-place schreiben
mix refactor --check             # CI-Gate: exit ≠ 0, sobald etwas zu refactorn wäre
mix refactor --dry-run           # git-style Diff drucken, nicht schreiben
mix refactor --log               # pro Refactor: Beschreibung + Rationale + Diff
mix refactor --auto              # nach jeder Datei einen Commit anlegen
mix refactor --step-by-step      # Refactor für Refactor über alle Files laufen
mix refactor --only RejectIsNil  # nur ein bestimmter Refactor (Suffix oder snake_case)
mix refactor lib/foo/bar.ex      # auf bestimmte Pfade beschränken

mix refactor.heex_clones         # HEEx-Klone-Bericht (exact / class-stripped / attrs-stripped)
```

Vollständige Optionsliste: `mix help refactor` und
`mix help refactor.heex_clones`.

## Konfiguration: `.refactor.exs`

Die Datei liegt im Projekt-Root des **Konsumenten** und ist ein purer
`Code.eval_string/3`-Map-Ausdruck. Ohne sie bricht `mix refactor` ab.

```elixir
%{
  # Pflicht: Pfade, die der Engine standardmäßig umschreibt.
  inputs: ["lib/**/*.ex", "test/**/*.exs"],

  # Optional: Per-Refactor-Opts. Keys sind fully-qualified Module,
  # Values sind Keyword-Listen. Häufige Schlüssel:
  #   priority:        integer (Default 100; höher läuft früher)
  #   skip_in_modules: [Module, ...] — Source-Files, die eines dieser
  #                    Module mit defmodule definieren, werden ausgelassen
  configured_modules: [
    {Number42.Refactors.Ex.ExpandShortFormBindings,
     skip_in_modules: [MyApp.Color]}
  ],

  # Optional: Refactors, die im Projekt nie laufen sollen.
  skipped_modules: [],

  # Optional: HEEx-Klon-Extraktion. Setze das Ziel-CoreComponents-Modul.
  # Bleibt der Key weg, ist `ExtractHeexExactClone` ein No-op.
  heex: %{
    core_components_module: "MyAppWeb.CoreComponents"
  }
}
```

Siehe `Mix.Tasks.Refactor`-Moduldoc für die vollständige Semantik der
einzelnen Schalter und die Wechselwirkungen (`--auto` + `--test`,
`--step-by-step` + `--stop`, etc.).

## Was steckt drin?

Aktuell **59 Refactors**, gruppiert nach Themengebiet:

- **Style & Reihenfolge:** Alias-Sortierung, Multi-Alias-Expansion,
  `import`-nach-`alias`, Funktions-Reihenfolge, Keyword-Sortierung,
  Leerzeilen zwischen Attributen.
- **Enum / Map / Stream-Idiomatik:** `Enum.into → Map.new`,
  `Enum.reduce → Enum.sum`, `Enum.reverse |> Enum.concat`,
  `Enum.flat_map → Enum.filter`, `Map.new`-Lambda zum For-Comprehension,
  Stream-freundliche Rewrites, `Enum.reject(&is_nil/1)`,
  `reduce_as_map`, `reduce_map_put`.
- **Pattern Matching statt Conditionals:** `if`-Lift in Klauseln,
  redundante Boolean-`if`, geschachteltes `case` → `with`,
  `with`-mit-einer-Klausel → `case`, `with`-ohne-`else`.
- **Pipes & Sigil-Rewrites:** Socket-zu-Pipe-Extraktion, Pipeline-Extraktion,
  Pipe-Reassign, `with` ins Pipeline lifte, gepinnten Ecto-Ausdruck lifte.
- **Length / String / List:** `length`-im-Guard, `length(x) == 0`, 
  `List.last(Enum.reverse(...))`, `String.graphemes |> length`,
  `Enum.sort |> Enum.take` als Top-K.
- **Definition-Hygiene:** `inline-single-expression-def`,
  `identity-passthrough`, `delegate-exact-duplicates`,
  `expand-short-form-{bindings,functions,params}`, ungenutzte Variable,
  `@impl true`-Resolve, trivialer `else`-Zweig, `case true/false`.
- **Cross-File-Extraktion:** geteiltes Modul, parametrische / umbenannte /
  intra-modul Klone, verschachtelte / Lambda- / Inline-Blöcke,
  `case` → Helper.
- **HEEx-Klone:** `extract-heex-exact-clone` (konfigurierbares Ziel),
  `extract-heex-for`.
- **Typ- & API-Safety:** `try/rescue` mit sicherer Alternative,
  `Map.get`-unsafe-Pass, `DateTime.utc_now |> ...truncate`.

`mix help refactor` listet jeden Refactor mit Kurzname auf.

---

## Lokale Entwicklung

Die Library setzt **devenv + direnv** voraus (siehe `devenv.nix`).
Erstmaliges Setup:

```sh
direnv allow            # erlaubt direnv, den Dev-Shell automatisch zu laden
devenv shell            # Elixir 1.19 / OTP 28 + Tools, einmaliges Reinmachen
mix deps.get            # macht das enterShell-Script schon, hier zur Sicherheit
mix compile             # erste Kompilation
```

Danach reicht ein `cd` ins Projekt — `direnv` aktiviert den Shell.
Wer kein Nix mag, kann die Versionen aus `devenv.nix` (Elixir 1.18+/1.19,
OTP 27+/28) auch über `asdf`/`mise` setzen; CI testet die Matrix
`1.18/27` und `1.19/28`.

**Tägliche Kommandos:**

| Aufgabe                                 | Kommando                                 |
| --------------------------------------- | ---------------------------------------- |
| Tests laufen lassen                     | `mix test`                               |
| Nur eine Test-Datei                     | `mix test test/refactors/ex/foo_test.exs` |
| Watch-Modus (manuell)                   | `mix test --stale`                       |
| Coverage                                | `mix test --cover`                       |
| Format-Check                            | `mix format --check-formatted`           |
| Format auto-fixen                       | `mix format`                             |
| Warnings als Errors kompilieren         | `mix compile --warnings-as-errors`       |
| Credo (high priority)                   | `mix credo --min-priority=high`          |
| Credo strict (volle Liste)              | `mix credo --strict`                     |
| Dialyzer (PLT baut beim ersten Lauf)    | `mix dialyzer`                           |
| Security-Audit der Deps                 | `mix deps.audit`                         |
| Doku lokal bauen + ansehen              | `mix docs && open doc/index.html`        |

**Vor jedem Commit lokal die Pre-commit-Triade laufen lassen:**

```sh
mix format
mix compile --warnings-as-errors
mix test
```

Das ist genau das, was `devenv shell precommit` macht (siehe
`devenv.nix`, `scripts.precommit.exec`). Wenn du es vorab manuell machst,
geht der Commit beim ersten Versuch durch — sonst formatiert der Hook
nach, der Commit bricht ab, und du musst neu `git add` + `git commit`.

## Testen

Jeder Refactor hat **genau eine** Test-Datei in
`test/refactors/<area>/<name>_test.exs`, die ihn **isoliert** prüft
(nicht über die volle Pipeline). Damit zeigt ein roter Test auf genau
das Modul, das gebrochen ist.

Das Test-Case-Modul ist `Number42.RefactorCase`
(`test/support/refactor_case.ex`). Es liefert drei Helper:

```elixir
defmodule Number42.Refactors.Ex.RejectIsNilTest do
  use Number42.RefactorCase, async: true

  alias Number42.Refactors.Ex.RejectIsNil
  @subject RejectIsNil

  describe "rewrites" do
    test "filter + not is_nil → Enum.reject(&is_nil/1)" do
      assert_rewrites(
        @subject,
        "Enum.filter(list, fn x -> not is_nil(x) end)",
        "Enum.reject(list, &is_nil/1)"
      )
    end
  end

  describe "leaves alone" do
    test "schon kanonisch" do
      assert_unchanged(@subject, "Enum.reject(list, &is_nil/1)")
    end
  end

  describe "idempotent" do
    test "zweimal == einmal" do
      assert_idempotent(@subject, "Enum.filter(list, fn x -> not is_nil(x) end)")
    end
  end
end
```

Wichtige Konventionen:

- **`async: true` ist Pflicht** — alle Refactor-Tests sind pure Funktionen,
  es gibt keine geteilte Datenbank- oder Prozess-State.
- **Whitespace-agnostischer Vergleich.** `assert_rewrites/3` collapsed
  jede Whitespace-Sequenz, bevor verglichen wird — Heredocs mit
  natürlicher Einrückung sind also okay, und wir umgehen einen
  `mix format`-Pass im Test-Pfad. Die Failure-Message zeigt trotzdem die
  rohen Before/Expected/Actual-Strings.
- **Drei Sektionen pro Test-Datei:** `describe "rewrites"`,
  `describe "leaves alone"`, `describe "idempotent"`. Idempotenz ist
  nicht optional — der Engine hat eine Fixpoint-Schleife und ein
  nicht-idempotenter Refactor läuft unendlich.
- **Tests prüfen unsere Refactors, nicht Sourceror.** Wenn ein Test bei
  einem Sourceror-Bump bräche, ohne dass wir etwas geändert haben,
  testet er die Library statt uns — umformulieren oder löschen.

Coverage-Hilfe:

```sh
mix test --cover                                       # Gesamt-Übersicht
mix test test/refactors/ex/reject_is_nil_test.exs --trace  # ein Refactor, geschwätzig
```

## Bugfixing-Workflow

Ein typischer Refactor-Bug sieht so aus: ein Konsument meldet, dass
`Foo.bar` plötzlich kaputt umgeschrieben wurde, oder ein File ändert sich
beim zweiten Lauf nochmal (Idempotenz-Bruch). So gehst du vor:

1. **Reproduktion isolieren.** Bau die kleinste Eingabe, die das
   Verhalten zeigt. Schau dir die AST-Struktur an, bevor du den
   Refactor-Code öffnest:

    ```sh
    mix run --no-start -e '
      src = "EnumYourBuggyExample"
      {:ok, ast} = Sourceror.parse_string(src)
      IO.inspect(ast, limit: :infinity)
    '
    ```

2. **Failing Test zuerst.** Schreibe in der passenden
   `test/refactors/<area>/<name>_test.exs` einen `assert_rewrites`-
   oder `assert_unchanged`-Case mit deiner Eingabe und der erwarteten
   Ausgabe. Lass ihn rot werden:

    ```sh
    mix test test/refactors/ex/your_refactor_test.exs --trace
    ```

3. **Engine isoliert ausführen.** Wenn die Pipeline ein Faktor sein
   könnte, prüf mit `--only`, ob der einzelne Refactor reicht:

    ```sh
    mix refactor --only YourRefactor --dry-run lib/path/to/file.ex
    ```

4. **Refactor fixen.** Schau in `lib/number42/refactors/ast_helpers.ex`,
   bevor du Helper neu baust — vieles ist schon da
   (`bare_var`, `body_to_exprs`, `clip_end_for_boolish_tail`, …).
5. **Idempotenz prüfen.** `assert_idempotent` mit dem reparierten
   Input ergänzen, sonst kommt der Bug beim Fixpoint zurück.
6. **Gegen die Library selbst gegentesten.** Wenn der Refactor nicht
   nur Stilkram macht, kann ein `mix refactor --only YourRefactor`
   im eigenen Repo unerwartete Folgen produzieren. Diff anschauen,
   danach **`git checkout -- lib/ test/`** — wir committen weder
   den Smoke-Test-Output noch zufällige Pipeline-Folgen, nur den
   Refactor + seinen Test.
7. **Vor Commit:**

    ```sh
    mix format
    mix compile --warnings-as-errors
    mix test
    ```

   Dann `git add <refactor>.ex <refactor>_test.exs` (nichts anderes)
   und committen. Der pre-commit-Hook wiederholt die Triade — wenn du
   sie vorher schon grün gemacht hast, läuft der Commit beim ersten
   Versuch durch.

### Häufige AST-Fallen

Bevor du Code schreibst, halt dich an diese Punkte (Details und Beispiele
stehen in der `AGENTS_README.md`):

- Sourceror wickelt `true`, `false`, `nil`, Atome, Integer, Floats in
  `{:__block__, _, [literal]}`. Pattern-Match auf beide Formen.
- Sourceror überzieht die Range von `true`/`false`/`nil` um eine Spalte
  → `Patch.replace` frisst sonst das Folgezeichen. Helfer:
  `clip_end_for_boolish_tail/2` aus `Number42.Refactors.AstHelpers`.
- `def`/`defp`/`defmacro`/`defmacrop`-Heads sehen aus wie generische
  Calls — die müssen explizit übersprungen oder unterschiedlich
  behandelt werden, sonst rewritest du Signaturen.
- `Sourceror.to_string/1` re-emittiert
  `:leading_comments`/`:trailing_comments` aus der Node-Meta. Beim
  Wiederverwenden bestehender Subtrees vor dem `to_string/1` mit
  `Macro.prewalk` strippen.
- Skippen ist besser als raten: bei mehrdeutigen Patterns lieber
  unverändert lassen.

## Einen eigenen Refactor schreiben

Ein Refactor ist ein Modul, das `Number42.Refactors.Refactor`
implementiert und mit `use Number42.Refactors.Refactor` markiert wird.
Die Engine entdeckt ihn beim Start automatisch:

```elixir
defmodule MyApp.Refactors.MyRule do
  use Number42.Refactors.Refactor

  @impl true
  def description, do: "Was dieser Refactor macht — eine Zeile."

  @impl true
  def transform(source, _opts) do
    # Sourceror-basierter Rewrite; den umgeschriebenen String zurückgeben.
    # Idempotent! Konformer Code muss unverändert durch.
    source
  end

  # Alle optional:
  # @impl true
  # def explanation, do: "Langform-Begründung für --log."
  # @impl true
  # def priority, do: 150               # Default 100; höher = früher
  # @impl true
  # def reformat_after?, do: true       # nach Anwenden mix format triggern
  # @impl true
  # def prepare(_opts), do: {:ok, term} # einmal pro Engine-Run, gecacht
end
```

Pflichteigenschaften:

- **Semantik-bewahrend.** Output verhält sich identisch zum Input.
- **Idempotent.** Zweiter Lauf == erster Lauf.
- **Skippen statt raten.** Ambivalente Fälle bleiben unverändert.

Schreibreihenfolge (TDD):

1. Test-Datei mit `assert_rewrites` / `assert_unchanged` / `assert_idempotent`.
2. `mix test --trace` → RED.
3. Refactor-Modul.
4. Test → GREEN.
5. Optional: Smoke-Test gegen die Library selbst, danach `git checkout -- lib/ test/`.

## Architektur in 5 Minuten

```
       .refactor.exs                 mix refactor [opts] [paths]
            │                                │
            ▼                                ▼
 ┌────────────────────────────────────────────────────────┐
 │ Mix.Tasks.Refactor       (lib/mix/tasks/refactor.ex)   │
 │  • Config laden, Inputs expandieren                    │
 │  • --auto/--test/--check/--step-by-step Driver         │
 │  • mix format als Follow-up bei reformat_after?        │
 └───────────┬────────────────────────────────────────────┘
             ▼
 ┌────────────────────────────────────────────────────────┐
 │ Number42.Refactors.Engine                              │
 │  • discoverte Refactors (`is_refactor`-Attribut)       │
 │  • sortiert nach priority/0 (höher zuerst)             │
 │  • Fixpoint-Loop pro Datei (max 5 Pässe)               │
 │  • prepare/1-Cache via :persistent_term                │
 └───────────┬────────────────────────────────────────────┘
             ▼
 ┌────────────────────────────────────────────────────────┐
 │ ein Refactor-Modul (lib/number42/refactors/ex/*.ex)    │
 │  • transform(source, opts) :: source                   │
 │  • benutzt Sourceror + AstHelpers + AstDiff            │
 └────────────────────────────────────────────────────────┘
```

Wichtige Module:

- **`Number42.Refactors.Engine`** — pure Library, kein I/O, kein Mix.
  Driver für die Refactor-Pipeline, kennt `--only` / `skipped_modules` /
  Prioritäten / Fixpoint-Loop.
- **`Number42.Refactors.Refactor`** — Behaviour + `__using__`-Makro.
  Setzt das `is_refactor`-Attribut, importiert `AstHelpers`.
- **`Number42.Refactors.AstHelpers`** — geteilte AST-Prädikate und
  -Accessors. Bevor du etwas neu baust: erst lesen.
- **`Number42.Refactors.AstDiff`** — interne Diff-Helfer für
  `--log` und Test-Failure-Messages.
- **`Mix.Tasks.Refactor`** — der CLI-Driver. Hier sitzen `--auto`,
  `--check`, `--step-by-step`, `--test`, der Follow-up-Format-Lauf.
- **`Mix.Tasks.Refactor.HeexClones`** — der separate HEEx-Klon-Bericht.
- **`Number42.Refactors.Heex.*`** — Tree, Fingerprint, Normalizer,
  Clones-Detection für HEEx-Subbäume.
- **`Number42.RefactorCase`** (`test/support/`) — gemeinsame
  Test-Helfer (`assert_rewrites`, `assert_unchanged`, `assert_idempotent`).

## CI & Quality Gates

Die CI in `.github/workflows/` läuft pro PR und Push auf `main`:

- **`ci.yml`** — Matrix `1.18 / OTP 27` + `1.19 / OTP 28`:
  `mix format --check-formatted`, `mix compile --warnings-as-errors`,
  `mix test`.
- **`credo.yml`** — `mix credo --min-priority=high` (high-Priority-only,
  damit niedrigere Hinweise nicht blocken; `mix credo --strict` lokal
  ist die volle Liste).
- **`dialyzer.yml`** — `mix dialyzer --format short`, mit PLT-Cache.
- **`security.yml`** — `mix deps.audit` (wöchentlich + bei jedem PR).
- **`auto-merge-dependabot.yml`** — Dependabot-Patch/Minor-PRs werden
  per Auto-Merge gemerged, sobald die obigen Checks grün sind.

Lokal lassen sich alle Checks unter dem Dev-Shell starten — die Sektion
[Lokale Entwicklung](#lokale-entwicklung) hat die Kommandos.

## Release & Versionierung

- Versionierung: Semver (siehe `CHANGELOG.md`, Keep-a-Changelog-Format).
- Pakete bauen: `mix hex.build`. Tatsächliches Publishen passiert
  bewusst manuell aus dem Maintainer-Account.
- `CHANGELOG.md` bei jedem releasten Change aktualisieren — speziell den
  `## [Unreleased]`-Block.

## Troubleshooting

**`mix` ist nicht im Pfad / unbekannter Befehl.** Du bist nicht im
Dev-Shell. `direnv reload` oder `devenv shell`. Wenn das nichts hilft,
`rm -rf .direnv .devenv`, dann `direnv reload`. (Siehe auch
`.claude/memories/nix-devenv-mix.md` — die Memories sind privat, der
Befehl ist trotzdem allgemein gültig.)

**Pre-commit-Hook bricht den Commit ab.** Höchstwahrscheinlich ein
`mix format`-Mismatch. Lokal `mix format` laufen lassen, neu stagen,
neu committen. **Nie `--no-verify` als Default** — nur als letzter
Ausweg, wenn die Infrastruktur (Nix-Cache, devenv-Reload) wirklich
hängt; dann vorab die Pre-commit-Triade manuell grün haben.

**Refactor läuft endlos in Tests.** Idempotenz gebrochen. `mix test
test/refactors/ex/<name>_test.exs --trace` führt direkt zur Stelle.
Ein `assert_idempotent` ist Pflicht in jeder Test-Datei.

**`Sourceror.to_string/1` produziert duplizierte Kommentare.**
Klassischer Trap: Kommentare in der Node-Meta. Lösung steht in
[Häufige AST-Fallen](#häufige-ast-fallen).

**`mix refactor` will eine `.refactor.exs`, die es nicht gibt.** Diese
Library hat selbst keine — sie ist Library, kein Konsument. Im
Konsumenten anlegen, siehe [Konfiguration](#konfiguration-refactorexs).

**Dialyzer ist langsam.** Erster Lauf baut den PLT — `priv/plts/`. In CI
gecacht über `mix.lock`-Hash. Wenn der Cache schmutzig ist:
`rm -rf priv/plts && mix dialyzer`.

## Lizenz

MIT — siehe [LICENSE](LICENSE).

[sourceror]: https://github.com/doorgan/sourceror
