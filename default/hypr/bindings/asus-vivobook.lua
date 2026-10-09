-- M5606UA firmware reports the emoji key as KEY_BLUETOOTH, the microphone
-- mode key as F14, and MyASUS as KEY_PROG1. Restrict these meanings to the
-- tested model so a Bluetooth key on another laptop keeps its own meaning.
local function read_dmi(name)
  local file = io.open("/sys/class/dmi/id/" .. name, "r")
  if not file then
    return ""
  end
  local value = file:read("*l") or ""
  file:close()
  return value
end

if read_dmi("sys_vendor") == "ASUSTeK COMPUTER INC."
    and read_dmi("product_name") == "ASUS Vivobook S 16 M5606UA_M5606UA" then
  o.bind("XF86Bluetooth", "Emojis", { panel = "omarchy.emojis" })
  -- KEY_F14 is XKB code 192; the default keysym is XF86Launch5.
  -- Expose Linux audio controls; ASUS Windows microphone algorithms are not available here.
  o.bind("code:192", "Microphone settings", { panel = "omarchy.audio" })
  o.bind("XF86Launch1", "Laptop hardware", { menu = "hardware" })
end
