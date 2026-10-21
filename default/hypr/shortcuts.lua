-- Named shortcuts that apps change through `omarchy shortcut set` instead of
-- editing Hyprland config. Omarchy declares its own with o.shortcut; apps
-- register theirs from the CLI. Each one's keys, description, and commands
-- live as data in ~/.config/omarchy/shortcuts/<id>, one `field=value` per line,
-- and are never loaded as Lua: they come from other programs.
--
-- o.shortcuts.apply() binds them all after Omarchy's defaults, taking their
-- keys from any default bound there. The CLI calls it live through
-- `hyprctl eval`, and asks o.shortcuts.snapshot(path) for what is bound.

local paths = require("default.hypr.paths")

o.shortcuts = { declared = {}, order = {}, bound = {}, current = {} }

local registry = paths.config_home .. "/omarchy/shortcuts"

local MODIFIERS = { CONTROL = "CTRL", MOD1 = "ALT", WIN = "SUPER", LOGO = "SUPER", MOD4 = "SUPER" }
local MODIFIER_KEYS = { ALT = true, SUPER = true, CONTROL = true, SHIFT = true, META = true, HYPER = true }

-- A modifier pressed on its own changes the modifier mask between its press
-- and release, so it only matches with the mask ignored.
local function modifier_key(key)
  local name = key:match("^(%u+)_[LR]$")
  return (name and MODIFIER_KEYS[name]) or key == "ISO_LEVEL3_SHIFT"
end

-- A chord as Hyprland matches it: modifiers sorted and case folded, so
-- "SUPER + ctrl + x" and "CTRL + SUPER + X" are the same keys, and a modifier
-- key alone reduces to that key. bin/omarchy-shortcut-functions matches this.
local function normalize(keys)
  local parts = {}
  for raw in keys:gmatch("[^+]+") do
    local part = raw:match("^%s*(.-)%s*$"):upper()
    if part ~= "" then
      table.insert(parts, part)
    end
  end

  local key = table.remove(parts) or ""
  if modifier_key(key) then
    return key
  end
  for index, modifier in ipairs(parts) do
    parts[index] = MODIFIERS[modifier] or modifier
  end
  table.sort(parts)
  table.insert(parts, key)

  return table.concat(parts, "+")
end

o.shortcuts.normalize = normalize

local function as_list(keys)
  if type(keys) == "table" then
    return keys
  elseif keys and keys ~= "" then
    return { keys }
  end

  return {}
end

-- Declare an Omarchy shortcut with its default keys. A user's or app's choice
-- in the registry replaces the keys when the shortcuts are applied.
--   o.shortcut("omarchy.dictation.toggle", {
--     description = "Toggle dictation",
--     keys = "SUPER + CTRL + X",
--     command = "omarchy-dictation toggle",
--   })
-- A `release` command makes it a hold: command on press, release on release.
function o.shortcut(id, spec)
  if not o.shortcuts.declared[id] then
    table.insert(o.shortcuts.order, id)
  end

  o.shortcuts.declared[id] = {
    description = spec.description,
    release_description = spec.release_description,
    command = spec.command,
    release = spec.release,
    keys = as_list(spec.keys),
  }
end

local function read_entry(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end

  local entry = { keys = {} }
  for line in file:lines() do
    local field, value = line:match("^([%w_]+)=(.*)$")
    if field == "keys" then
      entry.has_keys = true
      if value ~= "" then
        table.insert(entry.keys, value)
      end
    elseif field == "description" or field == "release_description" or field == "command" or field == "release" then
      entry[field] = value
    end
  end
  file:close()

  return entry
end

local function registered_ids()
  local ids = {}
  local handle = io.popen("find " .. o.shell_quote(registry) .. " -maxdepth 1 -type f -printf '%f\\n' 2>/dev/null | sort")
  if handle then
    for id in handle:lines() do
      if id:match("^[%w][%w._-]*$") then
        table.insert(ids, id)
      end
    end
    handle:close()
  end

  return ids
end

-- Every shortcut with the registry laid over Omarchy's declarations, in
-- declaration order and then by id.
local function resolve()
  local shortcuts, seen = {}, {}

  local function add(id, declared, entry)
    local shortcut = { id = id, source = declared and "omarchy" or "app", default_keys = declared and declared.keys or nil }
    for _, field in ipairs({ "description", "release_description", "command", "release" }) do
      shortcut[field] = declared and declared[field] or entry and entry[field] or nil
    end
    -- Apps name and run their own shortcuts; Omarchy's only take new keys.
    shortcut.description = shortcut.description or id
    shortcut.keys = (entry and entry.has_keys) and entry.keys or (declared and declared.keys) or {}
    shortcut.changed = entry ~= nil and entry.has_keys == true
    table.insert(shortcuts, shortcut)
    seen[id] = true
  end

  local entries = {}
  for _, id in ipairs(registered_ids()) do
    entries[id] = read_entry(registry .. "/" .. id)
  end

  for _, id in ipairs(o.shortcuts.order) do
    add(id, o.shortcuts.declared[id], entries[id])
  end
  for id, entry in pairs(entries) do
    if not seen[id] then
      add(id, nil, entry)
    end
  end
  table.sort(shortcuts, function(a, b)
    if (a.source == "omarchy") ~= (b.source == "omarchy") then
      return a.source == "omarchy"
    end
    return a.id < b.id
  end)

  return shortcuts
end

local function json_string(value)
  return '"' .. tostring(value):gsub('[%c"\\]', function(char)
    local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r" }
    return escapes[char] or string.format("\\u%04x", char:byte())
  end) .. '"'
end

local function json_list(values)
  local items = {}
  for _, value in ipairs(values) do
    table.insert(items, json_string(value))
  end
  return "[" .. table.concat(items, ",") .. "]"
end

-- Write every shortcut as JSON to path: what it binds now, its default, and
-- what runs, for `omarchy shortcut get` and `list`.
function o.shortcuts.snapshot(path)
  local items = {}
  for _, shortcut in ipairs(o.shortcuts.current) do
    local fields = {
      '"id":' .. json_string(shortcut.id),
      '"source":' .. json_string(shortcut.source),
      '"keys":' .. json_list(shortcut.keys),
      '"bound":' .. json_list(shortcut.bound or {}),
      '"changed":' .. tostring(shortcut.changed),
    }
    for _, field in ipairs({ "description", "release_description", "command", "release" }) do
      if shortcut[field] then
        table.insert(fields, '"' .. field .. '":' .. json_string(shortcut[field]))
      end
    end
    if shortcut.default_keys then
      table.insert(fields, '"default_keys":' .. json_list(shortcut.default_keys))
    end
    table.insert(items, "{" .. table.concat(fields, ",") .. "}")
  end

  local file = assert(io.open(path, "w"))
  file:write("[" .. table.concat(items, ",\n") .. "]\n")
  file:close()
end

-- Bind every shortcut, replacing what the previous apply bound. Moving a
-- shortcut off keys it took from a default needs a full reload to bring that
-- default back, since only the config knows what it was.
function o.shortcuts.apply()
  local shortcuts = resolve()

  local wanted = {}
  for _, shortcut in ipairs(shortcuts) do
    if shortcut.command then
      for _, keys in ipairs(shortcut.keys) do
        wanted[normalize(keys)] = true
      end
    end
  end
  local defaults = {}
  for keys in pairs(o.bound_keys) do
    defaults[normalize(keys)] = true
  end
  for chord, keys in pairs(o.shortcuts.bound) do
    if not wanted[chord] and defaults[chord] then
      hl.exec_cmd("hyprctl reload")
      return
    end
    hl.unbind(keys)
  end
  o.shortcuts.bound = {}

  o.shortcuts.binding = true
  for _, shortcut in ipairs(shortcuts) do
    shortcut.bound = {}
    for _, keys in ipairs(shortcut.command and shortcut.keys or {}) do
      local chord = normalize(keys)
      if not o.shortcuts.bound[chord] then
        hl.unbind(keys)
        local options = modifier_key(normalize(keys)) and { ignore_mods = true } or nil
        if shortcut.release then
          o.bind_hold(keys, shortcut.description, shortcut.command, shortcut.release_description or shortcut.description, shortcut.release, options)
        else
          o.bind(keys, shortcut.description, shortcut.command, options)
        end
        o.shortcuts.bound[chord] = keys
        table.insert(shortcut.bound, keys)
      end
    end
  end
  o.shortcuts.binding = false
  o.shortcuts.current = shortcuts
end
