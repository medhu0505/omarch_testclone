local keyboard = require("default.hypr.keyboard")

-- Send with explicit mods to the focused surface by omitting the window target,
-- so universal clipboard shortcuts reach both normal windows and focused
-- layer-shell surfaces such as Omarchy panels. A virtual keyboard (wtype) won't
-- do: the physically held SUPER merges into the injected chord at the seat.
-- The down/up split works around Hyprland send_shortcut sometimes leaving
-- synthetic key state stuck/repeating.
-- https://github.com/hyprwm/Hyprland/discussions/14099
local function send_shortcut_once(mods, key_or_resolver)
  return function()
    -- Resolve at press time so layout overrides loaded later take effect.
    local key = type(key_or_resolver) == "function" and key_or_resolver() or key_or_resolver
    hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "down" }))

    hl.timer(function()
      hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "up" }))
    end, { timeout = 50, type = "oneshot" })
  end
end

-- Lean on the terminal tag from default/hypr/apps/terminals.lua so there's one
-- definition of what counts as a terminal. Dynamic tags carry a trailing "*".
local function active_window_is_terminal()
  local window = hl.get_active_window()
  if not window then
    return false
  end

  for _, tag in ipairs(window.tags or {}) do
    if tag:gsub("%*$", "") == "terminal" then
      return true
    end
  end

  return false
end

local function universal_clipboard_shortcut(default_mods, default_key, terminal_mods, terminal_key)
  return function()
    if active_window_is_terminal() then
      send_shortcut_once(terminal_mods, terminal_key)()
    else
      send_shortcut_once(default_mods, default_key)()
    end
  end
end

-- Keys are sent as physical keycodes ("code:N", evdev keycode + 8, the same
-- convention the other bindings files use). A keysym name is resolved against
-- the active layout, so on a non-Latin layout (us,ru for example) there is no
-- Latin "C" keysym and send_key_state fails with "key not found". Keycodes
-- work under every layout; resolve them from the configured Latin layout so
-- layouts like AZERTY and Dvorak send their own A/C/V/X keys rather than US
-- positions.
-- https://github.com/omacom/omarchy/issues/16009
local us_keycodes = {
  A = "code:38",
  C = "code:54",
  V = "code:55",
  X = "code:53",
}

local keycodes_by_layout = {}

local function configured_option(name)
  local value = hl.get_config and hl.get_config(name)
  if type(value) == "string" and value ~= "" then
    return value
  end
end

local function layout_keycodes()
  local kb_layout = configured_option("input.kb_layout")
  local kb_variant = configured_option("input.kb_variant")
  local selected = (not kb_layout or not kb_variant) and keyboard.selected() or {}
  local layout = (kb_layout or selected.XKBLAYOUT or "us"):match("^[^,]*")
  local variant = (kb_variant or selected.XKBVARIANT or ""):match("^[^,]*")
  if layout == "" or (layout == "us" and variant == "") then
    return us_keycodes
  end

  local cache_key = layout .. ":" .. variant
  if keycodes_by_layout[cache_key] then
    return keycodes_by_layout[cache_key]
  end

  local keycodes = {}
  local evdev = io.open("/usr/share/X11/xkb/keycodes/evdev", "r")
  if evdev then
    for line in evdev:lines() do
      local name, code = line:match("^%s*<([%w_]+)>%s*=%s*(%d+)%s*;")
      if name then keycodes[name] = tonumber(code) end
    end
    evdev:close()
  end

  local symbols, seen = {}, {}
  local function load_symbols(file_name, section_name)
    if not file_name or not file_name:match("^[%w_%-]+$") then return end
    local id = file_name .. ":" .. (section_name or "")
    if seen[id] then return end
    seen[id] = true

    local file = io.open("/usr/share/X11/xkb/symbols/" .. file_name, "r")
    if not file then return end
    local content = file:read("*a"):gsub("//[^\n]*", ""):gsub("/%*.-%*/", "")
    file:close()

    local body
    for header, name, block in content:gmatch('([%w_%s]-)xkb_symbols%s+"([^"]+)"%s*(%b{})') do
      if section_name then
        if name == section_name then body = block; break end
      elseif header:find("default") or not body then
        body = block
        if header:find("default") then break end
      end
    end
    if not body then return end

    for statement in body:sub(2, -2):gsub('(include%s+"[^"]+")', "%1;"):gmatch("[^;]+") do
      for include in statement:gmatch('include%s+"([^"]+)"') do
        local inc_file, inc_section = include:match("^([^(]+)%(([^)]+)%)$")
        load_symbols(inc_file or include, inc_section)
      end
      local key_name, symbol = statement:gsub("[%w_]+%s*%b[]%s*=", ""):match("key%s*<([%w_]+)>%s*{.-%[%s*([%w_]+)")
      if key_name and symbol and symbol ~= "any" and symbol ~= "NoSymbol" then
        symbols[key_name] = symbol:upper()
      end
    end
  end

  load_symbols(layout, variant ~= "" and variant or nil)
  if not next(keycodes) or not next(symbols) then
    keycodes_by_layout[cache_key] = { A = "A", C = "C", V = "V", X = "X" }
    return keycodes_by_layout[cache_key]
  end

  local by_symbol = {}
  for key_name, symbol in pairs(symbols) do
    local code = keycodes[key_name]
    if code and (not by_symbol[symbol] or code < by_symbol[symbol]) then
      by_symbol[symbol] = code
    end
  end

  local resolved = {}
  for symbol, fallback in pairs(us_keycodes) do
    resolved[symbol] = by_symbol[symbol] and ("code:" .. by_symbol[symbol]) or fallback
  end
  keycodes_by_layout[cache_key] = resolved
  return resolved
end

local function layout_keycode(symbol)
  return function()
    return layout_keycodes()[symbol]
  end
end

local SELECT_ALL_KEYCODE = layout_keycode("A")
local COPY_KEYCODE = layout_keycode("C")
local PASTE_KEYCODE = layout_keycode("V")
local CUT_KEYCODE = layout_keycode("X")

o.bind("SUPER + A", "Select all", send_shortcut_once("CTRL", SELECT_ALL_KEYCODE))
o.bind("SUPER + C", "Universal copy", universal_clipboard_shortcut("CTRL", COPY_KEYCODE, "CTRL SHIFT", COPY_KEYCODE))
o.bind("SUPER + V", "Universal paste", universal_clipboard_shortcut("CTRL", PASTE_KEYCODE, "CTRL SHIFT", PASTE_KEYCODE))
o.bind("SUPER + X", "Universal cut", send_shortcut_once("CTRL", CUT_KEYCODE))
o.bind("SUPER + CTRL + V", "Clipboard manager", { panel = "omarchy.clipboard" })
