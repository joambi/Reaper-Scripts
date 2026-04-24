-- @description Panic stop playback and reset region launcher state
-- @version 1.0
-- @author Codex
-- @about
--   Stops playback immediately and clears the extstates used by the
--   region launcher scripts so any deferred auto-stop watchers end cleanly.

local function clear_extstates()
  local sections = {
    "JS_PlayRegionAtCursor",
    "JS_PlaySelectedRegionInManager",
    "JS_PlaySelectedRegionFromCurrentPos",
    "JS_SelectNextRegionAndPlay",
    "JS_SelectPreviousRegionAndPlay",
  }

  for _, section in ipairs(sections) do
    reaper.DeleteExtState(section, "run_token", false)
  end
end

local function main()
  reaper.Undo_BeginBlock()
  reaper.OnStopButton()
  clear_extstates()
  reaper.Undo_EndBlock("Panic stop playback and reset region launcher state", -1)
end

main()
