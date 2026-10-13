#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
require_command python3

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

export HOME="$test_tmp/home"
export XDG_STATE_HOME="$test_tmp/state"
export XDG_CACHE_HOME="$test_tmp/cache"
export XDG_CONFIG_HOME="$test_tmp/home/.config"
export XDG_DATA_HOME="$test_tmp/home/.local/share"

mkdir -p "$XDG_CONFIG_HOME/muse" "$XDG_DATA_HOME/muse/sessions/2026/10/12/demo"

# A login as `muse login` leaves it, and one model call's worth of session log.
jq -nc '{providers: {meta: {access_token: "token-1"}}}' >"$XDG_CONFIG_HOME/muse/auth.json"

session_log="$XDG_DATA_HOME/muse/sessions/2026/10/12/demo/session.jsonl"
now_us=$(python3 -c 'import time; print(int(time.time() * 1_000_000))')
python3 - "$session_log" "$now_us" <<'PY'
import json, sys

path, now_us = sys.argv[1], int(sys.argv[2])
calls = [
    {"input_tokens": 38219, "output_tokens": 290, "cache_read_tokens": 0, "cache_write_tokens": 0},
    {"input_tokens": 42901, "output_tokens": 357, "cache_read_tokens": 38132, "cache_write_tokens": 0},
]
for sequence, usage in enumerate(calls):
    event = {
        "schema_version": 1,
        "recorded_at": now_us + sequence * 1000,
        "record_type": "event",
        "payload_type": "runtime.session",
        "payload": {"event": {"kind": "model_completed", "model": "muse-wonder-1.0", "usage": usage}},
    }
    with open(path, "a") as handle:
        handle.write(json.dumps(event) + "\n")
# Noise the collector must skip: an estimate without real counters.
with open(path, "a") as handle:
    handle.write(json.dumps({"payload": {"event": {"kind": "model_completed", "model": "muse", "usage": {"estimated_tokens": 5}}}}) + "\n")
PY

python3 - "$XDG_DATA_HOME/muse/session-index.db" "$now_us" <<'PY'
import sqlite3, sys

database = sqlite3.connect(sys.argv[1])
database.execute("""
  CREATE TABLE sessions (
    session_id TEXT PRIMARY KEY,
    prompt_count INTEGER NOT NULL DEFAULT 0,
    created_at_us INTEGER
  )
""")
database.execute("INSERT INTO sessions VALUES ('demo', 2, ?)", (int(sys.argv[2]),))
database.commit()
database.close()
PY

collect() {
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-muse" python3 - "$@" <<'PY'
import importlib.machinery, importlib.util, json, os, sys

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

mint = {
    "subs_tier_name": "Muse Code Max Usage",
    "subs_usage": {
        "window": {"used_percent": 16, "window_duration_mins": 300, "resets_at": 1791865517},
        "weekly": {"used_percent": 5, "resets_at": 1792368000},
    },
}
collector.fetch_mint = lambda token: mint
sys.argv = ["omarchy-agent-usage-muse"] + sys.argv[1:]
collector.main()
PY
}

record=$(collect)
[[ $(jq -r .ready <<<"$record") == "true" ]] || fail "ready" "$(jq -r .ready <<<"$record")"
pass "ready"
[[ $(jq -r .tierLabel <<<"$record") == "Muse Code Max Usage" ]] || fail "tier" "$(jq -r .tierLabel <<<"$record")"
pass "tier"
[[ $(jq -r '.limits[0].label' <<<"$record") == "Session (5-hour)" ]] || fail "session window" "$(jq -r '.limits[0].label' <<<"$record")"
pass "session window"
[[ $(jq -r '.limits[0].percent' <<<"$record") == "0.16" ]] || fail "session percent" "$(jq -r '.limits[0].percent' <<<"$record")"
pass "session percent"
[[ $(jq -r '.limits[1].percent' <<<"$record") == "0.05" ]] || fail "weekly percent" "$(jq -r '.limits[1].percent' <<<"$record")"
pass "weekly percent"
[[ $(jq -r .totalPrompts <<<"$record") == "2" ]] || fail "prompts" "$(jq -r .totalPrompts <<<"$record")"
pass "prompts"
[[ $(jq -r .totalSessions <<<"$record") == "1" ]] || fail "sessions" "$(jq -r .totalSessions <<<"$record")"
pass "sessions"
[[ $(jq -r '.modelUsage["muse-wonder-1.0"].inputTokens' <<<"$record") == "42988" ]] || fail "model non-cached input" "$(jq -c '.modelUsage["muse-wonder-1.0"]' <<<"$record")"
pass "model non-cached input"
[[ $(jq -r '.modelUsage["muse-wonder-1.0"].outputTokens' <<<"$record") == "647" ]] || fail "model output" "$(jq -c '.modelUsage["muse-wonder-1.0"]' <<<"$record")"
pass "model output"
[[ $(jq -r '.modelUsage["muse-wonder-1.0"].cacheReadInputTokens' <<<"$record") == "38132" ]] || fail "model cache read" "$(jq -c '.modelUsage["muse-wonder-1.0"]' <<<"$record")"
pass "model cache read"
[[ $(jq -r '.recentDays[6].messageCount' <<<"$record") == "81767" ]] || fail "today tokens" "$(jq -r '.recentDays[6].messageCount' <<<"$record")"
pass "today tokens"

# The parse is cached; a second run answers from it without touching the log.
mv "$session_log" "$session_log.away"
cached=$(collect)
[[ $(jq -r '.recentDays[6].messageCount' <<<"$cached") == "81767" ]] || fail "cached today tokens" "$(jq -r '.recentDays[6].messageCount' <<<"$cached")"
pass "cached today tokens"
[[ -f "$XDG_CACHE_HOME/omarchy/agents-muse-cache.json" ]]

# --force re-parses and finds the log gone, --limits-only keeps the cache.
forced=$(collect --force)
[[ $(jq -r '.recentDays[6].messageCount' <<<"$forced") == "0" ]] || fail "forced today tokens" "$(jq -r '.recentDays[6].messageCount' <<<"$forced")"
pass "forced today tokens"
limits_only=$(collect --limits-only)
[[ $(jq -r '.recentDays[6].messageCount' <<<"$limits_only") == "0" ]] || fail "limits-only keeps cache" "$(jq -r '.recentDays[6].messageCount' <<<"$limits_only")"
pass "limits-only keeps cache"

# Without a login the meters step aside for the sign-in hint.
mv "$XDG_CONFIG_HOME/muse/auth.json" "$XDG_CONFIG_HOME/muse/auth.json.away"
unsigned=$(collect)
[[ $(jq -r .ready <<<"$unsigned") == "true" ]] || fail "unsigned ready" "$(jq -r .ready <<<"$unsigned")"
pass "unsigned ready"
jq -e '.authHelpText == "Run `muse login` to sign in to Muse Code."' <<<"$unsigned" >/dev/null ||
  fail "unsigned help" "$(jq -r .authHelpText <<<"$unsigned")"
pass "unsigned help"

echo "muse collector: all assertions passed"
