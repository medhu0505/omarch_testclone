-- Original mpv controller, using Hype's compact surfaces and Omarchy palette.
local assdraw = require 'mp.assdraw'
local opts = {font='JetBrainsMono Nerd Font', hide_timeout=2.5, corner_radius=0,
  surface_mode='gradient', surface_opacity=.55, gradient_inner_opacity=.05, gradient_outer_opacity=.55,
  light_surface_opacity=.92, light_gradient_inner_opacity=.82, light_gradient_outer_opacity=.97}
require('mp.options').read_options(opts, 'omarchy-controls')
local modes={'solid','translucent','gradient'}
local surface_mode=opts.surface_mode
if surface_mode ~= 'solid' and surface_mode ~= 'translucent' and surface_mode ~= 'gradient' then surface_mode='solid' end
local overlay = mp.create_osd_overlay('ass-events')
local palette = {background='#1a1b26', foreground='#c0caf5', accent='#7aa2f7',
  panel='#1e202c', button='#24283b', hover='#293a52', border='#3f4355',
  muted='#838aa8', error='#f7768e'}
local surface_cache={}
local W, H, scale = 960, 620, 1
local regions, seekbar, volume_slider = {}, nil, nil
local mx, my, inside = -1, -1, false
local dragging, pressed, focused, keyboard = false, nil, 1, false
local focused_id='play'
local last_move, visible, pinned = mp.get_time(), true, false
local reveal_until, milliseconds, show_total = mp.get_time()+3, false, true
local volume_feedback_until=0
local render
local input_visible, input_width, input_height
local original_sub_margin=mp.get_property_number('sub-margin-y',24)

local function prop(name, fallback) return mp.get_property_native(name, fallback) end
local function number(name, fallback) return mp.get_property_number(name, fallback or 0) end
local function color(hex) return hex:sub(6,7) .. hex:sub(4,5) .. hex:sub(2,3) end
local function escape(text) return mp.command_native({'escape-ass', tostring(text)}) end
local function light_theme()
  if palette.mode then return palette.mode == 'light' end
  -- Older generated palettes do not carry Omarchy's resolved mode yet.
  local hex=palette.background
  local r,g,b=tonumber(hex:sub(2,3),16),tonumber(hex:sub(4,5),16),tonumber(hex:sub(6,7),16)
  return (r*.2126+g*.7152+b*.0722)/255 > .5
end
local function format_time(t)
  t = math.max(0, math.floor(t or 0))
  if t >= 3600 then return string.format('%d:%02d:%02d', math.floor(t/3600), math.floor(t/60)%60, t%60) end
  return string.format('%02d:%02d', math.floor(t/60), t%60)
end
local function hit(r) return mx >= r.x and mx <= r.x+r.w and my >= r.y and my <= r.y+r.h end
local function menu(name)
  keyboard=false; pinned=false; reveal_until=0; last_move=0
  mp.disable_key_bindings('omarchy-keyboard')
  mp.commandv('script-binding', 'select/' .. name)
end
local function wake() last_move = mp.get_time(); render() end
local function seek_mouse()
  local duration = number('duration')
  if seekbar and duration > 0 then
    local ratio = math.max(0, math.min(1, (mx-seekbar.x)/seekbar.w))
    mp.commandv('seek', ratio*duration, 'absolute+exact')
  end
end
local function volume_mouse()
  if volume_slider then
    local ratio=math.max(0,math.min(1,(mx-volume_slider.x)/volume_slider.w))
    mp.set_property_number('volume',ratio*number('volume-max',130))
  end
end
local function update_drag()
  if dragging == 'seek' then seek_mouse()
  elseif dragging == 'volume-slider' then volume_mouse() end
end
local function select_region()
  for i, r in ipairs(regions) do if hit(r) then return i, r end end
end
local function update_pointer()
  local x,y = mp.get_mouse_pos()
  mx,my = x/scale,y/scale
end
local function down()
  update_pointer()
  keyboard = false
  local i, r = select_region()
  pressed = r and r.id or nil
  if r and (r.id == 'seek' or r.id == 'volume-slider') then dragging=r.id; update_drag() end
  wake()
end
local function up()
  update_pointer()
  local i, r = select_region()
  if not dragging and r and r.id == pressed and r.action then r.action() end
  dragging, pressed = false, nil
  wake()
end
local function scroll(direction)
  update_pointer()
  local _, r = select_region()
  if r and r.id == 'audio' then mp.commandv('cycle','audio', direction > 0 and 'up' or 'down')
  elseif r and r.id == 'subtitles' then mp.commandv('cycle','sub', direction > 0 and 'up' or 'down')
  elseif r and (r.id == 'volume' or r.id == 'volume-slider') then mp.commandv('add', 'volume', direction*5)
  elseif r and r.id == 'speed' then mp.commandv('add', 'speed', direction*.1)
  else mp.commandv('seek', direction*5, 'relative') end
  wake()
end
local function alternate(kind)
  update_pointer()
  local _,r = select_region()
  if not r then return end
  if r.id == 'play' then mp.commandv('cycle-values',kind == 'middle' and 'loop-playlist' or 'loop-file','inf','no')
  elseif r.id == 'volume' or r.id == 'volume-slider' then menu('select-audio-device')
  elseif r.id == 'fullscreen' then mp.commandv('cycle','window-maximized')
  elseif r.id == 'title' then
    if kind == 'middle' then mp.osd_message(mp.get_property('path',''))
    else menu('select-watch-history') end
  elseif r.id == 'prev' or r.id == 'next' or r.id == 'playlist' then menu('select-playlist')
  elseif r.id == 'chapter-prev' or r.id == 'chapter-next' then menu('select-chapter')
  elseif r.id == 'audio' then mp.commandv('cycle','audio','down')
  elseif r.id == 'subtitles' then mp.commandv('cycle','sub','down')
  elseif r.id == 'seek' then
    local duration=number('duration')
    local target=duration*math.max(0,math.min(1,(mx-seekbar.x)/seekbar.w))
    local best,distance
    for _,chapter in ipairs(prop('chapter-list',{})) do
      local delta=math.abs(chapter.time-target)
      if not distance or delta < distance then best,distance=chapter.time,delta end
    end
    if best then mp.commandv('seek',best,'absolute+exact') end
  end
  wake()
end
local mouse_keys = {
  {'MBTN_LEFT', up, down},
  {'MBTN_RIGHT', function() alternate('right') end},
  {'MBTN_MID', function() alternate('middle') end},
  {'Shift+MBTN_LEFT', function() alternate('middle') end},
  {'WHEEL_UP', function() scroll(1) end},
  {'WHEEL_DOWN', function() scroll(-1) end},
}
for _, section in ipairs({'omarchy-footer','omarchy-header'}) do
  mp.set_key_bindings(mouse_keys, section, 'force')
end

local function navigation(step)
  keyboard = true; pinned = true
  for i,r in ipairs(regions) do if r.id == focused_id then focused=i; break end end
  focused = (focused - 1 + step) % math.max(1, #regions) + 1
  if regions[focused] then focused_id=regions[focused].id end
  wake()
end
local function focused_region()
  for _,r in ipairs(regions) do if r.id == focused_id then return r end end
end
local function adjust_focused(direction)
  local r=focused_region()
  if r and (r.id == 'volume' or r.id == 'volume-slider') then mp.commandv('add','volume',direction*5)
  elseif r and r.id == 'speed' then mp.commandv('add','speed',direction*.1)
  else mp.commandv('seek',direction*5,'relative') end
  wake()
end
local function activate()
  local r = focused_region()
  if r and r.action then r.action() end
  wake()
end
mp.set_key_bindings({
  {'TAB', function() navigation(1) end},
  {'Shift+TAB', function() navigation(-1) end},
  {'ENTER', activate},
  {'LEFT',function() adjust_focused(-1) end},
  {'RIGHT',function() adjust_focused(1) end},
  {'ESC', function() keyboard=false; pinned=false; wake() end},
}, 'omarchy-keyboard', 'force')
mp.add_key_binding('a','audio-tracks',function() menu('select-aid') end)
mp.add_key_binding('TAB', 'focus-controls', function()
  keyboard=true; pinned=true; focused=1; focused_id='play'
  for i,r in ipairs(regions) do if r.id == 'play' then focused=i; break end end
  mp.enable_key_bindings('omarchy-keyboard')
  wake()
end)
mp.set_property('osd-font',opts.font)
-- Use this controller's themed sliders instead of mpv's text-colored OSD bar.
mp.set_property_bool('osd-bar',false)
mp.add_key_binding('Ctrl+F9','cycle-transparency',function()
  for i,mode in ipairs(modes) do
    if mode == surface_mode then surface_mode=modes[i%#modes+1]; break end
  end
  reveal_until=mp.get_time()+3
  mp.osd_message('Controls: '..surface_mode)
  wake()
end)
mp.add_key_binding('F10', 'toggle-controls', function() pinned=not pinned; wake() end)
mp.register_script_message('osc-visibility', function(mode)
  pinned = mode == 'always' or (mode == 'cycle' and not pinned)
  wake()
end)

render = function()
  local width, height = mp.get_osd_size()
  if width <= 0 or height <= 0 then return end
  local old_scale = scale
  scale = math.max(.75, math.min(1.6, height/720))
  W, H = width/scale, height/scale
  if scale ~= old_scale then mx, my = -1, -1 end
  local paused = prop('pause', false)
  local header, footer = 48, 112
  local bottom = H-footer
  local near_controls = inside and (my >= bottom-24 or my <= header+12)
  visible = not prop('user-data/mpv/console/open',false) and
    (keyboard or pinned or dragging or prop('idle-active',false) or
    mp.get_time() < reveal_until or near_controls and mp.get_time()-last_move < opts.hide_timeout)
  local sub_margin=visible and original_sub_margin+footer or original_sub_margin
  if number('sub-pos',100) >= 95 and number('sub-margin-y') ~= sub_margin then
    mp.set_property_number('sub-margin-y',sub_margin)
  end
  if prop('user-data/omarchy/surface-mode') ~= surface_mode then
    mp.set_property_native('user-data/omarchy/surface-mode',surface_mode)
  end
  local focus=keyboard and focused_id or ''
  if prop('user-data/omarchy/focused-control') ~= focus then
    mp.set_property_native('user-data/omarchy/focused-control',focus)
  end
  if prop('user-data/omarchy/controls-visible') ~= visible then
    mp.set_property_native('user-data/omarchy/controls-visible',visible)
  end
  if input_width ~= width or input_height ~= height then
    mp.set_mouse_area(0, bottom*scale, width, height, 'omarchy-footer')
    mp.set_mouse_area(0, 0, width, header*scale, 'omarchy-header')
    input_width, input_height = width, height
  end
  if input_visible ~= visible then
    for _, section in ipairs({'omarchy-footer','omarchy-header'}) do
      if visible then mp.enable_key_bindings(section, 'allow-hide-cursor')
      else mp.disable_key_bindings(section) end
    end
    input_visible = visible
  end
  if not keyboard then mp.disable_key_bindings('omarchy-keyboard') end
  if not visible then overlay:remove(); overlay.data=''; return end
  local a = assdraw.ass_new()
  local function box(x,y,w,h,fill,radius,border,opacity,border_opacity)
    local alpha=math.floor((1-math.max(0,math.min(1,opacity or 1)))*255+.5)
    a:new_event(); a:append('{\\pos(0,0)\\an7\\bord0\\shad0\\1c&H'..color(fill)..'&\\1a&H'..string.format('%02X',alpha)..'&}')
    a:draw_start()
    if radius and radius > 0 then a:round_rect_cw(x,y,x+w,y+h,radius)
    else a:rect_cw(x,y,x+w,y+h) end
    a:draw_stop()
    if border then
      -- Thin inset border keeps small buttons crisp at any scale.
      local ba=math.floor((1-math.max(0,math.min(1,border_opacity or 1)))*255+.5)
      a:new_event(); a:append('{\\pos(0,0)\\an7\\bord0\\shad0\\1c&H'..color(border)..'&\\1a&H'..string.format('%02X',ba)..'&}')
      a:draw_start(); a:round_rect_cw(x,y,x+w,y+h,radius or 0)
      a:round_rect_ccw(x+1,y+1,x+w-1,y+h-1,math.max(0,(radius or 0)-1)); a:draw_stop()
    end
  end
  local light=light_theme()
  local uniform_opacity=light and opts.light_surface_opacity or opts.surface_opacity
  local inner_opacity=light and opts.light_gradient_inner_opacity or opts.gradient_inner_opacity
  local outer_opacity=light and opts.light_gradient_outer_opacity or opts.gradient_outer_opacity
  local function surface_opacity(y)
    if surface_mode == 'solid' then return 1 end
    if surface_mode == 'translucent' then return uniform_opacity end
    local fraction=y <= header and 1-y/header or (y-bottom)/footer
    fraction=math.max(0,math.min(1,fraction))
    return inner_opacity+(outer_opacity-inner_opacity)*fraction
  end
  -- Reuse gradient geometry when only the playback clock or slider changes.
  local function cached_surface(slot,key,draw)
    local entry=surface_cache[slot]
    if not entry or entry.key ~= key then
      local target=a
      a=assdraw.ass_new()
      draw()
      entry={key=key,data=a.text}
      surface_cache[slot]=entry
      a=target
    end
    a:new_event(); a:append(entry.data)
  end
  local function gradient_rect(x,y,w,h,fill)
    -- Clip a full rectangle into adjacent bands. Drawing one-pixel shapes
    -- anti-aliases their edges and makes light backgrounds unexpectedly dim.
    local steps=math.ceil(h/2)
    for i=0,steps-1 do
      local y1=math.floor(y+i*h/steps+.5)
      local y2=math.floor(y+(i+1)*h/steps+.5)
      local opacity=surface_opacity((y1+y2)/2)
      local alpha=math.floor((1-math.max(0,math.min(1,opacity)))*255+.5)
      a:new_event()
      a:append(string.format('{\\pos(0,0)\\an7\\bord0\\shad0\\clip(%d,%d,%d,%d)\\1c&H%s&\\1a&H%02X&}',
        math.floor(x),y1,math.ceil(x+w),y2,color(fill),alpha))
      a:draw_start(); a:rect_cw(x,y,x+w,y+h); a:draw_stop()
    end
  end
  local function panel(y,h)
    local key=table.concat({W,H,scale,y,h,palette.panel,surface_mode,
      uniform_opacity,inner_opacity,outer_opacity},':')
    cached_surface(y == 0 and 'top' or 'footer',key,function()
      if surface_mode ~= 'gradient' then
        box(0,y,W,h,palette.panel,nil,nil,surface_opacity(y+h/2))
      else
        gradient_rect(0,y,W,h,palette.panel)
      end
    end)
  end
  local function text(x,y,label,size,fg,align,clip)
    a:new_event(); a:pos(x,y); a:an(align or 4)
    a:append('{\\fn'..opts.font..'\\fs'..size..'\\bord'..((light or surface_mode == 'solid') and '0' or '.6')..'\\3c&H'..color(palette.background)..'&\\shad0\\1a&H00&\\1c&H'..color(fg)..'&}')
    if clip then a:append(string.format('{\\clip(%d,%d,%d,%d)}',math.floor(clip[1]),math.floor(clip[2]),math.ceil(clip[3]),math.ceil(clip[4]))) end
    a:append(escape(label))
  end
  local function lines(x,y,segments,fg)
    a:new_event(); a:append('{\\pos(0,0)\\an7\\bord0\\shad0\\1c&H'..color(fg)..'&}')
    a:draw_start()
    for _, seg in ipairs(segments) do
      local x1,y1,x2,y2 = x+seg[1],y+seg[2],x+seg[3],y+seg[4]
      local dx,dy=x2-x1,y2-y1
      local length=math.sqrt(dx*dx+dy*dy)
      if length > 0 then
        local nx,ny=-dy/length*.8,dx/length*.8
        a:move_to(x1+nx,y1+ny); a:line_to(x2+nx,y2+ny)
        a:line_to(x2-nx,y2-ny); a:line_to(x1-nx,y1-ny)
      end
    end
    a:draw_stop()
  end
  local function icon(x,y,name,fg)
    if name == 'play' then
      a:new_event(); a:append('{\\pos(0,0)\\an7\\bord0\\shad0\\1c&H'..color(fg)..'&}'); a:draw_start()
      a:move_to(x-5,y-7); a:line_to(x+7,y); a:line_to(x-5,y+7); a:draw_stop()
    elseif name == 'pause' then lines(x,y,{{-4,-7,-4,7},{4,-7,4,7}},fg)
    elseif name == 'fullscreen' then lines(x,y,{{-7,-2,-7,-7},{-7,-7,-2,-7},{2,-7,7,-7},{7,-7,7,-2},{7,2,7,7},{7,7,2,7},{-2,7,-7,7},{-7,7,-7,2}},fg)
    elseif name == 'more' then
      for dx=-6,6,6 do box(x+dx-1,y-1,2,2,fg) end
    elseif name == 'prev' or name == 'next' then
      local dir=name == 'prev' and 1 or -1
      lines(x,y,{{dir*4,-6,dir*-3,0},{dir*-3,0,dir*4,6},{dir*-6,-6,dir*-6,6}},fg)
    elseif name == 'playlist' then lines(x,y,{{-7,-5,7,-5},{-7,0,7,0},{-7,5,7,5}},fg)
    elseif name == 'speaker' or name == 'muted' then
      lines(x,y,{{-6,-4,-2,-4},{-2,-4,3,-8},{3,-8,3,8},{3,8,-2,4},{-2,4,-6,4},{-6,4,-6,-4},{7,-4,9,0},{9,0,7,4}},fg)
      if name == 'muted' then lines(x,y,{{-9,9,10,-9}},fg) end
    elseif name == 'audio' then
      lines(x,y,{{-8,3,-8,-2},{-8,-2,-6,-6},{-6,-6,-3,-8},{-3,-8,3,-8},{3,-8,6,-6},{6,-6,8,-2},{8,-2,8,3},
        {-8,1,-4,1},{-4,1,-4,8},{-4,8,-8,8},{-8,8,-8,1},
        {4,1,8,1},{8,1,8,8},{8,8,4,8},{4,8,4,1}},fg)
    elseif name == 'subtitles' then
      lines(x,y,{{-8,-6,8,-6},{8,-6,8,6},{8,6,-8,6},{-8,6,-8,-6},{-5,2,-1,2},{2,2,5,2}},fg)
    elseif name == 'back' or name == 'forward' then
      local dir=name == 'back' and 1 or -1
      lines(x,y,{{dir*5,-5,dir*-2,0},{dir*-2,0,dir*5,5}},fg)
    end
  end
  local function button_surface(id,x,y,w,h,fill,border,hot)
    local key=table.concat({x,y,w,h,scale,fill,border,tostring(hot),opts.corner_radius,
      surface_mode,uniform_opacity,inner_opacity,outer_opacity},':')
    cached_surface('button-'..id,key,function()
      local opacity=surface_opacity(y+h/2)
      local border_opacity=surface_mode == 'solid' and 1 or hot and .9 or math.max(.25,opacity)
      if surface_mode == 'gradient' and not hot and opts.corner_radius == 0 then
        gradient_rect(x,y,w,h,fill)
        box(x,y,w,h,fill,0,border,0,border_opacity)
      else
        box(x,y,w,h,fill,opts.corner_radius,border,hot and math.max(.65,opacity) or opacity,border_opacity)
      end
    end)
  end
  regions={}
  local function button(id,x,y,w,label,glyph,action,active,enabled)
    local r={id=id,x=x,y=y,w=w,h=34,action=enabled ~= false and action or nil}
    regions[#regions+1]=r
    local hot=inside and hit(r) or keyboard and focused_id==id
    local fg=enabled == false and palette.muted or active and palette.accent or palette.foreground
    button_surface(id,x,y,w,34,hot and palette.hover or palette.button,hot and palette.accent or palette.border,hot)
    if glyph then icon(x+(label ~= '' and 18 or w/2),y+17,glyph,fg) end
    if label ~= '' then text(x+(glyph and 33 or w/2),y+17,label,15,fg,glyph and 4 or 5) end
    if hot then
      local help={menu='Menu · history, devices, key bindings, help',prev='Previous playlist entry · Shift+Left',next='Next playlist entry · Shift+Right',play='Play / pause · Space',back='Back 10 seconds · Left',forward='Forward 10 seconds · Right',
        audio='Audio tracks · a',subtitles='Subtitles · j',playlist='Playlist · F8',speed='Playback speed · [ / ]',
        volume='Mute · m, scroll to adjust volume',fullscreen='Fullscreen · f'}
      if help[id] and y > header then
        local tw=math.min(W-24,#help[id]*7.4+20)
        box((W-tw)/2,bottom-34,tw,28,palette.panel,opts.corner_radius,palette.border)
        text(W/2,bottom-20,help[id],12,palette.foreground,5)
      end
    end
  end
  panel(0,header)
  if surface_mode ~= 'gradient' then box(0,header-1,W,1,palette.border) end
  local title_right=W-104
  text(18,header/2,prop('filename',prop('media-title','Drop a video to play')),16,palette.foreground,4,{18,0,title_right,header})
  regions[#regions+1]={id='title',x=18,y=0,w=title_right-18,h=header,action=function() mp.commandv('script-binding','stats/display-page-5') end}
  button('menu',W-91,7,34,'','more',function() menu('menu') end)
  button('fullscreen',W-49,7,34,'','fullscreen',function() mp.commandv('cycle','fullscreen') end)
  panel(bottom,footer)
  if surface_mode ~= 'gradient' then box(0,bottom,W,1,palette.border) end
  local duration=number('duration')
  local time=number('time-pos')
  local sy=bottom+28
  text(18,sy,milliseconds and string.format('%s.%03d',format_time(time),math.floor(time%1*1000)) or format_time(time),13,palette.foreground)
  regions[#regions+1]={id='elapsed',x=0,y=sy-12,w=90,h=24,action=function() milliseconds=not milliseconds end}
  text(W-18,sy,duration > 0 and (show_total and format_time(duration) or '-'..format_time(duration-time)) or 'LIVE',13,palette.muted,6)
  regions[#regions+1]={id='remaining',x=W-90,y=sy-12,w=90,h=24,action=function() show_total=not show_total end}
  local x1,x2=104,W-104
  seekbar={id='seek',x=x1,y=sy-10,w=x2-x1,h=20}
  box(x1,sy-2,x2-x1,4,palette.button,2,nil,surface_opacity(sy))
  local position=duration > 0 and math.max(0,math.min(1,time/duration)) or 0
  if position > 0 then box(x1,sy-2,(x2-x1)*position,4,palette.accent,2) end
  for _, chapter in ipairs(prop('chapter-list',{})) do
    if duration > 0 then box(x1+(x2-x1)*chapter.time/duration,sy-4,1,8,palette.muted) end
  end
  if duration > 0 then
    box(x1+(x2-x1)*position-4,sy-5,8,10,palette.accent,3)
    seekbar.action=seek_mouse; regions[#regions+1]=seekbar
    if inside and hit(seekbar) then text(mx,sy-22,format_time((mx-x1)/(x2-x1)*duration),12,palette.foreground,5) end
  end
  local by=bottom+55
  button('play',18,by,42,'',paused and 'play' or 'pause',function() mp.commandv('cycle','pause') end,true)
  if W >= 620 then
  button('back',68,by,56,'10','back',function() mp.commandv('seek',-10,'relative') end)
  button('forward',132,by,56,'10','forward',function() mp.commandv('seek',10,'relative') end)
  end
  local playlist_count=number('playlist-count')
  if playlist_count > 1 and W >= 980 then
    button('prev',196,by,34,'','prev',function() mp.commandv('playlist-prev') end,false,number('playlist-pos')>0)
    button('next',238,by,34,'','next',function() mp.commandv('playlist-next') end,false,number('playlist-pos')<playlist_count-1)
  end
  if #prop('chapter-list',{}) > 1 and W >= 1200 then
    button('chapter-prev',280,by,34,'','prev',function() mp.commandv('add','chapter',-1) end)
    button('chapter-next',322,by,34,'','next',function() mp.commandv('add','chapter',1) end)
  end
  local compact=W < 850
  local right=W-18
  local fw=compact and 34 or 92
  right=right-fw
  button('playlist',right,by,fw,compact and '' or 'Queue','playlist',function() menu('select-playlist') end)
  right=right-8-(compact and 34 or 84)
  button('subtitles',right,by,compact and 34 or 84,compact and '' or 'Subs','subtitles',function() menu('select-sid') end)
  right=right-8-(compact and 34 or 92)
  button('audio',right,by,compact and 34 or 92,compact and '' or 'Audio','audio',function() menu('select-aid') end)
  if W >= 450 then
  right=right-8-64
  button('speed',right,by,64,string.format('%gx',number('speed',1)),nil,function()
    local speed=number('speed',1); mp.set_property_number('speed',speed>=2 and .5 or speed+.25)
  end)
  end
  local vy=by+17
  local vw=compact and 64 or 88
  local vx=right-8-vw
  local mute_x=W >= 420 and vx-12-34 or right-8-34
  button('volume',mute_x,by,34,'',prop('mute',false) and 'muted' or 'speaker',
    function() mp.commandv('cycle','mute') end,prop('mute',false))
  if W >= 420 then
    volume_slider={id='volume-slider',x=vx,y=by,w=vw,h=34,action=function() mp.commandv('cycle','mute') end}
    regions[#regions+1]=volume_slider
    local ratio=math.max(0,math.min(1,number('volume')/number('volume-max',130)))
    box(vx,vy-2,vw,4,palette.button,1,nil,surface_opacity(vy))
    if ratio > 0 then box(vx,vy-2,vw*ratio,4,palette.accent,1) end
    box(vx+vw*ratio-3,vy-5,6,10,palette.accent,opts.corner_radius)
    if mp.get_time() < volume_feedback_until or dragging == 'volume-slider' or inside and hit(volume_slider) or keyboard and focused_id=='volume-slider' then
      box(vx-8,by-27,vw+16,22,palette.panel,opts.corner_radius,palette.border)
      text(vx+vw/2,by-16,string.format('%d%%',number('volume')),12,palette.foreground,5)
    end
  else volume_slider=nil end
  if prop('idle-active',false) then
    text(W/2,H/2-18,'Drop a video or URL here',21,palette.foreground,5)
    text(W/2,H/2+18,'Space to play · f for fullscreen · Tab for controls',13,palette.muted,5)
  end
  overlay.res_x,overlay.res_y=W,H
  if overlay.data ~= a.text then overlay.data=a.text; overlay:update() end
end

mp.observe_property('mouse-pos','native',function(_,pos)
  if not pos then return end
  local x,y=pos.x/scale,pos.y/scale
  if x ~= mx or y ~= my then last_move=mp.get_time() end
  mx,my,inside=x,y,pos.hover
  if dragging then update_drag() end
  render()
end)
mp.observe_property('user-data/omarchy/theme','native',function(_,colors)
  if colors then
    palette.mode=colors.mode
    for key,value in pairs(colors) do palette[key]=value end
  end
  render()
end)
for _, name in ipairs({'time-pos','pause','duration','mute','speed','fullscreen','media-title','filename',
  'osd-dimensions','idle-active','chapter-list','track-list','playlist-pos','playlist-count','user-data/mpv/console/open'}) do
  mp.observe_property(name,'native',function() render() end)
end
mp.register_event('seek',function()
  reveal_until=mp.get_time()+1.5
  render()
end)
local previous_volume
mp.observe_property('volume','number',function(_,value)
  if previous_volume ~= nil and value ~= previous_volume then
    volume_feedback_until=mp.get_time()+1.5
    reveal_until=volume_feedback_until
  end
  previous_volume=value
  render()
end)
mp.register_event('shutdown',function() mp.set_property_number('sub-margin-y',original_sub_margin) end)
mp.register_event('file-loaded',function() reveal_until=mp.get_time()+3; render() end)
mp.add_periodic_timer(.2,render)
render()
