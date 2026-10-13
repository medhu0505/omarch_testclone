#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin"
# Apple Silicon: a battery not called BAT*, power_now signed by direction, and
# the thresholds and cycle count only under the native path.
mkdir -p "$tmp_dir/power/macsmc-battery"
printf '%s\n' '-10800000' >"$tmp_dir/power/macsmc-battery/power_now"
printf '75\n' >"$tmp_dir/power/macsmc-battery/charge_control_start_threshold"
printf '80\n' >"$tmp_dir/power/macsmc-battery/charge_control_end_threshold"
printf '212\n' >"$tmp_dir/power/macsmc-battery/cycle_count"
cat >"$tmp_dir/bin/upower" <<'STUB'
#!/bin/bash

# A wireless mouse enumerates first, as a battery_ device that is not a power
# supply; the machine's own battery follows it.
if [[ $1 == "-e" ]]; then
  echo "/org/freedesktop/UPower/devices/line_power_macsmc_ac"
  echo "/org/freedesktop/UPower/devices/battery_hidpp_battery_0"
  echo "/org/freedesktop/UPower/devices/battery_${OMARCHY_TEST_NATIVE_PATH//-/_}"
  exit 0
fi

if [[ $1 == "-i" && $2 == */battery_hidpp_battery_0 ]]; then
  cat <<'INFO'
  native-path:          hidpp_battery_0
  model:                Wireless Mouse
  power supply:         no
  state:                discharging
  percentage:           5%
INFO
  exit 0
fi

if [[ $1 == "-i" ]]; then
  cat <<'INFO'
  native-path:          macsmc-battery
  power supply:         yes
  state:                discharging
  energy:               28.3 Wh
  energy-full:          56.7 Wh
  energy-rate:          7.3 W
  time to empty:        2.5 hours
  percentage:           51%
INFO
  exit 0
fi

exit 1
STUB
chmod +x "$tmp_dir/bin/upower"

shell_output=$(OMARCHY_TEST_NATIVE_PATH=macsmc-battery OMARCHY_POWER_SUPPLY_PATH="$tmp_dir/power" PATH="$tmp_dir/bin:$PATH" "$ROOT/bin/omarchy-battery-status" --shell)

grep -Fx $'percentage\t51%' <<<"$shell_output" >/dev/null || fail "battery status reports the machine's battery, not the mouse's"
grep -Fx $'state\tdischarging' <<<"$shell_output" >/dev/null || fail "battery status reports state"
grep -Fx $'rate\t10.8W' <<<"$shell_output" >/dev/null || fail "battery status reports live sysfs power rate"
grep -Fx $'size\t56Wh' <<<"$shell_output" >/dev/null || fail "battery status reports full capacity"
grep -Fx $'time\t2h 30m' <<<"$shell_output" >/dev/null || fail "battery status reports remaining time"
grep -Fx $'cycles\t212' <<<"$shell_output" >/dev/null || fail "battery status reports native-path cycle count"
grep -Fx $'threshold\t75-80%' <<<"$shell_output" >/dev/null || fail "battery status reports native-path charge thresholds"

# The BAT* name the script used to key on is one of many; CMB0 is another.
mkdir -p "$tmp_dir/power/CMB0"
printf '7300000\n' >"$tmp_dir/power/CMB0/power_now"
sed -i 's/native-path:          macsmc-battery/native-path:          CMB0/' "$tmp_dir/bin/upower"
generic_output=$(OMARCHY_TEST_NATIVE_PATH=CMB0 OMARCHY_POWER_SUPPLY_PATH="$tmp_dir/power" PATH="$tmp_dir/bin:$PATH" "$ROOT/bin/omarchy-battery-status" --shell)
grep -Fx $'rate\t7.3W' <<<"$generic_output" >/dev/null || fail "battery status accepts arbitrary UPower battery paths"
pass "battery status supports Apple Silicon and arbitrary native battery paths"

# An 80% hold threshold doesn't trip while the battery is still below it.
hold_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir" "$hold_dir"' EXIT

mkdir -p "$hold_dir/bin" "$hold_dir/power/BAT0" "$hold_dir/power/ac"
printf 'Mains\n' >"$hold_dir/power/ac/type"
printf '1\n' >"$hold_dir/power/ac/online"
printf '80\n' >"$hold_dir/power/BAT0/charge_control_end_threshold"
cat >"$hold_dir/bin/upower" <<'STUB'
#!/bin/bash

if [[ $1 == "-e" ]]; then
  echo "/org/freedesktop/UPower/devices/battery_BAT0"
  exit 0
fi

if [[ $1 == "-i" ]]; then
  cat <<'INFO'
  native-path:          BAT0
  power supply:         yes
  state:                charging
  energy-full:          69.6 Wh
  energy-rate:          0.1 W
  time to full:         0.2 hours
  percentage:           79.5%
  charge-end-threshold: 80%
INFO
  exit 0
fi

exit 1
STUB
chmod +x "$hold_dir/bin/upower"

hold_output=$(OMARCHY_POWER_SUPPLY_PATH="$hold_dir/power" PATH="$hold_dir/bin:$PATH" "$ROOT/bin/omarchy-battery-status" --shell)

grep -Fx $'state\tcharging' <<<"$hold_output" >/dev/null || fail "a hold below its threshold is still charging"
pass "battery status doesn't trip a hold early"

# Once the battery reaches the threshold, idle charging is holding.
sed -i 's/percentage:           79.5%/percentage:           80.0%/' "$hold_dir/bin/upower"
held_output=$(OMARCHY_POWER_SUPPLY_PATH="$hold_dir/power" PATH="$hold_dir/bin:$PATH" "$ROOT/bin/omarchy-battery-status" --shell)
grep -Fx $'percentage\t80%' <<<"$held_output" >/dev/null || fail "threshold percentage still displays as 80%"
grep -Fx $'state\tholding' <<<"$held_output" >/dev/null || fail "idle charging at the threshold is holding"
pass "battery status reports holding once the raw percentage reaches the threshold"

# pending-charge only means the EC is not charging; it is a hold only with a
# real limit and the level at or above its start.
pending_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir" "$hold_dir" "$pending_dir"' EXIT

mkdir -p "$pending_dir/bin"
cat >"$pending_dir/bin/upower" <<'STUB'
#!/bin/bash

if [[ $1 == "-e" ]]; then
  echo "/org/freedesktop/UPower/devices/battery_BAT0"
  exit 0
fi

if [[ $1 == "-i" ]]; then
  cat "${UPOWER_INFO:?}"
  exit 0
fi

exit 1
STUB
chmod +x "$pending_dir/bin/upower"

setup_battery() {
  local state=$1 percentage=$2 start=$3 end=$4
  rm -rf "$pending_dir/power"
  mkdir -p "$pending_dir/power/BAT0" "$pending_dir/power/AC"
  printf '900000\n' >"$pending_dir/power/BAT0/current_now"
  printf '12000000\n' >"$pending_dir/power/BAT0/voltage_now"
  printf 'Mains\n' >"$pending_dir/power/AC/type"
  printf '1\n' >"$pending_dir/power/AC/online"
  [[ -n $start ]] && printf '%s\n' "$start" >"$pending_dir/power/BAT0/charge_control_start_threshold"
  [[ -n $end ]] && printf '%s\n' "$end" >"$pending_dir/power/BAT0/charge_control_end_threshold"
  UPOWER_INFO="$pending_dir/info"
  cat >"$UPOWER_INFO" <<INFO
  native-path:          BAT0
  power supply:         yes
  state:                $state
  energy:               28.3 Wh
  energy-full:          56.7 Wh
  energy-rate:          7.3 W
  time to empty:        2.5 hours
  percentage:           $percentage%
INFO
  export UPOWER_INFO
}

run_shell() {
  OMARCHY_POWER_SUPPLY_PATH="$pending_dir/power" PATH="$pending_dir/bin:$PATH" \
    "$ROOT/bin/omarchy-battery-status" --shell
}

# A dead pack parked in pending-charge with kernel-default limits (0/100) must
# not read as a threshold hold.
setup_battery pending-charge 0 "0" "100"
shell_output=$(run_shell)
grep -Fx $'state\tpending-charge' <<<"$shell_output" >/dev/null || fail "default-limit pending charge keeps its raw state"

grep -Fx $'threshold_start\t0' <<<"$shell_output" >/dev/null || fail "default limits are still reported"
grep -Fx $'threshold_end\t100' <<<"$shell_output" >/dev/null || fail "default limits are still reported"

if matches=$(rg -n '^state\tholding$' <<<"$shell_output"); then
  fail "kernel-default limits do not turn pending charge into a hold" "$matches"
fi

# A dead pack at 0% is never a limit hold, even with a real end limit and a
# zero/absent start.
setup_battery pending-charge 0 "" "80"
shell_output=$(run_shell)
grep -Fx $'state\tpending-charge' <<<"$shell_output" >/dev/null || fail "end-only dead pack keeps its raw state"
if matches=$(rg -n '^state\tholding$' <<<"$shell_output"); then
  fail "zero-start end-only limit does not turn a dead pack into a hold" "$matches"
fi

setup_battery pending-charge 0 "0" "80"
shell_output=$(run_shell)
grep -Fx $'state\tpending-charge' <<<"$shell_output" >/dev/null || fail "zero-start dead pack keeps its raw state"
if matches=$(rg -n '^state\tholding$' <<<"$shell_output"); then
  fail "zero-start limit does not turn a dead pack into a hold" "$matches"
fi

# A configured band reports as holding while inside it, and exposes the raw
# limits for the panel's own hold logic.
setup_battery pending-charge 78 "75" "80"
shell_output=$(run_shell)
grep -Fx $'state\tholding' <<<"$shell_output" >/dev/null || fail "in-band pending charge reports as holding"
grep -Fx $'threshold_start\t75' <<<"$shell_output" >/dev/null || fail "shell output exposes the limit start"
grep -Fx $'threshold_end\t80' <<<"$shell_output" >/dev/null || fail "shell output exposes the limit end"
grep -Fx $'threshold\t75-80%' <<<"$shell_output" >/dev/null || fail "threshold label spans the band"

# Below the band the hold does not apply (e.g. 9% with a 75-80 limit right
# after plug-in, while the EC briefly reports pending-charge).
setup_battery pending-charge 9 "75" "80"
shell_output=$(run_shell)
grep -Fx $'state\tpending-charge' <<<"$shell_output" >/dev/null || fail "below-limit pending charge keeps its raw state"
if matches=$(rg -n '^state\tholding$' <<<"$shell_output"); then
  fail "below-limit pending charge does not report as holding" "$matches"
fi

# Above the band the pack is still held by the limit (e.g. 90% with an 80%
# limit set while already charged past it).
setup_battery pending-charge 90 "75" "80"
shell_output=$(run_shell)
grep -Fx $'state\tholding' <<<"$shell_output" >/dev/null || fail "above-limit pending charge reports as holding"
grep -Fx $'threshold\t75-80%' <<<"$shell_output" >/dev/null || fail "above-limit hold keeps the threshold label"

if matches=$(rg -n 'omarchy-battery-(capacity|remaining|remaining-time)' "$ROOT/bin" "$ROOT/test" "$ROOT/shell" "$ROOT/docs"); then
  fail "battery status owns capacity and remaining calculations" "$matches"
fi

pass "battery status owns capacity and remaining calculations"
pass "battery status distinguishes real holds from generic pending charge"
