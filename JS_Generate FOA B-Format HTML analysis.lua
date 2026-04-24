-- @description Generate FOA B-Format HTML analysis
-- @version 1.0
-- @author Codex
-- @about
--   Analysiert eine FOA/B-Format-Datei (4 Kanaele) aus einem selektierten Media Item
--   oder ueber Dateiauswahl und erzeugt ein HTML-Dashboard mit Plotly:
--   Intensitaetsvektor X/Y/Z, Azimut, Elevation, Fokus, Pegel und Kanal-RMS.
--   Unterstuetzt ambiX (ACN/SN3D: W,Y,Z,X) und FuMa (W,X,Y,Z).

local DEFAULT_FRAME_MS = 50.0
local EPSILON = 1.0e-12

local function show_error(message)
  reaper.ShowMessageBox(tostring(message), "FOA HTML Analysis", 0)
end

local function show_info(message)
  reaper.ShowMessageBox(tostring(message), "FOA HTML Analysis", 0)
end

local function clamp(value, minimum, maximum)
  if value < minimum then return minimum end
  if value > maximum then return maximum end
  return value
end

local function dbfs(value)
  if value <= EPSILON then
    return -120.0
  end
  return 20.0 * math.log(value, 10)
end

local function sanitize_path(path)
  return (path or ""):gsub("\\", "/")
end

local function shell_quote(value)
  value = tostring(value or "")
  value = value:gsub("'", "'\\''")
  return "'" .. value .. "'"
end

local function basename(path)
  return (path or ""):match("([^/\\]+)$") or path or ""
end

local function split_inputs(csv)
  local a, b, c, d = csv:match("^([^,]*),([^,]*),([^,]*),(.*)$")
  if not a then
    return "", "", "", ""
  end
  return a, b, c, d
end

local function js_string(value)
  value = tostring(value or "")
  value = value:gsub("\\", "\\\\")
  value = value:gsub('"', '\\"')
  value = value:gsub("\r", "\\r")
  value = value:gsub("\n", "\\n")
  return '"' .. value .. '"'
end

local function js_number(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    return "0"
  end
  return string.format("%.10g", value)
end

local function js_array(values)
  local parts = {}
  for i = 1, #values do
    parts[i] = js_number(values[i])
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local function get_take_file_path(take)
  local source = reaper.GetMediaItemTake_Source(take)
  if not source then
    return ""
  end
  return reaper.GetMediaSourceFileName(source, "")
end

local function get_selected_take_context()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    return nil
  end

  local take = reaper.GetActiveTake(item)
  if not take then
    return nil
  end

  local source = reaper.GetMediaItemTake_Source(take)
  if not source then
    return nil
  end

  local length = reaper.GetMediaSourceLength(source)
  local sample_rate = reaper.GetMediaSourceSampleRate(source)
  local channels = reaper.GetMediaSourceNumChannels(source)

  return {
    mode = "take",
    item = item,
    take = take,
    source = source,
    source_path = get_take_file_path(take),
    length = length,
    sample_rate = sample_rate,
    channels = channels,
    accessor = nil,
    temp_track = nil,
  }
end

local function build_temp_take_context(file_path)
  local source = reaper.PCM_Source_CreateFromFile(file_path)
  if not source then
    return nil
  end

  local length = reaper.GetMediaSourceLength(source)
  local sample_rate = reaper.GetMediaSourceSampleRate(source)
  local channels = reaper.GetMediaSourceNumChannels(source)

  local track_index = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(track_index, false)
  local track = reaper.GetTrack(0, track_index)
  local item = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(item)

  reaper.SetMediaItemTake_Source(take, source)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0.0)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 0.0)
  reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0.0)
  reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0.0)
  reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", 0.0)

  return {
    mode = "file",
    item = item,
    take = take,
    source = source,
    source_path = file_path,
    length = length,
    sample_rate = sample_rate,
    channels = channels,
    accessor = nil,
    temp_track = track,
  }
end

local function cleanup_context(context)
  if not context then
    return
  end

  if context.accessor then
    reaper.DestroyAudioAccessor(context.accessor)
  end

  if context.temp_track then
    reaper.DeleteTrack(context.temp_track)
    reaper.UpdateArrange()
  end
end

local function parse_channel_list(text)
  local result = {}
  for token in tostring(text or ""):gmatch("[^%s;]+") do
    for number in token:gmatch("%d+") do
      result[#result + 1] = tonumber(number)
      if #result == 4 then
        return result
      end
    end
  end
  return result
end

local function normalize_browser_mode(text)
  local value = (text or ""):lower():match("^%s*(.-)%s*$")
  if value == "" then
    return "firefox"
  end
  if value == "firefox" or value == "ff" then
    return "firefox"
  end
  if value == "default" or value == "browser" or value == "system" then
    return "default"
  end
  if value == "none" or value == "save" or value == "off" then
    return "none"
  end
  return nil
end

local function prompt_for_source()
  local selected = get_selected_take_context()
  local default_path = selected and selected.source_path or ""
  local defaults = "selected,ambix,50,1 2 3 4,firefox," .. default_path
  local ok, csv = reaper.GetUserInputs(
    "FOA HTML Analysis",
    6,
    "Source (selected|file),Format (ambix|fuma),Frame ms,Source channels W X Y Z,Open (firefox|default|none),File path if needed",
    defaults
  )
  if not ok then
    return nil
  end

  local raw_source_mode, raw_format, raw_frame_ms, raw_channels, raw_browser, raw_path = csv:match("^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),(.*)$")
  if not raw_source_mode then
    show_error("Eingaben konnten nicht gelesen werden.")
    return nil
  end
  local source_mode = (raw_source_mode or ""):lower():match("^%s*(.-)%s*$")
  local channel_format = (raw_format or ""):lower():match("^%s*(.-)%s*$")
  local frame_ms = tonumber(raw_frame_ms) or DEFAULT_FRAME_MS
  local source_channels = parse_channel_list(raw_channels)
  local browser_mode = normalize_browser_mode(raw_browser)
  raw_path = (raw_path or ""):match("^%s*(.-)%s*$")

  if source_mode == "" then source_mode = "selected" end
  if channel_format == "" then channel_format = "ambix" end
  if channel_format ~= "ambix" and channel_format ~= "fuma" then
    show_error("Format muss 'ambix' oder 'fuma' sein.")
    return nil
  end

  if not browser_mode then
    show_error("Open muss 'firefox', 'default' oder 'none' sein.")
    return nil
  end

  if #source_channels ~= 4 then
    show_error("Bitte genau vier Quellkanaele fuer W X Y Z angeben, z. B. '1 2 3 4'.")
    return nil
  end

  frame_ms = clamp(frame_ms, 5.0, 1000.0)

  if source_mode:find("^sel") then
    if selected then
      selected.source_channels = source_channels
      selected.browser_mode = browser_mode
      return selected, channel_format, frame_ms
    end
    if raw_path == "" then
      local chosen, file_path = reaper.GetUserFileNameForRead("", "FOA/B-Format file", "")
      if not chosen then
        return nil
      end
      raw_path = file_path
    end
  elseif raw_path == "" then
    local chosen, file_path = reaper.GetUserFileNameForRead("", "FOA/B-Format file", "")
    if not chosen then
      return nil
    end
    raw_path = file_path
  end

  if raw_path == "" then
    show_error("Keine Datei angegeben.")
    return nil
  end

  local context = build_temp_take_context(raw_path)
  if not context then
    show_error("Datei konnte nicht geoeffnet werden.")
    return nil
  end

  context.source_channels = source_channels
  context.browser_mode = browser_mode
  return context, channel_format, frame_ms
end

local function get_channel_indices(channel_format)
  if channel_format == "fuma" then
    return { w = 1, x = 2, y = 3, z = 4 }
  end
  return { w = 1, y = 2, z = 3, x = 4 }
end

local function analyze_foa(context, channel_format, frame_ms)
  if context.channels < 4 then
    error("Die Quelle hat weniger als 4 Kanaele und ist kein FOA/B-Format.")
  end

  if context.sample_rate <= 0 then
    error("Sample-Rate konnte nicht gelesen werden.")
  end

  local source_channels = context.source_channels or { 1, 2, 3, 4 }
  for i = 1, 4 do
    if not source_channels[i] or source_channels[i] < 1 or source_channels[i] > context.channels then
      error(
        "Ungueltige Kanalbelegung fuer W/X/Y/Z. Datei hat "
          .. tostring(context.channels)
          .. " Kanaele, angegeben wurde Kanal "
          .. tostring(source_channels[i])
          .. "."
      )
    end
  end

  local accessor = reaper.CreateTakeAudioAccessor(context.take)
  context.accessor = accessor
  if not accessor then
    error("Audio Accessor konnte nicht erstellt werden.")
  end

  local sample_rate = context.sample_rate
  local source_length = math.max(0.0, context.length)
  local samples_per_frame = math.max(1, math.floor(sample_rate * (frame_ms / 1000.0) + 0.5))
  local frame_duration = samples_per_frame / sample_rate
  local start_time = math.max(0.0, reaper.GetAudioAccessorStartTime(accessor))
  local end_time = math.min(reaper.GetAudioAccessorEndTime(accessor), source_length)
  local mapping = get_channel_indices(channel_format)
  local buffer = reaper.new_array(samples_per_frame * context.channels)

  local time_values = {}
  local intensity_x = {}
  local intensity_y = {}
  local intensity_z = {}
  local azimuth = {}
  local elevation = {}
  local focus = {}
  local rms_w_db = {}
  local rms_total_db = {}
  local ch_sums = { 0.0, 0.0, 0.0, 0.0 }
  local total_samples = 0
  local time_position = start_time

  while time_position < end_time - 1.0e-9 do
    local remaining = end_time - time_position
    local current_duration = math.min(frame_duration, remaining)
    local current_samples = math.max(1, math.floor(current_duration * sample_rate + 0.5))
    buffer.clear()
    if current_samples ~= samples_per_frame then
      buffer.resize(current_samples * context.channels)
    end

    local result = reaper.GetAudioAccessorSamples(
      accessor,
      sample_rate,
      context.channels,
      time_position,
      current_samples,
      buffer
    )

    if result <= 0 then
      break
    end

    local sum_w2, sum_x2, sum_y2, sum_z2 = 0.0, 0.0, 0.0, 0.0
    local sum_ix, sum_iy, sum_iz = 0.0, 0.0, 0.0

    for sample_index = 0, current_samples - 1 do
      local base = sample_index * context.channels
      local w = buffer[base + source_channels[mapping.w]]
      local x = buffer[base + source_channels[mapping.x]]
      local y = buffer[base + source_channels[mapping.y]]
      local z = buffer[base + source_channels[mapping.z]]

      sum_w2 = sum_w2 + w * w
      sum_x2 = sum_x2 + x * x
      sum_y2 = sum_y2 + y * y
      sum_z2 = sum_z2 + z * z
      sum_ix = sum_ix + w * x
      sum_iy = sum_iy + w * y
      sum_iz = sum_iz + w * z

      ch_sums[1] = ch_sums[1] + w * w
      ch_sums[2] = ch_sums[2] + x * x
      ch_sums[3] = ch_sums[3] + y * y
      ch_sums[4] = ch_sums[4] + z * z
    end

    total_samples = total_samples + current_samples

    local inv_n = 1.0 / current_samples
    local ix = sum_ix * inv_n
    local iy = sum_iy * inv_n
    local iz = sum_iz * inv_n
    local energy = (sum_w2 + sum_x2 + sum_y2 + sum_z2) * inv_n
    local vector_mag = math.sqrt(ix * ix + iy * iy + iz * iz)
    local focus_value = clamp(vector_mag / (energy + EPSILON), 0.0, 1.0)
    local az = 0.0
    local el = 0.0

    if vector_mag > EPSILON then
      az = math.deg(math.atan(iy, ix))
      el = math.deg(math.atan(iz, math.sqrt(ix * ix + iy * iy)))
    end

    time_values[#time_values + 1] = time_position
    intensity_x[#intensity_x + 1] = ix
    intensity_y[#intensity_y + 1] = iy
    intensity_z[#intensity_z + 1] = iz
    azimuth[#azimuth + 1] = az
    elevation[#elevation + 1] = el
    focus[#focus + 1] = focus_value
    rms_w_db[#rms_w_db + 1] = dbfs(math.sqrt(sum_w2 * inv_n))
    rms_total_db[#rms_total_db + 1] = dbfs(math.sqrt(energy / 4.0))

    time_position = time_position + frame_duration
    if current_samples ~= samples_per_frame then
      buffer.resize(samples_per_frame * context.channels)
    end
  end

  if #time_values == 0 then
    error("Es konnten keine Audio-Samples gelesen werden.")
  end

  local ch_rms = {}
  local active_channels = 0
  for i = 1, 4 do
    ch_rms[i] = dbfs(math.sqrt(ch_sums[i] / math.max(1, total_samples)))
    if ch_rms[i] > -90.0 then
      active_channels = active_channels + 1
    end
  end

  return {
    meta = {
      filename = basename(context.source_path),
      source_path = sanitize_path(context.source_path),
      sr = sample_rate,
      channels = context.channels,
      analyzed_channels = 4,
      format = channel_format,
      duration = source_length,
      frames = #time_values,
      frame_ms = frame_ms,
      active_channels = active_channels,
      source_channels = source_channels,
    },
    time = time_values,
    intensity = { x = intensity_x, y = intensity_y, z = intensity_z },
    direction = { azimuth = azimuth, elevation = elevation },
    focus = focus,
    dynamics = { rms_w_db = rms_w_db, rms_total_db = rms_total_db },
    ch_rms = ch_rms,
  }
end

local function build_html(data)
  local m = data.meta

  return [[<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>FOA B-Format Analysis</title>
<script src="https://cdn.plot.ly/plotly-2.27.0.min.js"></script>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    background:
      radial-gradient(circle at top left, rgba(72,88,188,0.18), transparent 32%),
      radial-gradient(circle at top right, rgba(62,158,110,0.12), transparent 28%),
      #08080e;
    color: #e0e0e8;
    min-height: 100vh;
}
.hdr {
    background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
    padding: 28px 36px; border-bottom: 1px solid #2a2a3e;
    position: sticky; top: 0; z-index: 5;
    backdrop-filter: blur(10px);
}
.hdr h1 { font-size: 32px; font-weight: 700; color: #fff; letter-spacing: -0.03em; }
.hdr .sub { font-size: 16px; color: #9ca6d4; margin-top: 6px; }
.tags { display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap; }
.tag { background: #2a2a3e; padding: 6px 12px; border-radius: 999px; font-size: 13px; color: #c5cae7; }
.tag.ok { background: #1a3e2a; color: #66dd88; }
.wrap { padding: 26px; max-width: min(1800px, 96vw); margin: 0 auto; }
.row { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
@media (max-width: 900px) { .row { grid-template-columns: 1fr; } }
.card {
    background: rgba(16,16,26,0.92); border-radius: 14px; border: 1px solid #2a2a3e;
    padding: 18px; margin-bottom: 20px;
    box-shadow: 0 20px 40px rgba(0,0,0,0.18);
}
.card.full { grid-column: 1 / -1; }
.card h2 { font-size: 16px; color: #b3bad7; font-weight: 600; margin-bottom: 12px; }
.card .note { font-size: 12px; color: #6d7498; margin-top: 8px; line-height: 1.5; }
.toolbar {
    display: flex;
    gap: 10px;
    flex-wrap: wrap;
    margin-bottom: 18px;
}
.btn {
    appearance: none;
    border: 1px solid #33365a;
    background: #17192a;
    color: #d6dbff;
    border-radius: 999px;
    padding: 8px 14px;
    font-size: 13px;
    cursor: pointer;
}
.btn:hover { background: #222642; }
body.export .hdr { position: static; }
body.export .wrap { max-width: 1880px; padding: 24px; }
body.export .card { box-shadow: none; }
body.paper {
    background: #eef1f7;
    color: #172033;
}
body.paper .hdr {
    background: linear-gradient(135deg, #f7f9fe 0%, #edf2fb 100%);
    border-bottom: 1px solid #d7dfef;
}
body.paper .hdr h1 { color: #15203a; }
body.paper .hdr .sub { color: #4f6185; }
body.paper .tag { background: #dde5f4; color: #31415f; }
body.paper .tag.ok { background: #d9f2e2; color: #22603a; }
body.paper .card {
    background: rgba(255,255,255,0.96);
    border-color: #d8e0ef;
    box-shadow: 0 18px 36px rgba(78,97,137,0.10);
}
body.paper .card h2 { color: #253558; }
body.paper .card .note { color: #657694; }
body.paper .btn {
    background: #ffffff;
    color: #233150;
    border-color: #cfd8ea;
}
body.paper .btn:hover { background: #f5f8ff; }
body.export .toolbar,
body.screenshot .toolbar { display: none; }
body.screenshot .hdr { position: static; }
body.screenshot .wrap { max-width: 1880px; padding: 18px; }
body.screenshot .card { box-shadow: none; }
@media print {
    body {
        background: #ffffff !important;
        color: #101828 !important;
    }
    .toolbar { display: none !important; }
    .hdr { position: static !important; backdrop-filter: none !important; }
    .wrap { max-width: none !important; width: 100% !important; padding: 12mm !important; }
    .card {
        break-inside: avoid;
        box-shadow: none !important;
        border-color: #d8e0ef !important;
        background: #ffffff !important;
    }
}
</style>
</head>
<body>
<div class="hdr">
    <h1>FOA B-Format Intensitaetsvektor-Analyse</h1>
    <div class="sub" id="subtitle"></div>
    <div class="tags" id="tags"></div>
</div>
<div class="wrap">
    <div class="toolbar">
        <button class="btn" id="toggleExport">Export Layout</button>
        <button class="btn" id="togglePaper">Paper Theme</button>
        <button class="btn" id="toggleScreenshot">Screenshot Mode</button>
        <button class="btn" id="printPage">Print / PDF</button>
        <button class="btn" id="toggleLegend">Legends umschalten</button>
    </div>
    <div class="card full"><h2>Intensitaetsvektor X · Y · Z</h2><div id="p1"></div>
        <p class="note">Frame-basierte FOA-Naeherung aus W/X/Y/Z. X = vorne(+)/hinten(-), Y = links(+)/rechts(-), Z = oben(+)/unten(-).</p></div>

    <div class="row">
        <div class="card"><h2>Azimut (horizontal)</h2><div id="p2a"></div></div>
        <div class="card"><h2>Elevation (vertikal)</h2><div id="p2b"></div></div>
    </div>

    <div class="card full"><h2>Fokus und Pegel</h2><div id="p3"></div>
        <p class="note">Fokus = normierte Staerke des Intensitaetsvektors pro Frame. Hohe Werte deuten auf klar gerichtete Ereignisse, niedrigere Werte auf diffusere Felder.</p></div>

    <div class="row">
        <div class="card"><h2>3D-Trajectory</h2><div id="p4"></div></div>
        <div class="card"><h2>Azimut vs. Elevation</h2><div id="p5"></div></div>
    </div>

    <div class="card full"><h2>Kanal-RMS</h2><div id="p6"></div>
        <p class="note">Gesamt-RMS pro FOA-Kanal ueber die gesamte Datei.</p></div>
    </div>

<script>
const D = {
meta: {
filename: ]] .. js_string(m.filename) .. [[,
source_path: ]] .. js_string(m.source_path) .. [[,
sr: ]] .. js_number(m.sr) .. [[,
channels: ]] .. js_number(m.channels) .. [[,
analyzed_channels: ]] .. js_number(m.analyzed_channels) .. [[,
format: ]] .. js_string(m.format) .. [[,
duration: ]] .. js_number(m.duration) .. [[,
frames: ]] .. js_number(m.frames) .. [[,
frame_ms: ]] .. js_number(m.frame_ms) .. [[,
active_channels: ]] .. js_number(m.active_channels) .. [[,
source_channels: ]] .. js_array(m.source_channels) .. [[
},
time: ]] .. js_array(data.time) .. [[,
intensity: {
x: ]] .. js_array(data.intensity.x) .. [[,
y: ]] .. js_array(data.intensity.y) .. [[,
z: ]] .. js_array(data.intensity.z) .. [[
},
direction: {
azimuth: ]] .. js_array(data.direction.azimuth) .. [[,
elevation: ]] .. js_array(data.direction.elevation) .. [[
},
focus: ]] .. js_array(data.focus) .. [[,
dynamics: {
rms_w_db: ]] .. js_array(data.dynamics.rms_w_db) .. [[,
rms_total_db: ]] .. js_array(data.dynamics.rms_total_db) .. [[
},
ch_rms: ]] .. js_array(data.ch_rms) .. [[
};
const m = D.meta;
document.getElementById('subtitle').textContent = `${m.filename} | ${m.format}`;
document.getElementById('tags').innerHTML =
    `<span class="tag ok">FOA / ${m.analyzed_channels} ch</span>` +
    `<span class="tag">${m.channels}ch Quelle</span>` +
    `<span class="tag">${m.format}</span>` +
    `<span class="tag">WXYZ: ${m.source_channels.join('/')}</span>` +
    `<span class="tag">${m.sr} Hz</span>` +
    `<span class="tag">${m.duration}s</span>` +
    `<span class="tag ok">${m.active_channels} aktive Kanaele</span>` +
    `<span class="tag">${m.frame_ms}ms Frames</span>`;

const L = {
    paper_bgcolor: '#10101a', plot_bgcolor: '#10101a',
    font: { color: '#b0b7d6', size: 13 },
    margin: { l: 64, r: 28, t: 18, b: 54 },
    xaxis: { gridcolor: '#1e1e2e', zerolinecolor: '#2e2e3e' },
    yaxis: { gridcolor: '#1e1e2e', zerolinecolor: '#2e2e3e' },
    legend: { font: { color: '#b0b7d6', size: 12 }, bgcolor: 'rgba(0,0,0,0)', orientation: 'h', y: 1.14 }
};
const C = { responsive: true, displaylogo: false };
const plotIds = ['p1','p2a','p2b','p3','p4','p5','p6'];

Plotly.newPlot('p1', [
    { x: D.time, y: D.intensity.x, name: 'X (vorne/hinten)', line: { color: '#ff5555', width: 1.2 } },
    { x: D.time, y: D.intensity.y, name: 'Y (links/rechts)', line: { color: '#55cc55', width: 1.2 } },
    { x: D.time, y: D.intensity.z, name: 'Z (oben/unten)', line: { color: '#5588ff', width: 1.2 } }
], {
    ...L,
    xaxis: { ...L.xaxis, title: 'Zeit (s)' },
    yaxis: { ...L.yaxis, title: 'Intensitaet' },
    height: 420
}, C);

Plotly.newPlot('p2a', [{
    x: D.time, y: D.direction.azimuth,
    mode: 'markers', marker: { size: 3, color: D.focus, colorscale: 'YlOrRd', cmin: 0, cmax: 1,
        colorbar: { title: 'Fokus', len: 0.8, tickfont: { color: '#99a' }, titlefont: { color: '#99a' } } },
    hovertemplate: '%{x:.2f}s: %{y:.1f} deg<extra></extra>'
}], {
    ...L,
    xaxis: { ...L.xaxis, title: 'Zeit (s)' },
    yaxis: { ...L.yaxis, title: 'Azimut (deg)', range: [-180, 180], dtick: 45 },
    height: 420, showlegend: false
}, C);

Plotly.newPlot('p2b', [{
    x: D.time, y: D.direction.elevation,
    mode: 'markers', marker: { size: 3, color: D.focus, colorscale: 'YlOrRd', cmin: 0, cmax: 1,
        colorbar: { title: 'Fokus', len: 0.8, tickfont: { color: '#99a' }, titlefont: { color: '#99a' } } },
    hovertemplate: '%{x:.2f}s: %{y:.1f} deg<extra></extra>'
}], {
    ...L,
    xaxis: { ...L.xaxis, title: 'Zeit (s)' },
    yaxis: { ...L.yaxis, title: 'Elevation (deg)', range: [-90, 90], dtick: 30 },
    height: 420, showlegend: false
}, C);

Plotly.newPlot('p3', [
    { x: D.time, y: D.focus, name: 'Fokus', fill: 'tozeroy',
      fillcolor: 'rgba(85,136,255,0.12)', line: { color: '#5588ff', width: 1.2 } },
    { x: D.time, y: D.dynamics.rms_w_db, name: 'RMS W (dBFS)', yaxis: 'y2',
      line: { color: '#ff6688', width: 1 } },
    { x: D.time, y: D.dynamics.rms_total_db, name: 'RMS Total (dBFS)', yaxis: 'y2',
      line: { color: '#ffaa44', width: 1, dash: 'dot' } }
], {
    ...L,
    xaxis: { ...L.xaxis, title: 'Zeit (s)' },
    yaxis: { ...L.yaxis, title: 'Fokus', range: [0, 1], titlefont: { color: '#5588ff' } },
    yaxis2: { overlaying: 'y', side: 'right', title: 'Pegel (dBFS)',
              range: [-90, 3], gridcolor: '#1e1e2e',
              titlefont: { color: '#ff6688' }, tickfont: { color: '#ff6688' } },
    height: 420
}, C);

Plotly.newPlot('p4', [{
    x: D.intensity.x, y: D.intensity.y, z: D.intensity.z,
    type: 'scatter3d', mode: 'lines+markers',
    marker: { size: 2, color: D.time, colorscale: 'Portland',
              colorbar: { title: 'Zeit (s)', tickfont: { color: '#99a' }, titlefont: { color: '#99a' } } },
    line: { width: 2, color: D.time, colorscale: 'Portland' },
    hovertemplate: 't=%{marker.color:.2f}s<br>X=%{x:.4f}<br>Y=%{y:.4f}<br>Z=%{z:.4f}<extra></extra>'
}], {
    ...L,
    scene: {
        xaxis: { title: 'X (vorne)', gridcolor: '#1e1e2e', backgroundcolor: '#10101a' },
        yaxis: { title: 'Y (links)', gridcolor: '#1e1e2e', backgroundcolor: '#10101a' },
        zaxis: { title: 'Z (oben)', gridcolor: '#1e1e2e', backgroundcolor: '#10101a' },
        bgcolor: '#10101a', camera: { eye: { x: 1.5, y: 1.5, z: 1.2 } }
    },
    height: 560
}, C);

Plotly.newPlot('p5', [{
    x: D.direction.azimuth, y: D.direction.elevation,
    mode: 'markers',
    marker: { size: 4, color: D.time, colorscale: 'Portland', opacity: 0.7,
              colorbar: { title: 'Zeit (s)', tickfont: { color: '#99a' }, titlefont: { color: '#99a' } } },
    hovertemplate: 'Az: %{x:.1f} deg<br>El: %{y:.1f} deg<extra></extra>'
}], {
    ...L,
    xaxis: { ...L.xaxis, title: 'Azimut (deg)', range: [-180, 180], dtick: 45 },
    yaxis: { ...L.yaxis, title: 'Elevation (deg)', range: [-90, 90], dtick: 30,
             scaleanchor: 'x', scaleratio: 1 },
    height: 560, showlegend: false
}, C);

Plotly.newPlot('p6', [{
    x: ['W', 'X', 'Y', 'Z'],
    y: D.ch_rms,
    type: 'bar',
    marker: { color: ['#dddddd', '#ff5555', '#55cc55', '#5588ff'] },
    hovertemplate: '%{x}: %{y:.1f} dBFS<extra></extra>'
}], {
    ...L,
    xaxis: { ...L.xaxis, title: 'Kanal' },
    yaxis: { ...L.yaxis, title: 'RMS (dBFS)', range: [-120, 3] },
    height: 360,
    showlegend: false
}, C);

let legendsVisible = true;
document.getElementById('toggleLegend').addEventListener('click', () => {
    legendsVisible = !legendsVisible;
    plotIds.forEach((id) => Plotly.relayout(id, {showlegend: legendsVisible}));
});

document.getElementById('toggleExport').addEventListener('click', () => {
    document.body.classList.toggle('export');
    setTimeout(() => window.dispatchEvent(new Event('resize')), 60);
});

document.getElementById('togglePaper').addEventListener('click', () => {
    document.body.classList.toggle('paper');
    setTimeout(() => window.dispatchEvent(new Event('resize')), 60);
});

document.getElementById('toggleScreenshot').addEventListener('click', () => {
    document.body.classList.toggle('screenshot');
    setTimeout(() => window.dispatchEvent(new Event('resize')), 60);
});

document.getElementById('printPage').addEventListener('click', () => {
    window.print();
});
</script>
</body>
</html>
]]
end

local function default_output_path(source_path)
  if source_path and source_path ~= "" then
    local root = source_path:gsub("%.[^%.]+$", "")
    return root .. "_FOA_Analysis.html"
  end
  return reaper.GetResourcePath() .. "/FOA_BFormat_Analysis.html"
end

local function write_text_file(path, content)
  local file, err = io.open(path, "w")
  if not file then
    return false, err
  end
  file:write(content)
  file:close()
  return true
end

local function open_in_firefox(path)
  local firefox_app = "/Applications/Firefox.app"
  local quoted_path = shell_quote(path)

  if reaper.file_exists(firefox_app) then
    os.execute("open -a Firefox " .. quoted_path)
    return true
  end

  return false
end

local function open_in_default_browser(path)
  local quoted_path = shell_quote(path)
  os.execute("open " .. quoted_path)
  return true
end

local function main()
  local context, channel_format, frame_ms = prompt_for_source()
  if not context then
    return
  end

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()

  local ok, err = xpcall(function()
    local data = analyze_foa(context, channel_format, frame_ms)
    local output_path = default_output_path(context.source_path)
    local html = build_html(data)
    local wrote, write_err = write_text_file(output_path, html)
    if not wrote then
      error("HTML konnte nicht geschrieben werden: " .. tostring(write_err))
    end
    local browser_mode = context.browser_mode or "firefox"
    local opened = false
    if browser_mode == "firefox" then
      opened = open_in_firefox(output_path)
    elseif browser_mode == "default" then
      opened = open_in_default_browser(output_path)
    end

    if opened and browser_mode == "firefox" then
      show_info("HTML-Analyse geschrieben nach und in Firefox geoeffnet:\n" .. output_path)
    elseif opened and browser_mode == "default" then
      show_info("HTML-Analyse geschrieben nach und im Standardbrowser geoeffnet:\n" .. output_path)
    elseif browser_mode == "none" then
      show_info("HTML-Analyse geschrieben nach:\n" .. output_path)
    else
      show_info("HTML-Analyse geschrieben nach:\n" .. output_path .. "\n\nFirefox wurde nicht gefunden und daher nicht automatisch geoeffnet.")
    end
  end, debug.traceback)

  cleanup_context(context)
  reaper.Undo_EndBlock("Generate FOA B-Format HTML analysis", -1)
  reaper.PreventUIRefresh(-1)

  if not ok then
    show_error(err)
  end
end

main()
