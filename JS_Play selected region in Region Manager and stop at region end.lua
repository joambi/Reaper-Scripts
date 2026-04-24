-- @description Play selected region in Region Manager and stop at region end
-- @version 1.0
-- @author Codex
-- @about
--   Select a region in the Region/Marker Manager and run this script.
--   It starts playback at the selected region start and stops automatically
--   at the region end. If multiple regions are selected, the topmost selected
--   region in the Region Manager is used.

local EXT_SECTION = "JS_PlaySelectedRegionInManager"
local EXT_KEY = "run_token"

local function get_region_manager_list()
  local title = reaper.JS_Localize("Region/Marker Manager", "common")
  local manager = reaper.JS_Window_Find(title, true)
  if not manager then
    return nil, "Der Region/Marker Manager ist nicht offen."
  end

  local list = reaper.JS_Window_FindChildByID(manager, 1071)
  if not list then
    return nil, "Die Region-Liste im Region Manager konnte nicht gefunden werden."
  end

  return list
end

local function get_first_selected_region_number()
  local list, err = get_region_manager_list()
  if not list then
    return nil, err
  end

  local selected_count, selected_indexes = reaper.JS_ListView_ListAllSelItems(list)
  if not selected_count or selected_count == 0 then
    return nil, "Im Region Manager ist keine Region ausgewaehlt."
  end

  local top_index = nil
  for index in tostring(selected_indexes):gmatch("[^,]+") do
    local numeric_index = tonumber(index)
    if numeric_index and (not top_index or numeric_index < top_index) then
      top_index = numeric_index
    end
  end

  if not top_index then
    return nil, "Die Region-Auswahl konnte nicht gelesen werden."
  end

  local entry = reaper.JS_ListView_GetItemText(list, top_index, 1)
  if not entry or entry == "" then
    return nil, "Die ausgewaehlte Zeile im Region Manager ist leer."
  end

  local region_number = entry:match("^R(%d+)$")
  if not region_number then
    return nil, "Die ausgewaehlte Zeile ist keine Region."
  end

  return tonumber(region_number)
end

local function find_region_by_number(project, wanted_region_number)
  local marker_count, region_count = reaper.CountProjectMarkers(project)
  local total = marker_count + region_count

  for index = 0, total - 1 do
    local retval, is_region, start_pos, end_pos, _, markrgnindexnumber =
      reaper.EnumProjectMarkers(index)

    if retval > 0 and is_region and markrgnindexnumber == wanted_region_number then
      return start_pos, end_pos
    end
  end

  return nil
end

local function stop_at_region_end(project, region_end, token)
  local current_token = reaper.GetExtState(EXT_SECTION, EXT_KEY)
  if current_token ~= token then
    return
  end

  if (reaper.GetPlayStateEx(project) & 1) == 0 then
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
  if not reaper.APIExists("JS_ListView_ListAllSelItems") then
    reaper.ShowMessageBox(
      "Dieses Script braucht die Erweiterung js_ReaScriptAPI.",
      "Fehlende Erweiterung",
      0
    )
    return
  end

  local project = 0
  local region_number, err = get_first_selected_region_number()
  if not region_number then
    reaper.ShowMessageBox(err, "Region konnte nicht gestartet werden", 0)
    return
  end

  local region_start, region_end = find_region_by_number(project, region_number)
  if not region_start then
    reaper.ShowMessageBox(
      "Die ausgewaehlte Region wurde im Projekt nicht gefunden.",
      "Region konnte nicht gestartet werden",
      0
    )
    return
  end

  local play_state = reaper.GetPlayStateEx(project)
  if (play_state & 1) == 1 or (play_state & 2) == 2 then
    reaper.OnStopButton()
  end

  local token = tostring(reaper.time_precise())
  reaper.SetExtState(EXT_SECTION, EXT_KEY, token, false)

  reaper.Undo_BeginBlock()
  reaper.SetEditCurPos2(project, region_start, false, false)
  reaper.OnPlayButton()
  reaper.Undo_EndBlock("Play selected region in Region Manager and stop at region end", -1)

  stop_at_region_end(project, region_end, token)
end

main()
