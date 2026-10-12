function pair(monitors, moving, reference) {
  var names = monitors.map(function(monitor) { return monitor.name })
  if (names.indexOf(reference) < 0) {
    reference = names.filter(function(name) { return /^(eDP|LVDS|DSI)/.test(name) })[0] || names[0] || ""
  }
  if (names.indexOf(moving) < 0 || moving === reference)
    moving = names.filter(function(name) { return name !== reference }).pop() || ""
  return { moving: moving, reference: reference }
}

function bounds(monitors) {
  if (!monitors.length) return { x: 0, y: 0, width: 1, height: 1 }
  var left = Math.min.apply(null, monitors.map(function(m) { return m.x }))
  var top = Math.min.apply(null, monitors.map(function(m) { return m.y }))
  var right = Math.max.apply(null, monitors.map(function(m) { return m.x + m.logicalWidth }))
  var bottom = Math.max.apply(null, monitors.map(function(m) { return m.y + m.logicalHeight }))
  return { x: left, y: top, width: Math.max(1, right - left), height: Math.max(1, bottom - top) }
}

if (typeof module !== "undefined") module.exports = { pair: pair, bounds: bounds }
