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

local normalize, modifier_key = o.chord, o.modifier_key

-- Hyprland reads hl.unbind("all") as removing every binding, and "catchall"
-- binds every key in a submap, so neither ever comes from the registry.
local RESERVED_KEYS = { ALL = true, CATCHALL = true }

local function valid_keys(keys)
  return not RESERVED_KEYS[normalize(keys):match("([^+]*)$")]
end

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

-- Bind shortcuts. As the config loads, with no ids, every shortcut is bound.
-- Live, the CLI names the ids it changed, and only those are rebound: every
-- other shortcut stays as it is, along with anything a dictation backend or the
-- user unbound since. Moving a shortcut off keys it took from a default needs a
-- full reload to bring that default back, since only the config knows it.
function o.shortcuts.apply(ids)
  local shortcuts = resolve()

  local changed = nil
  if ids then
    changed = {}
    for _, id in ipairs(ids) do
      changed[id] = true
    end
  end
  local function rebinding(id)
    return changed == nil or changed[id] == true
  end

  local previous = {}
  for _, shortcut in ipairs(o.shortcuts.current) do
    previous[shortcut.id] = shortcut
  end

  local wanted = {}
  for _, shortcut in ipairs(shortcuts) do
    if shortcut.command and rebinding(shortcut.id) then
      for _, keys in ipairs(shortcut.keys) do
        wanted[normalize(keys)] = valid_keys(keys) or nil
      end
    end
  end
  for chord, owner in pairs(o.shortcuts.bound) do
    if rebinding(owner.id) and not wanted[chord] and o.bound_keys[chord] then
      hl.exec_cmd("hyprctl reload")
      return
    end
  end
  for chord, owner in pairs(o.shortcuts.bound) do
    if rebinding(owner.id) then
      hl.unbind(owner.keys)
      o.shortcuts.bound[chord] = nil
    end
  end

  o.shortcuts.binding = true
  for _, shortcut in ipairs(shortcuts) do
    if not rebinding(shortcut.id) then
      shortcut.bound = previous[shortcut.id] and previous[shortcut.id].bound or {}
    else
      shortcut.bound = {}
      for _, keys in ipairs(shortcut.command and shortcut.keys or {}) do
        local chord = normalize(keys)
        if valid_keys(keys) and not o.shortcuts.bound[chord] then
          -- Hyprland unbinds by the text a binding was made with, so a default
          -- spelled "SUPER + CTRL + X" survives an unbind of "CTRL + SUPER + X".
          for spelling in pairs(o.bound_keys[chord] or {}) do
            hl.unbind(spelling)
          end
          hl.unbind(keys)
          local options = modifier_key(chord:match("([^+]*)$")) and { ignore_mods = true } or nil
          if shortcut.release then
            o.bind_hold(keys, shortcut.description, shortcut.command, shortcut.release_description or shortcut.description, shortcut.release, options)
          else
            o.bind(keys, shortcut.description, shortcut.command, options)
          end
          o.shortcuts.bound[chord] = { id = shortcut.id, keys = keys }
          table.insert(shortcut.bound, keys)
        end
      end
    end
  end
  o.shortcuts.binding = false
  o.shortcuts.current = shortcuts
end
