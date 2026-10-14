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

COLLECTOR="$ROOT/bin/omarchy-agent-usage-opencode"

today=$(python3 -c 'import datetime as dt; print(dt.datetime.now().astimezone().strftime("%Y-%m-%d"))')
yesterday=$(python3 -c 'import datetime as dt; print((dt.datetime.now().astimezone() - dt.timedelta(days=1)).strftime("%Y-%m-%d"))')
now_ms=$(python3 -c 'import time; print(round(time.time() * 1000))')
yesterday_ms=$(python3 -c 'import time; print(round((time.time() - 86400) * 1000))')

# 1. A machine with no Opencode installed or data gives an empty record
record=$(OPENCODE_BIN="" OPENCODE_DB="$test_tmp/nonexistent.db" OPENCODE_CONFIG="$test_tmp/nonexistent.json" "$COLLECTOR")
[[ $(jq -c '{ready, tierLabel, limits, limitsStale, limitsFetchedAt, hasLocalStats}' <<<"$record") == \
   '{"ready":false,"tierLabel":"","limits":[],"limitsStale":false,"limitsFetchedAt":0,"hasLocalStats":false}' ]] ||
  fail "a machine nobody installed Opencode on gives an empty record" "$record"
pass "a machine nobody installed Opencode on gives an empty record"

# 2. Local database and config fixtures
db_file="$test_tmp/opencode.db"
cfg_file="$test_tmp/opencode.json"

sqlite3 "$db_file" <<EOF
CREATE TABLE message (
  id text PRIMARY KEY,
  session_id text NOT NULL,
  time_created integer NOT NULL,
  time_updated integer NOT NULL,
  data text NOT NULL
);
EOF

# Message 1 today: assistant with muse-spark-1.3, input 100, output 20, reasoning 10, cache read 30
m1_data=$(jq -nc --arg model "opencode/muse-spark-1.3" --argjson t "$now_ms" \
  '{"role":"assistant","modelID":$model,"time":{"created":$t},"tokens":{"input":100,"output":20,"reasoning":10,"cache":{"read":30,"write":0}}}')
# Message 2 today: assistant with claude-3-5-sonnet, input 200, output 50, cache read 0, cache write 10
m2_data=$(jq -nc --arg model "claude-3-5-sonnet" --argjson t "$now_ms" \
  '{"role":"assistant","modelID":$model,"time":{"created":$t},"tokens":{"input":200,"output":50,"reasoning":0,"cache":{"read":0,"write":10}}}')
# Message 3 yesterday: assistant with muse-spark-1.3, input 500, output 50
m3_data=$(jq -nc --arg model "opencode/muse-spark-1.3" --argjson t "$yesterday_ms" \
  '{"role":"assistant","modelID":$model,"time":{"created":$t},"tokens":{"input":500,"output":50,"reasoning":0,"cache":{"read":0,"write":0}}}')
# Message 4 today: user role (must be ignored)
m4_data='{"role":"user","tokens":{"input":50,"output":0}}'
# Message 5 today: assistant with 0 tokens (must be ignored)
m5_data='{"role":"assistant","tokens":{"input":0,"output":0}}'
# Message 6: malformed data blob
m6_data='not-json'

sqlite3 "$db_file" <<EOF
INSERT INTO message VALUES ('m1', 's1', $now_ms, $now_ms, '$m1_data');
INSERT INTO message VALUES ('m2', 's1', $now_ms, $now_ms, '$m2_data');
INSERT INTO message VALUES ('m3', 's2', $yesterday_ms, $yesterday_ms, '$m3_data');
INSERT INTO message VALUES ('m4', 's1', $now_ms, $now_ms, '$m4_data');
INSERT INTO message VALUES ('m5', 's1', $now_ms, $now_ms, '$m5_data');
INSERT INTO message VALUES ('m6', 's1', $now_ms, $now_ms, '$m6_data');
EOF

echo '{"model": "opencode/muse-spark-1.3"}' >"$cfg_file"

record=$(OPENCODE_BIN="" OPENCODE_DB="$db_file" OPENCODE_CONFIG="$cfg_file" "$COLLECTOR")

# Total tokens:
# m1: 100 + (20+10) + 30 = 160
# m2: 200 + 50 + 0 + 10 = 260
# today total = 160 + 260 = 420
# m3 (yesterday): 500 + 50 = 550
# grand total = 420 + 550 = 970
# sessions: s1, s2 = 2 total, s1 = 1 today
[[ $(jq -c '{ready, hasLocalStats, todayPrompts, totalPrompts, todaySessions, totalSessions, todayTotalTokens}' <<<"$record") == \
   '{"ready":true,"hasLocalStats":true,"todayPrompts":2,"totalPrompts":3,"todaySessions":1,"totalSessions":2,"todayTotalTokens":420}' ]] ||
  fail "Opencode counts prompts, sessions, and today tokens correctly" "$record"
pass "Opencode counts prompts, sessions, and today tokens correctly"

[[ $(jq -cS '{todayTokensByModel, todayRecent: .recentDays[6].messageCount, yesterdayRecent: .recentDays[5].messageCount}' <<<"$record") == \
   '{"todayRecent":420,"todayTokensByModel":{"claude-3-5-sonnet":260,"opencode/muse-spark-1.3":160},"yesterdayRecent":550}' ]] ||
  fail "weekly tokens count tokens rather than prompts, keeping models distinct" "$record"
pass "weekly tokens count tokens rather than prompts, keeping models distinct"

[[ $(jq -cS '.modelUsage' <<<"$record") == \
   '{"claude-3-5-sonnet":{"cacheCreationInputTokens":10,"cacheReadInputTokens":0,"inputTokens":200,"outputTokens":50},"opencode/muse-spark-1.3":{"cacheCreationInputTokens":0,"cacheReadInputTokens":30,"inputTokens":600,"outputTokens":80}}' ]] ||
  fail "all-time model usage preserves historical models and handles reasoning/cache tokens" "$record"
pass "all-time model usage preserves historical models and handles reasoning/cache tokens"

[[ $(jq -r '.tierLabel' <<<"$record") == "muse-spark-1.3" ]] ||
  fail "tierLabel extracts model name from config" "$record"
pass "tierLabel extracts model name from config"

# 3. Model fallback when config is missing
echo '{}' >"$cfg_file"
record=$(OPENCODE_BIN="" OPENCODE_DB="$db_file" OPENCODE_CONFIG="$cfg_file" "$COLLECTOR" --force)
[[ $(jq -r '.tierLabel' <<<"$record") == "opencode/muse-spark-1.3" ]] ||
  fail "tierLabel falls back to most-used model when config omits model" "$record"
pass "tierLabel falls back to most-used model when config omits model"

# 4. Limits-only refresh reuses the session scan
m7_data=$(jq -nc --arg model "claude-3-5-sonnet" --argjson t "$now_ms" \
  '{"role":"assistant","modelID":$model,"time":{"created":$t},"tokens":{"input":50,"output":10,"reasoning":0,"cache":{"read":0,"write":0}}}')
sqlite3 "$db_file" "INSERT INTO message VALUES ('m7', 's1', $now_ms, $now_ms, '$m7_data')"

record=$(OPENCODE_BIN="" OPENCODE_DB="$db_file" OPENCODE_CONFIG="$cfg_file" "$COLLECTOR" --limits-only)
[[ $(jq -r '.totalPrompts' <<<"$record") == 3 ]] ||
  fail "a limits-only refresh reuses the stats scan" "$record"
pass "a limits-only refresh reuses the stats scan"

# 5. A scan from another day is made again
stats_cache="$XDG_CACHE_HOME/omarchy/agent-usage/opencode-stats.json"
jq '.day = "2000-01-01"' "$stats_cache" >"$test_tmp/stale-stats.json"
mv "$test_tmp/stale-stats.json" "$stats_cache"

record=$(OPENCODE_BIN="" OPENCODE_DB="$db_file" OPENCODE_CONFIG="$cfg_file" "$COLLECTOR" --limits-only)
[[ $(jq -r '.totalPrompts' <<<"$record") == 4 ]] ||
  fail "a scan from another day is made again" "$record"
pass "a scan from another day is made again"

# 6. Unwritable cache directory does not stop usage scan
bad_cache="$test_tmp/bad-cache-file"
touch "$bad_cache"
record=$(XDG_CACHE_HOME="$bad_cache" OPENCODE_BIN="" OPENCODE_DB="$db_file" OPENCODE_CONFIG="$cfg_file" "$COLLECTOR")
[[ $(jq -r '.ready' <<<"$record") == "true" && $(jq -r '.totalPrompts' <<<"$record") == "4" ]] ||
  fail "collector still returns fresh usage when cache directory is unwritable" "$record"
pass "collector still returns fresh usage when cache directory is unwritable"

# 7. --write writes atomically to state file
state_file="$XDG_STATE_HOME/omarchy/agents/usage/opencode.json"
rm -f "$state_file"
OPENCODE_BIN="" OPENCODE_DB="$db_file" OPENCODE_CONFIG="$cfg_file" "$COLLECTOR" --write >/dev/null
[[ -f "$state_file" ]] && jq -e . >/dev/null "$state_file" ||
  fail "collector --write saves atomic state record"
pass "collector --write saves atomic state record"

# 8. --write failure exits with nonzero code
bad_state="$test_tmp/bad-state"
touch "$bad_state"
if XDG_STATE_HOME="$bad_state" OPENCODE_BIN="" OPENCODE_DB="$db_file" OPENCODE_CONFIG="$cfg_file" "$COLLECTOR" --write 2>/dev/null; then
  fail "collector --write should fail when state directory is not writable"
fi
pass "collector --write exits with nonzero code on failure"

# 9. Opencode ignores anthropic and openai messages to avoid double counting with Claude/Codex
m_ant=$(jq -nc --arg model "claude-3-7-sonnet" --argjson t "$now_ms" \
  '{"role":"assistant","providerID":"anthropic","modelID":$model,"time":{"created":$t},"tokens":{"input":1000,"output":500,"reasoning":0,"cache":{"read":0,"write":0}}}')
m_oai=$(jq -nc --arg model "gpt-5" --argjson t "$now_ms" \
  '{"role":"assistant","providerID":"openai","modelID":$model,"time":{"created":$t},"tokens":{"input":2000,"output":800,"reasoning":0,"cache":{"read":0,"write":0}}}')
sqlite3 "$db_file" <<EOF
INSERT INTO message VALUES ('m_ant', 's_overlap', $now_ms, $now_ms, '$m_ant');
INSERT INTO message VALUES ('m_oai', 's_overlap', $now_ms, $now_ms, '$m_oai');
EOF

record=$(OPENCODE_BIN="" OPENCODE_DB="$db_file" OPENCODE_CONFIG="$cfg_file" "$COLLECTOR" --force)
[[ $(jq -r '.totalPrompts' <<<"$record") == 4 ]] ||
  fail "Opencode ignores anthropic and openai messages to avoid double counting" "$record"
pass "Opencode ignores anthropic and openai messages to avoid double counting"

# 10. Opencode reads v2 session_message in a mixed database
sqlite3 "$db_file" <<EOF
CREATE TABLE session_message (
  id text PRIMARY KEY,
  session_id text NOT NULL,
  type text NOT NULL,
  seq integer NOT NULL,
  time_created integer NOT NULL,
  time_updated integer NOT NULL,
  data text NOT NULL
);
EOF

v2_data=$(jq -nc --arg model "deepseek-chat" --argjson t "$now_ms" \
  '{"model":{"id":$model,"providerID":"deepseek"},"time":{"created":$t},"tokens":{"input":300,"output":100,"reasoning":50,"cache":{"read":20,"write":0}}}')
v2_ant=$(jq -nc --arg model "claude-opus-5" --argjson t "$now_ms" \
  '{"model":{"id":$model,"providerID":"anthropic"},"time":{"created":$t},"tokens":{"input":999,"output":999}}')
v2_oai=$(jq -nc --arg model "gpt-5-codex" --argjson t "$now_ms" \
  '{"model":{"id":$model,"providerID":"openai"},"time":{"created":$t},"tokens":{"input":999,"output":999}}')
v2_user='{"tokens":{"input":50,"output":0}}'

sqlite3 "$db_file" <<EOF
INSERT INTO session_message VALUES ('v1', 's_v2', 'assistant', 1, $now_ms, $now_ms, '$v2_data');
INSERT INTO session_message VALUES ('v2', 's_v2', 'assistant', 2, $now_ms, $now_ms, '$v2_ant');
INSERT INTO session_message VALUES ('v3', 's_v2', 'assistant', 3, $now_ms, $now_ms, '$v2_oai');
INSERT INTO session_message VALUES ('v4', 's_v2', 'user', 4, $now_ms, $now_ms, '$v2_user');
EOF

record=$(OPENCODE_BIN="" OPENCODE_DB="$db_file" OPENCODE_CONFIG="$cfg_file" "$COLLECTOR" --force)
# 4 previous prompts + 1 deepseek prompt + 1 openai v2 prompt = 6 total prompts
# Anthropic v2 is skipped (collected by Claude); OpenAI v2 is counted (Codex only collects v1 message)
[[ $(jq -r '.totalPrompts' <<<"$record") == 6 && $(jq -r '.modelUsage["deepseek-chat"].inputTokens' <<<"$record") == 300 && $(jq -r '.modelUsage["gpt-5-codex"].inputTokens' <<<"$record") == 999 ]] ||
  fail "Opencode reads session_message rows, preserves v2 openai, and filters v2 anthropic" "$record"
pass "Opencode reads session_message rows, preserves v2 openai, and filters v2 anthropic"

# 11. Opencode counts usage from a v2-only database (no message table)
v2_db="$test_tmp/v2_only.db"
sqlite3 "$v2_db" <<EOF
CREATE TABLE session_message (
  id text PRIMARY KEY,
  session_id text NOT NULL,
  type text NOT NULL,
  seq integer NOT NULL,
  time_created integer NOT NULL,
  time_updated integer NOT NULL,
  data text NOT NULL
);
INSERT INTO session_message VALUES ('v_only', 's_v2only', 'assistant', 1, $now_ms, $now_ms, '$v2_data');
EOF

record=$(OPENCODE_BIN="" OPENCODE_DB="$v2_db" OPENCODE_CONFIG="$cfg_file" "$COLLECTOR" --force)
[[ $(jq -r '.ready' <<<"$record") == "true" && $(jq -r '.totalPrompts' <<<"$record") == 1 && $(jq -r '.todayTotalTokens' <<<"$record") == 470 ]] ||
  fail "Opencode counts usage from a v2-only database with session_message" "$record"
pass "Opencode counts usage from a v2-only database with session_message"

