-- Re-apply monitor scales saved by omarchy-hyprland-monitor-scaling on top of
-- the rule that governs each monitor, so a scale survives reloads without
-- editing ~/.config/hypr/monitors.lua.
--
-- Hyprland merges a later rule into an earlier one only when both use the same
-- output key, and a rule for a different key replaces it outright. So a saved
-- scale is applied as a full copy of the rule the config set for that monitor,
-- under that rule's own key, with only the scale changed. record() captures the
-- rules as the config sets them (after its loops and locals have run); apply()
-- runs once the user's config is loaded.
--
-- The saved file is data, never Lua: monitor descriptions come from EDID and
-- must not be loaded as code.

local paths = require("default.hypr.paths")

local M = {}

local state_dir = paths.home .. "/.local/state/omarchy/toggles/hypr"
local saved_file = state_dir .. "/monitor-scales"
local monitor_lua = paths.home .. "/.config/hypr/monitors.lua"

local rules = {}

-- Hyprland's Lua state outlives a reload while this module does not, so a
-- wrapper from the previous load may still be installed. Keep the original.
function M.record()
  local current = hl.monitor
  local original = current

  if _G.omarchy_monitor_scales and current == _G.omarchy_monitor_scales.wrapper then
    original = _G.omarchy_monitor_scales.original
  end

  local function wrapper(rule)
    if type(rule) == "table" then
      local copy = {}
      for key, value in pairs(rule) do
        copy[key] = value
      end
      table.insert(rules, copy)
    end

    return original(rule)
  end

  _G.omarchy_monitor_scales = { original = original, wrapper = wrapper }
  hl.monitor = wrapper
end

local function original_monitor()
  if _G.omarchy_monitor_scales then
    return _G.omarchy_monitor_scales.original
  end

  return hl.monitor
end

local function modified_at(path)
  local handle = io.popen("stat -c %Y " .. "'" .. path:gsub("'", "'\\''") .. "' 2>/dev/null")
  if not handle then
    return nil
  end

  local value = tonumber(handle:read("*l") or "")
  handle:close()
  return value
end

local function matches(output, name, description)
  if output == name then
    return true
  end

  if description ~= "" and output:sub(1, 5) == "desc:" then
    local wanted = output:sub(6)
    return wanted ~= "" and description:sub(1, #wanted) == wanted
  end

  return false
end

-- The last rule naming the monitor wins, as it does in Hyprland; the catch-all
-- only governs a monitor no other rule names.
local function governing_rule(name, description)
  local found
  local catch_all

  for _, rule in ipairs(rules) do
    local output = rule.output
    if type(output) == "string" then
      if output == "" then
        catch_all = rule
      elseif matches(output, name, description) then
        found = rule
      end
    end
  end

  return found, catch_all
end

local function apply_scale(scale, name, description)
  local rule, catch_all = governing_rule(name, description)
  local copy = {}

  for key, value in pairs(rule or catch_all or {}) do
    copy[key] = value
  end

  if not rule then
    copy.output = description ~= "" and ("desc:" .. description) or name
  end

  copy.scale = scale
  original_monitor()(copy)
end

function M.apply()
  local file = io.open(saved_file, "r")
  if not file then
    return
  end

  -- An edit to monitors.lua made after a scale was saved is the newer choice.
  local config_changed_at = modified_at(monitor_lua) or 0

  for line in file:lines() do
    local scale, name, saved_at, description = line:match("^([%d.]+)\t([%w._-]+)\t(%d+)\t([^\t]*)$")
    scale = tonumber(scale)
    saved_at = tonumber(saved_at)

    if scale and scale > 0 and saved_at and saved_at >= config_changed_at then
      apply_scale(scale, name, description)
    end
  end

  file:close()
end

return M
