#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
require_command python3

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

export HOME="$test_tmp/home"
export XDG_CONFIG_HOME="$test_tmp/config"
export XDG_CACHE_HOME="$test_tmp/cache"
export XDG_STATE_HOME="$test_tmp/state"

mkdir -p "$HOME" "$XDG_CONFIG_HOME/cursor" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

billing_end_ms=$(python3 -c 'import datetime as dt; print(int((dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=12)).timestamp() * 1000))')

signed_in() {
  jq -nc --arg token "$1" '{accessToken: $token}' >"$XDG_CONFIG_HOME/cursor/auth.json"
}

# COLLECT_ARGS unset => --force. COLLECT_ARGS="" => no flags (reuse allowed).
collect() {
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-x" BILLING_END_MS="$billing_end_ms" \
    AUTO_PCT="${AUTO_PCT:-37.5}" python3 - "$@" <<'PY'
import importlib.machinery, importlib.util, io, json, os, sys, urllib.error

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

end = int(os.environ["BILLING_END_MS"])
auto = float(os.environ["AUTO_PCT"])
responses = {
  "aiserver.v1.DashboardService/GetPlanInfo": {
    "planInfo": {
      "planName": "Pro",
      "price": "$20/mo",
      "includedUsagePeriod": "INCLUDED_USAGE_PERIOD_MONTHLY",
    }
  },
  "aiserver.v1.DashboardService/GetCurrentPeriodUsage": {
    "billingCycleEnd": end,
    "planUsage": {
      "autoPercentUsed": auto,
      "apiPercentUsed": 0,
      "totalPercentUsed": auto,
    },
  },
}

calls = {"n": 0}

def urlopen(request, timeout=None):
  calls["n"] += 1
  if os.environ.get("X_FAIL_USAGE") == "1":
    raise urllib.error.HTTPError(request.full_url, 401, "Unauthorized", hdrs=None, fp=None)
  if os.environ.get("X_REJECT_API") == "1":
    raise AssertionError(f"unexpected API call: {request.full_url}")
  method = request.full_url.split("://", 1)[-1].split("/", 1)[-1]
  if method.endswith("GetAggregatedUsageEvents"):
    # Optional day-token fixture for the tokens-by-day test.
    rows = json.loads(os.environ.get("X_DAY_AGG", "[]"))
    class Resp(io.BytesIO):
      def __enter__(self): return self
      def __exit__(self, *a): return False
    return Resp(json.dumps({"aggregations": rows}).encode())
  if method not in responses:
    raise AssertionError(f"unexpected method {method}")
  auth = request.get_header("Authorization") or request.get_header("authorization")
  expected = os.environ.get("X_TOKEN", "token-main")
  assert auth.split(" ", 1)[1] == expected

  class Resp(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): return False

  return Resp(json.dumps(responses[method]).encode())

collector.urllib.request.urlopen = urlopen
if "COLLECT_ARGS" in os.environ:
  args = os.environ["COLLECT_ARGS"].split() if os.environ["COLLECT_ARGS"] else []
else:
  args = ["--force"]
sys.argv = ["omarchy-agent-usage-x"] + args
collector.main()
print(f"\n__calls__={calls['n']}", file=sys.stderr)
PY
}

record=$(collect)
[[ $(jq -c '{ready, tierLabel, limits, usageStatusText}' <<<"$record") == '{"ready":false,"tierLabel":"","limits":[],"usageStatusText":"Cursor auth missing"}' ]] ||
  fail "without Cursor auth the X Subscription record stays empty" "$record"
pass "without Cursor auth the X Subscription record stays empty"

signed_in token-main
record=$(collect)
[[ $(jq -c '{ready, id, name, tierLabel, stale: .limitsStale, label: .limits[0].label, percent: .limits[0].percent}' <<<"$record") == '{"ready":true,"id":"x","name":"X Subscription","tierLabel":"Pro · $20/mo · shared monthly pool","stale":false,"label":"Included pool (Cursor + Grok)","percent":0.375}' ]] ||
  fail "X Subscription plan and shared pool come from Cursor dashboard APIs" "$record"
[[ -n $(jq -r '.limits[0].resetsAt' <<<"$record") ]] || fail "the billing window says when the period ends" "$record"
[[ $(jq -r '.authHelpText' <<<"$record") == "" ]] || fail "a successful probe drops the login hint" "$record"
pass "X Subscription plan and shared pool come from Cursor dashboard APIs"

# 0–100 API percents at and below 1 stay 1% / 0.5%, not a full bar.
record=$(AUTO_PCT=1 COLLECT_ARGS="--force" collect)
[[ $(jq -r '.limits[0].percent' <<<"$record") == "0.01" ]] ||
  fail "1% used from the API is 0.01, not a full bar" "$record"
record=$(AUTO_PCT=0.5 COLLECT_ARGS="--force" collect)
[[ $(jq -r '.limits[0].percent' <<<"$record") == "0.005" ]] ||
  fail "0.5% used from the API is 0.005" "$record"
pass "small API percentages stay small"

# Reused limits must not hit the network again.
record=$(X_REJECT_API=1 COLLECT_ARGS="" collect 2>"$test_tmp/reuse.err")
[[ $(jq -c '{percent: .limits[0].percent, help: .authHelpText, stale: .limitsStale}' <<<"$record") == '{"percent":0.005,"help":"","stale":false}' ]] ||
  fail "reused X Subscription limits drop the login hint" "$record"
grep -q 'unexpected API call' "$test_tmp/reuse.err" &&
  fail "cache reuse still called the API" "$(cat "$test_tmp/reuse.err")"
pass "reused X Subscription limits drop the login hint"

# A failed probe keeps the last numbers for this login and says so.
record=$(collect)
record=$(X_FAIL_USAGE=1 COLLECT_ARGS="--force" collect)
[[ $(jq -c '{usageStatusText, first: .limits[0].percent, stale: .limitsStale}' <<<"$record") == '{"usageStatusText":"Waiting for auth","first":0.375,"stale":true}' ]] ||
  fail "a failed probe keeps the last shared-pool numbers" "$record"
pass "a failed probe keeps the last shared-pool numbers"

# A different Cursor login never inherits the previous account's cache.
signed_in token-side
record=$(X_TOKEN=token-side AUTO_PCT=12 COLLECT_ARGS="--force" collect)
[[ $(jq -c '{percent: .limits[0].percent, stale: .limitsStale}' <<<"$record") == '{"percent":0.12,"stale":false}' ]] ||
  fail "a new Cursor login probes its own shared pool" "$record"
caches=$(find "$XDG_CACHE_HOME/omarchy/agent-usage" -name 'x-limits-*.json' | wc -l)
((caches >= 2)) || fail "each Cursor login keeps its own limits cache" "caches=$caches"
pass "a new Cursor login probes its own shared pool"

# Local Cursor transcripts become prompt/session stats from each turn's stamp.
projects="$HOME/.cursor/projects/demo/agent-transcripts"
mkdir -p "$projects"
today_stamp=$(python3 -c 'import datetime as dt; print(dt.date.today().strftime("%A, %b %-d, %Y"))')
old_stamp="Monday, Jan 5, 2026"
cat >"$projects/session-a.jsonl" <<JSONL
{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>${old_stamp}, 9:00 AM (UTC-5)</timestamp>\\n<user_query>old</user_query>"}]}}
{"role":"assistant","content":"hi"}
{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>${today_stamp}, 10:00 AM (UTC-5)</timestamp>\\n<user_query>today</user_query>"}]}}
{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>${today_stamp}, 11:00 AM (UTC-5)</timestamp>\\n<user_query>again</user_query>"}]}}
JSONL
cat >"$projects/session-b.jsonl" <<JSONL
{"type":"human","message":{"content":[{"type":"text","text":"<timestamp>${today_stamp}, 1:00 PM (UTC-5)</timestamp>\\n<user_query>other</user_query>"}]}}
JSONL
# Continuing an old file today must not move its undated/old prompts onto today.
cat >"$projects/session-old.jsonl" <<'JSONL'
{"role":"user","content":"no stamp here"}
{"role":"assistant","content":"ok"}
JSONL
touch -d "2026-01-02 12:00:00" "$projects/session-old.jsonl"
touch -d "$(date '+%Y-%m-%d %H:%M:%S')" "$projects/session-a.jsonl" "$projects/session-b.jsonl"
rm -f "$XDG_CACHE_HOME"/omarchy/agent-usage/x-scan.json
record=$(X_TOKEN=token-side COLLECT_ARGS="--force" collect)
[[ $(jq -c '{hasLocalStats, todayPrompts, todaySessions, totalPrompts, totalSessions, weekTokens: ([.recentDays[].messageCount] | add)}' <<<"$record") == '{"hasLocalStats":true,"todayPrompts":3,"todaySessions":2,"totalPrompts":5,"totalSessions":3,"weekTokens":0}' ]] ||
  fail "X Subscription counts dated prompts and keeps recentDays in tokens" "$record"
pass "X Subscription counts dated prompts and keeps recentDays in tokens"

# Empty / assistant-only transcripts do not invent activity.
mkdir -p "$projects/empty"
: >"$projects/empty/blank.jsonl"
printf '%s\n' '{"role":"assistant","content":"only reply"}' >"$projects/empty/assistant-only.jsonl"
rm -f "$XDG_CACHE_HOME"/omarchy/agent-usage/x-scan.json
record=$(X_TOKEN=token-side COLLECT_ARGS="--force" collect)
[[ $(jq -c '{totalPrompts, totalSessions, activeDays}' <<<"$record") == '{"totalPrompts":5,"totalSessions":3,"activeDays":2}' ]] ||
  fail "empty transcripts do not invent prompts or active days" "$record"
pass "empty transcripts do not invent prompts or active days"

# Stamped offsets convert into the machine's local calendar day.
python3 - "$ROOT/bin/omarchy-agent-usage-x" <<'PY'
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("collector", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)
obj = {
  "role": "user",
  "message": {
    "content": [{
      "type": "text",
      "text": "<timestamp>Monday, Oct 12, 2026, 11:30 PM (UTC-5)</timestamp>\n<user_query>x</user_query>",
    }]
  },
}
os.environ["TZ"] = "UTC"
# Reload local clock helpers after TZ change.
import time
time.tzset()
day = collector.prompt_day(obj)
assert str(day) == "2026-10-13", day
os.environ["TZ"] = "America/Chicago"
time.tzset()
day = collector.prompt_day(obj)
assert str(day) == "2026-10-12", day
iso_day = collector.prompt_day({"role": "user", "createdAt": "2026-10-13T04:30:00Z"})
assert str(iso_day) == "2026-10-12", iso_day
print("ok")
PY
[[ $? -eq 0 ]] || fail "prompt stamps convert into the local calendar day"
pass "prompt stamps convert into the local calendar day"

# Dashboard day aggregates fill recentDays.messageCount with tokens.
agg='[{"modelIntent":"grok-4.7-high-fast","inputTokens":100,"outputTokens":20,"cacheReadTokens":5,"cacheWriteTokens":0}]'
rm -f "$XDG_CACHE_HOME"/omarchy/agent-usage/x-tokens-*.json
record=$(X_TOKEN=token-side X_DAY_AGG="$agg" COLLECT_ARGS="--force" collect)
[[ $(jq -c '{todayTotalTokens, weekTokens: ([.recentDays[].messageCount] | add), model: .todayTokensByModel["grok-4.7-high-fast"]}' <<<"$record") == '{"todayTotalTokens":125,"weekTokens":875,"model":125}' ]] ||
  fail "dashboard day aggregates fill token counts for the week" "$record"
pass "dashboard day aggregates fill token counts for the week"

# limits-only reuses the transcript scan.

mkdir -p "$projects/extra"
printf '%s\n' "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"<timestamp>${today_stamp}, 2:00 PM (UTC-5)</timestamp>\\n<user_query>later</user_query>\"}]}}" >"$projects/extra/session-c.jsonl"
record=$(X_TOKEN=token-side COLLECT_ARGS="--limits-only" collect)
[[ $(jq -r '.totalSessions' <<<"$record") == 3 ]] || fail "a limits-only refresh reuses the transcript scan" "$record"
pass "a limits-only refresh reuses the transcript scan"
