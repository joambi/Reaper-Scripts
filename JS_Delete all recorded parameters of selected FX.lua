-- @description Delete all recorded parameters of selected FX
-- @version 1.0
-- @author Codex
-- @about
--   Loescht alle vorhandenen Automationspunkte saemtlicher Parameter-
--   Envelopes des ausgewaehlten FX auf der ersten selektierten Spur.

local function show_error(message)
  reaper.ShowMessageBox(message, "Delete FX Parameter Automation", 0)
end

local function main()
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    show_error("Bitte zuerst eine Spur auswaehlen.")
    return
  end

  local fx_count = reaper.TrackFX_GetCount(track)
  if fx_count == 0 then
    show_error("Auf der ausgewaehlten Spur wurde kein FX gefunden.")
    return
  end

  local ok, csv = reaper.GetUserInputs(
    "Delete FX Parameter Automation",
    1,
    "FX index auf der Spur (1-" .. tostring(fx_count) .. ")",
    "1"
  )
  if not ok then
    return
  end

  local fx_index_1based = tonumber(csv)
  if not fx_index_1based or fx_index_1based < 1 or fx_index_1based > fx_count then
    show_error("Bitte einen gueltigen FX-Index eingeben.")
    return
  end

  local fx_index = fx_index_1based - 1
  local _, fx_name = reaper.TrackFX_GetFXName(track, fx_index, "")
  local param_count = reaper.TrackFX_GetNumParams(track, fx_index)
  local deleted_envelopes = 0
  local deleted_points = 0

  reaper.Undo_BeginBlock()

  for param_index = 0, param_count - 1 do
    local envelope = reaper.GetFXEnvelope(track, fx_index, param_index, false)
    if envelope then
      local point_count = reaper.CountEnvelopePointsEx(envelope, -1)
      if point_count > 0 then
        reaper.DeleteEnvelopePointRangeEx(envelope, -1, -1e15, 1e15)
        reaper.Envelope_SortPointsEx(envelope, -1)
        deleted_envelopes = deleted_envelopes + 1
        deleted_points = deleted_points + point_count
      end
    end
  end

  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Delete all recorded parameters of selected FX", -1)

  reaper.ShowMessageBox(
    "Automationspunkte geloescht.\n\n" ..
    "FX: " .. tostring(fx_name) .. "\n" ..
    "Betroffene Envelopes: " .. tostring(deleted_envelopes) .. "\n" ..
    "Geloeschte Punkte: " .. tostring(deleted_points),
    "Delete FX Parameter Automation",
    0
  )
end

main()
