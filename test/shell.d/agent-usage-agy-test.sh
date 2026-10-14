#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
require_command python3
require_command sqlite3

# Pin timezone to UTC so date boundaries are consistent across environments
export TZ=UTC

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

export HOME="$test_tmp/home"
export XDG_STATE_HOME="$test_tmp/state"
export XDG_CACHE_HOME="$test_tmp/cache"
export PATH="$test_tmp/bin:/usr/bin:/bin"

mkdir -p "$test_tmp/bin"

COLLECTOR="$ROOT/bin/omarchy-agent-usage-agy"

today=$(python3 -c 'import datetime as dt; print(dt.datetime.now().astimezone().strftime("%Y-%m-%d"))')
yesterday=$(python3 -c 'import datetime as dt; print((dt.datetime.now().astimezone() - dt.timedelta(days=1)).strftime("%Y-%m-%d"))')
now_iso=$(python3 -c 'import datetime as dt; print(dt.datetime.now().astimezone().isoformat())')
yesterday_iso=$(python3 -c 'import datetime as dt; print((dt.datetime.now().astimezone() - dt.timedelta(days=1)).isoformat())')

# 1. A machine with no Antigravity installed or data gives an empty record
record=$(AGY_BIN="" AGY_DIR="$test_tmp/nonexistent" "$COLLECTOR")
[[ $(jq -c '{ready, tierLabel, limits, limitsStale, limitsFetchedAt, hasLocalStats}' <<<"$record") == \
   '{"ready":false,"tierLabel":"","limits":[],"limitsStale":false,"limitsFetchedAt":0,"hasLocalStats":false}' ]] ||
  fail "a machine nobody installed Antigravity on gives an empty record" "$record"
pass "a machine nobody installed Antigravity on gives an empty record"

# 2. Local data fixtures: history.jsonl, SQLite database, and brain transcripts
agy_dir="$test_tmp/agy"
mkdir -p "$agy_dir/brain/session-1" "$agy_dir/brain/session-2"

cat >"$agy_dir/history.jsonl" <<EOF
{"timestamp":"${today}T10:00:00","prompt":"hello today 1"}
{"timestamp":"${today}T11:00:00","prompt":"hello today 2"}
{"timestamp":"${yesterday}T09:00:00","prompt":"hello yesterday 1"}
{"timestamp":"${yesterday}T12:00:00","prompt":"hello yesterday 2"}
{"timestamp":"${yesterday}T15:00:00","prompt":"hello yesterday 3"}
EOF

sqlite3 "$agy_dir/conversation_summaries.db" <<EOF
CREATE TABLE conversation_summaries (
  conversation_id text PRIMARY KEY,
  parent_conversation_id text,
  last_modified_time text
);
INSERT INTO conversation_summaries VALUES ('c1', '', '${today} 10:00:00');
INSERT INTO conversation_summaries VALUES ('c2', '', '${yesterday} 10:00:00');
INSERT INTO conversation_summaries VALUES ('c3', NULL, '${yesterday} 14:00:00');
INSERT INTO conversation_summaries VALUES ('child-1', 'c1', '${today} 10:05:00');
EOF

cat >"$agy_dir/brain/session-1/transcript.jsonl" <<EOF
{"step_index":1,"created_at":"${now_iso}","input_tokens":100,"output_tokens":20,"cache_read_tokens":10,"model":"gemini-3.8-flash"}
{"step_index":2,"created_at":"${now_iso}","input_tokens":200,"output_tokens":30,"cache_read_tokens":0}
EOF

cat >"$agy_dir/brain/session-2/transcript.jsonl" <<EOF
{"step_index":1,"created_at":"${yesterday_iso}","input_tokens":500,"output_tokens":50,"cache_read_tokens":0,"model":"gemini-3.8-flash"}
EOF

record=$(AGY_BIN="" AGY_DIR="$agy_dir" "$COLLECTOR")

[[ $(jq -c '{ready, hasLocalStats, todayPrompts, totalPrompts, todaySessions, totalSessions, todayTotalTokens}' <<<"$record") == \
   '{"ready":true,"hasLocalStats":true,"todayPrompts":2,"totalPrompts":5,"todaySessions":1,"totalSessions":3,"todayTotalTokens":350}' ]] ||
  fail "Antigravity counts prompts, sessions, and today tokens correctly" "$record"
pass "Antigravity counts prompts, sessions, and today tokens correctly"

# Verify token-based weekly counts and model attribution
[[ $(jq -c '{todayTokensByModel, todayRecent: .recentDays[6].messageCount, yesterdayRecent: .recentDays[5].messageCount}' <<<"$record") == \
   '{"todayTokensByModel":{"gemini-3.8-flash":120,"unknown":230},"todayRecent":350,"yesterdayRecent":550}' ]] ||
  fail "weekly tokens count tokens rather than prompts, keeping models distinct" "$record"
pass "weekly tokens count tokens rather than prompts, keeping models distinct"

[[ $(jq -cS '.modelUsage' <<<"$record") == \
   '{"gemini-3.8-flash":{"cacheCreationInputTokens":0,"cacheReadInputTokens":10,"inputTokens":600,"outputTokens":70},"unknown":{"cacheCreationInputTokens":0,"cacheReadInputTokens":0,"inputTokens":200,"outputTokens":30}}' ]] ||
  fail "all-time model usage preserves historical models and handles unknown models" "$record"
pass "all-time model usage preserves historical models and handles unknown models"

# 3. Model changes in settings.json do not rewrite history
echo '{"model": "custom-exp-model"}' >"$agy_dir/settings.json"
record=$(AGY_BIN="" AGY_DIR="$agy_dir" "$COLLECTOR" --force)

[[ $(jq -r '.tierLabel' <<<"$record") == "custom-exp-model" ]] ||
  fail "active model is read from settings.json" "$record"
[[ $(jq -r '.modelUsage["custom-exp-model"]' <<<"$record") == "null" ]] ||
  fail "model changes in settings.json do not rewrite historical modelUsage" "$record"
pass "model changes in settings.json do not rewrite historical modelUsage"

# 4. Limits-only refresh reuses the session scan
cat >>"$agy_dir/history.jsonl" <<EOF
{"timestamp":"${today}T18:00:00","prompt":"hello later"}
EOF

record=$(AGY_BIN="" AGY_DIR="$agy_dir" "$COLLECTOR" --limits-only)
[[ $(jq -r '.totalPrompts' <<<"$record") == 5 ]] ||
  fail "a limits-only refresh reuses the stats scan" "$record"
pass "a limits-only refresh reuses the stats scan"

# 5. A scan from another day is made again
stats_cache="$XDG_CACHE_HOME/omarchy/agent-usage/agy-stats.json"
jq '.day = "2000-01-01"' "$stats_cache" >"$test_tmp/stale-stats.json"
mv "$test_tmp/stale-stats.json" "$stats_cache"

record=$(AGY_BIN="" AGY_DIR="$agy_dir" "$COLLECTOR" --limits-only)
[[ $(jq -r '.totalPrompts' <<<"$record") == 6 ]] ||
  fail "a scan from another day is made again" "$record"
pass "a scan from another day is made again"

# 6. Authoritative limits probe via agy CLI and staleness marking
cat >"$test_tmp/bin/agy" <<'EOF'
#!/bin/sh
if [ "$2" = "/usage" ]; then
  cat <<'JSON'
{"command":{"data":{"groups":[{"name":"Gemini Models","buckets":[{"window":"5h","remaining_fraction":0.8,"reset_time":"2026-10-12T00:00:00Z"}]}]}}}
JSON
  exit 0
fi
exit 1
EOF
chmod +x "$test_tmp/bin/agy"

rm -f "$XDG_CACHE_HOME/omarchy/agent-usage/agy-limits.json"
record=$(AGY_BIN="$test_tmp/bin/agy" AGY_DIR="$agy_dir" "$COLLECTOR" --force)
[[ $(jq -c '{label: .limits[0].label, percent: .limits[0].percent, stale: .limitsStale}' <<<"$record") == \
   '{"label":"Session (5-hour)","percent":0.2,"stale":false}' ]] ||
  fail "fresh authoritative limits are parsed with limitsStale=false" "$record"
[[ $(jq -r '.limitsFetchedAt' <<<"$record") -gt 0 ]] ||
  fail "limitsFetchedAt timestamp is recorded" "$record"
pass "authoritative limits are parsed from agy /usage"

# When probe fails later, cached limits are preserved and marked stale
cat >"$test_tmp/bin/agy" <<'EOF'
#!/bin/sh
exit 1
EOF
record=$(AGY_BIN="$test_tmp/bin/agy" AGY_DIR="$agy_dir" "$COLLECTOR" --force)
[[ $(jq -c '{label: .limits[0].label, percent: .limits[0].percent, stale: .limitsStale}' <<<"$record") == \
   '{"label":"Session (5-hour)","percent":0.2,"stale":true}' ]] ||
  fail "failed probe preserves cached limits with limitsStale=true" "$record"
pass "failed probe preserves cached limits with limitsStale=true"

# 7. Unwritable cache directory does not stop usage scan
bad_cache="$test_tmp/bad-cache-file"
touch "$bad_cache"
record=$(XDG_CACHE_HOME="$bad_cache" AGY_BIN="" AGY_DIR="$agy_dir" "$COLLECTOR")
[[ $(jq -r '.ready' <<<"$record") == "true" && $(jq -r '.totalPrompts' <<<"$record") == "6" ]] ||
  fail "collector still returns fresh usage when cache directory is unwritable" "$record"
pass "collector still returns fresh usage when cache directory is unwritable"

# 8. --write writes atomically to state file
state_file="$XDG_STATE_HOME/omarchy/agents/usage/agy.json"
rm -f "$state_file"
AGY_BIN="" AGY_DIR="$agy_dir" "$COLLECTOR" --write >/dev/null
[[ -f "$state_file" ]] && jq -e . >/dev/null "$state_file" ||
  fail "collector --write saves atomic state record"
pass "collector --write saves atomic state record"

# 9. --write failure exits with nonzero code
bad_state="$test_tmp/bad-state"
touch "$bad_state"
if XDG_STATE_HOME="$bad_state" AGY_BIN="" AGY_DIR="$agy_dir" "$COLLECTOR" --write 2>/dev/null; then
  fail "collector --write should fail when state directory is not writable"
fi
pass "collector --write exits with nonzero code on failure"
