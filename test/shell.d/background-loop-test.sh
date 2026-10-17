#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

loop_home="$test_tmp/home"
loop_state="$loop_home/.local/state/omarchy/current"
backgrounds="$loop_state/theme/backgrounds"
loop="$backgrounds/loops/1-totoro.mp4"
background="$backgrounds/1-totoro.webp"
other="$backgrounds/2-waves.webp"
link="$loop_state/background"
mkdir -p "${loop%/*}"
printf 'still\n' >"$background"
printf 'other still\n' >"$other"
printf 'loop video\n' >"$loop"
ln -s "$background" "$link"

resolved=$(HOME="$loop_home" "$ROOT/bin/omarchy-theme-bg-loop-apply" --resolve-only)
[[ $resolved == "$loop" ]] || fail "a loop matches the current still by filename" "$resolved"
pass "a loop matches the current still by filename"

resolved=$(HOME="$loop_home" "$ROOT/bin/omarchy-theme-bg-loop-apply" --resolve-only "$other")
[[ -z $resolved ]] || fail "a still without a matching loop has none" "$resolved"
pass "a still without a matching loop has none"

printf 'video background\n' >"$backgrounds/3-video.mp4"
printf 'loop video\n' >"$backgrounds/loops/3-video.mp4"
resolved=$(HOME="$loop_home" "$ROOT/bin/omarchy-theme-bg-loop-apply" --resolve-only "$backgrounds/3-video.mp4")
[[ -z $resolved ]] || fail "a video background never takes a loop" "$resolved"
pass "a video background never takes a loop"

still=$("$ROOT/bin/omarchy-theme-bg-loop-apply" --still "$loop")
[[ $still == "$background" ]] || fail "a loop maps back to its still" "$still"
still=$("$ROOT/bin/omarchy-theme-bg-loop-apply" --still "$other")
[[ $still == "$other" ]] || fail "a still maps to itself" "$still"
pass "a loop maps back to its still"

command_bin="$test_tmp/bin"
command_log="$test_tmp/command-log"
mkdir -p "$command_bin"
cat >"$command_bin/omarchy-shell" <<'SH'
#!/bin/bash
printf 'shell: %s\n' "$*" >>"$COMMAND_LOG"
SH
cat >"$command_bin/hyprctl" <<'SH'
#!/bin/bash
printf '{"option":"animations:enabled","bool":%s}\n' "$([[ ${ANIMATIONS:-on} == on ]] && echo true || echo false)"
SH
chmod +x "$command_bin/omarchy-shell" "$command_bin/hyprctl"

apply() {
  : >"$command_log"
  HOME="$loop_home" PATH="$command_bin:$PATH" COMMAND_LOG="$command_log" "$@" "$ROOT/bin/omarchy-theme-bg-loop-apply"
}

apply env
[[ $(readlink "$link") == "$loop" ]] || fail "the still's loop takes over the background" "$(readlink "$link")"
[[ $(<"$command_log") == "shell: -q background set $loop" ]] || fail "the shell learns of the loop" "$(<"$command_log")"
pass "the still's loop takes over the background"

apply env
[[ -z $(<"$command_log") ]] || fail "applying again changes nothing" "$(<"$command_log")"
pass "applying again changes nothing"

apply env ANIMATIONS=off
[[ $(readlink "$link") == "$background" ]] || fail "disabled animations return to the still" "$(readlink "$link")"
pass "disabled animations return to the still"

mkdir -p "$loop_home/.local/state/omarchy/toggles"
touch "$loop_home/.local/state/omarchy/toggles/background-loops-off"
ln -nsf "$loop" "$link"
apply env
[[ $(readlink "$link") == "$background" ]] || fail "the loop toggle returns to the still" "$(readlink "$link")"
pass "the loop toggle returns to the still"
rm "$loop_home/.local/state/omarchy/toggles/background-loops-off"

ln -nsf "$other" "$link"
apply env
[[ $(readlink "$link") == "$other" && -z $(<"$command_log") ]] || fail "a still without a loop stays" "$(readlink "$link")"
pass "a still without a loop stays"

# Cycling from a playing loop moves on from its still, not back to the first.
cat >"$command_bin/omarchy-theme-bg-set" <<'SH'
#!/bin/bash
printf 'set: %s\n' "$1" >>"$COMMAND_LOG"
SH
chmod +x "$command_bin/omarchy-theme-bg-set"
printf 'test\n' >"$loop_state/theme.name"
ln -nsf "$loop" "$link"
: >"$command_log"
HOME="$loop_home" PATH="$command_bin:$PATH" COMMAND_LOG="$command_log" "$ROOT/bin/omarchy-theme-bg-next"
[[ $(<"$command_log") == "set: $other" ]] || fail "bg next from a loop moves past its still" "$(<"$command_log")"
pass "bg next from a loop moves past its still"
