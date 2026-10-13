-- Keep scrolling reordering local until the first or last column is reached.
-- Resolve a named destination only when a neighboring monitor exists.
return function(direction)
  local window = hl.get_active_window()
  if not window then return end
  local workspace = window.workspace
  if window.floating or not workspace or workspace.special or workspace.tiled_layout ~= "scrolling" then
    hl.dispatch(hl.dsp.window.swap({ direction = direction }))
    return
  end

  local sign = direction == "l" and -1 or 1
  for _, other in ipairs(hl.get_windows({ workspace = tostring(workspace.id), floating = false, mapped = true })) do
    if other.address ~= window.address and not other.hidden and (other.at.x - window.at.x) * sign > 1 then
      hl.dispatch(hl.dsp.window.swap({ direction = direction }))
      return
    end
  end

  local monitor = hl.get_monitor(direction)
  if monitor then
    hl.dispatch(hl.dsp.window.move({ monitor = monitor.name, follow = true }))
  end
end
