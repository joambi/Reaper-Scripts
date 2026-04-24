# REAPER Region Launch Scripts

[![Reaper Scripts CI](https://github.com/https://github.com/joambi/Reaper-Scripts/actions/workflows/reaper-ci.yml/badge.svg)](https://github.com/https://github.com/joambi/Reaper-Scripts/actions/workflows/reaper-ci.yml)

Diese Sammlung ist fuer ein Live-Setup gedacht, bei dem Regions von Hand aus dem `Region/Marker Manager` gestartet werden.

Die Scripts starten Regions gezielt und stoppen automatisch am Regionsende. So kannst du dein Arrangement manuell abfahren, ohne die Live-FX selbst hart umzuschalten.

## Enthaltene Scripts

- `JS_Play selected region in Region Manager and stop at region end.lua`
  Startet die aktuell ausgewaehlte Region ab Regionsanfang.

- `JS_Play selected region in Region Manager from current position and stop at region end.lua`
  Startet die aktuell ausgewaehlte Region ab aktueller Cursor-Position, falls der Cursor innerhalb der Region liegt. Sonst ab Regionsanfang.

- `JS_Select next region in Region Manager and play it.lua`
  Waehlt im Region Manager die naechste Region aus und startet sie.

- `JS_Select previous region in Region Manager and play it.lua`
  Waehlt im Region Manager die vorige Region aus und startet sie.

- `JS_Play region at edit cursor and stop at region end.lua`
  Alternative Variante ohne Region Manager: startet die Region unter dem Edit-Cursor.

- `JS_Panic stop playback and reset region launcher state.lua`
  Stoppt sofort die Wiedergabe und setzt die internen Status der Region-Launcher zurueck.

- `JS_Generate FOA B-Format HTML analysis.py`
  Analysiert eine FOA/B-Format-Datei oder ein selektiertes 4-Kanal-Item und erzeugt ein HTML-Dashboard mit Intensitaetsvektor, Richtungsverlauf und Kanal-RMS.

- `JS_Generate FOA B-Format HTML analysis.lua`
  Lua-Version derselben Analyse fuer Setups, in denen Python-ReaScript in REAPER nicht verfuegbar ist.

- `JAR Post-Render B-Format-Analyse.lua`
  Startet `analyze_bformat.py` fuer ein selektiertes B-Format-/HOA-Item oder als Post-Render-Action fuer gerenderte Dateien.

## Empfohlene Tastenbelegung

- `Return`
  `JS_Play selected region in Region Manager and stop at region end.lua`

- `Shift+Return`
  `JS_Play selected region in Region Manager from current position and stop at region end.lua`

- `Cmd+Return` auf macOS oder `Ctrl+Return` auf Windows
  `JS_Select next region in Region Manager and play it.lua`

- `Alt+Return`
  `JS_Select previous region in Region Manager and play it.lua`

- `Escape` oder eine freie Taste in Reichweite
  `JS_Panic stop playback and reset region launcher state.lua`

## Installation in REAPER

1. `Actions -> Show action list`
2. `ReaScript -> Load`
3. Gewuenschtes Script aus diesem Ordner laden
4. Script in der Action List markieren
5. `Add...` klicken
6. Gewuenschte Taste druecken

## Voraussetzungen

- `js_ReaScriptAPI` muss installiert sein
- Der `Region/Marker Manager` muss offen sein fuer die Region-Manager-Scripts
- Fuer das HTML-Analyse-Script muss die Python-ReaScript-Unterstuetzung in REAPER aktiv sein

## FOA-Analyse

Das Script `JS_Generate FOA B-Format HTML analysis.py` unterstuetzt:

- `ambiX` mit Kanalreihenfolge `W, Y, Z, X`
- `FuMa` mit Kanalreihenfolge `W, X, Y, Z`

Workflow:

1. Optional ein 4-Kanal-FOA-Item in REAPER selektieren
2. Script starten
3. Quelle waehlen: `selected` oder `file`
4. Format `ambiX` oder `fuma` angeben
5. Frame-Groesse in Millisekunden setzen, z. B. `50`

Die HTML-Datei wird standardmaessig neben der Quelldatei als `*_FOA_Analysis.html` geschrieben.

Falls `.py` in REAPER ausgegraut bleibt, nutze stattdessen direkt:

- `JS_Generate FOA B-Format HTML analysis.lua`

Diese Version braucht keine Python-Konfiguration in REAPER.

## Live-Praxis

- Region im `Region/Marker Manager` markieren
- mit `Return` starten
- mit `Cmd/Ctrl+Return` zur naechsten Region springen
- mit `Alt+Return` zur vorigen Region springen
- mit `Escape` sofort stoppen, falls du live abbrechen musst

## Empfehlung fuer klickfreies Live-Setup

- Live-FX nicht per Region hart umschalten
- keine Presetwechsel im laufenden Live-Signal
- statt dessen `Dry`, `FX A`, `FX B` parallel laufen lassen
- nur Bus-Fader oder Send-Level mit kurzen Crossfades automatisieren

So bleibt dein Live-Pfad stabiler und die Regions steuern nur den Ablauf.

## GitHub Workflow

Das Repo enthaelt einen GitHub-Actions-Workflow unter `.github/workflows/reaper-ci.yml`.
Er prueft bei Pushes und Pull Requests:

- Lua-Syntax aller `.lua`-Scripts
- Lua-Linting mit `luacheck`
- Python-Syntax der Hilfsscripts
- einfache Repo-Regeln fuer ReaScripts, `jsfx` und `README.md`


