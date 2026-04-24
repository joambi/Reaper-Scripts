# MCP-Server für REAPER – Architektur-Plan

Stand: 2026-04-19
Scope der v1: **Bestehende `.lua` / `.py` Skripte aus diesem Projektordner per MCP-Tool in REAPER ausführen**
Stack: **Lua direkt in REAPER** (REAPER-seitig), Kommunikationsbrücke siehe unten

---

## 1. Grundproblem und empfohlene Brücke

### Die Reibung

MCP (Model Context Protocol) spricht per Definition **JSON-RPC 2.0 über stdio oder HTTP/SSE**. Das Protokoll erwartet einen langlebigen Prozess, der auf stdin lauscht.

REAPERs Lua-Umgebung ist aber:

- single-threaded (alle Scripte laufen im Main-Thread via `reaper.defer`)
- ohne bundled `luasocket` / `luasec`
- ohne direkten stdio-Zugriff (REAPER startet Scripts, nicht umgekehrt)

Ein **reiner** Lua-MCP-Server *innerhalb* REAPERs ist damit praktisch nicht umsetzbar, ohne native Sockets nachzuinstallieren und mit defer-Loops zu tricksen.

### Empfehlung: Hybrid mit REAPERs eingebautem Web-Interface

```
┌─────────────────┐    stdio JSON-RPC    ┌───────────────────┐   HTTP    ┌──────────────────┐
│  MCP-Client     │ ───────────────────► │  MCP-Shim (Lua)   │ ────────► │  REAPER Web API  │
│  (Claude etc.)  │ ◄─────────────────── │  standalone lua5.4│ ◄──────── │  (built-in)      │
└─────────────────┘                      └───────────────────┘           └────────┬─────────┘
                                                                                   │
                                                                                   ▼
                                                                         ┌─────────────────┐
                                                                         │ ReaScript-Runner│
                                                                         │  (Lua in REAPER)│
                                                                         └─────────────────┘
```

Warum diese Variante?

- **REAPERs Web-Interface ist bereits da.** `Preferences → Control/OSC/Web → Web browser interface` freischalten, Port z. B. `8080`. Damit entfällt jegliche Socket-Handling-Komplexität innerhalb REAPERs.
- **"Lua direkt in REAPER" bleibt das Kernstück.** Die gesamte Business-Logik (Script-Ausführung, Rückgabewerte, Fehlermeldungen, State) lebt als ReaScript im Projektordner.
- **Der MCP-Shim ist dünn.** Rund 150–250 Zeilen Lua, reines JSON-RPC-Mapping → HTTP-Call. Er kennt keine Domain-Logik und ist ein nahezu reines Transport-Gateway. Lauffähig mit `lua5.4` + `luasocket` oder `lua-http` als Standalone-Prozess.
- **Rückkanal ist lösbar.** REAPERs `/_/ACTIONID` gibt zwar nur ACK zurück, aber der Runner schreibt strukturierte Ergebnisse in eine temporäre Datei, die der Shim anschließend liest.

### Alternativen, die ich geprüft und verworfen habe

| Variante | Warum nicht v1 |
|---|---|
| OSC | Gut für Transport/Parameter, aber ungeeignet für „starte Script X und gib mir stdout zurück". |
| Pure-Lua-MCP-Server in REAPER via `defer` + `luasocket` | Fragil, erzwingt externe Abhängigkeiten, bricht wenn REAPER pausiert. |
| Externer Python-/Node-MCP-Server | Funktioniert, widerspricht aber der Vorgabe „Lua direkt in REAPER". |
| Nur Dateibasiertes IPC (Watch-Folder) | Zu hohe Latenz, keine saubere Fehlerpropagation. |

---

## 2. Komponenten

### 2.1 REAPER-seitig: `reascript_runner.lua`

Eine einzige, in REAPER installierte Action, die der MCP-Shim über das Web-Interface triggert. Zuständigkeiten:

- Payload-Parsing (liest Script-Name + Argumente aus `ExtState` oder einer Trigger-Datei)
- Safe-Execution: `pcall` um das Ziel-Script, sammelt Return-Wert und Fehler-Trace
- Ergebnis-Schreiben nach `<tempdir>/mcp_result_<id>.json` (atomar via `tmp → rename`)
- Logging nach `<tempdir>/mcp_runner.log`
- Registriert sich per `reaper.AddRemoveReaScript` automatisch beim ersten Start

### 2.2 MCP-Shim: `mcp_shim.lua`

Standalone-Lua-Prozess (nicht in REAPER), wird vom MCP-Client per stdio gestartet. Implementiert:

- MCP-Handshake (`initialize`, `initialized`)
- Tool-Listing (`tools/list`)
- Tool-Aufruf (`tools/call`) → REAPER-Web-API-POST → Poll auf `mcp_result_<id>.json` → JSON-RPC-Response
- Sauberes Error-Mapping (REAPER nicht erreichbar, Script nicht gefunden, Runtime-Fehler im Script)

### 2.3 Skript-Registry: `mcp_tools.json`

Deklarative Liste aller Skripte, die per MCP exponiert werden. Beispiel-Schema:

```json
{
  "tools": [
    {
      "name": "play_selected_region",
      "description": "Startet die im Region Manager ausgewählte Region und stoppt am Regionsende.",
      "script": "JS_Play selected region in Region Manager and stop at region end.lua",
      "parameters": {}
    },
    {
      "name": "generate_foa_analysis",
      "description": "Erzeugt HTML-Analyse für ein selektiertes FOA-Item oder eine Datei.",
      "script": "JS_Generate FOA B-Format HTML analysis.lua",
      "parameters": {
        "source":     { "type": "string", "enum": ["selected", "file"], "required": true },
        "format":     { "type": "string", "enum": ["ambiX", "fuma"],    "required": true },
        "frame_ms":   { "type": "integer", "default": 50 },
        "file_path":  { "type": "string", "required": false }
      }
    }
  ]
}
```

Vorteil: Neue Skripte aufnehmen = Eintrag in JSON. Kein Lua-Code anfassen.

---

## 3. Ausführungsfluss (Sequence)

```
Claude                MCP-Shim (lua)        REAPER Web API         ReaScript-Runner
  │  tools/call          │                       │                       │
  ├─────────────────────►│                       │                       │
  │                      │  POST /_/MCP_RUN      │                       │
  │                      │  ?id=42&tool=foo      │                       │
  │                      ├──────────────────────►│                       │
  │                      │                       │  invokes action       │
  │                      │                       ├──────────────────────►│
  │                      │                       │                       │ pcall(script)
  │                      │                       │                       │ write result.json
  │                      │                       │  200 OK (ACK)         │
  │                      │◄──────────────────────┤                       │
  │                      │  poll mcp_result_42.json (100 ms, max 30 s)   │
  │                      ├──────────────────────────────────────────────►│
  │                      │◄──────────────────────────────────────────────┤
  │  JSON-RPC result     │                       │                       │
  │◄─────────────────────┤                       │                       │
```

Timeout-Strategie: Default 30 s, per Tool überschreibbar (`timeout_ms` in `mcp_tools.json`). Bei Timeout schreibt der Shim einen JSON-RPC-Error und räumt die Result-Datei weg.

---

## 4. MCP-Tool-Spezifikation für v1

Alle v1-Tools bedienen den Use Case **Script-Execution**:

| Tool | Beschreibung |
|---|---|
| `list_scripts` | Gibt alle in `mcp_tools.json` registrierten Skripte zurück |
| `run_script` | Führt ein Script namentlich aus, mit optionalen Argumenten |
| `get_last_result` | Holt das Ergebnis des zuletzt getriggerten Runs (nützlich beim Debuggen) |
| `reaper_status` | Pingt REAPER, gibt Version und Projektname zurück |

Jedes Skript aus `mcp_tools.json` wird zusätzlich **als eigenes Tool** exponiert (z. B. `play_selected_region`). So bleibt die Oberfläche für den MCP-Client sprechend.

---

## 5. Projektlayout (geplant)

```
Reaper_Scripts_JS/
├── mcp/
│   ├── reascript_runner.lua       ← läuft in REAPER
│   ├── mcp_shim.lua               ← standalone, stdio-MCP-Server
│   ├── mcp_tools.json             ← Tool-Registry (deklarativ)
│   ├── lib/
│   │   ├── json.lua               ← dkjson oder rxi/json.lua
│   │   └── http_client.lua        ← luasocket-Wrapper
│   ├── install.lua                ← One-Shot: Runner als REAPER-Action registrieren
│   └── README.md                  ← Setup-Anleitung (Web-IF aktivieren, MCP-Client konfigurieren)
├── JS_*.lua                       ← bestehende Skripte (unverändert)
├── JS_*.py
└── README.md                      ← bleibt wie ist
```

**Bewusste Entscheidung:** Kein Unterordner für deine bestehenden Skripte. Der MCP-Server soll **zusätzlich** funktionieren, nicht invasiv. Deine Tastenbelegungen und Live-Workflows bleiben unberührt.

---

## 6. Setup (was du einmalig tun musst)

1. REAPER: `Preferences → Control/OSC/Web → Web browser interface` aktivieren
   - Port z. B. `8080`, lokal binden, optional Passwort setzen
2. `lua5.4` + `luasocket` + `dkjson` auf der Kommandozeile installierbar haben
   - macOS: `brew install lua luarocks && luarocks install luasocket dkjson`
3. `install.lua` einmal in REAPER laden → registriert den Runner als Action
4. MCP-Client (Claude, Cursor, etc.) auf `lua5.4 /pfad/zu/mcp_shim.lua` konfigurieren
5. Fertig. `list_scripts` aufrufen als Smoke-Test.

---

## 7. Offene Fragen / bewusste Trade-offs

- **Web-Interface-Security:** REAPERs Web-IF bindet per Default nur localhost. Für Remote-Szenarien (z. B. Studio-PC + Laptop) braucht es später einen Reverse-Proxy mit Auth. **Out of Scope v1.**
- **Parallel-Ausführung:** Nur ein Script gleichzeitig. REAPER ist single-threaded. Runner serialisiert Requests per `ExtState`-Lock.
- **Python-Skripte (`.py`):** Funktionieren, wenn REAPER Python aktiviert ist. Der Runner unterscheidet anhand der Endung und ruft den richtigen Interpreter-Pfad auf. Voraussetzung siehe bestehende README.
- **Return-Werte aus REAPER:** Beschränkt auf das, was das Skript selbst in die Result-Datei schreibt. Für v1 genügt `status`, `stdout`, `error`. Strukturierte Rückgaben (z. B. Track-Liste als JSON) sind v2.
- **js_ReaScriptAPI:** Muss installiert sein (gilt eh für deine bestehenden Skripte).

---

## 8. Nächste Schritte

Wenn du mit diesem Plan einverstanden bist, sind die konkreten nächsten Commits:

1. Ordnerstruktur `mcp/` anlegen
2. `reascript_runner.lua` + `install.lua` (REAPER-Seite)
3. `mcp_shim.lua` + `lib/` (Host-Seite)
4. `mcp_tools.json` mit zwei Start-Einträgen (`play_selected_region`, `panic_stop`) als Smoke-Test
5. `mcp/README.md` mit Setup-Anleitung auf Deutsch
6. End-to-End-Test: MCP-Client → `run_script` → REAPER stoppt tatsächlich Playback

**Offene Entscheidung für dich vor Code:**

- Soll ich beim Scaffold direkt **alle** aktuellen Skripte aus dem Ordner in `mcp_tools.json` aufnehmen, oder nur ein kleines Smoke-Test-Set?
- Port des Web-Interface: fest `8080` oder konfigurierbar per Env-Variable / `mcp_tools.json`?
- Ergebnis-Verzeichnis: REAPER-`GetResourcePath()/mcp/` oder Systemtemp? Ersteres überlebt Reboots, Letzteres ist sauberer.
