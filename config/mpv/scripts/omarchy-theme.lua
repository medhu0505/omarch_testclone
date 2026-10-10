-- Reload Omarchy's generated palette without restarting playback.
-- The custom controller observes user-data; built-in menus observe script-opts.
local msg = require 'mp.msg'
local options = {theme_file = '~/.local/state/omarchy/current/theme/mpv-theme.conf'}
require('mp.options').read_options(options, 'omarchy-theme')
local path = mp.command_native({'expand-path', options.theme_file})
local last_contents, last_warning
local palette_keys = {background=true, foreground=true, accent=true, panel=true,
  button=true, hover=true, border=true, muted=true, error=true}
local native_colors = {
  ['osd-color'] = true,
  ['osd-back-color'] = true,
  ['osd-outline-color'] = true,
  ['osd-selected-color'] = true,
  ['osd-selected-outline-color'] = true,
}

local script_color_keys = {
  ['console-menu_outline_color'] = true,
  ['console-focused_color'] = true,
  ['console-focused_back_color'] = true,
  ['console-match_color'] = true,
  ['context_menu-menu_outline_color'] = true,
  ['context_menu-focused_color'] = true,
  ['context_menu-focused_back_color'] = true,
  ['context_menu-disabled_color'] = true,
  ['stats-font_color'] = true,
  ['stats-border_color'] = true,
  ['stats-shadow_color'] = true,
  ['stats-plot_color'] = true,
  ['stats-plot_bg_color'] = true,
  ['stats-plot_bg_border_color'] = true,
}

local function warn_once(message)
  if message ~= last_warning then msg.warn(message) end
  last_warning = message
end

local function reload_theme()
  -- Omarchy swaps the theme directory during a switch. Keep the previous
  -- palette if the file is temporarily missing or not fully generated.
  local file = io.open(path, 'r')
  if not file then return end
  local contents = file:read('*a')
  file:close()
  if contents == last_contents then return end

  local script_colors, osd_colors, palette = {}, {}, {}
  for line in contents:gmatch('[^\r\n]+') do
    if not line:match('^%s*#') and not line:match('^%s*$') then
      local key, value = line:match('^%s*([%w_%-]+)%s*=%s*(%S+)%s*$')
      local script = key and key:match('^([%w_]+)%-[%w_]+$')
      if key == 'mode' and (value == 'light' or value == 'dark') then
        palette.mode=value
      elseif not value or not value:match('^#%x%x%x%x%x%x$') then
        warn_once('Ignoring incomplete or invalid Omarchy palette: ' .. path)
        return
      elseif palette_keys[key] then
        palette[key] = value
      elseif native_colors[key] then
        osd_colors[key] = value
      elseif script_color_keys[key] then
        script_colors[key] = script == 'stats' and
          (value:sub(6,7)..value:sub(4,5)..value:sub(2,3)) or value
      else
        warn_once('Ignoring incomplete or invalid Omarchy palette: ' .. path)
        return
      end
    end
  end
  for key in pairs(palette_keys) do
    if not palette[key] then
      warn_once('Ignoring incomplete Omarchy palette: ' .. path)
      return
    end
  end
  for key in pairs(native_colors) do
    if not osd_colors[key] then
      warn_once('Ignoring incomplete Omarchy palette: ' .. path)
      return
    end
  end

  for key in pairs(script_color_keys) do
    if not script_colors[key] then
      warn_once('Ignoring incomplete Omarchy palette: ' .. path)
      return
    end
  end

  -- Preserve layout settings and options belonging to other scripts.
  local script_opts = mp.get_property_native('script-opts', {})
  for key, value in pairs(script_colors) do script_opts[key] = value end
  mp.set_property_native('script-opts', script_opts)
  mp.set_property_native('user-data/omarchy/theme', palette)
  for key, value in pairs(osd_colors) do mp.set_property(key, value) end
  last_contents, last_warning = contents, nil
  msg.verbose('Applied Omarchy palette from ' .. path)
end

reload_theme()
-- mpv has no portable file-watcher API. Read this small local file once per
-- second, even while paused, and update properties only when it changes.
mp.add_periodic_timer(1, reload_theme)
mp.register_event('file-loaded', reload_theme)
mp.register_script_message('reload-omarchy-theme', reload_theme)
