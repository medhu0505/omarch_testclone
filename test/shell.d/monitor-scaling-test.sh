#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
home_dir="$test_tmp/home"
monitor_lua="$home_dir/.config/hypr/monitors.lua"
scale_log="$home_dir/.local/state/omarchy/monitor-scaling.log"
saved_scales="$home_dir/.local/state/omarchy/toggles/hypr/monitor-scales"

mkdir -p "$stub_bin" "$home_dir/.config/hypr"

cat >"$stub_bin/hyprctl" <<'SH'
#!/bin/bash

if [[ $1 == "monitors" && $2 == "-j" ]]; then
  printf '[{"name":"eDP-1","description":"%s","focused":true,"scale":%s,"width":%s,"height":%s,"refreshRate":120.0,"x":1920,"y":0,"transform":3}]' \
    "${OMARCHY_TEST_MONITOR_DESC:-}" "${OMARCHY_TEST_MONITOR_SCALE:-2}" "${OMARCHY_TEST_MONITOR_WIDTH:-2880}" "${OMARCHY_TEST_MONITOR_HEIGHT:-1800}"
elif [[ $1 == "reload" ]]; then
  :
else
  exit 1
fi
SH
chmod +x "$stub_bin/hyprctl"

write_monitor_config() {
  cat >"$monitor_lua" <<'LUA'
local omarchy_gdk_scale = 2
local omarchy_monitor_scale = 2
LUA
}

saved_scale() {
  awk -F '\t' -v name="${1:-eDP-1}" '$2 == name { print $1 }' "$saved_scales"
}

run_scaling() {
  HOME="$home_dir" \
    XDG_STATE_HOME="$home_dir/.local/state" \
    PATH="$stub_bin:$PATH" \
    OMARCHY_TEST_MONITOR_SCALE="${OMARCHY_TEST_MONITOR_SCALE:-2}" \
    "$ROOT/bin/omarchy-hyprland-monitor-scaling" "$@"
}

write_monitor_config
OMARCHY_TEST_MONITOR_SCALE=2 run_scaling up
[[ $(saved_scale) == "3" ]] || fail "monitor scaling up reaches 3x"
[[ $(saved_scale) == "3" ]] || fail "monitor scaling up persists 3x"
grep -F $'requested=up\tcurrent=2\tnew=3\tmonitor=eDP-1' "$scale_log" >/dev/null || fail "monitor scaling up writes audit log"
pass "monitor scaling up reaches 3x"

write_monitor_config
OMARCHY_TEST_MONITOR_SCALE=3 run_scaling down
[[ $(saved_scale) == "2" ]] || fail "monitor scaling down recovers 3x to 2x"
[[ $(saved_scale) == "2" ]] || fail "monitor scaling down persists 2x from 3x"
pass "monitor scaling down recovers 3x to 2x"

write_monitor_config
OMARCHY_TEST_MONITOR_SCALE=3.0000000000000004 run_scaling down
[[ $(saved_scale) == "2" ]] || fail "monitor scaling down snaps floating point 3x to 2x"
[[ $(saved_scale) == "2" ]] || fail "monitor scaling down persists 2x from floating point 3x"
pass "monitor scaling down snaps floating point 3x to 2x"

write_monitor_config
OMARCHY_TEST_MONITOR_SCALE=2 run_scaling 3
[[ $(saved_scale) == "3" ]] || fail "monitor scaling explicit 3x remains available"
[[ $(saved_scale) == "3" ]] || fail "monitor scaling explicit 3x persists"
grep -Fx 'local omarchy_gdk_scale = 3' "$monitor_lua" >/dev/null || fail "monitor scaling explicit 3x persists GDK scale"
pass "monitor scaling explicit 3x remains available"

# GTK only honors integer GDK_SCALE, so fractional monitor scales persist a
# rounded GDK scale.
write_monitor_config
OMARCHY_TEST_MONITOR_SCALE=2 run_scaling 1.6
[[ $(saved_scale) == "1.6" ]] || fail "monitor scaling explicit 1.6x remains available"
[[ $(saved_scale) == "1.6" ]] || fail "monitor scaling explicit 1.6x persists"
grep -Fx 'local omarchy_gdk_scale = 2' "$monitor_lua" >/dev/null || fail "monitor scaling 1.6x persists integer GDK scale 2"
pass "monitor scaling 1.6x persists integer GDK scale 2"

write_monitor_config
OMARCHY_TEST_MONITOR_SCALE=2 run_scaling 1.25
[[ $(saved_scale) == "1.25" ]] || fail "monitor scaling explicit 1.25x persists"
grep -Fx 'local omarchy_gdk_scale = 1' "$monitor_lua" >/dev/null || fail "monitor scaling 1.25x persists integer GDK scale 1"
pass "monitor scaling 1.25x persists integer GDK scale 1"

scale=$(OMARCHY_TEST_MONITOR_SCALE=3 run_scaling)
[[ $scale == "3" ]] || fail "monitor scaling reports explicit 3x scale" "actual: $scale"
pass "monitor scaling reports explicit 3x scale"

scale=$(OMARCHY_TEST_MONITOR_SCALE=3.2 run_scaling)
[[ $scale == "3.2" ]] || fail "monitor scaling reports the actual non-preset scale" "actual: $scale"
pass "monitor scaling reports the actual non-preset scale"

# 1280x800 approximates the 3x preset as 3.2x.
write_monitor_config
OMARCHY_TEST_MONITOR_SCALE=2 OMARCHY_TEST_MONITOR_WIDTH=1280 OMARCHY_TEST_MONITOR_HEIGHT=800 run_scaling 3
[[ $(saved_scale) == "3.2" ]] || fail "monitor scaling approximates explicit 3x as 3.2x"
[[ $(saved_scale) == "3.2" ]] ||
  fail "monitor scaling persists approximated 3.2x"
pass "monitor scaling approximates explicit 3x as 3.2x"

write_monitor_config
OMARCHY_TEST_MONITOR_SCALE=2 OMARCHY_TEST_MONITOR_WIDTH=1280 OMARCHY_TEST_MONITOR_HEIGHT=800 run_scaling up
[[ $(saved_scale) == "3.2" ]] || fail "monitor scaling up reaches approximated 3.2x"
pass "monitor scaling up reaches approximated 3.2x"

write_monitor_config
OMARCHY_TEST_MONITOR_SCALE=4 OMARCHY_TEST_MONITOR_WIDTH=1280 OMARCHY_TEST_MONITOR_HEIGHT=800 run_scaling down
[[ $(saved_scale) == "3.2" ]] || fail "monitor scaling down reaches approximated 3.2x"
pass "monitor scaling down reaches approximated 3.2x"

write_monitor_config
OMARCHY_TEST_MONITOR_SCALE=2 OMARCHY_TEST_MONITOR_WIDTH=6016 OMARCHY_TEST_MONITOR_HEIGHT=3384 run_scaling 1.25
[[ $(saved_scale) == "1.33333" ]] || fail "monitor scaling approximates explicit 1.25x"
pass "monitor scaling approximates explicit 1.25x"

write_monitor_config
OMARCHY_TEST_MONITOR_SCALE=2 OMARCHY_TEST_MONITOR_WIDTH=1280 OMARCHY_TEST_MONITOR_HEIGHT=800 run_scaling 3.2
[[ $(saved_scale) == "3.2" ]] || fail "monitor scaling accepts displayed approximate values"
pass "monitor scaling accepts displayed approximate values"

# On a mode where both 3x and 4x resolve to 4x, the duplicate is one step.
write_monitor_config
OMARCHY_TEST_MONITOR_SCALE=4 OMARCHY_TEST_MONITOR_WIDTH=1280 OMARCHY_TEST_MONITOR_HEIGHT=804 run_scaling down
[[ $(saved_scale) == "2" ]] || fail "monitor scaling down skips duplicate 4x approximation"
[[ $(saved_scale) == "2" ]] ||
  fail "monitor scaling down persists 2x after skipping duplicate approximation"
pass "monitor scaling down skips duplicate approximation"

# A monitor with a description is saved under it, replacing only its own entry,
# and the live rule keeps the monitor's position and rotation.
printf '1.6\tHDMI-A-1\t1\tOther Display\n2\teDP-1\t1\tAcer KB272 (rev 2)\n' >"$saved_scales"
write_monitor_config
OMARCHY_TEST_MONITOR_DESC="Acer KB272 (rev 2)" OMARCHY_TEST_MONITOR_SCALE=1 run_scaling up
[[ $(awk -F '\t' '$4 == "Acer KB272 (rev 2)" { print $1 }' "$saved_scales") == "1.25" ]] ||
  fail "monitor scaling saves a scale under the monitor's description"
[[ $(saved_scale HDMI-A-1) == "1.6" ]] || fail "monitor scaling keeps other monitors' saved scales"
pass "monitor scaling saves per monitor under its description"

require_command lua

# monitor-scales.lua re-applies each saved scale as a copy of the rule that
# governs the monitor, under that rule's own output key.
apply_saved_scales() {
  HOME="$home_dir" OMARCHY_PATH="$ROOT" lua <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path

local function show(rule)
  local keys = {}
  for key in pairs(rule) do table.insert(keys, key) end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do table.insert(parts, key .. "=" .. tostring(rule[key])) end
  print(table.concat(parts, " "))
end

local applying = false
hl = { monitor = function(rule) if applying then show(rule) end end }

package.loaded["default.hypr.monitor-scales"] = nil
local scales = require("default.hypr.monitor-scales")
scales.record()
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1, transform = 3 })
for _, desc in ipairs({ "desc:Acer KB272 A1", "desc:Acer KB272 B2" }) do
  hl.monitor({ output = desc, mode = "1920x1080@60", position = desc:sub(-2) == "A1" and "0x0" or "1920x0", scale = 1 })
end
applying = true
scales.apply()
applying = false
LUA
}

touch -d @1000 "$monitor_lua"
printf '1.25\tDP-2\t2000\tAcer KB272 A1\n1.6\teDP-1\t2000\t\n2\tDP-9\t500\tAcer KB272 B2\n' >"$saved_scales"
applied=$(apply_saved_scales 2>&1)
expected='mode=1920x1080@60 output=desc:Acer KB272 A1 position=0x0 scale=1.25
mode=preferred output=eDP-1 position=auto scale=1.6 transform=3'
[[ $applied == "$expected" ]] ||
  fail "saved scales re-apply over the governing rule, skipping ones older than monitors.lua" "actual: $applied"
pass "saved scales re-apply over the governing rule, skipping ones older than monitors.lua"
