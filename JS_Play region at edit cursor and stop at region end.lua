-- @description Play region at edit cursor and stop at region end
-- @version 1.0
-- @author Codex
-- @about
--   Put the edit cursor inside a region and run this script.
--   It starts playback at the region start and stops automatically
--   at the region end. Useful for manually launching regions from
--   the keyboard, e.g. when bound to Return/Enter.

local EXT_SECTION = "JS_PlayRegionAtCursor"
local EXT_KEY = "run_token"

local function find_region_at_position(project, position)
  local marker_count, region_count = reaper.CountProjectMarkers(project)
  local total = marker_count + region_count

  for index = 0, total - 1 do
    local retval, is_region, start_pos, end_pos, _, markrgnindexnumber =
      reaper.EnumProjectMarkers(index)

    if retval > 0 and is_region and position >= start_pos and position < end_pos then
      return start_pos, end_pos, markrgnindexnumber
    end
  end

  return nil
end

local function stop_at_region_end(project, region_end, token)
  local current_token = reaper.GetExtState(EXT_SECTION, EXT_KEY)
  if current_token ~= token then
    return
  end

  if (reaper.GetPlayState() & 1) == 0 then
    return
  end

  local play_pos = reaper.GetPlayPosition2Ex(project)
  if play_pos >= region_end - 0.002 then
    reaper.OnStopButton()
    return
  end

  reaper.defer(function()
    stop_at_region_end(project, region_end, token)
  end)
end

local function main()
  local project = 0
  local cursor_pos = reaper.GetCursorPositionEx(project)
  local region_start, region_end = find_region_at_position(project, cursor_pos)

  if not region_start then
    reaper.ShowMessageBox(
      "Setze den Edit-Cursor in eine Region und starte das Script erneut.",
      "Keine Region unter dem Cursor",
      0
    )
    return
  end

  local token = tostring(reaper.time_precise())
  reaper.SetExtState(EXT_SECTION, EXT_KEY, token, false)

  reaper.Undo_BeginBlock()
  reaper.SetEditCurPos2(project, region_start, false, false)
  reaper.OnPlayButton()
  reaper.Undo_EndBlock("Play region at edit cursor and stop at region end", -1)

  stop_at_region_end(project, region_end, token)
end

main()
