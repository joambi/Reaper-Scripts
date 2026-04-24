-- @description Write M2 etude directly to AmbiEncoder
-- @version 1.0
-- @author Codex
-- @about
--   Schreibt die M2-Etuede direkt als lineare Envelope-Punkte auf
--   X/Y/Z-Parameter eines ICST AmbiEncoder_64 auf der ausgewaehlten Spur.
--   Kein SPATAI, kein OSC-Log noetig.
--   Standard-Mapping: Stimme A -> Point 1, Stimme B -> Point 2.

local FX_NAME_HINT = "AmbiEncoder_64"

local SCORE = {
  {
    start_time = 0.0,
    end_time = 25.0,
    a = { x = -0.87, y = 0.50, z = 0.50 },
    b = { x = 0.94, y = -0.34, z = 0.50 },
  },
  {
    start_time = 25.0,
    end_time = 55.0,
    curve = "faster",
    a = { x = -0.87, y = -0.80, z = 0.75 },
    b = { x = 0.94, y = 0.80, z = 0.30 },
  },
  {
    start_time = 55.0,
    end_time = 80.0,
    curve = "linear",
    a = { x = -0.87, y = 0.55, z = 0.75 },
    b = { x = 0.94, y = -1.00, z = 0.30 },
  },
  {
    start_time = 80.0,
    end_time = 110.0,
    a = { x = -1.00, y = 0.55, z = 0.75 },
    b = { x = 0.20, y = 0.10, z = 0.30 },
  },
  {
    start_time = 110.0,
    end_time = 135.0,
    a = { x = -0.10, y = 0.00, z = 0.58 },
    b = { x = 0.10, y = 0.00, z = 0.52 },
  },
  {
    start_time = 135.0,
    end_time = 160.0,
    curve = "linear",
    a = { x = -0.62, y = 0.79, z = 0.64 },
    b = { x = -0.77, y = -0.64, z = 0.43 },
  },
  {
    start_time = 160.0,
    end_time = 168.0,
    curve = "linear",
    a = { x = -0.62, y = 0.79, z = 0.64 },
    b = { x = -0.77, y = -0.64, z = 0.43 },
  },
}

local SUBDIVISIONS_PER_SECTION = 24

local function lower(text)
  return text:lower()
end

local function show_error(message)
  reaper.ShowMessageBox(message, "Write M2 Etude", 0)
end

local function find_fx(track)
  local fx_count = reaper.TrackFX_GetCount(track)
  for fx_index = 0, fx_count - 1 do
    local retval, fx_name = reaper.TrackFX_GetFXName(track, fx_index, "")
    if retval and fx_name:find(FX_NAME_HINT, 1, true) then
      return fx_index, fx_name
    end
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
      local normalized = lower(param_name)
      if not indices.x and normalized == x_name then
        indices.x = param_index
      elseif not indices.y and normalized == y_name then
        indices.y = param_index
      elseif not indices.z and normalized == z_name then
        indices.z = param_index
      end
    end
  end

  return indices
end

local function get_envelope(track, fx_index, param_index)
  return reaper.GetFXEnvelope(track, fx_index, param_index, true)
end

local function get_param_range(track, fx_index, param_index)
  local _, minval, maxval = reaper.TrackFX_GetParam(track, fx_index, param_index)
  return minval, maxval
end

local function normalize_to_param(value, minval, maxval, axis)
  local normalized
  if axis == "z" then
    normalized = value
  else
    normalized = (value + 1.0) / 2.0
  end

  if normalized < minval then
    normalized = minval
  elseif normalized > maxval then
    normalized = maxval
  end

  return normalized
end

local function raw_envelope_value(envelope, normalized)
  local mode = reaper.GetEnvelopeScalingMode(envelope)
  return reaper.ScaleToEnvelopeMode(mode, normalized)
end

local function delete_points_in_range(envelope, start_time, end_time)
  reaper.DeleteEnvelopePointRangeEx(envelope, -1, start_time - 0.0001, end_time + 0.0001)
end

local function delete_all_points(envelope)
  reaper.DeleteEnvelopePointRangeEx(envelope, -1, -1e15, 1e15)
end

local function insert_point(envelope, time, normalized)
  local raw = raw_envelope_value(envelope, normalized)
  reaper.InsertEnvelopePointEx(envelope, -1, time, raw, 0, 0, false, true)
end

local function ease_in_out(progress)
  return (1 - math.cos(math.pi * progress)) / 2
end

local function ease_out_sine(progress)
  return math.sin((math.pi * progress) / 2)
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function section_progress(section, progress)
  if section.curve == "faster" then
    return ease_out_sine(progress)
  end
  if section.curve == "linear" then
    return progress
  end
  return ease_in_out(progress)
end

local function write_voice(track, fx_index, point_index, voice_key, start_offset, clear_range)
  local params = find_param_indices(track, fx_index, point_index)
  if not params.x or not params.y or not params.z then
    return nil, "X/Y/Z-Parameter fuer Point " .. tostring(point_index) .. " wurden nicht gefunden."
  end

  local x_env = get_envelope(track, fx_index, params.x)
  local y_env = get_envelope(track, fx_index, params.y)
  local z_env = get_envelope(track, fx_index, params.z)
  if not x_env or not y_env or not z_env then
    return nil, "Envelopes fuer Point " .. tostring(point_index) .. " konnten nicht angelegt werden."
  end

  local x_min, x_max = get_param_range(track, fx_index, params.x)
  local y_min, y_max = get_param_range(track, fx_index, params.y)
  local z_min, z_max = get_param_range(track, fx_index, params.z)

  local first_time = start_offset + SCORE[1].start_time
  local last_time = start_offset + SCORE[#SCORE].end_time

  if clear_range then
    delete_all_points(x_env)
    delete_all_points(y_env)
    delete_all_points(z_env)
  end

  local point_count = 0

  for section_index, section in ipairs(SCORE) do
    local start_time = start_offset + section.start_time
    local end_time = start_offset + section.end_time

    local previous = section_index == 1 and section[voice_key] or SCORE[section_index - 1][voice_key]
    local current = section[voice_key]

    for step = 0, SUBDIVISIONS_PER_SECTION do
      local progress = step / SUBDIVISIONS_PER_SECTION
      local eased = section_progress(section, progress)
      local point_time = lerp(start_time, end_time, progress)

      local x_value = lerp(previous.x, current.x, eased)
      local y_value = lerp(previous.y, current.y, eased)
      local z_value = lerp(previous.z, current.z, eased)

      insert_point(x_env, point_time, normalize_to_param(x_value, x_min, x_max, "x"))
      insert_point(y_env, point_time, normalize_to_param(y_value, y_min, y_max, "y"))
      insert_point(z_env, point_time, normalize_to_param(z_value, z_min, z_max, "z"))
      point_count = point_count + 1
    end
  end

  reaper.Envelope_SortPointsEx(x_env, -1)
  reaper.Envelope_SortPointsEx(y_env, -1)
  reaper.Envelope_SortPointsEx(z_env, -1)

  return {
    point_index = point_index,
    point_count = point_count,
    start_time = first_time,
    end_time = last_time,
  }
end

local function main()
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    show_error("Bitte zuerst die Zielspur mit dem AmbiEncoder auswaehlen.")
    return
  end

  local fx_index, fx_name = find_fx(track)
  if not fx_index then
    show_error("Auf der ausgewaehlten Spur wurde kein AmbiEncoder_64 gefunden.")
    return
  end

  local ok, csv = reaper.GetUserInputs(
    "Write M2 Etude",
    4,
    "Point fuer Stimme A,Point fuer Stimme B,Start offset (s),Bereich loeschen? (y/n)",
    "1,2,0,y"
  )
  if not ok then
    return
  end

  local point_a_text, point_b_text, start_offset_text, clear_text =
    csv:match("^%s*([^,]+),%s*([^,]+),%s*([^,]+),%s*([^,]+)%s*$")

  local point_a = tonumber(point_a_text or "")
  local point_b = tonumber(point_b_text or "")
  local start_offset = tonumber(start_offset_text or "")
  local clear_range = lower(clear_text or "") == "y"

  if not point_a or not point_b or point_a < 1 or point_a > 64 or point_b < 1 or point_b > 64 or not start_offset then
    show_error("Bitte gueltige Points 1-64 und einen gueltigen Start offset eingeben.")
    return
  end

  reaper.Undo_BeginBlock()

  local result_a, err_a = write_voice(track, fx_index, point_a, "a", start_offset, clear_range)
  if not result_a then
    reaper.Undo_EndBlock("Write M2 etude directly to AmbiEncoder", -1)
    show_error(err_a)
    return
  end

  local result_b, err_b = write_voice(track, fx_index, point_b, "b", start_offset, false)
  if not result_b then
    reaper.Undo_EndBlock("Write M2 etude directly to AmbiEncoder", -1)
    show_error(err_b)
    return
  end

  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Write M2 etude directly to AmbiEncoder", -1)

  reaper.ShowMessageBox(
    "M2-Etuede geschrieben.\n\n" ..
    "FX: " .. tostring(fx_name) .. "\n" ..
    "Stimme A -> Point " .. tostring(result_a.point_index) .. "\n" ..
    "Stimme B -> Point " .. tostring(result_b.point_index) .. "\n" ..
    "Zeit: " .. string.format("%.3f", result_a.start_time) .. "s bis " ..
      string.format("%.3f", result_a.end_time) .. "s",
    "Write M2 Etude",
    0
  )
end

main()
