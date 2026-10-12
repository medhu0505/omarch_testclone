#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

awake="$ROOT/bin/omarchy-agent-awake"
tmpdir=$(mktemp -d)
fake_bin="$tmpdir/bin"
clock_bin="$tmpdir/clock"
runtime="$tmpdir/runtime"
state="$runtime/omarchy/agent-awake"
log="$tmpdir/log"
home="$tmpdir/home"

cleanup() {
  [[ -r $tmpdir/holder.pid ]] && pkill -P "$(<"$tmpdir/holder.pid")" 2>/dev/null
  rm -rf "$tmpdir"
}
trap cleanup EXIT

mkdir -p "$fake_bin" "$clock_bin" "$runtime" "$home"
chmod 700 "$runtime"

# systemd stands in for itself: a unit is active while its holder runs, and the
# holder runs the real command, so readiness and the record are exercised.
cat >"$fake_bin/systemctl" <<'SH'
#!/bin/bash
[[ $1 == "--user" ]] && shift
case $1 in
  is-active)
    [[ ${@: -1} == "graphical-session.target" ]] && { [[ ! -e $TEST_DIR/no-desktop ]]; exit; }
    [[ -e $TEST_DIR/unit-active ]]
    ;;
  stop)
    echo "stop" >>"$TEST_DIR/log"
    if [[ -r $TEST_DIR/holder.pid ]]; then
      pkill -P "$(<"$TEST_DIR/holder.pid")" 2>/dev/null
      kill "$(<"$TEST_DIR/holder.pid")" 2>/dev/null
    fi
    rm -f "$TEST_DIR/unit-active" "$TEST_DIR/holder.pid" "$TEST_DIR/deactivating"
    "$TEST_DIR/bin/run-stop-hook"
    ;;
esac
SH

cat >"$fake_bin/systemd-run" <<'SH'
#!/bin/bash
if [[ " $* " == *" omarchy-notification-send "* ]]; then
  call="$*"
  call=${call##*omarchy-notification-send -g 󰈈 }
  printf 'notify %s\n' "$call" >>"$TEST_DIR/log"
  exit 0
fi
printf 'systemd-run %s\n' "$*" >>"$TEST_DIR/log"
[[ -e $TEST_DIR/run-fails ]] && exit 1
# A unit still in its stop hook is neither active nor gone.
[[ -e $TEST_DIR/deactivating ]] && { echo "Unit omarchy-agent-awake.service was already loaded" >&2; exit 1; }
for arg in "$@"; do
  [[ $arg == --property=ExecStopPost=* ]] && printf '%s\n' "${arg#--property=ExecStopPost=}" >"$TEST_DIR/stop-hook"
done
token=${@: -1}
touch "$TEST_DIR/unit-active"
if [[ ! -e $TEST_DIR/inhibit-fails ]]; then
  # A unit inherits none of its caller's descriptors. Until logind grants the
  # inhibitor, systemd-inhibit has not started the holder.
  ( [[ -e $TEST_DIR/slow-inhibit ]] && /usr/bin/sleep 1; omarchy-agent-awake hold "$token"; rm -f "$TEST_DIR/unit-active"; "$TEST_DIR/bin/run-stop-hook" ) </dev/null >/dev/null 2>&1 9>&- &
  echo $! >"$TEST_DIR/holder.pid"
else
  rm -f "$TEST_DIR/unit-active"
fi
SH

# systemd runs the stop hook once the holder is gone, however it went. It splits
# the line on quotes and backslashes and expands nothing, as shlex does.
cat >"$fake_bin/run-stop-hook" <<'SH'
#!/bin/bash
[[ -r $TEST_DIR/stop-hook ]] || exit 0
mapfile -t words < <(python3 -I -c 'import shlex, sys; print("\n".join(shlex.split(open(sys.argv[1]).read())))' "$TEST_DIR/stop-hook")
set -- "${words[@]}"
echo "stop-hook $*" >>"$TEST_DIR/log"
"$@"
SH

cat >"$fake_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf 'refusal %s\n' "${*: -1}" >>"$TEST_DIR/log"
SH

cat >"$fake_bin/omarchy-hw-laptop" <<'SH'
#!/bin/bash
[[ ! -e $TEST_DIR/no-lid ]]
SH

cat >"$fake_bin/omarchy-battery-present" <<'SH'
#!/bin/bash
[[ -e $TEST_DIR/battery ]]
SH

cat >"$fake_bin/upower" <<'SH'
#!/bin/bash
[[ -r $TEST_DIR/battery ]] && cat "$TEST_DIR/battery"
SH

# The lid, the displays and the power profile are all stand-ins, so a run on a
# real laptop never touches its own profile. The lid is open unless closed.
cat >"$fake_bin/omarchy-hw-laptop-closed" <<'SH'
#!/bin/bash
[[ -e $TEST_DIR/lid-closed ]]
SH

cat >"$fake_bin/omarchy-hw-external-monitors" <<'SH'
#!/bin/bash
[[ -e $TEST_DIR/docked ]]
SH

cat >"$fake_bin/busctl" <<'SH'
#!/bin/bash
[[ " $* " == *" ActiveProfile "* && -r $TEST_DIR/profile ]] || exit 1
printf 's "%s"\n' "$(<"$TEST_DIR/profile")"
SH

cat >"$fake_bin/powerprofilesctl" <<'SH'
#!/bin/bash
[[ $1 == "set" ]] || exit 1
echo "$2" >"$TEST_DIR/profile"
echo "powerprofilesctl set $2" >>"$TEST_DIR/log"
SH

cat >"$fake_bin/omarchy-powerprofiles-list" <<'SH'
#!/bin/bash
printf '%s\n' power-saver balanced performance
SH

cat >"$fake_bin/omarchy-powerprofiles-set" <<'SH'
#!/bin/bash
echo "omarchy-powerprofiles-set $*" >>"$TEST_DIR/log"
# A stalled call, as the holder's clock sees it.
[[ -e $TEST_DIR/slow-power && -r $TEST_DIR/now ]] && echo $(( $(<"$TEST_DIR/now") + 30 )) >"$TEST_DIR/now"
[[ -e $TEST_DIR/restore-fails ]] && exit 1
echo performance >"$TEST_DIR/profile"
SH

cat >"$fake_bin/omarchy-shell" <<'SH'
#!/bin/bash
exit 0
SH

ln -s "$awake" "$fake_bin/omarchy-agent-awake"
ln -s "$ROOT/bin/omarchy-agent-busy" "$fake_bin/omarchy-agent-busy"

# The holder's clock: date +%s reads a file that sleep advances, so hours of
# session pass in a moment and a runaway loop is cut off rather than hung.
cat >"$clock_bin/date" <<'SH'
#!/bin/bash
if [[ $* == "+%s" ]]; then
  cat "$TEST_DIR/now"
else
  exec /usr/bin/date "$@"
fi
SH

cat >"$clock_bin/sleep" <<'SH'
#!/bin/bash
now=$(<"$TEST_DIR/now")
echo $((now + ${1%.*})) >"$TEST_DIR/now"
read -r up _ <"$TEST_DIR/uptime"
echo "$((${up%.*} + ${1%.*})).00 0.00" >"$TEST_DIR/uptime"
[[ -x $TEST_DIR/on-sleep ]] && HOLDER=$PPID "$TEST_DIR/on-sleep"
(( now - $(<"$TEST_DIR/epoch") < 200000 )) || kill -TERM "$PPID"
SH

chmod +x "$fake_bin"/* "$clock_bin"/*

# Agent homes from the session running the tests would leak into the record.
unset CLAUDE_CONFIG_DIR CODEX_HOME GROK_HOME PI_CODING_AGENT_DIR XDG_DATA_HOME HERMES_HOME COPILOT_HOME

export TEST_DIR="$tmpdir"
export XDG_RUNTIME_DIR="$runtime"
export HOME="$home"

reset() {
  [[ -r $tmpdir/holder.pid ]] && { pkill -P "$(<"$tmpdir/holder.pid")" 2>/dev/null; kill "$(<"$tmpdir/holder.pid")" 2>/dev/null; } || true
  rm -f "$tmpdir"/{unit-active,holder.pid,no-desktop,no-lid,battery,run-fails,inhibit-fails,slow-inhibit,on-sleep,lid-closed,docked,stop-hook,slow-power,restore-fails,deactivating}
  echo performance >"$tmpdir/profile"
  rm -rf "$state" "$home"
  mkdir -p "$home"
  : >"$log"
}

run() {
  PATH="$fake_bin:$PATH" "$awake" "$@"
}

field() {
  local fields
  read -r -a fields <"$state/session"
  printf '%s\n' "${fields[$1]}"
}

# --- starting

reset
before=$(date +%s)
output=$(run 2h)
[[ $output == "Awake until "* ]] || fail "a duration starts a session" "$output"
deadline=$(field 1)
(( deadline - before >= 7200 && deadline - before <= 7202 )) || fail "2h ends two hours from now" "deadline=$deadline before=$before"
[[ $(field 2) == "time" ]] || fail "a duration is a time session"
pass "a duration starts a session ending that far from now"

args=$(grep '^systemd-run' "$log")
[[ $args == *"--what=handle-lid-switch "* ]] || fail "the holder takes the lid-switch inhibitor" "$args"
[[ $args != *sleep:* && $args != *:idle* && $args != *"--what=sleep"* && $args != *"--what=idle"* ]] || fail "the holder inhibits nothing but the lid" "$args"
[[ $args == *"--no-ask-password"* ]] || fail "the holder never prompts for a password" "$args"
[[ $args == *"--property=RuntimeMaxSec=86460"* ]] || fail "systemd bounds the holder's lifetime" "$args"
[[ $args == *"--property=ExecStopPost=\"$(readlink -f "$awake")\" restore-power"* ]] || fail "the unit gives back the power profile however its holder ends" "$args"
pass "only the lid switch is inhibited, and systemd bounds the holder"

[[ $(<"$state/ready") == "$(field 0)" ]] || fail "start returns only once the holder has the lid"
pass "start waits for the holder to confirm the inhibitor"

for spec in 90m:5400 1h30m:5400 45m:2700; do
  reset
  before=$(date +%s)
  run "${spec%%:*}" >/dev/null
  (( $(field 1) - before >= ${spec##*:} && $(field 1) - before <= ${spec##*:} + 2 )) || fail "${spec%%:*} lasts ${spec##*:} seconds"
done
pass "minutes and hours-and-minutes durations parse"

reset
target=$(date -d "+2 hours" +%H:%M)
run "$target" >/dev/null
[[ $(date -d "@$(field 1)" +%H:%M) == "$target" ]] || fail "a clock time ends at that time"
(( $(field 1) > $(date +%s) )) || fail "a clock time ends in the future"
reset
target=$(date -d "-1 hour" +%H:%M)
run "$target" >/dev/null
(( $(field 1) > $(date +%s) + 20 * 3600 )) || fail "a clock time already past today means tomorrow"
pass "a clock time ends at its next occurrence"

for bad in 0m 2x abc 25:00 12:60 1h-5m "" 100h; do
  reset
  if [[ -z $bad ]]; then continue; fi
  if run "$bad" >/dev/null 2>&1; then fail "'$bad' is refused"; fi
  [[ ! -e $state/session ]] || fail "'$bad' leaves no session behind"
done
pass "nonsense durations and times are refused"

reset
if run 24h1m >/dev/null 2>&1; then fail "a session longer than 24 hours is refused"; fi
run 24h >/dev/null || fail "a 24 hour session is allowed"
pass "sessions are capped at 24 hours"

reset
touch "$tmpdir/no-lid"
if output=$(run 2h 2>&1); then fail "a machine without a lid refuses"; fi
[[ $output == *"no lid"* ]] && ! grep -q '^systemd-run' "$log" || fail "a machine without a lid refuses before starting anything" "$output"
pass "a machine without a lid refuses"

reset
touch "$tmpdir/no-desktop"
if run 2h >/dev/null 2>&1; then fail "without a desktop session it refuses"; fi
pass "without a desktop session to lock, it refuses"

reset
printf '  percentage:          9%%\n  state:               discharging\n' >"$tmpdir/battery"
if output=$(run 2h 2>&1); then fail "a battery at the floor refuses to start"; fi
[[ $output == *"too low"* ]] || fail "the refusal says the battery is too low" "$output"
printf '  percentage:          9%%\n  state:               charging\n' >"$tmpdir/battery"
run 2h >/dev/null || fail "a low battery on the charger may start"
grep -q '^refusal The battery' "$log" || fail "a refusal nobody sees on a terminal is sent as a notification" "$(<"$log")"
pass "a battery at or below 10% and not charging refuses to start"

reset
touch "$tmpdir/run-fails"
if run 2h >/dev/null 2>&1; then fail "a unit that cannot start is reported"; fi
[[ ! -e $state/session ]] || fail "a unit that cannot start leaves no session"
reset
touch "$tmpdir/inhibit-fails"
if output=$(run 2h 2>&1); then fail "an inhibitor that is never granted is reported"; fi
[[ $output == *"Could not hold the lid"* && ! -e $state/session ]] || fail "an ungranted inhibitor is reported and cleaned up" "$output"
pass "a holder that never confirms is reported and cleaned up"

reset
touch "$tmpdir/slow-inhibit"
run 2h >/dev/null &
starting=$!
/usr/bin/sleep 0.5
kill -0 "$starting" 2>/dev/null || fail "start waits while the inhibitor has not been granted"
! PATH="$fake_bin:$PATH" "$awake" active || fail "a session is not active before its inhibitor is granted"
[[ $(PATH="$fake_bin:$PATH" "$awake" status | jq -r .active) == "false" ]] || fail "status does not claim a session before its inhibitor is granted"
wait "$starting" || fail "start succeeds once the inhibitor is granted"
PATH="$fake_bin:$PATH" "$awake" active || fail "the session is active once granted"
pass "nothing reports the lid held until logind has granted it"

reset
run 2h >/dev/null
CODEX_HOME="$tmpdir/codex-elsewhere" run agents >/dev/null
[[ $(<"$state/homes") == "CODEX_HOME=$tmpdir/codex-elsewhere" ]] || fail "an agent home set in the terminal reaches a holder already running" "$(cat "$state/homes")"
(cd "$tmpdir" && CODEX_HOME=relative PATH="$fake_bin:$PATH" "$awake" agents >/dev/null)
[[ $(<"$state/homes") == "CODEX_HOME=$tmpdir/relative" ]] || fail "a relative agent home is resolved where it was given" "$(cat "$state/homes")"
mkdir -p "$tmpdir/odd"$'\n'"dir"
(cd "$tmpdir/odd"$'\n'"dir" && CODEX_HOME=relative PATH="$fake_bin:$PATH" "$awake" agents >/dev/null)
[[ -z $(<"$state/homes") ]] || fail "a home that would span lines is dropped, not split" "$(cat "$state/homes")"
pass "agent homes set in the terminal reach the holder, new or running"

# --- a running session

reset
run 2h >/dev/null
token=$(field 0)
pid=$(<"$tmpdir/holder.pid")
run 4h >/dev/null
[[ $(grep -c '^systemd-run' "$log") == 1 && $(<"$tmpdir/holder.pid") == "$pid" ]] || fail "a new end time reuses the running holder" "$(<"$log")"
[[ $(field 0) == "$token" ]] || fail "the running holder keeps its token"
(( $(field 1) - $(date +%s) >= 4 * 3600 - 2 )) || fail "the new end time is recorded"
pass "a new end time is handed to the running holder without releasing the lid"

deadline=$(field 1)
run add 30m >/dev/null
(( $(field 1) == deadline + 1800 )) || fail "add pushes the end back from the current end"
pass "add pushes the end time back"

run add 20h >/dev/null 2>&1 && fail "add past 24 hours from the holder's start is refused"
(( $(field 1) == deadline + 1800 )) || fail "a refused add changes nothing"
pass "add cannot stretch a holder past 24 hours"

# A new end time for a running holder still counts from when that holder began.
read -r -a fields <"$state/session"
printf '%s %s %s %s %s\n' "${fields[0]}" "${fields[1]}" "${fields[2]}" "${fields[3]}" $(( $(date +%s) - 23 * 3600 )) >"$state/session"
if run 4h >/dev/null 2>&1; then fail "a new end time past the running holder's 24 hours is refused"; fi
run 30m >/dev/null || fail "a new end time inside the running holder's 24 hours is accepted"
pass "a new end time cannot stretch a running holder past 24 hours"

status=$(PATH="$fake_bin:$PATH" "$awake" status)
[[ $(jq -r .active <<<"$status") == "true" && $(jq -r .tooltip <<<"$status") == "Awake until "* ]] || fail "status reports an active session with its end" "$status"
PATH="$fake_bin:$PATH" "$awake" active || fail "active succeeds while a session runs"
pass "status and active report a running session"

run stop
! PATH="$fake_bin:$PATH" "$awake" active || fail "active fails once stopped"
[[ ! -e $state/session && -d $state ]] || fail "stop clears the session but keeps the watched directory"
pass "stop ends the session"

# A refusal is announced after the lock is let go: a notification server that
# hangs must not keep the holder from ending or stop from stopping.
reset
run 2h >/dev/null
mkfifo "$tmpdir/notify-gate"
cat >"$fake_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
echo refusal-waiting >>"$TEST_DIR/log"
read -r _ <"$TEST_DIR/notify-gate"
SH
run add 30h >/dev/null 2>&1 &
refusing=$!
for _ in {1..50}; do grep -q refusal-waiting "$log" && break; /usr/bin/sleep 0.1; done
grep -q refusal-waiting "$log" || fail "the refusal reached the notification"
timeout 5 env PATH="$fake_bin:$PATH" "$awake" stop || fail "stop does not wait on a stalled refusal notification"
echo go >"$tmpdir/notify-gate"
wait "$refusing" || true
cat >"$fake_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf 'refusal %s\n' "${*: -1}" >>"$TEST_DIR/log"
SH
chmod +x "$fake_bin/omarchy-notification-send"
pass "a refusal never holds the lock while it is announced"

reset
if run add 30m >/dev/null 2>&1; then fail "add without a session is refused"; fi
pass "add without a session is refused"

# A holder whose record is gone is on its way out: start waits for it to stop
# rather than hand it an end time it will never read.
reset
touch "$tmpdir/unit-active"
mkdir -p "$state"
run 2h >/dev/null
grep -q '^stop' "$log" || fail "start stops a holder that is ending"
[[ $(grep -c '^systemd-run' "$log") == 1 ]] || fail "start then runs a new holder"
pass "start after a holder began ending starts a new one"

# A unit that ended on its own may still be in its stop hook, giving the
# profile back; starting again then waits for it rather than failing.
reset
touch "$tmpdir/deactivating"
run 2h >/dev/null || fail "starting while the last unit is still in its stop hook succeeds" "$(<"$log")"
PATH="$fake_bin:$PATH" "$awake" active || fail "the new session is running"
pass "starting again while the last unit is still in its stop hook waits for it"

# Killed holder: the unit is gone but the record stays; status believes systemd.
reset
run 2h >/dev/null
# The wrapper may exit on its own once the holder is gone.
pkill -P "$(<"$tmpdir/holder.pid")" || true
kill "$(<"$tmpdir/holder.pid")" 2>/dev/null || true
rm -f "$tmpdir/unit-active"
[[ $(PATH="$fake_bin:$PATH" "$awake" status | jq -r .active) == "false" ]] || fail "a killed holder reads inactive"
pass "a killed holder reads inactive whatever its record says"

# --- the holder

hold_session() {
  reset
  mkdir -p -m 700 "$state"
  echo 1000000 >"$tmpdir/now"
  echo 1000000 >"$tmpdir/epoch"
  echo "500.00 0.00" >"$tmpdir/uptime"
  printf 'aaaaaaaaaaaaaaaa %s %s 1000000 1000000\n' "$1" "$2" >"$state/session"
}

hold() {
  OMARCHY_UPTIME_PATH="$tmpdir/uptime" PATH="$clock_bin:$fake_bin:$PATH" "$awake" hold aaaaaaaaaaaaaaaa 2>/dev/null
}

hold_session 1003600 time
hold
(( $(<"$tmpdir/now") >= 1003600 && $(<"$tmpdir/now") <= 1003605 )) || fail "the holder ends within a tick of its end time" "now=$(<"$tmpdir/now")"
[[ ! -e $state/session ]] || fail "an ended session clears its record"
grep -q '^notify Agent Awake is over' "$log" || fail "the end is announced" "$(<"$log")"
pass "the holder ends at its end time and says so"

hold_session 1003600 time
cat >"$tmpdir/on-sleep" <<'SH'
#!/bin/bash
(( $(<"$TEST_DIR/now") >= 1001000 )) && sed -i 's/ 1003600 / 1007200 /' "$XDG_RUNTIME_DIR/omarchy/agent-awake/session"
exit 0
SH
chmod +x "$tmpdir/on-sleep"
hold
(( $(<"$tmpdir/now") >= 1007200 )) || fail "the holder follows an end time moved while it runs"
pass "the holder rereads its end time"

hold_session 1086400 time
printf '  percentage:          10%%\n  state:               discharging\n' >"$tmpdir/battery"
hold
grep -q '^notify -u critical Agent Awake stopped The battery' "$log" || fail "10% discharging ends the session" "$(<"$log")"
(( $(<"$tmpdir/now") < 1000100 )) || fail "the battery is checked straight away"
pass "the battery floor ends the session"

hold_session 1003600 time
printf '  percentage:          5%%\n  state:               pending-charge\n' >"$tmpdir/battery"
hold
grep -q '^notify Agent Awake is over' "$log" || fail "a charging battery below the floor does not end it" "$(<"$log")"
pass "a battery that is charging does not end it"

hold_session 1003600 time
printf '  percentage:          9%%\n  state:               unknown\n' >"$tmpdir/battery"
hold
grep -q 'The battery is at' "$log" || fail "an unknown state below the floor counts as discharging" "$(<"$log")"
pass "a battery in an unknown state below the floor ends it"

hold_session 1086400 time
: >"$tmpdir/battery"
hold
grep -q 'Could not read the battery' "$log" || fail "a battery that cannot be read ends the session" "$(<"$log")"
(( $(<"$tmpdir/now") >= 1000030 )) || fail "one unreadable answer is forgiven"
pass "a battery that cannot be read twice in a row ends it"

# The wall clock moving back must not stop the battery being watched.
hold_session 1086400 time
printf '  percentage:          50%%\n  state:               discharging\n' >"$tmpdir/battery"
cat >"$tmpdir/on-sleep" <<'SH'
#!/bin/bash
if [[ ! -e $TEST_DIR/rolled-back ]]; then
  touch "$TEST_DIR/rolled-back"
  echo $(( $(<"$TEST_DIR/now") - 3600 )) >"$TEST_DIR/now"
  printf '  percentage:          8%%\n  state:               discharging\n' >"$TEST_DIR/battery"
fi
exit 0
SH
chmod +x "$tmpdir/on-sleep"
rm -f "$tmpdir/rolled-back"
hold
read -r up _ <"$tmpdir/uptime"
grep -q 'The battery is at' "$log" && (( ${up%.*} <= 540 )) || fail "the battery is still checked every 30 seconds after the clock moves back" "uptime=$up $(<"$log")"
pass "moving the clock back does not pause the battery check"

# Agents mode ends only once activity it has seen goes quiet.
hold_session 1028800 agents
hold
grep -q '^notify Agent Awake is over Its end time' "$log" || fail "never seeing an agent runs to the cap" "$(<"$log")"
pass "agents mode with no activity ever seen runs to its cap"

hold_session 1028800 agents
mkdir -p "$home/.claude/projects/p"
touch "$home/.claude/projects/p/s.jsonl"
cat >"$tmpdir/on-sleep" <<'SH'
#!/bin/bash
(( $(<"$TEST_DIR/now") >= 1003600 )) && touch -d "-20 minutes" "$HOME/.claude/projects/p/s.jsonl"
grep -q . "$XDG_RUNTIME_DIR/omarchy/agent-awake/agents" 2>/dev/null && cp "$XDG_RUNTIME_DIR/omarchy/agent-awake/agents" "$TEST_DIR/agents-seen"
exit 0
SH
chmod +x "$tmpdir/on-sleep"
hold
grep -q '^notify Agent Awake is over No agent activity' "$log" || fail "seen activity going quiet ends agents mode" "$(<"$log")"
(( $(<"$tmpdir/now") >= 1003600 && $(<"$tmpdir/now") < 1003700 )) || fail "agents mode ends at the first quiet check" "now=$(<"$tmpdir/now")"
[[ $(<"$tmpdir/agents-seen") == "Claude Code" ]] || fail "the agents with activity are recorded for the bar"
pass "agents mode ends once the activity it saw goes quiet"

hold_session 1028800 agents
mkdir -p "$tmpdir/codex-elsewhere/sessions"
touch "$tmpdir/codex-elsewhere/sessions/rollout.jsonl"
printf 'CODEX_HOME=%s\n' "$tmpdir/codex-elsewhere" >"$state/homes"
cat >"$tmpdir/on-sleep" <<'SH'
#!/bin/bash
cp "$XDG_RUNTIME_DIR/omarchy/agent-awake/agents" "$TEST_DIR/agents-seen" 2>/dev/null
kill -TERM "$HOLDER"
SH
chmod +x "$tmpdir/on-sleep"
{ hold || true; } 2>/dev/null
[[ $(cat "$tmpdir/agents-seen" 2>/dev/null) == "Codex" ]] || fail "the holder scans the agent homes it was handed"
rm -rf "$tmpdir/codex-elsewhere" "$tmpdir/agents-seen"
pass "the holder scans the agent homes it was handed"

# A start that lands while a scan runs draws a new generation, may swap the
# homes, and clears seen; the answer must not arm the new session, even when
# the start puts back a record identical to the one the scan read.
hold_session 1028800 agents
mkdir -p "$tmpdir/old-codex/sessions"
touch "$tmpdir/old-codex/sessions/rollout.jsonl"
printf 'CODEX_HOME=%s\n' "$tmpdir/old-codex" >"$state/homes"
echo 1111111111111111 >"$state/generation"
cat >"$clock_bin/omarchy-agent-busy" <<'SH'
#!/bin/bash
if [[ ! -e $TEST_DIR/restarted ]]; then
  touch "$TEST_DIR/restarted"
  echo 2222222222222222 >"$XDG_RUNTIME_DIR/omarchy/agent-awake/generation"
  rm -f "$XDG_RUNTIME_DIR/omarchy/agent-awake/seen"
  "$ROOT/bin/omarchy-agent-busy" "$@"
  status=$?
  echo "$status" >"$TEST_DIR/stale-scan-status"
  # Every later scan finds the agent quiet, so only this stale answer could arm it.
  touch -d "-20 minutes" "$TEST_DIR/old-codex/sessions/rollout.jsonl"
  exit $status
fi
exec "$ROOT/bin/omarchy-agent-busy" "$@"
SH
chmod +x "$clock_bin/omarchy-agent-busy"
rm -f "$tmpdir/restarted" "$tmpdir/stale-scan-status"
hold
rm -f "$clock_bin/omarchy-agent-busy"
rm -rf "$tmpdir/old-codex"
[[ $(cat "$tmpdir/stale-scan-status" 2>/dev/null) == "0" ]] || fail "the stale scan really found activity"
grep -q '^notify Agent Awake is over Its end time' "$log" || fail "a scan of homes a start replaced never arms the new session" "$(<"$log")"
pass "a scan of homes a start replaced never arms the new session"

hold_session 1028800 agents
touch "$state/seen"
hold
(( $(<"$tmpdir/now") >= 1000900 && $(<"$tmpdir/now") < 1000940 )) || fail "agents mode never ends in its first 15 minutes" "now=$(<"$tmpdir/now")"
grep -q '^notify Agent Awake is over No agent activity' "$log" || fail "quiet after the first 15 minutes ends it" "$(<"$log")"
pass "agents mode never ends in its first 15 minutes"

hold_session 1028800 agents
mkdir -p "$home/.claude/projects/p"
chmod 000 "$home/.claude/projects"
touch "$state/seen"
cat >"$tmpdir/on-sleep" <<'SH'
#!/bin/bash
(( $(<"$TEST_DIR/now") >= 1001000 )) && kill -TERM "$HOLDER"
exit 0
SH
chmod +x "$tmpdir/on-sleep"
{ hold || true; } 2>/dev/null
chmod 755 "$home/.claude/projects"
(( $(<"$tmpdir/now") >= 1001000 )) || fail "the holder outlives a failed scan until it is stopped" "now=$(<"$tmpdir/now")"
[[ -e $state/session ]] && ! grep -q '^notify' "$log" || fail "a scan that failed is not quiet" "$(<"$log")"
pass "a failed activity scan never ends agents mode"

hold_session 1003600 time
printf 'bbbbbbbbbbbbbbbb 1003600 time 1000000 1000000\n' >"$state/session"
hold
grep -q . "$state/session" && ! grep -q '^notify' "$log" || fail "a holder never ends another holder's session"
[[ ! -e $state/ready ]] || fail "a superseded holder never confirms"
pass "a holder leaves a session that is not its own alone"

hold_session 1003600 time
cat >"$tmpdir/on-sleep" <<'SH'
#!/bin/bash
(( $(<"$TEST_DIR/now") >= 1001000 )) && printf 'bbbbbbbbbbbbbbbb 1003600 time 1000000 1000000\n' >"$XDG_RUNTIME_DIR/omarchy/agent-awake/session"
exit 0
SH
chmod +x "$tmpdir/on-sleep"
hold
(( $(<"$tmpdir/now") < 1001100 )) || fail "a holder whose session passed to another stops at once" "now=$(<"$tmpdir/now")"
grep -q '^bbbbbbbbbbbbbbbb' "$state/session" && ! grep -q '^notify' "$log" || fail "a holder never clears or announces another holder's session"
pass "a holder that loses its session mid-run stops without touching the new one"

# --- several agents, and the last one out

# Agents mode waits for the last agent: Claude Code finishing while Codex still
# works keeps it awake, and it ends only once Codex is quiet too.
hold_session 1028800 agents
mkdir -p "$home/.claude/projects/p" "$home/.codex/sessions"
touch "$home/.claude/projects/p/s.jsonl" "$home/.codex/sessions/rollout.jsonl"
cat >"$tmpdir/on-sleep" <<'SH'
#!/bin/bash
now=$(<"$TEST_DIR/now")
(( now >= 1003600 )) && touch -d "-20 minutes" "$HOME/.claude/projects/p/s.jsonl"
(( now < 1007200 )) && touch "$HOME/.codex/sessions/rollout.jsonl"
(( now >= 1007200 )) && touch -d "-20 minutes" "$HOME/.codex/sessions/rollout.jsonl"
agents=$(cat "$XDG_RUNTIME_DIR/omarchy/agent-awake/agents" 2>/dev/null | paste -sd, -)
[[ -n $agents && $agents != "$(tail -1 "$TEST_DIR/agents-trail" 2>/dev/null)" ]] && echo "$agents" >>"$TEST_DIR/agents-trail"
exit 0
SH
chmod +x "$tmpdir/on-sleep"
rm -f "$tmpdir/agents-trail"
hold
(( $(<"$tmpdir/now") >= 1007200 && $(<"$tmpdir/now") < 1007240 )) || fail "agents mode waits for the last agent to go quiet" "now=$(<"$tmpdir/now")"
grep -q '^notify Agent Awake is over No agent activity' "$log" || fail "the last agent going quiet ends it" "$(<"$log")"
[[ $(paste -sd'|' "$tmpdir/agents-trail") == "Claude Code,Codex|Codex" ]] || fail "the active agents are tracked as each one finishes" "trail: $(paste -sd'|' "$tmpdir/agents-trail")"
rm -f "$tmpdir/agents-trail"
pass "agents mode tracks each agent and waits for the last one to finish"

# A timed session follows its end time whatever the agents do.
hold_session 1003600 time
mkdir -p "$home/.claude/projects/p"
touch "$home/.claude/projects/p/s.jsonl"
cat >"$tmpdir/on-sleep" <<'SH'
#!/bin/bash
touch -d "-20 minutes" "$HOME/.claude/projects/p/s.jsonl"
exit 0
SH
chmod +x "$tmpdir/on-sleep"
hold
(( $(<"$tmpdir/now") >= 1003600 )) && grep -q '^notify Agent Awake is over Its end time' "$log" || fail "a timed session ignores agents going quiet" "now=$(<"$tmpdir/now") $(<"$log")"
pass "a timed session follows its end time, not the agents"

# --- power saver

# Shut, undocked and working: power saver, given back once the lid opens.
hold_session 1003600 time
mkdir -p "$home/.claude/projects/p"
cat >"$tmpdir/on-sleep" <<'SH'
#!/bin/bash
touch "$HOME/.claude/projects/p/s.jsonl"
now=$(<"$TEST_DIR/now")
(( now >= 1000060 )) && touch "$TEST_DIR/lid-closed"
(( now >= 1000600 )) && { rm -f "$TEST_DIR/lid-closed"; cp "$TEST_DIR/profile" "$TEST_DIR/profile-at-open" 2>/dev/null; }
[[ -e $XDG_RUNTIME_DIR/omarchy/agent-awake/power-saver ]] && touch "$TEST_DIR/saver-seen"
(( now >= 1000700 )) && kill -TERM "$HOLDER"
exit 0
SH
chmod +x "$tmpdir/on-sleep"
rm -f "$tmpdir"/{saver-seen,profile-at-open}
{ hold || true; } 2>/dev/null
grep -q '^powerprofilesctl set power-saver' "$log" && [[ -e $tmpdir/saver-seen ]] || fail "a shut, undocked laptop with agents working goes to power saver" "$(<"$log")"
grep -q '^omarchy-powerprofiles-set autodetect' "$log" && [[ $(<"$tmpdir/profile") == "performance" && ! -e $state/power-saver ]] || fail "opening the lid gives the remembered profile back" "$(<"$log")"
pass "a shut, undocked laptop with agents working goes to power saver until the lid opens"

hold_session 1003600 agents
mkdir -p "$home/.claude/projects/p"
touch "$tmpdir/lid-closed" "$tmpdir/docked"
cat >"$tmpdir/on-sleep" <<'SH'
#!/bin/bash
touch "$HOME/.claude/projects/p/s.jsonl"
(( $(<"$TEST_DIR/now") >= 1000300 )) && kill -TERM "$HOLDER"
exit 0
SH
chmod +x "$tmpdir/on-sleep"
{ hold || true; } 2>/dev/null
! grep -q 'powerprofilesctl' "$log" || fail "a docked laptop with its lid shut is in use and keeps its profile" "$(<"$log")"
rm -f "$tmpdir/docked"
hold_session 1003600 agents
touch "$tmpdir/lid-closed"
cat >"$tmpdir/on-sleep" <<'SH'
#!/bin/bash
(( $(<"$TEST_DIR/now") >= 1000300 )) && kill -TERM "$HOLDER"
exit 0
SH
chmod +x "$tmpdir/on-sleep"
{ hold || true; } 2>/dev/null
! grep -q 'powerprofilesctl' "$log" || fail "a shut laptop with no agent working keeps its profile" "$(<"$log")"
pass "power saver needs both a shut, undocked lid and an agent working"

# Plugging in makes the battery service put the remembered profile back; the
# holder takes power saver again, and gives it back when the session ends.
hold_session 1001000 agents
mkdir -p "$home/.claude/projects/p"
touch "$tmpdir/lid-closed"
cat >"$tmpdir/on-sleep" <<'SH'
#!/bin/bash
touch "$HOME/.claude/projects/p/s.jsonl"
if (( $(<"$TEST_DIR/now") >= 1000300 )) && [[ ! -e $TEST_DIR/plugged ]]; then
  touch "$TEST_DIR/plugged"
  echo performance >"$TEST_DIR/profile"
fi
exit 0
SH
chmod +x "$tmpdir/on-sleep"
rm -f "$tmpdir/plugged"
hold
(( $(grep -c '^powerprofilesctl set power-saver' "$log") == 2 )) || fail "power saver is taken again after the battery service resets the profile" "$(<"$log")"
grep -q '^notify Agent Awake is over' "$log" && ! grep -q 'autodetect' "$log" && [[ -e $state/power-saver ]] ||
  fail "the holder leaves power saver to the stop hook, so a slow switch never holds the lid" "$(<"$log")"
run restore-power
[[ $(<"$tmpdir/profile") == "performance" && ! -e $state/power-saver ]] || fail "the stop hook gives the remembered profile back" "$(<"$log")"
rm -f "$tmpdir/plugged"
pass "power saver survives a plug event and is given back by the stop hook at the end"

# The agents finishing gives it back, though the lid stays shut.
hold_session 1003600 time
mkdir -p "$home/.claude/projects/p"
touch "$tmpdir/lid-closed" "$home/.claude/projects/p/s.jsonl"
cat >"$tmpdir/on-sleep" <<'SH'
#!/bin/bash
now=$(<"$TEST_DIR/now")
(( now < 1000300 )) && touch "$HOME/.claude/projects/p/s.jsonl"
(( now >= 1000300 )) && touch -d "-20 minutes" "$HOME/.claude/projects/p/s.jsonl"
(( now >= 1000400 )) && kill -TERM "$HOLDER"
exit 0
SH
chmod +x "$tmpdir/on-sleep"
{ hold || true; } 2>/dev/null
grep -q '^powerprofilesctl set power-saver' "$log" && grep -q '^omarchy-powerprofiles-set autodetect' "$log" && [[ ! -e $state/power-saver ]] ||
  fail "the agents going quiet gives the remembered profile back, lid shut or not" "$(<"$log")"
pass "the agents going quiet gives power saver back with the lid still shut"

# Someone already on power saver keeps it: the holder never owned it.
hold_session 1001000 agents
mkdir -p "$home/.claude/projects/p"
touch "$tmpdir/lid-closed"
echo power-saver >"$tmpdir/profile"
cat >"$tmpdir/on-sleep" <<'SH'
#!/bin/bash
touch "$HOME/.claude/projects/p/s.jsonl"
exit 0
SH
chmod +x "$tmpdir/on-sleep"
hold
! grep -q 'powerprofiles' "$log" && [[ $(<"$tmpdir/profile") == "power-saver" ]] || fail "a profile the holder did not change is never given back" "$(<"$log")"
pass "a power saver the user chose is left alone"

# The unit's stop hook, as systemd runs it, gives it back after a stop, and only
# when it was taken.
reset
run 2h >/dev/null
run stop
grep -q '^stop-hook ' "$log" && ! grep -q 'powerprofiles-set' "$log" || fail "the stop hook does nothing when power saver was never taken" "$(<"$log")"
run 2h >/dev/null
: >"$state/power-saver"
echo power-saver >"$tmpdir/profile"
run stop
grep -q '^omarchy-powerprofiles-set autodetect' "$log" && [[ ! -e $state/power-saver && $(<"$tmpdir/profile") == "performance" ]] ||
  fail "stopping gives back a power saver the holder took" "$(<"$log")"
pass "the unit's stop hook gives power saver back, and only when it was taken"

# A switch back that fails keeps the marker, so the next try still happens.
reset
mkdir -p "$state"
: >"$state/power-saver"
touch "$tmpdir/restore-fails"
if run restore-power; then fail "a failed give-back says so"; fi
[[ -e $state/power-saver ]] || fail "a failed give-back keeps its marker for the next try"
rm -f "$tmpdir/restore-fails"
run restore-power
[[ ! -e $state/power-saver ]] || fail "the next try gives it back"
pass "a give-back that fails is tried again"

# A checkout under a path with spaces, quotes and dollars still reaches its hook.
reset
odd="$tmpdir/Omarchy Work \$HOME \"q\"/bin"
mkdir -p "$odd"
cp "$awake" "$odd/omarchy-agent-awake"
PATH="$fake_bin:$PATH" "$odd/omarchy-agent-awake" 2h >/dev/null
: >"$state/power-saver"
PATH="$fake_bin:$PATH" "$odd/omarchy-agent-awake" stop
grep -qF "stop-hook $odd/omarchy-agent-awake restore-power" "$log" && [[ ! -e $state/power-saver ]] ||
  fail "the stop hook survives a path with spaces, quotes and dollars" "$(<"$log")"
pass "the stop hook survives a path with spaces, quotes and dollars"

# A profile switch that stalls never carries the session past its end.
hold_session 1000040 time
mkdir -p "$home/.claude/projects/p"
touch "$tmpdir/lid-closed" "$home/.claude/projects/p/s.jsonl" "$tmpdir/slow-power"
: >"$state/power-saver"
echo power-saver >"$tmpdir/profile"
cat >"$tmpdir/on-sleep" <<'SH'
#!/bin/bash
(( $(<"$TEST_DIR/now") >= 1000025 )) && rm -f "$TEST_DIR/lid-closed"
exit 0
SH
chmod +x "$tmpdir/on-sleep"
hold
(( $(<"$tmpdir/now") <= 1000045 )) || fail "a stalled profile switch never carries the session past its end" "now=$(<"$tmpdir/now")"
pass "a stalled profile switch never carries the session past its end"

# --- undocking with the lid shut

# Agent Awake keeps that lid from suspending, and suspend is what used to lock
# it, so the monitor watcher has to lock and blank it instead.
watch_bin="$tmpdir/watch-bin"
watch_log="$tmpdir/watch-log"
mkdir -p "$watch_bin"

stub() {
  printf '#!/bin/bash\n%s\n' "$2" >"$watch_bin/$1"
  chmod +x "$watch_bin/$1"
}

stub socat 'exit 0'
stub hyprctl 'exit 0'
stub omarchy-hw-laptop 'exit 1'
stub omarchy-hyprland-monitor-external-active 'exit 1'
stub omarchy-hyprland-monitor-modeless 'exit 1'
stub omarchy-system-lid-inhibit 'exit 0'
stub omarchy-hw-external-monitors '[[ -e $TEST_DIR/docked ]]'
stub omarchy-hw-laptop-closed '[[ -e $TEST_DIR/closed ]]'
stub omarchy-agent-awake '[[ $1 == "active" && -e $TEST_DIR/awake ]]'
stub omarchy-shell '[[ $* == "lock isLocked" ]] && { [[ -e $TEST_DIR/locked ]] && echo true || echo false; }'
for command in omarchy-hyprland-monitor-clamshell omarchy-brightness-display omarchy-brightness-keyboard; do
  stub "$command" "echo $command >>\"\$TEST_DIR/watch-log\""
done
stub omarchy-system-lock 'echo omarchy-system-lock >>"$TEST_DIR/watch-log"; touch "$TEST_DIR/locked"'

# The startup pass runs before any event is read, and socat ending at once ends
# the watcher; its delayed retries are left to the process group to clean up.
watch_once() {
  rm -f "$tmpdir"/{docked,closed,awake,locked}
  for flag in "$@"; do touch "$tmpdir/$flag"; done
  : >"$watch_log"
  PATH="$watch_bin:$PATH" HYPRLAND_INSTANCE_SIGNATURE=test setsid "$ROOT/bin/omarchy-hyprland-monitor-watch" &
  local pid=$!
  wait "$pid" || true
  kill -- -"$pid" 2>/dev/null || true
  mapfile -t watched <"$watch_log"
}

watch_once closed awake
[[ ${watched[*]:0:4} == "omarchy-system-lock omarchy-hyprland-monitor-clamshell omarchy-brightness-display" ]] ||
  fail "a closed, undocked lid under Agent Awake locks, reconciles, then blanks" "calls: ${watched[*]}"
pass "a closed, undocked lid under Agent Awake locks, reconciles, then blanks"

watch_once closed awake locked
[[ ${watched[*]:0:2} == "omarchy-hyprland-monitor-clamshell omarchy-brightness-display" ]] ||
  fail "an already locked session is blanked again, not locked again" "calls: ${watched[*]}"
# The retries repeat this pass, and keyboard off saves the current level each
# time, so a second call would save 0 for the wake to restore.
watch_once closed awake locked
/usr/bin/sleep 2
mapfile -t watched <"$watch_log"
[[ " ${watched[*]} " != *keyboard* ]] || fail "the watcher leaves the keyboard backlight to the lock" "calls: ${watched[*]}"
pass "an already locked session is blanked again, not locked again, and the keyboard is left alone"

# Undocked while the clamshell pass runs: the pass's own retries lose the lock
# to it, so the check after the pass has to lock as well as blank.
stub omarchy-hyprland-monitor-clamshell 'echo omarchy-hyprland-monitor-clamshell >>"$TEST_DIR/watch-log"; rm -f "$TEST_DIR/docked"'
watch_once closed awake docked
[[ ${watched[*]:0:4} == "omarchy-hyprland-monitor-clamshell omarchy-system-lock omarchy-brightness-display" ]] ||
  fail "undocking during the clamshell pass still locks before blanking" "calls: ${watched[*]}"
stub omarchy-hyprland-monitor-clamshell 'echo omarchy-hyprland-monitor-clamshell >>"$TEST_DIR/watch-log"'
pass "undocking during the clamshell pass still locks before blanking"

for flags in "closed" "awake" "closed awake docked"; do
  # shellcheck disable=SC2086
  watch_once $flags
  [[ ${watched[*]:0:1} == "omarchy-hyprland-monitor-clamshell" && " ${watched[*]} " != *" omarchy-system-lock "* && " ${watched[*]} " != *brightness* ]] ||
    fail "'$flags' neither locks nor blanks" "calls: ${watched[*]}"
done
pass "without Agent Awake, with the lid open, or docked, the watcher neither locks nor blanks"
