-- Reorder scrolling columns locally, then hand the window to the next monitor.
-- Dwindle uses the same handoff at a tiled workspace edge.
local function has_neighbor(window, other, direction, layout)
  local horizontal = direction == "l" or direction == "r"
  local axis = horizontal and "x" or "y"
  local cross = horizontal and "y" or "x"
  local sign = (direction == "l" or direction == "u") and -1 or 1
  if layout == "scrolling" then
    return (other.at.x - window.at.x) * sign > 1
  end
  local center = window.at[axis] + window.size[axis] / 2
  local other_center = other.at[axis] + other.size[axis] / 2
  local overlap = math.min(window.at[cross] + window.size[cross], other.at[cross] + other.size[cross])
    - math.max(window.at[cross], other.at[cross])
  return (other_center - center) * sign > 1 and overlap > 1
end

return function(direction)
  local window = hl.get_active_window()
  if not window then return end
  local workspace = window.workspace
  local layout = workspace and workspace.tiled_layout
  local horizontal = direction == "l" or direction == "r"
  if #hl.get_monitors() < 2 or window.floating or not workspace or workspace.special
      or (layout ~= "scrolling" and layout ~= "dwindle") or (layout == "scrolling" and not horizontal) then
    hl.dispatch(hl.dsp.window.swap({ direction = direction }))
    return
  end

  for _, other in ipairs(hl.get_windows({ workspace = tostring(workspace.id), floating = false, mapped = true })) do
    if other.address ~= window.address and not other.hidden and has_neighbor(window, other, direction, layout) then
      hl.dispatch(hl.dsp.window.swap({ direction = direction }))
      return
    end
  end

  local monitor = hl.get_monitor(direction)
  if monitor then
    hl.dispatch(hl.dsp.window.move({ monitor = monitor.name, follow = true }))
  end
end
