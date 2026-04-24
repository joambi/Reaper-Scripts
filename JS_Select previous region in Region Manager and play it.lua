-- @description Select previous region in Region Manager and play it
-- @version 1.0
-- @author Codex
-- @about
--   Moves the Region/Marker Manager selection to the previous region and starts it.
--   Playback always begins at the region start and stops automatically at the
--   region end. If no region is selected, the last region is used.

local EXT_SECTION = "JS_SelectPreviousRegionAndPlay"
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

local function build_region_rows(list)
  local rows = {}
  local item_count = reaper.JS_ListView_GetItemCount(list)

  for i = 0, item_count - 1 do
    local entry = reaper.JS_ListView_GetItemText(list, i, 1)
    local region_number = entry and entry:match("^R(%d+)$")
    if region_number then
      rows[#rows + 1] = { row = i, region_number = tonumber(region_number) }
    end
  end

  return rows
end

local function get_selected_row_index(list)
  local selected_count, selected_indexes = reaper.JS_ListView_ListAllSelItems(list)
  if not selected_count or selected_count == 0 then
    return nil
  end

  local top_index = nil
  for index in tostring(selected_indexes):gmatch("[^,]+") do
    local numeric_index = tonumber(index)
    if numeric_index and (not top_index or numeric_index < top_index) then
      top_index = numeric_index
    end
  end

  return top_index
end

local function select_row(list, row)
  reaper.JS_ListView_SetItemState(list, -1, 0x0, 0x2)
  reaper.JS_ListView_SetItemState(list, row, 0x3, 0x3)
  reaper.JS_ListView_EnsureVisible(list, row, false)
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
  local list, err = get_region_manager_list()
  if not list then
    reaper.ShowMessageBox(err, "Vorige Region konnte nicht gestartet werden", 0)
    return
  end

  local region_rows = build_region_rows(list)
  if #region_rows == 0 then
    reaper.ShowMessageBox(
      "Im Region Manager wurden keine Regions gefunden.",
      "Vorige Region konnte nicht gestartet werden",
      0
    )
    return
  end

  local selected_row = get_selected_row_index(list)
  local target = region_rows[#region_rows]

  if selected_row then
    for i = #region_rows, 1, -1 do
      if region_rows[i].row < selected_row then
        target = region_rows[i]
        break
      end
    end
  end

  select_row(list, target.row)

  local region_start, region_end = find_region_by_number(project, target.region_number)
  if not region_start then
    reaper.ShowMessageBox(
      "Die vorige Region wurde im Projekt nicht gefunden.",
      "Vorige Region konnte nicht gestartet werden",
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
  reaper.Undo_EndBlock("Select previous region in Region Manager and play it", -1)

  stop_at_region_end(project, region_end, token)
end

main()
