#!/bin/bash

# Issue #16009: the universal clipboard shortcuts send keysym names ("C", "V",
# "X", "A") to send_key_state, and Hyprland resolves the name against the active
# layout. On a non-Latin layout (us,ru for example) there is no Latin "C"
# keysym, so every press fails with "send_key_state: key not found". The binds
# must send physical keycodes ("code:N") resolved from the configured Latin
# layout instead, so they work under any active layout without sending US
# positions on AZERTY or Dvorak.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command lua

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/.config/omarchy"

have_xkb=0
[[ -r /usr/share/X11/xkb/keycodes/evdev && -r /usr/share/X11/xkb/symbols/fr ]] && have_xkb=1

HAVE_XKB="$have_xkb" HOME="$tmpdir" XDG_CONFIG_HOME="$tmpdir/.config" OMARCHY_PATH="$ROOT" lua - <<'LUA' || fail "universal clipboard shortcuts resolve keycodes from the effective layout"
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path

local config_dir = os.getenv("XDG_CONFIG_HOME") .. "/omarchy"
local sends, binds = {}, {}
local window = { tags = {} }
local config = {}

hl = setmetatable({
  dsp = setmetatable({}, {
    __index = function(_, name)
      return function(arg) return { dsp = name, arg = arg } end
    end,
  }),
  timer = function(fn, opts)
    fn()
  end,
  dispatch = function(dispatcher)
    table.insert(sends, dispatcher)
  end,
  get_active_window = function()
    return window
  end,
  get_config = function(key)
    return config[key]
  end,
}, {
  __index = function()
    return function() return {} end
  end,
})

o = {
  bind = function(keys, description, dispatcher)
    table.insert(binds, { keys = keys, description = description, dispatcher = dispatcher })
  end,
}

local function sends_since(fn)
  local before = #sends
  fn()
  return { table.unpack(sends, before + 1) }
end

local function keys_sent(bind)
  local entries = sends_since(bind.dispatcher)
  local keys = {}
  for _, entry in ipairs(entries) do
    local arg = entry.arg
    table.insert(keys, arg.key .. "@" .. arg.state)
    assert(arg.mods, "every send carries explicit mods")
  end
  return keys, entries
end

local function write_layout(content)
  local file = assert(io.open(config_dir .. "/keyboard-layouts", "w"))
  file:write(content)
  file:close()
end

local function check_binds(name, expected)
  local by_description = {}
  for _, bind in ipairs(binds) do
    by_description[bind.description] = bind
  end

  for description, want in pairs(expected) do
    local label = name .. " " .. description
    local bind = by_description[description]
    assert(bind, label .. " is bound")

    window.tags = {}
    local keys, entries = keys_sent(bind)
    assert(#keys == 2, label .. " sends a down and an up")
    assert(keys[1] == want.key .. "@down" and keys[2] == want.key .. "@up",
      label .. " sends " .. want.key .. " (got " .. keys[1] .. ", " .. keys[2] .. ")")
    assert(entries[1].arg.mods == want.mods and entries[2].arg.mods == want.mods,
      label .. " sends " .. want.mods)

    window.tags = { "terminal*" }
    local terminal_mods = want.terminal_mods or want.mods
    keys, entries = keys_sent(bind)
    assert(#keys == 2, label .. " sends a down and an up to terminals")
    assert(keys[1] == want.key .. "@down" and keys[2] == want.key .. "@up",
      label .. " keeps the same keycode for terminals (got " .. keys[1] .. ", " .. keys[2] .. ")")
    assert(entries[1].arg.mods == terminal_mods and entries[2].arg.mods == terminal_mods,
      label .. " sends " .. terminal_mods .. " to terminals")
  end
end

local function check_layout(name, layout_config, expected)
  config = {}
  write_layout(layout_config)
  binds = {}
  package.loaded["default.hypr.bindings.clipboard"] = nil
  require("default.hypr.bindings.clipboard")
  check_binds(name, expected)
end

check_layout("US", "XKBLAYOUT=us,ru\n", {
  ["Select all"] = { mods = "CTRL", key = "code:38" },
  ["Universal copy"] = { mods = "CTRL", key = "code:54", terminal_mods = "CTRL SHIFT" },
  ["Universal paste"] = { mods = "CTRL", key = "code:55", terminal_mods = "CTRL SHIFT" },
  ["Universal cut"] = { mods = "CTRL", key = "code:53" },
})

-- The AZERTY and Dvorak cases read the layouts from xkeyboard-config.
if os.getenv("HAVE_XKB") ~= "1" then
  print("ok - AZERTY and Dvorak clipboard keycodes # SKIP xkeyboard-config not installed")
  return
end

-- On AZERTY, A is <AD01> (code:24) and <AC01> (code:38) is Q, so Super + A
-- must send code:24 rather than Ctrl + Q.
local azerty_expected = {
  ["Select all"] = { mods = "CTRL", key = "code:24" },
  ["Universal copy"] = { mods = "CTRL", key = "code:54", terminal_mods = "CTRL SHIFT" },
  ["Universal paste"] = { mods = "CTRL", key = "code:55", terminal_mods = "CTRL SHIFT" },
  ["Universal cut"] = { mods = "CTRL", key = "code:53" },
}

local dvorak_expected = {
  ["Select all"] = { mods = "CTRL", key = "code:38" },
  ["Universal copy"] = { mods = "CTRL", key = "code:31", terminal_mods = "CTRL SHIFT" },
  ["Universal paste"] = { mods = "CTRL", key = "code:60", terminal_mods = "CTRL SHIFT" },
  ["Universal cut"] = { mods = "CTRL", key = "code:56" },
}

check_layout("AZERTY", "XKBLAYOUT=fr,ru\n", azerty_expected)
check_layout("Dvorak", "XKBLAYOUT=us\nXKBVARIANT=dvorak\n", dvorak_expected)

-- Personal overrides in ~/.config/hypr/input.lua are loaded after Omarchy
-- defaults, so hl.get_config("input.kb_layout") / "input.kb_variant" must take
-- precedence over keyboard-layouts at key-press time and react to later changes.
config = {}
write_layout("XKBLAYOUT=us\n")
binds = {}
package.loaded["default.hypr.bindings.clipboard"] = nil
require("default.hypr.bindings.clipboard")

config["input.kb_layout"] = "fr,us"
check_binds("AZERTY override", azerty_expected)

config["input.kb_layout"] = "us"
config["input.kb_variant"] = "dvorak"
check_binds("Dvorak override after load", dvorak_expected)
LUA

# The keycode strings never regress to layout-resolved keysym names.
if grep -E 'send_shortcut_once\([^)]*"[A-Z]"' "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../../default/hypr/bindings/clipboard.lua" >/dev/null; then
  fail "universal clipboard shortcuts send keycodes, not layout-resolved key names"
fi
pass "universal clipboard shortcuts send layout-independent keycodes"
