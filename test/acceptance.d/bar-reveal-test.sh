#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

original_position=$(omarchy-bar position)
original_hidden=false
[[ -f ~/.local/state/omarchy/toggles/bar-off ]] && original_hidden=true
shell_pid=$(quickshell list -a -j | jq -er 'if length == 1 then .[0].pid else error("expected one shell") end')
original_stat=$(cat "/proc/$shell_pid/stat")
original_start=$(awk '{print $20}' <<<"${original_stat##*) }")

cleanup() {
  same_shell || return 0
  omarchy-bar position "$original_position" >/dev/null 2>&1 || true
  if $original_hidden; then
    omarchy-toggle-bar on >/dev/null 2>&1 || true
  else
    omarchy-toggle-bar off >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

same_shell() {
  local stat current_pid
  stat=$(cat "/proc/$shell_pid/stat") || return 1
  [[ $(awk '{print $20}' <<<"${stat##*) }") == "$original_start" ]] || return 1
  current_pid=$(quickshell list -a -j | jq -er 'if length == 1 then .[0].pid else error("expected one shell") end') || return 1
  [[ $current_pid == "$shell_pid" ]]
}

# Flush the geometry result before fail() can take a repaint-producing capture.
record_state() {
  local description="$1" layers
  layers=$(hyprctl -j layers)
  jq -nc --arg time "$(TZ=America/New_York date --iso-8601=ns)" \
    --arg description "$description" --argjson pid "$shell_pid" \
    --arg start_ticks "$original_start" --argjson layers "$layers" \
    '{time:$time,description:$description,pid:$pid,start_ticks:$start_ticks,layers:$layers}' \
    >>"$ARTIFACTS/bar-reveal.jsonl"
  sync "$ARTIFACTS/bar-reveal.jsonl"
}

wait_bar() {
  local description="$1" predicate="$2" deadline=$((SECONDS + 15))
  until "$predicate" omarchy-bar >/dev/null 2>&1; do
    if ! same_shell; then
      record_state "$description: invalidated by shell change"
      # A process change is not a rendering timeout; do not capture recovery.
      printf 'not ok - %s: shell identity changed\n' "$description" >&2
      exit 1
    fi
    if ((SECONDS >= deadline)); then
      record_state "$description: timed out"
      fail "$description" "bar did not settle within 15 seconds"
    fi
    sleep 0.1
  done
  same_shell || { record_state "$description: shell identity changed"; exit 1; }
  record_state "$description: passed"
}

for edge in top bottom left right; do
  omarchy-bar position "$edge" >/dev/null
  for ((cycle = 1; cycle <= 20; cycle++)); do
    omarchy-toggle-bar on >/dev/null
    wait_bar "$edge $cycle hidden" layer_absent
    screenshot "success-bar-$edge-$cycle-hidden"
    sleep 1
    omarchy-toggle-bar off >/dev/null
    # No screenshot or OCR until the result has been durably recorded.
    wait_bar "$edge $cycle revealed" layer_on_screen
  done
  screenshot "success-bar-$edge-revealed"
  pass "bar reveals repeatedly from $edge without restarting the shell"
done
