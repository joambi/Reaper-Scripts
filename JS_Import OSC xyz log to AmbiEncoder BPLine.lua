-- @description Import OSC xyz log to AmbiEncoder BPLine
-- @version 1.0
-- @author Codex
-- @about
--   Liest einen OSC-Log mit Zeilen wie
--   "14:23:01 /object/1/xyz -8.7 2 -0"
--   oder
--   "0.250 /object/1/xyz -8.7 2 0"
--   und schreibt die Daten als lineare Automation auf die
--   X/Y/Z-Parameter eines FX auf der ausgewaehlten Spur.
--   Gedacht fuer ICST AmbiEncoder_64 oder aehnliche Plugins.

local FX_NAME_HINT = "AmbiEncoder_64"

local function trim(value)
  return value:match("^%s*(.-)%s*$")
end

local function read_file(path)
  local file, err = io.open(path, "r")
  if not file then
    return nil, err
  end

  local content = file:read("*all")
  file:close()
  return content
end

local function parse_timecode(text)
  local raw = trim(text)

  if raw:match("^%-?%d+%.?%d*$") then
    return tonumber(raw)
  end

  local h, m, s = raw:match("^(%d+):(%d+):(%d+%.?%d*)$")
  if h then
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
  end

  local mm, ss = raw:match("^(%d+):(%d+%.?%d*)$")
  if mm then
    return tonumber(mm) * 60 + tonumber(ss)
  end

  return nil
end

local function parse_osc_log(content, object_id)
  local events = {}
  local first_time = nil

  for line in content:gmatch("[^\r\n]+") do
    local ts, obj, x, y, z = line:match("^%s*([^%s]+)%s+/object/(%d+)/xyz%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)")
    if ts and tonumber(obj) == object_id then
      local abs_time = parse_timecode(ts)
      if abs_time then
        if not first_time then
          first_time = abs_time
        end

        events[#events + 1] = {
          time = abs_time - first_time,
          x = tonumber(x),
          y = tonumber(y),
          z = tonumber(z),
        }
      end
    end
  end

  return events
end

local function parse_all_osc_logs(content)
  local per_object = {}
  local first_time = nil

  for line in content:gmatch("[^\r\n]+") do
    local ts, obj, x, y, z = line:match("^%s*([^%s]+)%s+/object/(%d+)/xyz%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)")
    if ts and obj then
      local abs_time = parse_timecode(ts)
      local object_id = tonumber(obj)
      if abs_time and object_id then
        if not first_time then
          first_time = abs_time
        end

        per_object[object_id] = per_object[object_id] or {}
        per_object[object_id][#per_object[object_id] + 1] = {
          time = abs_time - first_time,
          x = tonumber(x),
          y = tonumber(y),
          z = tonumber(z),
        }
      end
    end
  end

  return per_object
end

local function lower(text)
  return text:lower()
end

local function find_fx(track)
  local fx_count = reaper.TrackFX_GetCount(track)
  local fallback = nil

  for fx_index = 0, fx_count - 1 do
    local retval, fx_name = reaper.TrackFX_GetFXName(track, fx_index, "")
    if retval then
      if fx_name:find(FX_NAME_HINT, 1, true) then
        return fx_index, fx_name
      end
      if not fallback then
        fallback = { fx_index, fx_name }
      end
    end
  end

  if fallback then
    return fallback[1], fallback[2]
  end

  return nil
end

local function find_param_indices(track, fx_index, point_index)
  local param_count = reaper.TrackFX_GetNumParams(track, fx_index)
  local indices = { x = nil, y = nil, z = nil }
  local x_name = "x " .. tostring(point_index)
  local y_name = "y " .. tostring(point_index)
  local z_name = "z " .. tostring(point_index)

  for param_index = 0, param_count - 1 do
    local retval, param_name = reaper.TrackFX_GetParamName(track, fx_index, param_index, "")
    if retval then
      local lowered = lower(param_name)
      if not indices.x and lowered == x_name then
        indices.x = param_index
      elseif not indices.y and lowered == y_name then
        indices.y = param_index
      elseif not indices.z and lowered == z_name then
        indices.z = param_index
      end
    end
  end

  return indices
end

local function get_param_range(track, fx_index, param_index)
  local _, minval, maxval = reaper.TrackFX_GetParam(track, fx_index, param_index)
  return minval, maxval
end

local function clamp(value, minval, maxval)
  if value < minval then
    return minval
  end
  if value > maxval then
    return maxval
  end
  return value
end

local function normalize(value, minval, maxval)
  if maxval == minval then
    return 0
  end
  return (value - minval) / (maxval - minval)
end

local function raw_envelope_value(envelope, normalized)
  local mode = reaper.GetEnvelopeScalingMode(envelope)
  return reaper.ScaleToEnvelopeMode(mode, normalized)
end

local function delete_points_in_range(envelope, start_time, end_time)
  reaper.DeleteEnvelopePointRangeEx(envelope, -1, start_time - 0.0001, end_time + 0.0001)
end

local function write_points(envelope, events, key, minval, maxval, start_offset)
  local inserted = 0

  for _, event in ipairs(events) do
    local source_value = event[key]
    local clamped = clamp(source_value, minval, maxval)
    local normalized = normalize(clamped, minval, maxval)
    local raw = raw_envelope_value(envelope, normalized)
    local point_time = start_offset + event.time

    reaper.InsertEnvelopePointEx(envelope, -1, point_time, raw, 0, 0, false, true)
    inserted = inserted + 1
  end

  reaper.Envelope_SortPointsEx(envelope, -1)
  return inserted
end

local function parse_mapping(text)
  local mapping = {}

  for pair in text:gmatch("[^,]+") do
    local object_id_text, point_index_text = pair:match("^%s*(%d+)%s*%-%>%s*(%d+)%s*$")
    if not object_id_text then
      object_id_text, point_index_text = pair:match("^%s*(%d+)%s*=%s*(%d+)%s*$")
    end

    local object_id = tonumber(object_id_text or "")
    local point_index = tonumber(point_index_text or "")

    if not object_id or not point_index or point_index < 1 or point_index > 64 then
      return nil
    end

    mapping[#mapping + 1] = { object_id = object_id, point_index = point_index }
  end

  if #mapping == 0 then
    return nil
  end

  return mapping
end

local function show_error(message)
  reaper.ShowMessageBox(message, "OSC xyz Import", 0)
end

local function main()
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    show_error("Bitte zuerst die Zielspur mit dem AmbiEncoder auswaehlen.")
    return
  end

  local ok, csv = reaper.GetUserInputs(
    "OSC xyz Import",
    3,
    "Mapping object->point,Start offset (s),Bereich loeschen? (y/n)",
    "1->1,2->2,0,y"
  )
  if not ok then
    return
  end

  local mapping_text, start_offset_text, clear_text =
    csv:match("^%s*(.-)%s*,%s*([^,]+),%s*([^,]+)%s*$")

  local mapping = parse_mapping(mapping_text or "")
  local start_offset = tonumber(start_offset_text or "")
  local clear_range = lower(clear_text or "") == "y"

  if not mapping or not start_offset then
    show_error("Mapping, z. B. 1->1,2->2, und Start offset muessen gueltig sein.")
    return
  end

  local retval, path = reaper.GetUserFileNameForRead("", "OSC-Log waehlen", ".txt")
  if not retval or not path or path == "" then
    return
  end

  local content, err = read_file(path)
  if not content then
    show_error("Datei konnte nicht gelesen werden:\n" .. tostring(err))
    return
  end

  local all_events = parse_all_osc_logs(content)

  local fx_index, fx_name = find_fx(track)
  if not fx_index then
    show_error("Auf der ausgewaehlten Spur wurde kein FX gefunden.")
    return
  end

  local imports = {}

  for _, entry in ipairs(mapping) do
    local events = all_events[entry.object_id]
    if not events or #events == 0 then
      show_error("Keine /object/" .. tostring(entry.object_id) .. "/xyz-Zeilen im Log gefunden.")
      return
    end

    local params = find_param_indices(track, fx_index, entry.point_index)
    if not params.x or not params.y or not params.z then
      show_error(
        "X/Y/Z-Parameter fuer Punkt " .. tostring(entry.point_index) .. " konnten nicht sicher gefunden werden.\n" ..
        "FX: " .. tostring(fx_name)
      )
      return
    end

    local x_env = reaper.GetFXEnvelope(track, fx_index, params.x, true)
    local y_env = reaper.GetFXEnvelope(track, fx_index, params.y, true)
    local z_env = reaper.GetFXEnvelope(track, fx_index, params.z, true)
    if not x_env or not y_env or not z_env then
      show_error("FX-Envelopes fuer Punkt " .. tostring(entry.point_index) .. " konnten nicht angelegt werden.")
      return
    end

    imports[#imports + 1] = {
      object_id = entry.object_id,
      point_index = entry.point_index,
      events = events,
      x_env = x_env,
      y_env = y_env,
      z_env = z_env,
      x_min = ({ get_param_range(track, fx_index, params.x) })[1],
      x_max = ({ get_param_range(track, fx_index, params.x) })[2],
      y_min = ({ get_param_range(track, fx_index, params.y) })[1],
      y_max = ({ get_param_range(track, fx_index, params.y) })[2],
      z_min = ({ get_param_range(track, fx_index, params.z) })[1],
      z_max = ({ get_param_range(track, fx_index, params.z) })[2],
      start_time = start_offset + events[1].time,
      end_time = start_offset + events[#events].time,
    }
  end

  reaper.Undo_BeginBlock()

  local summary = {}

  for _, item in ipairs(imports) do
    if clear_range then
      delete_points_in_range(item.x_env, item.start_time, item.end_time)
      delete_points_in_range(item.y_env, item.start_time, item.end_time)
      delete_points_in_range(item.z_env, item.start_time, item.end_time)
    end

    local x_count = write_points(item.x_env, item.events, "x", item.x_min, item.x_max, start_offset)
    local y_count = write_points(item.y_env, item.events, "y", item.y_min, item.y_max, start_offset)
    local z_count = write_points(item.z_env, item.events, "z", item.z_min, item.z_max, start_offset)

    summary[#summary + 1] = {
      object_id = item.object_id,
      point_index = item.point_index,
      count = math.min(x_count, y_count, z_count),
      start_time = item.start_time,
      end_time = item.end_time,
    }
  end

  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  reaper.Undo_EndBlock("Import OSC xyz log to AmbiEncoder BPLine", -1)

  local lines = {
    "Import abgeschlossen.",
    "",
    "FX: " .. tostring(fx_name),
  }

  for _, item in ipairs(summary) do
    lines[#lines + 1] =
      "Object " .. tostring(item.object_id) ..
      " -> Point " .. tostring(item.point_index) ..
      ", Punkte: " .. tostring(item.count) ..
      ", Zeit: " .. string.format("%.3f", item.start_time) ..
      "s bis " .. string.format("%.3f", item.end_time) .. "s"
  end

  reaper.ShowMessageBox(table.concat(lines, "\n"), "OSC xyz Import", 0)
end

main()
