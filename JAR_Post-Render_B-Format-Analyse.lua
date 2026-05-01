-- JAR Post-Render B-Format-Analyse
-- ====================================
-- ReaScript (Lua) fuer REAPER — ruft analyze_bformat.py nach dem Rendern auf
-- oder analysiert direkt das aktuell selektierte B-Format-/HOA-Item.
--
-- Erzeugt automatisch: .analysis.json, .analysis.md, .analysis.svg
-- Optional mit --compare: Vergleichs-SVG + Einzel-SVGs pro Dekodierung
--
-- Zwei Aufrufmodi:
--   1. Item-Modus: Ein Audio-Item mit B-Format-/HOA-Datei (4-64 Kanaele) selektieren
--   2. Post-Render-Modus: Im Render-Dialog als "Post-render action" eintragen
--
-- Voraussetzung: Python 3 mit numpy, scipy, soundfile, matplotlib
-- Installation:  pip3 install numpy scipy soundfile matplotlib
--
-- Konfiguration: VAULT_ROOT unten anpassen falls noetig.

local script_name = "JAR Post-Render B-Format-Analyse"
local VAULT_ROOT = "/Users/jschuet1/Library/Application\ Support/REAPER/Scripts"
local ANALYZE_SCRIPT = VAULT_ROOT .. "//Users/jschuet1/Library/Application\ Support/REAPER/Scripts"
local MAX_BFORMAT_CHANNELS = 64

local function shell_quote(value)
  value = tostring(value or "")
  value = value:gsub('"', '\\"')
  return '"' .. value .. '"'
end

local function get_dirname(path)
  return path and path:match("(.+)[/\\]") or nil
end

local function get_basename(path)
  return path and (path:match("[/\\]([^/\\]+)$") or path) or ""
end

local function file_exists(path)
  local handle = io.open(path, "r")
  if handle then
    handle:close()
    return true
  end
  return false
end

-- ─── Selektiertes Item als B-Format-/HOA-Quelle prüfen ───────────────────────

local function get_selected_bformat_item()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    return nil
  end

  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    return nil
  end

  local source = reaper.GetMediaItemTake_Source(take)
  if not source then
    return nil
  end

  local source_file = reaper.GetMediaSourceFileName(source, "")
  if not source_file or source_file == "" then
    return nil
  end

  local channels = reaper.GetMediaSourceNumChannels(source) or 0
  if channels < MIN_BFORMAT_CHANNELS or channels > MAX_BFORMAT_CHANNELS then
    return nil
  end

  return {
    item = item,
    take = take,
    file = source_file,
    file_name = get_basename(source_file),
    render_dir = get_dirname(source_file),
    channels = channels,
    source_mode = "item",
  }
end

-- ─── Render-Verzeichnis + Datei ermitteln ────────────────────────────────────

local function get_render_info()
  local retval, render_file = reaper.GetSetProjectInfo_String(0, "RENDER_FILE", "", false)
  local render_dir = nil
  local render_pattern = nil

  if retval and render_file ~= "" then
    render_dir = render_file:match("(.+)[/\\]")
    render_pattern = render_file:match("[/\\]([^/\\]+)$")
  end

  if not render_dir then
    render_dir = reaper.GetProjectPath("")
  end

  local ret2, pattern = reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "", false)
  if ret2 and pattern ~= "" then
    render_pattern = pattern
  end

  return render_dir, render_pattern
end

-- ─── B-Format-Datei im Render-Verzeichnis finden ─────────────────────────────

local function find_bformat_file(render_dir)
  local candidates = {}
  local patterns = {
    "A00.*%.wav$",
    ".*B%-Format.*%.wav$",
    ".*64ch.*%.wav$",
    ".*HOA.*%.wav$",
    ".*ambi[xX].*%.wav$",
  }

  local pipe = io.popen('ls -t "' .. render_dir .. '"/*.wav 2>/dev/null')
  if pipe then
    for line in pipe:lines() do
      local filename = get_basename(line)
      for _, pat in ipairs(patterns) do
        if filename:match(pat) then
          table.insert(candidates, line)
          break
        end
      end
    end
    pipe:close()
  end

  if #candidates == 0 then
    local pipe2 = io.popen('ls -t "' .. render_dir .. '"/*.wav 2>/dev/null | head -1')
    if pipe2 then
      local newest = pipe2:read("*l")
      pipe2:close()
      if newest and newest ~= "" then
        table.insert(candidates, newest)
      end
    end
  end

  return candidates
end

-- ─── Prüfe ob Dekodierungen vorhanden sind ───────────────────────────────────

local function has_decodings(render_dir)
  local pipe = io.popen('ls "' .. render_dir .. '"/A[1-6]*.wav 2>/dev/null | wc -l')
  if pipe then
    local count = tonumber(pipe:read("*a"):match("%d+")) or 0
    pipe:close()
    return count > 0, count
  end
  return false, 0
end

-- ─── Python finden ───────────────────────────────────────────────────────────

local function find_python()
  local candidates = {
    "/opt/homebrew/bin/python3",
    "/usr/local/bin/python3",
    "/usr/bin/python3",
    "python3"
  }

  for _, py in ipairs(candidates) do
    local handle = io.popen(py .. " --version 2>&1")
    if handle then
      local result = handle:read("*a")
      handle:close()
      if result and result:match("Python 3") then
        return py
      end
    end
  end

  return nil
end

-- ─── Abhängigkeiten prüfen ───────────────────────────────────────────────────

local function check_dependencies(python)
  local modules = {"numpy", "scipy", "soundfile", "matplotlib"}
  local missing = {}

  for _, mod in ipairs(modules) do
    local handle = io.popen(python .. ' -c "import ' .. mod .. '" 2>&1')
    if handle then
      local result = handle:read("*a")
      handle:close()
      if result and result:match("ModuleNotFoundError") then
        table.insert(missing, mod)
      end
    end
  end

  return missing
end

-- ─── Analysequelle wählen ────────────────────────────────────────────────────

local function resolve_analysis_source()
  local selected = get_selected_bformat_item()
  if selected then
    return selected
  end

  local render_dir = get_render_info()
  if not render_dir then
    return nil, "Weder selektiertes B-Format-Item noch Render-Verzeichnis gefunden."
  end

  local bformat_files = find_bformat_file(render_dir)
  if #bformat_files == 0 then
    return nil, "Keine B-Format WAV-Datei gefunden."
  end

  local file_path = bformat_files[1]
  return {
    file = file_path,
    file_name = get_basename(file_path),
    render_dir = render_dir,
    channels = nil,
    source_mode = "render",
  }
end

-- ─── Hauptlogik ──────────────────────────────────────────────────────────────

local function run_analysis()
  local python = find_python()
  if not python then
    reaper.ShowMessageBox(
      "Python 3 nicht gefunden.\n\n" ..
      "Installiere Python 3 und die Pakete:\n" ..
      "  pip3 install numpy scipy soundfile matplotlib",
      script_name .. " - Fehler", 0
    )
    return false
  end

  if not file_exists(ANALYZE_SCRIPT) then
    reaper.ShowMessageBox(
      "analyze_bformat.py nicht gefunden:\n" .. ANALYZE_SCRIPT .. "\n\n" ..
      "Stelle sicher, dass das Script im Vault liegt.",
      script_name .. " - Fehler", 0
    )
    return false
  end

  local missing = check_dependencies(python)
  if #missing > 0 then
    reaper.ShowMessageBox(
      "Fehlende Python-Pakete:\n  " .. table.concat(missing, ", ") .. "\n\n" ..
      "Installieren:\n  pip3 install " .. table.concat(missing, " "),
      script_name .. " - Fehler", 0
    )
    return false
  end

  local source, source_error = resolve_analysis_source()
  if not source then
    reaper.ShowMessageBox(
      (source_error or "Keine Analysequelle gefunden.") .. "\n\n" ..
      "Selektiere ein Audio-Item mit 4-64 Kanaelen oder rendere zuerst eine Datei.",
      script_name .. " - Fehler", 0
    )
    return false
  end

  local render_dir = source.render_dir
  local bformat_file = source.file
  local bformat_name = source.file_name

  if not render_dir or render_dir == "" then
    reaper.ShowMessageBox(
      "Verzeichnis der B-Format-Datei konnte nicht ermittelt werden:\n" .. tostring(bformat_file),
      script_name .. " - Fehler", 0
    )
    return false
  end

  local has_dec, dec_count = has_decodings(render_dir)
  local compare_flag = has_dec and " --compare" or ""
  local channel_info = source.channels and tostring(source.channels) or "unbekannt"
  local source_label = source.source_mode == "item" and "Selektiertes Item" or "Letzter Render"

  reaper.ShowConsoleMsg("\n" .. string.rep("=", 60) .. "\n")
  reaper.ShowConsoleMsg(script_name .. "\n")
  reaper.ShowConsoleMsg(string.rep("=", 60) .. "\n")
  reaper.ShowConsoleMsg("  Quelle:        " .. source_label .. "\n")
  reaper.ShowConsoleMsg("  Verzeichnis:   " .. render_dir .. "\n")
  reaper.ShowConsoleMsg("  B-Format:      " .. bformat_name .. "\n")
  reaper.ShowConsoleMsg("  Kanaele:       " .. channel_info .. "\n")
  reaper.ShowConsoleMsg("  Dekodierungen: " .. tostring(dec_count) .. " gefunden\n")
  reaper.ShowConsoleMsg("  Python:        " .. python .. "\n")
  reaper.ShowConsoleMsg("  Flags:         " .. (compare_flag ~= "" and "--compare" or "(keine)") .. "\n")
  reaper.ShowConsoleMsg(string.rep("-", 60) .. "\n")

  local cmd = string.format(
    "%s %s %s%s 2>&1",
    shell_quote(python),
    shell_quote(ANALYZE_SCRIPT),
    shell_quote(bformat_file),
    compare_flag
  )

  local handle = io.popen(cmd)
  if not handle then
    reaper.ShowMessageBox(
      "Python-Prozess konnte nicht gestartet werden.",
      script_name .. " - Fehler", 0
    )
    return false
  end

  local output = handle:read("*a")
  local success, _, exit_code = handle:close()
  reaper.ShowConsoleMsg((output or "") .. "\n")

  if success then
    reaper.ShowConsoleMsg("\n" .. string.rep("=", 60) .. "\n")
    reaper.ShowConsoleMsg("Analyse abgeschlossen.\n")
    reaper.ShowConsoleMsg(string.rep("=", 60) .. "\n\n")

    local msg = "B-Format-Analyse abgeschlossen:\n\n"
    msg = msg .. "Quelle: " .. source_label .. "\n"
    msg = msg .. "Datei: " .. bformat_name .. "\n"
    if source.channels then
      msg = msg .. "Kanaele: " .. tostring(source.channels) .. "\n"
    end
    msg = msg .. "\nErzeugte Dateien:\n"
    msg = msg .. "  - .analysis.json (Metriken)\n"
    msg = msg .. "  - .analysis.md (Markdown-Report)\n"
    msg = msg .. "  - .analysis.svg (Diagramme)\n"

    if has_dec then
      msg = msg .. "  - _SetA_Vergleich.svg (Vergleich)\n"
      msg = msg .. "  - " .. tostring(dec_count) .. " x Dekodierungs-SVGs\n"
    end

    msg = msg .. "\nVerzeichnis: " .. render_dir
    reaper.ShowMessageBox(msg, script_name .. " - Fertig", 0)
    return true
  end

  reaper.ShowConsoleMsg("\nAnalyse fehlgeschlagen (Exit: " .. tostring(exit_code) .. ")\n")
  reaper.ShowMessageBox(
    "Analyse fehlgeschlagen.\n\n" ..
    "Exit Code: " .. tostring(exit_code) .. "\n\n" ..
    "Details: REAPER Console (Cmd+Alt+M)",
    script_name .. " - Fehler", 0
  )
  return false
end

-- ─── Aufruf ──────────────────────────────────────────────────────────────────

run_analysis()