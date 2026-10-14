#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command flock

test_dir=$(mktemp -d)
volume_pid=""
cleanup() {
  if [[ -n $volume_pid ]]; then
    touch "$test_dir/data/osd-release"
    wait "$volume_pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT
mkdir -p "$test_dir/bin" "$test_dir/home" "$test_dir/runtime" "$test_dir/data"

# All audio clients and the OSD are fixtures; run the actual volume command.
cat >"$test_dir/bin/omarchy-audio-output-sink" <<'STUB'
#!/bin/bash
printf 'resolve\n' >>"$TEST_DATA/calls"
cat "$TEST_DATA/sink"
[[ ! -e $TEST_DATA/fail-resolver ]]
STUB
cat >"$test_dir/bin/pamixer" <<'STUB'
#!/bin/bash
printf 'pamixer' >>"$TEST_DATA/calls"
printf ' <%s>' "$@" >>"$TEST_DATA/calls"
printf '\n' >>"$TEST_DATA/calls"
[[ ! -e $TEST_DATA/fail-pamixer ]] || exit 1
if [[ -e $TEST_DATA/client-output ]]; then
  cat "$TEST_DATA/client-output"
else
  printf 'false %s\n' "$(cat "$TEST_DATA/percent")"
fi
STUB
cat >"$test_dir/bin/pactl" <<'STUB'
#!/bin/bash
printf 'pactl' >>"$TEST_DATA/calls"
printf ' <%s>' "$@" >>"$TEST_DATA/calls"
printf '\n' >>"$TEST_DATA/calls"
[[ ! -e $TEST_DATA/fail-$1 ]] || exit 1
case "$1" in
  set-sink-mute)
    [[ $2 == "$(cat "$TEST_DATA/sink")" && $3 == "toggle" ]] || exit 1
    if [[ $(cat "$TEST_DATA/muted") == "yes" ]]; then
      printf 'no\n' >"$TEST_DATA/muted"
    else
      printf 'yes\n' >"$TEST_DATA/muted"
    fi
    ;;
  get-sink-volume) printf 'Volume: front-left: 32768 / %s%% / -18.06 dB\n' "$(cat "$TEST_DATA/percent")" ;;
  get-sink-mute)
    [[ ${LC_ALL:-} == "C" ]] || exit 1
    if [[ -e $TEST_DATA/mute-output ]]; then
      cat "$TEST_DATA/mute-output"
    else
      printf 'Mute: %s\n' "$(cat "$TEST_DATA/muted")"
    fi
    ;;
  *) exit 1 ;;
esac
STUB
cat >"$test_dir/bin/date" <<'STUB'
#!/bin/bash
cat "$TEST_DATA/now"
STUB
cat >"$test_dir/bin/omarchy-osd" <<'STUB'
#!/bin/bash
printf 'osd' >>"$TEST_DATA/calls"
printf ' <%s>' "$@" >>"$TEST_DATA/calls"
printf '\n' >>"$TEST_DATA/calls"
if [[ -e $TEST_DATA/block-osd ]]; then
  touch "$TEST_DATA/osd-entered"
  for ((i = 0; i < 500; i++)); do
    [[ ! -e $TEST_DATA/osd-release ]] || exit 0
    sleep 0.01
  done
  exit 1
fi
STUB
chmod +x "$test_dir/bin/"*

physical="alsa_output.fixture speakers"
reset_scenario() {
  rm -f "$test_dir/data/"* "$test_dir/runtime/"*
  printf '%s\n' "$physical" >"$test_dir/data/sink"
  printf '48\n' >"$test_dir/data/percent"
  printf 'no\n' >"$test_dir/data/muted"
  printf '1000\n' >"$test_dir/data/now"
  : >"$test_dir/data/calls"
}
volume() {
  HOME="$test_dir/home" XDG_RUNTIME_DIR="$test_dir/runtime" TEST_DATA="$test_dir/data" \
    OMARCHY_PATH="$ROOT" PATH="$test_dir/bin:$PATH" \
    bash "$ROOT/bin/omarchy-audio-output-volume" "$@"
}
numeric_action() {
  local action="$1" percent="$2" direction="$3" step="$4" icon="volume-high" expected actual
  reset_scenario
  printf '%s\n' "$percent" >"$test_dir/data/percent"
  [[ $percent != "0" ]] || icon="volume-muted"
  volume "$action" || fail "$action succeeds"
  expected=$(printf 'resolve\npamixer <--sink> <%s>%s <%s> <--unmute> <--get-mute> <--get-volume>\nosd <-i> <%s> <-p> <%s>' \
    "$physical" "$direction" "$step" "$icon" "$percent")
  actual=$(cat "$test_dir/data/calls")
  [[ $actual == "$expected" ]] || fail "$action uses one client on the resolved sink, then shows its result" "$actual"
  pass "$action uses one client on the resolved sink, then shows its result"
}

numeric_action raise 48 ' <--increase>' 5
numeric_action lower 43 ' <--allow-boost> <--decrease>' 5
numeric_action +1 44 ' <--increase>' 1
numeric_action -1 42 ' <--allow-boost> <--decrease>' 1
numeric_action +5 100 ' <--increase>' 5
numeric_action -5 0 ' <--allow-boost> <--decrease>' 5
# Above 100%, only decreases allow boost so lowering remains gradual.
numeric_action lower 115 ' <--allow-boost> <--decrease>' 5

reset_scenario
printf 'bluetooth_output.fixture\n' >"$test_dir/data/sink"
volume raise
[[ $(cat "$test_dir/data/calls") == *'pamixer <--sink> <bluetooth_output.fixture> <--increase> <5> <--unmute> <--get-mute> <--get-volume>'* ]] ||
  fail "Bluetooth uses the sink returned by the resolver"
pass "Bluetooth uses the sink returned by the resolver"

for failure in fail-resolver fail-pamixer; do
  reset_scenario
  touch "$test_dir/data/$failure"
  if volume raise >"$test_dir/stdout" 2>"$test_dir/stderr"; then
    fail "$failure returns failure"
  fi
  [[ $(cat "$test_dir/data/calls") != *osd* ]] || fail "$failure suppresses the OSD"
  pass "$failure suppresses the OSD"
done
reset_scenario
: >"$test_dir/data/sink"
if volume raise >"$test_dir/stdout" 2>"$test_dir/stderr"; then
  fail "an empty sink returns failure"
fi
[[ $(cat "$test_dir/data/calls") == "resolve" ]] || fail "an empty sink never reaches an audio client"
pass "an empty sink never reaches an audio client"

for output in '' invalid '48' 'true' 'false 48%' 'FALSE 48' 'no 48' 'false -1' 'false 48 extra' ' false 48' 'false 48 ' $'false 48\nfalse 49' $'false 48\n\n'; do
  reset_scenario
  printf '%s' "$output" >"$test_dir/data/client-output"
  if volume raise >"$test_dir/stdout" 2>"$test_dir/stderr"; then
    fail "invalid client output returns failure"
  fi
  [[ $(cat "$test_dir/data/calls") != *osd* ]] || fail "invalid client output suppresses the OSD"
done
pass "missing, malformed, extra and multiline client output suppresses the OSD"

for output in 'true 55' 'false 55'; do
  reset_scenario
  printf '%s\n' "$output" >"$test_dir/data/client-output"
  volume raise
  icon="volume-high"
  [[ $output != "true 55" ]] || icon="volume-muted"
  [[ $(cat "$test_dir/data/calls") == *"osd <-i> <$icon> <-p> <55>" ]] || fail "the actual client mute boolean determines the icon"
done
pass "the actual client mute boolean determines the icon"

for action in '' invalid +x 5 --1; do
  reset_scenario
  if volume "$action" >"$test_dir/stdout" 2>"$test_dir/stderr"; then
    fail "invalid actions return failure"
  fi
  [[ $(cat "$test_dir/data/calls") != *pamixer* && $(cat "$test_dir/data/calls") != *pactl* && $(cat "$test_dir/data/calls") != *osd* ]] ||
    fail "invalid actions never reach an audio client or the OSD"
done
pass "invalid actions never reach an audio client or the OSD"

reset_scenario
volume mute-toggle
expected=$(printf 'resolve\npactl <set-sink-mute> <%s> <toggle>\npactl <get-sink-volume> <%s>\npactl <get-sink-mute> <%s>\nosd <-i> <volume-muted> <-p> <48>' \
  "$physical" "$physical" "$physical")
[[ $(cat "$test_dir/data/calls") == "$expected" ]] || fail "mute-toggle preserves the pactl path and reports mute state"
pass "mute-toggle preserves the pactl path and reports mute state"
: >"$test_dir/data/calls"
printf '1249\n' >"$test_dir/data/now"
volume mute-toggle
[[ $(cat "$test_dir/data/calls") == "resolve" ]] || fail "mute-toggle drops repeats before 250ms"
pass "mute-toggle drops repeats before 250ms"
printf '1250\n' >"$test_dir/data/now"
volume mute-toggle
[[ $(cat "$test_dir/data/muted") == "no" && $(cat "$test_dir/data/calls") == *'osd <-i> <volume-high> <-p> <48>' ]] ||
  fail "mute-toggle accepts the next event at 250ms and reports unmuted volume"
pass "mute-toggle accepts the next event at 250ms and reports unmuted volume"

for output in '' 'Mute: maybe' 'Mute: yes extra' $'Mute: yes\nMute: no' $'Mute: yes\n\n'; do
  reset_scenario
  printf '%s' "$output" >"$test_dir/data/mute-output"
  if volume mute-toggle >"$test_dir/stdout" 2>"$test_dir/stderr"; then
    fail "invalid mute-toggle output returns failure"
  fi
  [[ $(cat "$test_dir/data/calls") != *osd* ]] || fail "invalid mute-toggle output suppresses the OSD"
done
pass "mute-toggle validates its mute state before showing the OSD"

for failure in set-sink-mute get-sink-volume get-sink-mute; do
  reset_scenario
  touch "$test_dir/data/fail-$failure"
  if volume mute-toggle >"$test_dir/stdout" 2>"$test_dir/stderr"; then
    fail "a failed $failure returns failure"
  fi
  [[ $(cat "$test_dir/data/calls") != *osd* ]] || fail "a failed $failure suppresses the OSD"
  pass "a failed $failure suppresses the OSD"
done

reset_scenario
touch "$test_dir/data/block-osd"
volume raise >"$test_dir/stdout" 2>"$test_dir/stderr" &
volume_pid=$!
for ((i = 0; i < 500; i++)); do
  [[ ! -e $test_dir/data/osd-entered ]] || break
  sleep 0.01
done
[[ -e $test_dir/data/osd-entered ]] || fail "the first volume command reaches the blocked OSD"
calls_before=$(cat "$test_dir/data/calls")
volume lower
[[ $(cat "$test_dir/data/calls") == "$calls_before" ]] || fail "an overlapping repeat is dropped while the OSD runs"
touch "$test_dir/data/osd-release"
wait "$volume_pid" || fail "the first volume command finishes after its OSD"
volume_pid=""
[[ $(cat "$test_dir/data/calls") == "$calls_before" ]] || fail "dropped repeats do not queue a later volume change"
volume lower
[[ $(cat "$test_dir/data/calls") != "$calls_before" ]] || fail "the lock is released when the first command finishes"
pass "overlapping repeats are dropped through the OSD, without a backlog, and release the lock afterward"

[[ ! -e $test_dir/home/.cache/omarchy/audio-output-volume ]] || fail "a supplied XDG runtime directory is used without a fallback"
pass "a supplied XDG runtime directory is used for both lock and debounce without a fallback"
