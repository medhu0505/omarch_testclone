#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

stub_dir="$tmpdir/bin"
home_dir="$tmpdir/home"
notification_log="$tmpdir/notifications.log"
mkdir -p "$stub_dir" "$home_dir"

cat >"$stub_dir/hyprctl" <<'BASH'
#!/bin/bash

if [[ $1 == "activeworkspace" ]]; then
  printf '{"id":4,"tiledLayout":"%s"}\n' "$HYPRCTL_TILED_LAYOUT"
fi
BASH
chmod +x "$stub_dir/hyprctl"

cat >"$stub_dir/omarchy-notification-send" <<'BASH'
#!/bin/bash
printf '%s|' "$@" >>"$NOTIFICATION_LOG"
printf '\n' >>"$NOTIFICATION_LOG"
BASH
chmod +x "$stub_dir/omarchy-notification-send"

toggle() {
  : >"$notification_log"
  env HOME="$home_dir" XDG_STATE_HOME="$home_dir/.local/state" OMARCHY_PATH="$ROOT" \
    HYPRCTL_TILED_LAYOUT="$1" NOTIFICATION_LOG="$notification_log" \
    PATH="$stub_dir:$ROOT/bin:$PATH" "$ROOT/bin/omarchy-hyprland-window-single-square-aspect-toggle"
}

flag="$home_dir/.local/state/omarchy/toggles/hypr/single-window-aspect-ratio.lua"

toggle dwindle
[[ -f $flag ]] || fail "square aspect toggle turns the flag on"
grep -Fq "Enable single-window square aspect ratio|" "$notification_log" || fail "square aspect toggle reports enabling"
if grep -Fq "Has no effect" "$notification_log"; then
  fail "square aspect toggle adds no note on a dwindle workspace" "$(cat "$notification_log")"
fi
pass "square aspect toggle reports plainly on a dwindle workspace"

toggle master
[[ ! -f $flag ]] || fail "square aspect toggle turns the flag off"
grep -Fq "Disable single-window square aspect ratio|" "$notification_log" || fail "square aspect toggle reports disabling"
if grep -Fq "Has no effect" "$notification_log"; then
  fail "square aspect toggle adds no note on a master workspace, which honours the ratio" "$(cat "$notification_log")"
fi
pass "square aspect toggle reports plainly on a master workspace"

toggle scrolling
[[ -f $flag ]] || fail "square aspect toggle turns the flag back on"
grep -Fq "Enable single-window square aspect ratio|Has no effect on scrolling workspaces like this one.|" "$notification_log" ||
  fail "square aspect toggle says a scrolling workspace is unaffected" "$(cat "$notification_log")"
pass "square aspect toggle says a scrolling workspace is unaffected"

toggle scrolling
[[ ! -f $flag ]] || fail "square aspect toggle turns the flag off"
grep -Fq "Disable single-window square aspect ratio|Has no effect on scrolling workspaces like this one.|" "$notification_log" ||
  fail "square aspect toggle says disabling leaves a scrolling workspace unaffected" "$(cat "$notification_log")"
pass "square aspect toggle says disabling leaves a scrolling workspace unaffected"

mkdir -p "$home_dir/.local/state/omarchy/workspace-layouts"
printf '%s\n' 'o.workspace_mode({ workspace = "4", mode = "floating" })' >"$home_dir/.local/state/omarchy/workspace-layouts/4.lua"
toggle dwindle
[[ -f $flag ]] || fail "square aspect toggle turns the flag on again"
grep -Fq "Enable single-window square aspect ratio|Has no effect on floating workspaces like this one.|" "$notification_log" ||
  fail "square aspect toggle says a floating workspace is unaffected" "$(cat "$notification_log")"
pass "square aspect toggle says a floating workspace is unaffected"
