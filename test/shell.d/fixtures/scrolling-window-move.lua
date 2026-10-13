local move = dofile(os.getenv("OMARCHY_PATH") .. "/default/hypr/scrolling-window-move.lua")
local active, windows, monitor, dispatched
hl = {
  get_active_window = function() return active end,
  get_windows = function(filter)
    local result = {}
    for _, w in ipairs(windows) do
      if tostring(w.workspace.id) == filter.workspace and not w.floating and w.mapped then
        table.insert(result, w)
      end
    end
    return result
  end,
  get_monitor = function() return monitor end,
  dispatch = function(action) table.insert(dispatched, action) end,
  dsp = { window = {
    swap = function(args) return { kind = "swap", args = args } end,
    move = function(args) return { kind = "move", args = args } end,
  } },
}
local function window(x, id, opts)
  local w = { address = tostring(x) .. ":" .. tostring(id), at = { x = x }, workspace = { id = id or 1, tiled_layout = "scrolling" }, mapped = true }
  for k, v in pairs(opts or {}) do w[k] = v end
  return w
end
local function check(direction, expected)
  dispatched = {}
  move(direction)
  assert(#dispatched == (expected and 1 or 0))
  if expected then
    assert(dispatched[1].kind == expected)
    if expected == "swap" then assert(dispatched[1].args.direction == direction) end
    if expected == "move" then
      assert(dispatched[1].args.monitor == monitor.name)
      assert(dispatched[1].args.follow == true)
    end
  end
end
active = window(100, 1)
windows = { active, window(200, 1) }
monitor = { name = "DP-2" }
check("r", "swap") -- Includes a column beyond the visible viewport.
check("l", "move") -- Empty destination monitor requires no target window.
windows = { active, window(0, 1) }
check("l", "swap")
check("r", "move")
windows = { active, window(200, 2), window(200, 1, { floating = true }), window(200, 1, { hidden = true }), window(200, 1, { mapped = false }) }
check("r", "move") -- Other workspaces and non-tiled/hidden windows cannot block an edge.
monitor = nil
check("r", nil)
check("r", nil) -- Repeated outward presses do not dispatch invalid monitor moves.
active.workspace.tiled_layout = "dwindle"
check("r", "swap")
active.workspace.tiled_layout = "scrolling"
active.workspace.special = true
check("r", "swap")
active.workspace.special = false
active.floating = true
check("r", "swap")
active = nil
check("r", nil)
print("scrolling window movement regression cases passed")
